import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum NetworkStatus { online, offline, unknown }

/// Raw interface changes, starting with the current state. Override in tests
/// with a `StreamController` to fake going offline.
final connectivityStreamProvider = Provider<Stream<List<ConnectivityResult>>>((ref) async* {
  final connectivity = Connectivity();
  yield await connectivity.checkConnectivity();
  yield* connectivity.onConnectivityChanged;
});

/// Online/offline as the UI should treat it.
///
/// connectivity_plus reports interface types, not reachability: "online"
/// means "has a network", so copy must not promise that a server is up.
/// Plugin failures map to [NetworkStatus.unknown] (treated like online):
/// a broken signal must never block the user.
final networkStatusProvider = StreamProvider<NetworkStatus>((ref) async* {
  try {
    await for (final results in ref.watch(connectivityStreamProvider)) {
      yield statusFor(results);
    }
  } on Object {
    yield NetworkStatus.unknown;
  }
});

NetworkStatus statusFor(List<ConnectivityResult> results) =>
    results.isEmpty || results.every((r) => r == ConnectivityResult.none) ? NetworkStatus.offline : NetworkStatus.online;
