import 'package:sherpa_net/sherpa_net.dart';

/// Typed Hub failures. Branch on the subtype; R08 §1: "Always branch on
/// `X-Error-Code` first, status second."
///
/// Messages and URLs are redacted (signed CDN URLs carry a signature that
/// works as a credential for an hour).
sealed class HubException implements Exception {
  HubException(this.message, {this.statusCode, this.errorCode, this.requestId, Uri? url})
      : url = url == null ? null : Redactor.uri(url);

  final String message;
  final int? statusCode;

  /// `X-Error-Code` (`GatedRepo`, `EntryNotFound`, `RevisionNotFound`, …).
  final String? errorCode;

  /// `X-Request-Id`, for bug reports.
  final String? requestId;
  final Uri? url;

  /// Whether retrying the same request later can succeed.
  bool get retryable => false;

  @override
  String toString() => '$runtimeType(${statusCode ?? '-'}${errorCode == null ? '' : ' $errorCode'}): '
      '${Redactor.text(message)}${url == null ? '' : ' [$url]'}';
}

/// File content of a gated repo without (accepted) access. Metadata and the
/// tree stay public (R08 §7.2).
final class HubGatedRepoException extends HubException {
  HubGatedRepoException(super.message, {required this.repo, super.statusCode, super.errorCode, super.requestId, super.url});

  final String repo;

  /// 401: not signed in (or the token lacks `gated-repos`). 403: signed in
  /// but terms not accepted or pending manual approval.
  bool get needsSignIn => statusCode == 401;

  /// Where the user accepts the terms.
  Uri get accessPage => Uri.parse('https://huggingface.co/$repo');
}

/// 404 `EntryNotFound`: the path does not exist at that revision.
final class HubEntryNotFoundException extends HubException {
  HubEntryNotFoundException(super.message, {super.statusCode, super.errorCode, super.requestId, super.url});
}

/// 404 `RevisionNotFound`: unknown branch, tag or commit.
final class HubRevisionNotFoundException extends HubException {
  HubRevisionNotFoundException(super.message, {super.statusCode, super.errorCode, super.requestId, super.url});
}

/// The repo does not exist — or is private. The Hub answers both with
/// `401 Invalid username or password.` to anonymous callers, by design
/// (R08 §0.14), and with 404 `RepoNotFound` to signed-in ones.
final class HubRepoNotFoundException extends HubException {
  HubRepoNotFoundException(super.message, {super.statusCode, super.errorCode, super.requestId, super.url});

  bool get mayBePrivate => statusCode == 401;
}

/// 401 on an endpoint that requires a valid token (`/api/whoami-v2`).
final class HubUnauthorizedException extends HubException {
  HubUnauthorizedException(super.message, {super.statusCode, super.errorCode, super.requestId, super.url});
}

/// 429, or a local bucket that is known to be empty. [retryAfter] comes
/// from the JSON `retryAfter`, `Retry-After`, or the `ratelimit` `t=` value.
final class HubRateLimitedException extends HubException {
  HubRateLimitedException(super.message, {this.retryAfter, this.bucket, super.statusCode, super.errorCode, super.requestId, super.url});

  final Duration? retryAfter;

  /// `api`, `resolvers` or `pages` (R08 §6).
  final String? bucket;

  @override
  bool get retryable => true;
}

/// 403 `Auth failed: credentials expired` from the CDN: the signed URL is
/// older than an hour. Re-resolve and resume with Range (R08 §5.5 step 4).
final class HubUrlExpiredException extends HubException {
  HubUrlExpiredException(super.message, {super.statusCode, super.errorCode, super.requestId, super.url});

  @override
  bool get retryable => true;
}

/// "Access to this resource is disabled."
final class HubDisabledRepoException extends HubException {
  HubDisabledRepoException(super.message, {super.statusCode, super.errorCode, super.requestId, super.url});
}

/// Other 403s (org token policy, revoked token).
final class HubForbiddenException extends HubException {
  HubForbiddenException(super.message, {super.statusCode, super.errorCode, super.requestId, super.url});
}

/// Other 404s.
final class HubNotFoundException extends HubException {
  HubNotFoundException(super.message, {super.statusCode, super.errorCode, super.requestId, super.url});
}

/// 400: invalid parameter, sort direction or pagination cursor.
final class HubBadRequestException extends HubException {
  HubBadRequestException(super.message, {super.statusCode, super.errorCode, super.requestId, super.url});
}

/// 5xx after retries.
final class HubServerException extends HubException {
  HubServerException(super.message, {super.statusCode, super.errorCode, super.requestId, super.url});

  @override
  bool get retryable => true;
}

/// Connection failure or timeout after retries.
final class HubNetworkException extends HubException {
  HubNetworkException(super.message, {this.cause, super.url});

  final Object? cause;

  @override
  bool get retryable => true;
}

/// A response that does not have the documented shape (redirect without
/// `Location`, non-GGUF bytes, a disallowed redirect target, …).
final class HubProtocolException extends HubException {
  HubProtocolException(super.message, {super.statusCode, super.errorCode, super.requestId, super.url});
}

/// Any other HTTP status.
final class HubHttpException extends HubException {
  HubHttpException(super.message, {super.statusCode, super.errorCode, super.requestId, super.url});
}
