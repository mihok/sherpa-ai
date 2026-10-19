package io.github.mihok.sherpa_inference

import io.github.mihok.sherpa_inference.engine.FakeEngine
import io.github.mihok.sherpa_inference.engine.PackedEvents
import io.github.mihok.sherpa_inference.engine.PumpConfig
import io.github.mihok.sherpa_inference.engine.bench
import io.github.mihok.sherpa_inference.engine.cfg
import io.github.mihok.sherpa_inference.engine.opts
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The Binder payload codec (the Pigeon-generated StandardMessageCodec) and its size decisions. */
class WireTest {
  private val calls: List<EngineCall> = listOf(
    StartCall("libsherpa_engine.so", "/data/user/0/x/files/engine/engine_crash.txt", null),
    SystemInfoCall(),
    LoadModelCall(opts("/m/q.gguf").copy(modelId = "sha256:ab", chatTemplateOverride = "{{x}}"), 5, true, "ab12"),
    FreeModelCall(7),
    EstimateMemoryCall(opts(), cfg(nCtx = 8192, typeK = 8, typeV = 8)),
    CreateSessionCall(7, cfg(eventCapacity = 8)),
    FreeSessionCall(8),
    ResetSessionCall(8),
    SetThreadsCall(8, 4, 6),
    SessionInfoCall(8),
    SessionMemoryCall(8),
    GenerateCall(3, 8, """{"messages":[{"role":"user","content":"héllo 🌍"}]}"""),
    CreditCall(3, 2),
    CancelStreamCall(3),
    CancelSessionCall(8),
    CancelCall(5),
    TokenizeCall(7, "text 🌍", true, false),
    CountChatCall(7, "{}"),
    CountBatchCall(7, listOf("a", "b"), listOf("{}")),
    SaveStateCall(8, "/x.kv"),
    LoadStateCall(8, "/x.kv"),
    LoadLoraCall(7, "/l.gguf"),
    FreeLoraCall(9),
    SetLorasCall(8, listOf(9L, 10L), listOf(1.0, 0.5)),
    BenchCall(7, bench(), 0),
    ShutdownCall(),
    DebugCrashCall("abort"),
  )

  @Test fun everyCallRoundTrips() {
    for ((i, c) in calls.withIndex()) {
      val (id, back) = Wire.decodeCall(Wire.encodeCall(i.toLong() + 1, c))
      assertEquals(i.toLong() + 1, id)
      assertEquals(c.toString(), back.toString())
      if (c !is SystemInfoCall && c !is ShutdownCall) assertEquals(c, back)
    }
  }

  @Test fun typedArraysSurviveTheTrip() {
    val tokens = IntArray(100_000) { it * 7 }
    val (_, back) = Wire.decodeCall(Wire.encodeCall(1, DetokenizeCall(7, tokens, true)))
    assertArrayEquals(tokens, (back as DetokenizeCall).tokens)
  }

  @Test fun everyMessageRoundTrips() {
    val events = listOf(
      FakeEngine.ev(1, 3, text = "naïve 🌍 "),
      FakeEngine.ev(8, 3, code = 1, name = "stop", text = """{"role":"assistant","content":"x"}"""),
    )
    val exit = ProcessExitMsg(
      pid = 1234, reason = 5, reasonName = "CRASH_NATIVE", classification = "nativeCrash", status = 6,
      details = "crash", importance = 125, pssBytes = 1L shl 31, rssBytes = 3L shl 30, timestampMs = 1_700_000_000_000,
      processStateSummary = """{"v":1,"p":"generating"}""".toByteArray(), tombstone = "signal 6 (SIGABRT)",
    )
    val messages: List<InferenceMessage> = listOf(
      CallResult(1, null),
      CallResult(2, 42L),
      CallResult(3, "json"),
      CallResult(4, IntArray(3) { it }),
      CallResult(5, HandleInfoMsg((77L shl 32) or 1, "{}")),
      CallResult(6, EngineInfoMsg(1, "v", "{}", 99)),
      CallResult(7, MemoryEstimateMsg(1, 2, true, 3, 4, 5, 6, 7, 8, 9, 10)),
      CallResult(8, BenchResultMsg(1, 2, 3, 4.5, 5.5, 6.5, 7.5)),
      CallError(9, -13, "busy"),
      LoadProgress(10, 0.5),
      StreamStarted(1, 3),
      StreamFailed(1, -1, "bad"),
      EventBatch(1, events, true),
      HostStatus(HostStatusKind.EXIT_INFO, 2, 1234, "died", exit),
    )
    for (m in messages) {
      val back = Wire.decodeMessage(Wire.encodeMessage(m))
      assertEquals(m.toString().replace(Regex("\\[I@\\w+|\\[B@\\w+"), "#"), back.toString().replace(Regex("\\[I@\\w+|\\[B@\\w+"), "#"))
    }
    val batch = Wire.decodeMessage(Wire.encodeMessage(EventBatch(1, events, true))) as EventBatch
    assertEquals("naïve 🌍 ", batch.events[0].text)
    val status = Wire.decodeMessage(Wire.encodeMessage(messages.last())) as HostStatus
    assertArrayEquals(exit.processStateSummary, status.exit!!.processStateSummary)
  }

  @Test fun largePayloadsGoThroughSharedMemoryAndBatchesStayInline() {
    val longChat = "{\"messages\":[{\"role\":\"user\",\"content\":\"" + "x".repeat(500_000) + "\"}]}"
    assertTrue(Wire.useSharedMemory(Wire.encodeCall(1, GenerateCall(1, 2, longChat)).size))
    assertFalse(Wire.useSharedMemory(Wire.encodeCall(1, CreditCall(1, 1)).size))
    // A batch at the pump's byte cap is comfortably inline.
    val cap = PumpConfig().batchByteCap
    val events = List(10) { FakeEngine.ev(1, 1, text = "y".repeat(cap / 10 - 160)) }
    val bytes = Wire.encodeMessage(EventBatch(1, events, false)).size
    assertTrue("batch $bytes bytes", bytes <= cap + 1024 && !Wire.useSharedMemory(bytes))
    // Worst case in flight per stream: credits × inline max, well under half the 1 MiB Binder buffer.
    assertTrue(PumpConfig().streamCredits * Wire.INLINE_MAX <= 256 * 1024)
  }

  @Test fun packedEventsRoundTrip() {
    val events = listOf(
      FakeEngine.ev(4, 0xFFFFFFF0L, text = "{\"a\":", index = 2),
      FakeEngine.ev(7, 0xFFFFFFF0L, name = "CPU").copy(ttftMs = 12.5, decodeTps = 33.0, decodeMs = 999.0),
    )
    val back = PackedEvents.decode(PackedEvents.encode(events))
    assertEquals(events, back)
  }
}
