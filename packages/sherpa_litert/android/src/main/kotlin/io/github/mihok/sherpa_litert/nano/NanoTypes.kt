package io.github.mihok.sherpa_litert.nano

import kotlinx.coroutines.flow.Flow

// The engine boundary of the Gemini Nano side (ML Kit GenAI Prompt API). Plain Kotlin, so NanoController is
// tested with a fake client on the JVM; MlKitNanoClient is the only file that touches ML Kit.

/** One stateless Prompt API request (the API has no conversation: Dart renders the transcript into [prompt]). */
data class NanoPrompt(
  val systemInstruction: String? = null,
  val prompt: String,
  val images: List<ByteArray> = emptyList(),
  val temperature: Float? = null,
  val topK: Int? = null,
  val seed: Int? = null,
  val maxOutputTokens: Int? = null,
  val enableThinking: Boolean = false,
)

data class NanoOutput(val text: String, val finishReason: Int?)

sealed interface NanoDownload {
  data class Started(val bytesToDownload: Long) : NanoDownload

  data class Progress(val bytesDownloaded: Long) : NanoDownload

  data object Completed : NanoDownload

  data class Failed(val error: NanoError) : NanoDownload
}

/** A `GenAiException` (or another failure) with its ML Kit error code; classification happens in Dart. */
class NanoError(val code: Int, message: String, val retryAfterMs: Long? = null, cause: Throwable? = null) :
  Exception(message, cause)

/** One `GenerativeModel` (per release stage + preference). Suspending calls are main-safe. */
interface NanoClient : AutoCloseable {
  /** `FeatureStatus` value. */
  suspend fun checkStatus(): Int

  suspend fun baseModelName(): String?

  suspend fun tokenLimit(): Int?

  suspend fun isSystemPromptAvailable(): Boolean

  suspend fun isThinkingModeAvailable(): Boolean

  suspend fun isStructuredOutputAvailable(): Boolean

  suspend fun isCachingAvailable(): Boolean

  fun download(): Flow<NanoDownload>

  suspend fun warmup()

  suspend fun countTokens(prompt: NanoPrompt): Int

  /** Streams deltas through [onText] / [onThought] and returns the final candidate. */
  suspend fun generate(prompt: NanoPrompt, onText: (String) -> Unit, onThought: (String) -> Unit): NanoOutput
}

fun interface NanoClientFactory {
  fun create(releaseStage: Int, preference: Int): NanoClient
}
