import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa/services/background/background_copy.dart';
import 'package:sherpa/services/background/run_activity.dart';
import 'package:sherpa/services/inference/on_device_ids.dart';
import 'package:sherpa/state/services.dart' show localProviderId;
import 'package:sherpa_core/sherpa_core.dart' show RunOutcome, defaultSessionTitle;
import 'package:sherpa_platform/sherpa_platform.dart';
import 'package:sherpa_platform/testing.dart';

/// [RunActivity] over the plugin's fake backend: when leases begin and
/// end, short or long, what they say, expiry, pausing on-device runs,
/// notices and the notifications permission.
void main() {
  late FakePlatformBackend backend;
  late FakeForegroundSource fg;
  late RunActivity activity;
  late List<String> expired;
  var asked = 0;

  RunActivity make({
    BackgroundPlatform platform = BackgroundPlatform.android,
    bool enabled = true,
    bool notificationsAsked = true,
  }) =>
      activity = RunActivity(
        guard: BackgroundRunGuard(
          backend: backend,
          iosContinuedTaskPrefix: kAgentRunTaskPrefix,
          updateInterval: Duration.zero,
          random: Random(7),
        ),
        foreground: fg,
        platform: platform,
        enabled: enabled,
        notificationsAsked: notificationsAsked,
        onNotificationsAsked: () => asked++,
      );

  BackgroundRun start({
    String session = 's1',
    String title = 'Trip plan',
    String provider = 'cloud',
    bool long = false,
  }) =>
      activity.start(
        sessionId: session,
        title: title,
        providerId: provider,
        long: long,
        onExpired: (why) => expired.add('$session:$why'),
      );

  Future<void> idle() async {
    for (var i = 0; i < 5; i++) {
      await activity.idle;
      await pumpEventQueue();
    }
  }

  setUp(() {
    backend = FakePlatformBackend();
    fg = FakeForegroundSource();
    expired = [];
    asked = 0;
  });

  tearDown(() => activity.dispose());

  group('lease timing', () {
    test('a run that starts while Sherpa is visible begins a short lease; it ends with the run', () async {
      make();
      final run = start();
      await idle();
      final r = backend.begun.single;
      expect(r.long, isFalse, reason: 'a single reply: shortService / beginBackgroundTask');
      expect(r.title, 'Sherpa is finishing a reply in “Trip plan”');
      expect(r.reason, 'Writing the reply');
      expect(activity.snapshot.leased, isTrue);
      expect(activity.snapshot.chats, {'s1': ChatActivityState.running});

      run.end(RunOutcome.completed);
      await idle();
      expect(backend.ended, [r.id]);
      expect(activity.snapshot.leased, isFalse);
      expect(activity.snapshot.chats, isEmpty);
    });

    test('a run that starts in the background gets no lease (the OS would refuse it)', () async {
      fg.foreground = false;
      make();
      start();
      await idle();
      expect(backend.begun, isEmpty);
      expect(activity.snapshot.chats['s1'], ChatActivityState.running, reason: 'still tracked');
    });

    test('one lease for every run; it ends only when the last run ends', () async {
      make();
      final a = start(session: 'a', title: 'A');
      final b = start(session: 'b', title: 'B');
      await idle();
      expect(backend.begun, hasLength(1));
      a.end(RunOutcome.completed);
      await idle();
      expect(backend.ended, isEmpty);
      expect(backend.updates.last.text, 'Writing the reply', reason: 'now about b');
      b.end(RunOutcome.completed);
      await idle();
      expect(backend.ended, [backend.begun.single.id]);
    });

    test('disabled: runs are tracked but nothing is leased; enabling while visible leases', () async {
      make(enabled: false);
      start();
      await idle();
      expect(backend.begun, isEmpty);
      activity.enabled = true;
      await idle();
      expect(backend.begun, hasLength(1));
      activity.enabled = false;
      await idle();
      expect(backend.ended, hasLength(1), reason: 'turning it off releases the lease');
    });

    test('nothing at all on other platforms', () async {
      make(platform: BackgroundPlatform.other);
      start().end(RunOutcome.completed);
      await idle();
      expect(backend.begun, isEmpty);
      expect(activity.supported, isFalse);
    });
  });

  group('long leases', () {
    test('an agent run the user continued asks for a long lease from the start', () async {
      make();
      start(long: true);
      await idle();
      expect(backend.begun.single.long, isTrue, reason: 'specialUse / BGContinuedProcessingTask');
    });

    test('a reply that turns into an agent run is upgraded while Sherpa is visible', () async {
      make();
      final run = start();
      await idle();
      run
        ..update(phase: RunActivityPhase.usingTool, step: 1)
        ..markLong();
      await idle();
      expect(backend.begun.map((r) => r.long), [false, true]);
      expect(backend.ended, [backend.begun.first.id], reason: 'the short lease goes once the long one holds');
      expect(backend.begun.last.reason, 'Step 1 · Using a tool');
    });

    test('no upgrade from the background: the short lease stays', () async {
      make();
      final run = start();
      await idle();
      fg.foreground = false;
      run.markLong();
      await idle();
      expect(backend.begun, hasLength(1));
      expect(backend.ended, isEmpty);
    });

    test('iOS: continued processing is requested with the agentrun prefix and reports progress', () async {
      make(platform: BackgroundPlatform.ios);
      final run = start(long: true);
      await idle();
      expect(backend.begun.single.iosContinuedTaskIdentifier, startsWith('$kAgentRunTaskPrefix.'));
      run.update(step: 2, phase: RunActivityPhase.working);
      await idle();
      expect(backend.updates.last.text, 'Step 2 · Writing');
      expect(backend.updates.last.progress, closeTo(0.5, 1e-9), reason: 'iOS ends stalled-looking tasks first');
    });
  });

  group('expiry', () {
    test('in the background: the run is asked to stop with a checkpoint, then shows as paused', () async {
      make();
      final run = start();
      await idle();
      fg.foreground = false;
      backend.emit(SignalKind.leaseExpired, leaseId: backend.begun.single.id, detail: 'timeout');
      await idle();
      expect(expired, ['s1:timeout']);
      expect(run.expired, isTrue);
      // The chat cancels the run (RunOutcome.cancelled with a checkpoint).
      run.end(RunOutcome.cancelled);
      await idle();
      expect(activity.wasPausedInBackground('s1'), isTrue);
      expect(activity.snapshot.chats, {'s1': ChatActivityState.pausedInBackground});
      expect(backend.notices.single.title, 'Paused in “Trip plan”');
      // Continuing (a new run in that chat) clears it.
      start();
      expect(activity.wasPausedInBackground('s1'), isFalse);
    });

    test('while Sherpa is visible again: a new lease instead of stopping anything', () async {
      make();
      start();
      await idle();
      backend.emit(SignalKind.leaseExpired, leaseId: backend.begun.single.id, detail: 'timeout');
      await idle();
      expect(expired, isEmpty);
      expect(backend.begun, hasLength(2));
      expect(activity.snapshot.leased, isTrue);
    });
  });

  group('runs that pause in the background', () {
    test('iPhone on-device (llama.cpp, MLX): "Paused: open Sherpa to continue", never stopped by an expiry', () async {
      make(platform: BackgroundPlatform.ios);
      final run = start(provider: localProviderId, long: true);
      await idle();
      expect(run.pausesInBackground, isTrue);
      expect(backend.begun.single.long, isFalse, reason: 'no Live Activity pretending to make progress');
      fg.foreground = false;
      await idle();
      expect(backend.updates.last.text, kPausedOpenSherpa);
      expect(activity.snapshot.chats['s1'], ChatActivityState.waitingForApp);
      backend.emit(SignalKind.leaseExpired, leaseId: backend.begun.single.id, detail: 'background time expired');
      await idle();
      expect(expired, isEmpty, reason: 'it continues when Sherpa is back');
      fg.foreground = true;
      await idle();
      expect(backend.begun, hasLength(2), reason: 'visible again: leased again');
      expect(activity.snapshot.chats['s1'], ChatActivityState.running);
      expect(start(session: 's2', provider: mlxProviderId).pausesInBackground, isTrue);
      expect(start(session: 's3', provider: appleFmProviderId).pausesInBackground, isFalse,
          reason: 'Apple Intelligence runs out of process');
      expect(start(session: 's4', provider: 'cloud').pausesInBackground, isFalse);
    });

    test('Android keeps llama.cpp going; Gemini Nano waits, and the lease is released early', () async {
      make();
      expect(start(session: 'l', provider: localProviderId).pausesInBackground, isFalse);
      activity.dispose();
      backend = FakePlatformBackend();
      make();
      final nano = start(provider: geminiNanoProviderId);
      await idle();
      fg.foreground = false;
      await idle();
      expect(backend.updates.last.text, kPausedOpenSherpa);
      nano.update(phase: RunActivityPhase.waitingForApp);
      await idle();
      expect(backend.ended, [backend.begun.single.id], reason: 'nothing left to keep alive');
      expect(backend.notices.single.title, 'Paused in “Trip plan”');
      expect(backend.notices.single.text, 'The reply continues when Sherpa is on screen.');
    });
  });

  group('finished while away', () {
    test('Android: "Reply ready in …" with no message content, then the lease ends', () async {
      make();
      final run = start();
      await idle();
      fg.foreground = false;
      run.end(RunOutcome.completed);
      await idle();
      final n = backend.notices.single;
      expect(n.title, 'Reply ready in “Trip plan”');
      expect(n.text, 'Open Sherpa to read it.');
      expect(n.tag, 's1', reason: 'one per chat');
      expect(backend.ended, hasLength(1));
      expect(backend.updates.where((u) => u.text == n.title), isEmpty, reason: 'posted, so no last words needed');
      fg.foreground = true;
      await idle();
      expect(backend.clearedNotices, 1, reason: 'back on screen: stale notices go');
    });

    test('iOS (no notices): the lease ends with "Reply ready" as its last text', () async {
      backend.finishedNoticesSupported = false;
      make(platform: BackgroundPlatform.ios);
      final run = start(long: true);
      await idle();
      fg.foreground = false;
      run.end(RunOutcome.completed);
      await idle();
      expect(backend.notices, isEmpty);
      expect(backend.updates.last.text, 'Reply ready in “Trip plan”');
      expect(backend.updates.last.progress, 1.0);
      expect(backend.ended, hasLength(1));
    });

    test('while visible, or stopped by the user: no notice', () async {
      make();
      start().end(RunOutcome.completed);
      await idle();
      final b = start(session: 's2');
      await idle();
      fg.foreground = false;
      b.end(RunOutcome.cancelled);
      await idle();
      expect(backend.notices, isEmpty);
    });

    test('copy for every outcome', () {
      expect(finishedNotice(RunOutcome.maxSteps, 'Trip', paused: false)!.title, 'Sherpa paused in “Trip” to check in');
      expect(finishedNotice(RunOutcome.failed, 'Trip', paused: false)!.title, "A reply in “Trip” didn't finish");
      expect(finishedNotice(RunOutcome.completed, defaultSessionTitle, paused: false)!.title, 'Reply ready');
      expect(finishedNotice(RunOutcome.cancelled, 'Trip', paused: false), isNull);
      expect(quotedChatTitle('a' * 60), hasLength(kNotificationTitleChars + 2));
      expect(leaseTitle(['A', 'B']), 'Sherpa is finishing replies in 2 chats');
      expect(leaseText(step: 3, phase: RunActivityPhase.awaitingApproval, paused: false),
          'Waiting for your approval: open Sherpa to decide');
      expect(expectedChatTitle(defaultSessionTitle, '  plan   a trip '), 'plan a trip');
      expect(expectedChatTitle('Kept', 'other'), 'Kept');
      expect(expectedChatTitle(defaultSessionTitle, 'x' * 80), hasLength(58));
    });
  });

  group('notifications permission (Android 13+)', () {
    test('the first run asks once; Allow shows the system dialog', () async {
      backend.notifications = false;
      make(notificationsAsked: false);
      start();
      await idle();
      expect(activity.snapshot.askForNotifications, isTrue);
      expect(backend.permissionRequests, 0, reason: 'the chat explains first');
      expect(await activity.answerNotificationPrompt(allow: true), isTrue);
      expect(backend.permissionRequests, 1);
      expect(asked, 1, reason: 'persisted: never asked again');
      expect(activity.snapshot.askForNotifications, isFalse);
      backend.notifications = false;
      start(session: 's2');
      await idle();
      expect(activity.snapshot.askForNotifications, isFalse);
    });

    test('Not now is remembered and shows no dialog', () async {
      backend.notifications = false;
      make(notificationsAsked: false);
      start();
      await idle();
      expect(await activity.answerNotificationPrompt(allow: false), isFalse);
      expect(backend.permissionRequests, 0);
      expect(asked, 1);
      expect(activity.snapshot.askForNotifications, isFalse);
    });

    test('no prompt when already permitted, on iOS, or when the setting is off', () async {
      make(notificationsAsked: false);
      start();
      await idle();
      expect(activity.snapshot.askForNotifications, isFalse);
      activity.dispose();
      backend.notifications = false;
      make(platform: BackgroundPlatform.ios, notificationsAsked: false);
      start();
      await idle();
      expect(activity.snapshot.askForNotifications, isFalse);
      activity.dispose();
      make(enabled: false, notificationsAsked: false);
      start();
      await idle();
      expect(activity.snapshot.askForNotifications, isFalse);
    });
  });

  test('changes are announced for the UI', () async {
    make();
    final events = <void>[];
    final sub = activity.changes.listen(events.add);
    start().end(RunOutcome.completed);
    await idle();
    expect(events, isNotEmpty);
    await sub.cancel();
  });

  test('a refused lease leaves the run running and nothing to end', () async {
    backend.onBeginLease = (r) =>
        LeaseResult(id: r.id, mode: LeaseMode.none, granted: false, error: 'NotAllowed', notificationsVisible: false);
    make();
    final run = start();
    await idle();
    expect(activity.snapshot.leased, isFalse);
    run.end(RunOutcome.completed);
    await idle();
    expect(backend.ended, isEmpty);
  });
}
