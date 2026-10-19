import 'package:sherpa_net/sherpa_net.dart';

/// Severity of an [AuthLogger] record.
enum AuthLogLevel { debug, info, warning }

/// Receives diagnostics from the OAuth client.
///
/// Every message has been passed through [AuthRedact.text] before it gets
/// here, so a sink may forward it to the debug console or a diagnostics
/// export as-is. Tokens, codes, verifiers, `state` and client secrets never
/// appear (R02 §13: "Never put tokens, codes, verifiers or state in logs").
typedef AuthLogger = void Function(AuthLogLevel level, String message);

/// Redaction on top of [Redactor] for OAuth-specific values.
///
/// [Redactor.uri] already masks `code`, `code_verifier`, `*token*` and
/// `client_secret`; authorization URLs additionally carry `state`,
/// `code_challenge` and `nonce`, and device flows carry `device_code` and
/// `user_code`, none of which may be logged.
abstract final class AuthRedact {
  static final RegExp _extraParams = RegExp(
    r'^(state|code_challenge|nonce|device_code|user_code|registration_access_token|assertion)$',
    caseSensitive: false,
  );

  /// Masks credential-bearing query parameters and userinfo.
  static Uri uri(Uri u) {
    final base = Redactor.uri(u);
    if (!base.hasQuery) return base;
    final q = <String, List<String>>{
      for (final e in base.queryParametersAll.entries)
        e.key: _extraParams.hasMatch(e.key) ? const [Redactor.mask] : e.value,
    };
    return base.replace(queryParameters: q);
  }

  /// Scrubs [secrets] (exact values known to the caller, e.g. the refresh
  /// token just sent) and then token-shaped substrings.
  ///
  /// Scrubbing known values matters because an authorization server's
  /// `error_description` is attacker-controlled and may echo the request.
  static String text(String s, [Iterable<String?> secrets = const []]) {
    var out = s;
    for (final secret in secrets) {
      // Very short values would mask unrelated text and are not credentials.
      if (secret != null && secret.length >= 6) out = out.replaceAll(secret, Redactor.mask);
    }
    return Redactor.text(out);
  }

  static final RegExp _control = RegExp(r'[\x00-\x1f\x7f]');

  /// Makes an untrusted server string safe to show as plain text: control
  /// characters removed, length capped. Never render it as markup or feed it
  /// to a model (R02 §14.9).
  static String untrusted(String s, {int max = 200, Iterable<String?> secrets = const []}) {
    final clean = text(s, secrets).replaceAll(_control, ' ').trim();
    return clean.length <= max ? clean : '${clean.substring(0, max)}…';
  }
}

/// Internal logging front-end: redacts before anything reaches the sink.
final class AuthLog {
  const AuthLog([this._sink]);

  final AuthLogger? _sink;

  void debug(String message) => _emit(AuthLogLevel.debug, message);

  void info(String message) => _emit(AuthLogLevel.info, message);

  void warning(String message) => _emit(AuthLogLevel.warning, message);

  void _emit(AuthLogLevel level, String message) {
    final sink = _sink;
    if (sink != null) sink(level, AuthRedact.text(message));
  }
}
