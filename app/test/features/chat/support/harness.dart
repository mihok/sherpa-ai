import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:material_ui/material_ui.dart';
import 'package:sherpa/design/tokens.dart';
import 'package:sherpa/features/chat/state/chat_controller.dart';
import 'package:sherpa/features/chat/state/chat_dependencies.dart';
import 'package:sherpa/features/chat/state/chat_view_state.dart';
import 'package:sherpa/features/chat/state/frame_scheduler.dart';
import 'package:sherpa/state/providers.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_core/testing.dart';
import 'package:sherpa_providers/sherpa_providers.dart';

import 'fakes.dart';

const String kSession = 's1';
const String kProviderId = 'cloud';
const String kModelId = 'scripted-model';

/// The remote endpoint the scripted provider pretends to be.
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

/// Everything a chat needs, with deterministic clock and ids, wired through
/// a real [ProviderContainer] so tests exercise the same providers the app
/// uses.
final class ChatHarness {
  ChatHarness({
    List<ScriptedTurn> turns = const [],
    ModelProvider? provider,
    List<LocalTool> tools = const [],
    FrameScheduler? frames,
    bool configured = true,
    Duration eventDelay = Duration.zero,
    ModelCapabilities caps = const ModelCapabilities(contextLength: 32768),
    AgentConfig agentConfig = const AgentConfig(),
    List<ProviderConfig>? configs,
    Map<String, ModelProvider>? providers,
    ToolRouter? router,
    List<Override> overrides = const [],
  }) {
    this.provider = provider ??
        ScriptedProvider(turns, info: kCloudInfo, eventDelay: eventDelay, capabilitiesValue: caps);
    this.router = router ?? LocalToolRouter(tools);
    registry = FakeProviderRegistry(
      configs: configs ?? (configured ? [kCloudConfig] : const []),
      providers: providers ?? (configured ? {kProviderId: this.provider} : const {}),
    );
    container = ProviderContainer(
      overrides: [
        sessionStoreProvider.overrideWithValue(store),
        providerRegistryProvider.overrideWithValue(registry),
        preferencesProvider.overrideWithValue(prefs),
        clockProvider.overrideWithValue(clock),
        idGeneratorProvider.overrideWithValue(ids),
        toolRouterProvider.overrideWithValue(this.router),
        approvalPolicyProvider.overrideWithValue(policy),
        chatFrameSchedulerProvider.overrideWithValue(frames ?? MicrotaskFrameScheduler()),
        chatPlatformProvider.overrideWithValue(platform),
        chatAgentConfigProvider.overrideWithValue(agentConfig),
        chatRetrySleepProvider.overrideWithValue((_) async {}),
        ...overrides,
      ],
    );
  }

  final InMemorySessionStore store = InMemorySessionStore();
  final FakeClock clock = FakeClock(DateTime.utc(2026, 10, 18, 9));
  final SequentialIdGenerator ids = SequentialIdGenerator();
  final FakePreferences prefs = FakePreferences();
  final RecordingPlatformActions platform = RecordingPlatformActions();
  late final ApprovalPolicy policy = ApprovalPolicy(clock: clock);
  late final ModelProvider provider;
  late final ToolRouter router;
  late final FakeProviderRegistry registry;
  late final ProviderContainer container;

  /// Every state the controller published, in order.
  final List<ChatViewState> emissions = [];
  ProviderSubscription<ChatViewState>? _sub;

  ScriptedProvider get scripted => provider as ScriptedProvider;

  Future<SessionRecord> createSession({
    String id = kSession,
    bool withModel = true,
    String title = defaultSessionTitle,
  }) =>
      store.putSession(SessionRecord(
        id: id,
        title: title,
        createdAt: clock.now(),
        updatedAt: clock.now(),
        providerId: withModel ? kProviderId : null,
        modelId: withModel ? kModelId : null,
      ));

  /// Starts (and keeps alive) the controller for [id], recording emissions.
  Future<ChatController> open([String id = kSession]) async {
    _sub ??= container.listen<ChatViewState>(
      chatControllerProvider(id),
      (_, next) => emissions.add(next),
      fireImmediately: true,
    );
    final c = container.read(chatControllerProvider(id).notifier);
    await c.loaded;
    await settle();
    return c;
  }

  ChatController get controller => container.read(chatControllerProvider(kSession).notifier);

  ChatViewState get state => container.read(chatControllerProvider(kSession));

  /// Seeds a finished exchange directly in the store (no model call).
  Future<(Message user, Message reply)> seedExchange(
    String question,
    String answer, {
    String? parentId,
    List<ContentPart> extra = const [],
    JsonMap replyMetadata = const {},
  }) async {
    final session = await store.getSession(kSession);
    final user = Message(
      id: ids.next('msg'),
      parentId: parentId ?? session!.activeLeafId,
      role: Role.user,
      content: [TextPart(question)],
      createdAt: clock.now(),
    );
    clock.advance(const Duration(seconds: 1));
    final reply = Message(
      id: ids.next('msg'),
      parentId: user.id,
      role: Role.assistant,
      content: [...extra, TextPart(answer)],
      createdAt: clock.now(),
      providerId: kProviderId,
      modelId: kModelId,
      finishReason: 'stop',
      metadata: replyMetadata,
    );
    clock.advance(const Duration(seconds: 1));
    await store.putMessage(kSession, user);
    await store.putMessage(kSession, reply);
    await store.putSession(session!.copyWith(activeLeafId: reply.id, title: question));
    return (user, reply);
  }

  Future<List<Message>> activePath() async {
    final s = await store.getSession(kSession);
    return s?.activeLeafId == null ? const [] : store.path(kSession, s!.activeLeafId!);
  }

  /// Lets queued microtasks and zero-length timers run.
  Future<void> settle([int rounds = 30]) async {
    for (var i = 0; i < rounds; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// Polls until [condition] holds (real-time tests only).
  Future<void> until(bool Function() condition, {Duration timeout = const Duration(seconds: 5)}) async {
    final end = DateTime.now().add(timeout);
    while (!condition()) {
      if (DateTime.now().isAfter(end)) throw TimeoutException('condition not met', timeout);
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  void dispose() {
    _sub?.close();
    container.dispose();
  }
}

// ---------------------------------------------------------------------------
// Widget-test helpers

/// A theme with [SherpaTokens] registered, independent of the shell's theme
/// (which may not exist yet when these tests run).
ThemeData chatTestTheme(Brightness brightness, {bool reducedMotion = false}) {
  final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF3B6E8F), brightness: brightness);
  final dark = brightness == Brightness.dark;
  return ThemeData(
    colorScheme: scheme,
    fontFamily: 'Roboto',
    extensions: [
      SherpaTokens(
        space: const SpaceScale(),
        radius: const RadiusScale(),
        motion: MotionTokens(reduced: reducedMotion),
        semantic: SemanticColors(
          onDevice: dark ? const Color(0xFF7DD8A6) : const Color(0xFF1E7D4F),
          leavesDevice: dark ? const Color(0xFFF2B866) : const Color(0xFF9A5B00),
          success: dark ? const Color(0xFF7DD8A6) : const Color(0xFF1E7D4F),
          warning: dark ? const Color(0xFFF2B866) : const Color(0xFF9A5B00),
          danger: dark ? const Color(0xFFFFB4AB) : const Color(0xFFBA1A1A),
          reasoning: scheme.onSurfaceVariant,
          toolSurface: scheme.surfaceContainerLow,
          codeSurface: scheme.surfaceContainerHighest,
        ),
      ),
    ],
  );
}
