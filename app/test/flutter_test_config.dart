import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'support/golden_fonts.dart';

/// Runs before every test file in app/test (flutter_tools discovers it).
///
/// `flutter test` renders with test fonts (boxes) by default; goldens need
/// real glyphs, so Roboto (the Android default family, which the theme uses
/// in tests) and the Material Icons font are loaded once here.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  await loadGoldenFonts();
  await testMain();
}
