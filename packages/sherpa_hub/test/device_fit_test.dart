import 'dart:io';
import 'dart:math';

import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_hub/sherpa_hub.dart';
import 'package:test/test.dart';

const int _mib = 1 << 20;
const int _gib = 1 << 30;

// Shapes from the models' published configs (Qwen3 model cards); the 0.6B
// one is cross-checked against the real GGUF header below.
final _qwen06 = ModelArchitecture.dense(
    layers: 28, kvHeads: 8, headDim: 128, embeddingLength: 1024, feedForwardLength: 3072, vocabSize: 151936,
    headCount: 16, trainContextLength: 40960, parameterCount: 596049920);
final _qwen4b = ModelArchitecture.dense(
    layers: 36, kvHeads: 8, headDim: 128, embeddingLength: 2560, feedForwardLength: 9728, vocabSize: 151936,
    headCount: 32, trainContextLength: 40960);
final _qwen8b = ModelArchitecture.dense(
    layers: 36, kvHeads: 8, headDim: 128, embeddingLength: 4096, feedForwardLength: 12288, vocabSize: 151936,
    headCount: 32, trainContextLength: 40960);
final _qwen30bA3b = ModelArchitecture.dense(
    layers: 48, kvHeads: 4, headDim: 128, embeddingLength: 2048, feedForwardLength: 768 * 8, vocabSize: 151936,
    headCount: 32, trainContextLength: 262144, expertCount: 128, expertUsedCount: 8);

/// Real/public Q4 file sizes: the local Qwen3-0.6B-Q4_K_M.gguf, unsloth's
/// Qwen3-4B/8B Q4_K_M, and the R08 §14 row 6 30B-A3B UD-Q4_K_XL (live).
final Map<String, (ModelArchitecture, int)> _models = {
  'Qwen3-0.6B Q4_K_M': (_qwen06, 396705472),
  'Qwen3-4B Q4_K_M': (_qwen4b, 2497280256),
  'Qwen3-8B Q4_K_M': (_qwen8b, 5027783488),
  'Qwen3-30B-A3B UD-Q4_K_XL': (_qwen30bA3b, 17665334432),
};

DeviceProfile _android(double totalGib, double availGib) => DeviceProfile(
    platform: DevicePlatform.android,
    osVersion: '17',
    totalRamBytes: (totalGib * _gib).round(),
    availableRamBytes: (availGib * _gib).round());

DeviceProfile _ios(double totalGib, double availGib) => DeviceProfile(
    platform: DevicePlatform.ios,
    osVersion: '26',
    totalRamBytes: (totalGib * _gib).round(),
    availableRamBytes: (availGib * _gib).round());

/// Reference profiles: kernel-visible RAM and a realistic measured
/// availability (`availMem − threshold` / `os_proc_available_memory`).
final Map<String, DeviceProfile> _devices = {
  'Android 4 GB': _android(3.6, 1.4),
  'Android 6 GB': _android(5.6, 2.4),
  'Android 8 GB': _android(7.5, 3.6),
  'Android 12 GB': _android(11.2, 6.0),
  'iOS 6 GB': _ios(5.6, 2.9),
  'iOS 8 GB': _ios(7.5, 5.8),
};

ModelFootprintInput _input((ModelArchitecture, int) m) =>
    ModelFootprintInput(architecture: m.$1, weightBytes: m.$2, quant: QuantTypes.q4_k_m);

void main() {
  group('KV cache formula vs llama.cpp measurements (R04 §6, PROBE-1)', () {
    test('Qwen3-0.6B at n_ctx 4096: f16 448 MiB, q8_0 238 MiB, q4_0 126 MiB', () {
      KvEstimate kv(KvCacheType t) => estimateKvCache(_qwen06, contextLength: 4096, typeK: t, typeV: t);
      expect(kv(KvCacheType.f16).bytes, 448 * _mib);
      expect(kv(KvCacheType.q8_0).bytes, 238 * _mib);
      expect(kv(KvCacheType.q4_0).bytes, 126 * _mib);
      expect(kv(KvCacheType.f16).bytesPerFullCell, 114688);
      expect(kv(KvCacheType.q8_0).bytesPerFullCell, 60928);
      expect(kv(KvCacheType.q4_0).bytesPerFullCell, 32256);
      final mixed = estimateKvCache(_qwen06, contextLength: 4096, typeK: KvCacheType.q8_0, typeV: KvCacheType.f16);
      expect(mixed.bytes, 343 * _mib);
    });

    test('same numbers from the real GGUF header', () {
      final f = File('/opt/models/Qwen3-0.6B-Q4_K_M.gguf');
      final raf = f.openSync();
      addTearDown(raf.closeSync);
      final h = GgufReader.parse(raf.readSync(6 << 20), fileSize: raf.lengthSync()) as GgufHeader;
      final a = ModelArchitecture.fromGguf(h.metadata, parameterCount: h.parameterCount)!;
      expect(a.layerCount, 28);
      expect(a.kvHeadsPerLayer.toSet(), {8});
      expect(a.keyLength, 128);
      expect(a.parameterCount, 596049920);
      expect(estimateKvCache(a, contextLength: 4096, typeK: KvCacheType.f16, typeV: KvCacheType.f16).bytes, 448 * _mib);
      expect(estimateKvCache(a, contextLength: 4096).bytes, 238 * _mib);
      expect(estimateKvCache(a, contextLength: 4096, typeK: KvCacheType.q4_0, typeV: KvCacheType.q4_0).bytes, 126 * _mib);
    }, skip: File('/opt/models/Qwen3-0.6B-Q4_K_M.gguf').existsSync() ? false : 'needs the local model');

    test('n_ctx padding to 256 and per-sequence split (PROBE-1: 4096 × 3 seqs → 4608, 504 MiB)', () {
      expect(estimateKvCache(_qwen06, contextLength: 1000).contextCells, 1024);
      final split = estimateKvCache(_qwen06,
          contextLength: 4096, typeK: KvCacheType.f16, typeV: KvCacheType.f16, sequences: 3, unified: false);
      expect(split.contextCells, 1536);
      expect(split.contextCells * split.streams, 4608);
      expect(split.bytes, 504 * _mib);
      final unified =
          estimateKvCache(_qwen06, contextLength: 4096, typeK: KvCacheType.f16, typeV: KvCacheType.f16, sequences: 3);
      expect(unified.bytes, 448 * _mib);
    });

    test('compute buffer estimate tracks PROBE-1b (302.8 / 30.1 / 15.1 / 7.6 MiB)', () {
      double c(int ub, int outs) => estimateComputeBytes(_qwen06, nUbatch: ub, outputs: outs, contextCells: 4096) / _mib;
      expect(c(512, 512), closeTo(302.8, 1.0));
      expect(c(512, 1), closeTo(30.1, 0.5));
      expect(c(256, 1), closeTo(15.1, 0.5));
      expect(c(128, 1), closeTo(7.6, 0.5));
      expect(estimateComputeBytes(_qwen06, nUbatch: 512, contextCells: 4096, flashAttention: false) / _mib,
          greaterThan(c(512, 1) + 100), reason: 'without FA one layer of f32 KQ scores is materialized');
    });

    test('SWA layers use the small cache unless swa_full (R04 §5)', () {
      final gemma = ModelArchitecture(
        layerCount: 12,
        kvHeadsPerLayer: List.filled(12, 4),
        keyLength: 256,
        valueLength: 256,
        slidingWindow: 1024,
        swaLayers: [for (var i = 0; i < 12; i++) const SwaPattern.period(6).isSwa(i)],
      );
      final small = estimateKvCache(gemma, contextLength: 32768, typeK: KvCacheType.f16, typeV: KvCacheType.f16);
      expect(small.swaLayerCount, 10);
      expect(small.swaCells, 1280, reason: 'pad256(min(32768, 1024 + 256))');
      final row = 2 * 4 * 256 * 2;
      expect(small.bytes, row * (2 * 32768 + 10 * 1280));
      final full = estimateKvCache(gemma, contextLength: 32768, typeK: KvCacheType.f16, typeV: KvCacheType.f16, swaFull: true);
      expect(full.bytes, row * 12 * 32768);
    });

    test('hybrid, shared-KV and NextN layers keep no KV', () {
      final m = GgufMetadata({
        'general.architecture': 'qwen35',
        'qwen35.block_count': 9,
        'qwen35.nextn_predict_layers': 1,
        'qwen35.attention.head_count': 16,
        'qwen35.attention.head_count_kv': 2,
        'qwen35.attention.key_length': 256,
        'qwen35.full_attention_interval': 4,
      });
      final a = ModelArchitecture.fromGguf(m)!;
      expect(a.layerCount, 8);
      expect(a.kvHeadsPerLayer, [0, 0, 0, 2, 0, 0, 0, 2]);
      expect(a.notes, isNotEmpty);
      final g = ModelArchitecture.fromGguf(GgufMetadata({
        'general.architecture': 'gemma4',
        'gemma4.block_count': 10,
        'gemma4.attention.head_count_kv': 2,
        'gemma4.attention.key_length': 256,
        'gemma4.attention.shared_kv_layers': 4,
      }))!;
      expect(g.kvHeadsPerLayer, [2, 2, 2, 2, 2, 2, 0, 0, 0, 0]);
      final unknownSwa = ModelArchitecture.fromGguf(GgufMetadata({
        'general.architecture': 'mystery',
        'mystery.block_count': 2,
        'mystery.attention.head_count_kv': 1,
        'mystery.attention.key_length': 64,
        'mystery.attention.sliding_window': 512,
      }))!;
      expect(unknownSwa.swaLayers, isEmpty, reason: 'unknown layout → assume full attention (safe side)');
      expect(unknownSwa.notes.single, contains('over-estimates'));
    });

    test('architecture JSON round-trips', () {
      final a = ModelArchitecture.fromJson(_qwen30bA3b.toJson());
      expect(a.toJson(), _qwen30bA3b.toJson());
    });
  });

  group('device table (Q4 files, q8_0 KV, n_ctx 4096, n_ubatch 256)', () {
    const expected = {
      'Android 4 GB': ['fits', 'wontFit', 'wontFit', 'wontFit'],
      'Android 6 GB': ['fits', 'wontFit', 'wontFit', 'wontFit'],
      'Android 8 GB': ['fits', 'tight', 'wontFit', 'wontFit'],
      'Android 12 GB': ['fits', 'fits', 'tight', 'wontFit'],
      'iOS 6 GB': ['fits', 'wontFit', 'wontFit', 'wontFit'],
      'iOS 8 GB': ['fits', 'fits', 'tight', 'wontFit'],
    };
    for (final d in _devices.entries) {
      test(d.key, () {
        final verdicts = [for (final m in _models.values) assessFit(d.value, _input(m)).verdict.name];
        expect(verdicts, expected[d.key], reason: _models.keys.join(', '));
      });
    }

    test('breakdown of Qwen3-0.6B on a 4 GB Android', () {
      final r = assessFit(_devices['Android 4 GB']!, _input(_models['Qwen3-0.6B Q4_K_M']!));
      final b = r.breakdown;
      expect(b.weightsBytes, 396705472);
      expect(b.kvBytes, 238 * _mib);
      expect(b.computeBytes / _mib, closeTo(15.1, 0.5));
      expect(b.runtimeOverheadBytes, FitConstants.androidRuntimeOverheadBytes);
      expect(b.appOverheadBytes, 0, reason: 'measured availability already excludes the app');
      expect(r.processCapBytes, (3.6 * _gib * 0.5).round(), reason: 'Android 17 limiter ≈ half of RAM (R07 §2.3)');
      expect(r.processDemandBytes, b.kvBytes + b.computeBytes + b.runtimeOverheadBytes,
          reason: 'mmap weights are file-backed, not limiter-counted');
      expect(r.recommendedMaxContext, isNotNull);
      expect(r.recommendedMaxContext! % 256, 0);
      expect(r.recommendedMaxContext, greaterThan(4096));
    });

    test('iOS counts weights against os_proc_available_memory with the 0.6 rule (R06 §5)', () {
      final r = assessFit(_devices['iOS 8 GB']!, _input(_models['Qwen3-4B Q4_K_M']!));
      expect(r.processCapBytes, isNull);
      expect(r.demandBytes, r.breakdown.totalBytes);
      expect(r.demandBytes, lessThanOrEqualTo(r.budgetBytes * 0.6));
    });

    test('estimated budgets (no live reading) use the jetsam table and say so', () {
      const ios = DeviceProfile(platform: DevicePlatform.ios, totalRamBytes: 8 * _gib);
      final r = assessFit(ios, _input(_models['Qwen3-4B Q4_K_M']!));
      expect(r.budgetEstimated, isTrue);
      expect(r.budgetBytes, FitConstants.iosEntitledCap - FitConstants.appOverheadBytes);
      expect(r.reasons.map((x) => x.code), contains(FitReasonCode.budgetEstimated));
      const old = DeviceProfile(platform: DevicePlatform.ios, totalRamBytes: 4 * _gib);
      expect(assessFit(old, _input(_models['Qwen3-0.6B Q4_K_M']!)).budgetBytes,
          FitConstants.ios4GbCap - FitConstants.appOverheadBytes);
    });

    test('Android 17 limiter can refuse what physical RAM would allow', () {
      final d = _android(4, 3.5).copyWith(perProcessCapBytes: 512 * _mib);
      final r = assessFit(d, _input(_models['Qwen3-0.6B Q4_K_M']!), options: const FitOptions(contextLength: 16384));
      expect(r.verdict, FitVerdict.wontFit);
      expect(r.reasons.map((x) => x.code), contains(FitReasonCode.exceedsProcessLimit));
      final pre17 = DeviceProfile(platform: DevicePlatform.android, osVersion: '16', totalRamBytes: 4 * _gib,
          availableRamBytes: (3.5 * _gib).round());
      expect(assessFit(pre17, _input(_models['Qwen3-0.6B Q4_K_M']!)).processCapBytes, isNull);
    });

    test('removed / runtime-unsupported quants never fit; advisories are attached', () {
      final d = _devices['Android 12 GB']!.copyWith(thermal: ThermalLevel.serious, lowPowerMode: true);
      final m = _models['Qwen3-0.6B Q4_K_M']!;
      final removed = assessFit(d, ModelFootprintInput(architecture: m.$1, weightBytes: m.$2, quant: QuantTypes.q4_0_4_4));
      expect(removed.verdict, FitVerdict.wontFit);
      expect(removed.reasons.first.severity, FitSeverity.blocking);
      final nv = assessFit(d, ModelFootprintInput(architecture: m.$1, weightBytes: m.$2, quant: QuantTypes.nvfp4),
          options: const FitOptions(unsupportedQuants: {'NVFP4'}));
      expect(nv.verdict, FitVerdict.wontFit);
      final codes = assessFit(d, _input(m)).reasons.map((x) => x.code);
      expect(codes, containsAll([FitReasonCode.thermal, FitReasonCode.lowPower]));
      final adreno = DeviceProfile(platform: DevicePlatform.android, osVersion: '17', totalRamBytes: 12 * _gib,
          availableRamBytes: 6 * _gib, accelerators: {Accelerator.openclAdreno});
      final iq = assessFit(adreno, ModelFootprintInput(architecture: m.$1, weightBytes: m.$2, quant: QuantTypes.iq3_m));
      expect(iq.reasons.map((x) => x.code), contains(FitReasonCode.gpuBackendUnsupportedQuant));
      final moe = assessFit(adreno, _input(_models['Qwen3-30B-A3B UD-Q4_K_XL']!));
      expect(moe.reasons.map((x) => x.code), contains(FitReasonCode.mixtureOfExperts));
    });

    test('context is clamped to the trained length', () {
      final r = assessFit(_devices['Android 12 GB']!, _input(_models['Qwen3-0.6B Q4_K_M']!),
          options: const FitOptions(contextLength: 1 << 20));
      expect(r.contextLength, 40960);
      expect(r.reasons.first.code, FitReasonCode.contextClamped);
    });
  });

  group('properties', () {
    final rnd = Random(7);
    ModelArchitecture randomArch() => ModelArchitecture.dense(
          layers: 8 + rnd.nextInt(56),
          kvHeads: [1, 2, 4, 8, 16][rnd.nextInt(5)],
          headDim: [64, 128, 256][rnd.nextInt(3)],
          embeddingLength: 512 * (1 + rnd.nextInt(16)),
          feedForwardLength: 1024 * (1 + rnd.nextInt(28)),
          vocabSize: 32000 + rnd.nextInt(230000),
          trainContextLength: 4096 * (1 + rnd.nextInt(32)),
        );

    test('more available RAM never worsens the verdict', () {
      for (var i = 0; i < 300; i++) {
        final a = randomArch();
        final weights = (0.2 + rnd.nextDouble() * 12) * _gib;
        final input = ModelFootprintInput(architecture: a, weightBytes: weights.round());
        final platform = DevicePlatform.values[rnd.nextInt(3)];
        final total = (2 + rnd.nextInt(14)) * _gib;
        final opts = FitOptions(contextLength: 256 * (1 + rnd.nextInt(128)));
        FitVerdict? prev;
        int? prevCtx;
        for (var avail = 256 * _mib; avail <= total; avail += 256 * _mib) {
          final d = DeviceProfile(platform: platform, osVersion: '17', totalRamBytes: total, availableRamBytes: avail);
          final r = assessFit(d, input, options: opts);
          if (prev != null) expect(r.verdict.isWorseThan(prev), isFalse, reason: 'avail $avail');
          if (prevCtx != null) expect(r.recommendedMaxContext ?? 0, greaterThanOrEqualTo(prevCtx));
          prev = r.verdict;
          prevCtx = r.recommendedMaxContext ?? 0;
        }
      }
    });

    test('longer context never shrinks KV nor improves the verdict', () {
      for (var i = 0; i < 200; i++) {
        final a = randomArch();
        final type = KvCacheType.values[rnd.nextInt(KvCacheType.values.length)];
        final d = _devices.values.elementAt(rnd.nextInt(_devices.length));
        final input = ModelFootprintInput(architecture: a, weightBytes: ((0.2 + rnd.nextDouble() * 4) * _gib).round());
        var prevKv = 0;
        FitVerdict? prev;
        for (var ctx = 128; ctx <= 65536; ctx *= 2) {
          final kv = estimateKvCache(a, contextLength: ctx, typeK: type, typeV: type).bytes;
          expect(kv, greaterThanOrEqualTo(prevKv));
          prevKv = kv;
          final v = assessFit(d, input, options: FitOptions(contextLength: ctx, typeK: type, typeV: type),
                  computeMaxContext: false)
              .verdict;
          if (prev != null) expect(prev.isWorseThan(v), isFalse, reason: 'ctx $ctx');
          prev = v;
        }
      }
    });

    test('quantized KV is never larger than f16', () {
      for (var i = 0; i < 100; i++) {
        final a = randomArch();
        final f16 = estimateKvCache(a, contextLength: 8192, typeK: KvCacheType.f16, typeV: KvCacheType.f16).bytes;
        for (final t in [KvCacheType.q8_0, KvCacheType.q5_1, KvCacheType.q4_0, KvCacheType.iq4_nl]) {
          expect(estimateKvCache(a, contextLength: 8192, typeK: t, typeV: t).bytes, lessThan(f16));
        }
      }
    });
  });

  group('quant recommendation', () {
    QuantCandidate cand(String tag, int bytes, {int? params}) => QuantCandidate(
        id: tag, weightBytes: bytes, quant: parseGgufQuantTag(tag), parameterCount: params);

    test('measured effective bpw beats name-implied bpw (R08 §0.20)', () {
      // gemma-3-270m-it Q2_K.gguf: 237,079,584 bytes → 7.07 bpw (corpus row 17).
      expect(effectiveBitsPerWeight(237079584, 268098176), closeTo(7.07, 0.01));
      // Qwen3-Coder-30B-A3B UD-Q4_K_XL: 17,665,334,432 bytes / 30.53B → 4.63 (row 6).
      expect(effectiveBitsPerWeight(17665334432, 30530000000), closeTo(4.63, 0.01));
    });

    test('largest quality that fits, quantized preferred, removed never chosen', () {
      final params = _qwen4b.parameterCount ?? 4022468096;
      final cands = [
        cand('BF16', 8045000000, params: params),
        cand('Q8_0', 4280000000, params: params),
        cand('Q6_K', 3310000000, params: params),
        cand('Q4_K_M', 2497280256, params: params),
        cand('Q4_0_4_4', 2380000000, params: params),
        cand('Q3_K_M', 2080000000, params: params),
        cand('IQ2_XXS', 1200000000, params: params),
      ];
      final big = recommendQuant(_devices['Android 12 GB']!, _qwen4b, cands);
      // Q8_0: 4.28 GB weights + 306 MiB KV + buffers ≈ 4.4 GiB ≤ 0.75 × 6 GiB.
      expect(big.best!.candidate.id, 'Q8_0');
      expect(big.ranked.first.candidate.id, 'BF16');
      expect(big.ranked.first.fit.verdict, FitVerdict.wontFit);
      expect(big.ranked.firstWhere((r) => r.candidate.id == 'Q4_0_4_4').excludedReason, contains('removed'));
      final mid = recommendQuant(_devices['Android 8 GB']!, _qwen4b, cands);
      expect(mid.best!.candidate.id, 'Q3_K_M');
      final ios = recommendQuant(_devices['iOS 8 GB']!, _qwen4b, cands);
      expect(ios.best!.candidate.id, 'Q4_K_M');
      final tiny = recommendQuant(_devices['Android 4 GB']!, _qwen4b, cands);
      expect(tiny.best, isNull);
      expect(tiny.summary, isNotEmpty);
    });

    test('a float file is recommended only when no quantized file fits', () {
      final cands = [cand('F16', 1192000000, params: 596049920), cand('Q8_0', 639000000, params: 596049920)];
      expect(recommendQuant(_devices['Android 12 GB']!, _qwen06, cands).best!.candidate.id, 'Q8_0');
      expect(recommendQuant(_devices['Android 12 GB']!, _qwen06, [cands.first]).best!.candidate.id, 'F16');
    });

    test('runtime-unsupported and ternary types are excluded', () {
      final cands = [cand('NVFP4', 2400000000), cand('TQ1_0', 900000000), cand('Q4_K_M', 2497280256)];
      final r = recommendQuant(_devices['Android 12 GB']!, _qwen4b, cands,
          options: const FitOptions(unsupportedQuants: {'NVFP4'}));
      expect(r.best!.candidate.id, 'Q4_K_M');
      expect(r.ranked.where((x) => !x.eligible).map((x) => x.candidate.id).toSet(), {'NVFP4', 'TQ1_0'});
    });

    test('nothing fits with headroom → the best tight one as fallback', () {
      final r = recommendQuant(_devices['Android 12 GB']!, _qwen8b, [cand('Q4_K_M', 5027783488), cand('Q8_0', 8710000000)]);
      expect(r.best, isNull);
      expect(r.fallback!.candidate.id, 'Q4_K_M');
    });
  });

  group('storage', () {
    test('verdicts include temp bytes and the safety margin', () {
      expect(assessStorage(downloadBytes: 2 * _gib, freeBytes: 10 * _gib).verdict, StorageVerdict.ok);
      expect(assessStorage(downloadBytes: 2 * _gib, freeBytes: (2.5 * _gib).round()).verdict, StorageVerdict.tight);
      expect(assessStorage(downloadBytes: 2 * _gib, freeBytes: _gib).verdict, StorageVerdict.insufficient);
      expect(assessStorage(downloadBytes: 2 * _gib, freeBytes: null).verdict, StorageVerdict.unknown);
      final part = assessStorage(downloadBytes: 70 * _gib, tempBytes: 37 * _gib, freeBytes: 100 * _gib);
      expect(part.requiredBytes, 107 * _gib);
      expect(part.verdict, StorageVerdict.insufficient);
      final resumed = assessStorage(downloadBytes: 4 * _gib, alreadyHaveBytes: 3 * _gib, freeBytes: (2.2 * _gib).round());
      expect(resumed.requiredBytes, _gib);
      expect(resumed.verdict, StorageVerdict.ok);
    });
  });

  test('DeviceProfile JSON round-trips', () {
    const d = DeviceProfile(
      platform: DevicePlatform.android,
      osVersion: '17',
      totalRamBytes: 8 * _gib,
      availableRamBytes: 3 * _gib,
      cpuClass: CpuClass.high,
      cpuFeatures: {'i8mm', 'dotprod'},
      accelerators: {Accelerator.openclAdreno},
      thermal: ThermalLevel.fair,
      model: 'Test phone',
    );
    expect(DeviceProfile.fromJson(d.toJson()).toJson(), d.toJson());
    expect(d.osMajor, 17);
  });
}
