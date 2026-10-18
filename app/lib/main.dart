import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'app.dart';
import 'bootstrap.dart';

Future<void> main() async {
  final overrides = await bootstrap();
  runApp(ProviderScope(overrides: overrides, retry: noRetry, child: const SherpaApp()));
}
