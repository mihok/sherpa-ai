package io.github.mihok.sherpa_litert.lm

import io.github.mihok.sherpa_litert.EventBatch
import io.github.mihok.sherpa_litert.EventKind
import io.github.mihok.sherpa_litert.LiteRtEvent
import io.github.mihok.sherpa_litert.stream.HubConfig
import io.github.mihok.sherpa_litert.stream.ManualPoster
import io.github.mihok.sherpa_litert.stream.StreamHub
import java.util.concurrent.Executor
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class FakeConversation(val spec: LmConversationSpec) : LmConversation {
  var callback: LmCallback? = null
  val sent = ArrayList<LmMessage>()
  var cancels = 0
  var closed = false
  var tokens = 0

  /** When set, cancel() answers like LiteRT-LM (onError(CancellationException) → onCancelled). */
  var answerCancel = true

  override fun send(message: LmMessage, options: LmSendOptions, callback: LmCallback) {
    check(!closed) { "Conversation is not alive." }
    sent.add(message)
    this.callback = callback
  }

  override fun cancel() {
    cancels++
    if (answerCancel) callback?.onCancelled()
  }

  override fun tokenCount(): Int = tokens

  override fun benchmark(): LmBenchmark = LmBenchmark(12, 3, 0.25, 800.0, 40.0)

  override fun close() {
    closed = true
  }
}

class FakeEngine(val config: LmEngineConfig) : LmEngine {
  val conversations = ArrayList<FakeConversation>()
  var closed = false

  override fun createConversation(spec: LmConversationSpec): LmConversation {
    check(!closed)
    return FakeConversation(spec).also { conversations.add(it) }
  }

  var templateRendersTools: Boolean? = true

  override fun rendersTools(): Boolean? = templateRendersTools

  override fun close() {
    closed = true
  }
}

class FakeRuntime : LmRuntime {
  val engines = ArrayList<FakeEngine>()
  val attempts = ArrayList<String>()
  val failing = HashMap<String, Throwable>()

  override fun loadError(): String? = null

  override fun inspect(path: String): LmModelInfo =
    LmModelInfo("llm", 32768, false, false, false, listOf("gpu", "cpu"), null, null, null, true, false, false, 1.0, 64, 0.95)

  override fun createEngine(config: LmEngineConfig): LmEngine {
    attempts.add(config.backend)
    failing[config.backend]?.let { throw it }
    return FakeEngine(config).also { engines.add(it) }
  }
}

class LmControllerTest {
  private val poster = ManualPoster()
  private val batches = ArrayList<EventBatch>()
  private val hub = StreamHub(poster, HubConfig(credits = 100)).also { h -> h.sink = { batches.add(it) } }
  private val direct = Executor { it.run() }
  private val runtime = FakeRuntime()
  private val lm = LmController(runtime, hub, direct, "/native/lib")

  private val request = LmLoadRequest(path = "/m/gemma.litertlm", backends = listOf("gpu", "cpu"), maxNumTokens = 8192)

  private fun events(streamId: Long): List<LiteRtEvent> {
    poster.runAll()
    return batches.filter { it.streamId == streamId }.flatMap { it.events }
  }

  private fun globals(): List<LiteRtEvent> {
    poster.runAll()
    return batches.filter { it.streamId == 0L }.flatMap { it.events }
  }

  private fun loadAndOpen(id: String = "c1"): FakeConversation {
    lm.load(request)
    lm.openConversation(LmConversationSpec(id = id, systemInstruction = "sys"))
    return runtime.engines.last().conversations.last()
  }

  @Test
  fun loadTriesBackendsInOrderAndReportsFailures() {
    runtime.failing["gpu"] = LmStatusException(13, "OpenCL not found")
    val result = lm.load(request)
    assertEquals("cpu", result.backend)
    assertEquals(listOf("gpu: OpenCL not found"), result.failures)
    assertFalse(result.reused)
    assertEquals(true, result.rendersTools)
    assertEquals(listOf("gpu", "cpu"), runtime.attempts)
    assertEquals("/native/lib", runtime.engines.single().config.nativeLibraryDir)
    assertEquals(8192, runtime.engines.single().config.maxNumTokens)
    val again = lm.load(request)
    assertTrue("an equal request reuses the engine", again.reused)
    assertEquals(true, again.rendersTools)
    assertEquals(1, runtime.engines.size)
  }

  @Test
  fun loadFailsWithEveryAttempt() {
    runtime.failing["gpu"] = UnsatisfiedLinkError("no libOpenCL.so")
    runtime.failing["cpu"] = LmStatusException(8, "RESOURCE_EXHAUSTED: cannot allocate")
    try {
      lm.load(request)
      fail("expected LmLoadFailedException")
    } catch (e: LmLoadFailedException) {
      assertEquals(8, e.code)
      assertEquals(2, e.failures.size)
      assertTrue(e.failures[0].startsWith("gpu: no libOpenCL.so"))
    }
    assertNull(lm.loadedBackend)
  }

  @Test
  fun loadingAnotherModelClosesTheOldEngineAndConversations() {
    val c = loadAndOpen()
    lm.load(request.copy(path = "/m/qwen.litertlm"))
    assertTrue(runtime.engines[0].closed)
    assertTrue(c.closed)
    assertEquals(listOf("reload"), globals().map { it.detail })
  }

  @Test
  fun openConversationNeedsAnEngine() {
    try {
      lm.openConversation(LmConversationSpec(id = "x"))
      fail("expected LmStatusException")
    } catch (e: LmStatusException) {
      assertEquals(9, e.code)
    }
  }

  @Test
  fun openReplacesAConversationWithTheSameId() {
    val first = loadAndOpen("c1")
    lm.openConversation(LmConversationSpec(id = "c1", history = listOf(LmMessage("user", "hi"))))
    assertTrue(first.closed)
    assertEquals(setOf("c1"), lm.conversationIds)
    assertEquals("hi", runtime.engines.single().conversations.last().spec.history.single().text)
  }

  @Test
  fun aTurnStreamsDeltasThenDoneWithStats() {
    val c = loadAndOpen()
    c.tokens = 40
    lm.send(7, "c1", LmMessage("user", "Hi"), LmSendOptions(maxOutputTokens = 64))
    assertTrue(lm.isGenerating)
    val cb = c.callback!!
    cb.onThought("let me think")
    cb.onText("Hel")
    cb.onText("lo")
    cb.onToolCalls(listOf(LmToolCall("get_weather", "{\"city\":\"Oslo\"}")))
    c.tokens = 55
    cb.onDone()
    assertFalse(lm.isGenerating)
    val ev = events(7)
    assertEquals(
      listOf(EventKind.REASONING_DELTA, EventKind.TEXT_DELTA, EventKind.TOOL_CALLS, EventKind.DONE),
      ev.map { it.kind },
    )
    assertEquals("Hello", ev[1].text)
    assertEquals("get_weather", ev[2].toolCalls!!.single().name)
    val stats = ev.last().stats!!
    assertEquals(12L, stats.prefillTokens)
    assertEquals(3L, stats.decodeTokens)
    assertTrue("TTFT is measured per turn", checkNotNull(stats.timeToFirstTokenMs) >= 0.0)
    assertEquals(40L, stats.kvTokensBefore)
    assertEquals(55L, stats.kvTokensAfter)
    assertEquals("gpu", stats.backend)
  }

  @Test
  fun cancelStopsAtTheNextTokenAndEchoesTheReason() {
    val c = loadAndOpen()
    lm.send(1, "c1", LmMessage("user", "Story"), LmSendOptions())
    c.callback!!.onText("Once")
    poster.runAll()
    assertTrue(lm.cancel(1, "user"))
    assertEquals(1, c.cancels)
    c.callback!!.onText("upon a time") // after the cancel: dropped
    val ev = events(1)
    assertEquals(listOf(EventKind.TEXT_DELTA, EventKind.CANCELLED), ev.map { it.kind })
    assertEquals("user", ev.last().detail)
    assertFalse(lm.cancel(1, "user"))
  }

  @Test
  fun aCancelledStatusAfterACancelIsACancelNotAnError() {
    val c = loadAndOpen()
    c.answerCancel = false
    lm.send(1, "c1", LmMessage("user", "x"), LmSendOptions())
    lm.cancel(1, "user")
    c.callback!!.onError(LmStatusException(1, "CANCELLED"))
    assertEquals(EventKind.CANCELLED, events(1).last().kind)
  }

  @Test
  fun errorsCarryTheNativeStatus() {
    val c = loadAndOpen()
    lm.send(1, "c1", LmMessage("user", "x"), LmSendOptions())
    c.callback!!.onError(LmStatusException(3, "Input token ids are too long"))
    val e = events(1).single()
    assertEquals(EventKind.ERROR, e.kind)
    val err = checkNotNull(e.error)
    assertEquals("litert", err.source)
    assertEquals(3L, err.code)
    assertEquals("Input token ids are too long", err.message)
  }

  @Test
  fun sendFailsCleanlyForAnUnknownConversationOrABusyEngine() {
    val c = loadAndOpen()
    lm.send(1, "nope", LmMessage("user", "x"), LmSendOptions())
    assertEquals("state", events(1).single().error?.source)
    lm.send(2, "c1", LmMessage("user", "x"), LmSendOptions())
    lm.send(3, "c1", LmMessage("user", "y"), LmSendOptions())
    assertTrue(events(3).single().error?.message.orEmpty().contains("being generated"))
    c.callback!!.onDone()
    assertEquals(EventKind.DONE, events(2).last().kind)
  }

  @Test
  fun trimMemoryBelowTheThresholdDoesNothing() {
    loadAndOpen()
    lm.onTrimMemory(20, 40)
    lm.onTrimMemory(80, 0)
    assertEquals("gpu", lm.loadedBackend)
  }

  @Test
  fun trimMemoryStopsTheRunningTurnThenFreesTheEngine() {
    val c = loadAndOpen()
    c.answerCancel = false
    lm.send(9, "c1", LmMessage("user", "Long"), LmSendOptions())
    c.callback!!.onText("Partial")
    lm.onTrimMemory(40, 40)
    assertEquals(1, c.cancels)
    assertFalse("not freed while the native turn is still running", runtime.engines.single().closed)
    c.callback!!.onCancelled()
    assertTrue(runtime.engines.single().closed)
    assertTrue(c.closed)
    assertNull(lm.loadedBackend)
    val ev = events(9)
    assertEquals(EventKind.CANCELLED, ev.last().kind)
    assertEquals(LmController.REASON_MEMORY, ev.last().detail)
    assertEquals(listOf(LmController.REASON_MEMORY), globals().map { it.detail })
  }

  @Test
  fun trimMemoryWhileIdleFreesAtOnce() {
    val c = loadAndOpen()
    lm.onTrimMemory(40, 40)
    assertTrue(c.closed)
    assertTrue(runtime.engines.single().closed)
    assertEquals(EventKind.ENGINE_RELEASED, globals().single().kind)
    lm.onTrimMemory(40, 40) // nothing left: no second event
    assertEquals(1, globals().size)
  }

  @Test
  fun statusMessagesAreParsed() {
    val e = LmStatusException.parse("Status Code: 8. Message: RESOURCE_EXHAUSTED: out of memory")
    assertEquals(8, e.code)
    assertEquals("RESOURCE_EXHAUSTED: out of memory", e.message)
    assertEquals(-1, LmStatusException.parse("Failed to load model info").code)
  }

  @Test
  fun jsonArgumentsRoundTripWithoutWideningNumbers() {
    val json = """{"city":"Oslo","days":3,"temp":21.5,"tags":["a",true,null],"nested":{"k":1}}"""
    val map = JsonValues.decodeObject(json)
    assertEquals(json, JsonValues.encode(map))
    assertEquals(emptyMap<String, Any?>(), JsonValues.decodeObject(""))
  }
}
