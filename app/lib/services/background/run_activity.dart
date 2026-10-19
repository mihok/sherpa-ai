import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:sherpa_core/sherpa_core.dart' show RunOutcome;
import 'package:sherpa_platform/sherpa_platform.dart';

import '../../state/services.dart' show localProviderId;
import '../inference/on_device_ids.dart' show isForegroundOnlyProvider, mlxProviderId;
import 'background_copy.dart';

export 'background_copy.dart' show RunActivityPhase;

/// `<bundle id>.<context>` for iOS continued-processing tasks; the app's
/// Info.plist permits `io.github.mihok.sherpa.agentrun.*`.
const String kAgentRunTaskPrefix = 'io.github.mihok.sherpa.agentrun';

/// The reason a chat cancels its run with when the OS ended the background
/// time ([BackgroundRun] `onExpired`): the runner checkpoints the cancelled
/// run and the chat offers to continue it.
const String kBackgroundPauseReason = 'paused: background time ended';

/// Which operating system's rules apply.
enum BackgroundPlatform {
  android,
  ios,

  /// Host tests, desktop: nothing is leased, runs are only tracked.
  other;

  static BackgroundPlatform get current => Platform.isAndroid
      ? BackgroundPlatform.android
      : Platform.isIOS
          ? BackgroundPlatform.ios
          : BackgroundPlatform.other;
}

/// What a chat's run looks like from outside the chat (home, the chat
/// when it is reopened).
enum ChatActivityState {
  /// A run is in flight.
  running,

  /// In flight, but it can't go on until Sherpa is on screen: on-device
  /// GPU inference on iPhone, Gemini Nano.
  waitingForApp,

  /// The OS ended Sherpa's background time, so the run was checkpointed
  /// and stopped: "Paused when the app was in the background; tap to
  /// continue".
  pausedInBackground,
}

@immutable
final class RunActivitySnapshot {
  const RunActivitySnapshot({this.chats = const {}, this.askForNotifications = false, this.leased = false});

  /// Chats with a run in flight or paused by the background, by session id.
  final Map<String, ChatActivityState> chats;

  /// Show the "allow notifications" prompt (Android 13+, asked once).
  final bool askForNotifications;

  /// A background lease is held now.
  final bool leased;
}

/// Keeps agent runs alive when the user leaves Sherpa, across every chat.
///
/// Each chat registers a run when it starts ([start]) and ends it with its
/// outcome ([BackgroundRun.end]). The policy (docs/PLAN.md §7 decision 2,
/// R06 §6, R07 §4):
///
/// * **One lease for all runs**, begun when a run starts *while Sherpa is
///   visible* (Android refuses to start a foreground service from the
///   background; iOS continued-processing tasks must follow a user action)
///   and ended when the last run ends. A run that starts in the background
///   gets no lease of its own.
/// * **Short or long.** `long: false` (Android `shortService`, ~3 min; iOS
///   `beginBackgroundTask`, ~30 s) to finish a reply; `long: true` (Android
///   `specialUse`; iOS 26+ `BGContinuedProcessingTask` with its Live
///   Activity) once a run is an agent run: it called a tool or reached a
///   second step, or the user explicitly continued one. A short lease is
///   upgraded while Sherpa is still visible; afterwards it stays short.
/// * **Pausing runs.** On iPhone, llama.cpp and MLX pause in the
///   background (Metal refuses background GPU work; the inference
///   lifecycle checkpoints and waits), and Gemini Nano refuses background
///   use. Their text says [kPausedOpenSherpa] instead of pretending to
///   continue, they never ask for a long lease, an expiry leaves them be
///   (they continue when Sherpa is back), and when every run waits the
///   lease is released early.
/// * **Expiry.** When the OS ends the lease while Sherpa is away, every
///   other run's `onExpired` fires: the chat cancels it with a checkpoint
///   ([kBackgroundPauseReason]) and offers to continue. While Sherpa is
///   visible again, a new lease is begun instead.
/// * **Finished while away.** A run that ends while Sherpa is in the
///   background posts a notice ("Reply ready in “Trip”", no message
///   content) where the platform can (Android, permitted); otherwise the
///   lease ends with that as its last text (iOS Live Activity).
/// * **Notifications permission** (Android 13+): the first run that could
///   need it raises [RunActivitySnapshot.askForNotifications]; the chat
///   explains and [answerNotificationPrompt] shows the system dialog.
///
/// Disabled ([enabled] false: the "Keep working in the background"
/// setting), runs are still tracked but nothing is leased.
final class RunActivity {
  RunActivity({
    required BackgroundRunGuard guard,
    required ForegroundSource foreground,
    required this.platform,
    bool enabled = true,
    bool notificationsAsked = false,
    this.onNotificationsAsked,
  })  : _guard = guard,
        _foreground = foreground,
        _enabled = enabled,
        _asked = notificationsAsked {
    if (supported) {
      _visible = _foreground.isForeground;
      _foregroundSub = _foreground.changes.listen(_onForeground);
    }
  }

  final BackgroundRunGuard _guard;
  final ForegroundSource _foreground;
  final BackgroundPlatform platform;

  /// Persists that the notifications prompt was answered.
  final void Function()? onNotificationsAsked;

  StreamSubscription<bool>? _foregroundSub;
  final StreamController<void> _changes = StreamController<void>.broadcast();
  final List<BackgroundRun> _runs = [];
  final Set<String> _paused = {};

  bool _enabled;
  bool _asked;
  bool _ask = false;
  bool _visible = true;
  bool _disposed = false;

  BackgroundLease? _lease;
  bool _leaseLong = false;
  Future<void> _ops = Future<void>.value();

  /// Leases exist on this platform at all.
  bool get supported => platform != BackgroundPlatform.other;

  /// The "Keep working in the background" setting.
  bool get enabled => _enabled;

  set enabled(bool value) {
    if (value == _enabled) return;
    _enabled = value;
    if (!value) {
      _ask = false;
      _serial(_endLease);
    } else {
      _serial(_ensureLease);
    }
    _emit();
  }

  /// Sherpa is on screen (always true where nothing is leased).
  bool get appVisible => _visible;

  /// Emits after every change of [snapshot].
  Stream<void> get changes => _changes.stream;

  RunActivitySnapshot get snapshot => RunActivitySnapshot(
        chats: {
          for (final id in _paused) id: ChatActivityState.pausedInBackground,
          for (final r in _runs)
            if (!r._expired) r.sessionId: r._waiting ? ChatActivityState.waitingForApp : ChatActivityState.running,
        },
        askForNotifications: _ask,
        leased: _lease?.isActive ?? false,
      );

  /// The run in [sessionId] was stopped because Sherpa's background time
  /// ended (and nothing ran there since).
  bool wasPausedInBackground(String sessionId) => _paused.contains(sessionId);

  /// Forgets that [sessionId] was paused (the user continued or dismissed).
  void clearPaused(String sessionId) {
    if (_paused.remove(sessionId)) _emit();
  }

  /// Completes when every lease operation queued so far is done (tests).
  @visibleForTesting
  Future<void> get idle => _ops;

  /// Registers a run that starts now. [long]: an agent run the user
  /// explicitly continued (see the class docs). [onExpired] stops the run
  /// with a checkpoint when the OS ends the background time first.
  BackgroundRun start({
    required String sessionId,
    required String title,
    required String providerId,
    bool long = false,
    required void Function(String reason) onExpired,
  }) {
    final run = BackgroundRun._(this, sessionId, title, providerId, long, onExpired);
    _runs.add(run);
    _paused.remove(sessionId);
    if (_enabled && supported) {
      _serial(_ensureLease);
      if (platform == BackgroundPlatform.android && !_asked && !_ask && _visible) unawaited(_checkNotifications());
    }
    _emit();
    return run;
  }

  /// The user answered the notifications prompt: [allow] shows the system
  /// dialog (Android 13+). Returns whether notifications are permitted.
  Future<bool> answerNotificationPrompt({required bool allow}) async {
    _ask = false;
    if (!_asked) {
      _asked = true;
      onNotificationsAsked?.call();
    }
    _emit();
    if (!allow) return false;
    return _guard.requestNotificationsPermission();
  }

  /// Notifications are permitted (Android: POST_NOTIFICATIONS and enabled).
  Future<bool> notificationsPermitted() async {
    try {
      return await _guard.notificationsPermitted();
    } on Object {
      return false;
    }
  }

  /// Shows the system dialog now (the settings switch, a user action).
  Future<bool> requestNotifications() => answerNotificationPrompt(allow: true);

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_foregroundSub?.cancel());
    final lease = _lease;
    _lease = null;
    unawaited(lease?.end());
    unawaited(_changes.close());
  }

  // ---------------------------------------------------------------------------

  Future<void> _checkNotifications() async {
    final permitted = await notificationsPermitted();
    if (permitted || _asked || _disposed || !_enabled) return;
    _ask = true;
    _emit();
  }

  /// iPhone GPU inference (llama.cpp, MLX) and Gemini Nano can't run in
  /// the background; Apple Intelligence runs out of process and continues.
  bool _pausesInBackground(String providerId) =>
      isForegroundOnlyProvider(providerId) ||
      (platform == BackgroundPlatform.ios && (providerId == localProviderId || providerId == mlxProviderId));

  bool get _wantLong => _runs.any((r) => r._long && !r.pausesInBackground && !r._expired);

  void _serial(Future<void> Function() body) {
    _ops = _ops.then((_) => _disposed ? null : body()).catchError((Object e) {
      debugPrint('Background runs: ${e.runtimeType}');
    });
  }

  /// Begins (or upgrades to long) the lease for the current runs; only
  /// while Sherpa is visible.
  Future<void> _ensureLease() async {
    final live = _runs.where((r) => !r._expired).toList();
    if (!_enabled || !supported || live.isEmpty || !_visible) return;
    final long = _wantLong;
    final current = _lease;
    if (current != null && current.isActive && (_leaseLong || !long)) return _pushText();
    final lease = await _guard.begin(title: leaseTitle([for (final r in live) r._title]), reason: _text(), long: long);
    if (!lease.isActive) {
      debugPrint('Background lease refused: ${lease.error}');
      return;
    }
    _lease = lease;
    _leaseLong = long;
    unawaited(lease.expired.then((why) => _onExpired(lease, why)));
    // An upgrade: the long lease is in place before the short one goes.
    await current?.end();
    if (_runs.every((r) => r._expired) || !_enabled) await _endLease();
    _emit();
  }

  Future<void> _endLease({String? finalText}) async {
    final lease = _lease;
    _lease = null;
    _leaseLong = false;
    if (lease == null) return;
    await lease.end(text: finalText, progress: finalText == null ? null : 1);
    _emit();
  }

  /// What the lease says now: the newest run that isn't stopped.
  String _text() {
    final live = _runs.where((r) => !r._expired).toList();
    if (live.isEmpty) return '';
    final r = live.last;
    final text = leaseText(step: r._step, phase: r._phase, paused: !_visible && r.pausesInBackground);
    final q = live.length > 1 ? quotedChatTitle(r._title) : null;
    return q == null ? text : '$q: $text';
  }

  /// iOS ranks continued-processing tasks with little progress first for
  /// termination, so a step count becomes a creeping fraction there; on
  /// Android the bar stays indeterminate.
  double? _progress() {
    if (platform != BackgroundPlatform.ios || !_leaseLong) return null;
    final step = _runs.isEmpty ? 0 : _runs.map((r) => r._step).reduce(math.max);
    return step <= 0 ? null : step / (step + 2);
  }

  Future<void> _pushText() async {
    final lease = _lease;
    if (lease == null || !lease.isActive) return;
    await lease.update(text: _text(), progress: _progress());
  }

  void _onExpired(BackgroundLease lease, String why) {
    if (!identical(lease, _lease) || _disposed) return;
    _lease = null;
    _leaseLong = false;
    if (_visible) {
      // Sherpa is on screen again: nothing needs stopping.
      _serial(_ensureLease);
      _emit();
      return;
    }
    for (final r in [..._runs]) {
      if (r._expired) continue;
      if (r.pausesInBackground || r._phase == RunActivityPhase.waitingForApp) {
        r._waiting = true; // continues when Sherpa is back
        continue;
      }
      r._expired = true;
      try {
        r._onExpired(why);
      } on Object catch (e) {
        debugPrint('Background runs: expiry handler failed (${e.runtimeType})');
      }
    }
    _emit();
  }

  void _onForeground(bool visible) {
    if (visible == _visible || _disposed) return;
    _visible = visible;
    if (visible) {
      for (final r in _runs) {
        r._waiting = false;
      }
      unawaited(_guard.clearFinishedNotices());
      _serial(_ensureLease);
    } else {
      for (final r in _runs) {
        if (r.pausesInBackground) r._waiting = true;
      }
      _serial(() async {
        await _pushText();
        await _releaseIfAllWaiting();
      });
    }
    _emit();
  }

  /// Every run waits for Sherpa: holding the lease keeps nothing alive.
  /// The waiting runs say so in a notice instead.
  Future<void> _releaseIfAllWaiting() async {
    final live = _runs.where((r) => !r._expired).toList();
    if (_visible || _lease == null || live.isEmpty || !live.every((r) => r._phase == RunActivityPhase.waitingForApp)) {
      return;
    }
    var posted = false;
    for (final r in live) {
      final n = waitingNotice(r._title);
      posted = await _guard.notifyFinished(tag: r.sessionId, title: n.title, text: n.text) || posted;
    }
    await _endLease(finalText: posted ? null : kPausedOpenSherpa);
  }

  void _runEnded(BackgroundRun run, RunOutcome outcome) {
    _runs.remove(run);
    final paused = run._expired && outcome == RunOutcome.cancelled;
    if (paused) _paused.add(run.sessionId);
    _emit();
    final away = !_visible && supported && _enabled;
    final notice = away ? finishedNotice(outcome, run._title, paused: paused) : null;
    _serial(() async {
      var posted = false;
      if (notice != null) {
        posted = await _guard.notifyFinished(tag: run.sessionId, title: notice.title, text: notice.text);
      }
      if (_runs.every((r) => r._expired)) {
        await _endLease(finalText: notice != null && !posted ? notice.title : null);
      } else {
        await _pushText();
        await _releaseIfAllWaiting();
      }
    });
  }

  void _changed(BackgroundRun run, {bool upgrade = false}) {
    if (!_enabled || !supported) return;
    _serial(() async {
      if (upgrade && _visible && !_leaseLong) {
        await _ensureLease();
      } else {
        await _pushText();
      }
      await _releaseIfAllWaiting();
    });
  }

  void _emit() {
    if (!_disposed) _changes.add(null);
  }
}

/// One registered run (see [RunActivity.start]).
final class BackgroundRun {
  BackgroundRun._(this._activity, this.sessionId, this._title, this.providerId, this._long, this._onExpired);

  final RunActivity _activity;
  final String sessionId;
  final String providerId;
  final void Function(String reason) _onExpired;

  String _title;
  bool _long;
  int _step = 0;
  RunActivityPhase _phase = RunActivityPhase.working;
  bool _expired = false;
  bool _waiting = false;
  bool _ended = false;

  /// It pauses while Sherpa is in the background instead of continuing.
  bool get pausesInBackground => _activity._pausesInBackground(providerId);

  /// The OS ended the background time and [_onExpired] asked the chat to
  /// stop this run.
  bool get expired => _expired;

  /// Wants a long lease (see [RunActivity]).
  bool get long => _long;

  /// The chat was (re)named.
  set title(String value) {
    if (value == _title || value.trim().isEmpty || quotedChatTitle(value) == null) return;
    _title = value;
    _activity._changed(this);
  }

  /// The run reached [step] and/or is now doing [phase].
  void update({int? step, RunActivityPhase? phase}) {
    if (_ended) return;
    final s = step ?? _step;
    final p = phase ?? _phase;
    if (s == _step && p == _phase) return;
    _step = s;
    _phase = p;
    if (p != RunActivityPhase.waitingForApp && _activity.appVisible) _waiting = false;
    if (p == RunActivityPhase.waitingForApp && !_activity.appVisible) _waiting = true;
    _activity._changed(this);
  }

  /// It turned out to be an agent run (a tool call, a second step): ask
  /// for a long lease while Sherpa is still visible.
  void markLong() {
    if (_long || _ended) return;
    _long = true;
    _activity._changed(this, upgrade: true);
  }

  /// The run ended with [outcome]. Idempotent.
  void end(RunOutcome outcome) {
    if (_ended) return;
    _ended = true;
    _activity._runEnded(this, outcome);
  }
}
