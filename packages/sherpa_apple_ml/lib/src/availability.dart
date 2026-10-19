import 'package:meta/meta.dart';

/// Whether an Apple on-device engine can serve requests right now.
enum AppleMlStatus {
  /// Ready: requests will run (subject to memory admission for MLX).
  available,

  /// Not ready, but the user or the system can fix it: the model files still
  /// need downloading (MLX), or the system model is downloading / Apple
  /// Intelligence is switched off (Foundation Models).
  downloadable,

  /// Cannot work on this device or build (not iOS, simulator, iOS too old,
  /// ineligible device, unsupported architecture, ...).
  unsupported,
}

/// Machine-readable reason behind an [AppleMlAvailability].
enum AppleMlReason {
  none,

  /// Not running on iOS (Android, desktop, host tests).
  notIos,

  /// iOS older than the engine's floor (MLX 17, Foundation Models 26).
  osTooOld,

  /// MLX cannot evaluate on the iOS Simulator (no suitable Metal GPU family).
  simulator,

  /// No Metal device.
  noMetalDevice,

  /// The plugin was built without this engine (CocoaPods build has no MLX;
  /// an SDK before iOS 26 has no FoundationModels).
  notCompiled,

  // Foundation Models (`SystemLanguageModel.Availability.UnavailableReason`).
  deviceNotEligible,
  appleIntelligenceNotEnabled,
  modelNotReady,

  // MLX model directory.
  modelMissing,
  modelIncomplete,
  unsupportedArchitecture,
  legacyFormat,

  /// The weights alone exceed what the app may allocate now.
  insufficientMemory,
  unknown,
}

/// The verdict of `MlxProvider.availability` /
/// `AppleFoundationModelsProvider.status`.
@immutable
final class AppleMlAvailability {
  const AppleMlAvailability(this.status, this.reason, this.message, {this.details = const {}});

  const AppleMlAvailability.available({String message = 'Ready.', Map<String, Object?> details = const {}})
    : this(AppleMlStatus.available, AppleMlReason.none, message, details: details);

  final AppleMlStatus status;
  final AppleMlReason reason;

  /// A sentence for the UI (English; the app may localize from [reason]).
  final String message;

  /// Facts behind the verdict (bytes, model type, OS version, ...).
  final Map<String, Object?> details;

  bool get isAvailable => status == AppleMlStatus.available;

  @override
  String toString() => 'AppleMlAvailability(${status.name}, ${reason.name}: $message)';
}
