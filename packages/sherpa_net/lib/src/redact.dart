/// Removes secrets from anything that may reach logs, diagnostics exports,
/// crash reports or handoff bundles.
abstract final class Redactor {
  static const String mask = '«redacted»';

  static final Set<String> _sensitiveHeaders = {
    'authorization',
    'proxy-authorization',
    'x-api-key',
    'api-key',
    'cookie',
    'set-cookie',
    'x-goog-api-key',
    'anthropic-api-key',
    'openai-api-key',
    'x-hf-token',
  };

  static final RegExp _sensitiveParam = RegExp(
    r'^(api[-_]?key|key|token|access[-_]?token|refresh[-_]?token|id[-_]?token|code|code[-_]?verifier|client[-_]?secret|password|secret|sig|signature)$',
    caseSensitive: false,
  );

  /// Token-shaped substrings: bearer values, sk-/hf_/ghp_ style keys, JWTs.
  static final RegExp _bearer = RegExp(r'(Bearer\s+)[A-Za-z0-9._~+/=-]{8,}', caseSensitive: false);

  static final List<RegExp> _patterns = [
    RegExp(r'\b(sk-(?:ant-|proj-)?[A-Za-z0-9_-]{12,})'),
    RegExp(r'\b(hf_[A-Za-z0-9]{20,})'),
    RegExp(r'\b(gh[pousr]_[A-Za-z0-9]{20,})'),
    RegExp(r'\b(AIza[0-9A-Za-z_-]{30,})'),
    RegExp(r'\b(eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,})'),
  ];

  static bool isSensitiveHeader(String name) {
    final n = name.toLowerCase();
    return _sensitiveHeaders.contains(n) || n.contains('token') || n.contains('secret') || n.endsWith('-key');
  }

  static Map<String, String> headers(Map<String, String> h) => {
        for (final e in h.entries) e.key: isSensitiveHeader(e.key) ? mask : e.value,
      };

  static Uri uri(Uri u) {
    if (!u.hasQuery && u.userInfo.isEmpty) return u;
    final q = <String, List<String>>{};
    for (final e in u.queryParametersAll.entries) {
      q[e.key] = _sensitiveParam.hasMatch(e.key) ? [mask] : e.value;
    }
    return u.replace(userInfo: u.userInfo.isEmpty ? null : mask, queryParameters: q.isEmpty ? null : q);
  }

  static String text(String s) {
    var out = s.replaceAllMapped(_bearer, (m) => '${m[1]}$mask');
    for (final p in _patterns) {
      out = out.replaceAll(p, mask);
    }
    return out;
  }
}
