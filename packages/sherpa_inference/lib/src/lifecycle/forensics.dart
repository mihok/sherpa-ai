import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:sherpa_core/sherpa_core.dart';

/// What the engine was doing; recorded before risky work so that a process
/// death can be attributed on the next start.
enum InferencePhase { idle, loading, generating, savingState, restoringState, benchmarking }

/// One phase record (the content of the phase file). Kept tiny and free of
/// user data: it may end up in a bug report.
@immutable
final class PhaseRecord {
  const PhaseRecord({
    required this.phase,
    required this.at,
    this.modelId,
    this.modelName,
    this.nCtx,
    this.kvLayout,
  });

  factory PhaseRecord.fromJson(JsonMap j) => PhaseRecord(
        phase: InferencePhase.values.byName(j.opt<String>('phase') ?? 'idle'),
        at: DateTime.parse(j.req<String>('at')),
        modelId: j.opt<String>('modelId'),
        modelName: j.opt<String>('modelName'),
        nCtx: j.optInt('nCtx'),
        kvLayout: j.opt<String>('kv'),
      );

  final InferencePhase phase;
  final DateTime at;
  final String? modelId;
  final String? modelName;
  final int? nCtx;
  final String? kvLayout;

  JsonMap toJson() => compact({
        'phase': phase.name,
        'at': at.toUtc().toIso8601String(),
        'modelId': modelId,
        'modelName': modelName,
        'nCtx': nCtx,
        'kv': kvLayout,
      });

  /// ≤ 128 bytes, for Android's `setProcessStateSummary` (R07 §2.4).
  String get compactSummary {
    final s = jsonEncode(compact({'v': 1, 'p': phase.name, 'm': modelId?.hashCode.toRadixString(36), 'c': nCtx, 'k': kvLayout}));
    return s.length <= 128 ? s : s.substring(0, 128);
  }
}

/// The previous run ended while the engine was busy.
@immutable
final class EngineCrashReport {
  const EngineCrashReport({required this.phase, this.engineMessage});

  /// The phase that never completed.
  final PhaseRecord phase;

  /// The fatal ggml message from the engine's crash breadcrumb (definitive
  /// native abort), if any. Without it the process may also have been
  /// killed by the OS (jetsam / LMK / Android 17 limiter) during the phase.
  final String? engineMessage;

  bool get isNativeAbort => engineMessage != null && engineMessage!.isNotEmpty;

  /// Ready-to-show sentence.
  String get description {
    final what = switch (phase.phase) {
      InferencePhase.loading => 'loading',
      InferencePhase.generating => 'generating a reply with',
      InferencePhase.savingState => 'saving the conversation cache of',
      InferencePhase.restoringState => 'restoring the conversation cache of',
      InferencePhase.benchmarking => 'benchmarking',
      InferencePhase.idle => 'running',
    };
    final model = phase.modelName ?? phase.modelId ?? 'the model';
    final ctx = phase.nCtx == null ? '' : ' (${phase.nCtx}-token context)';
    final cause = isNativeAbort
        ? 'The on-device engine crashed'
        : 'The app was stopped (possibly by the system for using too much memory)';
    return '$cause while $what $model$ctx.';
  }
}

/// Crash forensics files in one directory:
/// * `engine_crash.txt` — `se_init_params.crash_breadcrumb_path`: the engine
///   appends the fatal ggml message there right before a GGML_ABORT ends
///   the process (it cannot prevent the abort).
/// * `engine_phase.json` — written by the lifecycle manager before each
///   risky phase and reset to idle after it, so a process death during a
///   phase (native crash *or* an OS memory kill, which leaves no trace) is
///   visible on the next start.
final class EngineForensics {
  EngineForensics(this.directory);

  final Directory directory;

  String get engineBreadcrumbPath => p.join(directory.path, 'engine_crash.txt');
  String get phaseFilePath => p.join(directory.path, 'engine_phase.json');

  PhaseRecord? _last;
  Future<void> _tail = Future.value();

  /// Records [record] durably before the phase starts. Only transitions are
  /// written (two small writes per generation), in call order. A failed
  /// write never fails the inference it describes.
  Future<void> enter(PhaseRecord record) {
    final next = _tail.then((_) async {
      final last = _last;
      if (last != null && last.phase == record.phase && last.modelId == record.modelId && last.nCtx == record.nCtx) {
        return;
      }
      _last = record;
      try {
        await directory.create(recursive: true);
        final tmp = File('$phaseFilePath.tmp');
        await tmp.writeAsString(jsonEncode(record.toJson()), flush: true);
        await tmp.rename(phaseFilePath);
      } on FileSystemException {
        _last = null;
      }
    });
    _tail = next;
    return next;
  }

  Future<void> idle(DateTime at) => enter(PhaseRecord(phase: InferencePhase.idle, at: at));

  /// Completes when every queued write has landed.
  Future<void> flush() => _tail;

  /// Inspects (and then clears) what the previous run left behind.
  Future<EngineCrashReport?> collect() async {
    await _tail;
    PhaseRecord? phase;
    String? message;
    try {
      phase = PhaseRecord.fromJson((jsonDecode(await File(phaseFilePath).readAsString()) as Map).cast<String, Object?>());
    } on Object {
      phase = null;
    }
    try {
      final f = File(engineBreadcrumbPath);
      if (await f.exists()) {
        message = (await f.readAsString()).trim();
        await f.delete();
      }
    } on Object {
      message = null;
    }
    _last = null;
    try {
      await File(phaseFilePath).delete();
    } on Object {
      // nothing recorded
    }
    final busy = phase != null && phase.phase != InferencePhase.idle;
    if (!busy && (message == null || message.isEmpty)) return null;
    return EngineCrashReport(
      phase: phase ?? PhaseRecord(phase: InferencePhase.idle, at: DateTime.now()),
      engineMessage: message == null || message.isEmpty ? null : message,
    );
  }
}
