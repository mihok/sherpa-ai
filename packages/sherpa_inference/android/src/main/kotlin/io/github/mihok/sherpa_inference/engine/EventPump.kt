package io.github.mihok.sherpa_inference.engine

import io.github.mihok.sherpa_inference.EngineEventMsg
import io.github.mihok.sherpa_inference.EventBatch
import io.github.mihok.sherpa_inference.InferenceMessage
import io.github.mihok.sherpa_inference.StreamFailed
import io.github.mihok.sherpa_inference.StreamStarted
import java.util.ArrayDeque
import java.util.concurrent.CompletableFuture
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/** Flow-control and cadence knobs (defaults mirror ffi_isolates.dart). */
data class PumpConfig(
  /** Longest block inside `se_poll_events` before commands (cancel, credit) are looked at again. */
  val pollTimeoutMs: Int = 4,
  /** Deltas are coalesced for about one frame; the first batch of a stream goes out at once (TTFT). */
  val coalesceWindowMs: Long = 16,
  /** Events per poll and per pending buffer. */
  val maxPendingEvents: Int = 256,
  /**
   * Batches a stream may have in flight across Binder + buffered in the main process / Dart before the pump
   * stops polling its session (then the engine ring fills and decode blocks: real backpressure).
   */
  val streamCredits: Int = 4,
  /**
   * Soft cap of one batch's payload. A stream's pending buffer at this size stops polling and is sent in
   * chunks of at most this size (one credit each); only a single event larger than the cap (a long FINISH
   * message, a big tool-call argument) exceeds it, and the transport moves such payloads through
   * SharedMemory. With [streamCredits] = 4 a stream holds at most ~64 KiB of a process's 1 MiB Binder buffer.
   */
  val batchByteCap: Int = 16 * 1024,
)

/**
 * The single consumer of every session's event ring (`se_poll_events`, header "Threading"), on its own
 * thread: a port of the FFI host's pump isolate (ffi_isolates.dart `_Pump`) with the same semantics —
 * starts queue behind a session's running/draining generation, cancelled streams drain until FINISH,
 * coalescing never drops an event, at most [PumpConfig.streamCredits] batches are outstanding per stream.
 */
class EventPump(
  private val engine: Engine,
  private val sink: (InferenceMessage) -> Unit,
  private val phases: PhaseTracker?,
  private val config: PumpConfig = PumpConfig(),
) {
  /** A generation start handed over by the session's serial queue. */
  class Start(
    val streamId: Long,
    val session: Long,
    val requestJson: String,
    val modelTag: String?,
    val nCtx: Long?,
    val kv: String?,
  ) {
    /** Completed once the start ran (started or refused) or is queued behind the session's previous one. */
    val handled = CompletableFuture<Unit>()
  }

  private sealed interface Cmd

  private class StartCmd(val start: Start) : Cmd

  private class CreditCmd(val streamId: Long, val n: Int) : Cmd

  private class CancelStreamCmd(val streamId: Long) : Cmd

  private class ReleaseCmd(val session: Long, val done: CompletableFuture<Unit>) : Cmd

  private class StopCmd(val done: CompletableFuture<Unit>) : Cmd

  private class Pending(var event: EngineEventMsg, var bytes: Int) {
    var text: StringBuilder? = null

    fun toMsg(): EngineEventMsg = text?.let { event.copy(text = it.toString()) } ?: event
  }

  private inner class Gen(val streamId: Long, val session: Long, val generationId: Long, val phase: PhaseTracker.Token?) {
    var credits = config.streamCredits
    var discard = false
    var finished = false
    var sentAny = false
    val pending = ArrayList<Pending>()
    var pendingBytes = 0
    var pendingSince = 0L

    val canPoll: Boolean
      get() = !finished &&
        (discard || (credits > 0 && pending.size < config.maxPendingEvents && pendingBytes < config.batchByteCap))
  }

  private val commands = LinkedBlockingQueue<Cmd>()
  private val gens = LinkedHashMap<Long, Gen>()
  private val waiting = HashMap<Long, ArrayDeque<Start>>()

  /** Streams cancelled before their start reached the pump (still in the session queue). */
  private val cancelledEarly = HashSet<Long>()
  private var stopped = false
  private val thread = Thread(::run, "sherpa-engine-pump").apply { isDaemon = true }

  /** Test hook: batches sent so far. */
  @Volatile var batchesSent = 0L
    private set

  fun startThread() = thread.start()

  fun start(s: Start) = commands.put(StartCmd(s))

  fun credit(streamId: Long, n: Int) = commands.put(CreditCmd(streamId, n))

  fun cancelStream(streamId: Long) = commands.put(CancelStreamCmd(streamId))

  /** Stops touching [session] (about to be freed): its streams fail, queued starts are refused. */
  fun release(session: Long): CompletableFuture<Unit> = CompletableFuture<Unit>().also { commands.put(ReleaseCmd(session, it)) }

  /** Cancels every generation and ends the thread. */
  fun stop(): CompletableFuture<Unit> = CompletableFuture<Unit>().also {
    if (!thread.isAlive) it.complete(Unit) else commands.put(StopCmd(it))
  }

  private fun run() {
    try {
      loop()
    } catch (t: Throwable) {
      // A pump bug must not leave streams hanging silently: fail them and keep the process alive for the
      // next connection (the Dart host sees StreamFailed, not a crash).
      for (g in gens.values) sink(StreamFailed(g.streamId, EngineError.INTERNAL.toLong(), "event pump failed: $t"))
      gens.clear()
    }
  }

  private fun loop() {
    while (!stopped) {
      while (true) handle(commands.poll() ?: break)
      if (stopped) break
      if (gens.isEmpty()) {
        handle(commands.take())
        continue
      }
      var drained = 0
      for (g in gens.values.toList()) if (g.canPoll) drained += drain(g, 0)
      flush()
      if (drained == 0) {
        val blocker = gens.values.firstOrNull { it.canPoll }
        if (blocker != null) {
          drain(blocker, config.pollTimeoutMs)
          flush()
        } else {
          // Every stream is out of credit or waiting for its coalescing window.
          commands.poll(config.pollTimeoutMs.toLong(), TimeUnit.MILLISECONDS)?.let(::handle)
          flush()
        }
      }
    }
  }

  private fun handle(c: Cmd) {
    when (c) {
      is StartCmd -> {
        val s = c.start
        if (cancelledEarly.remove(s.streamId)) {
          s.handled.complete(Unit)
        } else if (gens.values.any { it.session == s.session }) {
          waiting.getOrPut(s.session) { ArrayDeque() }.addLast(s)
          s.handled.complete(Unit)
        } else {
          begin(s)
        }
      }
      is CreditCmd -> gens[c.streamId]?.let { it.credits += c.n }
      is CancelStreamCmd -> {
        val g = gens[c.streamId]
        if (g != null) {
          g.discard = true
          g.pending.clear()
          g.pendingBytes = 0
          engine.cancel(g.session)
        } else {
          var found = false
          for (q in waiting.values) found = q.removeIf { it.streamId == c.streamId } || found
          if (!found) cancelledEarly.add(c.streamId)
        }
      }
      is ReleaseCmd -> {
        val dropped = gens.values.filter { it.session == c.session }
        for (g in dropped) {
          gens.remove(g.streamId)
          g.phase?.close()
          if (!g.discard && !g.finished) {
            sink(StreamFailed(g.streamId, EngineError.INVALID_ARG.toLong(), "session was freed during generation"))
          }
        }
        waiting.remove(c.session)?.forEach {
          sink(StreamFailed(it.streamId, EngineError.INVALID_ARG.toLong(), "session was freed"))
          it.handled.complete(Unit)
        }
        c.done.complete(Unit)
      }
      is StopCmd -> {
        stopped = true
        for (g in gens.values) {
          engine.cancel(g.session)
          g.phase?.close()
        }
        gens.clear()
        for (q in waiting.values) q.forEach { it.handled.complete(Unit) }
        waiting.clear()
        c.done.complete(Unit)
      }
    }
  }

  private fun begin(s: Start) {
    val generationId = try {
      engine.generateStart(s.session, s.requestJson)
    } catch (e: EngineError) {
      sink(StreamFailed(s.streamId, e.code.toLong(), e.message ?: ""))
      s.handled.complete(Unit)
      startNext(s.session)
      return
    }
    val phase = phases?.enter("generating", s.modelTag, s.nCtx, s.kv)
    gens[s.streamId] = Gen(s.streamId, s.session, generationId, phase)
    sink(StreamStarted(s.streamId, generationId))
    s.handled.complete(Unit)
  }

  private fun startNext(session: Long) {
    val q = waiting[session]
    val next = q?.pollFirst()
    if (q != null && q.isEmpty()) waiting.remove(session)
    if (next != null) begin(next)
  }

  private fun drain(g: Gen, timeoutMs: Int): Int {
    val events = try {
      engine.pollEvents(g.session, timeoutMs, config.maxPendingEvents)
    } catch (_: EngineError) {
      return 0
    }
    for (e in events) {
      if (e.generationId != g.generationId) continue // left over from a generation whose consumer is gone
      if (e.type == EventTypes.FINISH) g.finished = true
      if (g.discard || !EventTypes.known(e.type)) continue
      if (g.pending.isEmpty()) g.pendingSince = System.nanoTime()
      coalesce(g, e)
    }
    return events.size
  }

  /** EventCoalescer (engine_types.dart): lossless concatenation of adjacent deltas, latest prompt progress. */
  private fun coalesce(g: Gen, e: EngineEventMsg) {
    val last = g.pending.lastOrNull()
    if (last != null && last.event.type == e.type && last.event.generationId == e.generationId) {
      when (e.type) {
        EventTypes.TEXT_DELTA, EventTypes.REASONING_DELTA -> if (appendText(g, last, e)) return
        EventTypes.TOOL_CALL_ARGS_DELTA -> if (last.event.index == e.index && appendText(g, last, e)) return
        EventTypes.PROMPT_PROGRESS -> {
          last.event = e
          return
        }
      }
    }
    val size = sizeOf(e)
    g.pending.add(Pending(e, size))
    g.pendingBytes += size
  }

  /**
   * Appends a delta to the previous one unless that would push it past the byte cap: deltas are only ever
   * concatenated by consumers, so splitting a long run into several events is as lossless as merging.
   */
  private fun appendText(g: Gen, last: Pending, e: EngineEventMsg): Boolean {
    val add = utf8Length(e.text)
    if (last.bytes + add > config.batchByteCap) return false
    val b = last.text ?: StringBuilder(last.event.text).also { last.text = it }
    b.append(e.text)
    last.bytes += add
    g.pendingBytes += add
    return true
  }

  private fun flush() {
    val now = System.nanoTime()
    for (g in gens.values.toList()) {
      if (g.discard) {
        g.pending.clear()
        g.pendingBytes = 0
        if (g.finished) retire(g)
        continue
      }
      while (g.pending.isNotEmpty()) {
        val due = g.finished ||
          !g.sentAny ||
          g.pending.size >= config.maxPendingEvents ||
          g.pendingBytes >= config.batchByteCap ||
          now - g.pendingSince >= config.coalesceWindowMs * 1_000_000
        if (!due || g.credits <= 0) break
        sendChunk(g)
      }
      if (g.pending.isEmpty() && g.finished) retire(g)
    }
  }

  /** Sends the longest prefix of the pending events that fits the byte cap (at least one event). */
  private fun sendChunk(g: Gen) {
    var bytes = 0
    var n = 0
    while (n < g.pending.size) {
      val size = g.pending[n].bytes
      if (n > 0 && bytes + size > config.batchByteCap) break
      bytes += size
      n++
    }
    val chunk = g.pending.subList(0, n)
    val events = chunk.map { it.toMsg() }
    chunk.clear()
    g.pendingBytes = maxOf(0, g.pendingBytes - bytes)
    g.pendingSince = System.nanoTime()
    g.credits--
    g.sentAny = true
    val last = g.finished && g.pending.isEmpty()
    batchesSent++
    sink(EventBatch(g.streamId, events, last))
  }

  private fun retire(g: Gen) {
    gens.remove(g.streamId)
    g.phase?.close()
    startNext(g.session)
  }

  companion object {
    /** Approximate encoded size of one event in a batch (codec overhead + UTF-8 strings). */
    fun sizeOf(e: EngineEventMsg): Int = 160 + utf8Length(e.text) + utf8Length(e.id) + utf8Length(e.name)

    fun utf8Length(s: String): Int {
      var n = 0
      var i = 0
      while (i < s.length) {
        val c = s[i]
        n += when {
          c.code < 0x80 -> 1
          c.code < 0x800 -> 2
          Character.isHighSurrogate(c) && i + 1 < s.length -> {
            i++
            4
          }
          else -> 3
        }
        i++
      }
      return n
    }
  }
}
