import 'package:flutter/services.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../messages.pigeon.dart';

/// ML Kit `GenAiException.ErrorCode` values (javap of genai-common
/// 1.0.0-beta4) plus the AICore service codes the docs name.
abstract final class NanoErrorCode {
  static const unknown = 0;
  static const requestProcessingError = 4;
  static const cancelled = 7;
  static const notAvailable = 8;
  static const busy = 9;
  static const responseProcessingError = 11;
  static const requestTooLarge = 12;
  static const requestTooSmall = -100;
  static const responseGenerationError = 15;
  static const notSupported = 16;
  static const perAppBatteryUseQuotaExceeded = 27;
  static const backgroundUseBlocked = 30;
  static const notEnoughDiskSpace = 501;
  static const bindingFailure = 601;
  static const needsSystemUpdate = 604;
  static const featureNotFound = 606;
  static const aicoreIncompatible = -101;
  static const invalidInputImage = -102;
  static const cacheProcessingError = -103;
  static const structuredOutputRequestError = -104;
  static const structuredOutputResponseError = -105;
  static const structuredOutputMaxTokensError = -106;
}

/// absl::StatusCode values LiteRT-LM reports (`Status Code: X`).
abstract final class LiteRtStatus {
  static const cancelled = 1;
  static const unknown = 2;
  static const invalidArgument = 3;
  static const deadlineExceeded = 4;
  static const notFound = 5;
  static const permissionDenied = 7;
  static const resourceExhausted = 8;
  static const failedPrecondition = 9;
  static const aborted = 10;
  static const outOfRange = 11;
  static const unimplemented = 12;
  static const internal = 13;
  static const unavailable = 14;
  static const dataLoss = 15;
}

/// User-facing text for the foreground-only rule (R07 §1.5).
const String kNanoBackgroundMessage =
    'Gemini Nano only runs while Sherpa is on screen: Android (AICore) blocks it in the background, '
    'even from a foreground service. Open Sherpa to continue, or use another model for background work.';

final RegExp _contextOverflow = RegExp(
  r'too long|exceed|max(imum)?[ _]?num[ _]?tokens|context (length|window|size)|kv[- ]?cache.*full|'
  r'input.*tokens.*(limit|larger)|not enough (space|room) in',
  caseSensitive: false,
);

final RegExp _oom = RegExp(r'out of memory|\boom\b|failed to allocate|cannot allocate|alloc(ation)? failed',
    caseSensitive: false);

/// Classifies a LiteRT-LM native error (Dart policy; Kotlin only reports the
/// absl code and message).
ProviderException liteRtError(ErrorMsg e, {required String providerId}) {
  final msg = e.message;
  final kind = switch (e.source) {
    'state' when msg.contains('being generated') => ProviderErrorKind.overloaded,
    _ when msg.contains('no model is loaded') || msg.contains('no open conversation') => ProviderErrorKind.engineCrashed,
    'state' || 'argument' => ProviderErrorKind.invalidRequest,
    'io' => ProviderErrorKind.modelNotFound,
    _ => _liteRtKind(e.code, msg),
  };
  return ProviderException(kind, 'LiteRT-LM: $msg', providerId: providerId, cause: e.code);
}

ProviderErrorKind _liteRtKind(int code, String msg) {
  if (_contextOverflow.hasMatch(msg) || code == LiteRtStatus.outOfRange) return ProviderErrorKind.contextOverflow;
  if (_oom.hasMatch(msg)) return ProviderErrorKind.outOfMemory;
  return switch (code) {
    LiteRtStatus.resourceExhausted => ProviderErrorKind.outOfMemory,
    LiteRtStatus.invalidArgument || LiteRtStatus.failedPrecondition => ProviderErrorKind.invalidRequest,
    LiteRtStatus.notFound => ProviderErrorKind.modelNotFound,
    LiteRtStatus.unimplemented || LiteRtStatus.permissionDenied => ProviderErrorKind.unsupported,
    LiteRtStatus.deadlineExceeded => ProviderErrorKind.timeout,
    LiteRtStatus.unavailable || LiteRtStatus.aborted => ProviderErrorKind.overloaded,
    LiteRtStatus.internal || LiteRtStatus.unknown || LiteRtStatus.dataLoss => ProviderErrorKind.engineCrashed,
    _ => ProviderErrorKind.unknown,
  };
}

/// Classifies a Gemini Nano (ML Kit / AICore) error. BUSY and the per-app
/// quota are retryable (R07 §1.5: back off exponentially), with the delay
/// AICore suggests when it gives one.
ProviderException nanoError(ErrorMsg e, {required String providerId}) {
  if (e.source != 'nano') {
    return ProviderException(ProviderErrorKind.unknown, 'Gemini Nano: ${e.message}', providerId: providerId);
  }
  // No suggested delay (null or 0): the agent loop's exponential backoff applies.
  final ms = e.retryAfterMs;
  final retry = ms == null || ms <= 0 ? null : Duration(milliseconds: ms);
  final (kind, text) = switch (e.code) {
    NanoErrorCode.busy => (ProviderErrorKind.overloaded, 'Gemini Nano is busy; retrying shortly.'),
    NanoErrorCode.perAppBatteryUseQuotaExceeded =>
      (ProviderErrorKind.rateLimited, 'Gemini Nano usage quota for Sherpa is used up for now (AICore battery quota).'),
    NanoErrorCode.backgroundUseBlocked => (ProviderErrorKind.unsupported, kNanoBackgroundMessage),
    NanoErrorCode.requestTooLarge => (ProviderErrorKind.contextOverflow, 'The prompt is too long for Gemini Nano.'),
    NanoErrorCode.requestTooSmall ||
    NanoErrorCode.invalidInputImage ||
    NanoErrorCode.requestProcessingError ||
    NanoErrorCode.structuredOutputRequestError ||
    NanoErrorCode.structuredOutputResponseError ||
    NanoErrorCode.structuredOutputMaxTokensError ||
    NanoErrorCode.cacheProcessingError =>
      (ProviderErrorKind.invalidRequest, 'Gemini Nano rejected the request: ${e.message}'),
    NanoErrorCode.responseGenerationError ||
    NanoErrorCode.responseProcessingError =>
      (ProviderErrorKind.server, 'Gemini Nano failed to generate a reply: ${e.message}'),
    NanoErrorCode.bindingFailure => (ProviderErrorKind.engineCrashed, 'Could not reach AICore: ${e.message}'),
    NanoErrorCode.notAvailable ||
    NanoErrorCode.notSupported ||
    NanoErrorCode.featureNotFound ||
    NanoErrorCode.needsSystemUpdate ||
    NanoErrorCode.aicoreIncompatible ||
    NanoErrorCode.notEnoughDiskSpace =>
      (ProviderErrorKind.unsupported, 'Gemini Nano is not available: ${e.message}'),
    _ => (ProviderErrorKind.unknown, 'Gemini Nano: ${e.message}'),
  };
  return ProviderException(kind, text, providerId: providerId, retryAfter: retry, statusCode: e.code, cause: e.message);
}

/// Converts a failed host call (a [PlatformException] from Kotlin, a missing
/// plugin) into a [ProviderException].
ProviderException hostError(Object error, {required String providerId, bool nano = false}) {
  if (error is ProviderException) return error;
  if (error is MissingPluginException) {
    return ProviderException(ProviderErrorKind.unsupported, 'The sherpa_litert plugin is not registered in this build.',
        providerId: providerId, cause: error);
  }
  if (error is PlatformException) {
    final details = error.details;
    final code = details is List && details.isNotEmpty && details.first is int ? details.first as int : -1;
    final message = error.message ?? error.code;
    switch (error.code) {
      case 'unsupported':
        return ProviderException(ProviderErrorKind.unsupported, message, providerId: providerId, cause: error);
      case 'load_failed':
        final failures = details is List && details.length > 1 && details[1] is List
            ? (details[1] as List).map((f) => '$f').join('; ')
            : message;
        final kind = _oom.hasMatch(failures) || code == LiteRtStatus.resourceExhausted
            ? ProviderErrorKind.outOfMemory
            : (code == LiteRtStatus.notFound ? ProviderErrorKind.modelNotFound : ProviderErrorKind.unsupported);
        return ProviderException(kind, 'LiteRT-LM could not load the model ($failures).',
            providerId: providerId, cause: error);
      case 'litert_status':
        return liteRtError(ErrorMsg(source: 'litert', code: code, message: message), providerId: providerId);
      case 'nano_error':
        final retry = details is List && details.length > 1 && details[1] is int ? details[1] as int : null;
        return nanoError(ErrorMsg(source: 'nano', code: code, message: message, retryAfterMs: retry),
            providerId: providerId);
      case 'state' || 'argument':
        return liteRtError(ErrorMsg(source: error.code, code: -1, message: message), providerId: providerId);
    }
    return ProviderException(ProviderErrorKind.unknown, '${nano ? 'Gemini Nano' : 'LiteRT-LM'}: $message',
        providerId: providerId, cause: error);
  }
  return ProviderException(ProviderErrorKind.unknown, '$error', providerId: providerId, cause: error);
}
