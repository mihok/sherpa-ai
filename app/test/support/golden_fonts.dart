import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

/// True once Roboto and Material Icons were loaded; golden tests skip
/// otherwise (they would only compare tofu boxes).
bool goldenFontsLoaded = false;

/// Fonts come from the Flutter SDK's own cache (`material_fonts`), so no
/// font binaries live in the repo and CI uses the exact files the pinned
/// SDK ships.
Future<void> loadGoldenFonts() async {
  final root = _flutterRoot();
  if (root == null) return;
  final dir = Directory('$root/bin/cache/artifacts/material_fonts');
  if (!dir.existsSync()) return;

  final roboto = FontLoader('Roboto');
  for (final w in ['Light', 'Regular', 'Medium', 'Bold']) {
    final f = File('${dir.path}/Roboto-$w.ttf');
    if (f.existsSync()) roboto.addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
  }
  await roboto.load();

  final icons = File('${dir.path}/MaterialIcons-Regular.otf');
  if (icons.existsSync()) {
    await (FontLoader('MaterialIcons')..addFont(Future.value(ByteData.sublistView(icons.readAsBytesSync())))).load();
  } else {
    await _loadIconsFromBundle();
  }
  goldenFontsLoaded = true;
}

/// Fallback: the icon font bundled with the test assets.
Future<void> _loadIconsFromBundle() async {
  try {
    final manifest = jsonDecode(await rootBundle.loadString('FontManifest.json')) as List<Object?>;
    for (final entry in manifest.cast<Map<String, Object?>>()) {
      if (entry['family'] != 'MaterialIcons') continue;
      final loader = FontLoader('MaterialIcons');
      for (final font in (entry['fonts']! as List<Object?>).cast<Map<String, Object?>>()) {
        loader.addFont(rootBundle.load(font['asset']! as String));
      }
      await loader.load();
    }
  } on Object {
    // No bundle in this run; icons render as boxes.
  }
}

String? _flutterRoot() {
  final env = Platform.environment['FLUTTER_ROOT'];
  if (env != null && env.isNotEmpty) return env;
  // flutter_tester lives at <root>/bin/cache/artifacts/engine/<platform>/flutter_tester.
  final exe = File(Platform.resolvedExecutable);
  var dir = exe.parent;
  for (var i = 0; i < 6; i++) {
    if (File('${dir.path}/bin/flutter').existsSync()) return dir.path;
    dir = dir.parent;
  }
  return null;
}
