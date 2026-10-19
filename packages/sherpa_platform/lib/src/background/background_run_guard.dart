import 'dart:async';
import 'dart:math';

import '../backend.dart';
import '../messages.pigeon.dart';

/// Keeps the process (and its Dart isolate) alive while an agent reply or
/// run finishes after the user leaves the app.
///
/// **Android** (R07 §4): a foreground service in the main process with an
/// ongoing notification (ProgressStyle on API 36+). `long: false` →
/// `shortService` (~3 minutes, to finish the current reply); `long: true` →
/// `specialUse` (user-started agent runs). It must be started while the app
/// is visible: call [begin] when the run starts, not when the app pauses.
/// POST_NOTIFICATIONS (API 33+) is the app's to request; without it the
/// service still runs but its notification is only in the task manager
/// ([notificationsPermitted]).
///
/// **iOS** (R06 §6): `long: false` → `beginBackgroundTask` (seconds, not
/// minutes). `long: true` with [iosContinuedTaskPrefix] set → on iOS 26+ a
/// `BGContinuedProcessingTask` with a system Live Activity, else
/// `beginBackgroundTask`. Local GPU inference must still pause in the
/// background on iPhone (Metal refuses background command buffers); the
/// lease keeps the Dart loop, tools and remote calls going.
///
/// When the OS ends a lease first, [BackgroundLease.expired] completes and
/// the app should checkpoint and stop.
///
/// When a run finishes while the app is away, [notifyFinished] posts a
/// one-off notice on Android (iOS: unsupported, returns false; end the
/// lease with a final `text` so the Live Activity says it instead).
final class BackgroundRunGuard {
  BackgroundRunGuard({
    PlatformBackend? backend,
    this.iosContinuedTaskPrefix,
    this.iosRequestGpu = false,
    this.androidChannelName,
    this.androidFinishedChannelName,
    this.androidSmallIcon,
    this.updateInterval = const Duration(seconds: 1),
    Random? random,
  })  : _backend = backend ?? SherpaPlatform.backend,
        _random = random ?? Random.secure();

  final PlatformBackend _backend;
  final Random _random;

  /// `<bundle id>.<context>`; the Info.plist must permit
  /// `<bundle id>.<context>.*` in `BGTaskSchedulerPermittedIdentifiers`.
  /// Null disables the continued-processing path.
  final String? iosContinuedTaskPrefix;

  /// Ask for background GPU (`.gpu`) where `BGTaskScheduler.supportedResources`
  /// has it (M3+ iPads per Apple DTS; no iPhone) and the app has the
  /// Background GPU Access entitlement.
  final bool iosRequestGpu;

  /// User-visible notification channel name (Android).
  final String? androidChannelName;

  /// User-visible name of the channel [notifyFinished] posts on (Android).
  final String? androidFinishedChannelName;

  /// Drawable resource name for the notification's status-bar icon.
  final String? androidSmallIcon;

  /// [BackgroundLease.update] reaches the OS at most this often: Android
  /// drops notification updates beyond a few per second and the iOS Live
  /// Activity is rate-limited too.
  final Duration updateInterval;

  final Map<String, BackgroundLease> _leases = {};
  StreamSubscription<PlatformSignal>? _signals;

  /// Android: POST_NOTIFICATIONS granted and notifications enabled. iOS:
  /// always true (no notification is involved).
  Future<bool> notificationsPermitted() => _backend.notificationsPermitted();

  /// Android 13+: shows the system POST_NOTIFICATIONS dialog (call it after
  /// explaining why, from a user action) and completes with
  /// [notificationsPermitted]. Elsewhere it completes at once. Never throws.
  Future<bool> requestNotificationsPermission() async {
    try {
      return await _backend.requestNotificationsPermission();
    } on Object {
      return false;
    }
  }

  /// Posts a dismissible "finished" notice that opens the app (Android,
  /// when permitted); a notice with the same [tag] replaces the earlier
  /// one. Returns false when nothing was posted (iOS, no permission, a
  /// platform error). Put no message content in [title] or [text].
  Future<bool> notifyFinished({required String tag, required String title, required String text}) async {
    try {
      return await _backend.notifyRunFinished(
        FinishedNotice(tag: tag, title: title, text: text, androidChannelName: androidFinishedChannelName),
      );
    } on Object {
      return false;
    }
  }

  /// Removes the [notifyFinished] notices still showing (the app is back
  /// on screen). Never throws.
  Future<void> clearFinishedNotices() async {
    try {
      await _backend.clearFinishedNotices();
    } on Object {
      // Best effort.
    }
  }

  /// Starts a lease. Never throws for OS refusals: check
  /// [BackgroundLease.granted] and [BackgroundLease.error].
  Future<BackgroundLease> begin({required String title, required String reason, bool long = false}) async {
    final id = _newId();
    final lease = BackgroundLease._(this, id);
    // Registered before the native call so an early expiry is routed.
    _leases[id] = lease;
    _signals ??= _backend.signals().listen(_onSignal);
    final prefix = iosContinuedTaskPrefix;
    try {
      final result = await _backend.beginLease(LeaseRequest(
        id: id,
        title: title,
        reason: reason,
        long: long,
        androidChannelName: androidChannelName,
        androidSmallIcon: androidSmallIcon,
        iosContinuedTaskIdentifier: long && prefix != null ? '$prefix.$id' : null,
        iosRequestGpu: iosRequestGpu,
      ));
      lease._started(result);
    } catch (e) {
      lease._started(LeaseResult(id: id, mode: LeaseMode.none, granted: false, error: '$e', notificationsVisible: false));
    }
    if (!lease.isActive) await _forget(id);
    return lease;
  }

  void _onSignal(PlatformSignal s) {
    if (s.kind != SignalKind.leaseExpired) return;
    final lease = _leases[s.leaseId];
    if (lease == null) return;
    lease._expire(s.detail ?? 'expired');
    unawaited(_forget(lease.id));
  }

  Future<void> _forget(String id) async {
    _leases.remove(id);
    if (_leases.isEmpty) {
      final cancel = _signals?.cancel();
      _signals = null;
      await cancel;
    }
  }

  String _newId() => [for (var i = 0; i < 8; i++) _random.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
}

/// One background lease from [BackgroundRunGuard.begin].
final class BackgroundLease {
  BackgroundLease._(this._guard, this.id);

  final BackgroundRunGuard _guard;
  final String id;
  final Completer<String> _expired = Completer();

  LeaseMode _mode = LeaseMode.none;
  bool _granted = false;
  bool _active = false;
  String? _error;
  bool _notificationsVisible = false;

  Timer? _cooldown;
  ({double? progress, String? text})? _pending;

  /// Where the lease runs; [LeaseMode.none] when refused.
  LeaseMode get mode => _mode;

  /// The OS granted background time.
  bool get granted => _granted;

  /// Why it was refused or downgraded (e.g. continued processing unavailable
  /// → plain background task).
  String? get error => _error;

  /// Android: the notification is visible (POST_NOTIFICATIONS granted).
  bool get notificationsVisible => _notificationsVisible;

  /// Granted, not ended and not expired.
  bool get isActive => _active;

  /// Completes with the OS's reason when the OS ends the lease before [end]
  /// (shortService timeout, iOS expiration, task cancelled from the Live
  /// Activity). Never completes for a lease that was refused or ended
  /// normally.
  Future<String> get expired => _expired.future;

  void _started(LeaseResult r) {
    _mode = r.mode;
    _granted = r.granted;
    _error = r.error;
    _notificationsVisible = r.notificationsVisible;
    // An expiry may have raced ahead of the begin reply.
    _active = r.granted && !_expired.isCompleted;
  }

  void _expire(String reason) {
    _active = false;
    _cooldown?.cancel();
    _pending = null;
    if (!_expired.isCompleted) _expired.complete(reason);
  }

  /// Updates the notification / task title. [progress] is 0..1 (null =
  /// indeterminate). Throttled to [BackgroundRunGuard.updateInterval]; the
  /// latest values always win.
  Future<void> update({double? progress, String? text}) async {
    if (!_active) return;
    if (_cooldown != null) {
      _pending = (progress: progress, text: text);
      return;
    }
    _cooldown = Timer(_guard.updateInterval, _flush);
    await _guard._backend.updateLease(id, progress?.clamp(0.0, 1.0), text);
  }

  void _flush() {
    _cooldown = null;
    final p = _pending;
    _pending = null;
    if (p != null && _active) unawaited(update(progress: p.progress, text: p.text));
  }

  /// Releases the lease. Idempotent. A final [text] / [progress] is sent
  /// first, past the throttle (an iOS Live Activity shows it as the task
  /// completes); without them pending updates are dropped.
  Future<void> end({double? progress, String? text}) async {
    if (!_active) return;
    _active = false;
    _cooldown?.cancel();
    _cooldown = null;
    _pending = null;
    try {
      if (progress != null || text != null) {
        try {
          await _guard._backend.updateLease(id, progress?.clamp(0.0, 1.0), text);
        } on Object {
          // The end matters more than its last words.
        }
      }
      await _guard._backend.endLease(id);
    } finally {
      await _guard._forget(id);
    }
  }
}
