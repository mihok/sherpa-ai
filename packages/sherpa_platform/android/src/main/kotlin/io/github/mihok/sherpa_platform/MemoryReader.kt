package io.github.mihok.sherpa_platform

import android.app.ActivityManager
import android.content.Context
import android.os.Build
import android.os.PowerManager
import android.os.SystemClock
import java.io.File

/**
 * Raw memory/thermal/power readings. Called on Pigeon's background
 * TaskQueue: `getMemoryInfo`, `getThermalHeadroom` and `/proc` reads are
 * binder calls or file I/O and must not run on the main thread.
 */
internal class MemoryReader(context: Context) {
  private val activityManager: ActivityManager = requireNotNull(context.getSystemService(ActivityManager::class.java))
  private val powerManager: PowerManager = requireNotNull(context.getSystemService(PowerManager::class.java))

  private val headroomLock = Any()
  private var headroomAtMs = 0L
  private var headroom: Double? = null

  /**
   * Latest value pushed by the API 36 headroom listener (SignalHub); while it
   * is fresh, polling is skipped entirely.
   */
  @Volatile private var pushedHeadroom: Double? = null
  @Volatile private var pushedAtMs = 0L

  fun sample(): MemorySample {
    val mi = ActivityManager.MemoryInfo()
    activityManager.getMemoryInfo(mi)
    val proc = ActivityManager.RunningAppProcessInfo()
    ActivityManager.getMyMemoryState(proc)
    val status = readProcStatus()
    return MemorySample(
      platform = "android",
      timestampMs = System.currentTimeMillis(),
      apiLevel = Build.VERSION.SDK_INT.toLong(),
      availMemBytes = mi.availMem,
      thresholdBytes = mi.threshold,
      totalMemBytes = mi.totalMem,
      advertisedMemBytes = if (Build.VERSION.SDK_INT >= 34) mi.advertisedMem else null,
      freeMemBytes = if (Build.VERSION.SDK_INT >= 37) mi.freeMem else null,
      lowMemory = mi.lowMemory,
      lastTrimLevel = proc.lastTrimLevel.toLong(),
      rssBytes = status?.let(ProcStatusParser::rssBytes),
      anonSwapBytes = status?.let(ProcStatusParser::anonSwapBytes),
      thermalStatus = powerManager.currentThermalStatus.toLong(),
      thermalHeadroom = thermalHeadroom(),
      lowPowerMode = powerManager.isPowerSaveMode,
    )
  }

  fun onHeadroomPushed(value: Double) {
    pushedHeadroom = value
    pushedAtMs = SystemClock.elapsedRealtime()
  }

  /**
   * `getThermalHeadroom(10)` (API 30): "no benefit to calling this function
   * more frequently than about once per second"; faster calls return NaN
   * (R07 §3.3). Cached for [MIN_POLL_MS] so a burst of samples costs one
   * binder call, and skipped while the API 36 listener keeps us fresh.
   */
  private fun thermalHeadroom(): Double? {
    if (Build.VERSION.SDK_INT < 30) return null
    val now = SystemClock.elapsedRealtime()
    pushedHeadroom?.let { if (now - pushedAtMs < PUSH_FRESH_MS) return it }
    synchronized(headroomLock) {
      if (headroomAtMs != 0L && now - headroomAtMs < MIN_POLL_MS) return headroom
      val v = try {
        powerManager.getThermalHeadroom(FORECAST_SECONDS)
      } catch (_: RuntimeException) {
        Float.NaN
      }
      headroomAtMs = now
      // NaN = unsupported or rate-limited: keep the last good value.
      if (!v.isNaN()) headroom = v.toDouble()
      return headroom
    }
  }

  private fun readProcStatus(): Map<String, Long>? = try {
    ProcStatusParser.kilobytes(File("/proc/self/status").readText())
  } catch (_: Exception) {
    null
  }

  companion object {
    /** R07 §9.5: "getThermalHeadroom(10) at 1 Hz or less"; we poll ≤ 0.5 Hz. */
    const val MIN_POLL_MS = 2000L
    const val FORECAST_SECONDS = 10
    private const val PUSH_FRESH_MS = 10_000L
  }
}
