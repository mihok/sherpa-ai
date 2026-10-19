import 'dart:async';

import 'package:sherpa_core/sherpa_core.dart';

import '../backend.dart';
import '../messages.pigeon.dart';
import 'foreground.dart';
import 'pressure_policy.dart';
import 'pressure_tracker.dart';

/// [MemoryMonitor] backed by the OS (sherpa_core contract, PLAN §2).
///
/// - **Push first.** OS signals (trim, memory warning, dispatch pressure,
///   thermal, power) arrive over the Pigeon event channel and are folded in by
///   [PressureTracker] under [PressurePolicy].
/// - **Coalesced.** A burst of signals (Android sends UI_HIDDEN then
///   BACKGROUND; iOS posts a memory warning and a critical dispatch event
///   together) produces one fresh sample after [coalesceWindow]. An
///   escalation is published at once, before that sample, because the OS may
///   be about to kill the process.
/// - **Hysteresis.** Lower levels are published only after
///   [PressurePolicy.downgradeDelay], so contexts are not shrunk and regrown
///   on flapping readings.
/// - **Periodic sampling only while listened and in the foreground**
///   ([sampleInterval], 2 s by default). Nothing runs without listeners; in
///   the background only signals (and one sample on the transition) update
///   the state, so a backgrounded app does not wake up every 2 s.
///
/// [sample] works without listeners (admission control right before a model
/// load) and never throws: on a platform error it returns [current] and
/// records [lastError].
final class PlatformMemoryMonitor implements MemoryMonitor {
  PlatformMemoryMonitor({
    PlatformBackend? backend,
    ForegroundSource? foreground,
    PressurePolicy policy = const PressurePolicy(),
    this.sampleInterval = const Duration(seconds: 2),
    this.coalesceWindow = const Duration(milliseconds: 250),
    Clock clock = const SystemClock(),
  })  : _backend = backend ?? SherpaPlatform.backend,
        _foreground = foreground ?? WidgetsForegroundSource(),
        _clock = clock,
        _tracker = PressureTracker(policy);

  final PlatformBackend _backend;
  final ForegroundSource _foreground;
  final Clock _clock;
  final PressureTracker _tracker;
  final Duration sampleInterval;
  final Duration coalesceWindow;

  MemoryState _current = MemoryState.unknown;
  Object? _lastError;
  Future<MemoryState>? _inFlight;
  StreamSubscription<PlatformSignal>? _signalSub;
  StreamSubscription<bool>? _foregroundSub;
  Timer? _periodic;
  Timer? _coalesce;
  Timer? _deadline;
  bool _disposed = false;

  late final StreamController<MemoryState> _controller =
      StreamController.broadcast(onListen: _start, onCancel: _stop);

  PressurePolicy get policy => _tracker.policy;

  /// The last platform error from [sample], if any.
  Object? get lastError => _lastError;

  @override
  MemoryState get current => _current;

  @override
  Stream<MemoryState> get changes => _controller.stream;

  @override
  Future<MemoryState> sample() => _inFlight ??= _sampleOnce().whenComplete(() => _inFlight = null);

  Future<MemoryState> _sampleOnce() async {
    try {
      final s = await _backend.sampleMemory();
      _lastError = null;
      if (_disposed) return _current;
      // Without listeners no lifecycle subscription exists; read it now so
      // the limiter budget matches the UI state.
      if (!_controller.hasListener) _tracker.onForeground(_foreground.isForeground);
      _tracker.onSample(s);
      _publish();
    } catch (e) {
      _lastError = e;
    }
    return _current;
  }

  void _start() {
    _tracker.onForeground(_foreground.isForeground);
    _signalSub = _backend.signals().listen(_onSignal, onError: (Object e) => _lastError = e);
    _foregroundSub = _foreground.changes.listen(_onForeground);
    unawaited(sample());
    if (_tracker.foreground) _startPeriodic();
  }

  Future<void> _stop() async {
    _periodic?.cancel();
    _coalesce?.cancel();
    _deadline?.cancel();
    _periodic = _coalesce = _deadline = null;
    // Null the fields before awaiting so a re-listen during the await
    // starts fresh subscriptions instead of losing them.
    final cancels = [_signalSub?.cancel(), _foregroundSub?.cancel()];
    _signalSub = null;
    _foregroundSub = null;
    await Future.wait(cancels.nonNulls);
  }

  void _startPeriodic() {
    _periodic?.cancel();
    _periodic = Timer.periodic(sampleInterval, (_) => unawaited(sample()));
  }

  void _onForeground(bool foreground) {
    _tracker.onForeground(foreground);
    if (foreground) {
      _startPeriodic();
    } else {
      _periodic?.cancel();
      _periodic = null;
    }
    // One sample on every transition: the limiter budget and the trim
    // interpretation both depend on visibility.
    unawaited(sample());
  }

  void _onSignal(PlatformSignal signal) {
    if (signal.kind == SignalKind.leaseExpired) return;
    final now = _clock.now();
    _tracker.onSignal(signal, now);
    // Becoming critical is published at once (the OS may kill us next);
    // everything else in a burst is coalesced into one trailing update that
    // also carries fresh byte figures.
    final next = _tracker.evaluate(now);
    final urgent = (next.pressure == MemoryPressure.critical && _current.pressure != MemoryPressure.critical) ||
        (next.thermal == ThermalLevel.critical && _current.thermal != ThermalLevel.critical);
    if (urgent) _publish();
    _coalesce ??= Timer(coalesceWindow, () {
      _coalesce = null;
      unawaited(sample().then((_) => _publish()));
    });
  }

  /// Recomputes the state and emits it when anything but `source` changed.
  void _publish() {
    if (_disposed) return;
    final now = _clock.now();
    final next = _tracker.evaluate(now);
    if (!_sameState(next, _current)) {
      _current = next;
      if (_controller.hasListener) _controller.add(next);
    } else {
      _current = next;
    }
    _scheduleDeadline(now);
  }

  void _scheduleDeadline(DateTime now) {
    _deadline?.cancel();
    _deadline = null;
    final at = _tracker.nextDeadline(now);
    if (at == null || !_controller.hasListener) return;
    // +1 ms so the hold has strictly expired when we re-evaluate.
    _deadline = Timer(at.difference(now) + const Duration(milliseconds: 1), _publish);
  }

  static bool _sameState(MemoryState a, MemoryState b) =>
      a.pressure == b.pressure &&
      a.thermal == b.thermal &&
      a.lowPowerMode == b.lowPowerMode &&
      a.availableBytes == b.availableBytes &&
      a.totalBytes == b.totalBytes &&
      a.appFootprintBytes == b.appFootprintBytes;

  /// Stops sampling and closes [changes].
  Future<void> dispose() async {
    _disposed = true;
    await _stop();
    await _controller.close();
  }
}
