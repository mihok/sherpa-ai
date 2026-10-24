import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart' show setEquals;

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
  /// still applies, so a link the system doesn't count as Wi-Fi never
  /// carries a Wi-Fi-only download.
  unknown;

  bool get isOnline => this != offline;
}

/// Maps connectivity_plus interface types. It reports interfaces, not
/// reachability or meteredness: a phone tethered to another phone's
/// hotspot looks like Wi-Fi, here and to the OS constraint on the
/// transfer ([TransferRequest.requiresWiFi], a Wi-Fi network request on
/// Android 9 and later), so "Wi-Fi only" cannot keep a download off a
/// hotspot.
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

  /// The kind after each change of connection. That includes a change
  /// that keeps the kind, such as a VPN going on or off over Wi-Fi: the OS
  /// may judge the new link differently for a Wi-Fi-only transfer (Android
  /// doesn't start one while a VPN carries the traffic), so a download it
  /// held deserves another try.
  Stream<NetworkKind> get changes;
}

/// [NetworkMonitor] over a connectivity stream (the app's
/// `connectivityStreamProvider`, which tests already fake). The stream's
/// first event is the current state, so the monitor knows from its first
/// moment whether the phone is on Wi-Fi or mobile data. A later event with
/// the same kind but other interfaces (`[wifi, vpn]` → `[wifi]`) is a
/// change too; a repeat of the same interfaces is not.
///
/// A source that fails (plugin error, or a stream that refuses another
/// listener) leaves the monitor at [NetworkKind.unknown], which never
/// blocks a download, and is reported to [onError]: a broken connectivity
/// signal must never take the download manager down with it.
final class ConnectivityNetworkMonitor implements NetworkMonitor {
  ConnectivityNetworkMonitor(
    Stream<List<ConnectivityResult>> source, {
    NetworkKind initial = NetworkKind.unknown,
    void Function(Object error)? onError,
  }) : _current = initial {
    try {
      _sub = source.listen((r) {
        final next = networkKindOf(r);
        final link = r.toSet();
        final last = _link;
        final changed = next != _current || (last != null && !setEquals(link, last));
        _current = next;
        _link = link;
        if (changed) _changes.add(next);
      }, onError: (Object e) => onError?.call(e));
    } on Object catch (e) {
      onError?.call(e);
    }
  }

  NetworkKind _current;

  /// The interfaces of the last event; null before the first.
  Set<ConnectivityResult>? _link;
  StreamSubscription<List<ConnectivityResult>>? _sub;
  final StreamController<NetworkKind> _changes = StreamController.broadcast();

  @override
  NetworkKind get current => _current;

  @override
  Stream<NetworkKind> get changes => _changes.stream;

  Future<void> dispose() async {
    await _sub?.cancel();
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
