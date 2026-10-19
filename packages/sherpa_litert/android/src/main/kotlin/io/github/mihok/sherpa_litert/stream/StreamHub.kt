package io.github.mihok.sherpa_litert.stream

import io.github.mihok.sherpa_litert.EventBatch
import io.github.mihok.sherpa_litert.EventKind
import io.github.mihok.sherpa_litert.LiteRtEvent
import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/** Runs work on the thread that may call the event sink (the platform main thread in the app). */
fun interface Poster {
  fun post(delayMs: Long, task: Runnable)
}

/** Flow-control knobs (see pigeons/litert_api.dart "Streaming"). */
data class HubConfig(
  /** Batches a stream may have in flight before Dart returns credits. Matches `kStreamCredits` in Dart. */
  val credits: Int = 4,
  /** Pending (undelivered) bytes per stream at which the producer thread blocks, which stops decoding. */
  val maxPendingBytes: Int = 64 * 1024,
  /** Deltas are coalesced for about one frame; a stream's first batch goes out at once (TTFT). */
  val coalesceMs: Long = 16,
  /** How long a blocked producer sleeps between checks for a cancel. */
  val blockPollMs: Long = 100,
)

/**
 * Per-stream bounded buffers between engine callback threads and the Dart event channel.
 *
 * - Producers ([Stream.push]) run on engine threads (LiteRT-LM's native callback thread, ML Kit's worker). Adjacent
 *   text/reasoning deltas are concatenated (lossless), download progress keeps only the latest value.
 * - Batches are handed to [sink] on the [Poster] thread. A stream holds at most [HubConfig.credits] batches in
 *   flight; Dart returns one credit per batch it delivered to its listener ([credit]). Without credits, events pile
 *   up in the pending buffer until it reaches [HubConfig.maxPendingBytes]; then [Stream.push] blocks the producer
 *   (the engine stops decoding) until Dart takes more or the stream is [discard]ed.
 * - Terminal events ([Stream.finish]) never block and ignore credits once nothing is pending before them, so a
 *   cancelled or failed stream always ends.
 * - Global events (stream 0) bypass flow control.
 */
class StreamHub(private val poster: Poster, private val config: HubConfig = HubConfig()) {
  private val lock = ReentrantLock()
  private val roomAvailable = lock.newCondition()
  private val streams = HashMap<Long, Stream>()

  /** Set while Dart listens (main thread). Events for a missing sink are dropped. */
  @Volatile var sink: ((EventBatch) -> Unit)? = null

  /** Test/diagnostic hook: batches handed to [sink]. */
  @Volatile var batchesSent: Long = 0
    private set

  inner class Stream internal constructor(val id: Long) {
    internal var credits = config.credits
    internal val pending = ArrayList<LiteRtEvent>()
    internal var pendingBytes = 0
    internal var sentAny = false
    internal var flushScheduled = false
    internal var discarded = false
    internal var terminal: LiteRtEvent? = null
    internal var closed = false

    /** Queues [event]; blocks while the buffer is full (backpressure). Dropped after [discard] or [finish]. */
    fun push(event: LiteRtEvent) {
      lock.withLock {
        while (!discarded && terminal == null && pendingBytes >= config.maxPendingBytes) {
          roomAvailable.await(config.blockPollMs, TimeUnit.MILLISECONDS)
        }
        if (discarded || terminal != null || closed) return
        coalesce(event)
        scheduleLocked(this)
      }
    }

    /** Ends the stream with [event] (done / cancelled / error); later calls are ignored. */
    fun finish(event: LiteRtEvent) {
      lock.withLock {
        if (terminal != null || closed) return
        terminal = event
        roomAvailable.signalAll()
        scheduleLocked(this, immediate = true)
      }
    }

    val isFinished: Boolean
      get() = lock.withLock { terminal != null || closed }

    private fun coalesce(e: LiteRtEvent) {
      val last = pending.lastOrNull()
      val text = e.text
      if (last != null && text != null && last.kind == e.kind &&
        (e.kind == EventKind.TEXT_DELTA || e.kind == EventKind.REASONING_DELTA)
      ) {
        pending[pending.size - 1] = last.copy(text = (last.text ?: "") + text)
        pendingBytes += text.length
        return
      }
      if (last != null && e.kind == EventKind.DOWNLOAD_PROGRESS && last.kind == EventKind.DOWNLOAD_PROGRESS) {
        pending[pending.size - 1] = e
        return
      }
      pending.add(e)
      pendingBytes += sizeOf(e)
    }
  }

  /** Opens (or returns) the buffer of [streamId]. */
  fun open(streamId: Long): Stream = lock.withLock { streams.getOrPut(streamId) { Stream(streamId) } }

  fun stream(streamId: Long): Stream? = lock.withLock { streams[streamId] }

  /** Dart delivered [batches] batches of [streamId]. */
  fun credit(streamId: Long, batches: Int) {
    lock.withLock {
      val s = streams[streamId] ?: return
      s.credits += batches
      scheduleLocked(s, immediate = true)
    }
  }

  /**
   * Drops whatever [streamId] has pending and unblocks its producer; the terminal event still follows. Called when
   * Dart cancels: the consumer no longer wants the text, only the end.
   */
  fun discard(streamId: Long) {
    lock.withLock {
      val s = streams[streamId] ?: return
      s.discarded = true
      s.pending.clear()
      s.pendingBytes = 0
      roomAvailable.signalAll()
      scheduleLocked(s, immediate = true)
    }
  }

  /** Sends a global event (stream 0) at once, outside flow control. */
  fun global(event: LiteRtEvent) {
    poster.post(0) {
      batchesSent++
      sink?.invoke(EventBatch(0, listOf(event)))
    }
  }

  /** Fails every open stream (engine detached) and forgets them. */
  fun failAll(make: (Long) -> LiteRtEvent) {
    val open = lock.withLock { streams.values.filter { it.terminal == null && !it.closed }.toList() }
    for (s in open) s.finish(make(s.id))
  }

  /** Streams still known (open or with undelivered events). */
  fun openStreams(): Int = lock.withLock { streams.size }

  private fun scheduleLocked(s: Stream, immediate: Boolean = false) {
    if (s.flushScheduled) return
    s.flushScheduled = true
    val delay = if (immediate || !s.sentAny) 0L else config.coalesceMs
    poster.post(delay) { flush(s) }
  }

  private fun flush(s: Stream) {
    val batch: EventBatch?
    lock.withLock {
      s.flushScheduled = false
      if (s.closed) return
      val events = ArrayList<LiteRtEvent>()
      if (s.pending.isNotEmpty() && s.credits > 0) {
        events.addAll(s.pending)
        s.pending.clear()
        s.pendingBytes = 0
        s.credits--
        roomAvailable.signalAll()
      }
      val terminal = s.terminal
      if (terminal != null && s.pending.isEmpty()) {
        events.add(terminal)
        s.closed = true
        streams.remove(s.id)
      }
      batch = if (events.isEmpty()) null else EventBatch(s.id, events)
      if (batch != null) s.sentAny = true
    }
    if (batch != null) {
      batchesSent++
      sink?.invoke(batch)
    }
  }

  private companion object {
    fun sizeOf(e: LiteRtEvent): Int {
      var n = 64 + (e.text?.length ?: 0) + (e.detail?.length ?: 0)
      e.toolCalls?.forEach { n += it.name.length + it.argumentsJson.length }
      return n
    }
  }
}
