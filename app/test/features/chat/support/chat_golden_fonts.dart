import 'dart:io';

import 'package:flutter/services.dart';

/// Loads real fonts for the chat goldens.
///
/// `flutter test` renders text with box glyphs unless fonts are loaded by
/// hand (docs/research/12 §3.5). This is a helper the chat golden tests
/// call from `setUpAll`, deliberately not a `flutter_test_config.dart`, so
/// it never competes with the app-wide test config.
///
/// * Roboto and Material Icons come from the pinned Flutter SDK's
///   `material_fonts` cache, so no extra binaries are needed for them.
/// * Code and tool arguments use the `monospace` family; JetBrains Mono
///   (OFL, license next to it in `fonts/`) is registered under that name.
///
/// Returns false when the SDK fonts can't be found; callers skip then,
/// because comparing box glyphs proves nothing.
Future<bool> loadChatGoldenFonts() async {
  if (_loaded) return true;
  final root = _flutterRoot();
  if (root == null) return false;
  final dir = '$root/bin/cache/artifacts/material_fonts';
  final regular = File('$dir/Roboto-Regular.ttf');
  final icons = File('$dir/MaterialIcons-Regular.otf');
  final mono = File('test/features/chat/fonts/JetBrainsMono-Regular.ttf');
  if (!regular.existsSync() || !icons.existsSync() || !mono.existsSync()) return false;

  final roboto = FontLoader('Roboto');
  for (final weight in ['Light', 'Regular', 'Medium', 'Bold']) {
    final f = File('$dir/Roboto-$weight.ttf');
    if (f.existsSync()) roboto.addFont(_bytes(f));
  }
  await roboto.load();
  await (FontLoader('MaterialIcons')..addFont(_bytes(icons))).load();
  await (FontLoader('monospace')..addFont(_bytes(mono))).load();
  _loaded = true;
  return true;
}

bool _loaded = false;

Future<ByteData> _bytes(File f) => Future.value(ByteData.sublistView(f.readAsBytesSync()));

String? _flutterRoot() {
  final env = Platform.environment['FLUTTER_ROOT'];
  if (env != null && env.isNotEmpty && Directory(env).existsSync()) return env;
  // flutter_tester runs from <root>/bin/cache/artifacts/engine/<platform>/.
  var dir = File(Platform.resolvedExecutable).parent;
  for (var i = 0; i < 6; i++) {
    if (File('${dir.path}/bin/flutter').existsSync()) return dir.path;
    dir = dir.parent;
  }
  return null;
}
