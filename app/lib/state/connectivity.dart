import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/diagnostics/app_error_ring.dart';

enum NetworkStatus { online, offline, unknown }

/// Raw interface changes, starting with the current state.
///
/// Several consumers listen to this one stream: the offline banner
/// ([networkStatusProvider], from the first frame of every route) and the
/// download manager's network monitor (built on the first download). It
/// must therefore accept any number of listeners, and each must start with
/// the current state: a single-subscription stream here made the second
/// listener throw "Stream has already been listened to", which left the
/// download manager unbuildable on every real device.
///
/// Override in tests with a `StreamController`'s stream to fake going
/// offline.
final connectivityStreamProvider = Provider<Stream<List<ConnectivityResult>>>(
  (ref) {
    final connectivity = Connectivity();
    return connectivityFeed(current: connectivity.checkConnectivity, changes: connectivity.onConnectivityChanged);
  },
  name: 'connectivityStreamProvider',
);

/// A stream that any number of listeners can subscribe to; each one gets
/// [current] first, then every event of [changes] (connectivity_plus's
/// `onConnectivityChanged`, a broadcast stream).
///
/// A change that arrives before [current] answers is newer than it, so the
/// late answer is dropped instead of rolling the state back.
Stream<List<ConnectivityResult>> connectivityFeed({
  required Future<List<ConnectivityResult>> Function() current,
  required Stream<List<ConnectivityResult>> changes,
}) =>
    Stream.multi((c) {
      var changed = false;
      var cancelled = false;
      final sub = changes.listen((r) {
        changed = true;
        c.add(r);
      }, onError: c.addError);
      c.onCancel = () {
        cancelled = true;
        return sub.cancel();
      };
      Future<List<ConnectivityResult>>.sync(current).then((r) {
        if (!changed && !cancelled) c.add(r);
      }, onError: (Object e, StackTrace s) {
        if (!changed && !cancelled) c.addError(e, s);
      });
    });

/// Online/offline as the UI should treat it.
///
/// connectivity_plus reports interface types, not reachability: "online"
/// means "has a network", so copy must not promise that a server is up.
/// Plugin failures map to [NetworkStatus.unknown] (treated like online):
/// a broken signal must never block the user. They are recorded in the
/// diagnostics error ring, never swallowed silently.
final networkStatusProvider = StreamProvider<NetworkStatus>(
  (ref) async* {
    try {
      await for (final results in ref.watch(connectivityStreamProvider)) {
        yield statusFor(results);
      }
    } on Object catch (e) {
      ref.read(appErrorRingProvider).record(e, source: 'connectivity', code: 'network_status');
      yield NetworkStatus.unknown;
    }
  },
  name: 'networkStatusProvider',
);

NetworkStatus statusFor(List<ConnectivityResult> results) =>
    results.isEmpty || results.every((r) => r == ConnectivityResult.none) ? NetworkStatus.offline : NetworkStatus.online;
