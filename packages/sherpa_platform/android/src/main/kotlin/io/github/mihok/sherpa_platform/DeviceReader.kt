package io.github.mihok.sherpa_platform

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.Build
import android.os.StatFs
import java.io.File

/**
 * Device facts for model fit and kill forensics. Runs on Pigeon's background
 * TaskQueue (sysfs, /proc/cpuinfo, StatFs and the exit-info binder call).
 */
internal class DeviceReader(private val context: Context, private val memory: MemoryReader) {
  private val activityManager: ActivityManager = requireNotNull(context.getSystemService(ActivityManager::class.java))

  fun read(): DeviceInfo {
    val cores = cpuIndices()
    val maxFreq = cores.map { readLong("/sys/devices/system/cpu/cpu$it/cpufreq/cpuinfo_max_freq") ?: 0L }
    val capacity = cores.map { readLong("/sys/devices/system/cpu/cpu$it/cpu_capacity") ?: 0L }
    // bigCores() returns positions in `cores`; map back to kernel cpu numbers.
    val big = CpuTopology.bigCores(capacity, maxFreq).map { cores[it].toLong() }
    val features = try {
      CpuInfoParser.features(File("/proc/cpuinfo").readText())
    } catch (_: Exception) {
      emptyList()
    }
    val battery = battery()
    val storage = storage()
    return DeviceInfo(
      platform = "android",
      osVersion = Build.VERSION.RELEASE ?: Build.VERSION.SDK_INT.toString(),
      apiLevel = Build.VERSION.SDK_INT.toLong(),
      manufacturer = Build.MANUFACTURER,
      model = Build.MODEL,
      socManufacturer = if (Build.VERSION.SDK_INT >= 31) Build.SOC_MANUFACTURER else null,
      socModel = if (Build.VERSION.SDK_INT >= 31) Build.SOC_MODEL else null,
      hardware = Build.HARDWARE,
      machine = Build.DEVICE,
      memory = memory.sample(),
      freeStorageBytes = storage?.first,
      totalStorageBytes = storage?.second,
      cpuCores = cores.size.toLong(),
      cpuMaxFreqKHz = maxFreq,
      cpuCapacity = capacity,
      bigCoreIndices = big,
      performanceCores = big.size.toLong(),
      cpuFeatures = features,
      isLowRamDevice = activityManager.isLowRamDevice,
      batteryLevel = battery?.first,
      charging = battery?.second,
      lastExit = lastExit(),
    )
  }

  /** Kernel cpu numbers from `possible`; falls back to the online count. */
  private fun cpuIndices(): List<Int> {
    val possible = try {
      CpuTopology.parseRange(File("/sys/devices/system/cpu/possible").readText())
    } catch (_: Exception) {
      emptyList()
    }
    return possible.ifEmpty { (0 until Runtime.getRuntime().availableProcessors()).toList() }
  }

  /** StatFs on filesDir: the volume the database and model files live on. */
  private fun storage(): Pair<Long, Long>? = try {
    val fs = StatFs(context.filesDir.absolutePath)
    fs.availableBytes to fs.totalBytes
  } catch (_: Exception) {
    null
  }

  /**
   * Sticky ACTION_BATTERY_CHANGED read with a null receiver: no registration
   * is kept, and `BatteryManager.isCharging` (23) covers wireless/USB alike.
   */
  private fun battery(): Pair<Double?, Boolean?>? = try {
    val bm = context.getSystemService(BatteryManager::class.java)
    val capacity = bm?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY) ?: Int.MIN_VALUE
    val level = if (capacity in 0..100) {
      capacity / 100.0
    } else {
      val filter = IntentFilter(Intent.ACTION_BATTERY_CHANGED)
      val sticky: Intent? = if (Build.VERSION.SDK_INT >= 33) {
        context.registerReceiver(null, filter, Context.RECEIVER_NOT_EXPORTED)
      } else {
        context.registerReceiver(null, filter)
      }
      val l = sticky?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
      val s = sticky?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
      if (l >= 0 && s > 0) l.toDouble() / s else null
    }
    level to bm?.isCharging
  } catch (_: Exception) {
    null
  }

  /**
   * Most recent previous-process exit (API 30+). "Most recent" includes every
   * process of the app; the summary bytes are whatever that process last
   * passed to setProcessStateSummary (R07 §2.4). Dart compares timestamps to
   * avoid acting on the same record twice.
   */
  private fun lastExit(): ExitRecord? {
    if (Build.VERSION.SDK_INT < 30) return null
    return try {
      val info = activityManager.getHistoricalProcessExitReasons(context.packageName, 0, 1).firstOrNull()
        ?: return null
      val lmk = ActivityManager.isLowMemoryKillReportSupported()
      ExitRecord(
        reason = info.reason.toLong(),
        reasonName = ExitClassifier.reasonName(info.reason),
        classification = ExitClassifier.classify(info.reason, info.status, info.description, lmk),
        details = info.description,
        timestampMs = info.timestamp,
        status = info.status.toLong(),
        importance = info.importance.toLong(),
        // getPss/getRss are in kB.
        pssBytes = info.pss * 1024,
        rssBytes = info.rss * 1024,
        processName = info.processName,
        processStateSummary = info.processStateSummary,
      )
    } catch (_: Exception) {
      null
    }
  }

  private fun readLong(path: String): Long? = try {
    File(path).readText().trim().toLongOrNull()
  } catch (_: Exception) {
    null
  }
}
