package io.github.mihok.sherpa_inference

// Pure decoding of the `:inference` process's ApplicationExitInfo: stable names for the reason and a
// bounded, redacted excerpt of a native-crash tombstone. No android.* imports, so it runs as a plain JVM
// unit test. Interpreting the result (what to tell the user, whether to back off) is Dart policy.

/** Reason codes and classification, matching sherpa_platform's ExitClassifier vocabulary. */
object ExitDecoder {
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
   * - `memoryLimiter`: Android 17 limiter kills (`REASON_OTHER`, description "MemoryLimiter:AnonSwap").
   * - `lowMemory`: `REASON_LOW_MEMORY` (only when `isLowMemoryKillReportSupported()`).
   * - `likelyLowMemory`: without LMK reporting an LMK kill is `REASON_SIGNALED` + SIGKILL (R07 §2.4).
   * - `nativeCrash`: SIGSEGV/SIGABRT/... in native code — for the engine typically a GGML_ABORT (SIGABRT).
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

/**
 * A short, redacted summary of a native-crash tombstone (`ApplicationExitInfo.getTraceInputStream()` for
 * `REASON_CRASH_NATIVE`; a protobuf (tombstone.proto) since API 31, the classic text before). Kept: signal
 * and code, fault address, abort message, causes and the top [MAX_FRAMES] frames of the crashing thread as
 * `file name (function+offset) rel_pc`. Dropped: registers, memory dumps and maps, logcat buffers, open
 * fds, command line, other threads, build fingerprint. Paths are reduced to file names; the result is at
 * most [MAX_CHARS] characters.
 */
object TombstoneExcerpt {
  const val MAX_FRAMES = 8
  const val MAX_CHARS = 1500
  const val MAX_INPUT = 4 * 1024 * 1024
  private const val MAX_FIELD = 240

  fun from(bytes: ByteArray): String? {
    if (bytes.isEmpty()) return null
    val head = String(bytes, 0, minOf(bytes.size, 64), Charsets.ISO_8859_1)
    if (head.startsWith("*** ") || head.contains("pid: ") || head.startsWith("Build fingerprint")) {
      return fromText(String(bytes, Charsets.UTF_8))
    }
    return try {
      fromProto(bytes)
    } catch (_: RuntimeException) {
      null
    } ?: fromText(String(bytes, Charsets.UTF_8))
  }

  // ---------------------------------------------------------------------------------------------------
  // tombstone.proto (AOSP system/core/debuggerd/proto): Tombstone{6 tid, 10 signal_info, 14 abort_message,
  // 15 causes, 16 threads (map<uint32, Thread>)}; Signal{1 number, 2 name, 3 code, 4 code_name,
  // 8 has_fault_address, 9 fault_address}; Cause{1 human_readable}; Thread{1 id, 2 name,
  // 4 current_backtrace}; BacktraceFrame{1 rel_pc, 4 function_name, 5 function_offset, 6 file_name}.

  private class Frame(val relPc: Long, val function: String, val offset: Long, val file: String)

  fun fromProto(bytes: ByteArray): String? {
    var tid = -1L
    var signal: String? = null
    var abort: String? = null
    val causes = ArrayList<String>()
    val threads = HashMap<Long, List<Frame>>()
    var firstThread: List<Frame>? = null
    val r = Proto(bytes, 0, bytes.size)
    while (r.more()) {
      val (field, wire) = r.tag()
      when {
        field == 6 && wire == 0 -> tid = r.varint()
        field == 10 && wire == 2 -> signal = signal(r.sub())
        field == 14 && wire == 2 -> abort = r.string()
        field == 15 && wire == 2 -> {
          val c = r.sub()
          while (c.more()) {
            val (f, w) = c.tag()
            if (f == 1 && w == 2) causes.add(c.string()) else c.skip(w)
          }
        }
        field == 16 && wire == 2 -> {
          val entry = r.sub()
          var key = -1L
          var frames: List<Frame> = emptyList()
          while (entry.more()) {
            val (f, w) = entry.tag()
            when {
              f == 1 && w == 0 -> key = entry.varint()
              f == 2 && w == 2 -> frames = thread(entry.sub())
              else -> entry.skip(w)
            }
          }
          threads[key] = frames
          if (firstThread == null) firstThread = frames
        }
        else -> r.skip(wire)
      }
    }
    if (signal == null && abort == null && threads.isEmpty()) return null
    val frames = threads[tid] ?: firstThread ?: emptyList()
    val b = StringBuilder()
    signal?.let { b.append(it).append('\n') }
    abort?.takeIf { it.isNotBlank() }?.let { b.append("abort: ").append(redact(it)).append('\n') }
    for (c in causes.take(2)) b.append("cause: ").append(redact(c)).append('\n')
    for ((i, f) in frames.take(MAX_FRAMES).withIndex()) {
      b.append('#').append(i.toString().padStart(2, '0')).append(' ').append(baseName(f.file))
      if (f.function.isNotEmpty()) b.append(" (").append(clip(f.function, 120)).append('+').append(f.offset).append(')')
      b.append(" pc 0x").append(java.lang.Long.toHexString(f.relPc)).append('\n')
    }
    return finish(b)
  }

  private fun signal(r: Proto): String {
    var number = 0L
    var name = ""
    var code = 0L
    var codeName = ""
    var hasFault = false
    var fault = 0L
    while (r.more()) {
      val (f, w) = r.tag()
      when {
        f == 1 && w == 0 -> number = r.varint()
        f == 2 && w == 2 -> name = r.string()
        f == 3 && w == 0 -> code = r.varint()
        f == 4 && w == 2 -> codeName = r.string()
        f == 8 && w == 0 -> hasFault = r.varint() != 0L
        f == 9 && w == 0 -> fault = r.varint()
        else -> r.skip(w)
      }
    }
    val s = StringBuilder("signal ").append(number.toInt())
    if (name.isNotEmpty()) s.append(" (").append(clip(name, 16)).append(')')
    s.append(", code ").append(code.toInt())
    if (codeName.isNotEmpty()) s.append(" (").append(clip(codeName, 24)).append(')')
    if (hasFault) s.append(", fault addr 0x").append(java.lang.Long.toHexString(fault))
    return s.toString()
  }

  private fun thread(r: Proto): List<Frame> {
    val frames = ArrayList<Frame>()
    while (r.more()) {
      val (f, w) = r.tag()
      if (f == 4 && w == 2 && frames.size < MAX_FRAMES) frames.add(frame(r.sub())) else r.skip(w)
    }
    return frames
  }

  private fun frame(r: Proto): Frame {
    var relPc = 0L
    var function = ""
    var offset = 0L
    var file = ""
    while (r.more()) {
      val (f, w) = r.tag()
      when {
        f == 1 && w == 0 -> relPc = r.varint()
        f == 4 && w == 2 -> function = r.string()
        f == 5 && w == 0 -> offset = r.varint()
        f == 6 && w == 2 -> file = r.string()
        else -> r.skip(w)
      }
    }
    return Frame(relPc, function, offset, file)
  }

  /** Minimal protobuf wire-format reader (varint, 64-bit, length-delimited, 32-bit). */
  private class Proto(val b: ByteArray, var pos: Int, val end: Int) {
    fun more() = pos < end

    fun tag(): Pair<Int, Int> {
      val t = varint()
      return (t ushr 3).toInt() to (t and 7).toInt()
    }

    fun varint(): Long {
      var result = 0L
      var shift = 0
      while (true) {
        if (pos >= end) throw IllegalStateException("truncated varint")
        val x = b[pos++].toInt()
        result = result or ((x and 0x7F).toLong() shl shift)
        if (x and 0x80 == 0) return result
        shift += 7
        if (shift > 63) throw IllegalStateException("varint too long")
      }
    }

    fun length(): Int {
      val n = varint()
      if (n < 0 || n > end - pos) throw IllegalStateException("bad length $n")
      return n.toInt()
    }

    fun sub(): Proto {
      val n = length()
      val p = Proto(b, pos, pos + n)
      pos += n
      return p
    }

    fun string(): String {
      val n = length()
      val s = String(b, pos, minOf(n, 4096), Charsets.UTF_8)
      pos += n
      return s
    }

    fun skip(wire: Int) {
      when (wire) {
        0 -> varint()
        1 -> pos += 8
        2 -> {
          val n = length() // advances past the length varint first
          pos += n
        }
        5 -> pos += 4
        else -> throw IllegalStateException("wire type $wire")
      }
      if (pos > end) throw IllegalStateException("truncated field")
    }
  }

  // ---------------------------------------------------------------------------------------------------
  // Text tombstones (debuggerd's classic format)

  private val FRAME = Regex("""^\s*#(\d+)\s+pc\s+([0-9a-fA-F]+)\s+(\S+)(.*)$""")
  private val PARENS = Regex("""\(([^()]*)\)""")

  fun fromText(text: String): String? {
    val b = StringBuilder()
    var inBacktrace = false
    var frames = 0
    for (raw in text.lineSequence().take(4000)) {
      val line = raw.trimEnd()
      when {
        line.startsWith("signal ") && !b.contains("signal ") -> b.append(clip(line, 160)).append('\n')
        line.startsWith("Abort message:") -> b.append("abort: ")
          .append(redact(line.removePrefix("Abort message:").trim().trim('\''))).append('\n')
        line.startsWith("Cause:") -> b.append("cause: ").append(redact(line.removePrefix("Cause:").trim())).append('\n')
        line.trim() == "backtrace:" -> inBacktrace = frames == 0
        inBacktrace -> {
          val m = FRAME.find(line)
          if (m == null) {
            if (frames > 0) inBacktrace = false
          } else if (frames < MAX_FRAMES) {
            val (idx, pc, path, rest) = m.destructured
            val fn = PARENS.findAll(rest).map { it.groupValues[1] }
              .firstOrNull { !it.startsWith("BuildId") && !it.startsWith("offset") && !it.startsWith("deleted") }
            b.append('#').append(idx).append(' ').append(baseName(path))
            if (!fn.isNullOrEmpty()) b.append(" (").append(clip(fn, 120)).append(')')
            b.append(" pc 0x").append(pc.trimStart('0').ifEmpty { "0" }).append('\n')
            frames++
          }
        }
      }
    }
    return if (b.isEmpty()) null else finish(b)
  }

  // ---------------------------------------------------------------------------------------------------

  private val PATH = Regex("""(/[\w.+~=@-]+)+/([\w.+~=@-]+)""")

  /** Absolute paths → file names (model and app paths reveal user/device data), one line, bounded. */
  fun redact(s: String): String = clip(PATH.replace(s) { it.groupValues[2] }.replace(Regex("\\s+"), " "), MAX_FIELD)

  /** `/data/app/~~x/pkg-y/base.apk!/lib/arm64-v8a/libfoo.so` (a library mapped from the APK) → `libfoo.so`. */
  fun baseName(path: String): String = path.substringAfterLast('!').substringAfterLast('/').ifEmpty { "?" }

  private fun clip(s: String, max: Int): String = if (s.length <= max) s else s.take(max - 1) + "…"

  private fun finish(b: StringBuilder): String = clip(b.toString().trimEnd(), MAX_CHARS)
}
