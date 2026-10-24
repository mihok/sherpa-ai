import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa/features/models/model_directory_screen.dart';
import 'package:sherpa/routing/routes.dart';
import 'package:sherpa/services/downloads/downloads.dart';
import 'package:sherpa_hub/sherpa_hub.dart';

import '../features/models/support/models_rig.dart';
import '../features/models/support/sample_jobs.dart';
import '../services/support/fake_hub.dart' show hfToken;
import '../support/a11y_audit.dart';
import '../support/harness.dart';

// textContrastGuideline misreads, at 1× only: the 12 px note under "Files"
// samples the variant tiles' surface below it, and the account page's
// 12 px helper text samples anti-aliasing. The exact check still runs.
const _oneX = {AuditView.phone1x, AuditView.tablet1x};
const _note = '12 px text whose sampled box holds more of a neighbouring surface (or anti-aliasing) than glyph';

/// M6 audit of the on-device model screens: library, Hugging Face browser,
/// a repo's detail, downloads and the account (see [auditScreen]).
void main() {
  Future<ModelsRig> rigAt(
    WidgetTester tester,
    AuditView view,
    String location, {
    DeviceProfile device = phone12,
    Map<String, CatalogModelDetails>? details,
    List<DownloadJobView>? jobs,
    bool installed = false,
  }) async {
    final rig = await ModelsRig.create(tester, mode: view.themeMode, device: device, details: details);
    if (jobs != null) rig.staticJobs = jobs;
    if (installed) await _installTwo(tester, rig);
    await rig.pump(tester, size: view.size, textScale: view.textScale, location: location);
    return rig;
  }

  auditScreen('library, empty', (tester, view) async => rigAt(tester, view, Routes.models));
  auditScreen('library with models', (tester, view) async => rigAt(tester, view, Routes.models, installed: true));
  auditScreen('delete model dialog', (tester, view) async {
    await rigAt(tester, view, Routes.models, installed: true);
    await tester.tap(find.byTooltip('Delete Tiny 1B'));
    await tester.pumpAndSettle();
  });

  auditScreen('browse models', (tester, view) async => rigAt(tester, view, Routes.modelBrowse));
  auditScreen('browse models, nothing matches', (tester, view) async {
    await rigAt(tester, view, Routes.modelBrowse);
    await tester.enterText(find.byType(TextField).first, 'zzzz-no-such-model');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
  });
  auditScreen('trusted quantizers sheet', (tester, view) async {
    await rigAt(tester, view, Routes.modelBrowse);
    // What the "Edit" chip at the end of the quantizer row opens.
    unawaited(showEditQuantizersSheet(tester.element(find.byType(ModelDirectoryScreen))));
    await tester.pumpAndSettle();
  });
  auditScreen('trusted quantizers explained', (tester, view) async {
    await rigAt(tester, view, Routes.modelBrowse);
    await tester.tap(find.byTooltip('About trusted quantizers'));
    await tester.pumpAndSettle();
  });

  auditScreen('model detail', (tester, view) async => rigAt(tester, view, Routes.modelDetail(llama1b)),
      pixelContrastSkip: _oneX, contrastNote: _note);
  auditScreen('model detail, 4 GB phone', (tester, view) async {
    await rigAt(tester, view, Routes.modelDetail(llama1b), device: phone4);
  }, pixelContrastSkip: _oneX, contrastNote: _note);
  auditScreen('model detail, gated', (tester, view) async {
    await rigAt(tester, view, Routes.modelDetail(llama1b),
        details: {llama1b: fixtureDetails(llama1b, llama1bFiles, gating: HubGating.manual)});
  }, pixelContrastSkip: _oneX, contrastNote: _note);
  auditScreen('model detail, nothing runs on this phone', (tester, view) async {
    await rigAt(tester, view, Routes.modelDetail(llamaBase), details: {llamaBase: fixtureDetails(llamaBase, llamaBaseFiles)});
    expect(find.text('Find GGUF versions'), findsOneWidget);
  }, pixelContrastSkip: _oneX, contrastNote: _note);
  auditScreen('model detail, nothing runs on this iPhone: GGUF and MLX versions', (tester, view) async {
    await rigAt(tester, view, Routes.modelDetail(llamaBase),
        device: const DeviceProfile(platform: DevicePlatform.ios, totalRamBytes: 8 * gib, freeStorageBytes: 80 * gib),
        details: {llamaBase: fixtureDetails(llamaBase, llamaBaseFiles)});
    expect(find.text('Find MLX versions'), findsOneWidget);
  }, pixelContrastSkip: _oneX, contrastNote: _note);
  auditScreen("browse, a repo's GGUF versions", (tester, view) async {
    await rigAt(tester, view, Routes.modelBrowseVersionsOf(llamaBase));
    expect(find.text('Quantized from $llamaBase'), findsOneWidget);
  });
  auditScreen('browse, no versions found', (tester, view) async {
    await rigAt(tester, view, Routes.modelBrowseVersionsOf('acme/Brand-New-1B'));
    expect(find.text('No versions found'), findsOneWidget);
  });
  auditScreen('memory will be tight sheet', (tester, view) async {
    await rigAt(tester, view, Routes.modelDetail(llama1b), device: phone4);
    final row = find.widgetWithText(InkWell, 'Q4_K_M');
    await tester.scrollUntilVisible(row, 150, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Download Q4_K_M'));
    await tester.pumpAndSettle();
  });

  auditScreen('downloads', (tester, view) async => rigAt(tester, view, Routes.downloads, jobs: sampleJobs()));
  auditScreen('downloads, empty', (tester, view) async => rigAt(tester, view, Routes.downloads));
  auditScreen('cancel download dialog', (tester, view) async {
    await rigAt(tester, view, Routes.downloads, jobs: sampleJobs());
    await tester.tap(find.byTooltip('Cancel download').first);
    await tester.pumpAndSettle();
  });

  auditScreen('Hugging Face account, signed out', (tester, view) async => rigAt(tester, view, Routes.huggingFace),
      pixelContrastSkip: _oneX, contrastNote: _note);
  auditScreen('Hugging Face account, signed in', (tester, view) async {
    await rigAt(tester, view, Routes.huggingFace);
    final list = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(fieldLabeled('Access token'), 150, scrollable: list);
    await tester.enterText(fieldLabeled('Access token'), hfToken);
    await tester.scrollUntilVisible(find.text('Verify and save'), 150, scrollable: list);
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('Verify and save'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(find.text('Sherpa Tester'), findsOneWidget);
  });
}

/// Two installed models (one imported, with vision), as the library lists them.
Future<void> _installTwo(WidgetTester tester, ModelsRig rig) => tester.runAsync(() async {
      Future<void> add(String id, String name, {String? repo, LibrarySource source = LibrarySource.hub, String? mmproj}) async {
        final rel = '$id/$id.gguf';
        final f = File(rig.manager.layout.libraryPath(rel));
        await f.parent.create(recursive: true);
        await f.writeAsBytes(fillBytes(4096));
        await rig.library.add(LibraryModel(
          id: id,
          source: source,
          displayName: name,
          format: ModelFormat.gguf,
          files: [LibraryFile(path: rel, role: FileRole.model, sizeBytes: 812 << 20)],
          loadPath: rel,
          installedAt: DateTime.utc(2026, 10, 1),
          repo: repo,
          quant: 'Q4_K_M',
          defaultContextLength: 8192,
          toolUse: true,
        ));
      }

      await add('tiny', 'Tiny 1B', repo: 'acme/Tiny-1B-GGUF');
      await add('notes', 'A rather long imported model name for the notes', source: LibrarySource.imported);
    });
