import 'dart:io';

import 'package:meta/meta.dart';

/// Which destinations a user-supplied or server-supplied URL may reach.
///
/// Remote MCP servers, OAuth metadata documents and model endpoints come
/// from users or from other servers' responses, so they are SSRF vectors:
/// a malicious server can point discovery at the phone's LAN, a router
/// admin page or a cloud metadata address.
enum NetworkScope {
  /// Public internet only (default for anything a server tells us to fetch).
  publicOnly,

  /// Also RFC 1918 / ULA / `.local` hosts — for a user-added LAN server.
  localNetwork,

  /// Also loopback — for on-device servers the user explicitly added.
  loopback,
}

@immutable
final class UrlPolicyViolation implements Exception {
  const UrlPolicyViolation(this.url, this.reason);
  final String url;
  final String reason;

  @override
  String toString() => 'Blocked URL $url: $reason';
}

/// Validates URLs before Sherpa connects to them.
final class UrlPolicy {
  const UrlPolicy({
    this.scope = NetworkScope.publicOnly,
    this.allowHttp = false,
    this.httpRequiresLocalAddress = false,
    this.resolver = _systemResolve,
  });

  final NetworkScope scope;

  /// Plain http is only ever acceptable for loopback/LAN development servers.
  /// On its own it is gated by [scope] only, so a public host given by name
  /// would pass; set [httpRequiresLocalAddress] to enforce the address too.
  final bool allowHttp;

  /// With [allowHttp]: a plain-http URL must point at the user's own network.
  /// Its host (the literal, or every address the name resolves to in
  /// [check]) must be loopback, private (RFC 1918, CGNAT, ULA) or
  /// link-local, never public, so prompts and credentials are never sent
  /// unencrypted across the internet. `.local` (mDNS) names and literal
  /// private addresses pass; https URLs are unaffected. [checkSyntax] can
  /// only judge literals, so names are settled by [check] (call it again
  /// before connecting: DNS answers change).
  final bool httpRequiresLocalAddress;
  final Future<List<InternetAddress>> Function(String host) resolver;

  static Future<List<InternetAddress>> _systemResolve(String host) => InternetAddress.lookup(host);

  /// Syntactic checks that need no DNS. Throws [UrlPolicyViolation].
  Uri checkSyntax(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw UrlPolicyViolation(raw, 'not an absolute URL');
    }
    if (uri.userInfo.isNotEmpty) {
      throw UrlPolicyViolation(raw, 'credentials in URLs are not allowed');
    }
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'https' && scheme != 'http') {
      throw UrlPolicyViolation(raw, 'only https URLs are allowed');
    }
    if (scheme == 'http' && !(allowHttp && scope != NetworkScope.publicOnly)) {
      throw UrlPolicyViolation(raw, 'plain http is only allowed for local servers you add yourself');
    }
    final literal = InternetAddress.tryParse(_stripBrackets(uri.host));
    if (literal != null) {
      _checkAddress(raw, literal);
      if (scheme == 'http') _checkHttpAddress(raw, literal);
    }
    final host = uri.host.toLowerCase();
    if (scope == NetworkScope.publicOnly && (host == 'localhost' || host.endsWith('.localhost') || host.endsWith('.local') || host.endsWith('.internal'))) {
      throw UrlPolicyViolation(raw, 'local host names are not allowed here');
    }
    return uri;
  }

  /// Full check including DNS resolution of the host, so a public-looking
  /// name that resolves to a private address is rejected too.
  ///
  /// This narrows but cannot close DNS-rebinding windows; callers that fetch
  /// server-supplied URLs should also refuse redirects to other hosts.
  Future<Uri> check(String raw) async {
    final uri = checkSyntax(raw);
    if (InternetAddress.tryParse(_stripBrackets(uri.host)) != null) return uri;
    final List<InternetAddress> addresses;
    try {
      addresses = await resolver(uri.host);
    } on SocketException catch (e) {
      throw UrlPolicyViolation(raw, 'host does not resolve (${e.message})');
    }
    if (addresses.isEmpty) throw UrlPolicyViolation(raw, 'host does not resolve');
    final http = uri.scheme.toLowerCase() == 'http';
    for (final a in addresses) {
      _checkAddress(raw, a);
      if (http) _checkHttpAddress(raw, a);
    }
    return uri;
  }

  void _checkHttpAddress(String raw, InternetAddress a) {
    if (!httpRequiresLocalAddress || isLocalAddressKind(classify(a))) return;
    throw UrlPolicyViolation(
      raw,
      'plain http is only allowed to a server on your own network; ${a.address} is a public address',
    );
  }

  void _checkAddress(String raw, InternetAddress a) {
    final kind = classify(a);
    final ok = switch (kind) {
      AddressKind.public => true,
      AddressKind.private => scope != NetworkScope.publicOnly,
      AddressKind.loopback => scope == NetworkScope.loopback,
      AddressKind.linkLocal || AddressKind.unspecified || AddressKind.multicast || AddressKind.reserved => false,
    };
    if (!ok) throw UrlPolicyViolation(raw, '${kind.name} address ${a.address} is not allowed');
  }

  static String _stripBrackets(String h) => h.startsWith('[') && h.endsWith(']') ? h.substring(1, h.length - 1) : h;
}

enum AddressKind { public, private, loopback, linkLocal, unspecified, multicast, reserved }

/// Whether [kind] is an address on this device or the user's own network
/// (loopback, private incl. ULA and CGNAT, link-local): what
/// [UrlPolicy.httpRequiresLocalAddress] accepts for plain http.
bool isLocalAddressKind(AddressKind kind) => switch (kind) {
      AddressKind.loopback || AddressKind.private || AddressKind.linkLocal => true,
      _ => false,
    };

/// Classifies an address. Link-local (incl. 169.254.169.254 cloud metadata)
/// is never allowed, whatever the scope.
AddressKind classify(InternetAddress a) {
  final b = a.rawAddress;
  if (a.type == InternetAddressType.IPv4) {
    final (o0, o1) = (b[0], b[1]);
    if (o0 == 0) return AddressKind.unspecified;
    if (o0 == 127) return AddressKind.loopback;
    if (o0 == 10 || (o0 == 172 && o1 >= 16 && o1 <= 31) || (o0 == 192 && o1 == 168)) return AddressKind.private;
    if (o0 == 100 && o1 >= 64 && o1 <= 127) return AddressKind.private; // CGNAT
    if (o0 == 169 && o1 == 254) return AddressKind.linkLocal;
    if (o0 >= 224 && o0 <= 239) return AddressKind.multicast;
    if (o0 >= 240) return AddressKind.reserved;
    if (o0 == 192 && o1 == 0 && b[2] == 0) return AddressKind.reserved;
    if (o0 == 198 && (o1 == 18 || o1 == 19)) return AddressKind.reserved; // benchmarking
    return AddressKind.public;
  }
  if (b.every((x) => x == 0)) return AddressKind.unspecified;
  if (b.sublist(0, 15).every((x) => x == 0) && b[15] == 1) return AddressKind.loopback;
  // IPv4-mapped ::ffff:a.b.c.d → classify the embedded IPv4 address.
  if (b.sublist(0, 10).every((x) => x == 0) && b[10] == 0xff && b[11] == 0xff) {
    return classify(InternetAddress.fromRawAddress(b.sublist(12), type: InternetAddressType.IPv4));
  }
  if (b[0] == 0xfe && (b[1] & 0xc0) == 0x80) return AddressKind.linkLocal;
  if ((b[0] & 0xfe) == 0xfc) return AddressKind.private; // ULA fc00::/7
  if (b[0] == 0xff) return AddressKind.multicast;
  return AddressKind.public;
}
