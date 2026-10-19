import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa/bootstrap.dart' show noRetry;
import 'package:sherpa/design/haptics.dart';
import 'package:sherpa/design/theme.dart';
import 'package:sherpa/features/mcp/input/input_host.dart';
import 'package:sherpa/features/mcp/mcp_bootstrap.dart';
import 'package:sherpa/features/mcp/state/input_providers.dart';
import 'package:sherpa/services/mcp/input/interactive_handler.dart';
import 'package:sherpa/services/mcp/mcp_runtime.dart';
import 'package:sherpa/state/in_memory/in_memory_preferences_store.dart';
import 'package:sherpa/state/providers.dart';
import 'package:sherpa/state/ui_preferences.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../../../services/mcp/support/input_fakes.dart';
import '../../../services/mcp/support/mcp_fakes.dart';

export '../../../services/mcp/support/input_fakes.dart';
export '../../../services/mcp/support/mcp_fakes.dart';

final class _NoHaptics implements HapticsDriver {
  @override
  Future<void> perform(HapticKind kind) async {}
}

/// A real [McpRuntime] over fakes, a scripted model and a recording URL
/// opener, behind a small app with [McpInputHost].
final class InputRig {
  InputRig._(this.runtime, this.remote);

  static Future<InputRig> create(WidgetTester tester, {FakeRemoteServers? remote, Duration? inputTimeout}) async {
    final servers = remote ?? FakeRemoteServers();
    late McpRuntime rt;
    await tester.runAsync(() async {
      rt = await fakeRuntime(remote: servers, inputTimeout: inputTimeout ?? const Duration(minutes: 5));
    });
    final rig = InputRig._(rt, servers);
    addTearDown(() => tester.runAsync(rt.dispose));
    return rig;
  }

  final McpRuntime runtime;
  final FakeRemoteServers remote;
  final ScriptedModelProvider model = ScriptedModelProvider();
  late final FakeProviderRegistry registry = FakeProviderRegistry({'scripted': model});
  final RecordingUrlOpener opener = RecordingUrlOpener();
  final InMemoryPreferencesStore prefs = InMemoryPreferencesStore(defaultModel: defaultChoice, onboardingComplete: true);
  final InMemorySessionStore sessions = InMemorySessionStore();
  List<Override> extra = const [];

  InteractiveInputHandler get handler => runtime.manager.options.inputHandler! as InteractiveInputHandler;

  List<Override> get overrides => [
        ...mcpRuntimeOverrides(runtime),
        sessionStoreProvider.overrideWithValue(sessions),
        providerRegistryProvider.overrideWithValue(registry),
        preferencesProvider.overrideWithValue(prefs),
        clockProvider.overrideWithValue(FakeClock(DateTime.utc(2026, 10, 19, 12))),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator()),
        hapticsDriverProvider.overrideWithValue(_NoHaptics()),
        mcpUrlOpenerProvider.overrideWithValue(opener),
        ...extra,
      ];

  Future<void> pumpApp(
    WidgetTester tester, {
    Widget? home,
    Size size = const Size(420, 900),
    double textScale = 1,
    ThemeMode themeMode = ThemeMode.light,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(ProviderScope(
      overrides: overrides,
      retry: noRetry,
      child: MaterialApp(
        theme: SherpaTheme.light(),
        darkTheme: SherpaTheme.dark(),
        themeMode: themeMode,
        builder: (context, child) => McpInputHost(child: child ?? const SizedBox.shrink()),
        home: home ?? const Scaffold(body: Center(child: Text('home'))),
      ),
    ));
    await tester.pump();
  }

  /// Runs microtasks and real-time work (in-process servers) to completion.
  /// With [andSettle] false (spinners on screen never settle) it pumps
  /// long enough for sheet transitions instead.
  Future<void> settle(WidgetTester tester, {int rounds = 8, bool andSettle = true}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump(const Duration(milliseconds: 16));
    }
    if (andSettle) {
      await tester.pumpAndSettle();
    } else {
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }
  }
}
