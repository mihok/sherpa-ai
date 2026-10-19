import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart';

/// Wire protocol a remote endpoint speaks.
enum ApiFlavor {
  /// Anthropic Messages API (native, not the OpenAI-compat layer).
  anthropic,

  /// OpenAI Chat Completions; also llama.cpp server, Ollama, LM Studio,
  /// vLLM, OpenRouter, DeepSeek, HF Inference Providers router.
  openAiChat,

  /// OpenAI Responses API, used statelessly (`store: false`). Required for
  /// tool calling on current api.openai.com models.
  openAiResponses,
}

/// Known server implementations behind [ApiFlavor.openAiChat]. Each has
/// quirks (reasoning field name, context discovery, tool_choice support).
enum ServerProfile {
  auto,
  openAi,
  llamaCpp,
  ollama,
  lmStudio,
  vllm,
  openRouter,
  deepSeek,
  huggingFaceRouter,
  generic,
}

/// A user-configured remote endpoint. Secrets are NOT stored here: the API
/// key lives in the [SecretStore] under [secretKey].
@immutable
final class ProviderConfig {
  const ProviderConfig({
    required this.id,
    required this.flavor,
    required this.displayName,
    required this.baseUrl,
    this.profile = ServerProfile.auto,
    this.headers = const {},
    this.defaultModelId,
    this.allowLocalNetwork = false,
    this.modelOverrides = const {},
    this.streamIdleTimeout = defaultStreamIdleTimeout,
    this.streamStartTimeout = defaultStreamStartTimeout,
  });

  factory ProviderConfig.fromJson(JsonMap j) => ProviderConfig(
        id: j.req<String>('id'),
        flavor: ApiFlavor.values.byName(j.req<String>('flavor')),
        displayName: j.req<String>('displayName'),
        baseUrl: Uri.parse(j.req<String>('baseUrl')),
        profile: ServerProfile.values.byName(j.opt<String>('profile') ?? 'auto'),
        headers: (j.optObj('headers') ?? const {}).map((k, v) => MapEntry(k, v.toString())),
        defaultModelId: j.opt<String>('defaultModelId'),
        allowLocalNetwork: j.opt<bool>('allowLocalNetwork') ?? false,
        modelOverrides: {
          for (final e in (j.optObj('modelOverrides') ?? const {}).entries)
            e.key: ModelCapabilities.fromJson((e.value! as Map).cast<String, Object?>()),
        },
        streamIdleTimeout: _seconds(j.optInt('streamIdleTimeoutSeconds')) ?? defaultStreamIdleTimeout,
        streamStartTimeout: _seconds(j.optInt('streamStartTimeoutSeconds')) ?? defaultStreamStartTimeout,
      );

  static Duration? _seconds(int? s) => s == null || s <= 0 ? null : Duration(seconds: s);

  /// Default for [streamIdleTimeout]. Servers stream tokens (or keep-alive
  /// pings: Anthropic `ping`, OpenRouter comments, llama.cpp `:` lines)
  /// well within this; only a dead connection stays silent this long.
  static const Duration defaultStreamIdleTimeout = Duration(seconds: 90);

  /// Default for [streamStartTimeout]: generous, because a local server on
  /// slow hardware processes the whole prompt before its first token.
  static const Duration defaultStreamStartTimeout = Duration(minutes: 10);

  final String id;
  final ApiFlavor flavor;
  final String displayName;
  final Uri baseUrl;
  final ServerProfile profile;

  /// Extra, NON-secret headers (e.g. `OpenAI-Organization`). Anything that
  /// looks like a credential belongs in the secret store.
  final Map<String, String> headers;
  final String? defaultModelId;

  /// Permit http:// and private addresses (user's own LAN server).
  final bool allowLocalNetwork;

  /// User-set capability overrides per model id (e.g. context length).
  final Map<String, ModelCapabilities> modelOverrides;

  /// Longest silence allowed between two chunks of a streaming response
  /// once it has started. Longer means the connection is treated as dead
  /// (a half-open socket after a network handoff, a LAN host that went to
  /// sleep, a dropped NAT mapping): the request is aborted and the stream
  /// fails with a retryable [ProviderErrorKind.timeout].
  final Duration streamIdleTimeout;

  /// Longest wait for a streaming response to start: for its headers, and
  /// then again for its first body chunk. Separate from
  /// [streamIdleTimeout] because prompt processing (prefill) happens before
  /// the first token and can take minutes on a slow local server.
  final Duration streamStartTimeout;

  String get secretKey => 'provider/$id/api_key';

  ProviderConfig copyWith({
    String? displayName,
    Uri? baseUrl,
    ServerProfile? profile,
    Map<String, String>? headers,
    String? defaultModelId,
    bool? allowLocalNetwork,
    Map<String, ModelCapabilities>? modelOverrides,
    Duration? streamIdleTimeout,
    Duration? streamStartTimeout,
  }) =>
      ProviderConfig(
        id: id,
        flavor: flavor,
        displayName: displayName ?? this.displayName,
        baseUrl: baseUrl ?? this.baseUrl,
        profile: profile ?? this.profile,
        headers: headers ?? this.headers,
        defaultModelId: defaultModelId ?? this.defaultModelId,
        allowLocalNetwork: allowLocalNetwork ?? this.allowLocalNetwork,
        modelOverrides: modelOverrides ?? this.modelOverrides,
        streamIdleTimeout: streamIdleTimeout ?? this.streamIdleTimeout,
        streamStartTimeout: streamStartTimeout ?? this.streamStartTimeout,
      );

  JsonMap toJson() => compact({
        'id': id,
        'flavor': flavor.name,
        'displayName': displayName,
        'baseUrl': baseUrl.toString(),
        'profile': profile.name,
        'headers': headers.isEmpty ? null : headers,
        'defaultModelId': defaultModelId,
        'allowLocalNetwork': allowLocalNetwork ? true : null,
        'modelOverrides': modelOverrides.isEmpty
            ? null
            : {for (final e in modelOverrides.entries) e.key: e.value.toJson()},
        'streamIdleTimeoutSeconds':
            streamIdleTimeout == defaultStreamIdleTimeout ? null : streamIdleTimeout.inSeconds,
        'streamStartTimeoutSeconds':
            streamStartTimeout == defaultStreamStartTimeout ? null : streamStartTimeout.inSeconds,
      });
}
