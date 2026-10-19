import 'package:sherpa_hub/sherpa_hub.dart' show ModelFormat;

import '../../state/services.dart' show localProviderId;

/// Provider ids of the on-device providers the registry reserves next to
/// [localProviderId] (llama.cpp over the model library). None of them has
/// a `ProviderConfig`; `LocalProviderRegistry` resolves them itself, each
/// only on its platform (and reports it unavailable elsewhere).
///
/// * [mlxProviderId] — MLX library models (iOS);
/// * [appleFmProviderId] — Apple Intelligence's system model (iOS 26+);
/// * [liteRtProviderId] — LiteRT-LM library models (Android);
/// * [geminiNanoProviderId] — Gemini Nano through AICore (Android,
///   foreground only).
const String mlxProviderId = 'mlx';
const String appleFmProviderId = 'apple_fm';
const String liteRtProviderId = 'litert_lm';
const String geminiNanoProviderId = 'gemini_nano';

/// The platform providers (everything on-device but llama.cpp).
const Set<String> platformProviderIds = {mlxProviderId, appleFmProviderId, liteRtProviderId, geminiNanoProviderId};

/// Every on-device provider id, llama.cpp first.
const List<String> onDeviceProviderIds = [
  localProviderId,
  mlxProviderId,
  liteRtProviderId,
  appleFmProviderId,
  geminiNanoProviderId,
];

/// Whether chats on [providerId] run on this phone (no config; the privacy
/// badge says "on device").
bool isOnDeviceProviderId(String providerId) => providerId == localProviderId || platformProviderIds.contains(providerId);

/// The operating system's own model (no library file): Apple Intelligence,
/// Gemini Nano.
bool isSystemModelProvider(String providerId) => providerId == appleFmProviderId || providerId == geminiNanoProviderId;

/// Gemini Nano: AICore refuses requests while Sherpa is not on screen, even
/// from a foreground service, so background work (a run that continues
/// after the user leaves, MCP sampling, summaries) must never pick it
/// without saying so.
bool isForegroundOnlyProvider(String providerId) => providerId == geminiNanoProviderId;

/// What the UI says about a foreground-only provider.
const String kForegroundOnlyExplanation =
    'Gemini Nano only runs while Sherpa is on screen: Android stops it when you leave the app, even in the '
    'middle of a reply. A reply that was cut off continues when you come back; background work uses another model.';

/// What lists call an on-device provider; null for any other id.
String? onDeviceProviderName(String providerId) => switch (providerId) {
      localProviderId => kOnDeviceName,
      mlxProviderId => 'On this device (MLX)',
      liteRtProviderId => 'On this device (LiteRT)',
      appleFmProviderId => 'Apple Intelligence',
      geminiNanoProviderId => 'Gemini Nano',
      _ => null,
    };

/// What the picker, chat header and session list call the built-in
/// llama.cpp provider (`kLocalProviderName`); kept here so this file
/// imports no engine.
const String kOnDeviceName = 'On this device';

/// The provider a library model runs on, by its format: GGUF → llama.cpp
/// ([localProviderId]), MLX → [mlxProviderId], LiteRT → [liteRtProviderId].
/// Null for formats no on-device runtime loads.
String? libraryProviderIdFor(ModelFormat format) => switch (format) {
      ModelFormat.gguf || ModelFormat.ggufPart => localProviderId,
      ModelFormat.mlx => mlxProviderId,
      ModelFormat.litert => liteRtProviderId,
      _ => null,
    };
