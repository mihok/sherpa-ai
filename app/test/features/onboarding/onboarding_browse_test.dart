import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa/app.dart';
import 'package:sherpa/bootstrap.dart' show noRetry;
import 'package:sherpa/features/diagnostics/app_error_ring.dart';
import 'package:sherpa/features/models/hf_account_screen.dart';
import 'package:sherpa/features/models/model_detail_screen.dart';
import 'package:sherpa/features/models/state/models_providers.dart';
import 'package:sherpa/services/downloads/downloads.dart';
import 'package:sherpa/state/services.dart' show localProviderId;
import 'package:sherpa_hub/sherpa_hub.dart';

import '../../services/support/fake_hub.dart' show hfToken;
import '../../support/harness.dart';
import '../models/support/models_rig.dart';
import 'onboarding_on_device_test.dart' show settleUntil;

Future<void> _toOnDeviceStep(WidgetTester tester) async {
  await tapText(tester, 'Get started');
  await tapText(tester, 'Run a model on this phone');
  await settleUntil(tester, () => find.text('Finding a model that fits this phone…').evaluate().isEmpty, what: 'the pick');
}

/// The fixture catalog behind a switchable rate limit, counting detail
/// requests (a page reloaded after sign-in asks again).
final class _HubCatalog implements ModelCatalog {
  _HubCatalog(this._inner);

  final ModelCatalog _inner;
  bool rateLimited = false;
  int detailRequests = 0;

  @override
  String get id => _inner.id;

  @override
  Future<HubPage<CatalogEntry>> search(ModelSearchQuery query, {String? cursor}) async {
    if (rateLimited) throw HubRateLimitedException('Too Many Requests', statusCode: 429, retryAfter: const Duration(seconds: 30));
    return _inner.search(query, cursor: cursor);
  }

  @override
  Future<CatalogModelDetails> details(String modelId, {String? revision}) {
    detailRequests++;
    return _inner.details(modelId, revision: revision);
  }

  @override
  Future<List<CatalogFile>> files(String modelId, {required String revision}) => _inner.files(modelId, revision: revision);
}

/// Signs in on the Hugging Face account screen with the fake Hub's token.
Future<void> _signIn(WidgetTester tester) async {
  await tester.enterText(fieldLabeled('Access token'), hfToken);
  await tester.runAsync(() async {
    await tester.tap(find.text('Verify and save'));
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });
  await tester.pumpAndSettle();
  expect(find.text('Sherpa Tester'), findsOneWidget);
}

void main() {
  testWidgets('onboarding can search Hugging Face: a model picked there downloads and the first chat opens on it',
      (tester) async {
    final rig = await ModelsRig.create(tester, onboarded: false, details: <String, CatalogModelDetails>{});
    rig.catalog.detailsById[llama1b] = fixtureDetails(llama1b, [for (final f in rig.hub.files.values) f.listing]);
    await rig.pump(tester);
    await _toOnDeviceStep(tester);

    await tapText(tester, 'Choose another model from Hugging Face');
    expect(find.text('Browse models'), findsOneWidget, reason: 'the Hub browser, over onboarding');
    expect(find.byTooltip('Downloads'), findsNothing, reason: 'onboarding shows the download itself');
    await tester.enterText(find.byType(TextField).first, 'llama-3.2');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Llama 3.2').first);
    await settleUntil(tester, () => find.textContaining(RegExp(r'^Download Q')).evaluate().isNotEmpty,
        what: "the model page's Download button");
    await tester.tap(find.textContaining(RegExp(r'^Download Q')));

    // Back on onboarding, following that download, then into the chat.
    await settleUntil(tester, () => rig.app.prefs.onboardingComplete, what: 'onboarding done');
    await settleUntil(tester, () => find.textContaining('chat:').evaluate().isNotEmpty, what: 'the chat');
    final model = rig.library.models.single;
    expect(model.repo, llama1b);
    final session = (await rig.app.store.listSessions()).single;
    expect((session.providerId, session.modelId), (localProviderId, model.id));
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('when no starter model can be picked, browsing Hugging Face is the way forward', (tester) async {
    final rig = await ModelsRig.create(tester, onboarded: false, details: <String, CatalogModelDetails>{});
    await rig.pump(tester);
    await _toOnDeviceStep(tester);
    expect(find.textContaining("Couldn't pick a model"), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Choose a model from Hugging Face'), findsOneWidget);
    await tapText(tester, 'Choose a model from Hugging Face');
    expect(find.text('Browse models'), findsOneWidget);
    // Back returns to onboarding.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Run a model on this phone'), findsOneWidget);
  });

  testWidgets("onboarding: Browse's Sign in opens the account screen over the list, which reloads on the way back",
      (tester) async {
    final rig = await ModelsRig.create(tester, onboarded: false, details: <String, CatalogModelDetails>{});
    final catalog = _HubCatalog(rig.catalog)..rateLimited = true;
    rig.catalogOverride = catalog;
    await rig.pump(tester);
    await _toOnDeviceStep(tester);
    await tapText(tester, 'Choose a model from Hugging Face');
    expect(find.text('Hugging Face needs a breather'), findsOneWidget);

    await tapText(tester, 'Sign in');
    expect(find.byType(HuggingFaceAccountScreen), findsOneWidget,
        reason: "the account screen on top: the app's routes lead back to onboarding until it ends");
    await _signIn(tester);
    catalog.rateLimited = false;

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Browse models'), findsOneWidget, reason: 'back on the same list');
    expect(find.text('Hugging Face needs a breather'), findsNothing, reason: 'reloaded with the token');
    expect(find.textContaining('Llama 3.2'), findsWidgets);
    expect(rig.app.prefs.onboardingComplete, isFalse);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Run a model on this phone'), findsOneWidget);
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets("onboarding: a gated model's Add token opens the account screen over its page, which reloads with the token",
      (tester) async {
    final rig = await ModelsRig.create(tester, onboarded: false, details: <String, CatalogModelDetails>{});
    rig.catalog.detailsById[llama1b] = fixtureDetails(llama1b, llama1bFiles, gating: HubGating.auto);
    final catalog = _HubCatalog(rig.catalog);
    rig.catalogOverride = catalog;
    await rig.pump(tester);
    await _toOnDeviceStep(tester);
    // "Choose a model…" or "Choose another model…", whether or not the
    // starter pick took the gated repo.
    final browse = find.textContaining(RegExp(r'^Choose (a|another) model from Hugging Face$'));
    await tester.ensureVisible(browse);
    await tester.tap(browse);
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Llama 3.2').first);
    await settleUntil(tester, () => find.text('Add token').evaluate().isNotEmpty, what: "the gated model's page");
    final requests = catalog.detailRequests;
    final peeks = rig.shapes.peeked.length;

    await tapText(tester, 'Add token');
    expect(find.byType(HuggingFaceAccountScreen), findsOneWidget,
        reason: "the account screen on top: the app's routes lead back to onboarding until it ends");
    await _signIn(tester);

    await tester.binding.handlePopRoute();
    await settleUntil(tester, () => find.textContaining('Sherpa uses your token (sherpa-tester)').evaluate().isNotEmpty,
        what: 'the page with the token');
    expect(find.byWidgetPredicate((w) => w is ModelDetailScreen && w.repoId == llama1b), findsOneWidget,
        reason: 'back on the same page');
    expect(find.text('Add token'), findsNothing);
    expect(catalog.detailRequests, greaterThan(requests), reason: 'the details were asked for again');
    expect(rig.shapes.peeked.length, greaterThan(peeks), reason: 'the header peek ran again (it was behind the gate)');
    expect(rig.app.prefs.onboardingComplete, isFalse);
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('onboarding shows the download\'s notice beside the Wi-Fi action', (tester) async {
    const notice = 'This Wi-Fi is metered, so the download waits for another network.';
    final rig = await ModelsRig.create(tester, onboarded: false, details: <String, CatalogModelDetails>{}, network: NetworkKind.cellular);
    rig.catalog.detailsById[llama1b] = fixtureDetails(llama1b, [for (final f in rig.hub.files.values) f.listing]);
    rig.mapJobs = (jobs) => [
          for (final v in jobs)
            DownloadJobView(job: v.job.copyWith(notice: notice), phase: v.phase, bytesDone: v.bytesDone, wifiOnly: v.wifiOnly),
        ];
    await rig.pump(tester);
    await _toOnDeviceStep(tester);
    await tester.tap(find.textContaining('and start'));
    await settleUntil(tester, () => find.text('Use mobile data for this download').evaluate().isNotEmpty,
        what: 'the job waiting for Wi-Fi');
    expect(find.textContaining('Waiting for Wi-Fi'), findsOneWidget);
    expect(find.text(notice), findsOneWidget);
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('a download service that fails to start says why, is recorded, and the next tap retries it',
      (tester) async {
    final ring = AppErrorRing();
    final rig = await ModelsRig.create(tester, onboarded: false, details: <String, CatalogModelDetails>{});
    rig.catalog.detailsById[llama1b] = fixtureDetails(llama1b, [for (final f in rig.hub.files.values) f.listing]);
    var builds = 0;
    rig.managerOverride = downloadManagerProvider.overrideWith((ref) {
      if (builds++ == 0) throw StateError('Stream has already been listened to.');
      return rig.manager;
    });
    setWindow(tester, phone);
    await tester.pumpWidget(ProviderScope(
      overrides: [...rig.overrides, appErrorRingProvider.overrideWithValue(ring)],
      retry: noRetry,
      observers: [AppErrorObserver(ring: ring)],
      child: const SherpaApp(),
    ));
    await tester.pumpAndSettle();
    await _toOnDeviceStep(tester);

    await tester.tap(find.textContaining('and start'));
    await settleUntil(tester, () => find.textContaining("download service didn't start").evaluate().isNotEmpty,
        what: 'the reason');
    expect(find.textContaining("The download couldn't start"), findsNothing, reason: 'never the bare message');
    expect(find.textContaining('StateError'), findsOneWidget, reason: 'what failed, for a bug report');
    expect(find.widgetWithText(FilledButton, 'Choose a model from Hugging Face'), findsOneWidget);
    final records = [for (final r in ring.records) r.toJson()];
    expect(records, contains(allOf(containsPair('source', 'provider'), containsPair('code', 'downloadManagerProvider'))));
    expect(records, contains(allOf(containsPair('source', 'onboarding'), containsPair('code', 'download_manager'))));

    // The provider was rebuilt: the next tap downloads.
    await tester.tap(find.textContaining('and start'));
    await settleUntil(tester, () => rig.app.prefs.onboardingComplete, what: 'onboarding done');
    expect(rig.library.models, hasLength(1));
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('a model page and Downloads explain a failed download service instead of showing an error box',
      (tester) async {
    final rig = await ModelsRig.create(tester);
    var builds = 0;
    rig.managerOverride = downloadManagerProvider.overrideWith((ref) {
      if (builds++ == 0) throw StateError('broken');
      return rig.manager;
    });
    await rig.pump(tester, location: '/settings/models/downloads');
    expect(find.text("Downloads aren't available"), findsOneWidget);
    expect(find.byType(ErrorWidget), findsNothing);

    await goTo(tester, '/settings/models/browse/bartowski/Llama-3.2-1B-Instruct-GGUF');
    await settleUntil(tester, () => find.textContaining(RegExp(r'^Download Q|Try again')).evaluate().isNotEmpty,
        what: 'the download bar');
    expect(find.byType(ErrorWidget), findsNothing);
    await tester.tap(find.text('Try again'));
    await settleUntil(tester, () => find.textContaining(RegExp(r'^Download Q')).evaluate().isNotEmpty,
        what: 'the Download button after retrying');
    expect(rig.manager.jobs, isEmpty);
    expect(find.byType(ErrorWidget), findsNothing);
    expect(builds, 2);
    expect(rig.manager, isA<DownloadManager>());
  }, timeout: const Timeout(Duration(minutes: 2)));
}
