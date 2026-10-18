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
      );

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

  String get secretKey => 'provider/$id/api_key';

  ProviderConfig copyWith({
    String? displayName,
    Uri? baseUrl,
    ServerProfile? profile,
    Map<String, String>? headers,
    String? defaultModelId,
    bool? allowLocalNetwork,
    Map<String, ModelCapabilities>? modelOverrides,
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
      });
}
