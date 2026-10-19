/// OpenAI-wire adapters: Chat Completions (with per-server quirk profiles,
/// server detection and context discovery) and the stateless Responses API.
library;

export 'chat_provider.dart' show OpenAiChatProvider;
export 'chat_request.dart' show ChatRequestBody, buildChatRequest, effortValue, visibleTools;
export 'chat_stream.dart' show ChatStreamParser;
export 'detect.dart' show classifyProbes, detectServerProfile, profileForKnownHost;
export 'discovery.dart' show ModelDiscovery, chatToolsUnavailable;
export 'endpoint.dart' show rejectsParameter;
export 'known_models.dart' show KnownModel, lookupKnownModel, openAiKnownModels, openAiModelTakesPdf;
export 'quirks.dart';
export 'responses_provider.dart' show OpenAiResponsesProvider;
export 'responses_request.dart'
    show ResponsesInputMapper, ResponsesRequestBody, buildResponsesRequest, responsesOptionalParams;
export 'responses_stream.dart' show ResponsesStreamParser;
export 'usage.dart' show parseChatUsage, parseResponsesUsage, parseTimings;
