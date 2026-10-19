package io.github.mihok.sherpa_inference.engine

import io.github.mihok.sherpa_inference.CallError
import io.github.mihok.sherpa_inference.CancelCall
import io.github.mihok.sherpa_inference.CancelSessionCall
import io.github.mihok.sherpa_inference.CancelStreamCall
import io.github.mihok.sherpa_inference.CountBatchCall
import io.github.mihok.sherpa_inference.CreateSessionCall
import io.github.mihok.sherpa_inference.CreditCall
import io.github.mihok.sherpa_inference.DebugCrashCall
import io.github.mihok.sherpa_inference.EngineInfoMsg
import io.github.mihok.sherpa_inference.EventBatch
import io.github.mihok.sherpa_inference.FreeModelCall
import io.github.mihok.sherpa_inference.FreeSessionCall
import io.github.mihok.sherpa_inference.GenerateCall
import io.github.mihok.sherpa_inference.HandleInfoMsg
import io.github.mihok.sherpa_inference.LoadModelCall
import io.github.mihok.sherpa_inference.LoadProgress
import io.github.mihok.sherpa_inference.ResetSessionCall
import io.github.mihok.sherpa_inference.SaveStateCall
import io.github.mihok.sherpa_inference.SessionInfoCall
import io.github.mihok.sherpa_inference.SetThreadsCall
import io.github.mihok.sherpa_inference.ShutdownCall
import io.github.mihok.sherpa_inference.StartCall
import io.github.mihok.sherpa_inference.StreamStarted
import io.github.mihok.sherpa_inference.SystemInfoCall
import io.github.mihok.sherpa_inference.TokenizeCall
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicLong

/** The service-side dispatcher against [FakeEngine]: ordering, flow control, cancellation, handles. */
class EngineCoreTest {
  private val ids = AtomicLong(100)
  private val rec = Recorder()
  private val phases = ArrayList<String>()
  private lateinit var engine: FakeEngine
  private lateinit var core: EngineCore

  private fun setUp(
    engine: FakeEngine = FakeEngine(),
    pump: PumpConfig = PumpConfig(),
    debuggable: Boolean = false,
  ): EngineCore {
    this.engine = engine
    core = EngineCore(engine, rec::sink, pid = 4242, phases = PhaseTracker { synchronized(phases) { phases.add(it) } }, pumpConfig = pump, debuggable = debuggable, idleWaitMs = 100)
    return core
  }

  @After fun tearDown() {
    if (::core.isInitialized) core.shutdown(2000)
  }

  private fun call(c: io.github.mihok.sherpa_inference.EngineCall): Long = ids.incrementAndGet().also { core.submit(it, c) }

  private fun started(): EngineInfoMsg = rec.result(call(StartCall("libsherpa_engine.so", "/tmp/crash.txt"))) as EngineInfoMsg

  private fun model(path: String = "/models/m.gguf"): Long =
    (rec.result(call(LoadModelCall(opts(path), 0, false, "tag1"))) as HandleInfoMsg).handle

  private fun session(model: Long, eventCapacity: Long = 0): Long =
    (rec.result(call(CreateSessionCall(model, cfg(eventCapacity = eventCapacity)))) as HandleInfoMsg).handle

  private fun generate(stream: Long, session: Long, json: String = "{}") = core.submit(0, GenerateCall(stream, session, json))

  /** Grants credits as batches arrive (an unpaused consumer). */
  private fun consume(stream: Long): EventBatch {
    var granted = 0
    while (true) {
      val batches = rec.batches(stream)
      while (granted < batches.size) {
        core.submit(0, CreditCall(stream, 1))
        granted++
      }
      batches.lastOrNull()?.takeIf { it.last }?.let { return it }
      Thread.sleep(2)
    }
  }

  @Test fun startOpensTheEngineOnceAndReportsThePid() {
    setUp()
    val info = started()
    assertEquals(1L, info.abiVersion)
    assertEquals(4242L, info.pid)
    assertEquals("fake 1.0", info.version)
    started()
    assertEquals(1, engine.calls.count { it == "open" })
    assertTrue(engine.calls.contains("backendInit:/tmp/crash.txt"))
    assertEquals("""{"backends":["CPU"]}""", rec.result(call(SystemInfoCall())))
  }

  @Test fun anUnavailableEngineIsAnUnsupportedError() {
    setUp()
    val e = rec.error(call(StartCall("missing")))
    assertEquals(EngineError.UNSUPPORTED.toLong(), e.code)
    assertTrue(e.message.contains("dlopen"))
    assertEquals(EngineError.UNSUPPORTED.toLong(), rec.error(call(LoadModelCall(opts(), 0, false, "t"))).code)
  }

  @Test fun aGenerationStreamsEveryEventInOrderEndingWithOneFinish() {
    setUp()
    started()
    val s = session(model())
    generate(1, s)
    rec.started(1)
    consume(1)
    val events = rec.events(1)
    assertEquals("Hello world!", rec.text(1))
    assertEquals(1, events.count { it.type == EventTypes.FINISH })
    assertEquals(EventTypes.FINISH, events.last().type)
    val types = events.map { it.type }
    assertTrue(types.indexOf(EventTypes.USAGE) < types.indexOf(EventTypes.FINISH))
    assertTrue(types.indexOf(EventTypes.PERF) < types.indexOf(EventTypes.FINISH))
    assertTrue("only the last batch is last", rec.batches(1).dropLast(1).none { it.last })
  }

  @Test fun handlesAreSaltedIdsNotPointers() {
    setUp()
    started()
    val m = model()
    assertTrue("salt in the high bits", (m ushr 32) > 0)
    assertTrue(engine.sessions.keys.none { it == m })
    // Two service instances (before/after a restart) never mint the same id for the same slot.
    assertNotEquals(HandleTable<Unit>("t", salt = 1).add(5, Unit), HandleTable<Unit>("t", salt = 2).add(5, Unit))
    val e = rec.error(call(TokenizeCall(m xor (1L shl 40), "hi", false, false)))
    assertEquals(EngineError.INVALID_ARG.toLong(), e.code)
    assertTrue(e.message.contains("unknown"))
  }

  @Test fun pausedConsumerBoundsBatchesInFlightAndBlocksTheEngine() {
    // A paused Dart subscription returns no credits: the pump must stop after streamCredits batches, stop
    // polling, and the engine worker must block on its full ring (no queue grows anywhere).
    val deltas = List(200) { "t$it " }
    setUp(FakeEngine(ringCapacity = 8, tokenDelayMs = 1, script = { deltas }), PumpConfig(coalesceWindowMs = 1))
    started()
    val s = session(model())
    generate(1, s)
    rec.started(1)
    assertTrue("engine worker blocked on a full ring", engine.awaitBlocked(engine.sessions.keys.first()))
    Thread.sleep(200)
    val inFlight = rec.batches(1).size
    assertTrue("at most 4 batches without credit, got $inFlight", inFlight in 1..4)
    assertTrue(engine.sessions.values.first().blockedOnFullRing)
    // Resume: everything arrives, nothing dropped.
    consume(1)
    assertEquals(deltas.joinToString(""), rec.text(1))
    assertTrue(engine.sessions.values.first().blockedMs >= 150)
  }

  @Test fun batchesRespectTheByteCapExceptForASingleLargeEvent() {
    val big = "x".repeat(40_000)
    val deltas = List(300) { "0123456789".repeat(10) } + big
    setUp(FakeEngine(ringCapacity = 64, script = { deltas }), PumpConfig(batchByteCap = 4096, coalesceWindowMs = 50))
    started()
    val s = session(model())
    // Let the ring fill before the first credit so the pump sees lots of events at once.
    generate(1, s)
    rec.started(1)
    consume(1)
    assertEquals(deltas.joinToString(""), rec.text(1))
    for (b in rec.batches(1)) {
      val size = b.events.sumOf { EventPump.sizeOf(it) }
      assertTrue("batch of $size bytes (${b.events.size} events) over the cap", size <= 4096 + 160 || b.events.size == 1)
    }
    assertTrue("the oversized delta travelled alone", rec.batches(1).any { b -> b.events.size == 1 && b.events[0].text == big })
    assertTrue(rec.batches(1).size > 3)
  }

  @Test fun sessionCallsRunInArrivalOrderWhileOtherSessionsProceed() {
    setUp()
    started()
    val m = model()
    val a = session(m)
    val b = session(m)
    val gate = CountDownLatch(1)
    engine.calls.clear()
    engine.onSessionCall = { if (it == "setThreads:1") gate.await() }
    val first = call(SetThreadsCall(a, 1, 1))
    val second = call(SessionInfoCall(a))
    val third = call(ResetSessionCall(a))
    // Session b is not stuck behind a's blocked call.
    rec.result(call(SetThreadsCall(b, 2, 2)))
    Thread.sleep(50)
    assertFalse(rec.all.any { it is io.github.mihok.sherpa_inference.CallResult && it.requestId in setOf(first, second, third) })
    gate.countDown()
    rec.result(first)
    rec.result(second)
    rec.result(third)
    val order = engine.calls.filter { it.startsWith("setThreads:1") || it == "sessionInfo" || it.startsWith("reset") }
    assertEquals(listOf("setThreads:1", "sessionInfo", "reset"), order.map { it.substringBefore('@') })
  }

  @Test fun sessionCallsDuringAGenerationAreBusy() {
    setUp(FakeEngine(tokenDelayMs = 100, script = { List(30) { "x" } }))
    started()
    val s = session(model())
    generate(1, s)
    rec.started(1)
    val e = rec.error(call(ResetSessionCall(s)))
    assertEquals(EngineError.BUSY.toLong(), e.code)
    core.submit(0, CancelSessionCall(s))
    consume(1)
  }

  @Test fun cancelGenerationEndsWithFinishCancelled() {
    setUp(FakeEngine(tokenDelayMs = 20, script = { List(200) { "x" } }))
    started()
    val s = session(model())
    generate(1, s)
    rec.started(1)
    Thread.sleep(60)
    core.submit(0, CancelSessionCall(s))
    val last = consume(1)
    assertEquals("cancelled", last.events.last().name)
    assertEquals(1, rec.events(1).count { it.type == EventTypes.FINISH })
  }

  @Test fun aCancelledStreamDrainsAndTheNextGenerationWaitsForIt() {
    setUp(FakeEngine(tokenDelayMs = 10, script = { json -> if (json == "{}") List(100) { "a" } else listOf("b") }))
    started()
    val s = session(model())
    generate(1, s)
    rec.started(1)
    Thread.sleep(30)
    core.submit(0, CancelStreamCall(1))
    val before = rec.batches(1).size
    generate(2, s, """{"second":true}""")
    rec.started(2)
    consume(2)
    assertEquals("b", rec.text(2))
    Thread.sleep(50)
    assertEquals("nothing of the cancelled stream after the cancel", before, rec.batches(1).size)
    assertEquals(2, engine.calls.count { it == "generate" })
  }

  @Test fun aStreamCancelledBeforeItsStartRanNeverStarts() {
    setUp()
    started()
    val s = session(model())
    val gate = CountDownLatch(1)
    engine.onSessionCall = { if (it == "setThreads:3") gate.await() }
    val blocker = call(SetThreadsCall(s, 3, 3))
    generate(7, s)
    core.submit(0, CancelStreamCall(7))
    gate.countDown()
    rec.result(blocker)
    rec.result(call(SessionInfoCall(s)))
    Thread.sleep(50)
    assertEquals(0, engine.calls.count { it == "generate" })
    assertTrue(rec.all.none { it is StreamStarted && it.streamId == 7L })
  }

  @Test fun aRefusedStartIsAStreamFailure() {
    setUp()
    started()
    val s = session(model())
    generate(1, s, "not json")
    assertEquals(EngineError.INVALID_ARG.toLong(), rec.failed(1).code)
    generate(2, s)
    consume(2)
  }

  @Test fun freeingASessionFailsItsStreamAndForgetsTheHandle() {
    setUp(FakeEngine(tokenDelayMs = 20, script = { List(100) { "x" } }))
    started()
    val s = session(model())
    generate(1, s)
    rec.started(1)
    rec.result(call(FreeSessionCall(s)))
    assertEquals(EngineError.INVALID_ARG.toLong(), rec.failed(1).code)
    assertEquals(EngineError.INVALID_ARG.toLong(), rec.error(call(SessionInfoCall(s))).code)
    assertTrue(engine.calls.contains("sessionFree"))
  }

  @Test fun freeWhileAnotherThreadUsesTheModelIsDeferred() {
    setUp()
    started()
    val m = model()
    val inside = CountDownLatch(1)
    val release = CountDownLatch(1)
    engine.onTokenize = {
      inside.countDown()
      release.await()
    }
    val tok = call(TokenizeCall(m, "abc", false, false))
    inside.awaitOrFail()
    rec.result(call(FreeModelCall(m)))
    assertTrue("not freed while tokenize runs", engine.freed.isEmpty())
    release.countDown()
    rec.result(tok)
    Thread.sleep(20)
    assertEquals(1, engine.freed.size)
    assertEquals(EngineError.INVALID_ARG.toLong(), rec.error(call(TokenizeCall(m, "x", false, false))).code)
  }

  @Test fun loadProgressAndCancellation() {
    setUp(FakeEngine().apply { loadBlocksUntilCancelled = true })
    started()
    val id = call(LoadModelCall(opts(), 77, true, "t"))
    val p = rec.await<LoadProgress> { it is LoadProgress && it.requestId == id }
    assertEquals(0.0, p.progress, 0.0)
    core.submit(0, CancelCall(77))
    assertEquals(EngineError.CANCELLED.toLong(), rec.error(id).code)
    val progress = rec.all.filterIsInstance<LoadProgress>().map { it.progress }
    assertEquals(listOf(0.0, 0.25, 0.5, 1.0), progress)
    assertTrue("canceller freed", engine.cancellers.isEmpty())
  }

  @Test fun countBatchAnswersEveryItemInOneReply() {
    setUp()
    started()
    val m = model()
    val r = rec.result(call(CountBatchCall(m, listOf("ab", "bad", "abcd"), listOf("{}", "nope")))) as IntArray
    assertEquals(listOf(2, -1, 4, 2, -1), r.toList())
  }

  @Test fun stateSaveReturnsTheFileSize() {
    setUp()
    started()
    val s = session(model())
    val f = java.io.File.createTempFile("state", ".kv")
    try {
      assertEquals(1234L, rec.result(call(SaveStateCall(s, f.path))))
    } finally {
      f.delete()
    }
  }

  @Test fun phasesAreSummarizedForTheProcessStateSummary() {
    setUp()
    started()
    val s = session(model())
    generate(1, s)
    consume(1)
    Thread.sleep(20)
    val seen = synchronized(phases) { phases.toList() }
    assertTrue(seen.any { it.contains("\"p\":\"loading\"") && it.contains("\"m\":\"tag1\"") })
    assertTrue(seen.any { it.contains("\"p\":\"generating\"") && it.contains("\"c\":4096") && it.contains("f16/q8_0") })
    assertEquals("""{"v":1,"p":"idle","h":"proc"}""", seen.last())
    assertTrue(seen.all { it.toByteArray().size <= 128 })
  }

  @Test fun shutdownFreesEveryHandleAndRefusesLaterCalls() {
    setUp()
    started()
    val m = model()
    session(m)
    rec.result(call(ShutdownCall()))
    assertEquals(0, core.liveHandles())
    assertTrue(engine.calls.contains("sessionFree"))
    assertTrue(engine.calls.contains("modelFree"))
    assertEquals(EngineError.UNSUPPORTED.toLong(), rec.error(call(SystemInfoCall())).code)
  }

  @Test fun debugCrashesNeedADebuggableBuild() {
    setUp()
    val e = rec.error(call(DebugCrashCall("abort")))
    assertEquals(EngineError.UNSUPPORTED.toLong(), e.code)
    core.shutdown(1000)
    setUp(debuggable = true)
    core.submit(1, DebugCrashCall("segv"))
    Thread.sleep(20)
    assertTrue(engine.calls.contains("debugCrash:1"))
    assertTrue(rec.all.none { it is CallError && it.requestId == 1L })
  }
}
