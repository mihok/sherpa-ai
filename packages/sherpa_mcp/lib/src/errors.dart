/// Errors raised by the MCP client.
///
/// Cancellation is not an error here: it surfaces as sherpa_core's
/// `CancelledException`, so a user pressing stop is never reported as a
/// failure. SDK-local conditions (timeouts, limits) are distinct types and
/// can never be mistaken for a server's JSON-RPC error (basic/index.md
/// §Error codes).
library;

import 'package:sherpa_net/sherpa_net.dart' show Redactor;

import 'protocol/jsonrpc.dart';

/// Base class of every MCP client error.
sealed class McpException implements Exception {
  const McpException(this.message);

  /// Redacted, safe to log.
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// The server answered with a JSON-RPC error.
final class McpRpcException extends McpException {
  McpRpcException(this.error, {this.httpStatus}) : super(Redactor.text('${error.message} (code ${error.code})'));

  final JsonRpcError error;

  /// Set when the error came in a non-2xx HTTP response body.
  final int? httpStatus;

  int get code => error.code;

  /// Unknown tool / prompt, bad arguments, invalid cursor, resource not
  /// found (M), missing `_meta`.
  bool get isInvalidParams => code == JsonRpcError.invalidParams;

  /// Resource not found in either era (-32602 with `data.uri` in M, -32002 in L).
  bool get isResourceNotFound =>
      code == JsonRpcError.legacyResourceNotFound ||
      (code == JsonRpcError.invalidParams && error.data is Map && (error.data! as Map).containsKey('uri'));
}

/// The peer violated the protocol (invalid result, unknown `resultType`,
/// an input request for a capability we did not declare, …).
final class McpProtocolException extends McpException {
  McpProtocolException(String message) : super(Redactor.text(message));
}

/// Network or HTTP failure that is not a JSON-RPC error.
final class McpTransportException extends McpException {
  McpTransportException(String message, {this.statusCode, this.retryAfter, this.cause, this.streamInterrupted = false})
      : super(Redactor.text(message));

  final int? statusCode;
  final Duration? retryAfter;
  final Object? cause;

  /// A response stream ended before its response arrived. In 2026-07-28 the
  /// request is lost and may be re-issued with a new id; only re-issue
  /// operations that are safe to repeat.
  final bool streamInterrupted;
}

/// A non-2xx HTTP answer (other than auth challenges, which become
/// [McpAuthRequiredException]). [rpcError] is the JSON-RPC error in the body,
/// when there was one; [body] is a bounded, redacted prefix.
final class McpHttpStatusException extends McpTransportException {
  McpHttpStatusException(int statusCode, {required this.body, this.rpcError, this.headers = const {}, super.retryAfter})
      : super('HTTP $statusCode${rpcError == null ? '' : ': ${rpcError.message} (${rpcError.code})'}',
            statusCode: statusCode);

  final String body;
  final JsonRpcError? rpcError;
  final Map<String, String> headers;

  @override
  int get statusCode => super.statusCode!;
}

/// A legacy server answered 404 to a request carrying `Mcp-Session-Id`:
/// the session expired and the client MUST re-initialize.
final class McpSessionExpiredException extends McpTransportException {
  McpSessionExpiredException() : super('session expired (HTTP 404)', statusCode: 404);
}

/// The request did not complete in time (SDK-local, never a peer error).
final class McpTimeoutException extends McpException {
  const McpTimeoutException(super.message);
}

/// A size cap was exceeded (message body, SSE event, pages, input rounds).
final class McpLimitExceededException extends McpException {
  const McpLimitExceededException(super.message);
}

/// The server requires (re-)authorization. When [needsUserConsent] is set,
/// the app must run its OAuth flow (sherpa_auth) and reconnect.
final class McpAuthRequiredException extends McpException {
  McpAuthRequiredException({
    required this.statusCode,
    required this.needsUserConsent,
    this.wwwAuthenticate,
    String? message,
  }) : super(message ?? 'authorization required (HTTP $statusCode)');

  final int statusCode;
  final bool needsUserConsent;

  /// The raw `WWW-Authenticate` header (scope step-up, resource metadata).
  final String? wwwAuthenticate;
}

/// No era could be established for the endpoint.
final class McpEraNegotiationException extends McpException {
  McpEraNegotiationException(String message, {this.attempts = const []}) : super(Redactor.text(message));

  /// What each probe step saw, for the debug console.
  final List<String> attempts;
}

/// No mutually supported protocol version.
final class McpUnsupportedVersionException extends McpException {
  McpUnsupportedVersionException({required this.supported, required this.requested})
      : super('no mutually supported protocol version (server: ${supported.join(', ')}; asked: $requested)');

  final List<String> supported;
  final String requested;
}

/// The user (or policy) declined a sampling/roots input request, so the
/// originating request could not complete.
final class McpInputDeclinedException extends McpException {
  const McpInputDeclinedException(super.message);
}

/// A server-side task failed (`status: failed`).
final class McpTaskFailedException extends McpException {
  McpTaskFailedException(this.taskId, this.error)
      : super(Redactor.text('task $taskId failed: ${error?.message ?? 'no error given'}'));

  final String taskId;
  final JsonRpcError? error;
}

/// The connection is closed or was lost.
final class McpConnectionClosedException extends McpException {
  const McpConnectionClosedException([super.message = 'connection closed']);
}
