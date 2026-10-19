package io.github.mihok.sherpa_inference.engine

import io.github.mihok.sherpa_inference.BenchCall
import io.github.mihok.sherpa_inference.BenchResultMsg
import io.github.mihok.sherpa_inference.CancelCall
import io.github.mihok.sherpa_inference.CancelSessionCall
import io.github.mihok.sherpa_inference.CountBatchCall
import io.github.mihok.sherpa_inference.CountChatCall
import io.github.mihok.sherpa_inference.CreateSessionCall
import io.github.mihok.sherpa_inference.CreditCall
import io.github.mihok.sherpa_inference.DetokenizeCall
import io.github.mihok.sherpa_inference.EngineCall
import io.github.mihok.sherpa_inference.EngineEventMsg
import io.github.mihok.sherpa_inference.EngineInfoMsg
import io.github.mihok.sherpa_inference.EstimateMemoryCall
import io.github.mihok.sherpa_inference.EventBatch
import io.github.mihok.sherpa_inference.FreeModelCall
import io.github.mihok.sherpa_inference.FreeSessionCall
import io.github.mihok.sherpa_inference.GenerateCall
import io.github.mihok.sherpa_inference.HandleInfoMsg
import io.github.mihok.sherpa_inference.LoadModelCall
import io.github.mihok.sherpa_inference.LoadProgress
import io.github.mihok.sherpa_inference.LoadStateCall
import io.github.mihok.sherpa_inference.MemoryEstimateMsg
import io.github.mihok.sherpa_inference.ResetSessionCall
import io.github.mihok.sherpa_inference.SaveStateCall
import io.github.mihok.sherpa_inference.SessionInfoCall
import io.github.mihok.sherpa_inference.StartCall
import io.github.mihok.sherpa_inference.SystemInfoCall
import io.github.mihok.sherpa_inference.TokenizeCall
import io.github.mihok.sherpa_inference.Wire
import org.junit.AfterClass
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.BeforeClass
import org.junit.FixMethodOrder
import org.junit.Test
import org.junit.runners.MethodSorters
import java.io.File
import java.util.concurrent.atomic.AtomicLong

/**
 * The real thing minus Binder: the JNI shim (tool/build_host_jni.sh, loaded with System.load) driving the
 * host-built libsherpa_engine.so and Qwen3-0.6B through the same [EngineCore] + [EventPump] the
 * `:inference` service runs, with every message passed through the [Wire] codec like a Binder hop.
 * Skips when the shim, engine or model is missing (SHERPA_JNI_LIB / sherpa.hostJni, SHERPA_ENGINE_LIB,
 * SHERPA_TEST_MODEL; SHERPA_TEST_THREADS, default 2).
 */
@FixMethodOrder(MethodSorters.NAME_ASCENDING)
class JniEngineHostTest {
  companion object {
    private val jniLib = System.getProperty("sherpa.hostJni") ?: System.getenv("SHERPA_JNI_LIB")
    private val engineLib = System.getenv("SHERPA_ENGINE_LIB")?.takeIf { it.isNotEmpty() }
      ?: "/opt/vendor-src/sherpa-engine-build/host-shared/libsherpa_engine.so"
    private val modelPath = System.getenv("SHERPA_TEST_MODEL")?.takeIf { it.isNotEmpty() } ?: "/opt/models/Qwen3-0.6B-Q4_K_M.gguf"
    private val threads = System.getenv("SHERPA_TEST_THREADS")?.toLongOrNull() ?: 2L

    private val rec = Recorder()
    private var core: EngineCore? = null
    private var model = 0L
    private val ids = AtomicLong(1000)
    private val streams = AtomicLong(1)
    private val tmp = File(System.getProperty("java.io.tmpdir"), "sherpa-jni-test-${System.nanoTime()}")
    private val perf = ArrayList<String>()

    private fun available(): Boolean =
      jniLib != null && File(jniLib).isFile && File(engineLib).isFile && File(modelPath).isFile

    @BeforeClass @JvmStatic fun load() {
      if (!available()) return
      NativeEngine.load(jniLib)
      tmp.mkdirs()
      // Every message crosses the Wire codec, as it would cross Binder.
      core = EngineCore(JniEngine(), { m -> rec.sink(Wire.decodeMessage(Wire.encodeMessage(m))) }, pid = 1, phases = PhaseTracker {})
    }

    @AfterClass @JvmStatic fun unload() {
      core?.shutdown()
      tmp.deleteRecursively()
      if (perf.isNotEmpty()) {
        println("\nsherpa_inference JNI path (host, $threads threads, ${File(modelPath).name})")
        perf.forEach(::println)
      }
    }
  }

  private fun core(): EngineCore {
    assumeTrue("no host JNI shim / engine / model (run tool/build_host_jni.sh)", available())
    return core!!
  }

  private fun call(c: EngineCall): Long = ids.incrementAndGet().also {
    val (id, decoded) = Wire.decodeCall(Wire.encodeCall(it, c))
    core().submit(id, decoded)
  }

  private fun ensureModel(): Long {
    core()
    if (model == 0L) {
      rec.result(call(StartCall(engineLib, File(tmp, "engine_crash.txt").path)))
      model = (rec.result(call(LoadModelCall(opts(modelPath), 0, false, "qwen3"))) as HandleInfoMsg).handle
    }
    return model
  }

  private fun session(nCtx: Long = 1024, eventCapacity: Long = 0): Long =
    (rec.result(call(CreateSessionCall(ensureModel(), cfg(nCtx = nCtx, eventCapacity = eventCapacity, nThreads = threads, seed = 42)))) as HandleInfoMsg).handle

  private fun request(content: String, maxTokens: Int) =
    """{"messages":[{"role":"user","content":"$content"}],"max_tokens":$maxTokens,"temperature":0,"enable_thinking":false,"seed":42}"""

  /** Runs one generation as an unpaused consumer (one credit per batch); [onBatch] may cancel or pause. */
  private fun generate(session: Long, json: String, pauseAfterFirstMs: Long = 0, onBatch: (Long, Int) -> Unit = { _, _ -> }): Pair<Long, List<EngineEventMsg>> {
    val stream = streams.incrementAndGet()
    core().submit(0, GenerateCall(stream, session, json))
    rec.started(stream)
    var granted = 0
    val deadline = System.currentTimeMillis() + 120_000
    while (System.currentTimeMillis() < deadline) {
      val batches = rec.batches(stream)
      while (granted < batches.size) {
        onBatch(stream, granted)
        if (granted == 0 && pauseAfterFirstMs > 0) Thread.sleep(pauseAfterFirstMs)
        core().submit(0, CreditCall(stream, 1))
        granted++
      }
      if (batches.lastOrNull()?.last == true) return stream to rec.events(stream)
      Thread.sleep(1)
    }
    throw AssertionError("generation did not finish")
  }

  @Test fun a_startOpensTheRealEngine() {
    core()
    val info = rec.result(call(StartCall(engineLib, File(tmp, "engine_crash.txt").path))) as EngineInfoMsg
    assertEquals(1L, info.abiVersion)
    assertTrue(info.version, info.version.startsWith("sherpa_engine"))
    assertTrue(info.systemInfoJson.contains("backends"))
    assertTrue((rec.result(call(SystemInfoCall())) as String).contains("CPU"))
  }

  @Test fun b_estimateAndLoadWithProgress() {
    core()
    rec.result(call(StartCall(engineLib, null)))
    val est = rec.result(call(EstimateMemoryCall(opts(modelPath), cfg(nCtx = 2048, nThreads = threads)))) as MemoryEstimateMsg
    assertTrue(est.totalBytes > est.kvBytes && est.kvBytes > 0)
    val t0 = System.nanoTime()
    val id = call(LoadModelCall(opts(modelPath), 0, true, "qwen3"))
    val loaded = rec.result(id, 120_000) as HandleInfoMsg
    perf.add("| model load (mmap, progress over the codec) | ${(System.nanoTime() - t0) / 1_000_000} ms |")
    assertTrue(loaded.infoJson.contains("qwen3"))
    val progress = rec.all.filterIsInstance<LoadProgress>().filter { it.requestId == id }.map { it.progress }
    assertTrue("progress reported: $progress", progress.isNotEmpty() && progress.last() >= 0.99)
    rec.result(call(FreeModelCall(loaded.handle)))
  }

  @Test fun c_tokensRoundTripAndCountsInOneHop() {
    val m = ensureModel()
    val tokens = rec.result(call(TokenizeCall(m, "Hello world 🌍", false, false))) as IntArray
    assertTrue(tokens.isNotEmpty())
    assertEquals("Hello world 🌍", rec.result(call(DetokenizeCall(m, tokens, false))))
    val chat = request("hi", 4)
    val n = rec.result(call(CountChatCall(m, chat))) as Long
    assertTrue(n > 3)
    val batch = rec.result(call(CountBatchCall(m, listOf("Hello world 🌍", ""), listOf(chat, "not json")))) as IntArray
    assertEquals(listOf(tokens.size, 0, n.toInt()), batch.take(3))
    assertTrue("a bad item is a negative status", batch[3] < 0)
  }

  @Test fun d_generatesAShortReply() {
    val s = session()
    val info = rec.result(call(SessionInfoCall(s))) as String
    assertTrue(info, info.contains("\"n_ctx\":1024"))
    val (stream, events) = generate(s, request("Say hello in five words.", 24))
    val text = events.filter { it.type == EventTypes.TEXT_DELTA }.joinToString("") { it.text }
    println("reply: ${text.replace('\n', ' ')} | finish ${events.last().name}")
    assertTrue(text.isNotBlank())
    val types = events.map { it.type }
    assertEquals(1, types.count { it == EventTypes.FINISH })
    assertEquals(EventTypes.FINISH, types.last())
    assertTrue(types.indexOf(EventTypes.USAGE) < types.indexOf(EventTypes.FINISH))
    assertTrue(types.indexOf(EventTypes.PERF) < types.indexOf(EventTypes.FINISH))
    val p = events.first { it.type == EventTypes.PERF }
    val usage = events.first { it.type == EventTypes.USAGE }
    perf.add("| plain reply: prompt ${usage.promptTokens}, TTFT ${"%.0f".format(p.ttftMs)} ms, prefill ${"%.1f".format(p.prefillTps)} t/s, decode ${"%.1f".format(p.decodeTps)} t/s, ${rec.batches(stream).size} batches for ${usage.completionTokens} tokens |")
    rec.result(call(FreeSessionCall(s)))
  }

  @Test fun e_cancelStopsPromptlyAndTheSessionIsReusable() {
    val s = session()
    var cancelAt = 0L
    val (_, events) = generate(s, request("Write a long story about a lighthouse keeper.", 400)) { stream, _ ->
      // Like the FFI integration test: cancel once three deltas arrived.
      val deltas = rec.events(stream).count { it.type == EventTypes.TEXT_DELTA && it.text.isNotEmpty() }
      if (cancelAt == 0L && rec.events(stream).sumOf { if (it.type == EventTypes.TEXT_DELTA) it.text.length else 0 } >= 12 && deltas >= 1) {
        cancelAt = System.nanoTime()
        core().submit(0, CancelSessionCall(s))
      }
    }
    val latencyMs = (System.nanoTime() - cancelAt) / 1_000_000
    val story = events.filter { it.type == EventTypes.TEXT_DELTA }.joinToString("") { it.text }
    assertTrue("cancel was sent", cancelAt != 0L)
    assertEquals("story so far: $story", "cancelled", events.last().name)
    assertTrue("cancel took $latencyMs ms", latencyMs < 1500)
    perf.add("| cancel → FINISH(cancelled) | $latencyMs ms |")
    val (_, next) = generate(s, request("Hi", 4))
    assertEquals(1, next.count { it.type == EventTypes.FINISH })
    rec.result(call(FreeSessionCall(s)))
  }

  @Test fun f_pausedConsumerBlocksDecodingWithoutLosingEvents() {
    // Same proof as the FFI integration test, made independent of machine load: with an 8-slot ring and
    // no credits returned, the engine worker must block, so its own decode clock (decode_ms) covers the
    // whole pause. The pause is 2.5x the unpaused decode time, so an engine that kept decoding into an
    // unbounded queue would have finished well inside it (decode_ms ~ reference < pause).
    val s = session(nCtx = 512, eventCapacity = 8)
    val body = request("Write the numbers from 1 to 40 separated by commas.", 40)
    val (_, reference) = generate(s, body)
    val refDecode = reference.first { it.type == EventTypes.PERF }.decodeMs
    val pauseMs = maxOf(3000L, (refDecode * 2.5).toLong()).coerceAtMost(30_000)
    rec.result(call(ResetSessionCall(s)))
    val (stream, paused) = generate(s, body, pauseAfterFirstMs = pauseMs)
    fun text(ev: List<EngineEventMsg>) = ev.filter { it.type == EventTypes.TEXT_DELTA }.joinToString("") { it.text }
    assertEquals("no event was dropped", text(reference), text(paused))
    val usage = paused.first { it.type == EventTypes.USAGE }
    assertTrue("long enough to fill the ring: ${usage.completionTokens}", usage.completionTokens >= 30)
    val decode = paused.first { it.type == EventTypes.PERF }.decodeMs
    assertTrue("decode_ms $decode must cover the ${pauseMs} ms pause (reference $refDecode)", decode >= pauseMs * 0.8)
    assertTrue("bounded batches", rec.batches(stream).size >= 2)
    perf.add("| backpressure: decode_ms ${"%.0f".format(refDecode)} → ${"%.0f".format(decode)} with a $pauseMs ms pause (8-slot ring) |")
    rec.result(call(FreeSessionCall(s)))
  }

  @Test fun g_stateSaveAndLoadRestoreTheCache() {
    val s1 = session()
    val body = request("The capital of France is", 2)
    generate(s1, body)
    val path = File(tmp, "direct.kv").path
    val bytes = rec.result(call(SaveStateCall(s1, path))) as Long
    assertTrue(bytes > 0 && bytes == File(path).length())
    rec.result(call(FreeSessionCall(s1)))
    val s2 = session()
    val n = rec.result(call(LoadStateCall(s2, path))) as Long
    assertTrue(n > 0)
    val (_, events) = generate(s2, body)
    assertTrue(events.first { it.type == EventTypes.USAGE }.cachedTokens > 0)
    val s3 = (rec.result(call(CreateSessionCall(ensureModel(), cfg(nCtx = 1024, nThreads = threads, typeK = 8, typeV = 8)))) as HandleInfoMsg).handle
    assertEquals(-12L, rec.error(call(LoadStateCall(s3, path))).code)
    rec.result(call(FreeSessionCall(s2)))
    rec.result(call(FreeSessionCall(s3)))
  }

  @Test fun h_benchAndCancelledBench() {
    val m = ensureModel()
    val r = rec.result(call(BenchCall(m, bench(nThreads = threads, nPrompt = 32, nGen = 8), 0)), 120_000) as BenchResultMsg
    assertTrue(r.promptTokensPerSec > 0 && r.genTokensPerSec > 0)
    perf.add("| bench pp32/tg8: ${"%.1f".format(r.promptTokensPerSec)} / ${"%.1f".format(r.genTokensPerSec)} t/s |")
    val id = call(BenchCall(m, bench(nThreads = threads, nPrompt = 512, nGen = 256), 99))
    Thread.sleep(100)
    core().submit(0, CancelCall(99))
    assertEquals(EngineError.CANCELLED.toLong(), rec.error(id, 60_000).code)
  }

  /**
   * The workload the README compares with FfiEngineHost: a small call's round trip (dispatcher + pool + JNI
   * + the Wire codec both ways, as across Binder; no Binder itself) and a fixed greedy 40-token reply.
   */
  @Test fun j_latencyWorkload() {
    ensureModel()
    val replies = java.util.concurrent.LinkedBlockingQueue<io.github.mihok.sherpa_inference.InferenceMessage>()
    val bench = EngineCore(JniEngine(), { m -> replies.put(Wire.decodeMessage(Wire.encodeMessage(m))) }, pid = 1)
    try {
      fun rt(c: EngineCall, id: Long): Any? {
        val (rid, decoded) = Wire.decodeCall(Wire.encodeCall(id, c))
        bench.submit(rid, decoded)
        while (true) {
          when (val m = replies.take()) {
            is io.github.mihok.sherpa_inference.CallResult -> if (m.requestId == id) return m.value
            is io.github.mihok.sherpa_inference.CallError -> if (m.requestId == id) throw AssertionError(m.message)
            else -> {}
          }
        }
      }
      rt(StartCall(engineLib, null), 1)
      val m = (rt(LoadModelCall(opts(modelPath), 0, false, "q"), 2) as HandleInfoMsg).handle
      val chat = request("hi", 4)
      repeat(20) { rt(CountChatCall(m, chat), 10L + it) }
      val samples = (0 until 200).map {
        val t = System.nanoTime()
        rt(CountChatCall(m, chat), 100L + it)
        (System.nanoTime() - t) / 1000.0
      }.sorted()
      perf.add("| countChatTokens round trip: median ${"%.0f".format(samples[100])} µs, p90 ${"%.0f".format(samples[180])} µs |")
      val tok = (0 until 500).map {
        val t = System.nanoTime()
        rt(TokenizeCall(m, "hi", false, false), 1000L + it)
        (System.nanoTime() - t) / 1000.0
      }.sorted()
      perf.add("| tokenize(\"hi\") round trip: median ${"%.0f".format(tok[250])} µs, p90 ${"%.0f".format(tok[450])} µs |")
    } finally {
      bench.shutdown()
    }
    val s = session()
    val body = request("Write the numbers from 1 to 40 separated by commas.", 40)
    val runs = (0 until 3).map {
      rec.result(call(ResetSessionCall(s)))
      val (stream, ev) = generate(s, body)
      Triple(ev.first { it.type == EventTypes.PERF }, ev.first { it.type == EventTypes.USAGE }, rec.batches(stream).size)
    }
    val p = runs.sortedBy { it.first.decodeTps }[1]
    perf.add("| 40-token greedy reply (median of 3): TTFT ${"%.0f".format(p.first.ttftMs)} ms, prefill ${"%.1f".format(p.first.prefillTps)} t/s, decode ${"%.1f".format(p.first.decodeTps)} t/s, ${p.third} batches for ${p.second.completionTokens} tokens |")
    rec.result(call(FreeSessionCall(s)))
  }

  @Test fun i_freedAndForeignHandlesAreRejected() {
    val s = session()
    rec.result(call(FreeSessionCall(s)))
    assertEquals(EngineError.INVALID_ARG.toLong(), rec.error(call(SessionInfoCall(s))).code)
    val batch = rec.all.filterIsInstance<EventBatch>()
    assertTrue(batch.isNotEmpty())
  }
}
