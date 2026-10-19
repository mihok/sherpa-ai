import 'dart:async';
import 'dart:convert';
import 'dart:io' show IOException;
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../common/redaction.dart';
import '../errors.dart';
import 'network_policy.dart';

/// Size, time and redirect caps for OAuth HTTP traffic (R02 §3.1, §14.3).
@immutable
final class AuthHttpLimits {
  const AuthHttpLimits({
    this.timeout = const Duration(seconds: 10),
    this.maxMetadataBytes = 64 << 10,
    this.maxTokenResponseBytes = 64 << 10,
    this.maxRedirects = 5,
  });

  /// Covers connect, headers *and* body, so a slow-drip server cannot hold a
  /// discovery step open.
  final Duration timeout;

  /// PRM / AS metadata / DCR responses.
  final int maxMetadataBytes;

  /// Token and device-authorization responses.
  final int maxTokenResponseBytes;

  /// Same-origin hops (the TS SDKs' `fetchWithinOrigin` also stops at 5).
  final int maxRedirects;
}

/// A buffered response. [oversized] responses have an empty [body].
@immutable
final class AuthHttpResponse {
  const AuthHttpResponse({
    required this.statusCode,
    required this.headers,
    required this.body,
    required this.url,
    this.oversized = false,
  });

  final int statusCode;
  final Map<String, String> headers;
  final Uint8List body;

  /// Where the response came from after same-origin redirects.
  final Uri url;

  /// The body exceeded the cap and was abandoned.
  final bool oversized;

  bool get ok => statusCode >= 200 && statusCode < 300;

  bool get isRedirect => statusCode >= 300 && statusCode < 400;

  String get text => utf8.decode(body, allowMalformed: true);

  /// The body as a JSON object, or null when it is not one (an HTML
  /// catch-all page, a JSON array, truncated bytes).
  JsonMap? jsonObject() {
    if (oversized || body.isEmpty) return null;
    try {
      final v = jsonDecode(utf8.decode(body));
      return v is Map ? (normalizeJson(v)! as Map<Object?, Object?>).cast<String, Object?>() : null;
    } on FormatException {
      return null;
    }
  }
}

/// The only way `sherpa_auth` talks to the network.
///
/// - Every URL, including each redirect hop, passes [AuthNetworkPolicy.check]
///   (SSRF; R02 §14.3).
/// - Redirects are never followed by the HTTP stack: a 301/302/303 is
///   followed only for GET, 307/308 for any method, and only within the
///   origin (or its https upgrade on default ports), at most
///   [AuthHttpLimits.maxRedirects] times. Anything else is returned
///   unfollowed, which discovery treats as "not found" (TS
///   `fetchWithinOrigin` semantics).
/// - No `Authorization` or cookies are ever added implicitly; only the
///   token endpoint passes client credentials explicitly (R02 §4.2: "Never
///   send Authorization/cookies on metadata fetches").
/// - Bodies are capped and the whole exchange is bounded by
///   [AuthHttpLimits.timeout].
/// - Network failures become [AuthNetworkException] with redacted text.
final class AuthHttp {
  AuthHttp({
    required http.Client client,
    this.policy = const AuthNetworkPolicy(),
    this.limits = const AuthHttpLimits(),
    this.userAgent = 'sherpa-auth/0.1',
    AuthLogger? logger,
  })  : _client = client,
        _log = AuthLog(logger);

  AuthHttp._({
    required http.Client client,
    required this.policy,
    required this.limits,
    required this.userAgent,
    required AuthLog log,
  })  : _client = client,
        _log = log;

  final http.Client _client;
  final AuthNetworkPolicy policy;
  final AuthHttpLimits limits;
  final String userAgent;
  final AuthLog _log;

  /// Same transport with another network policy (per-server LAN trust).
  AuthHttp withPolicy(AuthNetworkPolicy other) =>
      identical(other, policy) ? this : AuthHttp._(client: _client, policy: other, limits: limits, userAgent: userAgent, log: _log);

  Future<AuthHttpResponse> get(Uri url, {int? maxBytes}) =>
      _send('GET', url, maxBytes: maxBytes ?? limits.maxMetadataBytes);

  /// `application/x-www-form-urlencoded` POST. [secrets] are scrubbed from
  /// any error text produced while sending.
  Future<AuthHttpResponse> postForm(
    Uri url,
    Map<String, String> form, {
    Map<String, String> headers = const {},
    int? maxBytes,
    Iterable<String?> secrets = const [],
  }) =>
      _send('POST', url,
          headers: {'content-type': 'application/x-www-form-urlencoded', ...headers},
          body: _formEncode(form),
          maxBytes: maxBytes ?? limits.maxTokenResponseBytes,
          secrets: secrets);

  Future<AuthHttpResponse> postJson(Uri url, Object body, {int? maxBytes}) => _send('POST', url,
      headers: const {'content-type': 'application/json'},
      body: jsonEncode(body),
      maxBytes: maxBytes ?? limits.maxMetadataBytes);

  static String _formEncode(Map<String, String> form) => form.entries
      .map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
      .join('&');

  Future<AuthHttpResponse> _send(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    String? body,
    required int maxBytes,
    Iterable<String?> secrets = const [],
  }) async {
    var current = await policy.check(url);
    final deadline = DateTime.now().add(limits.timeout);
    for (var hop = 0;; hop++) {
      final req = http.Request(method, current)
        ..followRedirects = false
        ..headers['accept'] = 'application/json'
        ..headers['user-agent'] = userAgent
        ..headers.addAll(headers);
      if (body != null) req.body = body;
      final http.StreamedResponse resp;
      try {
        resp = await _client.send(req).timeout(_remaining(deadline));
      } on Object catch (e) {
        throw _networkError(e, current, secrets);
      }
      if (_redirectStatuses.contains(resp.statusCode)) {
        final target = _redirectTarget(resp, current);
        final keepsMethod = resp.statusCode == 307 || resp.statusCode == 308 || method == 'GET';
        if (target != null && keepsMethod && hop < limits.maxRedirects && _withinOrigin(current, target)) {
          await _drain(resp);
          _log.debug('following same-origin redirect ${AuthRedact.uri(current)} -> ${AuthRedact.uri(target)}');
          current = await policy.check(target);
          continue;
        }
        if (target != null) {
          _log.info('not following redirect ${AuthRedact.uri(current)} -> ${AuthRedact.uri(target)}');
        }
      }
      final Uint8List? bytes;
      try {
        bytes = await _readCapped(resp.stream, maxBytes, _remaining(deadline));
      } on Object catch (e) {
        throw _networkError(e, current, secrets);
      }
      if (bytes == null) _log.warning('response from ${AuthRedact.uri(current)} exceeds $maxBytes bytes; abandoned');
      return AuthHttpResponse(
        statusCode: resp.statusCode,
        headers: resp.headers,
        body: bytes ?? Uint8List(0),
        url: current,
        oversized: bytes == null,
      );
    }
  }

  static const Set<int> _redirectStatuses = {301, 302, 303, 307, 308};

  static Uri? _redirectTarget(http.StreamedResponse resp, Uri from) {
    final location = resp.headers['location'];
    if (location == null || location.isEmpty) return null;
    try {
      return from.resolve(location);
    } on FormatException {
      return null;
    }
  }

  /// Same scheme, host and port, or the https form of an http origin on
  /// default ports (TS `isWithinOrigin`). Redirects that add userinfo are
  /// refused outright.
  static bool _withinOrigin(Uri from, Uri to) {
    if (to.userInfo.isNotEmpty) return false;
    final sameHost = from.host.toLowerCase() == to.host.toLowerCase();
    if (from.scheme == to.scheme && sameHost && from.port == to.port) return true;
    return sameHost && from.scheme == 'http' && to.scheme == 'https' && !from.hasPort && !to.hasPort;
  }

  static Duration _remaining(DateTime deadline) {
    final d = deadline.difference(DateTime.now());
    return d.isNegative ? Duration.zero : d;
  }

  static Future<void> _drain(http.StreamedResponse resp) async {
    try {
      await resp.stream.drain<void>();
    } on Object {
      // The body of a redirect is irrelevant.
    }
  }

  /// Reads at most [max] bytes; returns null (and stops reading) beyond it.
  static Future<Uint8List?> _readCapped(Stream<List<int>> stream, int max, Duration timeout) {
    final done = Completer<Uint8List?>();
    final out = BytesBuilder(copy: false);
    late final StreamSubscription<List<int>> sub;
    sub = stream.listen(
      (chunk) {
        out.add(chunk);
        if (out.length > max && !done.isCompleted) {
          done.complete(null);
          unawaited(sub.cancel());
        }
      },
      onError: (Object e, StackTrace s) {
        if (!done.isCompleted) done.completeError(e, s);
      },
      onDone: () {
        if (!done.isCompleted) done.complete(out.takeBytes());
      },
      cancelOnError: true,
    );
    return done.future.timeout(timeout, onTimeout: () {
      unawaited(sub.cancel());
      throw TimeoutException('response body timed out', timeout);
    });
  }

  AuthException _networkError(Object e, Uri url, Iterable<String?> secrets) {
    if (e is AuthException) return e;
    if (e is TimeoutException) return AuthNetworkException('request timed out', url: url);
    if (e is http.ClientException || e is IOException) {
      return AuthNetworkException(AuthRedact.text('connection failed: $e', secrets), url: url);
    }
    // Anything else is a programming error in a custom client; still never
    // let its text carry secrets.
    return AuthNetworkException(AuthRedact.text('request failed: ${e.runtimeType}', secrets), url: url);
  }
}
