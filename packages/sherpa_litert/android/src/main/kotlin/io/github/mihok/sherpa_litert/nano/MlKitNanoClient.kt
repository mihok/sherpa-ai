package io.github.mihok.sherpa_litert.nano

import com.google.mlkit.genai.common.DownloadStatus
import com.google.mlkit.genai.common.GenAiException
import com.google.mlkit.genai.common.StreamingCallback
import com.google.mlkit.genai.prompt.Content
import com.google.mlkit.genai.prompt.GenerateContentRequest
import com.google.mlkit.genai.prompt.Generation
import com.google.mlkit.genai.prompt.GenerativeModel
import com.google.mlkit.genai.prompt.ImagePart
import com.google.mlkit.genai.prompt.SystemInstruction
import com.google.mlkit.genai.prompt.TextPart
import com.google.mlkit.genai.prompt.generationConfig
import com.google.mlkit.genai.prompt.modelConfig
import java.util.concurrent.ExecutorService
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.map

/**
 * [NanoClient] over `com.google.mlkit:genai-prompt:1.0.0-beta4` (API checked with javap):
 * `Generation.getClient(GenerationConfig)` → `GenerativeModel` with `checkStatus`, `download(): Flow`,
 * `generateContent(request, StreamingCallback)` (`onNewText` / `onNewThought` deltas), `countTokens`,
 * `getTokenLimit`, the feature probes and `close`. `GenAiException.errorCode` / `retryDelay` become [NanoError].
 */
class MlKitNanoClient(releaseStage: Int, preference: Int, worker: ExecutorService) : NanoClient {
  private val model: GenerativeModel = Generation.getClient(
    generationConfig {
      workerExecutor = worker
      modelConfig = modelConfig {
        this.releaseStage = releaseStage
        this.preference = preference
      }
    },
  )

  override suspend fun checkStatus(): Int = wrap { model.checkStatus() }

  override suspend fun baseModelName(): String? = wrap { model.getBaseModelName() }

  override suspend fun tokenLimit(): Int? = wrap { model.getTokenLimit() }

  override suspend fun isSystemPromptAvailable(): Boolean = wrap { model.isSystemPromptAvailable() }

  override suspend fun isThinkingModeAvailable(): Boolean = wrap { model.isThinkingModeAvailable() }

  override suspend fun isStructuredOutputAvailable(): Boolean = wrap { model.isStructuredOutputFeatureAvailable() }

  override suspend fun isCachingAvailable(): Boolean = wrap { model.isCachingFeatureAvailable() }

  override fun download(): Flow<NanoDownload> = model.download()
    .map { s ->
      when (s) {
        is DownloadStatus.DownloadStarted -> NanoDownload.Started(s.bytesToDownload)
        is DownloadStatus.DownloadProgress -> NanoDownload.Progress(s.totalBytesDownloaded)
        is DownloadStatus.DownloadCompleted -> NanoDownload.Completed
        is DownloadStatus.DownloadFailed -> NanoDownload.Failed(toError(s.e))
      }
    }
    .catch { e -> if (e is GenAiException) emit(NanoDownload.Failed(toError(e))) else throw e }

  override suspend fun warmup() = wrap { model.warmup() }

  override suspend fun countTokens(prompt: NanoPrompt): Int = wrap { model.countTokens(request(prompt)).totalTokens }

  override suspend fun generate(prompt: NanoPrompt, onText: (String) -> Unit, onThought: (String) -> Unit): NanoOutput =
    wrap {
      val response = model.generateContent(
        request(prompt),
        object : StreamingCallback {
          override fun onNewText(text: String) = onText(text)

          override fun onNewThought(thought: String) = onThought(thought)
        },
      )
      val candidate = response.candidates.firstOrNull()
      NanoOutput(candidate?.text ?: "", candidate?.finishReason)
    }

  override fun close() = model.close()

  private fun request(p: NanoPrompt): GenerateContentRequest {
    val content = Content.Builder().apply {
      for (bytes in p.images) addPart(ImagePart(bytes))
      addPart(TextPart(p.prompt))
    }.build()
    return GenerateContentRequest.Builder(content).apply {
      p.systemInstruction?.takeIf { it.isNotBlank() }?.let { systemInstruction = SystemInstruction(it) }
      temperature = p.temperature
      topK = p.topK
      seed = p.seed
      maxOutputTokens = p.maxOutputTokens
      enableThinking = p.enableThinking
    }.build()
  }

  private inline fun <T> wrap(block: () -> T): T =
    try {
      block()
    } catch (e: GenAiException) {
      throw toError(e)
    }

  private fun toError(e: GenAiException): NanoError =
    NanoError(e.errorCode, e.message ?: "Gemini Nano error ${e.errorCode}", e.retryDelay.toMillis().takeIf { it > 0 }, e)
}

class MlKitNanoClientFactory(private val worker: ExecutorService) : NanoClientFactory {
  override fun create(releaseStage: Int, preference: Int): NanoClient = MlKitNanoClient(releaseStage, preference, worker)
}
