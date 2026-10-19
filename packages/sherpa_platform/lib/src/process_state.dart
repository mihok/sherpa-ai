import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'backend.dart';

/// Records what the process is doing so the next launch can tell *why* it
/// died (Android `setProcessStateSummary`, read back through
/// `ApplicationExitInfo.getProcessStateSummary`, R07 §2.4).
///
/// Write at every inference phase change ("loading model X ctx Y"); after a
/// low-memory or memory-limiter kill during `load`/`decode`, the app can
/// downgrade the model, context or backend automatically. iOS has no
/// equivalent, so [write] returns false there.
abstract final class ProcessStateRecorder {
  /// "Maximum length is 128 bytes" (ActivityManager docs).
  static const int maxBytes = 128;

  static String? _last;
  static PlatformBackend? _lastBackend;

  /// Writes [summary] (UTF-8, cut to [maxBytes] at a character boundary).
  /// Repeating the previous summary is skipped because the system may
  /// throttle these calls. Must not contain PII: hash model ids
  /// ([ProcessStateSummary.hashModelId]).
  static Future<bool> write(String summary, {PlatformBackend? backend}) async {
    final target = backend ?? SherpaPlatform.backend;
    final bytes = truncateUtf8(summary, maxBytes);
    final text = utf8.decode(bytes);
    if (text == _last && identical(target, _lastBackend)) return true;
    final ok = await target.setProcessStateSummary(bytes);
    if (ok) {
      _last = text;
      _lastBackend = target;
    }
    return ok;
  }

  /// Writes a structured [ProcessStateSummary].
  static Future<bool> record(ProcessStateSummary summary, {PlatformBackend? backend}) =>
      write(summary.encode(), backend: backend);

  /// Forgets the de-duplication state (tests).
  @visibleForTesting
  static void reset() {
    _last = null;
    _lastBackend = null;
  }

  /// UTF-8 bytes of [s], at most [max], never splitting a code point.
  static Uint8List truncateUtf8(String s, int max) {
    final bytes = utf8.encode(s);
    if (bytes.length <= max) return bytes;
    var end = max;
    while (end > 0 && (bytes[end] & 0xC0) == 0x80) {
      end--;
    }
    return Uint8List.sublistView(bytes, 0, end);
  }
}

/// Inference phase for kill forensics.
enum ProcessPhase { idle, load, prefill, decode, unload }

/// Compact, PII-free process state: `v1 p=decode m=1a2b3c4d b=cpu c=8192 fg=0`
/// (R07 §2.4's `{v, modelIdHash, backend, ctxTokens, phase, fgState}`), well
/// under the 128-byte limit.
@immutable
final class ProcessStateSummary {
  const ProcessStateSummary({
    required this.phase,
    this.modelHash,
    this.backend,
    this.contextTokens,
    this.foreground,
  });

  /// [modelId] is hashed here so callers cannot leak a file path by accident.
  factory ProcessStateSummary.forModel({
    required ProcessPhase phase,
    required String modelId,
    String? backend,
    int? contextTokens,
    bool? foreground,
  }) =>
      ProcessStateSummary(
        phase: phase,
        modelHash: hashModelId(modelId),
        backend: backend,
        contextTokens: contextTokens,
        foreground: foreground,
      );

  final ProcessPhase phase;

  /// 8 hex digits, see [hashModelId].
  final String? modelHash;

  /// Engine backend, e.g. `cpu`, `metal`, `opencl` (≤ 16 chars, no spaces).
  final String? backend;
  final int? contextTokens;
  final bool? foreground;

  /// FNV-1a 32-bit of [modelId] as 8 hex digits: stable across launches, no
  /// crypto dependency, not reversible to a path or repo name in practice.
  static String hashModelId(String modelId) {
    var h = 0x811c9dc5;
    for (final b in utf8.encode(modelId)) {
      h ^= b;
      h = (h * 0x01000193) & 0xffffffff;
    }
    return h.toRadixString(16).padLeft(8, '0');
  }

  String encode() {
    final parts = ['v1', 'p=${phase.name}'];
    if (modelHash != null) parts.add('m=$modelHash');
    final b = backend?.replaceAll(RegExp(r'[\s=]'), '_');
    if (b != null) parts.add('b=${b.length > 16 ? b.substring(0, 16) : b}');
    if (contextTokens != null) parts.add('c=$contextTokens');
    if (foreground != null) parts.add('fg=${foreground! ? 1 : 0}');
    return parts.join(' ');
  }

  /// Parses [encode]'s output; null for anything else (an older format or a
  /// free-text summary).
  static ProcessStateSummary? tryParse(String? text) {
    if (text == null) return null;
    final parts = text.trim().split(' ');
    if (parts.isEmpty || parts.first != 'v1') return null;
    final kv = <String, String>{
      for (final p in parts.skip(1))
        if (p.contains('=')) p.substring(0, p.indexOf('=')): p.substring(p.indexOf('=') + 1),
    };
    final phase = ProcessPhase.values.where((v) => v.name == kv['p']).firstOrNull;
    if (phase == null) return null;
    return ProcessStateSummary(
      phase: phase,
      modelHash: kv['m'],
      backend: kv['b'],
      contextTokens: int.tryParse(kv['c'] ?? ''),
      foreground: switch (kv['fg']) { '1' => true, '0' => false, _ => null },
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ProcessStateSummary &&
      other.phase == phase &&
      other.modelHash == modelHash &&
      other.backend == backend &&
      other.contextTokens == contextTokens &&
      other.foreground == foreground;

  @override
  int get hashCode => Object.hash(phase, modelHash, backend, contextTokens, foreground);

  @override
  String toString() => encode();
}
