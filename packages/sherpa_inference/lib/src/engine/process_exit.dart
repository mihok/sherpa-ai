import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../lifecycle/forensics.dart';
import 'process_messages.pigeon.dart';

/// Why the `:inference` process ended (`ExitDecoder.classify` on the
/// Android side, over `ApplicationExitInfo`).
enum EngineExitKind {
  /// SIGSEGV/SIGABRT/... in native code; for the engine typically a
  /// GGML_ABORT (SIGABRT).
  nativeCrash,

  /// An uncaught Java/Kotlin exception in the service.
  crash,

  /// The low-memory killer (`REASON_LOW_MEMORY`).
  lowMemory,

  /// SIGKILL on a device without LMK reporting: almost always the LMK.
  likelyLowMemory,

  /// Android 17's per-app anonymous-memory limiter.
  memoryLimiter,
  signaled,
  anr,
  excessiveResourceUsage,
  exitSelf,
  userStopped,
  freezer,

  /// Package update, permission change, dependency death, ...
  system,
  other,
  unknown;

  static EngineExitKind byName(String name) => values.firstWhere((k) => k.name == name, orElse: () => unknown);

  bool get isMemoryKill => this == lowMemory || this == likelyLowMemory || this == memoryLimiter;
}

/// One `ApplicationExitInfo` of the `:inference` process (API 30+), with
/// the phase it recorded through `setProcessStateSummary` and a bounded,
/// redacted tombstone excerpt for native crashes (API 31+).
@immutable
final class EngineProcessExit {
  const EngineProcessExit({
    required this.pid,
    required this.reason,
    required this.reasonName,
    required this.kind,
    required this.status,
    required this.timestamp,
    this.details,
    this.importance,
    this.pssBytes,
    this.rssBytes,
    this.phase,
    this.summary,
    this.tombstone,
  });

  factory EngineProcessExit.fromMessage(ProcessExitMsg m) {
    final at = DateTime.fromMillisecondsSinceEpoch(m.timestampMs, isUtc: true);
    final summary = _decodeSummary(m.processStateSummary);
    return EngineProcessExit(
      pid: m.pid,
      reason: m.reason,
      reasonName: m.reasonName,
      kind: EngineExitKind.byName(m.classification),
      status: m.status,
      timestamp: at,
      details: m.details,
      importance: m.importance,
      pssBytes: m.pssBytes,
      rssBytes: m.rssBytes,
      summary: summary,
      phase: summary == null ? null : parseProcessSummary(summary, at: at),
      tombstone: m.tombstone,
    );
  }

  final int pid;

  /// `ApplicationExitInfo.REASON_*` and its name.
  final int reason;
  final String reasonName;
  final EngineExitKind kind;

  /// Exit code, or the signal number for signaled / native-crash exits.
  final int status;
  final DateTime timestamp;
  final String? details;
  final int? importance;
  final int? pssBytes;
  final int? rssBytes;

  /// What the engine was doing, from the process state summary.
  final PhaseRecord? phase;

  /// The raw summary string (`{"v":1,"p":...,"h":"proc"}`).
  final String? summary;
  final String? tombstone;

  /// "native crash (SIGABRT)", "killed by the system to free memory", ...
  String get description => switch (kind) {
        EngineExitKind.nativeCrash => 'native crash (${signalName(status)})',
        EngineExitKind.crash => 'crashed (uncaught exception)',
        EngineExitKind.lowMemory || EngineExitKind.likelyLowMemory => 'killed by the system to free memory',
        EngineExitKind.memoryLimiter => "killed by Android's per-app memory limit",
        EngineExitKind.signaled => 'killed by ${signalName(status)}',
        EngineExitKind.anr => 'stopped responding (ANR)',
        EngineExitKind.excessiveResourceUsage => 'killed for excessive resource use',
        EngineExitKind.exitSelf => 'exited (status $status)',
        EngineExitKind.userStopped => 'stopped by the user',
        EngineExitKind.freezer => 'killed while frozen',
        EngineExitKind.system => 'stopped by the system ($reasonName)',
        EngineExitKind.other || EngineExitKind.unknown => 'died ($reasonName${details == null ? '' : ': $details'})',
      };

  /// The tombstone's abort line or first frame, for one-line reports.
  String? get tombstoneHeadline {
    final t = tombstone;
    if (t == null) return null;
    final lines = t.split('\n');
    return lines.firstWhere((l) => l.startsWith('abort: '),
        orElse: () => lines.firstWhere((l) => l.startsWith('#00'), orElse: () => ''));
  }

  static String signalName(int signal) => switch (signal) {
        1 => 'SIGHUP',
        2 => 'SIGINT',
        3 => 'SIGQUIT',
        4 => 'SIGILL',
        5 => 'SIGTRAP',
        6 => 'SIGABRT',
        7 => 'SIGBUS',
        8 => 'SIGFPE',
        9 => 'SIGKILL',
        11 => 'SIGSEGV',
        13 => 'SIGPIPE',
        15 => 'SIGTERM',
        31 => 'SIGSYS',
        _ => 'signal $signal',
      };

  static String? _decodeSummary(Uint8List? bytes) {
    if (bytes == null || bytes.isEmpty) return null;
    return utf8.decode(bytes, allowMalformed: true);
  }
}

/// Parses the summary the service passes to `setProcessStateSummary`
/// (PhaseTracker.kt): `{"v":1,"p":"generating","m":"<tag>","c":4096,"k":"f16/f16","h":"proc"}`.
/// [PhaseRecord.modelId] is the short model tag, not the spec id.
PhaseRecord? parseProcessSummary(String summary, {required DateTime at}) {
  try {
    final j = (jsonDecode(summary) as Map).cast<String, Object?>();
    final p = j['p'];
    if (p is! String) return null;
    final phase = InferencePhase.values.firstWhere((v) => v.name == p, orElse: () => InferencePhase.idle);
    final c = j['c'];
    return PhaseRecord(
      phase: phase,
      at: at,
      modelId: j['m'] as String?,
      nCtx: c is num ? c.toInt() : null,
      kvLayout: j['k'] as String?,
    );
  } on Object {
    return null;
  }
}

/// One death of the `:inference` process, as reported on
/// [ProcessEngineHost.crashes] (and summarized in [EngineHostCrashed.reason]).
@immutable
final class EngineProcessCrash {
  const EngineProcessCrash({
    required this.epoch,
    required this.at,
    required this.recentCrashes,
    required this.gaveUp,
    this.pid,
    this.exit,
    this.engineMessage,
    this.transportDetail,
  });

  /// The epoch whose handles died.
  final int epoch;
  final DateTime at;
  final int? pid;

  /// Null when Android kept no record (API < 30, or it was not found in time).
  final EngineProcessExit? exit;

  /// The fatal ggml message the engine appended to its crash breadcrumb
  /// (`se_init_params.crash_breadcrumb_path`) right before aborting.
  final String? engineMessage;

  /// What the plugin observed ("the inference process died", ...).
  final String? transportDetail;

  /// Crashes inside the restart policy's window, this one included.
  final int recentCrashes;

  /// The crash loop limit was reached: no automatic restart.
  final bool gaveUp;

  PhaseRecord? get phase => exit?.phase;

  bool get isMemoryKill => exit?.kind.isMemoryKill ?? false;

  bool get isNativeCrash => (exit?.kind == EngineExitKind.nativeCrash) || (engineMessage?.isNotEmpty ?? false);

  /// One sentence: what happened, during which phase, and the engine's own
  /// message when it left one.
  String get reason {
    final b = StringBuffer('The on-device engine process ')
      ..write(exit?.description ?? (engineMessage != null ? 'aborted' : 'died (no exit record)'));
    final ph = phase;
    if (ph != null) b.write(' while ${_phaseText(ph)}');
    final detail = engineMessage ?? exit?.tombstoneHeadline;
    if (detail != null && detail.isNotEmpty) b.write(': $detail');
    if (gaveUp) b.write('. It keeps crashing ($recentCrashes times in a row); not restarting automatically');
    return b.toString();
  }

  static String _phaseText(PhaseRecord p) {
    final what = switch (p.phase) {
      InferencePhase.idle => 'idle',
      InferencePhase.loading => 'loading a model',
      InferencePhase.generating => 'generating',
      InferencePhase.savingState => 'saving a conversation cache',
      InferencePhase.restoringState => 'restoring a conversation cache',
      InferencePhase.benchmarking => 'benchmarking',
    };
    final shape = [if (p.nCtx != null) '${p.nCtx}-token context', if (p.kvLayout != null) 'KV ${p.kvLayout}'];
    return shape.isEmpty ? what : '$what (${shape.join(', ')})';
  }
}

/// How [ProcessEngineHost] restarts a dead `:inference` process.
///
/// Delays grow from [initialDelay] by [multiplier] up to [maxDelay]; a
/// process that stayed up for [stableAfter] resets the backoff. [maxCrashes]
/// deaths (or failed restarts) within [window] are a crash loop: the host
/// stops restarting, reports `gaveUp`, and every call fails with "engine
/// unavailable" until [ProcessEngineHost.retry].
@immutable
final class ProcessRestartPolicy {
  const ProcessRestartPolicy({
    this.initialDelay = const Duration(milliseconds: 250),
    this.maxDelay = const Duration(seconds: 30),
    this.multiplier = 2.0,
    this.maxCrashes = 5,
    this.window = const Duration(minutes: 3),
    this.stableAfter = const Duration(minutes: 1),
  });

  final Duration initialDelay;
  final Duration maxDelay;
  final double multiplier;
  final int maxCrashes;
  final Duration window;
  final Duration stableAfter;

  Duration delayFor(int attempt) {
    final ms = initialDelay.inMilliseconds * math.pow(multiplier, math.min(attempt, 30));
    return Duration(milliseconds: math.min(ms, maxDelay.inMilliseconds.toDouble()).round());
  }
}
