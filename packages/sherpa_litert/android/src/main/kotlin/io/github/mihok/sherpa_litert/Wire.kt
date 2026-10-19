package io.github.mihok.sherpa_litert

import io.github.mihok.sherpa_litert.lm.LmConversationSpec
import io.github.mihok.sherpa_litert.lm.LmLoadRequest
import io.github.mihok.sherpa_litert.lm.LmLoadResult
import io.github.mihok.sherpa_litert.lm.LmMessage
import io.github.mihok.sherpa_litert.lm.LmModelInfo
import io.github.mihok.sherpa_litert.lm.LmSampler
import io.github.mihok.sherpa_litert.lm.LmSendOptions
import io.github.mihok.sherpa_litert.lm.LmToolCall
import io.github.mihok.sherpa_litert.lm.LmToolResponse

/** Pigeon messages ⇄ engine types (field copies only). */
internal object Wire {
  fun message(m: ChatMessageMsg) = LmMessage(
    role = m.role,
    text = m.text,
    toolCalls = m.toolCalls.orEmpty().map { LmToolCall(it.name, it.argumentsJson) },
    toolResponses = m.toolResponses.orEmpty().map { LmToolResponse(it.name, it.responseJson) },
    images = m.images.orEmpty(),
    imagePaths = m.imagePaths.orEmpty(),
    thought = m.thought,
  )

  fun spec(s: ConversationSpecMsg): LmConversationSpec {
    val topK = s.topK
    val topP = s.topP
    val temperature = s.temperature
    val sampler = if (topK != null && topP != null && temperature != null) {
      LmSampler(topK.toInt(), topP, temperature, (s.seed ?: 0L).toInt())
    } else {
      null
    }
    return LmConversationSpec(
      id = s.conversationId,
      systemInstruction = s.systemInstruction,
      history = s.history.map(::message),
      toolsJson = s.toolsJson,
      sampler = sampler,
      enableResponseFormat = s.enableResponseFormat,
    )
  }

  fun options(r: SendRequestMsg) = LmSendOptions(
    maxOutputTokens = r.maxOutputTokens?.toInt(),
    enableThinking = r.enableThinking,
    thinkingBudget = r.thinkingBudget?.toInt(),
    responseSchemaJson = r.responseSchemaJson,
  )

  fun load(r: LoadRequestMsg) = LmLoadRequest(
    path = r.path,
    backends = r.backends,
    maxNumTokens = r.maxNumTokens?.toInt(),
    cpuThreads = r.cpuThreads?.toInt(),
    cacheDir = r.cacheDir,
    vision = r.vision,
    audio = r.audio,
    benchmark = r.benchmark,
  )

  fun loadResult(r: LmLoadResult) = LoadResultMsg(r.backend, r.failures, r.initMs, r.reused, r.rendersTools)

  fun info(i: LmModelInfo, fileBytes: Long) = ModelInfoMsg(
    modelType = i.modelType,
    maxContextTokens = i.maxContextTokens.toLong(),
    dynamicContext = i.dynamicContext,
    vision = i.vision,
    audio = i.audio,
    textBackends = i.textBackends,
    npuBrand = i.npuBrand,
    socName = i.socName,
    minRuntimeVersion = i.minRuntimeVersion,
    supportsFunctionCalling = i.supportsFunctionCalling,
    supportsThinking = i.supportsThinking,
    speculativeDecoding = i.speculativeDecoding,
    defaultTemperature = i.defaultTemperature,
    defaultTopK = i.defaultTopK?.toLong(),
    defaultTopP = i.defaultTopP,
    fileBytes = fileBytes,
  )
}
