package io.github.mihok.sherpa_litert.lm

import com.google.ai.edge.litertlm.Backend
import com.google.ai.edge.litertlm.BackendType
import com.google.ai.edge.litertlm.Content
import com.google.ai.edge.litertlm.Contents
import com.google.ai.edge.litertlm.Conversation
import com.google.ai.edge.litertlm.ConversationConfig
import com.google.ai.edge.litertlm.Engine
import com.google.ai.edge.litertlm.EngineConfig
import com.google.ai.edge.litertlm.ExperimentalApi
import com.google.ai.edge.litertlm.ExperimentalFlags
import com.google.ai.edge.litertlm.LiteRtLmJniException
import com.google.ai.edge.litertlm.LlmCapability
import com.google.ai.edge.litertlm.Message
import com.google.ai.edge.litertlm.MessageCallback
import com.google.ai.edge.litertlm.Modality
import com.google.ai.edge.litertlm.ModelInfo
import com.google.ai.edge.litertlm.ModelType
import com.google.ai.edge.litertlm.NpuBrand
import com.google.ai.edge.litertlm.OpenApiTool
import com.google.ai.edge.litertlm.ResponseFormat
import com.google.ai.edge.litertlm.SamplerConfig
import com.google.ai.edge.litertlm.ThinkingConfig
import com.google.ai.edge.litertlm.ToolCall
import com.google.ai.edge.litertlm.tool
import com.google.gson.JsonParser
import java.io.File
import java.util.concurrent.CancellationException

/**
 * [LmRuntime] over `com.google.ai.edge.litertlm` 0.18.0 (Engine → Conversation; API checked with javap and the
 * v0.18.0 Kotlin sources):
 *
 * - Conversations use `automaticToolCalling = false`: tools are `OpenApiTool`s built from Sherpa's JSON schemas
 *   whose `execute` is never called; the model's calls arrive in `Message.toolCalls` and Dart owns the tool loop.
 * - Streaming uses `sendMessageAsync(message, MessageCallback)`: each `onMessage` is a chunk (a delta) of text,
 *   of the `thought` channel, or a tool-call message. `cancelProcess()` ends the turn with
 *   `onError(CancellationException)`.
 * - Errors from native code are `LiteRtLmJniException("Status Code: X. Message: Y")`; they are rethrown as
 *   [LmStatusException] with the absl code.
 * - [LmEngine.rendersTools] probes the chat template with a dummy tool (`renderPrefaceIntoString`), because
 *   `LlmCapability.supportsFunctionCalling()` was false for Qwen3-0.6B, which calls tools natively.
 */
class LiteRtRuntime : LmRuntime {
  override fun loadError(): String? =
    try {
      System.loadLibrary("litertlm_jni")
      null
    } catch (t: Throwable) {
      t.message ?: t.toString()
    }

  override fun inspect(path: String): LmModelInfo {
    if (!File(path).isFile) throw LmStatusException(5, "model file not found: $path")
    val info = try {
      ModelInfo.from(path)
    } catch (e: LiteRtLmJniException) {
      throw LmStatusException.parse(e.message, e)
    }
    return info.use { readInfo(it) }
  }

  private fun readInfo(info: ModelInfo): LmModelInfo {
    val modalities = runCatching { info.inputModalities() }.getOrNull()
    val llm = info as? LlmCapability
    val sampler = runCatching { llm?.defaultSamplerParams() }.getOrNull()
    val brand = runCatching { info.npuBrand(Modality.TEXT) }.getOrNull()
    return LmModelInfo(
      modelType = when (info.modelType) {
        ModelType.LLM -> "llm"
        ModelType.EMBEDDING -> "embedding"
        else -> "unknown"
      },
      maxContextTokens = runCatching { info.maxContextTokens() }.getOrDefault(0),
      dynamicContext = runCatching { info.isDynamicContext() }.getOrDefault(false),
      vision = modalities?.vision ?: false,
      audio = modalities?.audio ?: false,
      textBackends = runCatching { info.supportedBackends(Modality.TEXT) }.getOrDefault(emptyList()).map {
        when (it) {
          BackendType.CPU -> "cpu"
          BackendType.GPU -> "gpu"
          BackendType.NPU -> "npu"
        }
      },
      npuBrand = brand?.takeIf { it != NpuBrand.UNKNOWN }?.name?.lowercase(),
      socName = runCatching { info.socName(Modality.TEXT) }.getOrNull()?.takeIf { it.isNotBlank() },
      minRuntimeVersion = runCatching { info.minRuntimeVersion() }.getOrNull()?.takeIf { it.isNotBlank() },
      supportsFunctionCalling = runCatching { llm?.supportsFunctionCalling() }.getOrNull() ?: false,
      supportsThinking = runCatching { llm?.supportsThinking() }.getOrNull() ?: false,
      speculativeDecoding = runCatching { llm?.hasSpeculativeDecodingSupport() }.getOrNull() ?: false,
      defaultTemperature = sampler?.temperature?.toDouble()?.takeIf { it > 0 },
      defaultTopK = sampler?.topK?.takeIf { it > 0 },
      defaultTopP = sampler?.topP?.toDouble()?.takeIf { it > 0 },
    )
  }

  @OptIn(ExperimentalApi::class)
  override fun createEngine(config: LmEngineConfig): LmEngine {
    // Process-wide flag read when the engine is created: per-turn TTFT and prefill/decode counts.
    ExperimentalFlags.enableBenchmark = config.benchmark
    val backend = backendFor(config.backend, config)
    val engine = Engine(
      EngineConfig(
        modelPath = config.path,
        backend = backend,
        visionBackend = if (config.vision) Backend.GPU() else null,
        audioBackend = if (config.audio) Backend.CPU() else null,
        maxNumTokens = config.maxNumTokens,
        cacheDir = config.cacheDir,
      ),
    )
    try {
      engine.initialize()
    } catch (t: Throwable) {
      runCatching { engine.close() }
      if (t is LiteRtLmJniException) throw LmStatusException.parse(t.message, t)
      throw t
    }
    return RealEngine(engine, config.benchmark)
  }

  private fun backendFor(name: String, config: LmEngineConfig): Backend = when (name) {
    "cpu" -> Backend.CPU(threadCount = config.cpuThreads)
    "gpu" -> Backend.GPU()
    "npu" -> Backend.NPU(nativeLibraryDir = config.nativeLibraryDir)
    else -> throw IllegalArgumentException("unknown backend '$name'")
  }

  private class RealEngine(private val engine: Engine, private val benchmark: Boolean) : LmEngine {
    override fun createConversation(spec: LmConversationSpec): LmConversation {
      val conversation = try {
        engine.createConversation(
          ConversationConfig(
            systemInstruction = spec.systemInstruction?.takeIf { it.isNotEmpty() }?.let { Contents.of(it) },
            initialMessages = spec.history.map(::toMessage),
            tools = spec.toolsJson.map { tool(SchemaOnlyTool(it)) },
            samplerConfig = spec.sampler?.let { SamplerConfig(it.topK, it.topP, it.temperature, it.seed) },
            automaticToolCalling = false,
            enableResponseFormat = spec.enableResponseFormat,
          ),
        )
      } catch (e: LiteRtLmJniException) {
        throw LmStatusException.parse(e.message, e)
      }
      return RealConversation(conversation, benchmark)
    }

    @OptIn(ExperimentalApi::class)
    override fun rendersTools(): Boolean? = try {
      engine.createConversation(
        ConversationConfig(
          systemInstruction = Contents.of("probe"),
          tools = listOf(tool(SchemaOnlyTool(PROBE_TOOL))),
          automaticToolCalling = false,
        ),
      ).use { it.renderPrefaceIntoString().contains(PROBE_NAME) }
    } catch (_: Throwable) {
      null
    }

    override fun close() = engine.close()
  }

  private class RealConversation(private val conversation: Conversation, private val benchmark: Boolean) :
    LmConversation {
    override fun send(message: LmMessage, options: LmSendOptions, callback: LmCallback) {
      val thinking = when {
        options.enableThinking == null -> null
        options.enableThinking -> ThinkingConfig(true, options.thinkingBudget ?: -1)
        else -> ThinkingConfig(false, 0)
      }
      try {
        conversation.sendMessageAsync(
          toMessage(message),
          object : MessageCallback {
            override fun onMessage(message: Message) {
              val text = message.contents.contents.filterIsInstance<Content.Text>().joinToString("") { it.text }
              val thought = message.channels["thought"]
              if (!thought.isNullOrEmpty()) callback.onThought(thought)
              if (text.isNotEmpty()) callback.onText(text)
              if (message.toolCalls.isNotEmpty()) {
                callback.onToolCalls(message.toolCalls.map { LmToolCall(it.name, JsonValues.encode(it.arguments)) })
              }
            }

            override fun onDone() = callback.onDone()

            override fun onError(throwable: Throwable) {
              when (throwable) {
                is CancellationException -> callback.onCancelled()
                is LiteRtLmJniException -> callback.onError(LmStatusException.parse(throwable.message, throwable))
                else -> callback.onError(throwable)
              }
            }
          },
          maxOutputToken = options.maxOutputTokens,
          thinkingConfig = thinking,
          responseFormat = options.responseSchemaJson?.let { ResponseFormat.json(it) },
        )
      } catch (e: LiteRtLmJniException) {
        throw LmStatusException.parse(e.message, e)
      }
    }

    override fun cancel() {
      if (conversation.isAlive) conversation.cancelProcess()
    }

    override fun tokenCount(): Int? = runCatching { conversation.getTokenCount() }.getOrNull()

    @OptIn(ExperimentalApi::class)
    override fun benchmark(): LmBenchmark? {
      if (!benchmark) return null
      val b = runCatching { conversation.getBenchmarkInfo() }.getOrNull() ?: return null
      return LmBenchmark(
        prefillTokens = b.lastPrefillTokenCount,
        decodeTokens = b.lastDecodeTokenCount,
        timeToFirstTokenSec = b.timeToFirstTokenInSecond,
        prefillTokensPerSec = b.lastPrefillTokensPerSecond,
        decodeTokensPerSec = b.lastDecodeTokensPerSecond,
      )
    }

    override fun close() {
      if (conversation.isAlive) conversation.close()
    }
  }

  /** Registers a schema with the engine; never executed (`automaticToolCalling = false`). */
  private class SchemaOnlyTool(private val description: String) : OpenApiTool {
    override fun getToolDescriptionJsonString(): String = description

    override fun execute(paramsJsonString: String): String =
      throw IllegalStateException("Sherpa executes tools itself (automaticToolCalling = false)")
  }

  internal companion object {
    const val PROBE_NAME = "sherpa_probe_tool"
    const val PROBE_TOOL =
      """{"name":"$PROBE_NAME","description":"probe","parameters":{"type":"object","properties":{}}}"""

    fun toMessage(m: LmMessage): Message = when (m.role) {
      "system" -> Message.system(Contents.of(m.text ?: ""))
      "user" -> Message.user(Contents.of(userParts(m)))
      "model" -> Message.model(
        Contents.of(listOfNotNull(m.text?.takeIf { it.isNotEmpty() }?.let { Content.Text(it) })),
        m.toolCalls.map { ToolCall(it.name, JsonValues.decodeObject(it.argumentsJson)) },
        m.thought?.takeIf { it.isNotEmpty() }?.let { mapOf("thought" to it) } ?: emptyMap(),
      )
      "tool" -> Message.tool(
        Contents.of(m.toolResponses.map { Content.ToolResponse(it.name, JsonParser.parseString(it.responseJson)) }),
      )
      else -> throw IllegalArgumentException("unknown role '${m.role}'")
    }

    private fun userParts(m: LmMessage): List<Content> = buildList {
      m.images.forEach { add(Content.ImageBytes(it)) }
      m.imagePaths.forEach { add(Content.ImageFile(it)) }
      add(Content.Text(m.text ?: ""))
    }
  }
}
