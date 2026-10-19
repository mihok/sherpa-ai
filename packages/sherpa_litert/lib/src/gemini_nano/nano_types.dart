import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../messages.pigeon.dart';

/// `ModelReleaseStage` of ML Kit's `ModelConfig`.
enum NanoReleaseStage {
  stable(0),
  preview(1);

  const NanoReleaseStage(this.value);

  final int value;
}

/// `ModelPreference` of ML Kit's `ModelConfig`.
enum NanoPreference {
  fast(1),
  full(2);

  const NanoPreference(this.value);

  final int value;
}

/// ML Kit `FeatureStatus` values.
abstract final class NanoFeatureStatus {
  static const unavailable = 0;
  static const downloadable = 1;
  static const downloading = 2;
  static const available = 3;
}

/// Policy knobs of [GeminiNanoProvider].
@immutable
final class GeminiNanoOptions {
  const GeminiNanoOptions({
    this.releaseStage = NanoReleaseStage.stable,
    this.preference = NanoPreference.fast,
    this.maxOutputTokens = 1024,
    this.toolCalling = true,
    this.vision = false,
    this.countTokens = true,
    this.fallbackInputTokenLimit = 4000,
  });

  final NanoReleaseStage releaseStage;
  final NanoPreference preference;

  /// Default output cap (requests may lower it). The docs warn against
  /// outputs above 4K tokens.
  final int maxOutputTokens;

  /// Offer tools through the prompted JSON format (the Prompt API has no
  /// tool-calling API).
  final bool toolCalling;

  /// Send images of the last user message (`ImagePart`). Off until checked
  /// on devices: the docs do not say which Nano versions take images.
  final bool vision;

  /// `countTokens` before (prompt) and after (output) a reply for usage.
  final bool countTokens;

  /// "Input must be under 4000 tokens", used until `getTokenLimit` answers.
  final int fallbackInputTokenLimit;

  NanoConfigMsg get config => NanoConfigMsg(releaseStage: releaseStage.value, preference: preference.value);
}

/// What `checkStatus` and the feature probes said.
@immutable
final class GeminiNanoInfo {
  const GeminiNanoInfo({
    required this.featureStatus,
    this.baseModelName,
    this.tokenLimit,
    this.systemPrompt,
    this.thinking,
    this.structuredOutput,
    this.caching,
  });

  factory GeminiNanoInfo.fromMsg(NanoStatusMsg m) => GeminiNanoInfo(
        featureStatus: m.featureStatus,
        baseModelName: m.baseModelName,
        tokenLimit: m.tokenLimit,
        systemPrompt: m.systemPrompt,
        thinking: m.thinking,
        structuredOutput: m.structuredOutput,
        caching: m.caching,
      );

  final int featureStatus;

  /// e.g. `nano-v3`.
  final String? baseModelName;
  final int? tokenLimit;
  final bool? systemPrompt;
  final bool? thinking;
  final bool? structuredOutput;
  final bool? caching;

  bool get available => featureStatus == NanoFeatureStatus.available;

  JsonMap toJson() => compact({
        'featureStatus': featureStatus,
        'baseModelName': baseModelName,
        'tokenLimit': tokenLimit,
        'systemPrompt': systemPrompt,
        'thinking': thinking,
        'structuredOutput': structuredOutput,
        'caching': caching,
      });
}

/// Progress of [GeminiNanoProvider.download].
@immutable
sealed class NanoDownloadUpdate {
  const NanoDownloadUpdate();
}

final class NanoDownloadStarted extends NanoDownloadUpdate {
  const NanoDownloadStarted(this.totalBytes);

  final int totalBytes;
}

final class NanoDownloadProgress extends NanoDownloadUpdate {
  const NanoDownloadProgress(this.downloadedBytes, {this.totalBytes});

  final int downloadedBytes;
  final int? totalBytes;

  /// 0..1 when the total is known.
  double? get fraction =>
      totalBytes == null || totalBytes! <= 0 ? null : (downloadedBytes / totalBytes!).clamp(0.0, 1.0).toDouble();
}

final class NanoDownloadCompleted extends NanoDownloadUpdate {
  const NanoDownloadCompleted();
}

final class NanoDownloadFailed extends NanoDownloadUpdate {
  const NanoDownloadFailed(this.error);

  final ProviderException error;
}
