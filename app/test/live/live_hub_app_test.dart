@Tags(['live'])
library;

import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/io_client.dart';
import 'package:sherpa/bootstrap.dart' show noRetry;
import 'package:sherpa/features/diagnostics/app_error_ring.dart';
import 'package:sherpa/features/models/state/directory_controller.dart';
import 'package:sherpa/features/models/state/models_providers.dart';
import 'package:sherpa/features/models/state/variant_download.dart';
import 'package:sherpa/features/onboarding/starter_model.dart';
import 'package:sherpa/services/device/device_profile_source.dart';
import 'package:sherpa/services/downloads/downloads.dart';
import 'package:sherpa/state/connectivity.dart';
import 'package:sherpa/state/providers.dart';
import 'package:sherpa_core/sherpa_core.dart' show InMemorySecretStore;
import 'package:sherpa_hub/sherpa_hub.dart';

/// The two paths from the field report, against the real huggingface.co,
/// through the app's own providers (only the platform plugins are stood in
/// for: connectivity says Wi-Fi, bytes move in-process instead of through
/// background_downloader). Off by default:
///
///     SHERPA_LIVE_HUB=1 flutter test test/live/live_hub_app_test.dart
///
/// Honours HTTPS_PROXY, and SHERPA_LIVE_CA (a PEM bundle) for TLS-inspecting
/// proxies. Anonymous only: about 15 API requests, and at most a few MB of
/// model bytes (a GGUF header peek plus the first MiB of the starter model).
void main() {
  final enabled = Platform.environment['SHERPA_LIVE_HUB'] == '1';
  final skip = enabled ? false : 'set SHERPA_LIVE_HUB=1 to run against huggingface.co';
  late IOClient http;
  late Directory dir;
  late AppErrorRing ring;

  HttpOverrides? testOverrides;

  setUpAll(() async {
    if (!enabled) return;
    // flutter_test answers every HttpClient request with 400; this file
    // talks to the real Hub.
    testOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    final ca = Platform.environment['SHERPA_LIVE_CA'];
    final ctx = SecurityContext(withTrustedRoots: true);
    if (ca != null && File(ca).existsSync()) ctx.setTrustedCertificates(ca);
    http = IOClient(HttpClient(context: ctx)
      ..findProxy = HttpClient.findProxyFromEnvironment
      ..connectionTimeout = const Duration(seconds: 20));
    dir = await Directory.systemTemp.createTemp('sherpa_live_');
  });

  tearDownAll(() async {
    if (!enabled) return;
    HttpOverrides.global = testOverrides;
    http.close();
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  ProviderContainer container({TransferBackend? transfers}) {
    ring = AppErrorRing();
    final c = ProviderContainer(overrides: [
      hubHttpClientProvider.overrideWithValue(http),
      secretStoreProvider.overrideWithValue(InMemorySecretStore()),
      modelRecordStoreProvider.overrideWithValue(InMemoryRecordStore()),
      modelStorageLayoutProvider.overrideWithValue(ModelStorageLayout('${dir.path}/models')),
      // An 8 GB arm64 Android phone with room to spare.
      deviceProfileSourceProvider.overrideWithValue(FixedDeviceProfileSource(const DeviceProfile(
        platform: DevicePlatform.android,
        totalRamBytes: 8 << 30,
        freeStorageBytes: 64 << 30,
      ))),
      connectivityStreamProvider.overrideWithValue(connectivityFeed(
        current: () async => [ConnectivityResult.wifi],
        changes: const Stream.empty(),
      )),
      if (transfers != null) transferBackendProvider.overrideWithValue(transfers),
      appErrorRingProvider.overrideWithValue(ring),
    ], retry: noRetry);
    addTearDown(c.dispose);
    return c;
  }

  Future<void> until(bool Function() test, {required String what, Duration timeout = const Duration(seconds: 60)}) async {
    final deadline = DateTime.now().add(timeout);
    while (!test()) {
      if (DateTime.now().isAfter(deadline)) throw TimeoutException('timed out waiting for $what');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  test('Browse: the default directory, a typed query and a pasted link return models', () async {
    final c = container();
    c.listen(directoryControllerProvider, (_, _) {});
    DirectoryState s() => c.read(directoryControllerProvider);
    final controller = c.read(directoryControllerProvider.notifier);
    Future<void> settled() async {
      await Future<void>.delayed(DirectoryController.debounce + const Duration(milliseconds: 50));
      await until(() => !s().loading && !s().loadingMore, what: 'the search');
    }

    await settled();
    expect(s().failure, isNull, reason: '${s().failure}');
    expect(s().raw.length, greaterThanOrEqualTo(30), reason: 'the default trending GGUF page');
    expect(s().items, isNotEmpty);

    controller.setText('qwen3 0.6b');
    await settled();
    expect(s().failure, isNull, reason: '${s().failure}');
    expect(s().items.map((e) => e.id.toLowerCase()), contains(contains('qwen3-0.6b')));

    controller.setText('https://huggingface.co/Qwen/Qwen3-0.6B-GGUF');
    await settled();
    expect(s().failure, isNull, reason: '${s().failure}');
    expect(s().items.map((e) => e.id), contains('Qwen/Qwen3-0.6B-GGUF'));
    expect(s().query.repoId, 'Qwen/Qwen3-0.6B-GGUF');

    controller
      ..setText('')
      ..update((q) => q.copyWith(size: SizeBucket.tiny));
    await settled();
    expect(s().failure, isNull, reason: '${s().failure}');
    expect(s().items.isNotEmpty || s().hasMore, isTrue, reason: 'results, or a way to search further');
    expect(ring.records, isEmpty);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 3)));

  test("Onboarding: the starter model resolves to the CDN and its first bytes arrive through the app's DownloadManager",
      () async {
    final transfers = _FirstBytes(InProcessTransferBackend(client: http, token: () async => null));
    final c = container(transfers: transfers);
    final pick = await c.read(starterModelProvider.future);
    expect(kStarterModelRepos, contains(pick.details.id));
    expect(pick.row.downloadBytes, lessThanOrEqualTo(kStarterMaxDownloadBytes));

    final manager = c.read(downloadManagerProvider);
    final o = await enqueueVariant(manager, pick.details, pick.row, pick.shape);
    expect(o, isA<Enqueued>(), reason: o is EnqueueRefused ? o.reasons.join(' ') : '$o');
    final jobId = (o as Enqueued).jobId;
    await until(() => transfers.bytes >= 1 << 20 || manager.job(jobId)!.phase == JobPhase.failed,
        what: 'the first MiB', timeout: const Duration(minutes: 2));
    await manager.pause(jobId);
    final v = manager.job(jobId)!;
    expect(v.phase, isNot(JobPhase.failed), reason: v.error);

    final r = transfers.requests.first;
    expect(r.hubOrigin, isFalse, reason: 'LFS/Xet files come from the CDN');
    expect(r.url.host, isNot('huggingface.co'));
    expect(r.headers.keys.map((k) => k.toLowerCase()), isNot(contains('authorization')));
    expect(r.requiresWiFi, isTrue);
    final part = File(manager.layout.partPath(r.id));
    final head = part.openSync()..setPositionSync(0);
    expect(String.fromCharCodes(head.readSync(4)), 'GGUF');
    head.closeSync();

    await manager.cancel(jobId);
    expect(part.existsSync(), isFalse);
    expect(ring.records, isEmpty);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 4)));
}

/// The in-process backend, stopped hard after [limit] bytes so a live run
/// never pulls a whole model, and never restarted.
final class _FirstBytes implements TransferBackend {
  _FirstBytes(this._inner);

  static const int limit = 8 << 20;

  final TransferBackend _inner;
  final List<TransferRequest> requests = [];
  int bytes = 0;

  @override
  int get transientBytes => 0;

  @override
  Future<void> recover() => _inner.recover();

  @override
  TransferHandle start(TransferRequest request) {
    requests.add(request);
    final h = _inner.start(request);
    h.progress.listen((p) {
      bytes = p.bytesOnDisk;
      if (bytes >= limit) unawaited(h.stop());
    });
    return h;
  }
}
