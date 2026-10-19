import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa/features/chat/state/chat_controller.dart';
import 'package:sherpa/features/chat/state/chat_errors.dart';
import 'package:sherpa/features/chat/state/chat_view_state.dart';
import 'package:sherpa/features/chat/state/notice_copy.dart';
import 'package:sherpa/features/chat/state/transcript_model.dart';
import 'package:sherpa/features/diagnostics/app_error_ring.dart';
import 'package:sherpa/services/background/background_providers.dart';
import 'package:sherpa/services/background/run_activity.dart';
import 'package:sherpa/services/inference/on_device_ids.dart';
import 'package:sherpa/state/services.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_core/testing.dart';
import 'package:sherpa_platform/sherpa_platform.dart';
import 'package:sherpa_platform/testing.dart';

import 'support/fakes.dart';
import 'support/harness.dart';

const ProviderInfo _localInfo = ProviderInfo(
  id: localProviderId,
  kind: ProviderKind.localLlamaCpp,
  displayName: 'On this device',
  location: ExecutionLocation.onDevice,
);

/// The chat and [RunActivity] together: every run is registered when it
/// starts and ended with its outcome; the OS ending the background time
/// pauses it with a checkpoint and Continue picks it up; on-device runs on
/// iPhone pause instead of pretending; a reply finished while away posts a
/// notice; chat errors reach the diagnostics ring by type and code.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ChatHarness h;
  late FakePlatformBackend backend;
  late FakeForegroundSource fg;
  late RunActivity activity;
  late AppErrorRing ring;

  ChatHarness harness({
    ModelProvider? provider,
    List<ScriptedTurn> turns = const [],
    List<LocalTool> tools = const [],
    BackgroundPlatform platform = BackgroundPlatform.android,
    Map<String, ModelProvider>? providers,
    bool configured = true,
  }) {
    backend = FakePlatformBackend();
    fg = FakeForegroundSource();
    ring = AppErrorRing();
    activity = RunActivity(
      guard: BackgroundRunGuard(backend: backend, updateInterval: Duration.zero, random: Random(3)),
      foreground: fg,
      platform: platform,
      notificationsAsked: true,
    );
    return h = ChatHarness(
      provider: provider,
      turns: turns,
      tools: tools,
      providers: providers,
      configured: configured,
      configs: providers == null ? null : const [],
      overrides: [
        runActivityProvider.overrideWithValue(activity),
        appErrorRingProvider.overrideWithValue(ring),
      ],
    );
  }

  Future<void> settle() async {
    for (var i = 0; i < 4; i++) {
      await activity.idle;
      await h.settle();
    }
  }

  tearDown(() {
    h.dispose();
    activity.dispose();
  });

  test('a send begins a short lease while visible, named after the chat, and ends it with the reply', () async {
    final p = ManualProvider();
    harness(provider: p);
    await h.createSession();
    final c = await h.open();
    final done = c.send('Plan a weekend in Lisbon');
    await p.started;
    await settle();
    final lease = backend.begun.single;
    expect(lease.long, isFalse, reason: 'a reply: shortService / beginBackgroundTask');
    expect(lease.title, 'Sherpa is finishing a reply in “Plan a weekend in Lisbon”',
        reason: 'the title the runner is about to give the chat');
    expect(activity.snapshot.chats, {kSession: ChatActivityState.running});
    p.emit(const TextDelta('Start at '));
    await p.finish();
    await done;
    await settle();
    expect(backend.ended, [lease.id]);
    expect(activity.snapshot.chats, isEmpty);
    expect(backend.notices, isEmpty, reason: 'finished on screen');
  });

  test('a run that calls a tool is upgraded to a long lease while Sherpa is visible', () async {
    harness(
      tools: [FakeTool('lookup')],
      turns: [
        ScriptedTurn.toolCalls([const ToolCall(id: 'c1', name: 'lookup', arguments: {})]),
        ScriptedTurn.text('Found it.'),
      ],
    );
    await h.createSession();
    final c = await h.open();
    await c.send('Find the ferry times');
    await settle();
    expect(backend.begun.map((r) => r.long), [false, true], reason: 'specialUse once it is an agent run');
    expect(backend.ended.toSet(), {for (final r in backend.begun) r.id});
  });

  group('the OS ends the background time', () {
    test('the run stops with a checkpoint, says why, and Continue picks it up with a long lease', () async {
      final p = ManualProvider();
      harness(provider: p);
      const id = 'trip';
      await h.createSession(id: id);
      // Listened like a screen, so the chat can be closed and reopened.
      var screen = h.container.listen(chatControllerProvider(id), (_, _) {});
      ChatViewState state() => h.container.read(chatControllerProvider(id));
      final c = h.container.read(chatControllerProvider(id).notifier);
      await c.loaded;
      final done = c.send('Plan a weekend in Lisbon');
      await p.started;
      p.emit(const TextDelta('Day one: the '));
      await settle();
      fg.foreground = false;
      backend.emit(SignalKind.leaseExpired, leaseId: backend.begun.single.id, detail: 'timeout');
      await done;
      await settle();

      expect(state().status, ChatRunStatus.cancelled);
      final notice = state().notices.singleWhere((n) => n.code == kBackgroundPausedNotice);
      expect(notice.message, startsWith('Paused when the app was in the background'));
      expect(notice.action, ChatNoticeAction.continueRun);
      expect(state().notices.where((n) => n.code == 'stopped'), isEmpty, reason: 'the user did not stop it');
      final cp = await h.store.getCheckpoint(id);
      expect(cp?.phase, RunPhase.cancelled, reason: 'checkpointed by the runner');
      final leaf = (await h.store.getSession(id))!.activeLeafId!;
      final partial = (await h.store.path(id, leaf)).last;
      expect(partial.text, 'Day one: the ');
      expect(partial.finishReason, FinishReason.cancelled.name);
      expect(backend.notices.single.title, 'Paused in “Plan a weekend in Lisbon”');
      expect(activity.wasPausedInBackground(id), isTrue);
      expect(activity.snapshot.chats[id], ChatActivityState.pausedInBackground, reason: 'the chat list says so too');

      // Closed (its controller freed) and reopened later: it still says so.
      screen.close();
      await settle();
      screen = h.container.listen(chatControllerProvider(id), (_, _) {});
      final reopened = h.container.read(chatControllerProvider(id).notifier);
      expect(reopened, isNot(same(c)));
      await reopened.loaded;
      expect(state().notices.map((n) => n.code), contains(kBackgroundPausedNotice));

      fg.foreground = true;
      final again = reopened.continueRun();
      await p.started;
      await settle();
      expect(backend.begun.last.long, isTrue, reason: 'the user asked to continue an agent run');
      expect(state().notices.where((n) => n.code == kBackgroundPausedNotice), isEmpty);
      p.emit(const TextDelta('Day one: the Alfama.'));
      await p.finish();
      await again;
      await settle();
      expect(state().status, ChatRunStatus.idle);
      expect(turnText(state()), 'Day one: the Alfama.');
      expect(activity.wasPausedInBackground(id), isFalse);
      screen.close();
    });

    test('while Sherpa is on screen again nothing stops: a new lease is taken', () async {
      final p = ManualProvider();
      harness(provider: p);
      await h.createSession();
      final c = await h.open();
      final done = c.send('Hi');
      await p.started;
      await settle();
      backend.emit(SignalKind.leaseExpired, leaseId: backend.begun.single.id, detail: 'timeout');
      await settle();
      expect(h.state.isRunActive, isTrue);
      expect(backend.begun, hasLength(2));
      await p.finish();
      await done;
    });
  });

  test('finished while Sherpa is in the background: "Reply ready", without the reply', () async {
    final p = ManualProvider();
    harness(provider: p);
    await h.createSession();
    final c = await h.open();
    final done = c.send('Summarize my notes');
    await p.started;
    await settle();
    fg.foreground = false;
    p.emit(const TextDelta('Your notes say the secret is 42.'));
    await p.finish();
    await done;
    await settle();
    final n = backend.notices.single;
    expect(n.title, 'Reply ready in “Summarize my notes”');
    expect('${n.title} ${n.text}', isNot(contains('42')), reason: 'no message content');
    expect(backend.ended, hasLength(1));
  });

  test('iPhone, on-device model: "Paused: open Sherpa to continue", and an expiry does not stop it', () async {
    final p = ManualProvider(info: _localInfo);
    harness(provider: p, platform: BackgroundPlatform.ios, providers: {localProviderId: p}, configured: false);
    await h.store.putSession(SessionRecord(
      id: kSession,
      title: 'Offline notes',
      createdAt: h.clock.now(),
      updatedAt: h.clock.now(),
      providerId: localProviderId,
      modelId: 'manual-model',
    ));
    final c = await h.open();
    final done = c.send('Hi');
    await p.started;
    await settle();
    expect(backend.begun.single.long, isFalse);
    fg.foreground = false;
    await settle();
    expect(backend.updates.last.text, 'Paused: open Sherpa to continue');
    backend.emit(SignalKind.leaseExpired, leaseId: backend.begun.single.id, detail: 'background time expired');
    await settle();
    expect(h.state.isRunActive, isTrue, reason: 'the inference lifecycle pauses it; it resumes on return');
    fg.foreground = true;
    p.emit(const TextDelta('Hello.'));
    await p.finish();
    await done;
    await settle();
    expect(h.state.lastOutcome, RunOutcome.completed);
    expect(h.state.notices.where((n) => n.code == kBackgroundPausedNotice), isEmpty);
  });

  test('a provider waiting for the foreground reads plainly, not as a GPU message', () async {
    final p = ManualProvider();
    harness(provider: p);
    await h.createSession();
    final c = await h.open();
    final done = c.send('Hi');
    await p.started;
    p.emit(const ProviderNotice(kWaitingForForegroundNotice,
        'On-device generation waits until Sherpa is back on screen (the GPU is unavailable in the background).'));
    await settle();
    final n = h.state.notices.singleWhere((n) => n.code == kWaitingForForegroundNotice);
    expect(n.message, 'Paused while Sherpa is in the background. The reply continues when you come back.');
    expect(n.message, isNot(contains('GPU')));
    p.emit(const TextDelta('Back again.'));
    await settle();
    expect(h.state.notices.where((n) => n.code == kWaitingForForegroundNotice), isEmpty,
        reason: 'the reply moved on, so the progress line goes');
    await p.finish();
    await done;
  });

  test('chat errors reach the diagnostics ring by type and code, never their text', () async {
    harness(turns: [
      ScriptedTurn.error(const ProviderException(ProviderErrorKind.auth, 'echo: my secret prompt', statusCode: 401)),
    ]);
    await h.createSession();
    final c = await h.open();
    await c.send('Hi');
    await settle();
    expect(h.state.error?.kind, ChatErrorKind.auth);
    final r = ring.records.where((r) => r.source == 'chat').single;
    expect(r.type, 'ProviderException');
    expect(r.code, 'auth_401');
    expect('${r.toJson()}', isNot(contains('secret')));
  });

  test('a phone with only MLX or Gemini Nano models can start a chat (not "add a provider")', () async {
    final mlx = ScriptedProvider(const [],
        info: const ProviderInfo(
          id: mlxProviderId,
          kind: ProviderKind.localMlx,
          displayName: 'On this device (MLX)',
          location: ExecutionLocation.onDevice,
        ));
    harness(configured: false, providers: {mlxProviderId: mlx, geminiNanoProviderId: mlx});
    await h.createSession(withModel: false);
    await h.open();
    expect(h.state.availability, ProviderAvailability.needsModel);
    expect(h.state.onDeviceModels, 2);
  });
}

String turnText(ChatViewState s) => s.items.whereType<AssistantTurnItem>().last.copyText;
