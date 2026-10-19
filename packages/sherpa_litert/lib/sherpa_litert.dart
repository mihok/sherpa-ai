/// On-device model providers for Sherpa on Android (Flutter plugin):
///
/// * [LiteRtLmProvider] — `.litertlm` models through LiteRT-LM 0.18.0
///   (CPU/GPU, NPU for SoC-specific files), native or prompted tool calling,
///   conversation reuse with rebuild on divergence, memory-pressure release.
/// * [GeminiNanoProvider] — Gemini Nano through the ML Kit GenAI Prompt API
///   (AICore), foreground only, with status and download.
///
/// Both talk to Kotlin through one Pigeon API ([LiteRtBackend]); on iOS and
/// desktop they compile and report "unsupported".
library;

export 'src/backend.dart' show LiteRtBackend, PigeonLiteRtBackend, SherpaLitert, UnsupportedLiteRtBackend;
export 'src/common/availability.dart';
export 'src/common/errors.dart' show LiteRtStatus, NanoErrorCode, kNanoBackgroundMessage;
export 'src/common/event_router.dart' show LiteRtEventRouter, NativeStream, kStreamCredits;
export 'src/common/foreground.dart';
export 'src/common/prompted_tools.dart';
export 'src/gemini_nano/gemini_nano_provider.dart';
export 'src/gemini_nano/nano_types.dart';
export 'src/gemini_nano/prompt_renderer.dart';
export 'src/litert_lm/conversation_cache.dart';
export 'src/litert_lm/event_mapper.dart';
export 'src/litert_lm/litert_lm_provider.dart';
export 'src/litert_lm/model_spec.dart';
export 'src/litert_lm/request_mapper.dart';
// Wire types: needed to implement LiteRtBackend.
export 'src/messages.pigeon.dart'
    show
        ChatMessageMsg,
        ConversationSpecMsg,
        ErrorMsg,
        EventBatch,
        EventKind,
        GenerationStatsMsg,
        LiteRtEvent,
        LoadRequestMsg,
        LoadResultMsg,
        ModelInfoMsg,
        NanoConfigMsg,
        NanoRequestMsg,
        NanoStatusMsg,
        PlatformInfoMsg,
        SendRequestMsg,
        ToolCallMsg,
        ToolResponseMsg;
