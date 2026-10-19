import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart';

/// Whether an on-device provider can run here, for the UI.
enum AvailabilityState {
  /// Ready to use.
  available,

  /// Supported, but a model must be downloaded first (Gemini Nano:
  /// `GeminiNanoProvider.download`).
  downloadable,

  /// A download is in progress (started by this or another app).
  downloading,

  /// Cannot run on this device or platform; [ProviderAvailability.reason]
  /// says why.
  unsupported,
}

/// The answer of `LiteRtLmProvider.availability` and
/// `GeminiNanoProvider.status`.
///
/// [reason] is user-facing English (one sentence). [code] is stable and
/// machine-readable: `ok`, `not_android`, `plugin_missing`, `runtime_missing`,
/// `unsupported_format`, `file_missing`, `inspect_failed`, `not_an_llm`,
/// `runtime_too_old`, `wrong_soc` (LiteRT-LM); `downloadable`,
/// `downloading`, `aicore_unavailable`, `feature_not_found`,
/// `aicore_binding_failed`, `needs_system_update`, `aicore_incompatible`,
/// `not_supported`, `status_error` (Gemini Nano).
@immutable
final class ProviderAvailability {
  const ProviderAvailability(this.state, this.code, this.reason, {this.details = const {}});

  const ProviderAvailability.available({String reason = 'Ready.', JsonMap details = const {}})
      : this(AvailabilityState.available, 'ok', reason, details: details);

  const ProviderAvailability.unsupported(String code, String reason, {JsonMap details = const {}})
      : this(AvailabilityState.unsupported, code, reason, details: details);

  final AvailabilityState state;
  final String code;
  final String reason;

  /// Extra facts for diagnostics (backends, context, SoC, error codes).
  final JsonMap details;

  bool get isAvailable => state == AvailabilityState.available;

  bool get canDownload => state == AvailabilityState.downloadable;

  @override
  String toString() => 'ProviderAvailability(${state.name}, $code: $reason)';
}
