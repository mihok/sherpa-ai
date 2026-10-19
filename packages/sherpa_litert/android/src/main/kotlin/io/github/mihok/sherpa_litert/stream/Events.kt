package io.github.mihok.sherpa_litert.stream

import io.github.mihok.sherpa_litert.ErrorMsg
import io.github.mihok.sherpa_litert.EventKind
import io.github.mihok.sherpa_litert.GenerationStatsMsg
import io.github.mihok.sherpa_litert.LiteRtEvent
import io.github.mihok.sherpa_litert.ToolCallMsg

/** Event constructors, so producers never build half-filled [LiteRtEvent]s. */
object Events {
  fun text(delta: String) = LiteRtEvent(EventKind.TEXT_DELTA, text = delta)

  fun reasoning(delta: String) = LiteRtEvent(EventKind.REASONING_DELTA, text = delta)

  fun toolCalls(calls: List<ToolCallMsg>) = LiteRtEvent(EventKind.TOOL_CALLS, toolCalls = calls)

  fun done(stats: GenerationStatsMsg) = LiteRtEvent(EventKind.DONE, stats = stats)

  fun cancelled(reason: String) = LiteRtEvent(EventKind.CANCELLED, detail = reason)

  fun error(source: String, code: Long, message: String, retryAfterMs: Long? = null) =
    LiteRtEvent(EventKind.ERROR, error = ErrorMsg(source, code, message, retryAfterMs))

  fun downloadStarted(bytes: Long) = LiteRtEvent(EventKind.DOWNLOAD_STARTED, value = bytes)

  fun downloadProgress(bytes: Long) = LiteRtEvent(EventKind.DOWNLOAD_PROGRESS, value = bytes)

  fun downloadCompleted() = LiteRtEvent(EventKind.DOWNLOAD_COMPLETED)

  fun downloadFailed(error: ErrorMsg) = LiteRtEvent(EventKind.DOWNLOAD_FAILED, error = error)

  fun trimMemory(level: Int) = LiteRtEvent(EventKind.TRIM_MEMORY, value = level.toLong())

  fun engineReleased(reason: String) = LiteRtEvent(EventKind.ENGINE_RELEASED, detail = reason)
}
