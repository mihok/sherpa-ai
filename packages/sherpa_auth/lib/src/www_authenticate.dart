import 'package:meta/meta.dart';

import 'flow/scopes.dart';

/// One challenge from a `WWW-Authenticate` header (RFC 9110 §11.6.1).
@immutable
final class AuthChallenge {
  const AuthChallenge({
    required this.scheme,
    this.token68,
    this.params = const {},
    this.duplicateParams = const {},
  });

  /// As received; compare with [isScheme] (schemes are case-insensitive).
  final String scheme;

  /// `Negotiate abc==`-style credentials; mutually exclusive with [params].
  final String? token68;

  /// Auth-params with lower-cased names (names are case-insensitive) and
  /// unescaped quoted-string values. The first occurrence wins.
  final Map<String, String> params;

  /// Names that appeared more than once. RFC 9110 §11.2 says each name MUST
  /// occur only once per challenge and RFC 6750 §3 says the same for
  /// `scope`; the first value is kept and callers log the violation.
  final Set<String> duplicateParams;

  bool isScheme(String name) => scheme.toLowerCase() == name.toLowerCase();

  String? param(String name) => params[name.toLowerCase()];

  @override
  String toString() => 'AuthChallenge($scheme${token68 != null ? ' <token68>' : ''}, ${params.keys.join(',')})';
}

/// A parsed `WWW-Authenticate` field value: a list of challenges.
///
/// The TS SDKs split the header on the first space and pull each field out
/// with an unanchored regex (TS1 L471-483, TS2 L923-933), so
/// `error_description="need scope=x"` before `scope=` yields the wrong
/// scope and only the first challenge's scheme is checked. This is a real
/// tokenizer for the RFC 9110 grammar:
///
/// ```
/// WWW-Authenticate = #challenge
/// challenge   = auth-scheme [ 1*SP ( token68 / #auth-param ) ]
/// auth-param  = token BWS "=" BWS ( token / quoted-string )
/// token68     = 1*( ALPHA / DIGIT / "-" / "." / "_" / "~" / "+" / "/" ) *"="
/// ```
///
/// Several header lines are equivalent to one comma-joined line
/// (RFC 9110 §5.3), which is how `package:http` folds them. Parsing never
/// throws: malformed fragments are skipped up to the next comma.
@immutable
final class WwwAuthenticate {
  const WwwAuthenticate(this.challenges);

  final List<AuthChallenge> challenges;

  /// Parses one field value (or several joined with `,`).
  static WwwAuthenticate parse(String header) => WwwAuthenticate(List.unmodifiable(_Parser(header).run()));

  /// Parses every line of a multi-valued header.
  static WwwAuthenticate parseAll(Iterable<String> lines) => parse(lines.join(', '));

  /// From a `package:http`-style header map (lower-cased keys).
  static WwwAuthenticate? fromHeaders(Map<String, String> headers) {
    final v = headers['www-authenticate'] ?? headers['WWW-Authenticate'];
    return v == null || v.trim().isEmpty ? null : parse(v);
  }

  /// First challenge with [scheme], case-insensitively.
  AuthChallenge? find(String scheme) {
    for (final c in challenges) {
      if (c.isScheme(scheme)) return c;
    }
    return null;
  }

  @override
  String toString() => 'WwwAuthenticate($challenges)';
}

final class _Parser {
  _Parser(this.s);

  final String s;
  int i = 0;

  static bool _isTchar(int c) =>
      (c >= 0x30 && c <= 0x39) ||
      (c >= 0x41 && c <= 0x5a) ||
      (c >= 0x61 && c <= 0x7a) ||
      '!#\$%&\'*+-.^_`|~'.codeUnits.contains(c);

  static bool _isToken68Char(int c) =>
      (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a) || '-._~+/'.codeUnits.contains(c);

  bool get _end => i >= s.length;

  int get _c => s.codeUnitAt(i);

  void _skipWs() {
    while (!_end && (_c == 0x20 || _c == 0x09)) {
      i++;
    }
  }

  /// Skips whitespace and empty list elements (`#rule` allows `, ,`).
  void _skipListSeparators() {
    while (!_end && (_c == 0x20 || _c == 0x09 || _c == 0x2c)) {
      i++;
    }
  }

  String _token() {
    final start = i;
    while (!_end && _isTchar(_c)) {
      i++;
    }
    return s.substring(start, i);
  }

  /// quoted-string = DQUOTE *( qdtext / quoted-pair ) DQUOTE. Returns null
  /// (and consumes to the end) when unterminated.
  String? _quoted() {
    assert(_c == 0x22);
    i++;
    final out = StringBuffer();
    while (!_end) {
      final c = _c;
      if (c == 0x22) {
        i++;
        return out.toString();
      }
      if (c == 0x5c && i + 1 < s.length) {
        out.writeCharCode(s.codeUnitAt(i + 1));
        i += 2;
        continue;
      }
      out.writeCharCode(c);
      i++;
    }
    return null;
  }

  void _skipToComma() {
    while (!_end && _c != 0x2c) {
      if (_c == 0x22) {
        _quoted();
      } else {
        i++;
      }
    }
  }

  /// Tries `token BWS "=" BWS ( token / quoted-string )` at the cursor.
  /// Restores the cursor and returns null if it is not an auth-param.
  (String, String)? _authParam() {
    final start = i;
    final name = _token();
    if (name.isEmpty) return null;
    _skipWs();
    if (_end || _c != 0x3d) {
      i = start;
      return null;
    }
    i++; // '='
    _skipWs();
    if (_end) {
      i = start;
      return null;
    }
    if (_c == 0x22) {
      final v = _quoted();
      if (v == null) {
        i = start;
        return null;
      }
      return (name.toLowerCase(), v);
    }
    final v = _bareValue();
    if (v.isEmpty) {
      i = start;
      return null;
    }
    return (name.toLowerCase(), v);
  }

  /// An unquoted value. The grammar says `token`, but servers send
  /// `scope=files:read` and bare URLs (`:` and `/` are not tchars), so any
  /// run up to whitespace, `,` or `"` is accepted — except one starting with
  /// `=`, which keeps `abc==` a token68.
  String _bareValue() {
    if (_end || _c == 0x3d) return '';
    final start = i;
    while (!_end && _c != 0x20 && _c != 0x09 && _c != 0x2c && _c != 0x22) {
      i++;
    }
    return s.substring(start, i);
  }

  /// Tries a token68 that runs to the end of the list element.
  String? _token68() {
    final start = i;
    while (!_end && _isToken68Char(_c)) {
      i++;
    }
    if (i == start) return null;
    while (!_end && _c == 0x3d) {
      i++;
    }
    final value = s.substring(start, i);
    _skipWs();
    if (_end || _c == 0x2c) return value;
    i = start;
    return null;
  }

  List<AuthChallenge> run() {
    final out = <AuthChallenge>[];
    String? scheme;
    String? token68;
    var params = <String, String>{};
    var dups = <String>{};

    void flush() {
      if (scheme != null) {
        out.add(AuthChallenge(
          scheme: scheme!,
          token68: token68,
          params: Map.unmodifiable(params),
          duplicateParams: Set.unmodifiable(dups),
        ));
      }
      scheme = null;
      token68 = null;
      params = <String, String>{};
      dups = <String>{};
    }

    void addParam((String, String) p) {
      if (params.containsKey(p.$1)) {
        dups.add(p.$1);
      } else {
        params[p.$1] = p.$2;
      }
    }

    while (true) {
      _skipListSeparators();
      if (_end) break;
      // Inside a challenge with params, a list element may be another
      // auth-param of the same challenge…
      if (scheme != null && token68 == null) {
        final p = _authParam();
        if (p != null) {
          addParam(p);
          _skipWs();
          if (!_end && _c != 0x2c) _skipToComma();
          continue;
        }
      }
      // …or the start of a new challenge.
      final name = _token();
      if (name.isEmpty) {
        // Not a token (stray quote, '=', non-ASCII): skip the element.
        i++;
        _skipToComma();
        continue;
      }
      if (!_end && _c == 0x3d) {
        // `name=` where a scheme was expected: a parameter without a
        // challenge (or after a token68). Malformed; skip it.
        _skipToComma();
        continue;
      }
      flush();
      scheme = name;
      final hadSpace = !_end && (_c == 0x20 || _c == 0x09);
      _skipWs();
      if (_end || _c == 0x2c || !hadSpace) {
        if (!_end && _c != 0x2c) _skipToComma();
        continue;
      }
      final p = _authParam();
      if (p != null) {
        addParam(p);
        _skipWs();
        if (!_end && _c != 0x2c) _skipToComma();
        continue;
      }
      final t = _token68();
      if (t != null) {
        token68 = t;
        continue;
      }
      _skipToComma();
    }
    flush();
    return out;
  }
}

/// The OAuth-relevant parameters of a `Bearer` (RFC 6750 §3) or `DPoP`
/// (RFC 9449 §7.1) challenge, with the RFC 9728 §5.1 `resource_metadata`.
///
/// Everything here is attacker-controlled: [resourceMetadata] feeds the
/// SSRF policy and [errorDescription] is display-only.
@immutable
final class BearerChallenge {
  const BearerChallenge({
    required this.scheme,
    this.error,
    this.scope,
    this.resourceMetadata,
    this.errorDescription,
    this.realm,
    this.duplicateParams = const {},
  });

  /// Selects the `Bearer` challenge (falling back to `DPoP`, as TS2 does
  /// with `RECOGNIZED_CHALLENGE_SCHEMES`). `resource_metadata` may sit on
  /// either scheme (RFC 9728 §5.1), so it is taken from the first
  /// recognised challenge that carries a usable one.
  static BearerChallenge? select(WwwAuthenticate header) {
    final bearer = header.find('Bearer');
    final dpop = header.find('DPoP');
    final base = bearer ?? dpop;
    if (base == null) return null;
    Uri? metadata;
    for (final c in [?bearer, ?dpop]) {
      metadata = parseResourceMetadataUrl(c.param('resource_metadata'));
      if (metadata != null) break;
    }
    return BearerChallenge(
      scheme: base.scheme,
      error: base.param('error'),
      scope: base.param('scope'),
      resourceMetadata: metadata,
      errorDescription: base.param('error_description'),
      realm: base.param('realm'),
      duplicateParams: base.duplicateParams,
    );
  }

  /// Parses the header of an HTTP response; null when there is no Bearer
  /// or DPoP challenge.
  static BearerChallenge? fromHeaders(Map<String, String> headers) {
    final h = WwwAuthenticate.fromHeaders(headers);
    return h == null ? null : select(h);
  }

  static BearerChallenge? parse(String header) => select(WwwAuthenticate.parse(header));

  final String scheme;

  /// `invalid_request`, `invalid_token`, `insufficient_scope`; absent when
  /// the request carried no credentials (RFC 6750 §3.1).
  final String? error;

  /// Raw space-delimited scope, authoritative for the current operation
  /// (A26 L105-114).
  final String? scope;

  /// Absolute http(s) PRM URL, or null when absent, relative or malformed
  /// (then discovery falls back to the well-known URLs).
  final Uri? resourceMetadata;

  /// Untrusted, display-only.
  final String? errorDescription;
  final String? realm;
  final Set<String> duplicateParams;

  List<String> get scopes => splitScopes(scope);

  bool get isInsufficientScope => error == 'insufficient_scope';

  bool get isInvalidToken => error == 'invalid_token';

  /// Accepts only absolute http(s) URLs without userinfo or fragment.
  static Uri? parseResourceMetadataUrl(String? raw) {
    if (raw == null) return null;
    final u = Uri.tryParse(raw.trim());
    if (u == null || !u.isAbsolute || u.host.isEmpty || u.userInfo.isNotEmpty || u.hasFragment) return null;
    final scheme = u.scheme.toLowerCase();
    return scheme == 'https' || scheme == 'http' ? u : null;
  }

  @override
  String toString() => 'BearerChallenge($scheme, error: $error, scope: $scope, resource_metadata: $resourceMetadata)';
}
