package io.github.mihok.sherpa_litert.lm

// The engine boundary of the LiteRT-LM side. Plain Kotlin (no Android, Flutter or LiteRT-LM types), so
// LmController is tested with fakes on the JVM and LiteRtRuntime compiles against both litertlm-android and
// the desktop litertlm-jvm artifact (used for the host smoke run, see README "Verification").

data class LmToolCall(val name: String, val argumentsJson: String)

data class LmToolResponse(val name: String, val responseJson: String)

/** One conversation message. [role] is `system`, `user`, `model` or `tool`. */
data class LmMessage(
  val role: String,
  val text: String? = null,
  val toolCalls: List<LmToolCall> = emptyList(),
  val toolResponses: List<LmToolResponse> = emptyList(),
  val images: List<ByteArray> = emptyList(),
  val imagePaths: List<String> = emptyList(),
  val thought: String? = null,
)

data class LmSampler(val topK: Int, val topP: Double, val temperature: Double, val seed: Int)

data class LmConversationSpec(
  val id: String,
  val systemInstruction: String? = null,
  val history: List<LmMessage> = emptyList(),
  val toolsJson: List<String> = emptyList(),
  val sampler: LmSampler? = null,
  val enableResponseFormat: Boolean = false,
)

data class LmSendOptions(
  val maxOutputTokens: Int? = null,
  val enableThinking: Boolean? = null,
  val thinkingBudget: Int? = null,
  val responseSchemaJson: String? = null,
)

/** What [LmRuntime.createEngine] gets: one backend, already chosen. */
data class LmEngineConfig(
  val path: String,
  /** `cpu`, `gpu` or `npu`. */
  val backend: String,
  val maxNumTokens: Int? = null,
  val cpuThreads: Int? = null,
  val cacheDir: String? = null,
  val vision: Boolean = false,
  val audio: Boolean = false,
  val nativeLibraryDir: String = "",
  val benchmark: Boolean = true,
)

data class LmModelInfo(
  val modelType: String,
  val maxContextTokens: Int,
  val dynamicContext: Boolean,
  val vision: Boolean,
  val audio: Boolean,
  val textBackends: List<String>,
  val npuBrand: String?,
  val socName: String?,
  val minRuntimeVersion: String?,
  val supportsFunctionCalling: Boolean,
  val supportsThinking: Boolean,
  val speculativeDecoding: Boolean,
  val defaultTemperature: Double?,
  val defaultTopK: Int?,
  val defaultTopP: Double?,
)

data class LmBenchmark(
  val prefillTokens: Int,
  val decodeTokens: Int,
  val timeToFirstTokenSec: Double,
  val prefillTokensPerSec: Double,
  val decodeTokensPerSec: Double,
)

/** Streaming callbacks of one turn. Exactly one of [onDone], [onCancelled], [onError] ends it. */
interface LmCallback {
  fun onText(delta: String)

  fun onThought(delta: String)

  fun onToolCalls(calls: List<LmToolCall>)

  fun onDone()

  fun onCancelled()

  fun onError(error: Throwable)
}

/** The LiteRT-LM library: inspection and engine creation. Calls block; run them off the main thread. */
interface LmRuntime {
  /** Null when the native library loads, else why it does not. */
  fun loadError(): String?

  fun inspect(path: String): LmModelInfo

  /** Creates and initializes an engine (seconds); throws when [LmEngineConfig.backend] cannot start. */
  fun createEngine(config: LmEngineConfig): LmEngine
}

interface LmEngine : AutoCloseable {
  fun createConversation(spec: LmConversationSpec): LmConversation

  /**
   * Whether the chat template renders registered tools: true = native function calling works, false = the
   * template drops tools (and tool calls/responses in history), so tools must be described in the prompt.
   * Null when unknown.
   */
  fun rendersTools(): Boolean?
}

interface LmConversation : AutoCloseable {
  /** Starts a turn and returns at once; [callback] runs on an engine thread. */
  fun send(message: LmMessage, options: LmSendOptions, callback: LmCallback)

  /** Stops the running turn at the next token boundary ([LmCallback.onCancelled] follows). */
  fun cancel()

  /** Tokens in the conversation's KV cache, or null when unavailable. */
  fun tokenCount(): Int?

  /** Counts of the last turn, or null when benchmarking is off. */
  fun benchmark(): LmBenchmark?
}

/**
 * A native status (absl::StatusCode) parsed from `LiteRtLmJniException("Status Code: X. Message: Y")`; [code] is
 * -1 when the message has no code. Classification into Sherpa error kinds happens in Dart.
 */
class LmStatusException(val code: Int, message: String, cause: Throwable? = null) : RuntimeException(message, cause) {
  companion object {
    private val pattern = Regex("""Status Code:\s*(-?\d+)\.?\s*Message:\s*(.*)""", RegexOption.DOT_MATCHES_ALL)

    fun parse(message: String?, cause: Throwable? = null): LmStatusException {
      val m = message?.let { pattern.find(it) }
      return if (m != null) {
        LmStatusException(m.groupValues[1].toInt(), m.groupValues[2].trim(), cause)
      } else {
        LmStatusException(-1, message ?: cause?.toString() ?: "unknown error", cause)
      }
    }
  }
}
