package io.github.mihok.sherpa_inference

import java.nio.ByteBuffer

/**
 * The Binder payload format between the main process and `:inference`: the codec Pigeon generated for
 * pigeons/inference_api.dart (a StandardMessageCodec — plain JVM code, so nothing Flutter initializes in
 * the service process). Calls travel as `[requestId, EngineCall]`, replies/events as one InferenceMessage.
 * Both processes run the same APK, so both ends always agree on the schema.
 */
object Wire {
  /** Bumped when the AIDL contract changes shape (both ends ship in one APK; this is a sanity check). */
  const val PROTOCOL_VERSION = 1

  /**
   * Largest payload sent inline in a transaction. Above it the bytes go through SharedMemory (one fd in the
   * parcel). Oneway transactions share half of a process's 1 MiB Binder buffer, so inline payloads stay
   * small: ≤ 32 KiB each, ≤ 4 batches of ≤ 16 KiB in flight per stream (PumpConfig).
   */
  const val INLINE_MAX = 32 * 1024

  /** Refuse anything larger (a runaway request JSON); 64 MiB fits any realistic context. */
  const val MAX_MESSAGE = 64 * 1024 * 1024

  private val codec get() = InferenceHostApi.codec

  fun useSharedMemory(size: Int): Boolean = size > INLINE_MAX

  fun encodeCall(requestId: Long, call: EngineCall): ByteArray = encode(listOf(requestId, call))

  fun decodeCall(bytes: ByteArray): Pair<Long, EngineCall> {
    val list = decode(bytes) as List<*>
    return (list[0] as Number).toLong() to (list[1] as EngineCall)
  }

  fun encodeMessage(message: InferenceMessage): ByteArray = encode(message)

  fun decodeMessage(bytes: ByteArray): InferenceMessage = decode(bytes) as InferenceMessage

  private fun encode(value: Any): ByteArray {
    val buffer = codec.encodeMessage(value) ?: error("nothing to encode")
    buffer.flip()
    val out = ByteArray(buffer.remaining())
    buffer.get(out)
    require(out.size <= MAX_MESSAGE) { "message of ${out.size} bytes exceeds $MAX_MESSAGE" }
    return out
  }

  private fun decode(bytes: ByteArray): Any? = codec.decodeMessage(ByteBuffer.wrap(bytes))
}
