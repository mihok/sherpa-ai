package io.github.mihok.sherpa_platform

// Pure parsers for OS text formats and exit records. No android.* imports, so
// they run as plain JVM unit tests (android/src/test). Policy (what a reading
// *means* for memory pressure) lives in Dart; these only turn kernel/OS
// formats into numbers and stable names.

/** Normalizes the `Features` line of `/proc/cpuinfo` (R07 §3.4, R05 CPU variants). */
object CpuInfoParser {
  /**
   * Kernel hwcap names → Sherpa names (the set llama.cpp's CPU variant loader
   * and the device-fit `cpuFeatures` care about). `asimddp` is the kernel's
   * name for the ARMv8.2 dot product; `asimdhp`/`fphp` are half-precision.
   */
  private val names = linkedMapOf(
    "asimddp" to "dotprod",
    "i8mm" to "i8mm",
    "sve" to "sve",
    "sve2" to "sve2",
    "sme" to "sme",
    "sme2" to "sme2",
    "bf16" to "bf16",
    "asimdhp" to "fp16",
    "fphp" to "fp16",
  )

  /**
   * Union of every `Features` line (heterogeneous SoCs list one per core and
   * in theory could differ), mapped through [names], sorted.
   */
  fun features(cpuinfo: String): List<String> {
    val out = sortedSetOf<String>()
    for (line in cpuinfo.lineSequence()) {
      val colon = line.indexOf(':')
      if (colon < 0) continue
      if (line.substring(0, colon).trim() != "Features") continue
      for (flag in line.substring(colon + 1).trim().split(Regex("\\s+"))) {
        names[flag.lowercase()]?.let(out::add)
      }
    }
    return out.toList()
  }
}

/** CPU topology from sysfs (R07 §3.4). */
object CpuTopology {
  /** Parses a sysfs cpu list such as `0-3,5,7-8` (`/sys/devices/system/cpu/possible`). */
  fun parseRange(text: String): List<Int> {
    val out = sortedSetOf<Int>()
    for (part in text.trim().split(',')) {
      val p = part.trim()
      if (p.isEmpty()) continue
      val dash = p.indexOf('-')
      if (dash < 0) {
        p.toIntOrNull()?.let(out::add)
      } else {
        val lo = p.substring(0, dash).trim().toIntOrNull() ?: continue
        val hi = p.substring(dash + 1).trim().toIntOrNull() ?: continue
        if (hi >= lo && hi - lo < 1024) out.addAll(lo..hi)
      }
    }
    return out.toList()
  }

  /**
   * Cores outside the lowest-performance cluster: llama.cpp's `n_threads`
   * should be prime + big cores (R07 §3.4 "exclude the lowest-capacity
   * cluster"; little cores make every token wait for the slowest thread).
   *
   * Uses `cpu_capacity` when every core reports it (the scheduler's own
   * ranking), else `cpuinfo_max_freq`. A value of 0 means unknown; unknown
   * cores are never reported as big. A homogeneous CPU (one cluster) returns
   * every known core; no data returns an empty list.
   */
  fun bigCores(capacity: List<Long>, maxFreqKHz: List<Long>): List<Int> {
    val useCapacity = capacity.isNotEmpty() && capacity.all { it > 0 }
    val values = if (useCapacity) capacity else maxFreqKHz
    val known = values.withIndex().filter { it.value > 0 }
    if (known.isEmpty()) return emptyList()
    val lowest = known.minOf { it.value }
    val big = known.filter { it.value > lowest }.map { it.index }
    return if (big.isEmpty()) known.map { it.index } else big
  }
}

/** `/proc/self/status` fields (values are in kB). */
object ProcStatusParser {
  fun kilobytes(status: String): Map<String, Long> {
    val out = HashMap<String, Long>()
    for (line in status.lineSequence()) {
      val colon = line.indexOf(':')
      if (colon <= 0) continue
      val rest = line.substring(colon + 1).trim()
      if (!rest.endsWith("kB")) continue
      rest.removeSuffix("kB").trim().toLongOrNull()?.let { out[line.substring(0, colon)] = it }
    }
    return out
  }

  /** VmRSS in bytes. */
  fun rssBytes(fields: Map<String, Long>): Long? = fields["VmRSS"]?.times(1024)

  /**
   * RssAnon + VmSwap in bytes: anonymous resident memory plus what was pushed
   * to zRAM, which is the quantity the Android 17 limiter caps ("anonymous
   * RSS + swap", R07 §2.3). File-backed mmap weights are not in it.
   */
  fun anonSwapBytes(fields: Map<String, Long>): Long? {
    val anon = fields["RssAnon"] ?: return null
    return (anon + (fields["VmSwap"] ?: 0L)) * 1024
  }
}

/**
 * Turns an `ApplicationExitInfo` (reason, status, description) into a stable
 * name the Dart side keys its auto-downgrade on (R07 §2.3–2.4). Constants are
 * the platform values, inlined so this stays a pure JVM class.
 */
object ExitClassifier {
  const val REASON_UNKNOWN = 0
  const val REASON_EXIT_SELF = 1
  const val REASON_SIGNALED = 2
  const val REASON_LOW_MEMORY = 3
  const val REASON_CRASH = 4
  const val REASON_CRASH_NATIVE = 5
  const val REASON_ANR = 6
  const val REASON_INITIALIZATION_FAILURE = 7
  const val REASON_PERMISSION_CHANGE = 8
  const val REASON_EXCESSIVE_RESOURCE_USAGE = 9
  const val REASON_USER_REQUESTED = 10
  const val REASON_USER_STOPPED = 11
  const val REASON_DEPENDENCY_DIED = 12
  const val REASON_OTHER = 13
  const val REASON_FREEZER = 14
  const val REASON_PACKAGE_STATE_CHANGE = 15
  const val REASON_PACKAGE_UPDATED = 16
  private const val SIGKILL = 9

  fun reasonName(reason: Int): String = when (reason) {
    REASON_EXIT_SELF -> "EXIT_SELF"
    REASON_SIGNALED -> "SIGNALED"
    REASON_LOW_MEMORY -> "LOW_MEMORY"
    REASON_CRASH -> "CRASH"
    REASON_CRASH_NATIVE -> "CRASH_NATIVE"
    REASON_ANR -> "ANR"
    REASON_INITIALIZATION_FAILURE -> "INITIALIZATION_FAILURE"
    REASON_PERMISSION_CHANGE -> "PERMISSION_CHANGE"
    REASON_EXCESSIVE_RESOURCE_USAGE -> "EXCESSIVE_RESOURCE_USAGE"
    REASON_USER_REQUESTED -> "USER_REQUESTED"
    REASON_USER_STOPPED -> "USER_STOPPED"
    REASON_DEPENDENCY_DIED -> "DEPENDENCY_DIED"
    REASON_OTHER -> "OTHER"
    REASON_FREEZER -> "FREEZER"
    REASON_PACKAGE_STATE_CHANGE -> "PACKAGE_STATE_CHANGE"
    REASON_PACKAGE_UPDATED -> "PACKAGE_UPDATED"
    else -> "UNKNOWN"
  }

  /**
   * - `memoryLimiter`: Android 17 limiter kills report `REASON_OTHER` with a
   *   description containing "MemoryLimiter:AnonSwap"; matching any
   *   "MemoryLimiter" description also catches future variants.
   * - `lowMemory`: `REASON_LOW_MEMORY` (only reported when
   *   `isLowMemoryKillReportSupported()`).
   * - `likelyLowMemory`: without LMK reporting, an LMK kill looks like
   *   `REASON_SIGNALED` + SIGKILL (R07 §2.4).
   */
  fun classify(reason: Int, status: Int, description: String?, lmkReportSupported: Boolean): String {
    if (description?.contains("MemoryLimiter", ignoreCase = true) == true) return "memoryLimiter"
    return when (reason) {
      REASON_LOW_MEMORY -> "lowMemory"
      REASON_SIGNALED -> if (status == SIGKILL && !lmkReportSupported) "likelyLowMemory" else "signaled"
      REASON_CRASH -> "crash"
      REASON_CRASH_NATIVE -> "nativeCrash"
      REASON_ANR -> "anr"
      REASON_EXCESSIVE_RESOURCE_USAGE -> "excessiveResourceUsage"
      REASON_USER_REQUESTED, REASON_USER_STOPPED -> "userStopped"
      REASON_EXIT_SELF -> "exitSelf"
      REASON_FREEZER -> "freezer"
      REASON_PACKAGE_UPDATED, REASON_PACKAGE_STATE_CHANGE, REASON_PERMISSION_CHANGE,
      REASON_DEPENDENCY_DIED, REASON_INITIALIZATION_FAILURE -> "system"
      REASON_OTHER -> "other"
      else -> "unknown"
    }
  }
}

/** Truncates to at most [max] bytes without splitting a UTF-8 sequence. */
object Utf8 {
  fun truncate(bytes: ByteArray, max: Int): ByteArray {
    if (bytes.size <= max) return bytes
    var end = max
    // Back up over continuation bytes (10xxxxxx) so the cut lands on a lead byte.
    while (end > 0 && (bytes[end].toInt() and 0xC0) == 0x80) end--
    return bytes.copyOf(end)
  }
}
