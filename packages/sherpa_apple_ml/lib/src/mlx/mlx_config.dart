import 'package:meta/meta.dart';

import 'mlx_model_dir.dart';

/// KV-cache settings, mapped 1:1 onto mlx-swift-lm `GenerateParameters`
/// (R06 §2.4). Set either [kvScheme] (`"turbo8v3"`, `"affine8"`, …) or
/// [kvBits]; never both.
@immutable
final class MlxKvSettings {
  const MlxKvSettings({
    this.kvBits,
    this.kvGroupSize = 64,
    this.quantizedKVStart = 0,
    this.kvScheme,
    this.maxKVSize,
    this.prefillStepSize,
  }) : assert(kvBits == null || kvScheme == null, 'use kvBits or kvScheme, not both');

  /// 4 or 8 (affine). POLICY: tool-calling sessions stay at 8 (R11 §9.6.2).
  final int? kvBits;
  final int kvGroupSize;
  final int quantizedKVStart;
  final String? kvScheme;

  /// Rotating-cache size; null = admission picks it from the context.
  final int? maxKVSize;

  /// Prefill chunk: lower it on low-RAM devices (peak activation memory).
  final int? prefillStepSize;

  int? get effectiveBits => kvBits ?? _schemeBits(kvScheme);

  static int? _schemeBits(String? scheme) {
    if (scheme == null) return null;
    final m = RegExp(r'(\d+)').firstMatch(scheme);
    return m == null ? null : int.tryParse(m.group(1)!);
  }

  MlxKvSettings withMaxKVSize(int? size) => MlxKvSettings(
    kvBits: kvBits,
    kvGroupSize: kvGroupSize,
    quantizedKVStart: quantizedKVStart,
    kvScheme: kvScheme,
    maxKVSize: size,
    prefillStepSize: prefillStepSize,
  );

  Map<String, Object?> toJson() => {
    'kvBits': kvBits,
    'kvGroupSize': kvGroupSize,
    'quantizedKVStart': quantizedKVStart,
    'kvScheme': kvScheme,
    'maxKVSize': maxKVSize,
    'prefillStepSize': prefillStepSize,
  };
}

/// An MLX model the app installed (the library's MLX entries).
@immutable
final class MlxModelSpec {
  const MlxModelSpec({
    required this.id,
    required this.directory,
    this.displayName,
    this.preferredContext = 8192,
    this.minContext = 2048,
    this.kv = const MlxKvSettings(kvBits: 8),
    this.toolCalling = true,
  });

  /// `ModelRequest.modelId`.
  final String id;

  /// The model directory, or any file in it (the library's `loadPath`).
  final String directory;
  final String? displayName;

  /// Context to aim for; admission may shrink it to what fits.
  final int preferredContext;

  /// Below this the model is not worth loading (admission refuses).
  final int minContext;
  final MlxKvSettings kv;

  /// Offer tools to this model (when its template supports them).
  final bool toolCalling;

  String get label => displayName ?? id;
}

/// Provider-wide policy. Every number is POLICY / UNVERIFIED on devices.
@immutable
final class MlxProviderConfig {
  const MlxProviderConfig({
    this.cacheLimitBytes = 32 << 20,
    this.memoryLimitFraction = 0.9,
    this.budgetFraction = 0.6,
    this.overheadBytes = 384 << 20,
    this.cancelGrace = const Duration(seconds: 2),
    this.restorePromptCaches = false,
  });

  /// `Memory.cacheLimit` (R06 §2.9: ~20 MB suggested; 32–64 MB in §12).
  final int cacheLimitBytes;

  /// `Memory.memoryLimit` as a fraction of what the process may still
  /// allocate when the model loads.
  final double memoryLimitFraction;

  /// R06 §5 budget rule: weights + KV + activations ≤ 0.6 ×
  /// `os_proc_available_memory()`.
  final double budgetFraction;

  /// Activations, tokenizer and buffer cache on top of weights and KV.
  final int overheadBytes;

  /// After a cancel, how long to wait for the native `finished` before
  /// ending the stream anyway.
  final Duration cancelGrace;

  /// EXPERIMENTAL: start a rebuilt session from a prompt cache saved with
  /// `MlxProvider.savePromptCache` (fragment continuation, README). Off by
  /// default: mlx-swift-lm 3.32.3 cannot pair a restored KV cache with a
  /// transcript.
  final bool restorePromptCaches;
}

/// The admission verdict for loading [MlxModelDirectory] now.
@immutable
final class MlxAdmission {
  const MlxAdmission._(this.admitted, this.maxKVSize, this.estimateBytes, this.reason);

  /// Decides whether the model fits and how large a context it can have:
  /// `weights + overhead + kvBytesPerToken × context ≤ budgetFraction ×
  /// procAvailableBytes`, with the context shrunk (in 256-token steps) down
  /// to [MlxModelSpec.minContext] before refusing.
  factory MlxAdmission.plan({
    required MlxModelDirectory dir,
    required MlxModelSpec spec,
    required int procAvailableBytes,
    required MlxProviderConfig config,
  }) {
    final budget = (procAvailableBytes * config.budgetFraction).floor();
    final fixed = dir.weightsBytes + config.overheadBytes + config.cacheLimitBytes;
    final train = dir.contextLength;
    var ctx = spec.kv.maxKVSize ?? spec.preferredContext;
    if (train != null && train > 0 && ctx > train) ctx = train;
    final perToken = dir.kvBytesPerToken(kvBits: spec.kv.effectiveBits, groupSize: spec.kv.kvGroupSize);
    if (fixed > budget) {
      return MlxAdmission._(
        false,
        null,
        fixed,
        'needs about ${_gb(fixed)} for weights and runtime, ${_gb(budget)} is available to models now',
      );
    }
    if (perToken == null || perToken <= 0) return MlxAdmission._(true, ctx, fixed, 'kv size unknown');
    final fit = ((budget - fixed) ~/ perToken) ~/ 256 * 256;
    if (fit < ctx) {
      if (fit < spec.minContext) {
        return MlxAdmission._(
          false,
          null,
          fixed + perToken * spec.minContext,
          'not enough memory for a ${spec.minContext}-token context (${_gb(budget)} available to models)',
        );
      }
      ctx = fit;
    }
    return MlxAdmission._(true, ctx, fixed + perToken * ctx, null);
  }

  final bool admitted;

  /// `GenerateParameters.maxKVSize` to use (= the context the context
  /// manager is told about).
  final int? maxKVSize;
  final int estimateBytes;
  final String? reason;

  static String _gb(int bytes) => '${(bytes / (1 << 30)).toStringAsFixed(1)} GB';
}
