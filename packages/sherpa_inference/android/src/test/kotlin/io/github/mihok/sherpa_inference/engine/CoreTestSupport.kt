package io.github.mihok.sherpa_inference.engine

import io.github.mihok.sherpa_inference.BenchConfigMsg
import io.github.mihok.sherpa_inference.CallError
import io.github.mihok.sherpa_inference.CallResult
import io.github.mihok.sherpa_inference.EngineEventMsg
import io.github.mihok.sherpa_inference.EventBatch
import io.github.mihok.sherpa_inference.InferenceMessage
import io.github.mihok.sherpa_inference.ModelOptionsMsg
import io.github.mihok.sherpa_inference.SessionConfigMsg
import io.github.mihok.sherpa_inference.StreamFailed
import io.github.mihok.sherpa_inference.StreamStarted
import java.util.Collections
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/** Collects everything an [EngineCore] sends, with blocking waits. */
class Recorder {
  val all: MutableList<InferenceMessage> = Collections.synchronizedList(ArrayList())
  private val queue = LinkedBlockingQueue<InferenceMessage>()

  fun sink(m: InferenceMessage) {
    all.add(m)
    queue.put(m)
  }

  /** Waits for the first message (from the start or after earlier waits) matching [pred]. */
  fun <T : InferenceMessage> await(timeoutMs: Long = 10_000, pred: (InferenceMessage) -> Boolean): T {
    val deadline = System.currentTimeMillis() + timeoutMs
    synchronized(all) { all.firstOrNull { pred(it) && it !in consumed } }?.let {
      consumed.add(it)
      @Suppress("UNCHECKED_CAST")
      return it as T
    }
    while (true) {
      val left = deadline - System.currentTimeMillis()
      if (left <= 0) throw AssertionError("timed out waiting; got ${all.toList()}")
      val m = queue.poll(left, TimeUnit.MILLISECONDS) ?: continue
      if (pred(m) && m !in consumed) {
        consumed.add(m)
        @Suppress("UNCHECKED_CAST")
        return m as T
      }
    }
  }

  private val consumed = Collections.newSetFromMap(java.util.IdentityHashMap<InferenceMessage, Boolean>())

  fun result(id: Long, timeoutMs: Long = 10_000): Any? {
    val m = await<InferenceMessage>(timeoutMs) { (it is CallResult && it.requestId == id) || (it is CallError && it.requestId == id) }
    if (m is CallError) throw AssertionError("call $id failed: ${m.code} ${m.message}")
    return (m as CallResult).value
  }

  fun error(id: Long, timeoutMs: Long = 10_000): CallError {
    val m = await<InferenceMessage>(timeoutMs) { (it is CallResult && it.requestId == id) || (it is CallError && it.requestId == id) }
    if (m is CallResult) throw AssertionError("call $id succeeded: ${m.value}")
    return m as CallError
  }

  fun batches(stream: Long): List<EventBatch> = synchronized(all) { all.filterIsInstance<EventBatch>().filter { it.streamId == stream } }

  fun events(stream: Long): List<EngineEventMsg> = batches(stream).flatMap { it.events }

  fun started(stream: Long): StreamStarted = await { it is StreamStarted && it.streamId == stream }

  fun failed(stream: Long): StreamFailed = await { it is StreamFailed && it.streamId == stream }

  fun lastBatch(stream: Long, timeoutMs: Long = 10_000): EventBatch =
    await(timeoutMs) { it is EventBatch && it.streamId == stream && it.last }

  fun text(stream: Long): String = events(stream).filter { it.type == EventTypes.TEXT_DELTA }.joinToString("") { it.text }
}

fun opts(path: String = "/models/m.gguf") = ModelOptionsMsg(path, null, -1, -1, true, false, false)

fun cfg(nCtx: Long = 0, eventCapacity: Long = 0, nThreads: Long = 0, typeK: Long = -1, typeV: Long = -1, seed: Long = 0xFFFFFFFFL) =
  SessionConfigMsg(nCtx, 0, 0, nThreads, nThreads, typeK, typeV, -1, 0, -1, seed, 0, 0, eventCapacity)

fun bench(nThreads: Long = 1, nPrompt: Long = 16, nGen: Long = 4) =
  BenchConfigMsg(nThreads, nThreads, 0, 0, 0, nPrompt, nGen, 1, -1, -1, -1)
