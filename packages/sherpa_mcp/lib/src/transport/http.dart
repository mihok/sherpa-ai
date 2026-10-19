/// HTTP plumbing shared by the HTTP transports (internal).
///
/// Every request goes through an injected `http.Client` as an
/// `AbortableRequest` (so closing a stream really tears the socket down —
/// the 2026-07-28 cancellation signal), with:
/// * the server's [UrlPolicy] checked (with DNS) once per URL,
/// * redirects not followed by the client; same-origin 307/308 are
///   re-sent by hand (other redirects are errors: following them would
///   carry the credential to a host the policy never saw),
/// * auth headers from [McpAuthHook] on every request and 401/403 handed
///   back to it (one retry),
/// * a headers timeout, and bounded body / SSE-event sizes.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show IOException;

import 'package:http/http.dart' as http;
import 'package:sherpa_core/sherpa_core.dart' show CancelledException;
import 'package:sherpa_net/sherpa_net.dart';

import '../auth.dart';
import '../config.dart';
import '../errors.dart';
import '../protocol/jsonrpc.dart';

/// A one-shot abort signal (completes, never errors).
final class Abort {
  final Completer<void> _c = Completer<void>();

  bool get isAborted => _c.isCompleted;

  Future<void> get future => _c.future;

  void abort() {
    if (!_c.isCompleted) _c.complete();
  }

  /// Aborts this when [other] completes.
  void follow(Future<void>? other) {
    if (other != null) unawaited(other.then((_) => abort()));
  }
}

/// Response headers have arrived; the body is still a stream.
final class McpHttpResponse {
  McpHttpResponse(this.statusCode, this.headers, this._body, this._limits, this._abort);

  final int statusCode;

  /// Lower-case names.
  final Map<String, String> headers;
  final Stream<List<int>> _body;
  final McpLimits _limits;
  final Abort _abort;

  bool get ok => statusCode >= 200 && statusCode < 300;

  String get mediaType => (headers['content-type'] ?? '').split(';').first.trim().toLowerCase();

  bool get isJson => mediaType == 'application/json' || mediaType.endsWith('+json');

  bool get isEventStream => mediaType == 'text/event-stream';

  /// Reads the whole body, failing past [maxBytes] (never truncates: a
  /// truncated JSON-RPC message is worse than an error).
  Future<String> readText({int? maxBytes}) async {
    final cap = maxBytes ?? _limits.maxMessageBytes;
    final bytes = <int>[];
    try {
      await for (final chunk in _body) {
        if (bytes.length + chunk.length > cap) {
          _abort.abort();
          throw McpLimitExceededException('response body exceeds $cap bytes');
        }
        bytes.addAll(chunk);
      }
    } on McpException {
      rethrow;
    } on Object catch (e) {
      throw mapHttpError(e);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// A bounded prefix of the body (error pages), never throwing.
  Future<String> readErrorBody() async {
    final bytes = <int>[];
    try {
      await for (final chunk in _body) {
        final room = _limits.maxErrorBodyBytes - bytes.length;
        if (chunk.length >= room) {
          bytes.addAll(chunk.take(room));
          break;
        }
        bytes.addAll(chunk);
      }
    } on Object {
      // Best effort.
    } finally {
      _abort.abort();
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// Decodes the body as SSE. The bytes of one in-progress event are capped
  /// at `maxMessageBytes` (the counter resets on every dispatched event);
  /// comment lines (`:` keep-alives) are dropped by [SseDecoder]. Transport
  /// failures surface as [McpTransportException] / [CancelledException].
  Stream<SseEvent> events({Duration? idleTimeout}) {
    var pending = 0;
    var resetNext = false;
    final cap = _limits.maxMessageBytes;
    Stream<List<int>> body = _body.map((chunk) {
      // A chunk ending in a blank line completed whatever event was in
      // progress (comment-only keep-alives dispatch nothing, so they reset
      // the counter here rather than in the event map below).
      if (resetNext) pending = 0;
      pending += chunk.length;
      if (pending > cap) {
        _abort.abort();
        throw McpLimitExceededException('SSE event exceeds $cap bytes');
      }
      resetNext = _endsWithBlankLine(chunk);
      return chunk;
    });
    if (idleTimeout != null) {
      body = body.timeout(idleTimeout, onTimeout: (sink) {
        _abort.abort();
        sink.addError(McpTimeoutException('stream idle for $idleTimeout'));
        sink.close();
      });
    }
    return body.transform(const SseDecoder()).map((e) {
      pending = 0;
      return e;
    }).handleError((Object e) => throw mapHttpError(e));
  }

  static bool _endsWithBlankLine(List<int> c) {
    final n = c.length;
    if (n >= 2 && c[n - 1] == 0x0A && (c[n - 2] == 0x0A || c[n - 2] == 0x0D)) return true;
    return n >= 2 && c[n - 1] == 0x0D && c[n - 2] == 0x0D;
  }

  /// Releases the connection without reading the body.
  void discard() {
    _abort.abort();
    _body.listen(null, onError: (Object _) {}, cancelOnError: true).cancel().ignore();
  }
}

/// Maps `package:http` / IO failures into this package's errors.
Object mapHttpError(Object e) => switch (e) {
      McpException() || CancelledException() => e,
      http.RequestAbortedException() => const CancelledException('request aborted'),
      TimeoutException(:final message) => McpTimeoutException(message ?? 'timed out'),
      http.ClientException(:final message) => McpTransportException('network error: $message', cause: e),
      IOException() => McpTransportException('network error: $e', cause: e),
      UrlPolicyViolation() => McpTransportException(e.toString(), cause: e),
      _ => McpTransportException('unexpected transport error: $e', cause: e),
    };

/// Sends MCP HTTP requests for one server.
final class McpHttp {
  McpHttp({
    required http.Client client,
    required this.serverUrl,
    required UrlPolicy policy,
    required this.timeouts,
    required this.limits,
    this.auth,
    Map<String, String> baseHeaders = const {},
  })  : _client = client,
        _policy = policy,
        _baseHeaders = baseHeaders;

  final http.Client _client;

  /// The canonical server URL (auth resource and policy anchor).
  final Uri serverUrl;
  final UrlPolicy _policy;
  final McpTimeouts timeouts;
  final McpLimits limits;
  final McpAuthHook? auth;
  final Map<String, String> _baseHeaders;
  final Set<String> _checked = {};

  /// Invoked after the hook supplied a new credential (cacheScope
  /// `private` entries belong to the old authorization context).
  void Function()? onCredentialChanged;

  /// Policy check (DNS included) once per URL per transport instance.
  Future<void> checkUrl(Uri url) async {
    final key = url.replace(query: '', fragment: '').toString();
    if (_checked.contains(key)) return;
    try {
      await _policy.check(url.toString());
    } on UrlPolicyViolation catch (e) {
      throw McpTransportException(e.toString(), cause: e);
    }
    _checked.add(key);
  }

  /// Sends one request and returns when headers arrive. Non-2xx statuses
  /// are returned (callers classify them), except 401/403, which go to the
  /// auth hook and end in [McpAuthRequiredException] unless it retries.
  Future<McpHttpResponse> send(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    List<int>? body,
    Future<void>? abort,
  }) async {
    var target = url;
    var authRetried = false;
    for (var hop = 0;; hop++) {
      await checkUrl(target);
      final a = Abort()..follow(abort);
      if (a.isAborted) throw const CancelledException('request aborted');
      final request = http.AbortableRequest(method, target, abortTrigger: a.future)..followRedirects = false;
      request.headers.addAll(_baseHeaders);
      if (auth != null) request.headers.addAll(await auth!.headersFor(serverUrl));
      request.headers.addAll(headers);
      if (body != null) request.bodyBytes = body;
      final http.StreamedResponse r;
      try {
        r = await _client.send(request).timeout(timeouts.headers, onTimeout: () {
          a.abort();
          throw McpTimeoutException('no response headers from ${Redactor.uri(target)} within ${timeouts.headers}');
        });
      } on Object catch (e) {
        throw mapHttpError(e);
      }
      final response = McpHttpResponse(r.statusCode, r.headers, r.stream, limits, a);
      if (r.statusCode == 401 || r.statusCode == 403) {
        response.discard();
        final hook = auth;
        final challenge = r.headers['www-authenticate'];
        if (hook == null) {
          throw McpAuthRequiredException(statusCode: r.statusCode, needsUserConsent: true, wwwAuthenticate: challenge);
        }
        final decision = authRetried ? AuthRetry.fail : await hook.onAuthChallenge(serverUrl, r.statusCode, r.headers);
        switch (decision) {
          case AuthRetry.retry:
            authRetried = true;
            onCredentialChanged?.call();
            continue;
          case AuthRetry.needsUserConsent:
            throw McpAuthRequiredException(statusCode: r.statusCode, needsUserConsent: true, wwwAuthenticate: challenge);
          case AuthRetry.fail:
            throw McpAuthRequiredException(
                statusCode: r.statusCode, needsUserConsent: false, wwwAuthenticate: challenge);
        }
      }
      if (r.isRedirect || (r.statusCode >= 300 && r.statusCode < 400)) {
        response.discard();
        final location = r.headers['location'];
        final next = location == null ? null : target.resolve(location);
        final sameOrigin = next != null &&
            next.scheme == target.scheme &&
            next.host.toLowerCase() == target.host.toLowerCase() &&
            next.port == target.port;
        if ((r.statusCode == 307 || r.statusCode == 308) && sameOrigin && hop < 3) {
          target = next;
          continue;
        }
        throw McpTransportException(
          'redirect ${r.statusCode} to ${next == null ? '(none)' : Redactor.uri(next)} not followed',
          statusCode: r.statusCode,
        );
      }
      return response;
    }
  }

  /// Converts a non-2xx response into [McpHttpStatusException], parsing a
  /// JSON-RPC error from the body when there is one.
  Future<McpHttpStatusException> statusError(McpHttpResponse r) async {
    final body = await r.readErrorBody();
    return McpHttpStatusException(
      r.statusCode,
      body: Redactor.text(body),
      rpcError: parseRpcErrorBody(body),
      headers: r.headers,
      retryAfter: parseRetryAfter(r.headers),
    );
  }
}

/// The JSON-RPC error object in an HTTP error body, if any (TS v2
/// `parseJsonRpcErrorBody`: an object with an `error` whose `code` is a number).
JsonRpcError? parseRpcErrorBody(String body) {
  if (body.trim().isEmpty) return null;
  try {
    final j = jsonDecode(body);
    if (j is! Map) return null;
    final e = j['error'];
    if (e is! Map) return null;
    return JsonRpcError.fromJson(e.cast<String, Object?>());
  } on Object {
    return null;
  }
}
