import 'package:sherpa_hub/sherpa_hub.dart';
import 'package:test/test.dart';

const int _mib = 1 << 20;
const int _gib = 1 << 30;

/// mlx-community/Qwen3-4B-4bit's config.json (the keys the estimate reads).
const Map<String, Object?> _qwen3_4bConfig = {
  'model_type': 'qwen3',
  'num_hidden_layers': 36,
  'num_attention_heads': 32,
  'num_key_value_heads': 8,
  'head_dim': 128,
  'hidden_size': 2560,
  'intermediate_size': 9728,
  'max_position_embeddings': 40960,
  'vocab_size': 151936,
  'quantization': {'group_size': 64, 'bits': 4},
};

DeviceProfile _ios(double totalGib, double availGib) => DeviceProfile(
    platform: DevicePlatform.ios,
    osVersion: '26',
    totalRamBytes: (totalGib * _gib).round(),
    availableRamBytes: (availGib * _gib).round());

DeviceProfile _android(double totalGib, double availGib, {String os = '16'}) => DeviceProfile(
    platform: DevicePlatform.android,
    osVersion: os,
    totalRamBytes: (totalGib * _gib).round(),
    availableRamBytes: (availGib * _gib).round());

void main() {
  group('ModelArchitecture.fromMlxConfig', () {
    test('reads layers, KV heads, head size and the trained context', () {
      final a = ModelArchitecture.fromMlxConfig(_qwen3_4bConfig)!;
      expect(a.layerCount, 36);
      expect(a.kvHeadsPerLayer.toSet(), {8});
      expect(a.keyLength, 128);
      expect(a.trainContextLength, 40960);
      expect(a.architecture, 'qwen3');
    });

    test('nested text_config (multimodal) and head size from hidden / heads', () {
      final a = ModelArchitecture.fromMlxConfig({
        'model_type': 'gemma3',
        'text_config': {'num_hidden_layers': 26, 'num_attention_heads': 8, 'num_key_value_heads': 4, 'hidden_size': 2048},
      })!;
      expect(a.layerCount, 26);
      expect(a.keyLength, 256);
      expect(a.kvHeadsPerLayer.first, 4);
    });

    test('a sliding window is counted as full attention, with a note', () {
      final a = ModelArchitecture.fromMlxConfig({..._qwen3_4bConfig, 'sliding_window': 4096})!;
      expect(a.notes.single, contains('sliding-window'));
    });

    test('null without the layer count or head geometry', () {
      expect(ModelArchitecture.fromMlxConfig(const {'model_type': 'x'}), isNull);
      expect(ModelArchitecture.fromMlxConfig(const {'num_hidden_layers': 4}), isNull);
    });
  });

  group('MLX fit', () {
    final arch = ModelArchitecture.fromMlxConfig(_qwen3_4bConfig)!;
    const weights = 2264924160; // the repo's model.safetensors

    test('weights, 8-bit KV from config.json and the MLX overhead', () {
      final f = assessRuntimeFit(_ios(7.5, 5.8), RuntimeFootprintInput.mlx(weightBytes: weights, architecture: arch));
      // 2 (K,V) × 36 layers × 8 heads × 128 × 1.0625 B × 4096 cells.
      expect(f.breakdown.kvBytes, (2 * 36 * 8 * 128 * 4096 * 1.0625).round());
      expect(f.breakdown.weightsBytes, weights);
      expect(f.breakdown.runtimeOverheadBytes, FitConstants.mlxRuntimeOverheadBytes);
      expect(f.breakdown.computeBytes, 0);
      expect(f.verdict, FitVerdict.fits);
      expect(f.recommendedMaxContext, isNotNull);
      expect(f.recommendedMaxContext! % 256, 0);
      expect(f.recommendedMaxContext!, lessThanOrEqualTo(40960));
    });

    test('the same arithmetic as sherpa_apple_ml admission: 0.6 × available', () {
      // 6 GB iPhone with 2.9 GB available: 0.6 × 2.9 = 1.74 GB < 2.26 GB weights.
      final f = assessRuntimeFit(_ios(5.6, 2.9), RuntimeFootprintInput.mlx(weightBytes: weights, architecture: arch));
      expect(f.verdict, isNot(FitVerdict.fits));
      expect(f.reasons.first.code, anyOf(FitReasonCode.exceedsAvailableMemory, FitReasonCode.nearAvailableMemory));
    });

    test('a longer context costs more KV; the trained context caps it', () {
      final short = assessRuntimeFit(_ios(7.5, 5.8), RuntimeFootprintInput.mlx(weightBytes: weights, architecture: arch));
      final long = assessRuntimeFit(_ios(7.5, 5.8), RuntimeFootprintInput.mlx(weightBytes: weights, architecture: arch),
          options: const FitOptions(contextLength: 100000));
      expect(long.breakdown.kvBytes, greaterThan(short.breakdown.kvBytes));
      expect(long.contextLength, 40960);
      expect(long.reasons.map((r) => r.code), contains(FitReasonCode.contextClamped));
    });

    test('without config.json: weights only, said so, no recommended context', () {
      final f = assessRuntimeFit(_ios(7.5, 5.8), const RuntimeFootprintInput.mlx(weightBytes: weights));
      expect(f.breakdown.kvBytes, 0);
      expect(f.recommendedMaxContext, isNull);
      expect(f.reasons.map((r) => r.message).join(' '), contains('config.json'));
    });
  });

  group('LiteRT fit', () {
    const gemma = 2583 * _mib; // ~ gemma-3n-E2B-it-int4.litertlm

    test('the file plus a CPU weight cache of about its size', () {
      expect(liteRtWeightCacheBytes(gemma), gemma);
      final f = assessRuntimeFit(_android(15, 9), RuntimeFootprintInput.liteRt(fileBytes: gemma));
      expect(f.breakdown.weightsBytes, gemma);
      expect(f.breakdown.repackBytes, gemma);
      expect(f.breakdown.runtimeOverheadBytes, FitConstants.liteRtRuntimeOverheadBytes);
      expect(f.breakdown.kvBytes, 0);
      expect(f.demandBytes, 2 * gemma + FitConstants.liteRtRuntimeOverheadBytes);
      expect(f.verdict, FitVerdict.fits);
      expect(f.reasons.map((r) => r.message).join(' '), contains('weight cache'));
      expect(f.recommendedMaxContext, isNull);
    });

    test('the weight cache is what makes a 4 GB phone refuse', () {
      final f = assessRuntimeFit(_android(3.6, 1.4), RuntimeFootprintInput.liteRt(fileBytes: gemma));
      expect(f.verdict, FitVerdict.wontFit);
      expect(f.reasons.first.severity, FitSeverity.blocking);
    });

    test('the Android 17 limiter counts the cache (anonymous), not the mapped file', () {
      final f = assessRuntimeFit(_android(7.5, 6.5, os: '17'), RuntimeFootprintInput.liteRt(fileBytes: gemma));
      expect(f.processCapBytes, isNotNull);
      expect(f.processDemandBytes, gemma + FitConstants.liteRtRuntimeOverheadBytes);
    });
  });

  group('LiteRT storage', () {
    HubRepoFile lfs(String path, int size) =>
        HubRepoFile(path: path, size: size, lfsSha256: 'a' * 64, lfsSize: size, xetHash: 'b' * 64, oid: 'c' * 40);
    const commit = 'c03ac9c3bdc5ae949111acb945338933f396e4d7';

    test('a .litertlm plan counts the weight cache in the storage check', () {
      final o = planDownload(
        repo: 'litert-community/Qwen3-0.6B',
        commit: commit,
        files: [lfs('Qwen3-0.6B.litertlm', 614 * _mib), const HubRepoFile(path: 'README.md', size: 10, oid: 'd')],
      );
      final plan = o as DownloadPlan;
      expect(plan.variant.runtime, SherpaRuntime.litert);
      expect(plan.runtimeCacheBytes, 614 * _mib);
      expect(plan.tempBytes, 614 * _mib);
      // 614 MB to download fits 1.8 GB free with the 1 GB margin; with the
      // cache it does not.
      final withCache = assessStorage(downloadBytes: plan.totalBytes, tempBytes: plan.tempBytes, freeBytes: 1800 * _mib);
      final without = assessStorage(downloadBytes: plan.totalBytes, freeBytes: 1800 * _mib);
      expect(without.verdict, StorageVerdict.ok);
      expect(withCache.verdict, StorageVerdict.tight);
    });

    test('GGUF plans have no runtime cache', () {
      final plan = planDownload(
        repo: 'bartowski/Llama-3.2-1B-Instruct-GGUF',
        commit: commit,
        files: [lfs('Llama-3.2-1B-Instruct-Q4_K_M.gguf', 807694464)],
      ) as DownloadPlan;
      expect(plan.runtimeCacheBytes, 0);
      expect(plan.tempBytes, 0);
    });
  });
}
