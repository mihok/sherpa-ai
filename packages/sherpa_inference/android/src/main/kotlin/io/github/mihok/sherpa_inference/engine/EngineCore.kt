package io.github.mihok.sherpa_inference.engine

import io.github.mihok.sherpa_inference.BenchCall
import io.github.mihok.sherpa_inference.CallError
import io.github.mihok.sherpa_inference.CallResult
import io.github.mihok.sherpa_inference.CancelCall
import io.github.mihok.sherpa_inference.CancelSessionCall
import io.github.mihok.sherpa_inference.CancelStreamCall
import io.github.mihok.sherpa_inference.CountBatchCall
import io.github.mihok.sherpa_inference.CountChatCall
import io.github.mihok.sherpa_inference.CreateSessionCall
import io.github.mihok.sherpa_inference.CreditCall
import io.github.mihok.sherpa_inference.DebugCrashCall
import io.github.mihok.sherpa_inference.DetokenizeCall
import io.github.mihok.sherpa_inference.EngineCall
import io.github.mihok.sherpa_inference.EngineInfoMsg
import io.github.mihok.sherpa_inference.EstimateMemoryCall
import io.github.mihok.sherpa_inference.FreeLoraCall
import io.github.mihok.sherpa_inference.FreeModelCall
import io.github.mihok.sherpa_inference.FreeSessionCall
import io.github.mihok.sherpa_inference.GenerateCall
import io.github.mihok.sherpa_inference.HandleInfoMsg
import io.github.mihok.sherpa_inference.InferenceMessage
import io.github.mihok.sherpa_inference.LoadLoraCall
import io.github.mihok.sherpa_inference.LoadModelCall
import io.github.mihok.sherpa_inference.LoadProgress
import io.github.mihok.sherpa_inference.LoadStateCall
import io.github.mihok.sherpa_inference.ResetSessionCall
import io.github.mihok.sherpa_inference.SaveStateCall
import io.github.mihok.sherpa_inference.SessionInfoCall
import io.github.mihok.sherpa_inference.SessionMemoryCall
import io.github.mihok.sherpa_inference.SetLorasCall
import io.github.mihok.sherpa_inference.SetThreadsCall
import io.github.mihok.sherpa_inference.ShutdownCall
import io.github.mihok.sherpa_inference.StartCall
import io.github.mihok.sherpa_inference.StreamFailed
import io.github.mihok.sherpa_inference.SystemInfoCall
import io.github.mihok.sherpa_inference.TokenizeCall
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.TimeUnit

/**
 * The service-side request dispatcher: one per attached client. Pure JVM (no android.*), so it runs in the
 * plain-JVM unit tests against a fake [Engine] and, through [JniEngine], against the real host engine.
 *
 * [submit] is called on a Binder thread and returns at once; replies, progress, stream starts and event
 * batches go to [sink] from worker threads (in order per stream). Threading:
 * * Blocking calls run on a cached pool ([pool]) so a multi-second load never stalls another session or
 *   the Binder thread; model-scoped reads (tokenize, counts, info) run concurrently (models are immutable).
 * * Session calls (including generation starts) run on that session's [SerialExecutor] in arrival order.
 *   Ops that the engine refuses while generating wait up to [idleWaitMs] for a just-finished generation's
 *   busy flag to clear, then fail with SE_ERR_BUSY as the header specifies (same as the FFI worker).
 * * Events: [EventPump] (single consumer of every ring). Cancels bypass every queue.
 * * Handles are salted ids in [HandleTable]s; frees wait for in-flight users of the same handle.
 */
class EngineCore(
  private val engine: Engine,
  private val sink: (InferenceMessage) -> Unit,
  private val pid: Long,
  private val phases: PhaseTracker? = null,
  pumpConfig: PumpConfig = PumpConfig(),
  private val debuggable: Boolean = false,
  private val onDebugKill: () -> Unit = {},
  /**
   * How long a session op waits for a just-finished generation to clear the engine's busy flag (it is
   * cleared right after FINISH is queued, se_session.cpp worker_main). Longer than the FFI worker's 200 ms:
   * on a loaded device the engine worker can be descheduled in that window. A generation that is really
   * running still yields SE_ERR_BUSY, just after this delay.
   */
  private val idleWaitMs: Int = 1000,
) {
  private class ModelMeta(val tag: String)

  private class SessionMeta(val model: Long, val tag: String, val nCtx: Long?, val kv: String?, val queue: SerialExecutor)

  private val pool: ExecutorService = enginePool("sherpa-engine")
  private val models = HandleTable<ModelMeta>("model")
  private val sessions = HandleTable<SessionMeta>("session")
  private val loras = HandleTable<Long>("lora")
  private val pump = EventPump(engine, sink, phases, pumpConfig).also { it.startThread() }

  /** cancelId → `se_canceller`; guarded by itself so a cancel never reaches a freed canceller. */
  private val cancellers = HashMap<Long, Long>()

  /** Model tags by handle, for sessions created later (phase summaries). */
  private val modelTags = ConcurrentHashMap<Long, String>()

  @Volatile private var started: EngineInfoMsg? = null

  @Volatile private var closing = false
  private val startLock = Any()

  /** Test hook: the pump (batch counters). */
  val eventPump: EventPump get() = pump

  fun submit(requestId: Long, call: EngineCall) {
    if (closing && call !is ShutdownCall) {
      if (requestId != 0L) sink(CallError(requestId, EngineError.UNSUPPORTED.toLong(), "the engine is shutting down"))
      return
    }
    when (call) {
      // Fire-and-forget controls: never queued behind work.
      is CreditCall -> pump.credit(call.streamId, call.n.toInt())
      is CancelStreamCall -> pump.cancelStream(call.streamId)
      is CancelSessionCall -> ignoreErrors { sessions.use(call.session) { engine.cancel(it.ptr) } }
      is CancelCall -> synchronized(cancellers) { cancellers[call.cancelId]?.let(engine::cancellerCancel) }
      is GenerateCall -> generate(call)
      is StartCall -> async(requestId) { start(call) }
      is SystemInfoCall -> async(requestId) { requireStarted(); engine.systemInfoJson() }
      is LoadModelCall -> loadModel(requestId, call)
      is FreeModelCall -> async(requestId) {
        modelTags.remove(call.model)
        if (!models.retire(call.model) { engine.modelFree(it) }) throw unknown("model", call.model)
        null
      }
      is EstimateMemoryCall -> async(requestId) { requireStarted(); engine.estimateMemory(call.model, call.session) }
      is CreateSessionCall -> async(requestId) { createSession(call) }
      is FreeSessionCall -> onSession(requestId, call.session) { freeSession(call.session, it.ptr) }
      is ResetSessionCall -> onSession(requestId, call.session) {
        idle(it.ptr)
        engine.sessionReset(it.ptr)
        null
      }
      is SetThreadsCall -> onSession(requestId, call.session) {
        idle(it.ptr)
        engine.sessionSetThreads(it.ptr, call.nThreads.toInt(), call.nThreadsBatch.toInt())
        null
      }
      is SessionInfoCall -> onSession(requestId, call.session) { engine.sessionInfoJson(it.ptr) }
      is SessionMemoryCall -> onSession(requestId, call.session) { engine.sessionMemory(it.ptr) }
      is TokenizeCall -> onModel(requestId, call.model) {
        engine.tokenize(it, call.text, call.addSpecial, call.parseSpecial)
      }
      is DetokenizeCall -> onModel(requestId, call.model) { engine.detokenize(it, call.tokens, call.renderSpecial) }
      is CountChatCall -> onModel(requestId, call.model) { engine.countChat(it, call.requestJson).toLong() }
      is CountBatchCall -> onModel(requestId, call.model) { m ->
        val out = IntArray(call.texts.size + call.chatRequests.size)
        for ((i, t) in call.texts.withIndex()) out[i] = engine.countText(m, t)
        for ((i, c) in call.chatRequests.withIndex()) out[call.texts.size + i] = engine.countChatOrStatus(m, c)
        out
      }
      is SaveStateCall -> onSession(requestId, call.session) {
        idle(it.ptr)
        phases?.enter("savingState", it.meta.tag, it.meta.nCtx, it.meta.kv).use { _ ->
          engine.stateSave(it.ptr, call.path)
        }
        File(call.path).length()
      }
      is LoadStateCall -> onSession(requestId, call.session) {
        idle(it.ptr)
        phases?.enter("restoringState", it.meta.tag, it.meta.nCtx, it.meta.kv).use { _ ->
          engine.stateLoad(it.ptr, call.path).toLong()
        }
      }
      is LoadLoraCall -> onModel(requestId, call.model) { loras.add(engine.loraLoad(it, call.path), call.model) }
      is FreeLoraCall -> async(requestId) {
        if (!loras.retire(call.lora) { engine.loraFree(it) }) throw unknown("lora", call.lora)
        null
      }
      is SetLorasCall -> onSession(requestId, call.session) { s ->
        idle(s.ptr)
        withLoras(call.loras) { ptrs ->
          engine.setLoras(s.ptr, ptrs, FloatArray(call.scales.size) { i -> call.scales[i].toFloat() })
        }
        null
      }
      is BenchCall -> bench(requestId, call)
      is ShutdownCall -> async(requestId) {
        shutdown()
        null
      }
      is DebugCrashCall -> debugCrash(requestId, call.mode)
    }
  }

  // ---------------------------------------------------------------------------------------------------
  // Calls

  private fun start(call: StartCall): EngineInfoMsg = synchronized(startLock) {
    started?.let { return it }
    engine.open(call.library)
    engine.backendInit(call.crashBreadcrumbPath, call.backendDir)
    EngineInfoMsg(engine.abiVersion().toLong(), engine.versionString(), engine.systemInfoJson(), pid).also { started = it }
  }

  private fun requireStarted() {
    if (started == null) throw EngineError(EngineError.UNSUPPORTED, "the engine was not started")
  }

  private fun loadModel(requestId: Long, call: LoadModelCall) {
    val canceller = registerCanceller(call.cancelId)
    async(requestId, onDone = { freeCanceller(call.cancelId) }) {
      requireStarted()
      val progress = if (!call.progress) null else {
        var last = -1f
        ProgressSink { p ->
          if (p - last >= 0.01f || p >= 1f) {
            last = p
            sink(LoadProgress(requestId, p.toDouble()))
          }
          true
        }
      }
      val tag = call.phaseTag
      val ptr = phases?.enter("loading", tag).use { _ -> engine.modelLoad(call.options, canceller, progress) }
      val info = try {
        engine.modelInfoJson(ptr)
      } catch (e: EngineError) {
        engine.modelFree(ptr)
        throw e
      }
      val id = models.add(ptr, ModelMeta(tag))
      modelTags[id] = tag
      HandleInfoMsg(id, info)
    }
  }

  private fun createSession(call: CreateSessionCall): HandleInfoMsg {
    requireStarted()
    return models.use(call.model) { m ->
      val ptr = engine.sessionCreate(m.ptr, call.config)
      val info = try {
        engine.sessionInfoJson(ptr)
      } catch (e: EngineError) {
        engine.sessionFree(ptr)
        throw e
      }
      val (nCtx, kv) = PhaseTracker.sessionShape(info)
      val queue = SerialExecutor(pool)
      HandleInfoMsg(sessions.add(ptr, SessionMeta(call.model, m.meta.tag, nCtx, kv, queue)), info)
    }
  }

  private fun freeSession(id: Long, ptr: Long): Any? {
    // The pump must stop polling the session before it is freed (single consumer, then se_session_free).
    pump.release(ptr).get(10, TimeUnit.SECONDS)
    sessions.retire(id) { engine.sessionFree(it) }
    return null
  }

  private fun generate(call: GenerateCall) {
    val meta = try {
      sessionQueue(call.session)
    } catch (e: EngineError) {
      sink(StreamFailed(call.streamId, e.code.toLong(), e.message ?: ""))
      return
    }
    meta.queue.execute {
      try {
        sessions.use(call.session) { s ->
          val start = EventPump.Start(call.streamId, s.ptr, call.requestJson, s.meta.tag, s.meta.nCtx, s.meta.kv)
          pump.start(start)
          // Keep later session calls behind this start (arrival order), but never behind the generation.
          start.handled.get(30, TimeUnit.SECONDS)
        }
      } catch (e: EngineError) {
        sink(StreamFailed(call.streamId, e.code.toLong(), e.message ?: ""))
      } catch (t: Throwable) {
        sink(StreamFailed(call.streamId, EngineError.INTERNAL.toLong(), "generation start failed: $t"))
      }
    }
  }

  private fun bench(requestId: Long, call: BenchCall) {
    val canceller = registerCanceller(call.cancelId)
    async(requestId, onDone = { freeCanceller(call.cancelId) }) {
      models.use(call.model) { m ->
        phases?.enter("benchmarking", m.meta.tag).use { _ -> engine.bench(m.ptr, call.config, canceller) }
      }
    }
  }

  private fun debugCrash(requestId: Long, mode: String) {
    if (!debuggable) {
      sink(CallError(requestId, EngineError.UNSUPPORTED.toLong(), "debug crashes need a debuggable build"))
      return
    }
    when (mode) {
      "kill" -> onDebugKill()
      "abort" -> engine.debugCrash(0)
      "segv" -> engine.debugCrash(1)
      else -> engine.debugCrash(2)
    }
  }

  /** Cancels everything and frees every handle (ShutdownCall, client death, service destroy). Idempotent. */
  fun shutdown(timeoutMs: Long = 5000) {
    closing = true
    try {
      pump.stop().get(timeoutMs, TimeUnit.MILLISECONDS)
    } catch (_: Exception) {
      // The pump thread is a daemon; sessions are cancelled by se_session_free below anyway.
    }
    synchronized(cancellers) { cancellers.values.forEach(engine::cancellerCancel) }
    for (id in sessions.ids()) sessions.retire(id) { engine.sessionFree(it) }
    for (id in loras.ids()) loras.retire(id) { engine.loraFree(it) }
    for (id in models.ids()) models.retire(id) { engine.modelFree(it) }
    pool.shutdown()
  }

  /** Live handles (diagnostics, tests). */
  fun liveHandles(): Int = models.size() + sessions.size() + loras.size()

  // ---------------------------------------------------------------------------------------------------
  // Plumbing

  private fun registerCanceller(cancelId: Long): Long {
    if (cancelId == 0L || started == null) return 0
    val c = engine.cancellerCreate()
    synchronized(cancellers) { cancellers[cancelId] = c }
    return c
  }

  private fun freeCanceller(cancelId: Long) {
    if (cancelId == 0L) return
    synchronized(cancellers) { cancellers.remove(cancelId)?.let(engine::cancellerFree) }
  }

  private fun sessionQueue(id: Long): SessionMeta = sessions.use(id) { it.meta }

  private fun unknown(kind: String, id: Long) = EngineError(EngineError.INVALID_ARG, "unknown or freed $kind handle #${id and 0xFFFFFFFFL}")

  /** A session call on the session's queue, in arrival order. */
  private fun onSession(requestId: Long, id: Long, body: (HandleTable<SessionMeta>.Entry) -> Any?) {
    val meta = try {
      sessionQueue(id)
    } catch (e: EngineError) {
      reply(requestId, e)
      return
    }
    meta.queue.execute { answer(requestId) { sessions.use(id) { body(it) } } }
  }

  /** A model-scoped call on the pool (concurrent: models are immutable and thread-safe). */
  private fun onModel(requestId: Long, id: Long, body: (Long) -> Any?) =
    async(requestId) { models.use(id) { body(it.ptr) } }

  private fun async(requestId: Long, onDone: () -> Unit = {}, body: () -> Any?) {
    try {
      pool.execute {
        try {
          answer(requestId, body)
        } finally {
          onDone()
        }
      }
    } catch (e: Exception) {
      onDone()
      reply(requestId, EngineError(EngineError.UNSUPPORTED, "the engine is shutting down"))
    }
  }

  private fun answer(requestId: Long, body: () -> Any?) {
    val result = try {
      Result.success(body())
    } catch (t: Throwable) {
      Result.failure(t)
    }
    result.fold({ if (requestId != 0L) sink(CallResult(requestId, it)) }, { reply(requestId, it) })
  }

  private fun reply(requestId: Long, t: Throwable) {
    if (requestId == 0L) return
    val (code, message) = when (t) {
      is EngineError -> t.code.toLong() to (t.message ?: "")
      is OutOfMemoryError -> EngineError.OOM.toLong() to "out of memory in the inference process"
      else -> EngineError.INTERNAL.toLong() to "inference service: $t"
    }
    sink(CallError(requestId, code, message))
  }

  /** se_wait closes the race between FINISH and the engine clearing its busy flag (ffi_isolates `_idle`). */
  private fun idle(ptr: Long) {
    engine.waitIdle(ptr, idleWaitMs)
  }

  private fun <T> withLoras(ids: List<Long>, block: (LongArray) -> T): T {
    val ptrs = LongArray(ids.size)
    fun hold(i: Int): T {
      if (i == ids.size) return block(ptrs)
      return loras.use(ids[i]) { e ->
        ptrs[i] = e.ptr
        hold(i + 1)
      }
    }
    return hold(0)
  }

  private inline fun ignoreErrors(block: () -> Unit) {
    try {
      block()
    } catch (_: EngineError) {
      // cancel of an unknown session: nothing runs
    }
  }
}
