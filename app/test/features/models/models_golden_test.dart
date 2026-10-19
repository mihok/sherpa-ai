@Tags(['golden'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa/routing/routes.dart';

import '../../support/golden_fonts.dart';
import 'support/models_rig.dart';
import 'support/sample_jobs.dart';

/// Pixel goldens for the model screens at phone size, light and dark.
///
/// Same rules as test/goldens: software Skia with Roboto + Material Icons
/// from the pinned SDK, stable only on the pinned Linux image. Regenerate
/// with `flutter test --tags golden --update-goldens test/features/models`.
void main() {
  final skip = !goldenFontsLoaded;

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    final name = mode.name;

    testWidgets('directory $name', (tester) async {
      final rig = await ModelsRig.create(tester, mode: mode, device: phone12);
      await rig.pump(tester, location: Routes.modelBrowse);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/model_directory_$name.png'));
    }, skip: skip);

    testWidgets('detail $name', (tester) async {
      final rig = await ModelsRig.create(tester, mode: mode, device: phone4);
      await rig.pump(tester, location: Routes.modelDetail(llama1b));
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/model_detail_$name.png'));
    }, skip: skip);

    testWidgets('downloads $name', (tester) async {
      final rig = await ModelsRig.create(tester, mode: mode);
      rig.staticJobs = sampleJobs();
      await rig.pump(tester, location: Routes.downloads);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/model_downloads_$name.png'));
    }, skip: skip);
  }
}
