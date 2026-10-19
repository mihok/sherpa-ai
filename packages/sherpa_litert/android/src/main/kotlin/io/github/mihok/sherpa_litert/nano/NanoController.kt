package io.github.mihok.sherpa_litert.nano

import io.github.mihok.sherpa_litert.ErrorMsg
import io.github.mihok.sherpa_litert.GenerationStatsMsg
import io.github.mihok.sherpa_litert.NanoConfigMsg
import io.github.mihok.sherpa_litert.NanoRequestMsg
import io.github.mihok.sherpa_litert.NanoStatusMsg
import io.github.mihok.sherpa_litert.stream.Events
import io.github.mihok.sherpa_litert.stream.StreamHub
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

/**
 * Gemini Nano through ML Kit's Prompt API: status probes, model download with progress, streaming generation and
 * cancel. All work runs in [scope] (a dedicated dispatcher in the plugin), never on the main thread.
 *
 * Cancel ends the stream at once with `cancelled` and then cancels the job: whether ML Kit stops AICore's
 * decode when its suspend call is cancelled is not documented, so Dart never waits on it.
 *
 * The foreground-only rule (AICore answers BACKGROUND_USE_BLOCKED otherwise, even in a foreground service) is
 * enforced in Dart before a request is sent; this class only reports error codes.
 */
class NanoController(
  private val factory: NanoClientFactory,
  private val hub: StreamHub,
  private val scope: CoroutineScope,
) {
  private val clients = ConcurrentHashMap<Pair<Int, Int>, NanoClient>()
  private val jobs = ConcurrentHashMap<Long, Job>()

  private fun client(config: NanoConfigMsg): NanoClient {
    val key = config.releaseStage.toInt() to config.preference.toInt()
    return clients.getOrPut(key) { factory.create(key.first, key.second) }
  }

  suspend fun status(config: NanoConfigMsg): NanoStatusMsg {
    val c = try {
      client(config)
    } catch (t: Throwable) {
      return NanoStatusMsg(featureStatus = -1, error = errorMsg(t))
    }
    val status = try {
      c.checkStatus()
    } catch (t: Throwable) {
      if (t is CancellationException) throw t
      return NanoStatusMsg(featureStatus = -1, error = errorMsg(t))
    }
    if (status != FEATURE_AVAILABLE) return NanoStatusMsg(featureStatus = status.toLong())
    return NanoStatusMsg(
      featureStatus = status.toLong(),
      baseModelName = probe { c.baseModelName() },
      tokenLimit = probe { c.tokenLimit() }?.toLong(),
      systemPrompt = probe { c.isSystemPromptAvailable() },
      thinking = probe { c.isThinkingModeAvailable() },
      structuredOutput = probe { c.isStructuredOutputAvailable() },
      caching = probe { c.isCachingAvailable() },
    )
  }

  fun download(streamId: Long, config: NanoConfigMsg) {
    val stream = hub.open(streamId)
    val job = scope.launch(start = CoroutineStart.LAZY) {
      try {
        client(config).download().collect { d ->
          when (d) {
            is NanoDownload.Started -> stream.push(Events.downloadStarted(d.bytesToDownload))
            is NanoDownload.Progress -> stream.push(Events.downloadProgress(d.bytesDownloaded))
            NanoDownload.Completed -> stream.finish(Events.downloadCompleted())
            is NanoDownload.Failed -> stream.finish(Events.downloadFailed(errorMsg(d.error)))
          }
        }
        // The flow ended without a terminal status: nothing failed, so it completed.
        stream.finish(Events.downloadCompleted())
      } catch (e: CancellationException) {
        stream.finish(Events.cancelled("cancelled"))
      } catch (t: Throwable) {
        stream.finish(Events.downloadFailed(errorMsg(t)))
      } finally {
        jobs.remove(streamId)
      }
    }
    jobs[streamId] = job
    job.start()
  }

  suspend fun warmup(config: NanoConfigMsg) = client(config).warmup()

  fun generate(request: NanoRequestMsg) {
    val streamId = request.streamId
    val stream = hub.open(streamId)
    val prompt = NanoPrompt(
      systemInstruction = request.systemInstruction,
      prompt = request.prompt,
      images = request.images ?: emptyList(),
      temperature = request.temperature?.toFloat(),
      topK = request.topK?.toInt(),
      seed = request.seed?.toInt(),
      maxOutputTokens = request.maxOutputTokens?.toInt(),
      enableThinking = request.enableThinking,
    )
    val job = scope.launch(start = CoroutineStart.LAZY) {
      try {
        val c = client(request.config)
        val promptTokens = if (request.countTokens) runCatchingNonCancel { c.countTokens(prompt) } else null
        val out = c.generate(
          prompt,
          onText = { if (it.isNotEmpty()) stream.push(Events.text(it)) },
          onThought = { if (it.isNotEmpty()) stream.push(Events.reasoning(it)) },
        )
        val outputTokens = if (request.countTokens && out.text.isNotEmpty()) {
          runCatchingNonCancel { c.countTokens(NanoPrompt(prompt = out.text)) }
        } else {
          null
        }
        stream.finish(
          Events.done(
            GenerationStatsMsg(
              finishReason = out.finishReason?.toLong(),
              promptTokens = promptTokens?.toLong(),
              outputTokens = outputTokens?.toLong(),
              backend = "aicore",
            ),
          ),
        )
      } catch (e: CancellationException) {
        stream.finish(Events.cancelled("cancelled"))
      } catch (t: Throwable) {
        val m = errorMsg(t)
        stream.finish(Events.error(m.source, m.code, m.message, m.retryAfterMs))
      } finally {
        jobs.remove(streamId)
      }
    }
    jobs[streamId] = job
    job.start()
  }

  /** Ends [streamId] now with `cancelled` ([reason]) and cancels its job. False when unknown. */
  fun cancel(streamId: Long, reason: String): Boolean {
    val job = jobs.remove(streamId) ?: return false
    hub.discard(streamId)
    hub.stream(streamId)?.finish(Events.cancelled(reason))
    job.cancel()
    return true
  }

  fun closeAll() {
    for (j in jobs.values) j.cancel()
    jobs.clear()
    for (c in clients.values) runCatching { c.close() }
    clients.clear()
  }

  private suspend fun <T> probe(block: suspend () -> T): T? = runCatchingNonCancel { block() }

  private suspend fun <T> runCatchingNonCancel(block: suspend () -> T): T? =
    try {
      block()
    } catch (e: CancellationException) {
      throw e
    } catch (_: Throwable) {
      null
    }

  companion object {
    const val FEATURE_AVAILABLE = 3

    fun errorMsg(t: Throwable): ErrorMsg = when (t) {
      is NanoError -> ErrorMsg("nano", t.code.toLong(), t.message ?: "Gemini Nano error ${t.code}", t.retryAfterMs)
      is IllegalStateException -> ErrorMsg("state", -1, t.message ?: t.toString())
      is IllegalArgumentException -> ErrorMsg("argument", -1, t.message ?: t.toString())
      else -> ErrorMsg("host", -1, t.message ?: t.toString())
    }
  }
}
