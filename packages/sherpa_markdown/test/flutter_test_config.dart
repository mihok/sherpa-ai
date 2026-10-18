// Test bootstrap discovered by `flutter test` for every test in this
// package.
//
// `flutter test` renders with test fonts (every glyph is a box), which
// makes goldens useless for reviewing typography. We load real fonts:
// * Roboto and Material Icons from the Flutter SDK's material_fonts cache
//   (always present: `flutter precache` downloads them by default),
// * every font in the asset FontManifest (flutter_math_fork's KaTeX fonts),
// * KaTeX Typewriter registered as `monospace`, the first family of the
//   default code style, so code renders in a real fixed-width face.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  await _loadFonts();
  final comparator = goldenFileComparator;
  if (comparator is LocalFileComparator) {
    goldenFileComparator = _TolerantComparator(
      comparator.basedir.resolve('golden_test.dart'),
    );
  }
  await testMain();
}

Future<void> _loadFonts() async {
  final materialFonts = _materialFontsDir();
  if (materialFonts != null) {
    final roboto = FontLoader('Roboto');
    for (final file in const [
      'Roboto-Regular.ttf',
      'Roboto-Italic.ttf',
      'Roboto-Medium.ttf',
      'Roboto-MediumItalic.ttf',
      'Roboto-Bold.ttf',
      'Roboto-BoldItalic.ttf',
    ]) {
      final f = File('${materialFonts.path}/$file');
      if (f.existsSync()) roboto.addFont(_bytes(f));
    }
    await roboto.load();
    final icons = File('${materialFonts.path}/MaterialIcons-Regular.otf');
    if (icons.existsSync()) {
      await (FontLoader('MaterialIcons')..addFont(_bytes(icons))).load();
    }
  }

  // Fonts declared by dependencies (KaTeX) are in the test asset bundle.
  final manifest = json.decode(
    await rootBundle.loadString('FontManifest.json'),
  ) as List<Object?>;
  for (final entry in manifest.cast<Map<String, Object?>>()) {
    final family = entry['family']! as String;
    final loader = FontLoader(
      family.replaceFirst(RegExp(r'^packages/[^/]+/'), ''),
    );
    final samePackaged = FontLoader(family);
    for (final font
        in (entry['fonts']! as List<Object?>).cast<Map<String, Object?>>()) {
      final asset = font['asset']! as String;
      loader.addFont(rootBundle.load(asset));
      samePackaged.addFont(rootBundle.load(asset));
    }
    await loader.load();
    await samePackaged.load();
  }
  const typewriter =
      'packages/flutter_math_fork/lib/katex_fonts/fonts/KaTeX_Typewriter-Regular.ttf';
  await (FontLoader('monospace')..addFont(rootBundle.load(typewriter))).load();
}

Future<ByteData> _bytes(File f) async =>
    ByteData.sublistView(await f.readAsBytes());

/// `$FLUTTER_ROOT/bin/cache/artifacts/material_fonts`, found via the
/// environment or by walking up from the flutter_tester binary
/// (`bin/cache/artifacts/engine/<platform>/flutter_tester`).
Directory? _materialFontsDir() {
  final roots = <String>[?Platform.environment['FLUTTER_ROOT']];
  var dir = File(Platform.resolvedExecutable).parent;
  for (var i = 0; i < 6; i++) {
    roots.add(dir.path);
    dir = dir.parent;
  }
  for (final root in roots) {
    for (final candidate in [
      '$root/bin/cache/artifacts/material_fonts',
      '$root/artifacts/material_fonts',
      '$root/material_fonts',
    ]) {
      final d = Directory(candidate);
      if (d.existsSync()) return d;
    }
  }
  return null;
}

/// Accepts tiny anti-aliasing differences (≤ 0.5 % of pixels) so goldens
/// survive harmless rasterizer updates; anything larger still fails with
/// the usual diff images.
class _TolerantComparator extends LocalFileComparator {
  _TolerantComparator(super.testFile);

  static const _tolerance = 0.005;

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    final result = await GoldenFileComparator.compareLists(
      imageBytes,
      await getGoldenBytes(golden),
    );
    if (result.passed || result.diffPercent <= _tolerance) {
      result.dispose();
      return true;
    }
    final error = await generateFailureOutput(result, golden, basedir);
    result.dispose();
    throw FlutterError(error);
  }
}
