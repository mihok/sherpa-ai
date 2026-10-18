import 'package:flutter/foundation.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_providers/sherpa_providers.dart';

import '../../../state/provider_location.dart';
import '../../../state/services.dart';

/// The model a chat talks to, plus what the privacy badge must say about it.
@immutable
final class ModelSelection {
  const ModelSelection({
    required this.providerId,
    required this.modelId,
    required this.providerName,
    required this.modelName,
    required this.location,
    this.host,
  });

  final String providerId;
  final String modelId;
  final String providerName;
  final String modelName;
  final ExecutionLocation location;

  /// Where prompts go when they leave the device (shown verbatim: the user
  /// should be able to recognise the exact server).
  final String? host;

  ModelChoice get choice => ModelChoice(providerId: providerId, modelId: modelId);

  bool get leavesDevice => location != ExecutionLocation.onDevice;

  PrivacyBadgeData get privacy => PrivacyBadgeData(location: location, host: host);

  ModelSelection copyWith({String? modelName, String? providerName, ExecutionLocation? location, String? host}) =>
      ModelSelection(
        providerId: providerId,
        modelId: modelId,
        providerName: providerName ?? this.providerName,
        modelName: modelName ?? this.modelName,
        location: location ?? this.location,
        host: host ?? this.host,
      );

  @override
  bool operator ==(Object other) =>
      other is ModelSelection &&
      other.providerId == providerId &&
      other.modelId == modelId &&
      other.providerName == providerName &&
      other.modelName == modelName &&
      other.location == location &&
      other.host == host;

  @override
  int get hashCode => Object.hash(providerId, modelId, providerName, modelName, location, host);
}

/// The two facts every privacy badge shows: does data leave the device, and
/// if so, to which host.
@immutable
final class PrivacyBadgeData {
  const PrivacyBadgeData({required this.location, this.host});

  final ExecutionLocation location;
  final String? host;

  bool get leavesDevice => location != ExecutionLocation.onDevice;

  /// Short label for text-only contexts: "On device", "→ api.anthropic.com".
  String get shortLabel => switch (location) {
        ExecutionLocation.onDevice => 'On device',
        _ => host == null ? 'Leaves device' : '→ $host',
      };

  /// Full sentence for screen readers and tooltips; worded exactly like the
  /// design system's `PrivacyBadge` so every surface says the same thing.
  String get description => switch (location) {
        ExecutionLocation.onDevice => 'Runs on this device. Nothing leaves your phone.',
        ExecutionLocation.localNetwork =>
          'Leaves this device. Sent to ${host ?? 'a server'} on your local network.',
        ExecutionLocation.remote => 'Leaves this device. Sent to ${host ?? 'a remote server'}.',
      };
}

/// Classifies a configured endpoint before (or without) building the
/// provider, with the app-wide rules in `state/provider_location.dart`.
PrivacyBadgeData privacyForConfig(ProviderConfig config) =>
    PrivacyBadgeData(location: locationOf(config), host: hostLabel(config.baseUrl));

/// What a built provider reports about itself.
PrivacyBadgeData privacyForProvider(ProviderInfo info) => PrivacyBadgeData(
      location: info.location,
      host: info.baseUrl == null ? null : hostLabel(info.baseUrl!),
    );

/// Compact token label: 8192 → "8K", 200000 → "200K", 1048576 → "1M",
/// 1530 → "1.5K".
///
/// Context windows are quoted in binary units by local runtimes (8192,
/// 131072) and decimal ones by remote APIs (200000), so exact powers of
/// 1024 use binary units and everything else decimal.
String formatTokenCount(int tokens) {
  final binary = tokens >= 1024 && tokens % 1024 == 0;
  final kilo = binary ? 1024 : 1000;
  String fmt(double v) => v >= 10 || v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(1);
  if (tokens >= kilo * kilo) return '${fmt(tokens / (kilo * kilo))}M';
  if (tokens >= kilo) return '${fmt(tokens / kilo)}K';
  return '$tokens';
}
