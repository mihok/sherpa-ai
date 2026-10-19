package io.github.mihok.sherpa_platform

import android.content.BroadcastReceiver
import android.content.ComponentCallbacks2
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.res.Configuration
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import java.util.concurrent.CopyOnWriteArraySet

/**
 * Pushes OS events to Dart while the event channel is listened, and only
 * then: every registration is made in [onListen] and removed in [onCancel],
 * so an app that never listens pays nothing.
 *
 * Sources (R07 §2.1, §3.3):
 * - `onTrimMemory`: only UI_HIDDEN (20) and BACKGROUND (40) are delivered on
 *   API 34+; older devices (minSdk 29) still send RUNNING_* levels.
 * - thermal status listener (29) and, on 36+, the headroom listener, which
 *   also feeds [MemoryReader] so polling stops while pushes are fresh.
 * - ACTION_POWER_SAVE_MODE_CHANGED (battery saver).
 */
internal class SignalHub(private val context: Context, private val memory: MemoryReader) : SignalsStreamHandler() {
  private val main = Handler(Looper.getMainLooper())
  private val powerManager: PowerManager = requireNotNull(context.getSystemService(PowerManager::class.java))
  private var sink: PigeonEventSink<PlatformSignal>? = null

  private val trimCallbacks = object : ComponentCallbacks2 {
    override fun onTrimMemory(level: Int) = emit(SignalKind.TRIM_MEMORY, level.toLong())

    override fun onConfigurationChanged(newConfig: Configuration) {}

    // Deprecated in API 35 and not delivered since 34, but still abstract in
    // ComponentCallbacks. Reported as TRIM_MEMORY_COMPLETE (80), its old
    // equivalent ("the system is running low on memory").
    @Deprecated("Deprecated in Android API 35")
    override fun onLowMemory() = emit(SignalKind.TRIM_MEMORY, 80L)
  }

  private val thermalListener = PowerManager.OnThermalStatusChangedListener { status ->
    emit(SignalKind.THERMAL, status.toLong())
  }

  // Typed as Any so the API 36 interface is only loaded behind the SDK check.
  private var headroomListener: Any? = null

  private val powerReceiver = object : BroadcastReceiver() {
    override fun onReceive(c: Context, intent: Intent) {
      emit(SignalKind.POWER_MODE, if (powerManager.isPowerSaveMode) 1L else 0L)
    }
  }

  override fun onListen(p0: Any?, sink: PigeonEventSink<PlatformSignal>) {
    if (this.sink != null) unregister()
    this.sink = sink
    active.add(this)
    context.registerComponentCallbacks(trimCallbacks)
    powerManager.addThermalStatusListener(context.mainExecutor, thermalListener)
    if (Build.VERSION.SDK_INT >= 36) {
      val l = PowerManager.OnThermalHeadroomChangedListener { headroom, forecast, _, _ ->
        // The forecast (10 s on most devices) is what the policy acts on;
        // fall back to the current value when the forecast is NaN.
        val v = if (forecast.isNaN()) headroom else forecast
        if (!v.isNaN()) {
          memory.onHeadroomPushed(v.toDouble())
          emit(SignalKind.THERMAL_HEADROOM, 0L, value = v.toDouble())
        }
      }
      try {
        powerManager.addThermalHeadroomListener(context.mainExecutor, l)
        headroomListener = l
      } catch (_: RuntimeException) {
        // Unsupported HAL: MemoryReader keeps polling getThermalHeadroom.
      }
    }
    val filter = IntentFilter(PowerManager.ACTION_POWER_SAVE_MODE_CHANGED)
    if (Build.VERSION.SDK_INT >= 33) {
      context.registerReceiver(powerReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
    } else {
      context.registerReceiver(powerReceiver, filter)
    }
  }

  override fun onCancel(p0: Any?) {
    unregister()
    sink = null
  }

  private fun unregister() {
    active.remove(this)
    try {
      context.unregisterComponentCallbacks(trimCallbacks)
      powerManager.removeThermalStatusListener(thermalListener)
      if (Build.VERSION.SDK_INT >= 36) {
        (headroomListener as? PowerManager.OnThermalHeadroomChangedListener)?.let {
          powerManager.removeThermalHeadroomListener(it)
        }
      }
      headroomListener = null
      context.unregisterReceiver(powerReceiver)
    } catch (_: IllegalArgumentException) {
      // Already unregistered.
    }
  }

  fun emit(kind: SignalKind, level: Long, value: Double? = null, leaseId: String? = null, detail: String? = null) {
    val signal = PlatformSignal(kind, level, value, leaseId, detail, System.currentTimeMillis())
    // Event sinks must be called on the platform main thread.
    if (Looper.myLooper() == Looper.getMainLooper()) sink?.success(signal) else main.post { sink?.success(signal) }
  }

  companion object {
    /** Hubs with a live listener; [RunService] reports lease expiry to them. */
    val active = CopyOnWriteArraySet<SignalHub>()

    fun broadcast(kind: SignalKind, leaseId: String, detail: String) {
      for (hub in active) hub.emit(kind, 0L, leaseId = leaseId, detail = detail)
    }
  }
}
