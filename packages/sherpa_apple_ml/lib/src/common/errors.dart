import 'package:flutter/services.dart' show PlatformException;
import 'package:sherpa_core/sherpa_core.dart';

/// Error codes the Swift side puts in `AmEvent.code` of an `error` event and
/// in `SherpaAppleMlError.code` of a failed host call. Swift classifies the
/// native error (it is the only side that can see the Swift type); the
/// mapping onto core kinds is here.
abstract final class AppleMlErrorCode {
  static const outOfMemory = 'outOfMemory';
  static const contextOverflow = 'contextOverflow';
  static const modelNotFound = 'modelNotFound';
  static const unsupported = 'unsupported';
  static const invalidRequest = 'invalidRequest';
  static const rateLimited = 'rateLimited';
  static const timeout = 'timeout';
  static const busy = 'busy';
  static const server = 'server';

  /// An MLX error caught by the plugin's error handler (instead of MLX's
  /// default handler, which exits the process).
  static const engineError = 'engineError';

  /// The model was unloaded under the generation (memory warning, reload).
  static const modelUnloaded = 'modelUnloaded';
  static const assetsUnavailable = 'assetsUnavailable';
  static const unsupportedLanguage = 'unsupportedLanguage';

  /// The native session Dart planned to append to is gone (dropped on a
  /// memory warning): the providers rebuild and retry once.
  static const sessionLost = 'sessionLost';
  static const unknown = 'unknown';
}

ProviderErrorKind errorKindForCode(String? code) => switch (code) {
  AppleMlErrorCode.outOfMemory => ProviderErrorKind.outOfMemory,
  AppleMlErrorCode.contextOverflow => ProviderErrorKind.contextOverflow,
  AppleMlErrorCode.modelNotFound => ProviderErrorKind.modelNotFound,
  AppleMlErrorCode.unsupported || AppleMlErrorCode.assetsUnavailable => ProviderErrorKind.unsupported,
  AppleMlErrorCode.invalidRequest || AppleMlErrorCode.unsupportedLanguage => ProviderErrorKind.invalidRequest,
  AppleMlErrorCode.rateLimited => ProviderErrorKind.rateLimited,
  AppleMlErrorCode.timeout => ProviderErrorKind.timeout,
  AppleMlErrorCode.busy => ProviderErrorKind.overloaded,
  AppleMlErrorCode.server => ProviderErrorKind.server,
  AppleMlErrorCode.engineError ||
  AppleMlErrorCode.modelUnloaded ||
  AppleMlErrorCode.sessionLost => ProviderErrorKind.engineCrashed,
  _ => ProviderErrorKind.unknown,
};

ProviderException appleMlException(String? code, String? message, {required String providerId, Object? cause}) =>
    ProviderException(
      errorKindForCode(code),
      message?.isNotEmpty ?? false ? message! : 'on-device generation failed',
      providerId: providerId,
      cause: cause,
    );

/// Converts anything a backend call threw.
ProviderException appleMlErrorFrom(Object error, {required String providerId}) => switch (error) {
  ProviderException() => error,
  PlatformException(:final code, :final message) => appleMlException(
    code,
    message,
    providerId: providerId,
    cause: error,
  ),
  UnsupportedError(:final message) => ProviderException(
    ProviderErrorKind.unsupported,
    message ?? 'unsupported',
    providerId: providerId,
    cause: error,
  ),
  _ => ProviderException(ProviderErrorKind.unknown, '$error', providerId: providerId, cause: error),
};

/// `finished` event codes → core finish reasons (null: not a terminal code).
FinishReason finishReasonForCode(String? code, {required bool sawToolCalls}) => switch (code) {
  'length' => FinishReason.length,
  'cancelled' => FinishReason.cancelled,
  'refusal' => FinishReason.refusal,
  'guardrail' => FinishReason.contentFilter,
  _ => sawToolCalls ? FinishReason.toolCalls : FinishReason.stop,
};
