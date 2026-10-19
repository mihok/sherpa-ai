import 'dart:io' show InternetAddress;

import 'package:meta/meta.dart';
import 'package:sherpa_net/sherpa_net.dart';

import '../errors.dart';

/// Which hosts OAuth traffic may reach (R02 §14.3).
///
/// Every URL the OAuth client fetches or opens is attacker-influenced:
/// `resource_metadata` comes from a `WWW-Authenticate` header,
/// `authorization_servers` from the PRM, every endpoint from AS metadata.
/// The default is [UrlPolicy] in `publicOnly` mode (https, public addresses,
/// DNS-resolved). The one exception is a server the *user* added as a LAN
/// or loopback server: its host — and only its host — is checked with the
/// wider [localPolicy], so a self-hosted server can run its AS on the same
/// box without turning every metadata URL into a LAN probe. A private
/// address on any other host stays blocked.
@immutable
final class AuthNetworkPolicy {
  const AuthNetworkPolicy({
    this.publicPolicy = const UrlPolicy(),
    this.localPolicy,
    this.localHosts = const {},
  });

  /// Policy for the server at [serverUrl], which the user configured with
  /// [scope] (`publicOnly` unless they explicitly added a LAN/loopback
  /// server). [allowHttp] permits plain http on that host only.
  ///
  /// [extraLocalHosts] are further hosts the user explicitly trusted for
  /// this server (e.g. its AS on another LAN machine).
  factory AuthNetworkPolicy.forServer(
    Uri serverUrl, {
    NetworkScope scope = NetworkScope.publicOnly,
    bool allowHttp = false,
    Set<String> extraLocalHosts = const {},
    Future<List<InternetAddress>> Function(String host)? resolver,
  }) {
    final public = resolver == null ? const UrlPolicy() : UrlPolicy(resolver: resolver);
    if (scope == NetworkScope.publicOnly) return AuthNetworkPolicy(publicPolicy: public);
    return AuthNetworkPolicy(
      publicPolicy: public,
      localPolicy: resolver == null
          ? UrlPolicy(scope: scope, allowHttp: allowHttp)
          : UrlPolicy(scope: scope, allowHttp: allowHttp, resolver: resolver),
      localHosts: {serverUrl.host.toLowerCase(), for (final h in extraLocalHosts) h.toLowerCase()},
    );
  }

  final UrlPolicy publicPolicy;
  final UrlPolicy? localPolicy;

  /// Lower-cased hosts (names or literals) the user explicitly trusted.
  final Set<String> localHosts;

  UrlPolicy policyFor(Uri url) {
    final local = localPolicy;
    return local != null && localHosts.contains(url.host.toLowerCase()) ? local : publicPolicy;
  }

  /// Syntax-only check (no DNS), for URLs handed to the system browser.
  Uri checkSyntax(Uri url) {
    _rejectAmbiguousNumericHost(url);
    try {
      return policyFor(url).checkSyntax(url.toString());
    } on UrlPolicyViolation catch (e) {
      throw AuthPolicyException('blocked URL: ${e.reason}', url: url);
    }
  }

  /// Full check including DNS resolution, for URLs this process connects to.
  Future<Uri> check(Uri url) async {
    _rejectAmbiguousNumericHost(url);
    try {
      return await policyFor(url).check(url.toString());
    } on UrlPolicyViolation catch (e) {
      throw AuthPolicyException('blocked URL: ${e.reason}', url: url);
    }
  }

  static final RegExp _numericLabel = RegExp(r'^(0x[0-9a-f]*|[0-9]+)$', caseSensitive: false);
  static final RegExp _canonicalOctet = RegExp(r'^(0|[1-9][0-9]{0,2})$');

  /// Rejects IPv4 spellings that are not canonical dotted-quad: octal
  /// (`0177.0.0.1`), hex (`0x7f.1`), shortened (`127.1`) or single-number
  /// (`2130706433`) forms. `InternetAddress.tryParse` returns null for them,
  /// so the literal-address check would be skipped while `getaddrinfo` may
  /// still resolve them to loopback (SBP26 SSRF: "octal, hex and mapped
  /// forms").
  static void _rejectAmbiguousNumericHost(Uri url) {
    var host = url.host;
    if (host.endsWith('.')) host = host.substring(0, host.length - 1);
    if (host.isEmpty || host.contains(':')) return; // IPv6 literals are parsed by UrlPolicy.
    final labels = host.split('.');
    if (labels.length > 4 || !labels.every(_numericLabel.hasMatch)) return;
    final canonical = labels.length == 4 &&
        labels.every((l) => _canonicalOctet.hasMatch(l) && int.parse(l) <= 255) &&
        InternetAddress.tryParse(host) != null;
    if (!canonical) throw AuthPolicyException('blocked URL: non-canonical numeric host', url: url);
  }
}
