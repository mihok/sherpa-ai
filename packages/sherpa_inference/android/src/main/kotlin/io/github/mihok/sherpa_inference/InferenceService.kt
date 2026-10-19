package io.github.mihok.sherpa_inference

import android.app.ActivityManager
import android.app.Application
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.os.Build
import android.os.IBinder
import android.os.Process
import android.os.RemoteException
import android.util.Log
import io.github.mihok.sherpa_inference.engine.Engine
import io.github.mihok.sherpa_inference.engine.EngineCore
import io.github.mihok.sherpa_inference.engine.EngineError
import io.github.mihok.sherpa_inference.engine.JniEngine
import io.github.mihok.sherpa_inference.engine.NativeEngine
import io.github.mihok.sherpa_inference.engine.PhaseTracker
import java.lang.reflect.Proxy
import java.util.concurrent.Executors

/**
 * Hosts sherpa_engine in the app's private `:inference` process (manifest: `android:process=":inference"`,
 * `exported="false"`, NOT `isolatedProcess` — an isolated uid could not open the GGUF, state files or LoRAs,
 * which the engine opens and mmaps by path).
 *
 * A bound-only service: it lives exactly as long as the main process binds it (SherpaInferencePlugin),
 * inherits that process's importance through the binding flags (BindPolicy), and never starts itself in the
 * foreground. Nothing Flutter-related runs here: the app's Application class is the platform default
 * (`${applicationName}` = android.app.Application), ContentProviders such as androidx.startup's are only
 * installed in the main process, and no FlutterEngine is ever created. The only Flutter class loaded is
 * the plain-Java StandardMessageCodec behind [Wire].
 *
 * Each attached client gets its own [EngineCore]; a client's death (or close) cancels its generations and
 * frees its handles. [onDestroy] (last unbind) frees everything, so an idle process holds no model memory.
 */
class InferenceService : Service() {
  private val sessions = java.util.Collections.synchronizedSet(HashSet<Session>())
  private val background = Executors.newCachedThreadPool { r -> Thread(r, "sherpa-inference-teardown").apply { isDaemon = true } }
  private lateinit var tracker: PhaseTracker
  private var engineFactory: () -> Engine = ::createEngine

  override fun onCreate() {
    super.onCreate()
    tracker = PhaseTracker(StateSummaryReporter(this)::publish)
  }

  override fun onBind(intent: Intent): IBinder = binder

  override fun onUnbind(intent: Intent): Boolean = false

  override fun onDestroy() {
    val all = synchronized(sessions) { sessions.toList().also { sessions.clear() } }
    for (s in all) s.shutdownAsync("service destroyed")
    super.onDestroy()
  }

  private val binder = object : IInferenceService.Stub() {
    override fun attach(client: IInferenceClient, protocolVersion: Int): IInferenceSession {
      if (protocolVersion != Wire.PROTOCOL_VERSION) {
        throw IllegalArgumentException("protocol $protocolVersion is not ${Wire.PROTOCOL_VERSION}")
      }
      val s = Session(client)
      sessions.add(s)
      try {
        client.asBinder().linkToDeath(s, 0)
      } catch (e: RemoteException) {
        s.shutdownAsync("client died while attaching")
      }
      return s
    }
  }

  private inner class Session(private val client: IInferenceClient) : IInferenceSession.Stub(), IBinder.DeathRecipient {
    private val core = EngineCore(
      engine = engineFactory(),
      sink = ::deliver,
      pid = Process.myPid().toLong(),
      phases = tracker,
      debuggable = (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0,
      onDebugKill = { Process.killProcess(Process.myPid()) },
    )

    @Volatile private var closed = false

    private fun deliver(message: InferenceMessage) {
      if (closed) return
      val blob = try {
        Blob.of(Wire.encodeMessage(message))
      } catch (t: Throwable) {
        Log.e(TAG, "cannot encode ${message.javaClass.simpleName}", t)
        return
      }
      try {
        client.receive(blob)
      } catch (e: RemoteException) {
        // The main process is gone; binderDied tears this session down.
      } finally {
        blob.close()
      }
    }

    override fun pid(): Int = Process.myPid()

    override fun send(message: Blob) {
      if (closed) return
      val (requestId, call) = try {
        Wire.decodeCall(message.bytes())
      } catch (t: Throwable) {
        Log.e(TAG, "undecodable call", t)
        return
      }
      core.submit(requestId, call)
    }

    override fun close() = shutdownAsync("client closed")

    override fun binderDied() = shutdownAsync("client died")

    fun shutdownAsync(why: String) {
      if (closed) return
      closed = true
      sessions.remove(this)
      try {
        client.asBinder().unlinkToDeath(this, 0)
      } catch (_: Exception) {
        // already dead
      }
      background.execute {
        Log.i(TAG, "engine session closing: $why")
        core.shutdown()
      }
    }
  }

  companion object {
    private const val TAG = "SherpaInference"

    /** Name of this service's process relative to the package (manifest `android:process`). */
    const val PROCESS_SUFFIX = ":inference"

    private val jni: Result<Unit> by lazy { runCatching { NativeEngine.load() } }

    /**
     * The JNI shim, or an [Engine] whose every call fails with "engine unavailable" when the shim cannot
     * load (e.g. an ABI the plugin does not build).
     */
    private fun createEngine(): Engine {
      val failure = jni.exceptionOrNull() ?: return JniEngine()
      val reason = "the inference JNI shim could not be loaded: $failure"
      return Proxy.newProxyInstance(Engine::class.java.classLoader, arrayOf(Engine::class.java)) { _, _, _ ->
        throw EngineError(EngineError.UNSUPPORTED, reason)
      } as Engine
    }

    /**
     * True in the `:inference` process. An app with a custom Application that initializes Flutter (or
     * anything heavy) in `onCreate` should skip that work when this returns true.
     */
    @JvmStatic
    fun isInferenceProcess(context: Context): Boolean {
      return Application.getProcessName() == context.packageName + PROCESS_SUFFIX
    }
  }
}

/**
 * `ActivityManager.setProcessStateSummary` from THIS (`:inference`) process on every phase transition
 * ([PhaseTracker]); the main process reads it back from the dead process's `ApplicationExitInfo`.
 * Off the engine threads (it is a Binder call into system_server), in order, failures ignored (the system
 * may throttle).
 */
private class StateSummaryReporter(context: Context) {
  private val am = context.getSystemService(ActivityManager::class.java)
  private val executor = Executors.newSingleThreadExecutor { r -> Thread(r, "sherpa-inference-summary").apply { isDaemon = true } }

  fun publish(summary: String) {
    if (Build.VERSION.SDK_INT < 30 || am == null) return
    executor.execute {
      try {
        val bytes = summary.toByteArray(Charsets.UTF_8)
        am.setProcessStateSummary(if (bytes.size <= PhaseTracker.MAX_BYTES) bytes else bytes.copyOf(PhaseTracker.MAX_BYTES))
      } catch (_: RuntimeException) {
        // Throttled or rejected: forensics are best effort.
      }
    }
  }
}
