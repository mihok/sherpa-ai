package io.github.mihok.sherpa_litert.nano

import io.github.mihok.sherpa_litert.EventBatch
import io.github.mihok.sherpa_litert.EventKind
import io.github.mihok.sherpa_litert.LiteRtEvent
import io.github.mihok.sherpa_litert.NanoConfigMsg
import io.github.mihok.sherpa_litert.NanoRequestMsg
import io.github.mihok.sherpa_litert.stream.HubConfig
import io.github.mihok.sherpa_litert.stream.Poster
import io.github.mihok.sherpa_litert.stream.StreamHub
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class FakeNanoClient : NanoClient {
  var status = 3
  var statusError: Throwable? = null
  var generateError: Throwable? = null
  var hang: CompletableDeferred<Unit>? = null
  val prompts = CopyOnWriteArrayList<NanoPrompt>()
  var downloads: List<NanoDownload> = listOf(NanoDownload.Started(100), NanoDownload.Progress(50), NanoDownload.Completed)
  var closed = false

  override suspend fun checkStatus(): Int = statusError?.let { throw it } ?: status

  override suspend fun baseModelName(): String = "nano-v3"

  override suspend fun tokenLimit(): Int = 4000

  override suspend fun isSystemPromptAvailable(): Boolean = true

  override suspend fun isThinkingModeAvailable(): Boolean = throw NanoError(16, "not supported")

  override suspend fun isStructuredOutputAvailable(): Boolean = true

  override suspend fun isCachingAvailable(): Boolean = false

  override fun download(): Flow<NanoDownload> = flowOf(*downloads.toTypedArray())

  override suspend fun warmup() {}

  override suspend fun countTokens(prompt: NanoPrompt): Int = prompt.prompt.length

  override suspend fun generate(prompt: NanoPrompt, onText: (String) -> Unit, onThought: (String) -> Unit): NanoOutput {
    prompts.add(prompt)
    generateError?.let { throw it }
    onThought("hmm")
    onText("Hello ")
    hang?.await()
    onText("there")
    return NanoOutput("Hello there", 0)
  }

  override fun close() {
    closed = true
  }
}

class NanoControllerTest {
  private val batches = CopyOnWriteArrayList<EventBatch>()
  private val hub = StreamHub(Poster { _, task -> task.run() }, HubConfig(credits = 100)).also { h ->
    h.sink = { batches.add(it) }
  }
  private val client = FakeNanoClient()
  private val thread = Executors.newSingleThreadExecutor()
  private val scope = CoroutineScope(SupervisorJob() + thread.asCoroutineDispatcher())
  private val nano = NanoController({ _, _ -> client }, hub, scope)
  private val config = NanoConfigMsg(0, 1)

  @After
  fun tearDown() {
    scope.cancel()
    thread.shutdownNow()
  }

  private fun events(streamId: Long): List<LiteRtEvent> = batches.filter { it.streamId == streamId }.flatMap { it.events }

  private fun awaitEnd(streamId: Long) {
    val deadline = System.currentTimeMillis() + 5000
    while (System.currentTimeMillis() < deadline) {
      if (events(streamId).any { it.kind in TERMINAL }) return
      Thread.sleep(5)
    }
    throw AssertionError("stream $streamId did not end: ${events(streamId)}")
  }

  private fun request(id: Long, count: Boolean = true) =
    NanoRequestMsg(id, config, "sys", "Hi", null, 0.2, 40, 7, 128, false, count)

  @Test
  fun statusProbesWhenAvailableAndToleratesProbeFailures() = runBlocking {
    val s = nano.status(config)
    assertEquals(3L, s.featureStatus)
    assertEquals("nano-v3", s.baseModelName)
    assertEquals(4000L, s.tokenLimit)
    assertEquals(true, s.systemPrompt)
    assertNull("a failing probe is just unknown", s.thinking)
    assertNull(s.error)
  }

  @Test
  fun statusReportsAicoreErrorsAsData() = runBlocking {
    client.statusError = NanoError(606, "FEATURE_NOT_FOUND")
    val s = nano.status(config)
    assertEquals(-1L, s.featureStatus)
    val err = checkNotNull(s.error)
    assertEquals("nano", err.source)
    assertEquals(606L, err.code)
  }

  @Test
  fun statusSkipsProbesWhenNotAvailable() = runBlocking {
    client.status = 1
    val s = nano.status(config)
    assertEquals(1L, s.featureStatus)
    assertNull(s.baseModelName)
  }

  @Test
  fun generateStreamsDeltasAndCountsTokens() {
    nano.generate(request(4))
    awaitEnd(4)
    val ev = events(4)
    // The immediate poster flushes every push, so deltas arrive one per batch here.
    assertEquals(EventKind.REASONING_DELTA, ev.first().kind)
    assertEquals(EventKind.DONE, ev.last().kind)
    assertEquals("Hello there", ev.filter { it.kind == EventKind.TEXT_DELTA }.joinToString("") { it.text ?: "" })
    val stats = ev.last().stats!!
    assertEquals(0L, stats.finishReason)
    assertEquals(2L, stats.promptTokens)
    assertEquals(11L, stats.outputTokens)
    val p = client.prompts.single()
    assertEquals("sys", p.systemInstruction)
    assertEquals(0.2f, p.temperature!!, 1e-6f)
    assertEquals(128, p.maxOutputTokens)
  }

  @Test
  fun errorsCarryTheMlKitCodeAndRetryDelay() {
    client.generateError = NanoError(9, "BUSY", retryAfterMs = 2000)
    nano.generate(request(5, count = false))
    awaitEnd(5)
    val e = events(5).single().error ?: throw AssertionError("no error")
    assertEquals("nano", e.source)
    assertEquals(9L, e.code)
    assertEquals(2000L, e.retryAfterMs)
  }

  @Test
  fun cancelEndsTheStreamAtOnceAndCancelsTheJob() {
    client.hang = CompletableDeferred()
    nano.generate(request(6, count = false))
    val deadline = System.currentTimeMillis() + 5000
    while (events(6).none { it.kind == EventKind.TEXT_DELTA } && System.currentTimeMillis() < deadline) Thread.sleep(5)
    assertTrue(nano.cancel(6, "background"))
    val ev = events(6)
    assertEquals(EventKind.CANCELLED, ev.last().kind)
    assertEquals("background", ev.last().detail)
    assertFalse("unknown afterwards", nano.cancel(6, "user"))
    Thread.sleep(50)
    assertEquals("nothing after the cancel", 1, events(6).count { it.kind in TERMINAL })
  }

  @Test
  fun downloadReportsProgress() {
    nano.download(8, config)
    awaitEnd(8)
    assertEquals(
      listOf(EventKind.DOWNLOAD_STARTED, EventKind.DOWNLOAD_PROGRESS, EventKind.DOWNLOAD_COMPLETED),
      events(8).map { it.kind },
    )
  }

  @Test
  fun aFailedDownloadReportsTheError() {
    client.downloads = listOf(NanoDownload.Started(100), NanoDownload.Failed(NanoError(501, "NOT_ENOUGH_DISK_SPACE")))
    nano.download(9, config)
    awaitEnd(9)
    val last = events(9).last()
    assertEquals(EventKind.DOWNLOAD_FAILED, last.kind)
    assertEquals(501L, checkNotNull(last.error).code)
  }

  @Test
  fun closeAllClosesClients() = runBlocking {
    nano.status(config)
    nano.closeAll()
    assertTrue(client.closed)
  }

  private companion object {
    val TERMINAL = setOf(
      EventKind.DONE, EventKind.CANCELLED, EventKind.ERROR, EventKind.DOWNLOAD_COMPLETED, EventKind.DOWNLOAD_FAILED,
    )
  }
}
