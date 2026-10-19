package io.github.mihok.sherpa_inference.engine

import io.github.mihok.sherpa_inference.EngineEventMsg
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * The event batch format of `NativeEngine.pollEvents` (sherpa_jni.c `jni_poll_events`): one JNI crossing and
 * one array per poll instead of an object per event. Little-endian:
 *
 *     i32 count, then per event:
 *       i32 type, generation_id (uint32), index, code, prompt_tokens, cached_tokens, completion_tokens,
 *           n_drafted, n_accepted, progress_done, progress_total
 *       f64 ttft_ms, prefill_tps, decode_tps, draft_accept_rate, prefill_ms, decode_ms
 *       text, id, name: i32 byte length + UTF-8 bytes
 *
 * [encode] exists for tests (the fake engine) and documents the layout the C side must produce.
 */
object PackedEvents {
  fun decode(packed: ByteArray): List<EngineEventMsg> {
    val b = ByteBuffer.wrap(packed).order(ByteOrder.LITTLE_ENDIAN)
    val n = b.int
    require(n in 0..1_000_000) { "corrupt event batch ($n events)" }
    val out = ArrayList<EngineEventMsg>(n)
    repeat(n) {
      val type = b.int.toLong()
      val generationId = b.int.toLong() and 0xFFFFFFFFL
      val index = b.int.toLong()
      val code = b.int.toLong()
      val promptTokens = b.int.toLong()
      val cachedTokens = b.int.toLong()
      val completionTokens = b.int.toLong()
      val nDrafted = b.int.toLong()
      val nAccepted = b.int.toLong()
      val progressDone = b.int.toLong()
      val progressTotal = b.int.toLong()
      val ttftMs = b.double
      val prefillTps = b.double
      val decodeTps = b.double
      val draftAcceptRate = b.double
      val prefillMs = b.double
      val decodeMs = b.double
      val text = str(b)
      val id = str(b)
      val name = str(b)
      out.add(
        EngineEventMsg(
          type = type,
          generationId = generationId,
          index = index,
          code = code,
          text = text,
          id = id,
          name = name,
          promptTokens = promptTokens,
          cachedTokens = cachedTokens,
          completionTokens = completionTokens,
          nDrafted = nDrafted,
          nAccepted = nAccepted,
          progressDone = progressDone,
          progressTotal = progressTotal,
          ttftMs = ttftMs,
          prefillTps = prefillTps,
          decodeTps = decodeTps,
          draftAcceptRate = draftAcceptRate,
          prefillMs = prefillMs,
          decodeMs = decodeMs,
        ),
      )
    }
    return out
  }

  fun encode(events: List<EngineEventMsg>): ByteArray {
    val strings = events.map { e -> Triple(e.text.toByteArray(), e.id.toByteArray(), e.name.toByteArray()) }
    val size = 4 + events.size * (11 * 4 + 6 * 8 + 3 * 4) + strings.sumOf { it.first.size + it.second.size + it.third.size }
    val b = ByteBuffer.allocate(size).order(ByteOrder.LITTLE_ENDIAN)
    b.putInt(events.size)
    for ((i, e) in events.withIndex()) {
      b.putInt(e.type.toInt())
      b.putInt(e.generationId.toInt())
      b.putInt(e.index.toInt())
      b.putInt(e.code.toInt())
      b.putInt(e.promptTokens.toInt())
      b.putInt(e.cachedTokens.toInt())
      b.putInt(e.completionTokens.toInt())
      b.putInt(e.nDrafted.toInt())
      b.putInt(e.nAccepted.toInt())
      b.putInt(e.progressDone.toInt())
      b.putInt(e.progressTotal.toInt())
      b.putDouble(e.ttftMs)
      b.putDouble(e.prefillTps)
      b.putDouble(e.decodeTps)
      b.putDouble(e.draftAcceptRate)
      b.putDouble(e.prefillMs)
      b.putDouble(e.decodeMs)
      val (t, id, name) = strings[i]
      b.putInt(t.size).put(t)
      b.putInt(id.size).put(id)
      b.putInt(name.size).put(name)
    }
    return b.array()
  }

  private fun str(b: ByteBuffer): String {
    val len = b.int
    require(len >= 0 && len <= b.remaining()) { "corrupt event batch (string of $len bytes)" }
    if (len == 0) return ""
    val s = String(b.array(), b.arrayOffset() + b.position(), len, Charsets.UTF_8)
    b.position(b.position() + len)
    return s
  }
}

/** `se_event_type` / `se_finish_reason` codes the service needs. */
object EventTypes {
  const val TEXT_DELTA = 1L
  const val REASONING_DELTA = 2L
  const val TOOL_CALL_START = 3L
  const val TOOL_CALL_ARGS_DELTA = 4L
  const val TOOL_CALL_DONE = 5L
  const val USAGE = 6L
  const val PERF = 7L
  const val FINISH = 8L
  const val ERROR = 9L
  const val PROMPT_PROGRESS = 10L

  fun known(type: Long): Boolean = type in TEXT_DELTA..PROMPT_PROGRESS
}
