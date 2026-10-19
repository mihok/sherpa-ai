package io.github.mihok.sherpa_litert

import android.app.ActivityManager
import android.content.ComponentCallbacks2
import android.content.Context
import android.content.res.Configuration
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.github.mihok.sherpa_litert.lm.LiteRtRuntime
import io.github.mihok.sherpa_litert.lm.LmController
import io.github.mihok.sherpa_litert.lm.LmLoadFailedException
import io.github.mihok.sherpa_litert.lm.LmStatusException
import io.github.mihok.sherpa_litert.nano.MlKitNanoClientFactory
import io.github.mihok.sherpa_litert.nano.NanoController
import io.github.mihok.sherpa_litert.stream.Events
import io.github.mihok.sherpa_litert.stream.Poster
import io.github.mihok.sherpa_litert.stream.StreamHub
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.cancel
import kotlinx.coroutines.withContext

/**
 * Entry point (Android only). Threads:
 * - `sherpa-litert-engine`: one dedicated thread for every LiteRT-LM call (load, conversations, send, cancel,
 *   release). Pigeon's suspend handlers start on the main thread and switch to it at once, so the platform
 *   main thread never blocks on the engine.
 * - `sherpa-nano`: the coroutine dispatcher of Gemini Nano work; `sherpa-nano-worker` is ML Kit's worker executor.
 * - LiteRT-LM's and ML Kit's own callback threads produce deltas into [StreamHub], which hands batches to the event
 *   sink on the main thread.
 *
 * `onTrimMemory` is forwarded to Dart and, at or above the level Dart set ([setTrimPolicy], default
 * TRIM_MEMORY_BACKGROUND = 40), stops a running LiteRT-LM turn at the next token and frees the engine.
 */
class SherpaLitertPlugin : FlutterPlugin, LiteRtHostApi {
  private lateinit var context: Context
  private lateinit var hub: StreamHub
  private lateinit var lm: LmController
  private lateinit var nano: NanoController
  private lateinit var runtime: LiteRtRuntime
  private lateinit var nanoScope: CoroutineScope

  private val engineThread: ExecutorService = singleThread("sherpa-litert-engine")
  private val engineDispatcher = engineThread.asCoroutineDispatcher()
  private val nanoThread: ExecutorService = singleThread("sherpa-nano")
  private val nanoDispatcher = nanoThread.asCoroutineDispatcher()
  private val nanoWorker: ExecutorService = singleThread("sherpa-nano-worker")

  @Volatile private var trimThreshold = ComponentCallbacks2.TRIM_MEMORY_BACKGROUND

  private val trimCallbacks = object : ComponentCallbacks2 {
    override fun onTrimMemory(level: Int) {
      hub.global(Events.trimMemory(level))
      val threshold = trimThreshold
      if (threshold > 0 && level >= threshold) runOnEngine { lm.onTrimMemory(level, threshold) }
    }

    override fun onConfigurationChanged(newConfig: Configuration) {}

    // Deprecated in API 35 and not delivered since 34, but still abstract in ComponentCallbacks; reported as
    // TRIM_MEMORY_COMPLETE (80), its old equivalent (same as sherpa_platform's SignalHub).
    @Deprecated("Deprecated in Android API 35")
    override fun onLowMemory() = onTrimMemory(TRIM_MEMORY_COMPLETE)
  }

  private val events = object : EventsStreamHandler() {
    override fun onListen(p0: Any?, sink: PigeonEventSink<EventBatch>) {
      hub.sink = { sink.success(it) }
    }

    override fun onCancel(p0: Any?) {
      hub.sink = null
    }
  }

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    context = binding.applicationContext
    val main = Handler(Looper.getMainLooper())
    hub = StreamHub(Poster { delayMs, task -> if (delayMs <= 0) main.post(task) else main.postDelayed(task, delayMs) })
    runtime = LiteRtRuntime()
    lm = LmController(runtime, hub, engineThread, context.applicationInfo.nativeLibraryDir)
    nanoScope = CoroutineScope(SupervisorJob() + nanoDispatcher)
    nano = NanoController(MlKitNanoClientFactory(nanoWorker), hub, nanoScope)
    LiteRtHostApi.setUp(binding.binaryMessenger, this)
    EventsStreamHandler.register(binding.binaryMessenger, events)
    context.registerComponentCallbacks(trimCallbacks)
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    LiteRtHostApi.setUp(binding.binaryMessenger, null)
    context.unregisterComponentCallbacks(trimCallbacks)
    hub.sink = null
    nano.closeAll()
    nanoScope.cancel()
    runOnEngine { lm.release("detached") }
  }

  // --- Device ---------------------------------------------------------------------------------------------

  override suspend fun platformInfo(): PlatformInfoMsg = withContext(engineDispatcher) {
    val loadError = runtime.loadError()
    PlatformInfoMsg(
      apiLevel = Build.VERSION.SDK_INT.toLong(),
      supportedAbis = Build.SUPPORTED_ABIS.toList(),
      socManufacturer = if (Build.VERSION.SDK_INT >= 31) Build.SOC_MANUFACTURER else null,
      socModel = if (Build.VERSION.SDK_INT >= 31) Build.SOC_MODEL else null,
      nativeLibraryDir = context.applicationInfo.nativeLibraryDir,
      cacheDir = context.cacheDir.path,
      liteRtAvailable = loadError == null,
      liteRtError = loadError,
      mlKitAvailable = runCatching { Class.forName("com.google.mlkit.genai.prompt.Generation") }.isSuccess,
    )
  }

  override fun isAppInForeground(): Boolean {
    val info = ActivityManager.RunningAppProcessInfo()
    ActivityManager.getMyMemoryState(info)
    return info.importance == ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND
  }

  // --- LiteRT-LM --------------------------------------------------------------------------------------------

  override suspend fun inspectModel(path: String): ModelInfoMsg = onEngine {
    Wire.info(lm.inspect(path), File(path).length())
  }

  override suspend fun loadEngine(request: LoadRequestMsg): LoadResultMsg = onEngine {
    Wire.loadResult(lm.load(Wire.load(request)))
  }

  override suspend fun releaseEngine(reason: String) = onEngine { lm.release(reason) }

  override suspend fun openConversation(spec: ConversationSpecMsg) = onEngine { lm.openConversation(Wire.spec(spec)) }

  override suspend fun closeConversation(conversationId: String) = onEngine { lm.closeConversation(conversationId) }

  override fun sendMessage(request: SendRequestMsg) = runOnEngine {
    lm.send(request.streamId, request.conversationId, Wire.message(request.message), Wire.options(request))
  }

  override fun cancel(streamId: Long, reason: String) {
    if (nano.cancel(streamId, reason)) return
    runOnEngine { lm.cancel(streamId, reason) }
  }

  override fun credit(streamId: Long, batches: Long) = hub.credit(streamId, batches.toInt())

  override fun setTrimPolicy(releaseAtLevel: Long) {
    trimThreshold = releaseAtLevel.toInt()
  }

  // --- Gemini Nano ------------------------------------------------------------------------------------------

  override suspend fun nanoStatus(config: NanoConfigMsg): NanoStatusMsg = withContext(nanoDispatcher) { nano.status(config) }

  override fun nanoDownload(streamId: Long, config: NanoConfigMsg) = nano.download(streamId, config)

  override suspend fun nanoWarmup(config: NanoConfigMsg) = withContext(nanoDispatcher) {
    try {
      nano.warmup(config)
    } catch (e: CancellationException) {
      throw e
    } catch (t: Throwable) {
      val m = NanoController.errorMsg(t)
      throw SherpaLitertError("nano_error", m.message, listOf(m.code, m.retryAfterMs))
    }
  }

  override fun nanoGenerate(request: NanoRequestMsg) = nano.generate(request)

  // --- Helpers ----------------------------------------------------------------------------------------------

  /** Runs [block] on the engine thread; failures become [SherpaLitertError]s Dart can classify. */
  private suspend fun <T> onEngine(block: () -> T): T = withContext(engineDispatcher) {
    try {
      block()
    } catch (e: LmLoadFailedException) {
      throw SherpaLitertError("load_failed", e.message, listOf(e.code.toLong(), e.failures))
    } catch (e: LmStatusException) {
      throw SherpaLitertError("litert_status", e.message, listOf(e.code.toLong()))
    } catch (e: IllegalStateException) {
      throw SherpaLitertError("state", e.message ?: e.toString(), null)
    } catch (e: IllegalArgumentException) {
      throw SherpaLitertError("argument", e.message ?: e.toString(), null)
    }
  }

  private fun runOnEngine(block: () -> Unit) {
    try {
      engineThread.execute(block)
    } catch (_: RejectedExecutionException) {
      // Shutting down.
    }
  }

  private companion object {
    const val TRIM_MEMORY_COMPLETE = 80

    fun singleThread(name: String): ExecutorService = Executors.newSingleThreadExecutor { r ->
      Thread(r, name).apply { isDaemon = true }
    }
  }
}
