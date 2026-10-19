import 'dart:io' show InternetAddress;

import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_net/sherpa_net.dart';

/// The URL policy for a user-configured model endpoint.
///
/// Public endpoints must be https on public addresses. When the user marked
/// the endpoint as their own local server, private addresses are allowed,
/// and so is loopback: a server on the phone itself (Termux, an on-device
/// llama-server) or the host machine seen from an iOS simulator is reached
/// via `localhost`. Plain http is allowed then too, but only to a host that
/// resolves to such a local address ([UrlPolicy.httpRequiresLocalAddress]):
/// the opt-in must never send prompts and the API key unencrypted to a
/// public server named by hostname. Link-local and metadata addresses stay
/// blocked whatever the setting (enforced by [UrlPolicy]).
///
/// [resolver] replaces system DNS (tests, or a caller that resolves itself).
UrlPolicy endpointUrlPolicy({
  required bool allowLocalNetwork,
  Future<List<InternetAddress>> Function(String host)? resolver,
}) {
  if (resolver != null) {
    return allowLocalNetwork
        ? UrlPolicy(scope: NetworkScope.loopback, allowHttp: true, httpRequiresLocalAddress: true, resolver: resolver)
        : UrlPolicy(resolver: resolver);
  }
  return allowLocalNetwork
      ? const UrlPolicy(scope: NetworkScope.loopback, allowHttp: true, httpRequiresLocalAddress: true)
      : const UrlPolicy();
}

/// Where prompts sent to [baseUrl] are processed, for the privacy
/// indicator. Decided from the URL alone (no DNS), erring towards
/// [ExecutionLocation.remote] for names that could be public.
ExecutionLocation endpointLocation(Uri baseUrl) {
  final host = baseUrl.host.toLowerCase();
  final bare = host.startsWith('[') && host.endsWith(']') ? host.substring(1, host.length - 1) : host;
  final ip = InternetAddress.tryParse(bare);
  if (ip != null) {
    return switch (classify(ip)) {
      AddressKind.private || AddressKind.loopback || AddressKind.linkLocal => ExecutionLocation.localNetwork,
      _ => ExecutionLocation.remote,
    };
  }
  final local = host == 'localhost' ||
      !host.contains('.') ||
      const ['.localhost', '.local', '.lan', '.home', '.internal', '.home.arpa', '.localdomain']
          .any(host.endsWith);
  return local ? ExecutionLocation.localNetwork : ExecutionLocation.remote;
}

/// Joins [path] onto [base] keeping the base path (`/v1`, `/api/v1`) and any
/// query (Azure-style `?api-version=`).
Uri joinPath(Uri base, String path) {
  final b = base.path.endsWith('/') ? base.path.substring(0, base.path.length - 1) : base.path;
  final p = path.startsWith('/') ? path : '/$path';
  return base.replace(path: '$b$p');
}

/// [base] with a trailing `/v1` or `/api/v1` removed: where server-native
/// endpoints such as `/props` or `/api/version` live (R10 §5).
Uri serverRoot(Uri base) {
  var p = base.path;
  while (p.endsWith('/')) {
    p = p.substring(0, p.length - 1);
  }
  for (final suffix in const ['/api/v1', '/v1']) {
    if (p.endsWith(suffix)) {
      p = p.substring(0, p.length - suffix.length);
      break;
    }
  }
  return base.replace(path: p);
}
