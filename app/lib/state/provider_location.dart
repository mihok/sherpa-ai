import 'dart:async';
import 'dart:io' show InternetAddress, SocketException;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_net/sherpa_net.dart' show AddressKind, classify;
import 'package:sherpa_providers/sherpa_providers.dart';

/// Resolves a host name to its addresses (system DNS in the app, a fake in
/// tests).
typedef HostResolver = Future<List<InternetAddress>> Function(String host);

/// DNS for the "my own network" checks: the base-URL check before saving a
/// provider and the badge verification ([verifyLocalHost]). Tests override
/// it (real lookups never complete inside widget tests).
final hostResolverProvider = Provider<HostResolver>((ref) => InternetAddress.lookup);

/// [localHostVerdicts] for widgets: watching it rebuilds them when a host
/// gets verified, so a badge computed with [locationOf] stays current.
final localHostVerdictsProvider = Provider<LocalHostVerdicts>((ref) {
  void changed() => ref.notifyListeners();
  localHostVerdicts.addListener(changed);
  ref.onDispose(() => localHostVerdicts.removeListener(changed));
  return localHostVerdicts;
});

/// Where prompts sent to [config] physically go. Drives every privacy badge
/// and the privacy dashboard, so it errs towards "leaves the device".
///
/// - loopback (127.0.0.1, ::1, localhost): a server running on this phone
///   (e.g. llama.cpp in Termux) → on device;
/// - private addresses and `.local` / `.lan` / `.home.arpa` names → local
///   network (still leaves the phone!);
/// - any other host name the user marked as "my own network" → local
///   network only once DNS confirmed it ([verifyLocalHost]: every address it
///   resolves to is private or loopback). Until then it counts as remote
///   and [isUnverifiedLocal] is true, so badges can say so: the opt-in alone
///   never makes a public server look local;
/// - everything else → remote.
///
/// Synchronous: verdicts come from [localHostVerdicts], a small app-wide
/// cache filled by [verifyLocalHost].
ExecutionLocation locationOf(ProviderConfig config, {LocalHostVerdicts? verdicts}) {
  final host = config.baseUrl.host.toLowerCase();
  final literal = _literal(host);
  if (literal != null) return _locationOfAddresses([literal]);
  if (host == 'localhost' || host.endsWith('.localhost')) return ExecutionLocation.onDevice;
  if (_isLocalName(host)) return ExecutionLocation.localNetwork;
  if (!config.allowLocalNetwork) return ExecutionLocation.remote;
  return (verdicts ?? localHostVerdicts).of(host) ?? ExecutionLocation.remote;
}

/// The user said "this is a server on my own network" for a host name DNS
/// hasn't confirmed yet: badges show it as leaving the device, marked
/// unverified ([privacyHostLabel]).
bool isUnverifiedLocal(ProviderConfig config, {LocalHostVerdicts? verdicts}) {
  if (!config.allowLocalNetwork) return false;
  final host = config.baseUrl.host.toLowerCase();
  if (_literal(host) != null || host == 'localhost' || host.endsWith('.localhost') || _isLocalName(host)) {
    return false;
  }
  return (verdicts ?? localHostVerdicts).of(host) == null;
}

/// Host text for [config]'s privacy badge: [hostLabel], plus "(unverified)"
/// while [isUnverifiedLocal].
String privacyHostLabel(ProviderConfig config, {LocalHostVerdicts? verdicts}) {
  final label = hostLabel(config.baseUrl);
  return isUnverifiedLocal(config, verdicts: verdicts) ? '$label (unverified)' : label;
}

/// Looks up [config]'s host (when it is a name behind the "my own network"
/// opt-in) and records where it points, so [locationOf] can call it local.
/// Returns the location afterwards. A name that doesn't resolve stays
/// unverified; nothing here ever throws.
Future<ExecutionLocation> verifyLocalHost(
  ProviderConfig config, {
  HostResolver? resolver,
  LocalHostVerdicts? verdicts,
}) async {
  final cache = verdicts ?? localHostVerdicts;
  if (isUnverifiedLocal(config, verdicts: cache)) {
    final host = config.baseUrl.host.toLowerCase();
    try {
      cache.record(host, await (resolver ?? InternetAddress.lookup)(host));
    } on SocketException {
      // Offline, or the LAN server's name isn't known here: stays unverified.
    } on Object catch (e) {
      debugPrint('verifyLocalHost($host): $e');
    }
  }
  return locationOf(config, verdicts: cache);
}

/// For widgets that show [config]'s badge: starts [verifyLocalHost] in the
/// background when its host is an unverified opt-in name (once per host at
/// a time). Widgets watch [localHostVerdictsProvider] to rebuild when the
/// verdict lands.
void ensureLocalHostVerified(ProviderConfig config, HostResolver resolver, {LocalHostVerdicts? verdicts}) {
  if (!isUnverifiedLocal(config, verdicts: verdicts)) return;
  final host = config.baseUrl.host.toLowerCase();
  if (!_verifying.add(host)) return;
  unawaited(
    verifyLocalHost(config, resolver: resolver, verdicts: verdicts).whenComplete(() => _verifying.remove(host)),
  );
}

final Set<String> _verifying = {};

/// DNS verdicts for host names behind the "my own network" opt-in, keyed by
/// lowercase host. A verdict expires after [ttl] (DNS answers change), and a
/// listener hears about every new one so badges can rebuild.
final class LocalHostVerdicts extends ChangeNotifier {
  LocalHostVerdicts({this.ttl = const Duration(minutes: 30), DateTime Function()? now})
      : _now = now ?? DateTime.now;

  final Duration ttl;
  final DateTime Function() _now;
  final Map<String, ({ExecutionLocation location, DateTime at})> _verdicts = {};

  /// The verified location of [host], or null when unknown or expired.
  ExecutionLocation? of(String host) {
    final v = _verdicts[host.toLowerCase()];
    if (v == null || _now().difference(v.at) > ttl) return null;
    return v.location;
  }

  /// Records what [host] resolved to: on device when every address is
  /// loopback, local network when every address is loopback or private,
  /// otherwise remote. An empty answer records nothing.
  void record(String host, List<InternetAddress> addresses) {
    if (addresses.isEmpty) return;
    final location = _locationOfAddresses(addresses);
    final key = host.toLowerCase();
    final before = of(key);
    _verdicts[key] = (location: location, at: _now());
    if (before != location) notifyListeners();
  }

  @visibleForTesting
  void clear() {
    _verdicts.clear();
    notifyListeners();
  }
}

/// The app-wide verdict cache [locationOf] reads by default.
final LocalHostVerdicts localHostVerdicts = LocalHostVerdicts();

/// Host shown in "Leaves device → host" (port kept for LAN servers, where it
/// tells Ollama apart from LM Studio on the same machine).
String hostLabel(Uri uri) {
  final host = uri.host;
  final defaultPort = (uri.scheme == 'https' && uri.port == 443) || (uri.scheme == 'http' && uri.port == 80);
  return !uri.hasPort || defaultPort ? host : '$host:${uri.port}';
}

InternetAddress? _literal(String host) {
  final bare = host.startsWith('[') && host.endsWith(']') ? host.substring(1, host.length - 1) : host;
  return InternetAddress.tryParse(bare);
}

/// Special-use names that only exist on a local network (mDNS `.local`,
/// RFC 8375 `.home.arpa`, the common router `.lan`).
bool _isLocalName(String host) => host.endsWith('.local') || host.endsWith('.lan') || host.endsWith('.home.arpa');

ExecutionLocation _locationOfAddresses(List<InternetAddress> addresses) {
  final kinds = addresses.map(classify).toSet();
  if (kinds.every((k) => k == AddressKind.loopback)) return ExecutionLocation.onDevice;
  final local = kinds.every((k) => k == AddressKind.loopback || k == AddressKind.private || k == AddressKind.linkLocal);
  return local ? ExecutionLocation.localNetwork : ExecutionLocation.remote;
}
