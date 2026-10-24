import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa/app.dart';
import 'package:sherpa/bootstrap.dart' show noRetry;
import 'package:sherpa/features/diagnostics/app_error_ring.dart';
import 'package:sherpa/features/models/model_library_screen.dart' show modelFilePickerProvider;
import 'package:sherpa/features/models/state/local_model_choice.dart';
import 'package:sherpa/features/models/state/models_providers.dart';
import 'package:sherpa/routing/chat_route.dart';
import 'package:sherpa/routing/routes.dart';
import 'package:sherpa/services/device/device_profile_source.dart';
import 'package:sherpa/services/downloads/downloads.dart';
import 'package:sherpa/state/connectivity.dart';
import 'package:sherpa/state/provider_location.dart';
import 'package:sherpa/state/providers.dart';
import 'package:sherpa/state/ui_preferences.dart';
import 'package:sherpa_core/sherpa_core.dart' show InMemorySecretStore;
import 'package:sherpa_hub/sherpa_hub.dart';

import '../../support/harness.dart';
import '../onboarding/onboarding_on_device_test.dart' show settleUntil;
import 'support/models_rig.dart';

/// The download path with the app's real connectivity → network monitor →
/// download manager providers (only connectivity_plus's platform channels
/// are faked, answering what a phone answers).
///
/// The offline banner listens to the connectivity feed from the first frame
/// of every route; the download manager's network monitor listens later,
/// on the first download. A single-subscription feed made that second
/// listen throw, so on every real device the download manager could not be
/// built: onboarding said "The download couldn't start", and the model
/// page showed a grey box instead of its Download button. The rest of the
/// suite fakes the feed with a broadcast controller and injects a prebuilt
/// manager, which hid it.

const _method = MethodChannel('dev.fluttercommunity.plus/connectivity');
const _events = EventChannel('dev.fluttercommunity.plus/connectivity_status');

/// connectivity_plus answering like a phone on [types] (`wifi`, `mobile`, …).
void mockPhoneConnectivity(List<String> types) {
  final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  m.setMockMethodCallHandler(_method, (call) async => call.method == 'check' ? types : null);
  m.setMockStreamHandler(_events, MockStreamHandler.inline(onListen: (_, _) {}));
  addTearDown(() {
    m.setMockMethodCallHandler(_method, null);
    m.setMockStreamHandler(_events, null);
  });
}

/// The rig's services, minus the broadcast connectivity fake and the
/// prebuilt network monitor / library / download manager: those are the
/// production providers from lib/.
List<Override> productionDownloadOverrides(ModelsRig rig, {String folder = 'prod'}) {
  final a = rig.app;
  return [
    clockProvider.overrideWithValue(a.clock),
    idGeneratorProvider.overrideWithValue(a.ids),
    secretStoreProvider.overrideWithValue(a.secrets),
    sessionStoreProvider.overrideWithValue(a.store),
    providerRegistryProvider.overrideWithValue(a.appRegistry),
    preferencesProvider.overrideWithValue(a.prefs),
    uiPreferencesStoreProvider.overrideWithValue(a.ui),
    hapticsDriverProvider.overrideWithValue(a.haptics),
    chatScreenBuilderProvider.overrideWithValue(a.chat),
    hostResolverProvider.overrideWithValue(a.resolve),
    modelRecordStoreProvider.overrideWithValue(InMemoryRecordStore()),
    modelStorageLayoutProvider.overrideWithValue(ModelStorageLayout('${rig.dir.path}/$folder')),
    modelCatalogProvider.overrideWithValue(rig.catalog),
    modelShapeSourceProvider.overrideWithValue(rig.shapes),
    deviceProfileSourceProvider.overrideWithValue(rig.device),
    transferBackendProvider.overrideWithValue(rig.backend),
    hubHttpClientProvider.overrideWithValue(rig.hub.client),
    useLocalModelInChatProvider.overrideWithValue((context, choice) async {}),
    modelFilePickerProvider.overrideWithValue(() async => null),
  ];
}

final class _NoTransfers implements TransferBackend {
  @override
  int get transientBytes => 0;

  @override
  Future<void> recover() async {}

  @override
  TransferHandle start(TransferRequest request) => throw UnimplementedError();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('connectivity feed', () {
    test('every listener gets the current state first, then changes', () async {
      final changes = StreamController<List<ConnectivityResult>>.broadcast();
      addTearDown(changes.close);
      var checks = 0;
      final feed = connectivityFeed(
        current: () async {
          checks++;
          return [ConnectivityResult.wifi];
        },
        changes: changes.stream,
      );
      final a = <List<ConnectivityResult>>[];
      final b = <List<ConnectivityResult>>[];
      final subA = feed.listen(a.add);
      await pumpEventQueue();
      // A second listener (the download manager after the banner) is fine.
      final subB = feed.listen(b.add);
      await pumpEventQueue();
      changes.add([ConnectivityResult.mobile]);
      await pumpEventQueue();
      expect(a, [
        [ConnectivityResult.wifi],
        [ConnectivityResult.mobile],
      ]);
      expect(b, a);
      expect(checks, 2, reason: 'each listener reads the state when it subscribes');
      await subA.cancel();
      await subB.cancel();
    });

    test('a change that beats the initial check wins; the stale check is dropped', () async {
      final changes = StreamController<List<ConnectivityResult>>.broadcast();
      addTearDown(changes.close);
      final check = Completer<List<ConnectivityResult>>();
      final got = <List<ConnectivityResult>>[];
      final sub = connectivityFeed(current: () => check.future, changes: changes.stream).listen(got.add);
      await pumpEventQueue();
      changes.add([ConnectivityResult.none]);
      check.complete([ConnectivityResult.wifi]);
      await pumpEventQueue();
      expect(got, [
        [ConnectivityResult.none],
      ]);
      await sub.cancel();
    });
  });

  group('production providers', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('sherpa_wiring_'));
    tearDown(() async {
      if (dir.existsSync()) await dir.delete(recursive: true);
    });

    ProviderContainer container({DeviceProfile device = phone12}) {
      final c = ProviderContainer(overrides: [
        modelRecordStoreProvider.overrideWithValue(InMemoryRecordStore()),
        modelStorageLayoutProvider.overrideWithValue(ModelStorageLayout('${dir.path}/models')),
        secretStoreProvider.overrideWithValue(InMemorySecretStore()),
        transferBackendProvider.overrideWithValue(_NoTransfers()),
        deviceProfileSourceProvider.overrideWithValue(FixedDeviceProfileSource(device)),
        appErrorRingProvider.overrideWithValue(AppErrorRing()),
      ], retry: noRetry);
      addTearDown(c.dispose);
      return c;
    }

    test('the banner listens first, then the download manager builds and knows the phone is on Wi-Fi', () async {
      mockPhoneConnectivity(['wifi']);
      final c = container();
      // What OfflineBannerHost does on the first frame of every route.
      c.listen(networkStatusProvider, (_, _) {});
      await pumpEventQueue();
      expect(c.read(networkStatusProvider).value, NetworkStatus.online);

      // What onboarding's "Download … and start" does first. This threw
      // "Bad state: Stream has already been listened to".
      final manager = c.read(downloadManagerProvider);
      await manager.init();
      await pumpEventQueue();
      expect(c.read(networkMonitorProvider).current, NetworkKind.wifi);
      expect(c.read(appErrorRingProvider).records, isEmpty);
    });

    test('on mobile data the monitor knows it from the start, so Wi-Fi-only jobs wait and offer mobile data', () async {
      mockPhoneConnectivity(['mobile']);
      final c = container();
      c.listen(networkStatusProvider, (_, _) {});
      await pumpEventQueue();
      final manager = c.read(downloadManagerProvider);
      await manager.init();
      await pumpEventQueue();
      expect(c.read(networkMonitorProvider).current, NetworkKind.cellular,
          reason: 'not "unknown": an unknown network never holds a job, and the OS would hold it silently');
      final details = fixtureDetails(llama1b, llama1bFiles);
      final plan = planDownload(
          repo: details.id, commit: details.commit, files: [for (final f in details.files) f.file], quant: 'Q4_K_M');
      final o = await manager.enqueue(plan as DownloadPlan, meta: const DownloadMeta(displayName: 'Llama'));
      expect(o, isA<Enqueued>());
      expect(manager.job((o as Enqueued).jobId)!.phase, JobPhase.waitingForWifi);
    });

    test('a connectivity feed that cannot be listened to leaves the manager working (unknown network), and is recorded',
        () async {
      final c = ProviderContainer(overrides: [
        modelRecordStoreProvider.overrideWithValue(InMemoryRecordStore()),
        modelStorageLayoutProvider.overrideWithValue(ModelStorageLayout('${dir.path}/models')),
        secretStoreProvider.overrideWithValue(InMemorySecretStore()),
        transferBackendProvider.overrideWithValue(_NoTransfers()),
        deviceProfileSourceProvider.overrideWithValue(FixedDeviceProfileSource(phone12)),
        appErrorRingProvider.overrideWithValue(AppErrorRing()),
        // A single-subscription stream that someone else already holds.
        connectivityStreamProvider.overrideWith((ref) {
          final controller = StreamController<List<ConnectivityResult>>();
          ref.onDispose(controller.close);
          controller.stream.listen((_) {});
          return controller.stream;
        }),
      ], retry: noRetry);
      addTearDown(c.dispose);
      final manager = c.read(downloadManagerProvider);
      await manager.init();
      expect(c.read(networkMonitorProvider).current, NetworkKind.unknown);
      final rec = c.read(appErrorRingProvider).records.single;
      expect(rec.toJson(), containsPair('code', 'network_monitor'));
      expect(rec.type, 'StateError');
    });
  });

  testWidgets('onboarding: "Download … and start" downloads with the production providers', (tester) async {
    mockPhoneConnectivity(['wifi']);
    final ring = AppErrorRing();
    final rig = await ModelsRig.create(tester, onboarded: false, details: <String, CatalogModelDetails>{});
    rig.catalog.detailsById[llama1b] = fixtureDetails(llama1b, [for (final f in rig.hub.files.values) f.listing]);
    setWindow(tester, phone);
    await tester.pumpWidget(ProviderScope(
      overrides: [...productionDownloadOverrides(rig), appErrorRingProvider.overrideWithValue(ring)],
      retry: noRetry,
      observers: [AppErrorObserver(ring: ring)],
      child: const SherpaApp(),
    ));
    await tester.pumpAndSettle();
    await tapText(tester, 'Get started');
    await tapText(tester, 'Run a model on this phone');
    await settleUntil(tester, () => find.text('Finding a model that fits this phone…').evaluate().isEmpty, what: 'the pick');
    await tester.tap(find.textContaining('and start'));
    await settleUntil(
      tester,
      () =>
          find.textContaining("couldn't").evaluate().isNotEmpty ||
          find.textContaining(RegExp('chat:|Opening your first chat')).evaluate().isNotEmpty,
      what: 'the download to finish or fail',
    );
    expect(find.textContaining("couldn't"), findsNothing);
    expect(rig.backend.requests, isNotEmpty, reason: 'bytes moved through the transfer backend');
    expect(ring.records, isEmpty);
    await tester.pumpWidget(const SizedBox());
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('a model page offers its Download button with the production providers, and it downloads',
      (tester) async {
    mockPhoneConnectivity(['wifi']);
    final ring = AppErrorRing();
    final rig = await ModelsRig.create(tester, details: <String, CatalogModelDetails>{});
    rig.catalog.detailsById[llama1b] = fixtureDetails(llama1b, [for (final f in rig.hub.files.values) f.listing]);
    setWindow(tester, phone);
    final errors = <Object>[];
    final previous = FlutterError.onError;
    FlutterError.onError = (d) => errors.add(d.exception);
    addTearDown(() => FlutterError.onError = previous);
    await tester.pumpWidget(ProviderScope(
      overrides: [...productionDownloadOverrides(rig), appErrorRingProvider.overrideWithValue(ring)],
      retry: noRetry,
      observers: [AppErrorObserver(ring: ring)],
      child: const SherpaApp(),
    ));
    await tester.pumpAndSettle();
    await goTo(tester, Routes.modelDetail(llama1b));
    await settleUntil(tester, () => find.textContaining(RegExp(r'^Download Q')).evaluate().isNotEmpty,
        what: 'the Download button');
    expect(find.byType(ErrorWidget), findsNothing);
    await tester.tap(find.textContaining(RegExp(r'^Download Q')));
    await settleUntil(tester, () => rig.backend.requests.isNotEmpty, what: 'the transfer');
    FlutterError.onError = previous;
    expect(errors, isEmpty);
    expect(ring.records, isEmpty);
    await tester.pumpWidget(const SizedBox());
  }, timeout: const Timeout(Duration(minutes: 2)));
}
