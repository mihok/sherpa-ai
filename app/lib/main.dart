import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'app.dart';
import 'bootstrap.dart';
import 'features/diagnostics/app_error_ring.dart';

Future<void> main() async {
  final overrides = await bootstrap();
  runApp(ProviderScope(
    overrides: overrides,
    retry: noRetry,
    // Failed providers go to the diagnostics error ring (type and code only).
    observers: const [AppErrorObserver()],
    child: const SherpaApp(),
  ));
}
