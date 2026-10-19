package io.github.mihok.sherpa_inference.engine

import io.github.mihok.sherpa_inference.BenchConfigMsg
import io.github.mihok.sherpa_inference.BenchResultMsg
import io.github.mihok.sherpa_inference.EngineEventMsg
import io.github.mihok.sherpa_inference.MemoryEstimateMsg
import io.github.mihok.sherpa_inference.ModelOptionsMsg
import io.github.mihok.sherpa_inference.SessionConfigMsg

/**
 * The sherpa_engine C ABI as seen by [EngineCore]: native pointers in, Kotlin values out, failures as
 * [EngineError]. [JniEngine] is the real one; unit tests use a fake. Thread rules are the header's
 * ("Threading"): model handles are shareable, one generation per session, [pollEvents] has a single
 * consumer (the pump thread), [cancel] / [cancellerCancel] are thread-safe.
 */
interface Engine {
  /** dlopen + ABI check; throws [EngineError] (SE_ERR_UNSUPPORTED) with the reason. Idempotent. */
  fun open(library: String)

  fun abiVersion(): Int

  fun versionString(): String

  fun backendInit(breadcrumbPath: String?, backendDir: String?)

  fun systemInfoJson(): String

  fun cancellerCreate(): Long

  fun cancellerCancel(canceller: Long)

  fun cancellerFree(canceller: Long)

  fun modelLoad(options: ModelOptionsMsg, canceller: Long, progress: ProgressSink?): Long

  fun modelFree(model: Long)

  fun modelInfoJson(model: Long): String

  fun tokenize(model: Long, text: String, addSpecial: Boolean, parseSpecial: Boolean): IntArray

  /** Token count or a negative status. */
  fun countText(model: Long, text: String): Int

  fun detokenize(model: Long, tokens: IntArray, renderSpecial: Boolean): String

  /** Prompt tokens of a chat request; throws on error. */
  fun countChat(model: Long, requestJson: String): Int

  /** Prompt tokens or a negative status. */
  fun countChatOrStatus(model: Long, requestJson: String): Int

  fun estimateMemory(options: ModelOptionsMsg, config: SessionConfigMsg): MemoryEstimateMsg

  fun sessionCreate(model: Long, config: SessionConfigMsg): Long

  fun sessionFree(session: Long)

  fun sessionReset(session: Long)

  fun sessionSetThreads(session: Long, nThreads: Int, nThreadsBatch: Int)

  fun sessionInfoJson(session: Long): String

  fun sessionMemory(session: Long): MemoryEstimateMsg

  /** The generation id. Throws SE_ERR_BUSY / SE_ERR_INVALID_ARG like `se_generate_start`. */
  fun generateStart(session: Long, requestJson: String): Long

  /** Up to [maxEvents] events, blocking up to [timeoutMs] when none are queued; empty when none. */
  fun pollEvents(session: Long, timeoutMs: Int, maxEvents: Int): List<EngineEventMsg>

  fun cancel(session: Long)

  /** `se_wait`: 0 (idle) or SE_ERR_TIMEOUT. */
  fun waitIdle(session: Long, timeoutMs: Int): Int

  fun stateSave(session: Long, path: String)

  fun stateLoad(session: Long, path: String): Int

  fun loraLoad(model: Long, path: String): Long

  fun loraFree(lora: Long)

  fun setLoras(session: Long, loras: LongArray, scales: FloatArray)

  fun bench(model: Long, config: BenchConfigMsg, canceller: Long): BenchResultMsg

  /** Debug only: 0 abort, 1 SIGSEGV, 2 _exit. */
  fun debugCrash(mode: Int)
}

/** [Engine] over the JNI shim. Call [NativeEngine.load] first. */
class JniEngine : Engine {
  override fun open(library: String) {
    val why = NativeEngine.open(utf8(library))
    if (why != null) throw EngineError(EngineError.UNSUPPORTED, why)
  }

  override fun abiVersion(): Int = NativeEngine.abiVersion()

  override fun versionString(): String = text(NativeEngine.versionString())

  override fun backendInit(breadcrumbPath: String?, backendDir: String?) =
    NativeEngine.backendInit(breadcrumbPath?.let(::utf8), backendDir?.let(::utf8), 0)

  override fun systemInfoJson(): String = text(NativeEngine.systemInfoJson())

  override fun cancellerCreate(): Long = NativeEngine.cancellerCreate()

  override fun cancellerCancel(canceller: Long) = NativeEngine.cancellerCancel(canceller)

  override fun cancellerFree(canceller: Long) = NativeEngine.cancellerFree(canceller)

  override fun modelLoad(options: ModelOptionsMsg, canceller: Long, progress: ProgressSink?): Long =
    NativeEngine.modelLoad(utf8(options.path), modelInts(options), modelStrs(options), canceller, progress)

  override fun modelFree(model: Long) = NativeEngine.modelFree(model)

  override fun modelInfoJson(model: Long): String = text(NativeEngine.modelInfoJson(model))

  override fun tokenize(model: Long, text: String, addSpecial: Boolean, parseSpecial: Boolean): IntArray =
    NativeEngine.tokenize(model, utf8(text), addSpecial, parseSpecial)

  override fun countText(model: Long, text: String): Int = NativeEngine.countText(model, utf8(text))

  override fun detokenize(model: Long, tokens: IntArray, renderSpecial: Boolean): String =
    text(NativeEngine.detokenize(model, tokens, renderSpecial))

  override fun countChat(model: Long, requestJson: String): Int = NativeEngine.countChat(model, utf8(requestJson), true)

  override fun countChatOrStatus(model: Long, requestJson: String): Int =
    NativeEngine.countChat(model, utf8(requestJson), false)

  override fun estimateMemory(options: ModelOptionsMsg, config: SessionConfigMsg): MemoryEstimateMsg =
    estimate(NativeEngine.estimateMemory(utf8(options.path), modelInts(options), modelStrs(options), sessionInts(config)))

  override fun sessionCreate(model: Long, config: SessionConfigMsg): Long =
    NativeEngine.sessionCreate(model, sessionInts(config))

  override fun sessionFree(session: Long) = NativeEngine.sessionFree(session)

  override fun sessionReset(session: Long) = NativeEngine.sessionReset(session)

  override fun sessionSetThreads(session: Long, nThreads: Int, nThreadsBatch: Int) =
    NativeEngine.sessionSetThreads(session, nThreads, nThreadsBatch)

  override fun sessionInfoJson(session: Long): String = text(NativeEngine.sessionInfoJson(session))

  override fun sessionMemory(session: Long): MemoryEstimateMsg = estimate(NativeEngine.sessionMemory(session))

  override fun generateStart(session: Long, requestJson: String): Long =
    NativeEngine.generateStart(session, utf8(requestJson))

  override fun pollEvents(session: Long, timeoutMs: Int, maxEvents: Int): List<EngineEventMsg> {
    val packed = NativeEngine.pollEvents(session, timeoutMs, maxEvents) ?: return emptyList()
    return PackedEvents.decode(packed)
  }

  override fun cancel(session: Long) = NativeEngine.cancel(session)

  override fun waitIdle(session: Long, timeoutMs: Int): Int = NativeEngine.waitIdle(session, timeoutMs)

  override fun stateSave(session: Long, path: String) = NativeEngine.stateSave(session, utf8(path))

  override fun stateLoad(session: Long, path: String): Int = NativeEngine.stateLoad(session, utf8(path))

  override fun loraLoad(model: Long, path: String): Long = NativeEngine.loraLoad(model, utf8(path))

  override fun loraFree(lora: Long) = NativeEngine.loraFree(lora)

  override fun setLoras(session: Long, loras: LongArray, scales: FloatArray) =
    NativeEngine.setLoras(session, loras, scales)

  override fun bench(model: Long, config: BenchConfigMsg, canceller: Long): BenchResultMsg {
    val r = NativeEngine.bench(model, benchInts(config), canceller)
    return BenchResultMsg(
      nPrompt = r[0].toLong(),
      nGen = r[1].toLong(),
      nThreads = r[2].toLong(),
      promptTokensPerSec = r[3],
      genTokensPerSec = r[4],
      promptMs = r[5],
      genMs = r[6],
    )
  }

  override fun debugCrash(mode: Int) = NativeEngine.debugCrash(mode)

  companion object {
    private fun utf8(s: String): ByteArray = s.toByteArray(Charsets.UTF_8)

    private fun text(b: ByteArray): String = String(b, Charsets.UTF_8)

    /** Order fixed by sherpa_jni.c (MODEL_INTS). */
    fun modelInts(o: ModelOptionsMsg): IntArray = intArrayOf(
      o.nGpuLayers.toInt(),
      o.loadMode.toInt(),
      if (o.useExtraBuffers) 1 else 0,
      if (o.vocabOnly) 1 else 0,
      if (o.loadMtp) 1 else 0,
    )

    /** Order fixed by sherpa_jni.c (MODEL_STRS). */
    fun modelStrs(o: ModelOptionsMsg): Array<ByteArray?> = arrayOf(
      o.chatTemplateOverride?.let(::utf8),
      o.modelId?.let(::utf8),
      o.mmprojPath?.let(::utf8),
      o.draftModelPath?.let(::utf8),
    )

    /** Order fixed by sherpa_jni.c (SESSION_INTS). `seed` is uint32: its low 32 bits are passed. */
    fun sessionInts(c: SessionConfigMsg): IntArray = intArrayOf(
      c.nCtx.toInt(),
      c.nBatch.toInt(),
      c.nUbatch.toInt(),
      c.nThreads.toInt(),
      c.nThreadsBatch.toInt(),
      c.typeK.toInt(),
      c.typeV.toInt(),
      c.flashAttention.toInt(),
      c.nOutputsMax.toInt(),
      c.swaFull.toInt(),
      c.seed.toInt(),
      c.speculative.toInt(),
      c.specMaxDraft.toInt(),
      c.eventCapacity.toInt(),
    )

    /** Order fixed by sherpa_jni.c (BENCH_INTS). */
    fun benchInts(c: BenchConfigMsg): IntArray = intArrayOf(
      c.nThreads.toInt(),
      c.nThreadsBatch.toInt(),
      c.nBatch.toInt(),
      c.nUbatch.toInt(),
      c.nCtx.toInt(),
      c.nPrompt.toInt(),
      c.nGen.toInt(),
      c.nReps.toInt(),
      c.typeK.toInt(),
      c.typeV.toInt(),
      c.flashAttention.toInt(),
    )

    fun estimate(v: LongArray): MemoryEstimateMsg = MemoryEstimateMsg(
      nCtx = v[0],
      nCtxSeq = v[1],
      flashAttention = v[2] == 1L,
      modelBytes = v[3],
      modelMappedBytes = v[4],
      kvBytes = v[5],
      computeBytes = v[6],
      outputBytes = v[7],
      totalBytes = v[8],
      kvBytesPerToken = v[9],
      fileBytes = v[10],
    )
  }
}
