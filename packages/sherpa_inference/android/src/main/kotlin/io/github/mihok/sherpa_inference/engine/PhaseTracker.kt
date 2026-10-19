package io.github.mihok.sherpa_inference.engine

/**
 * What the engine in this process is doing, as the ≤ 128-byte summary the service passes to
 * `ActivityManager.setProcessStateSummary` (API 30+). The main process reads it back from the
 * `ApplicationExitInfo` of a dead `:inference` process, so a crash or kill is attributed to the phase it
 * interrupted (R07 §2.4). Same vocabulary as Dart's `InferencePhase` / `PhaseRecord.compactSummary`:
 *
 *     {"v":1,"p":"generating","m":"<model tag>","c":4096,"k":"f16/f16","h":"proc"}
 *
 * `p` is idle | loading | generating | savingState | restoringState | benchmarking; `m` is a short tag the
 * Dart host derives from the model identity (never a path or user data); `h` marks the process host.
 * Concurrent phases: the most recently entered one that is still active wins. Only transitions are
 * published (the system may throttle the call).
 */
class PhaseTracker(private val publish: (String) -> Unit) {
  inner class Token internal constructor(
    val phase: String,
    val modelTag: String?,
    val nCtx: Long?,
    val kv: String?,
  ) : AutoCloseable {
    private var closed = false

    override fun close() {
      synchronized(this@PhaseTracker) {
        if (closed) return
        closed = true
        active.remove(this)
        publishLocked()
      }
    }
  }

  private val active = ArrayList<Token>()
  private var last: String? = null

  fun enter(phase: String, modelTag: String? = null, nCtx: Long? = null, kv: String? = null): Token =
    synchronized(this) {
      val t = Token(phase, modelTag, nCtx, kv)
      active.add(t)
      publishLocked()
      t
    }

  /** The current summary (for tests and diagnostics). */
  fun current(): String = synchronized(this) { summary(active.lastOrNull()) }

  private fun publishLocked() {
    val s = summary(active.lastOrNull())
    if (s == last) return
    last = s
    // Under the lock so transitions reach the publisher in order; it only enqueues.
    publish(s)
  }

  companion object {
    const val MAX_BYTES = 128
    private val SAFE = Regex("[^A-Za-z0-9._:/+-]")

    fun summary(t: Token?): String {
      if (t == null) return """{"v":1,"p":"idle","h":"proc"}"""
      val b = StringBuilder("""{"v":1,"p":"""").append(clean(t.phase, 16)).append('"')
      t.modelTag?.let { b.append(""","m":"""").append(clean(it, 24)).append('"') }
      t.nCtx?.let { b.append(""","c":""").append(it) }
      t.kv?.let { b.append(""","k":"""").append(clean(it, 16)).append('"') }
      b.append(""","h":"proc"}""")
      val s = b.toString()
      return if (s.toByteArray().size <= MAX_BYTES) s else """{"v":1,"p":"${clean(t.phase, 16)}","h":"proc"}"""
    }

    private fun clean(s: String, max: Int): String = SAFE.replace(s, "").take(max)

    private val N_CTX = Regex("\"n_ctx\"\\s*:\\s*(\\d+)")
    private val TYPE_K = Regex("\"type_k\"\\s*:\\s*\"([^\"]*)\"")
    private val TYPE_V = Regex("\"type_v\"\\s*:\\s*\"([^\"]*)\"")

    /** (n_ctx, "k/v") from `se_session_info_json` without a JSON library (org.json is not on the JVM). */
    fun sessionShape(infoJson: String): Pair<Long?, String?> {
      val nCtx = N_CTX.find(infoJson)?.groupValues?.get(1)?.toLongOrNull()
      val k = TYPE_K.find(infoJson)?.groupValues?.get(1)
      val v = TYPE_V.find(infoJson)?.groupValues?.get(1)
      return nCtx to (if (k != null && v != null) "$k/$v" else null)
    }
  }
}
