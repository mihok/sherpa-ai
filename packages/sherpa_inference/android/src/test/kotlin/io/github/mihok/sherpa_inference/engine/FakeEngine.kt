package io.github.mihok.sherpa_inference.engine

import io.github.mihok.sherpa_inference.BenchConfigMsg
import io.github.mihok.sherpa_inference.BenchResultMsg
import io.github.mihok.sherpa_inference.EngineEventMsg
import io.github.mihok.sherpa_inference.MemoryEstimateMsg
import io.github.mihok.sherpa_inference.ModelOptionsMsg
import io.github.mihok.sherpa_inference.SessionConfigMsg
import java.util.ArrayDeque
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

/**
 * An [Engine] with the engine's concurrency semantics, for dispatcher tests: one generation per session
 * on its own worker thread, a bounded event ring that BLOCKS the worker when full (backpressure), cancel
 * observed between tokens, SE_ERR_BUSY for session calls while generating, single-consumer polling.
 */
class FakeEngine(
  private val ringCapacity: Int = 8,
  private val tokenDelayMs: Long = 0,
  /** Builds the deltas of a generation from its request JSON. */
  var script: (String) -> List<String> = { listOf("Hel", "lo", " world", "!") },
) : Engine {
  private val next = AtomicLong(0x1000)
  val calls: MutableList<String> = Collections.synchronizedList(ArrayList())
  val freed: MutableList<Long> = Collections.synchronizedList(ArrayList())
  val cancellers = HashMap<Long, Boolean>()

  /** Hooks to make calls block (ordering / deferred-free / cancel tests). */
  @Volatile var onSessionCall: (String) -> Unit = {}
  @Volatile var onTokenize: () -> Unit = {}
  @Volatile var loadBlocksUntilCancelled = false

  inner class Session(val ptr: Long) {
    val lock = Object()
    val ring = ArrayDeque<EngineEventMsg>()
    var busy = false
    var cancelled = false
    var generation = 0L
    var worker: Thread? = null
    @Volatile var blockedOnFullRing = false
    @Volatile var maxRing = 0
    @Volatile var blockedMs = 0L
  }

  val sessions = HashMap<Long, Session>()

  private fun session(ptr: Long): Session = synchronized(sessions) { sessions[ptr] } ?: throw EngineError(EngineError.INVALID_ARG, "bad session")

  override fun open(library: String) {
    calls.add("open")
    if (library == "missing") throw EngineError(EngineError.UNSUPPORTED, "dlopen(missing) failed")
  }

  override fun abiVersion() = 1

  override fun versionString() = "fake 1.0"

  override fun backendInit(breadcrumbPath: String?, backendDir: String?) {
    calls.add("backendInit:$breadcrumbPath")
  }

  override fun systemInfoJson() = """{"backends":["CPU"]}"""

  override fun cancellerCreate(): Long = next.incrementAndGet().also { synchronized(cancellers) { cancellers[it] = false } }

  override fun cancellerCancel(canceller: Long) {
    synchronized(cancellers) {
      cancellers[canceller] = true
      (cancellers as Object).notifyAll()
    }
  }

  override fun cancellerFree(canceller: Long) {
    synchronized(cancellers) { cancellers.remove(canceller) }
  }

  override fun modelLoad(options: ModelOptionsMsg, canceller: Long, progress: ProgressSink?): Long {
    calls.add("modelLoad:${options.path}")
    for (p in listOf(0.0f, 0.25f, 0.5f, 1.0f)) progress?.onProgress(p)
    if (loadBlocksUntilCancelled) {
      val deadline = System.currentTimeMillis() + 5000
      synchronized(cancellers) {
        while (cancellers[canceller] != true && System.currentTimeMillis() < deadline) (cancellers as Object).wait(50)
        if (cancellers[canceller] == true) throw EngineError(EngineError.CANCELLED, "model load cancelled")
      }
    }
    if (options.path.endsWith("missing.gguf")) throw EngineError(-3, "no such file")
    return next.incrementAndGet()
  }

  override fun modelFree(model: Long) {
    calls.add("modelFree")
    freed.add(model)
  }

  override fun modelInfoJson(model: Long) = """{"arch":"fake"}"""

  override fun tokenize(model: Long, text: String, addSpecial: Boolean, parseSpecial: Boolean): IntArray {
    calls.add("tokenize")
    onTokenize()
    return IntArray(text.length) { it }
  }

  override fun countText(model: Long, text: String) = if (text == "bad") -1 else text.length

  override fun detokenize(model: Long, tokens: IntArray, renderSpecial: Boolean) = "x".repeat(tokens.size)

  override fun countChat(model: Long, requestJson: String): Int {
    val n = countChatOrStatus(model, requestJson)
    if (n < 0) throw EngineError(n, "bad request")
    return n
  }

  override fun countChatOrStatus(model: Long, requestJson: String) = if (requestJson.startsWith("{")) requestJson.length else -1

  override fun estimateMemory(options: ModelOptionsMsg, config: SessionConfigMsg) =
    MemoryEstimateMsg(config.nCtx, config.nCtx, false, 1, 1, 2, 3, 4, 10, 5, 6)

  override fun sessionCreate(model: Long, config: SessionConfigMsg): Long {
    val ptr = next.incrementAndGet()
    synchronized(sessions) { sessions[ptr] = Session(ptr) }
    return ptr
  }

  override fun sessionFree(session: Long) {
    calls.add("sessionFree")
    val s = synchronized(sessions) { sessions.remove(session) } ?: return
    synchronized(s.lock) {
      s.cancelled = true
      s.lock.notifyAll()
    }
    s.worker?.join(2000)
    freed.add(session)
  }

  private fun sessionOp(name: String, session: Long) {
    val s = session(session)
    calls.add("$name@${Thread.currentThread().name}")
    onSessionCall(name)
    synchronized(s.lock) { if (s.busy) throw EngineError(EngineError.BUSY, "generating") }
  }

  override fun sessionReset(session: Long) = sessionOp("reset", session)

  override fun sessionSetThreads(session: Long, nThreads: Int, nThreadsBatch: Int) = sessionOp("setThreads:$nThreads", session)

  override fun sessionInfoJson(session: Long): String {
    calls.add("sessionInfo")
    onSessionCall("sessionInfo")
    return """{"n_ctx":4096,"type_k":"f16","type_v":"q8_0"}"""
  }

  override fun sessionMemory(session: Long) = MemoryEstimateMsg(4096, 4096, true, 1, 1, 2, 3, 4, 10, 5, 6)

  override fun generateStart(session: Long, requestJson: String): Long {
    val s = session(session)
    val deltas = script(requestJson)
    synchronized(s.lock) {
      if (s.busy) throw EngineError(EngineError.BUSY, "a generation is running")
      if (!requestJson.startsWith("{")) throw EngineError(EngineError.INVALID_ARG, "malformed JSON")
      s.busy = true
      s.cancelled = false
      s.generation++
    }
    val gen = s.generation
    calls.add("generate")
    s.worker = Thread({ work(s, gen, deltas) }, "fake-worker").apply {
      isDaemon = true
      start()
    }
    return gen
  }

  private fun put(s: Session, e: EngineEventMsg) {
    synchronized(s.lock) {
      val t0 = System.nanoTime()
      while (s.ring.size >= ringCapacity) {
        s.blockedOnFullRing = true
        s.lock.wait(50)
        if (!synchronized(sessions) { sessions.containsKey(s.ptr) }) return
      }
      s.blockedMs += (System.nanoTime() - t0) / 1_000_000
      s.blockedOnFullRing = false
      s.ring.addLast(e)
      s.maxRing = maxOf(s.maxRing, s.ring.size)
      s.lock.notifyAll()
    }
  }

  private fun work(s: Session, gen: Long, deltas: List<String>) {
    var produced = 0
    var cancelled = false
    for (d in deltas) {
      if (tokenDelayMs > 0) Thread.sleep(tokenDelayMs)
      if (synchronized(s.lock) { s.cancelled }) {
        cancelled = true
        break
      }
      put(s, ev(EventTypes.TEXT_DELTA, gen, text = d))
      produced++
    }
    put(s, ev(EventTypes.USAGE, gen, completion = produced.toLong()))
    put(s, ev(EventTypes.PERF, gen, name = "CPU"))
    put(s, ev(EventTypes.FINISH, gen, code = if (cancelled) 4 else 1, name = if (cancelled) "cancelled" else "stop"))
    synchronized(s.lock) {
      s.busy = false
      s.lock.notifyAll()
    }
  }

  override fun pollEvents(session: Long, timeoutMs: Int, maxEvents: Int): List<EngineEventMsg> {
    val s = session(session)
    synchronized(s.lock) {
      if (s.ring.isEmpty() && timeoutMs > 0) s.lock.wait(timeoutMs.toLong())
      val out = ArrayList<EngineEventMsg>()
      while (s.ring.isNotEmpty() && (maxEvents <= 0 || out.size < maxEvents)) out.add(s.ring.removeFirst())
      if (out.isNotEmpty()) s.lock.notifyAll()
      return out
    }
  }

  override fun cancel(session: Long) {
    val s = synchronized(sessions) { sessions[session] } ?: return
    synchronized(s.lock) {
      s.cancelled = true
      s.lock.notifyAll()
    }
  }

  override fun waitIdle(session: Long, timeoutMs: Int): Int {
    val s = session(session)
    val deadline = System.currentTimeMillis() + timeoutMs
    synchronized(s.lock) {
      while (s.busy) {
        val left = deadline - System.currentTimeMillis()
        if (left <= 0) return EngineError.TIMEOUT
        s.lock.wait(left)
      }
    }
    return 0
  }

  override fun stateSave(session: Long, path: String) {
    sessionOp("stateSave", session)
    java.io.File(path).writeBytes(ByteArray(1234))
  }

  override fun stateLoad(session: Long, path: String): Int {
    sessionOp("stateLoad", session)
    return 42
  }

  override fun loraLoad(model: Long, path: String) = next.incrementAndGet()

  override fun loraFree(lora: Long) {
    freed.add(lora)
  }

  override fun setLoras(session: Long, loras: LongArray, scales: FloatArray) {
    sessionOp("setLoras:${loras.size}", session)
  }

  override fun bench(model: Long, config: BenchConfigMsg, canceller: Long) =
    BenchResultMsg(config.nPrompt, config.nGen, config.nThreads, 100.0, 20.0, 1.0, 2.0)

  override fun debugCrash(mode: Int) {
    calls.add("debugCrash:$mode")
  }

  fun awaitBlocked(session: Long, timeoutMs: Long = 3000): Boolean {
    val s = session(session)
    val deadline = System.currentTimeMillis() + timeoutMs
    while (System.currentTimeMillis() < deadline) {
      if (s.blockedOnFullRing) return true
      Thread.sleep(5)
    }
    return false
  }

  companion object {
    fun ev(type: Long, gen: Long, text: String = "", code: Long = 0, name: String = "", completion: Long = 0, index: Long = -1) =
      EngineEventMsg(
        type = type, generationId = gen, index = index, code = code, text = text, id = "", name = name,
        promptTokens = 0, cachedTokens = 0, completionTokens = completion, nDrafted = 0, nAccepted = 0,
        progressDone = 0, progressTotal = 0, ttftMs = 0.0, prefillTps = 0.0, decodeTps = 0.0, draftAcceptRate = 0.0,
        prefillMs = 0.0, decodeMs = 0.0,
      )
  }
}

/** Latch helper. */
fun CountDownLatch.awaitOrFail(ms: Long = 5000) {
  if (!await(ms, TimeUnit.MILLISECONDS)) throw AssertionError("timed out")
}
