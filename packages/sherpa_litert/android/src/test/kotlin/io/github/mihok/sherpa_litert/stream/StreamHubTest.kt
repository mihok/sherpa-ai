package io.github.mihok.sherpa_litert.stream

import io.github.mihok.sherpa_litert.EventBatch
import io.github.mihok.sherpa_litert.EventKind
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Runs posted tasks only when the test says so (stands in for the main thread). */
class ManualPoster : Poster {
  private val tasks = ArrayList<Runnable>()

  override fun post(delayMs: Long, task: Runnable) {
    synchronized(tasks) { tasks.add(task) }
  }

  fun runAll() {
    while (true) {
      val next = synchronized(tasks) { if (tasks.isEmpty()) null else tasks.removeAt(0) } ?: return
      next.run()
    }
  }

  val pending: Int
    get() = synchronized(tasks) { tasks.size }
}

class StreamHubTest {
  private val poster = ManualPoster()
  private val sent = ArrayList<EventBatch>()

  private fun hub(config: HubConfig = HubConfig()) = StreamHub(poster, config).also { h -> h.sink = { sent.add(it) } }

  @Test
  fun firstBatchGoesOutAtOnceAndAdjacentDeltasAreCoalesced() {
    val hub = hub()
    val s = hub.open(5)
    s.push(Events.text("Hel"))
    s.push(Events.text("lo"))
    s.push(Events.reasoning("hmm"))
    poster.runAll()
    assertEquals(1, sent.size)
    assertEquals(5L, sent[0].streamId)
    assertEquals(listOf(EventKind.TEXT_DELTA, EventKind.REASONING_DELTA), sent[0].events.map { it.kind })
    assertEquals("Hello", sent[0].events[0].text)
  }

  @Test
  fun creditsBoundBatchesInFlight() {
    val hub = hub(HubConfig(credits = 2))
    val s = hub.open(1)
    repeat(5) { i ->
      s.push(Events.text("t$i"))
      poster.runAll()
    }
    assertEquals("only two batches without credits", 2, sent.size)
    hub.credit(1, 1)
    poster.runAll()
    assertEquals(3, sent.size)
    assertEquals("t2t3t4", sent[2].events.single().text)
  }

  @Test
  fun terminalWaitsBehindPendingEventsButEndsTheStream() {
    val hub = hub(HubConfig(credits = 1))
    val s = hub.open(1)
    s.push(Events.text("a"))
    poster.runAll()
    s.push(Events.text("b"))
    s.finish(Events.done(io.github.mihok.sherpa_litert.GenerationStatsMsg()))
    poster.runAll()
    assertEquals("no credit for 'b' yet", 1, sent.size)
    hub.credit(1, 1)
    poster.runAll()
    assertEquals(listOf(EventKind.TEXT_DELTA, EventKind.DONE), sent[1].events.map { it.kind })
    assertEquals(0, hub.openStreams())
    s.push(Events.text("late"))
    poster.runAll()
    assertEquals("events after the end are dropped", 2, sent.size)
  }

  @Test
  fun discardDropsPendingAndLetsTheTerminalThrough() {
    val hub = hub(HubConfig(credits = 1))
    val s = hub.open(1)
    s.push(Events.text("a"))
    poster.runAll()
    s.push(Events.text("never seen"))
    hub.discard(1)
    s.finish(Events.cancelled("user"))
    poster.runAll()
    assertEquals(2, sent.size)
    assertEquals(EventKind.CANCELLED, sent[1].events.single().kind)
    assertEquals("user", sent[1].events.single().detail)
  }

  @Test
  fun producerBlocksAtTheByteCapUntilDartTakesMore() {
    val hub = hub(HubConfig(credits = 1, maxPendingBytes = 200, blockPollMs = 5))
    val s = hub.open(1)
    s.push(Events.text("x"))
    poster.runAll() // the one credit is spent
    val blocked = CountDownLatch(1)
    val finished = AtomicBoolean(false)
    val producer = Thread {
      repeat(10) { s.push(Events.text("y".repeat(100))) }
      finished.set(true)
      blocked.countDown()
    }
    producer.start()
    assertFalse("the producer is held at the cap", blocked.await(200, TimeUnit.MILLISECONDS))
    assertFalse(finished.get())
    // Dart keeps crediting: the producer drains through.
    val deadline = System.currentTimeMillis() + 5000
    while (!finished.get() && System.currentTimeMillis() < deadline) {
      hub.credit(1, 1)
      poster.runAll()
      Thread.sleep(5)
    }
    assertTrue(finished.get())
    producer.join(1000)
    hub.credit(1, 10)
    poster.runAll()
    val text = sent.flatMap { it.events }.joinToString("") { it.text ?: "" }
    assertEquals("x" + "y".repeat(1000), text)
  }

  @Test
  fun discardUnblocksABlockedProducer() {
    val hub = hub(HubConfig(credits = 0, maxPendingBytes = 100, blockPollMs = 5))
    val s = hub.open(1)
    val done = CountDownLatch(1)
    Thread {
      repeat(5) { s.push(Events.text("z".repeat(80))) }
      done.countDown()
    }.start()
    assertFalse(done.await(100, TimeUnit.MILLISECONDS))
    hub.discard(1)
    assertTrue(done.await(2, TimeUnit.SECONDS))
  }

  @Test
  fun downloadProgressKeepsOnlyTheLatestValue() {
    val hub = hub(HubConfig(credits = 1))
    val s = hub.open(3)
    s.push(Events.downloadStarted(100))
    poster.runAll()
    s.push(Events.downloadProgress(10))
    s.push(Events.downloadProgress(20))
    s.push(Events.downloadProgress(30))
    hub.credit(3, 1)
    poster.runAll()
    assertEquals(listOf(30L), sent[1].events.map { it.value })
  }

  @Test
  fun globalEventsBypassFlowControl() {
    val hub = hub(HubConfig(credits = 0))
    hub.global(Events.trimMemory(40))
    poster.runAll()
    assertEquals(0L, sent.single().streamId)
    assertEquals(40L, sent.single().events.single().value)
  }
}
