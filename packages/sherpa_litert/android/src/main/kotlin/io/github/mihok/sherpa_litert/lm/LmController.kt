package io.github.mihok.sherpa_litert.lm

import io.github.mihok.sherpa_litert.GenerationStatsMsg
import io.github.mihok.sherpa_litert.LiteRtEvent
import io.github.mihok.sherpa_litert.ToolCallMsg
import io.github.mihok.sherpa_litert.stream.Events
import io.github.mihok.sherpa_litert.stream.StreamHub
import java.util.concurrent.Executor

/** What Dart asked to load; equal requests reuse the loaded engine. */
data class LmLoadRequest(
  val path: String,
  /** Tried in order; the first that initializes wins (Dart picks the order, e.g. npu, gpu, cpu). */
  val backends: List<String>,
  val maxNumTokens: Int? = null,
  val cpuThreads: Int? = null,
  val cacheDir: String? = null,
  val vision: Boolean = false,
  val audio: Boolean = false,
  val benchmark: Boolean = true,
)

data class LmLoadResult(
  val backend: String,
  val failures: List<String>,
  val initMs: Double,
  val reused: Boolean,
  val rendersTools: Boolean? = null,
)

/** Every backend failed; [failures] is `backend: message` per attempt, [code] the last native status. */
class LmLoadFailedException(val failures: List<String>, val code: Int) :
  RuntimeException("no backend could load the model: ${failures.joinToString("; ")}")

/**
 * Owns THE LiteRT-LM engine (at most one: weights are GBs), its conversations and the running turn.
 *
 * Threading: every public method must run on [engineThread], a dedicated single-thread executor (the plugin
 * guarantees it; tests call from one thread). Engine callbacks arrive on LiteRT-LM's native thread: deltas go
 * straight into the turn's [StreamHub.Stream] (which may block that thread: backpressure), terminal callbacks hop
 * back to [engineThread] so stats, the end of the turn and a deferred release are serialized with everything else.
 *
 * No policy here: Dart decides the backend order, when to (re)build a conversation and the trim threshold.
 */
class LmController(
  private val runtime: LmRuntime,
  private val hub: StreamHub,
  private val engineThread: Executor,
  private val nativeLibraryDir: String,
) {
  private class Loaded(val request: LmLoadRequest, val engine: LmEngine, val backend: String, val rendersTools: Boolean?)

  private inner class Turn(
    val streamId: Long,
    val conversationId: String,
    val conversation: LmConversation,
    val stream: StreamHub.Stream,
    val kvBefore: Int?,
  ) {
    @Volatile var cancelReason: String? = null
    var ended = false
    val startNs = System.nanoTime()

    /** First delta of this turn. Measured here: BenchmarkInfo's TTFT is the conversation's first turn only
     * (observed on the host run: identical across later turns). */
    @Volatile var firstOutputNs = 0L

    fun sawOutput() {
      if (firstOutputNs == 0L) firstOutputNs = System.nanoTime()
    }
  }

  private var loaded: Loaded? = null
  private val conversations = LinkedHashMap<String, LmConversation>()
  private var turn: Turn? = null
  private var releaseAfterTurn: String? = null

  val isGenerating: Boolean
    get() = turn != null

  val loadedBackend: String?
    get() = loaded?.backend

  val conversationIds: Set<String>
    get() = conversations.keys.toSet()

  fun inspect(path: String): LmModelInfo = runtime.inspect(path)

  fun load(request: LmLoadRequest): LmLoadResult {
    loaded?.let {
      if (it.request == request) return LmLoadResult(it.backend, emptyList(), 0.0, reused = true, rendersTools = it.rendersTools)
    }
    if (turn != null) throw LmStatusException(9, "cannot load a model while a reply is being generated")
    closeAll("reload")
    val failures = ArrayList<String>()
    var lastCode = -1
    for (backend in request.backends) {
      val start = System.nanoTime()
      try {
        val engine = runtime.createEngine(
          LmEngineConfig(
            path = request.path,
            backend = backend,
            maxNumTokens = request.maxNumTokens,
            cpuThreads = request.cpuThreads,
            cacheDir = request.cacheDir,
            vision = request.vision,
            audio = request.audio,
            nativeLibraryDir = nativeLibraryDir,
            benchmark = request.benchmark,
          ),
        )
        val initMs = (System.nanoTime() - start) / 1e6
        val rendersTools = runCatching { engine.rendersTools() }.getOrNull()
        loaded = Loaded(request, engine, backend, rendersTools)
        return LmLoadResult(backend, failures, initMs, reused = false, rendersTools = rendersTools)
      } catch (e: LmStatusException) {
        failures += "$backend: ${e.message}"
        lastCode = e.code
      } catch (t: Throwable) {
        // UnsatisfiedLinkError (no GPU/NPU libraries), OutOfMemoryError on the Java side, ...
        failures += "$backend: ${t.message ?: t}"
      }
    }
    throw LmLoadFailedException(failures, lastCode)
  }

  /** Closes the engine; a running turn is stopped first and the release happens when it has ended. */
  fun release(reason: String) {
    val t = turn
    if (t != null) {
      releaseAfterTurn = reason
      cancel(t.streamId, reason)
      return
    }
    closeAll(reason)
  }

  /** `onTrimMemory`: at or above [threshold] (0 = never) stop at a token boundary and free the engine. */
  fun onTrimMemory(level: Int, threshold: Int) {
    if (threshold <= 0 || level < threshold) return
    if (loaded == null && conversations.isEmpty()) return
    release(REASON_MEMORY)
  }

  fun openConversation(spec: LmConversationSpec) {
    val engine = loaded?.engine ?: throw LmStatusException(9, "no model is loaded")
    if (turn?.conversationId == spec.id) throw LmStatusException(9, "conversation '${spec.id}' is generating")
    conversations.remove(spec.id)?.let { runCatching { it.close() } }
    conversations[spec.id] = engine.createConversation(spec)
  }

  fun closeConversation(id: String) {
    if (turn?.conversationId == id) throw LmStatusException(9, "conversation '$id' is generating")
    conversations.remove(id)?.let { runCatching { it.close() } }
  }

  fun send(streamId: Long, conversationId: String, message: LmMessage, options: LmSendOptions) {
    val stream = hub.open(streamId)
    val conversation = conversations[conversationId]
    if (conversation == null) {
      stream.finish(Events.error("state", 9, "no open conversation '$conversationId'"))
      return
    }
    if (turn != null) {
      stream.finish(Events.error("state", 9, "another reply is being generated"))
      return
    }
    val t = Turn(streamId, conversationId, conversation, stream, conversation.tokenCount())
    turn = t
    try {
      conversation.send(message, options, callbackFor(t))
    } catch (e: Throwable) {
      end(t, errorEvent(e))
    }
  }

  /** Stops [streamId] at the next token. False when it is not the running turn. */
  fun cancel(streamId: Long, reason: String): Boolean {
    val t = turn
    if (t == null || t.streamId != streamId) return false
    if (t.cancelReason == null) t.cancelReason = reason
    hub.discard(streamId)
    try {
      t.conversation.cancel()
    } catch (e: Throwable) {
      end(t, Events.cancelled(t.cancelReason ?: reason))
    }
    return true
  }

  private fun callbackFor(t: Turn) = object : LmCallback {
    override fun onText(delta: String) {
      t.sawOutput()
      if (t.cancelReason == null) t.stream.push(Events.text(delta))
    }

    override fun onThought(delta: String) {
      t.sawOutput()
      if (t.cancelReason == null) t.stream.push(Events.reasoning(delta))
    }

    override fun onToolCalls(calls: List<LmToolCall>) {
      t.sawOutput()
      if (t.cancelReason == null) t.stream.push(Events.toolCalls(calls.map { ToolCallMsg(it.name, it.argumentsJson) }))
    }

    override fun onDone() = engineThread.execute { end(t, Events.done(stats(t))) }

    override fun onCancelled() = engineThread.execute { end(t, Events.cancelled(t.cancelReason ?: "cancelled")) }

    override fun onError(error: Throwable) = engineThread.execute {
      val reason = t.cancelReason
      // A cancel can surface as a CANCELLED status (absl code 1) rather than onCancelled.
      val cancelled = reason != null && (error as? LmStatusException)?.code == 1
      end(t, if (cancelled) Events.cancelled(reason) else errorEvent(error))
    }
  }

  private fun stats(t: Turn): GenerationStatsMsg {
    val b = runCatching { t.conversation.benchmark() }.getOrNull()
    return GenerationStatsMsg(
      prefillTokens = b?.prefillTokens?.toLong(),
      decodeTokens = b?.decodeTokens?.toLong(),
      timeToFirstTokenMs = if (t.firstOutputNs > 0) (t.firstOutputNs - t.startNs) / 1e6 else null,
      prefillTokensPerSec = b?.prefillTokensPerSec,
      decodeTokensPerSec = b?.decodeTokensPerSec,
      kvTokensBefore = t.kvBefore?.toLong(),
      kvTokensAfter = runCatching { t.conversation.tokenCount() }.getOrNull()?.toLong(),
      backend = loaded?.backend,
    )
  }

  private fun end(t: Turn, terminal: LiteRtEvent) {
    if (t.ended) return
    t.ended = true
    if (turn === t) turn = null
    t.stream.finish(terminal)
    val release = releaseAfterTurn
    if (release != null) {
      releaseAfterTurn = null
      closeAll(release)
    }
  }

  private fun closeAll(reason: String) {
    val had = loaded != null || conversations.isNotEmpty()
    for (c in conversations.values) runCatching { c.close() }
    conversations.clear()
    loaded?.let { runCatching { it.engine.close() } }
    loaded = null
    if (had) hub.global(Events.engineReleased(reason))
  }

  companion object {
    const val REASON_MEMORY = "memory_pressure"

    fun errorEvent(e: Throwable): LiteRtEvent = when (e) {
      is LmStatusException -> Events.error("litert", e.code.toLong(), e.message ?: "native error")
      is LmLoadFailedException -> Events.error("litert", e.code.toLong(), e.message ?: "load failed")
      is IllegalStateException -> Events.error("state", -1, e.message ?: e.toString())
      is IllegalArgumentException -> Events.error("argument", -1, e.message ?: e.toString())
      is java.io.IOException -> Events.error("io", -1, e.message ?: e.toString())
      else -> Events.error("host", -1, e.message ?: e.toString())
    }
  }
}
