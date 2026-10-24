import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa/app.dart';
import 'package:sherpa/features/models/hf_account_screen.dart';
import 'package:sherpa/features/models/model_detail_screen.dart';
import 'package:sherpa/features/models/model_library_screen.dart';
import 'package:sherpa/features/models/state/hub_account.dart';
import 'package:sherpa/features/models/state/local_model_choice.dart';
import 'package:sherpa/features/models/widgets/model_card.dart';
import 'package:sherpa/routing/router.dart' show routerProvider;
import 'package:sherpa/routing/routes.dart';
import 'package:sherpa/services/downloads/downloads.dart';
import 'package:sherpa_data/sherpa_data.dart';
import 'package:sherpa_hub/sherpa_hub.dart';

import '../../services/support/fake_hub.dart' show hfToken;
import '../../services/support/gguf_fixture.dart';
import '../../support/harness.dart';
import 'support/models_rig.dart';
import 'support/sample_jobs.dart';

const iphone8 = DeviceProfile(platform: DevicePlatform.ios, totalRamBytes: 8 * gib, freeStorageBytes: 80 * gib);

/// The app's router.
GoRouter routerOf(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(SherpaApp))).read(routerProvider);

Finder cardFor(String id) => find.byWidgetPredicate((w) => w is ModelCard && w.entry.id == id);

Finder variantRow(String label) => find.ancestor(of: find.text(label), matching: find.byType(InkWell)).first;

/// Scrolls the horizontal filter row until [f] is built and visible.
Future<void> revealChip(WidgetTester tester, Finder f) async {
  final row = find.ancestor(of: find.widgetWithText(ChoiceChip, 'GGUF'), matching: find.byType(Scrollable)).first;
  await tester.scrollUntilVisible(f, 120, scrollable: row);
  await tester.pumpAndSettle();
}

/// Polls [test] in real time (inside `runAsync`), failing after [timeout].
Future<void> until(bool Function() test, {Duration timeout = const Duration(seconds: 10), String? what}) async {
  final deadline = DateTime.now().add(timeout);
  while (!test()) {
    if (DateTime.now().isAfter(deadline)) throw TimeoutException('timed out waiting for ${what ?? 'condition'}');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<void> scrollTo(WidgetTester tester, Finder f) async {
  await tester.scrollUntilVisible(f, 200, scrollable: find.byType(Scrollable).first);
  await tester.pumpAndSettle();
}

void main() {
  group('directory', () {
    testWidgets('lists GGUF results, hides uncensored fine-tunes until asked, and says how many', (tester) async {
      final rig = await ModelsRig.create(tester);
      await rig.pump(tester, location: Routes.modelBrowse);

      expect(find.text('Browse models'), findsOneWidget);
      expect(cardFor(llama1b), findsOneWidget);
      expect(cardFor('unsloth/Qwen3-8B-GGUF'), findsOneWidget);
      expect(cardFor('mlx-community/Qwen3-8B-4bit'), findsNothing, reason: 'GGUF is the default format');
      expect(cardFor('mradermacher/Llama-3.3-70B-Instruct-abliterated-GGUF'), findsNothing);
      expect(find.text('1 uncensored fine-tune hidden'), findsOneWidget);

      await tester.tap(find.text('Show'));
      await tester.pumpAndSettle();
      expect(find.text('Showing uncensored fine-tunes'), findsOneWidget);
      await scrollTo(tester, cardFor('mradermacher/Llama-3.3-70B-Instruct-abliterated-GGUF'));
      expect(cardFor('mradermacher/Llama-3.3-70B-Instruct-abliterated-GGUF'), findsOneWidget);
      final prefs = await rig.store.get(DocumentCollections.preferences, ModelPreferenceIds.models);
      expect(prefs?['showUncensored'], isTrue, reason: 'the choice persists');
    });

    testWidgets('search is debounced and filters by text', (tester) async {
      final rig = await ModelsRig.create(tester);
      await rig.pump(tester, location: Routes.modelBrowse);

      await tester.enterText(find.byType(TextField).first, 'qwen');
      await tester.pump(const Duration(milliseconds: 100));
      expect(cardFor(llama1b), findsOneWidget, reason: 'still debouncing');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(cardFor(llama1b), findsNothing);
      expect(cardFor('unsloth/Qwen3-8B-GGUF'), findsOneWidget);

      await tester.enterText(find.byType(TextField).first, 'no-such-model');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('No models match'), findsOneWidget);
    });

    testWidgets('format and trusted-quantizer chips narrow the results', (tester) async {
      final rig = await ModelsRig.create(tester, device: iphone8);
      await rig.pump(tester, location: Routes.modelBrowse);

      await tester.tap(find.widgetWithText(ChoiceChip, 'MLX'));
      await tester.pumpAndSettle();
      expect(cardFor('mlx-community/Qwen3-8B-4bit'), findsOneWidget);
      expect(cardFor(llama1b), findsNothing);

      await tester.tap(find.widgetWithText(ChoiceChip, 'GGUF'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilterChip, 'bartowski'));
      await tester.pumpAndSettle();
      expect(cardFor(llama1b), findsOneWidget);
      expect(cardFor('unsloth/Qwen3-8B-GGUF'), findsNothing);
    });

    testWidgets('only the formats this device runs are offered: LiteRT on Android, MLX on iPhone', (tester) async {
      Iterable<String> chips() => tester.widgetList<ChoiceChip>(find.byType(ChoiceChip)).map((c) => (c.label as Text).data!);

      final android = await ModelsRig.create(tester);
      await android.pump(tester, location: Routes.modelBrowse);
      expect(chips(), ['GGUF', 'LiteRT']);

      final iphone = await ModelsRig.create(tester, device: iphone8);
      await iphone.pump(tester, location: Routes.modelBrowse);
      expect(chips(), ['GGUF', 'MLX']);
    });

    testWidgets('size and tool-use filters apply on the client', (tester) async {
      final rig = await ModelsRig.create(tester);
      await rig.pump(tester, location: Routes.modelBrowse);

      await tester.tap(find.widgetWithText(FilterChip, 'Size'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Under 2B').last);
      await tester.pumpAndSettle();
      expect(cardFor(llama1b), findsOneWidget);
      expect(cardFor('ggml-org/gemma-3-270m-it-GGUF'), findsOneWidget);
      expect(cardFor('unsloth/Qwen3-8B-GGUF'), findsNothing);

      await revealChip(tester, find.widgetWithText(FilterChip, 'Tool use'));
      await tester.tap(find.widgetWithText(FilterChip, 'Tool use'));
      await tester.pumpAndSettle();
      expect(cardFor(llama1b), findsOneWidget);
      expect(cardFor('ggml-org/gemma-3-270m-it-GGUF'), findsNothing);
    });

    testWidgets('cards carry decoded name chips and an estimated fit', (tester) async {
      final rig = await ModelsRig.create(tester, device: phone4);
      await rig.pump(tester, location: Routes.modelBrowse);
      final card = find.descendant(of: cardFor('unsloth/Qwen3-8B-GGUF'), matching: find.byType(Text));
      final texts = tester.widgetList<Text>(card).map((t) => t.data).toList();
      expect(texts, containsAll(['Qwen 3', '8B', 'GGUF']));
      expect(texts, contains('Likely too big'), reason: '8B at 4-bit on a 4 GB phone');
    });

    testWidgets('tapping a card opens the detail page', (tester) async {
      final rig = await ModelsRig.create(tester);
      await rig.pump(tester, location: Routes.modelBrowse);
      await tester.tap(cardFor(llama1b));
      await tester.pumpAndSettle();
      expect(find.text(llama1b), findsOneWidget);
      expect(find.text('Q4_K_M'), findsWidgets);
    });
  });

  group('detail', () {
    testWidgets('fit badges on a 12 GB phone: everything fits, Q8_0 recommended', (tester) async {
      final rig = await ModelsRig.create(tester, device: phone12);
      await rig.pump(tester, location: Routes.modelDetail(llama1b));
      expect(rig.shapes.peeked, ['Llama-3.2-1B-Instruct-Q4_K_M.gguf'], reason: 'one header peek sizes every quant');

      for (final q in ['F16', 'Q8_0', 'Q4_K_M', 'Q2_K']) {
        expect(find.descendant(of: variantRow(q), matching: find.text('Fits')), findsOneWidget, reason: q);
      }
      expect(find.descendant(of: variantRow('Q8_0'), matching: find.text('Recommended')), findsOneWidget);
      expect(find.text('5.2 bits/weight'), findsOneWidget, reason: 'Q4_K_M measured: bytes × 8 ÷ params');
      expect(find.textContaining('Download Q8_0'), findsOneWidget, reason: 'the recommended variant is preselected');
      await scrollTo(tester, find.text('Q4_0_4_4'));
      expect(find.descendant(of: find.ancestor(of: find.text('Q4_0_4_4'), matching: find.byType(Opacity)), matching: find.text('Unavailable')),
          findsOneWidget);
    });

    testWidgets("4 GB phone: Q8_0 won't fit and can't be downloaded; Q4_K_M is tight", (tester) async {
      final rig = await ModelsRig.create(tester, device: phone4);
      await rig.pump(tester, location: Routes.modelDetail(llama1b));

      expect(find.descendant(of: variantRow('Q8_0'), matching: find.text("Won't fit")), findsOneWidget);
      expect(find.descendant(of: variantRow('F16'), matching: find.text("Won't fit")), findsOneWidget);
      expect(find.descendant(of: variantRow('Q4_K_M'), matching: find.text('Tight')), findsOneWidget);
      expect(find.descendant(of: variantRow('Q2_K'), matching: find.text('Fits')), findsOneWidget);
      expect(find.descendant(of: variantRow('Q2_K'), matching: find.text('Recommended')), findsOneWidget);

      await tester.tap(variantRow('Q8_0'));
      await tester.pumpAndSettle();
      final button = tester.widget<FilledButton>(find.ancestor(of: find.textContaining('Download Q8_0'), matching: find.byType(FilledButton)));
      expect(button.onPressed, isNull, reason: "Won't fit is never downloadable");
      expect(find.textContaining("Won't fit on this device: Needs about"), findsOneWidget);
    });

    testWidgets('Tight asks first; "Download anyway" queues the pinned plan', (tester) async {
      final rig = await ModelsRig.create(tester, device: phone4);
      await rig.pump(tester, location: Routes.modelDetail(llama1b));

      await tester.tap(variantRow('Q4_K_M'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Download Q4_K_M'));
      await tester.pumpAndSettle();
      expect(find.text('Memory will be tight'), findsOneWidget);
      expect(find.textContaining('KV cache'), findsWidgets, reason: 'the breakdown explains the number');

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(rig.manager.jobs, isEmpty);

      await tester.tap(find.textContaining('Download Q4_K_M'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Download anyway'));
      await tester.pumpAndSettle();
      final job = rig.manager.jobs.single.job;
      expect(job.repo, llama1b);
      expect(job.commit, fixtureCommit);
      expect(job.label, 'Q4_K_M');
      expect(job.meta.recommendedContext, isNotNull);
      expect(find.textContaining('Downloading'), findsWidgets);
    });

    testWidgets('gated repo explains the steps and offers the token screen', (tester) async {
      final rig = await ModelsRig.create(
        tester,
        details: {llama1b: fixtureDetails(llama1b, llama1bFiles, gating: HubGating.manual)},
      );
      await rig.pump(tester, location: Routes.modelDetail(llama1b));
      expect(find.text('Accept the terms on huggingface.co'), findsOneWidget);
      expect(find.textContaining('approves requests by hand'), findsOneWidget);
      expect(find.text('https://huggingface.co/$llama1b'), findsOneWidget);
      await tester.tap(find.text('Add token'));
      await tester.pumpAndSettle();
      expect(find.byType(HuggingFaceAccountScreen), findsOneWidget);
    });

    testWidgets("a Transformers repo on Android says what runs here, plainly, and finds the repo's GGUF versions over it",
        (tester) async {
      final rig = await ModelsRig.create(tester, details: {
        llama1b: fixtureDetails(llama1b, llama1bFiles),
        llamaBase: fixtureDetails(llamaBase, llamaBaseFiles),
      });
      await rig.pump(tester, location: Routes.modelBrowse);
      await tester.enterText(find.byType(TextField).first, llamaBase);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open $llamaBase'));
      await tester.pumpAndSettle();

      expect(
          find.text('Nothing in this repository runs on Android. Sherpa on Android runs GGUF and LiteRT-LM models. '
              'Look for a GGUF version of this model.'),
          findsOneWidget);
      expect(find.textContaining('Look for a GGUF version'), findsOneWidget, reason: 'said once, in the summary');
      final scheme = Theme.of(tester.element(find.byType(ModelDetailScreen))).colorScheme;
      expect(tester.widget<Text>(find.text("Sherpa can't run Transformers weights (safetensors).")).style?.color,
          scheme.onSurfaceVariant,
          reason: 'a fact about the format, not an error');
      expect(find.text("Can't run here"), findsOneWidget);
      expect(find.text('Unavailable'), findsNothing);
      expect(find.textContaining('MLX'), findsNothing);
      expect(find.textContaining(RegExp(r'^Download ')), findsNothing, reason: 'no button that can never be pressed');

      await tester.tap(find.text('Find GGUF versions'));
      await tester.pumpAndSettle();
      expect(find.text('Quantized from $llamaBase'), findsOneWidget, reason: 'the filter is on screen');
      expect(tester.widget<TextField>(find.byType(TextField).first).controller!.text, isEmpty,
          reason: 'a list of its own, not the search typed under it');
      expect(cardFor(llama1b), findsOneWidget);
      expect(cardFor('unsloth/Qwen3-8B-GGUF'), findsNothing);

      // A version's page and back: the versions; back again: the page that
      // asked for them, then the search typed before it.
      await tester.tap(cardFor(llama1b));
      await tester.pumpAndSettle();
      expect(find.byWidgetPredicate((w) => w is ModelDetailScreen && w.repoId == llama1b), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Quantized from $llamaBase'), findsOneWidget);
      expect(cardFor('unsloth/Qwen3-8B-GGUF'), findsNothing);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byWidgetPredicate((w) => w is ModelDetailScreen && w.repoId == llamaBase), findsOneWidget);
      expect(find.text('Quantized from $llamaBase'), findsNothing);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Open $llamaBase'), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField).first).controller!.text, llamaBase);
    });

    testWidgets('on an iPhone the page finds GGUF or MLX versions, as its summary says', (tester) async {
      final rig = await ModelsRig.create(tester, device: iphone8, details: {llamaBase: fixtureDetails(llamaBase, llamaBaseFiles)});
      await rig.pump(tester, location: Routes.modelDetail(llamaBase));
      expect(find.textContaining('Look for a GGUF or MLX version of this model.'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Find GGUF versions'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Find MLX versions'), findsOneWidget);

      await tester.tap(find.text('Find MLX versions'));
      await tester.pumpAndSettle();
      expect(find.text('Quantized from $llamaBase'), findsOneWidget);
      expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'MLX')).selected, isTrue);
      expect(find.text('Hugging Face lists no MLX versions of $llamaBase yet.'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Find MLX versions'), findsOneWidget, reason: 'back on the page that asked');
    });

    testWidgets('a repo nobody has made a GGUF of: the versions list says so and offers every model', (tester) async {
      const repo = 'acme/Brand-New-1B';
      final rig = await ModelsRig.create(tester, details: {repo: fixtureDetails(repo, llamaBaseFiles)});
      await rig.pump(tester, location: Routes.modelDetail(repo));
      await tester.tap(find.text('Find GGUF versions'));
      await tester.pumpAndSettle();

      expect(find.text('No versions found'), findsOneWidget);
      expect(find.text('Hugging Face lists no GGUF versions of $repo yet.'), findsOneWidget);
      expect(find.byTooltip('Hugging Face repos tagged as quantized from $repo. Some may be fine-tunes of it.'),
          findsOneWidget);

      // With a filter on, fewer filters come first; every model stays an option.
      await tester.tap(find.widgetWithText(FilterChip, 'Size'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Under 2B').last);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(FilledButton, 'Clear filters'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Show all models'), findsNWidgets(2), reason: 'the versions row and the empty state');
      await tester.tap(find.widgetWithText(FilledButton, 'Clear filters'));
      await tester.pumpAndSettle();
      expect(find.text('No versions found'), findsOneWidget, reason: 'still the versions of $repo');

      await tester.tap(find.widgetWithText(FilledButton, 'Show all models'));
      await tester.pumpAndSettle();
      expect(find.text('No versions found'), findsNothing);
      expect(cardFor(llama1b), findsOneWidget);
    });

    testWidgets("the route swapping Browse's list for a repo's versions swaps the search box too", (tester) async {
      final rig = await ModelsRig.create(tester);
      await rig.pump(tester, location: Routes.modelBrowse);
      await tester.enterText(find.byType(TextField).first, 'qwen');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      routerOf(tester).go(Routes.modelBrowseVersionsOf(llamaBase));
      await tester.pumpAndSettle();
      expect(find.text('Quantized from $llamaBase'), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField).first).controller!.text, isEmpty);
      expect(cardFor(llama1b), findsOneWidget);
    });

    testWidgets('unreadable header: fit unknown, download asks first', (tester) async {
      final rig = await ModelsRig.create(tester, shapes: const {});
      await rig.pump(tester, location: Routes.modelDetail(llama1b));
      expect(find.text('Fit unknown'), findsWidgets);
      await tester.tap(find.textContaining('Download '));
      await tester.pumpAndSettle();
      expect(find.text("Fit couldn't be checked"), findsOneWidget);
    });
  });

  group('downloads', () {
    testWidgets('progress, pause and resume drive the real manager', (tester) async {
      final rig = await ModelsRig.create(tester);
      await rig.pump(tester, location: Routes.downloads);
      expect(find.text('No downloads'), findsOneWidget);

      final gate = Completer<void>();
      rig.backend.gate = gate;
      await tester.runAsync(() async {
        final plan = planDownload(
          repo: rig.hub.repo,
          commit: rig.hub.commit,
          files: [for (final f in rig.hub.files.values) f.listing],
          quant: 'Q4_K_M',
        ) as DownloadPlan;
        await rig.manager.enqueue(plan, meta: const DownloadMeta(displayName: 'Llama 3.2 1B', quant: 'Q4_K_M'));
        await until(() => rig.manager.jobs.isNotEmpty && rig.manager.jobs.single.phase == JobPhase.downloading, what: 'downloading');
      });
      await tester.pumpAndSettle();
      expect(find.text('In progress'), findsOneWidget);
      expect(find.text('Llama 3.2 1B'), findsOneWidget);
      expect(find.textContaining('Downloading'), findsOneWidget);

      await tester.runAsync(() async {
        await tester.tap(find.byTooltip('Pause'));
        gate.complete();
        await until(() => rig.manager.jobs.isNotEmpty && rig.manager.jobs.single.phase == JobPhase.paused, what: 'paused');
      });
      await tester.pumpAndSettle();
      expect(find.text('Paused'), findsOneWidget);
      expect(find.text('Paused. Progress is kept'), findsOneWidget);

      rig.backend.gate = null;
      await tester.runAsync(() async {
        await tester.tap(find.byTooltip('Resume'));
        await until(() => rig.manager.jobs.isNotEmpty && rig.manager.jobs.single.phase == JobPhase.done, what: 'done');
      });
      await tester.pumpAndSettle();
      expect(find.text('Verified'), findsOneWidget);
      expect(find.text('Verified and ready to use'), findsOneWidget);
    });

    testWidgets('numbers have their units and the Wi-Fi toggle persists', (tester) async {
      final rig = await ModelsRig.create(tester);
      rig.staticJobs = sampleJobs();
      await rig.pump(tester, location: Routes.downloads);
      expect(find.text('1.2 of 2.3 GB'), findsOneWidget);
      expect(find.text('3.0 MB/s'), findsOneWidget);
      expect(find.text('6 min left'), findsOneWidget);
      expect(find.text('Waiting for Wi-Fi'), findsOneWidget);
      expect(find.textContaining('Use mobile data for this one'), findsOneWidget);
      expect(find.textContaining("didn't match its SHA-256"), findsOneWidget);

      await tester.runAsync(() async {
        await tester.tap(find.text('Download over Wi-Fi only'));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pumpAndSettle();
      expect(rig.manager.wifiOnly, isFalse);
      final prefs = await rig.store.get(DocumentCollections.preferences, ModelPreferenceIds.models);
      expect(prefs?['wifiOnly'], isFalse);
    });
  });

  group('library', () {
    testWidgets('delete asks, removes the model and frees its files', (tester) async {
      final rig = await ModelsRig.create(tester);
      final model = await tester.runAsync(() async {
        final rel = 'acme__tiny@067b946cf014/tiny.gguf';
        final f = File(rig.manager.layout.libraryPath(rel));
        await f.parent.create(recursive: true);
        await f.writeAsBytes(fillBytes(4096));
        return rig.library.add(LibraryModel(
          id: 'model_1',
          source: LibrarySource.hub,
          displayName: 'Tiny 1B',
          format: ModelFormat.gguf,
          files: [LibraryFile(path: rel, role: FileRole.model, sizeBytes: 4096)],
          loadPath: rel,
          installedAt: DateTime.utc(2026, 10, 1),
          repo: 'acme/Tiny-1B-GGUF',
          quant: 'Q4_K_M',
          defaultContextLength: 8192,
        ));
      });
      await rig.pump(tester, location: Routes.models);
      expect(find.text('Tiny 1B'), findsOneWidget);
      expect(find.text('Q4_K_M'), findsOneWidget);
      expect(find.text('8K context'), findsOneWidget);

      await tester.tap(find.text('Use in chat'));
      await tester.pumpAndSettle();
      expect(rig.usedInChat.single.providerId, localProviderId);
      expect(rig.usedInChat.single.modelId, 'model_1');

      await tester.tap(find.byTooltip('Delete Tiny 1B'));
      await tester.pumpAndSettle();
      expect(find.text('Delete Tiny 1B?'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.text('Delete'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(find.text('Tiny 1B'), findsNothing);
      expect(find.text('No on-device models yet'), findsOneWidget);
      expect(await rig.store.get(DocumentCollections.modelLibrary, model!.id), isNull);
      expect(File(rig.manager.layout.libraryPath(model.loadPath)).existsSync(), isFalse);
    });

    testWidgets('"Add a model file…" refuses a pickle with the reason, imports a GGUF', (tester) async {
      final rig = await ModelsRig.create(tester);
      await rig.pump(tester, location: Routes.models);
      rig.pickedFile = await tester.runAsync(() async {
        final f = File('${rig.dir.path}/pytorch_model.bin');
        await f.writeAsBytes([0x80, 0x02, 0x63]);
        return PathModelFile(f);
      });
      await tester.runAsync(() async {
        await tester.tap(find.text('Add a model file…'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(find.text("Couldn't add this file"), findsOneWidget);
      expect(find.textContaining('pickle-based format'), findsOneWidget);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(rig.library.models, isEmpty);

      // A successful import is covered by the library unit tests (real file
      // IO can't run under the widget-test clock); here: the list shows it.
      await tester.runAsync(() async {
        final f = File('${rig.dir.path}/Tiny-Q4_K_M.gguf');
        await f.writeAsBytes(syntheticGguf(totalBytes: 256 << 10));
        final o = await rig.library.importFile(PathModelFile(f), freeStorageBytes: 1 << 30);
        expect(o, isA<Imported>());
      });
      await tester.pumpAndSettle();
      expect(find.text('Tiny Llama Test'), findsOneWidget);
      expect(find.text('Imported'), findsOneWidget);
    });
  });

  group('settings', () {
    testWidgets('settings has the two new entries', (tester) async {
      final rig = await ModelsRig.create(tester);
      await rig.pump(tester, location: Routes.settings);
      expect(find.text('Models & downloads'), findsOneWidget);
      expect(find.text('Hugging Face account'), findsOneWidget);
      await tester.tap(find.text('Models & downloads'));
      await tester.pumpAndSettle();
      expect(find.byType(ModelLibraryScreen), findsOneWidget);
    });

    testWidgets('Hugging Face token: rejected token shows why; a good one is verified and stored', (tester) async {
      final rig = await ModelsRig.create(tester);
      await rig.pump(tester, location: Routes.huggingFace);

      await tester.enterText(fieldLabeled('Access token'), 'hf_wrongwrongwrongwrongwrong');
      await tester.runAsync(() async {
        await tester.tap(find.text('Verify and save'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(find.textContaining('rejected this token'), findsOneWidget);
      expect(await rig.app.secrets.read(HubAccount.tokenKey), isNull);

      await tester.enterText(fieldLabeled('Access token'), hfToken);
      await tester.runAsync(() async {
        await tester.tap(find.text('Verify and save'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(find.text('Sherpa Tester'), findsOneWidget);
      expect(find.textContaining('@sherpa-tester'), findsOneWidget);
      expect(await rig.app.secrets.read(HubAccount.tokenKey), hfToken);
      final profile = await rig.store.get(DocumentCollections.preferences, ModelPreferenceIds.hubAccount);
      expect(profile.toString(), isNot(contains(hfToken)), reason: 'the database never holds the token');

      await tester.tap(find.text('Sign out').first);
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(TextButton, 'Sign out'));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pumpAndSettle();
      expect(await rig.app.secrets.read(HubAccount.tokenKey), isNull);
      expect(find.text('Verify and save'), findsOneWidget);
    });
  });
}
