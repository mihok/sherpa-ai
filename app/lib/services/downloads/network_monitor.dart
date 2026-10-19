import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

/// What kind of network the device is on, as far as "Wi-Fi only" cares.
enum NetworkKind {
  /// Wi-Fi or Ethernet: unmetered for our purposes.
  wifi,

  /// Mobile data only.
  cellular,

  /// No network interface.
  offline,

  /// VPN-only, Bluetooth tethering, plugin failure… The manager does not
  /// block on unknown; the OS-level `requiresWiFi` flag on the transfer
  /// still applies, so a metered link is refused by the system itself.
  unknown;

  bool get isOnline => this != offline;
}

/// Maps connectivity_plus interface types. It reports interfaces, not
/// reachability or meteredness; a phone tethered to another phone's
/// hotspot looks like Wi-Fi. That gap is why transfers also carry the OS
/// constraint ([TransferRequest.requiresWiFi]).
NetworkKind networkKindOf(List<ConnectivityResult> results) {
  if (results.isEmpty || results.every((r) => r == ConnectivityResult.none)) return NetworkKind.offline;
  if (results.contains(ConnectivityResult.wifi) || results.contains(ConnectivityResult.ethernet)) {
    return NetworkKind.wifi;
  }
  if (results.contains(ConnectivityResult.mobile)) return NetworkKind.cellular;
  return NetworkKind.unknown;
}

/// Current network kind plus changes.
abstract interface class NetworkMonitor {
  NetworkKind get current;

  Stream<NetworkKind> get changes;
}

/// [NetworkMonitor] over a connectivity stream (the app's
/// `connectivityStreamProvider`, which tests already fake).
final class ConnectivityNetworkMonitor implements NetworkMonitor {
  ConnectivityNetworkMonitor(Stream<List<ConnectivityResult>> source, {NetworkKind initial = NetworkKind.unknown})
      : _current = initial {
    _sub = source.listen((r) {
      final next = networkKindOf(r);
      if (next == _current) return;
      _current = next;
      _changes.add(next);
    }, onError: (Object _) {});
  }

  NetworkKind _current;
  late final StreamSubscription<List<ConnectivityResult>> _sub;
  final StreamController<NetworkKind> _changes = StreamController.broadcast();

  @override
  NetworkKind get current => _current;

  @override
  Stream<NetworkKind> get changes => _changes.stream;

  Future<void> dispose() async {
    await _sub.cancel();
    await _changes.close();
  }
}

/// Settable monitor for tests and previews.
final class FakeNetworkMonitor implements NetworkMonitor {
  FakeNetworkMonitor([this._current = NetworkKind.wifi]);

  NetworkKind _current;
  final StreamController<NetworkKind> _changes = StreamController.broadcast();

  @override
  NetworkKind get current => _current;

  set current(NetworkKind v) {
    if (v == _current) return;
    _current = v;
    _changes.add(v);
  }

  @override
  Stream<NetworkKind> get changes => _changes.stream;

  Future<void> dispose() => _changes.close();
}
