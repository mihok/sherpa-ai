package io.github.mihok.sherpa_inference.engine

import android.annotation.SuppressLint

/**
 * A failed engine call: an `se_status` (negative) and `se_last_error()`. Thrown by the JNI shim
 * (src/main/cpp/sherpa_jni.c), which passes the message as UTF-8 bytes (never modified UTF-8).
 */
class EngineError(val code: Int, message: String) : Exception(message) {
  constructor(code: Int, utf8: ByteArray) : this(code, String(utf8, Charsets.UTF_8))

  companion object {
    const val INVALID_ARG = -1
    const val OOM = -2
    const val CANCELLED = -7
    const val BUSY = -13
    const val UNSUPPORTED = -14
    const val TIMEOUT = -16
    const val INTERNAL = -99
  }
}

/** Load progress from the loading thread; return false to cancel the load. */
fun interface ProgressSink {
  fun onProgress(progress: Float): Boolean
}

/**
 * The JNI shim's entry points (registered by `JNI_OnLoad`). Raw and unchecked: use [JniEngine]. Pointers are
 * engine handles and never leave the `:inference` process ([EngineCore] maps them to opaque ids).
 *
 * Array layouts are fixed by sherpa_jni.c: model options `ints` = n_gpu_layers, load_mode,
 * use_extra_bufts, vocab_only, load_mtp and `strs` = chat_template_override, model_id, mmproj_path,
 * draft_model_path; session `ints` = the 14 SessionConfig fields in [JniEngine.sessionInts] order; bench
 * `ints` in [JniEngine.benchInts] order; memory estimates as 11 longs; bench results as 7 doubles.
 */
@Suppress("FunctionName")
object NativeEngine {
  /** Loads the shim into this process: the APK's copy by name, or [path] (host JVM tests only). */
  @SuppressLint("UnsafeDynamicallyLoadedCode")
  @JvmStatic
  fun load(path: String? = null) {
    if (path != null) System.load(path) else System.loadLibrary("sherpa_inference_jni")
  }

  /** dlopen + dlsym + ABI check. Null on success, else why (UTF-8). Idempotent. */
  @JvmStatic external fun open(library: ByteArray): ByteArray?

  @JvmStatic external fun abiVersion(): Int

  @JvmStatic external fun versionString(): ByteArray

  @JvmStatic external fun backendInit(breadcrumb: ByteArray?, backendDir: ByteArray?, logLevel: Int)

  @JvmStatic external fun systemInfoJson(): ByteArray

  @JvmStatic external fun cancellerCreate(): Long

  @JvmStatic external fun cancellerCancel(canceller: Long)

  @JvmStatic external fun cancellerFree(canceller: Long)

  @JvmStatic external fun modelLoad(
    path: ByteArray,
    ints: IntArray,
    strs: Array<ByteArray?>,
    canceller: Long,
    progress: ProgressSink?,
  ): Long

  @JvmStatic external fun modelFree(model: Long)

  @JvmStatic external fun modelInfoJson(model: Long): ByteArray

  @JvmStatic external fun tokenize(model: Long, text: ByteArray, addSpecial: Boolean, parseSpecial: Boolean): IntArray

  /** Count or a negative status (never throws for engine errors). */
  @JvmStatic external fun countText(model: Long, text: ByteArray): Int

  @JvmStatic external fun detokenize(model: Long, tokens: IntArray, renderSpecial: Boolean): ByteArray

  @JvmStatic external fun countChat(model: Long, json: ByteArray, throwOnError: Boolean): Int

  @JvmStatic external fun estimateMemory(
    path: ByteArray,
    modelInts: IntArray,
    modelStrs: Array<ByteArray?>,
    sessionInts: IntArray,
  ): LongArray

  @JvmStatic external fun sessionCreate(model: Long, ints: IntArray): Long

  @JvmStatic external fun sessionFree(session: Long)

  @JvmStatic external fun sessionReset(session: Long)

  @JvmStatic external fun sessionSetThreads(session: Long, nThreads: Int, nThreadsBatch: Int)

  @JvmStatic external fun sessionInfoJson(session: Long): ByteArray

  @JvmStatic external fun sessionMemory(session: Long): LongArray

  /** The generation id (uint32). */
  @JvmStatic external fun generateStart(session: Long, json: ByteArray): Long

  /** A [PackedEvents] batch, or null when nothing arrived within [timeoutMs]. */
  @JvmStatic external fun pollEvents(session: Long, timeoutMs: Int, maxEvents: Int): ByteArray?

  @JvmStatic external fun cancel(session: Long)

  /** `se_wait`: SE_OK or SE_ERR_TIMEOUT. */
  @JvmStatic external fun waitIdle(session: Long, timeoutMs: Int): Int

  @JvmStatic external fun stateSave(session: Long, path: ByteArray)

  @JvmStatic external fun stateLoad(session: Long, path: ByteArray): Int

  @JvmStatic external fun loraLoad(model: Long, path: ByteArray): Long

  @JvmStatic external fun loraFree(lora: Long)

  @JvmStatic external fun setLoras(session: Long, loras: LongArray, scales: FloatArray)

  @JvmStatic external fun bench(model: Long, ints: IntArray, canceller: Long): DoubleArray

  /** 0 abort, 1 SIGSEGV, 2 _exit(3). Debuggable builds only (checked by the caller). */
  @JvmStatic external fun debugCrash(mode: Int)
}
