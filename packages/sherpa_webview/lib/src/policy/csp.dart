/// Content-Security-Policy construction for MCP App views (R03 §5, §11.5).
///
/// Pure Dart (no Flutter): the Chromium security suite's golden fixture is
/// checked against this builder by `test/csp_test.dart`.
library;

import 'package:meta/meta.dart';

/// One validated CSP source: `scheme://[*.]host[:port]`.
///
/// Only origins are accepted (no path, query, userinfo, keyword, `data:`,
/// `blob:`, bare `*`, IP literal or single-label host), so a server cannot
/// inject directives or widen the policy beyond the hosts it names.
@immutable
final class CspOrigin {
  const CspOrigin._(this.scheme, this.host, this.port, {required this.wildcard});

  /// `https` or `wss`.
  final String scheme;

  /// Lower-case ASCII host without the `*.` prefix.
  final String host;

  /// Explicit port, if any.
  final int? port;

  /// `https://*.example.com`: any subdomain (not the apex, per CSP).
  final bool wildcard;

  static final RegExp _shape = RegExp(r'^(https|wss)://(\*\.)?([a-z0-9.-]+)(?::(\d{1,5}))?/?$');
  static final RegExp _label = RegExp(r'^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$');
  static final RegExp _numeric = RegExp(r'^[0-9]+$');

  /// Parses [raw]; returns null for anything that is not a plain origin.
  /// [schemes] limits the accepted schemes (`wss` only makes sense for
  /// `connect-src`).
  static CspOrigin? tryParse(String raw, {Set<String> schemes = const {'https', 'wss'}}) {
    final s = raw.trim().toLowerCase();
    if (s.length > 270) return null;
    final m = _shape.firstMatch(s);
    if (m == null) return null;
    final scheme = m.group(1)!;
    if (!schemes.contains(scheme)) return null;
    final host = m.group(3)!;
    if (host.length > 253 || host.endsWith('.') || host.startsWith('.')) return null;
    final labels = host.split('.');
    // At least two labels: rejects `localhost`, `intranet`, bare TLDs; a
    // wildcard needs a registrable-looking base (`*.co` is refused, `*.co.uk`
    // cannot be told apart without the public-suffix list: see README).
    if (labels.length < 2) return null;
    if (!labels.every(_label.hasMatch)) return null;
    // IPv4 literals (and anything with an all-numeric TLD); IPv6 literals
    // never match the shape because of the brackets.
    if (_numeric.hasMatch(labels.last)) return null;
    // Names that resolve on the LAN or the device (mDNS `.local`, home
    // routers, split-horizon DNS), never publicly. `.example` stays allowed:
    // it never resolves, and the security suite uses it.
    if (const {'localhost', 'local', 'internal', 'intranet', 'invalid', 'test', 'onion', 'home', 'lan', 'corp', 'arpa'}
        .contains(labels.last)) {
      return null;
    }
    int? port;
    if (m.group(4) case final p?) {
      port = int.parse(p);
      if (port < 1 || port > 65535) return null;
    }
    return CspOrigin._(scheme, host, port, wildcard: m.group(2) != null);
  }

  /// The CSP source expression (and the canonical key for consent).
  String get source => '$scheme://${wildcard ? '*.' : ''}$host${port == null ? '' : ':$port'}';

  @override
  bool operator ==(Object other) => other is CspOrigin && other.source == source;

  @override
  int get hashCode => source.hashCode;

  @override
  String toString() => source;
}

/// Validated, de-duplicated domain lists from a resource's `_meta.ui.csp`.
@immutable
final class DeclaredDomains {
  const DeclaredDomains({
    this.connect = const [],
    this.resource = const [],
    this.rejected = const [],
    this.ignoredFrameDomains = const [],
    this.ignoredBaseUriDomains = const [],
  });

  /// Parses the raw `csp` object; never throws. Entries that are not plain
  /// origins land in [rejected] (shown in the consent sheet, never granted).
  factory DeclaredDomains.fromCsp(Map<String, Object?>? csp) {
    if (csp == null) return const DeclaredDomains();
    final rejected = <String>[];
    List<CspOrigin> read(String key, Set<String> schemes) {
      final out = <CspOrigin>[];
      final v = csp[key];
      if (v is! List) return out;
      for (final e in v.take(64)) {
        if (e is! String) continue;
        final o = CspOrigin.tryParse(e, schemes: schemes);
        if (o == null) {
          rejected.add(e.length > 120 ? '${e.substring(0, 120)}…' : e);
        } else if (!out.contains(o)) {
          out.add(o);
        }
      }
      return out;
    }

    List<String> strings(String key) => [
          for (final e in (csp[key] is List ? csp[key]! as List : const <Object?>[]).take(64))
            if (e is String) e,
        ];

    return DeclaredDomains(
      connect: read('connectDomains', const {'https', 'wss'}),
      resource: read('resourceDomains', const {'https'}),
      rejected: rejected,
      ignoredFrameDomains: strings('frameDomains'),
      ignoredBaseUriDomains: strings('baseUriDomains'),
    );
  }

  /// `fetch` / XHR / WebSocket / EventSource targets.
  final List<CspOrigin> connect;

  /// Script, style, image, font and media hosts.
  final List<CspOrigin> resource;

  /// Declared entries that failed validation.
  final List<String> rejected;

  /// `frameDomains` / `baseUriDomains` are never granted in this version
  /// (`frame-src 'none'`, `base-uri 'none'`): a permitted tightening.
  final List<String> ignoredFrameDomains;
  final List<String> ignoredBaseUriDomains;

  bool get isEmpty => connect.isEmpty && resource.isEmpty;

  /// Every grantable origin (connect first), for the consent sheet.
  List<CspOrigin> get all => [...connect, ...resource.where((r) => !connect.contains(r))];

  /// The subset of these lists whose [CspOrigin.source] is in [granted].
  /// Anything the user granted that the resource did not declare is dropped
  /// (the host MUST NOT allow undeclared domains).
  DeclaredDomains grant(Set<String> granted) => DeclaredDomains(
        connect: [for (final o in connect) if (granted.contains(o.source)) o],
        resource: [for (final o in resource) if (granted.contains(o.source)) o],
      );

  /// `hostCapabilities.sandbox.csp`: what the host actually allows.
  Map<String, Object?> toSandboxCsp() => {
        'connectDomains': [for (final o in connect) o.source],
        'resourceDomains': [for (final o in resource) o.source],
      };
}

/// The CSP applied to both the shell document and (inherited, plus a copy
/// injected as the first element of) the View's `srcdoc` document.
///
/// With nothing granted:
/// `default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; …`
/// (no network at all). `'self'` is dropped everywhere (there is no
/// same-origin server on mobile), `'unsafe-eval'` and workers are not
/// allowed, and `frame-src`, `object-src`, `base-uri`, `form-action` and
/// `manifest-src` are `'none'`.
@immutable
final class McpAppCsp {
  const McpAppCsp._(this.policy, this.granted);

  /// Builds the policy from the GRANTED domains only.
  factory McpAppCsp.build([DeclaredDomains granted = const DeclaredDomains()]) {
    final r = [for (final o in granted.resource) o.source];
    final c = [for (final o in granted.connect) o.source];
    String list(List<String> base, List<String> extra) {
      final all = [...base, ...extra];
      return all.isEmpty ? "'none'" : all.join(' ');
    }

    final directives = <String>[
      "default-src 'none'",
      'script-src ${list(const ["'unsafe-inline'"], r)}',
      'style-src ${list(const ["'unsafe-inline'"], r)}',
      'img-src ${list(const ['data:', 'blob:'], r)}',
      'font-src ${list(const [], r)}',
      'media-src ${list(const [], r)}',
      'connect-src ${list(const [], c)}',
      "frame-src 'none'",
      "child-src 'none'",
      "worker-src 'none'",
      "object-src 'none'",
      "base-uri 'none'",
      "form-action 'none'",
      "manifest-src 'none'",
    ];
    return McpAppCsp._(directives.join('; '), granted);
  }

  /// The `content` of the `<meta http-equiv="Content-Security-Policy">`.
  final String policy;

  /// What was granted (reported back to the View).
  final DeclaredDomains granted;

  /// Origins the native layer lets through (Android request interception,
  /// iOS content rules). Empty means "block every network load".
  List<String> get allowedOrigins => <String>{
        for (final o in [...granted.connect, ...granted.resource]) o.source,
      }.toList();

  bool get allowsNetwork => allowedOrigins.isNotEmpty;

  /// Characters native code accepts in a policy (it substitutes the policy
  /// into the shell's meta tag and refuses anything else, failing closed).
  static final RegExp allowedChars = RegExp(r"^[a-z0-9 :;'*./-]+$");

  @override
  String toString() => policy;
}
