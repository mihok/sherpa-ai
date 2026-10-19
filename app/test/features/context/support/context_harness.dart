import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa/design/theme.dart';
import 'package:sherpa/features/chat/chat_screen.dart';
import 'package:sherpa/features/chat/state/chat_controller.dart';
import 'package:sherpa/features/chat/state/chat_dependencies.dart';
import 'package:sherpa/features/context/handoff/handoff_import_screen.dart';
import 'package:sherpa/features/context/handoff/handoff_platform.dart';
import 'package:sherpa/features/context/handoff/handoff_screen.dart';
import 'package:sherpa/features/context/inspector_screen.dart';
import 'package:sherpa/routing/chat_screen_binding.dart';
import 'package:sherpa/routing/context_route.dart';
import 'package:sherpa/state/observable_session_store.dart';
import 'package:sherpa/state/providers.dart';
import 'package:sherpa/state/services.dart';
import 'package:sherpa/state/ui_preferences.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_core/testing.dart';
import 'package:sherpa_providers/sherpa_providers.dart';

import '../../chat/support/fakes.dart';

const String kSession = 's1';
const String kProviderId = 'cloud';
const String kModelId = 'scripted-model';

final ProviderInfo kCloudInfo = ProviderInfo(
  id: kProviderId,
  kind: ProviderKind.fake,
  displayName: 'Test Cloud',
  location: ExecutionLocation.remote,
  baseUrl: Uri.parse('https://api.example.com/v1'),
);

final ProviderConfig kCloudConfig = ProviderConfig(
  id: kProviderId,
  flavor: ApiFlavor.anthropic,
  displayName: 'Test Cloud',
  baseUrl: Uri.parse('https://api.example.com/v1'),
  defaultModelId: kModelId,
);

/// An 8K window: small enough that a few tool results fill it, so the
/// ladder's thresholds (prune 55%, compact 70%, handoff 90%) are reachable.
const ModelCapabilities kSmallWindow = ModelCapabilities(contextLength: 8192);

/// `n` numbered lines, like a log or file a tool returned.
String lines(int n, {String what = 'payload'}) =>
    [for (var i = 1; i <= n; i++) 'line $i of the $what text, with a few more words'].join('\n');

/// Records share/save/pick calls instead of touching platform channels.
final class FakeHandoffPlatform implements HandoffPlatform {
  final List<({String name, Uint8List bytes, String mimeType})> shared = [];
  final List<String> saved = [];
  PickedFile? nextPick;
  bool scan = true;
  int cleared = 0;

  @override
  Future<void> shareFile({
    required String name,
    required Uint8List bytes,
    required String mimeType,
    String? subject,
  }) async =>
      shared.add((name: name, bytes: bytes, mimeType: mimeType));

  @override
  Future<bool> saveFile({required String name, required Uint8List bytes, required String mimeType}) async {
    saved.add(name);
    return true;
  }

  @override
  Future<PickedFile?> pickFile({required int maxBytes}) async {
    final p = nextPick;
    if (p?.bytes != null && p!.bytes!.length > maxBytes) return PickedFile(name: p.name, size: p.bytes!.length);
    return p;
  }

  @override
  Future<void> clearShared() async => cleared++;

  @override
  bool get canScan => scan;
}

/// A chat with the real controller, runner and ladder over in-memory
/// stores and a [ScriptedProvider], plus the context feature's seams.
final class ContextHarness {
  ContextHarness({
    List<ScriptedTurn> turns = const [],
    ModelCapabilities caps = kSmallWindow,
    List<LocalTool> tools = const [],
    ContextManager? manager,
    bool configured = true,
    this.scanner,
    this.extra = const [],
  }) {
    provider = ScriptedProvider(turns, info: kCloudInfo, capabilitiesValue: caps);
    router = LocalToolRouter(tools);
    registry = FakeProviderRegistry(
      configs: configured ? [kCloudConfig] : const [],
      providers: configured ? {kProviderId: provider} : const {},
    );
    this.manager = manager ?? LadderContextManager(clock: clock, random: Random(7), toolLookup: router.lookup);
    container = ProviderContainer(overrides: overrides);
  }

  final ObservableSessionStore store = ObservableSessionStore(InMemorySessionStore());
  final FakeClock clock = FakeClock(DateTime.utc(2026, 10, 18, 9));
  final SequentialIdGenerator ids = SequentialIdGenerator();
  final FakePreferences prefs = FakePreferences(defaultModel: const ModelChoice(providerId: kProviderId, modelId: kModelId));
  final RecordingPlatformActions chatPlatform = RecordingPlatformActions();
  final FakeHandoffPlatform platform = FakeHandoffPlatform();
  final InMemorySecretStore secrets = InMemorySecretStore();
  final InMemoryUiPreferencesStore ui = InMemoryUiPreferencesStore();
  final Future<String?> Function(BuildContext context)? scanner;

  /// More overrides (seams a test replaces).
  final List<Override> extra;
  late final ScriptedProvider provider;
  late final LocalToolRouter router;
  late final FakeProviderRegistry registry;
  late final ContextManager manager;
  late final ProviderContainer container;

  List<Override> get overrides => [
        sessionStoreProvider.overrideWithValue(store),
        providerRegistryProvider.overrideWithValue(registry),
        preferencesProvider.overrideWithValue(prefs),
        secretStoreProvider.overrideWithValue(secrets),
        uiPreferencesStoreProvider.overrideWithValue(ui),
        clockProvider.overrideWithValue(clock),
        idGeneratorProvider.overrideWithValue(ids),
        toolRouterProvider.overrideWithValue(router),
        approvalPolicyProvider.overrideWithValue(ApprovalPolicy(clock: clock)),
        chatFrameSchedulerProvider.overrideWithValue(MicrotaskFrameScheduler()),
        chatPlatformProvider.overrideWithValue(chatPlatform),
        chatRetrySleepProvider.overrideWithValue((_) async {}),
        chatContextManagerProvider.overrideWithValue(manager),
        handoffPlatformProvider.overrideWithValue(platform),
        contextScreensProvider.overrideWithValue(contextScreens),
        if (scanner != null) handoffScannerProvider.overrideWithValue(scanner!),
        ...extra,
      ];

  ChatController get chat => container.read(chatControllerProvider(kSession).notifier);

  /// Keeps the chat controller alive for the test and waits for its load.
  Future<ChatController> open() async {
    container.listen(chatControllerProvider(kSession), (_, _) {});
    final c = chat;
    await c.loaded;
    return c;
  }

  Future<SessionRecord> createSession({String id = kSession, String title = 'Plan the audit'}) => store.putSession(
        SessionRecord(
          id: id,
          title: title,
          createdAt: clock.now(),
          updatedAt: clock.now(),
          providerId: kProviderId,
          modelId: kModelId,
        ),
      );

  /// Appends one exchange to the active branch: the user asks, the
  /// assistant reads a file ([resultLines] lines), then answers.
  Future<void> addTurn(int n, {int resultLines = 60, String? userText}) async {
    final session = (await store.getSession(kSession))!;
    String id(String k) => 't$n-$k';
    final t = clock.now();
    final msgs = [
      Message(
        id: id('u'),
        parentId: session.activeLeafId,
        role: Role.user,
        content: [TextPart(userText ?? 'Step $n: read the next log and tell me what changed. Never email customers.')],
        createdAt: t,
      ),
      Message(
        id: id('a'),
        parentId: id('u'),
        role: Role.assistant,
        content: [
          TextPart('Reading log $n.'),
          ToolCallPart(ToolCall(id: 'call$n', name: 'read_file', arguments: {'path': '/logs/day$n.log'})),
        ],
        createdAt: t.add(const Duration(seconds: 1)),
        providerId: kProviderId,
        modelId: kModelId,
        finishReason: 'toolCalls',
      ),
      Message(
        id: id('r'),
        parentId: id('a'),
        role: Role.tool,
        content: [
          ToolResultPart(
            callId: 'call$n',
            toolName: 'read_file',
            content: [TextPart(lines(resultLines, what: 'day $n log'))],
          ),
        ],
        createdAt: t.add(const Duration(seconds: 2)),
      ),
      Message(
        id: id('f'),
        parentId: id('r'),
        role: Role.assistant,
        content: [TextPart('Day $n: nothing unusual, ${'steady traffic ' * 6}.')],
        createdAt: t.add(const Duration(seconds: 3)),
        providerId: kProviderId,
        modelId: kModelId,
        finishReason: 'stop',
      ),
    ];
    for (final m in msgs) {
      await store.putMessage(kSession, m);
    }
    await store.putSession(session.copyWith(activeLeafId: id('f'), updatedAt: t));
    clock.advance(const Duration(minutes: 1));
  }

  /// A session with [turns] exchanges.
  Future<void> seedConversation({int turns = 6, int resultLines = 60}) async {
    await createSession();
    for (var n = 1; n <= turns; n++) {
      await addTurn(n, resultLines: resultLines);
    }
  }

  Future<List<Message>> activePath([String id = kSession]) async {
    final s = await store.getSession(id);
    return s?.activeLeafId == null ? const [] : store.path(id, s!.activeLeafId!);
  }

  /// Polls until [condition] holds (real-time tests only).
  Future<void> until(bool Function() condition, {Duration timeout = const Duration(seconds: 5)}) async {
    final end = DateTime.now().add(timeout);
    while (!condition()) {
      if (DateTime.now().isAfter(end)) throw TimeoutException('condition not met', timeout);
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  void dispose() => container.dispose();
}

/// A text reply without usage (usage would calibrate the runner's token
/// estimate against made-up numbers).
ScriptedTurn textTurn(String text) => ScriptedTurn([TextDelta(text), const Finish(FinishReason.stop)]);

/// The app's real themes at phone size, with the context routes.
Future<GoRouter> pumpContext(
  WidgetTester tester,
  ContextHarness h, {
  required String location,
  Brightness brightness = Brightness.light,
  Size size = const Size(400, 860),
  double textScale = 1.0,
  bool realChat = false,
}) async {
  tester.view.physicalSize = size * tester.view.devicePixelRatio;
  addTearDown(tester.view.resetPhysicalSize);
  final router = GoRouter(
    initialLocation: location,
    routes: [
      GoRoute(
        path: '/chat/:id',
        builder: (_, s) => realChat
            ? ChatScreen(sessionId: s.pathParameters['id']!)
            : Scaffold(body: Text('chat:${s.pathParameters['id']}')),
        routes: [
          GoRoute(
            path: 'context',
            builder: (_, s) => ContextInspectorScreen(sessionId: s.pathParameters['id']!),
          ),
          GoRoute(
            path: 'handoff',
            builder: (_, s) => HandoffScreen(sessionId: s.pathParameters['id']!),
          ),
        ],
      ),
      GoRoute(path: '/handoff/import', builder: (_, _) => const HandoffImportScreen()),
      GoRoute(path: '/onboarding', builder: (_, _) => const Scaffold(body: Text('onboarding'))),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: h.container,
      child: MediaQuery(
        data: MediaQueryData.fromView(tester.view).copyWith(textScaler: TextScaler.linear(textScale)),
        child: MaterialApp.router(
          debugShowCheckedModeBanner: false,
          theme: SherpaTheme.light(),
          darkTheme: SherpaTheme.dark(),
          themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
          routerConfig: router,
        ),
      ),
    ),
  );
  await settle(tester);
  return router;
}

/// Pumps frames until async work and animations are done (pumpAndSettle
/// with a bound, since some screens animate a progress indicator).
Future<void> settle(WidgetTester tester, {int frames = 40}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  await tester.pump(const Duration(seconds: 1));
  await tester.pump();
}
