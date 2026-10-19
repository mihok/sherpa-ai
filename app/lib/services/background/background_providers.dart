import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sherpa_platform/sherpa_platform.dart';

import '../../state/ui_preferences.dart';
import 'run_activity.dart';

/// Which platform's background rules apply (tests pick one).
final backgroundPlatformProvider = Provider<BackgroundPlatform>((ref) => BackgroundPlatform.current);

/// The plugin's lease API. The default talks to the platform plugin on
/// Android/iOS and refuses everything elsewhere; tests pass a
/// `FakePlatformBackend`.
final backgroundRunGuardProvider = Provider<BackgroundRunGuard>(
  (ref) => BackgroundRunGuard(
    iosContinuedTaskPrefix: kAgentRunTaskPrefix,
    androidChannelName: 'Replies in progress',
    androidFinishedChannelName: 'Finished replies',
  ),
);

/// Whether Sherpa is on screen, for [RunActivity].
final backgroundForegroundProvider = Provider<ForegroundSource>((ref) => WidgetsForegroundSource());

/// The app's one [RunActivity]: every chat registers its runs here. Lives
/// as long as the app (a rebuild would forget runs in flight), so its
/// inputs are read once and the setting is followed with a listener.
final runActivityProvider = Provider<RunActivity>((ref) {
  final settings = ref.read(uiSettingsProvider);
  final activity = RunActivity(
    guard: ref.read(backgroundRunGuardProvider),
    foreground: ref.read(backgroundForegroundProvider),
    platform: ref.read(backgroundPlatformProvider),
    enabled: settings.backgroundRuns,
    notificationsAsked: settings.backgroundNotificationsAsked,
    onNotificationsAsked: () => unawaited(
      ref.read(uiSettingsProvider.notifier).update((s) => s.copyWith(backgroundNotificationsAsked: true)),
    ),
  );
  ref.listen(uiSettingsProvider.select((s) => s.backgroundRuns), (_, on) => activity.enabled = on);
  ref.onDispose(activity.dispose);
  return activity;
});

/// [RunActivity.snapshot], live: which chats run, wait or were paused by
/// the background, and whether to ask about notifications.
final runActivitySnapshotProvider = Provider<RunActivitySnapshot>((ref) {
  final activity = ref.watch(runActivityProvider);
  final sub = activity.changes.listen((_) => ref.invalidateSelf());
  ref.onDispose(sub.cancel);
  return activity.snapshot;
});

/// One chat's background state (null: nothing running or paused).
final chatActivityProvider = Provider.family<ChatActivityState?, String>(
  (ref, sessionId) => ref.watch(runActivitySnapshotProvider.select((s) => s.chats[sessionId])),
);
