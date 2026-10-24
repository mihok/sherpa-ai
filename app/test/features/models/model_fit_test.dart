import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa/features/models/state/model_fit.dart';
import 'package:sherpa/features/models/widgets/fit_explain.dart';
import 'package:sherpa/features/models/widgets/format.dart';
import 'package:sherpa_hub/sherpa_hub.dart';

import 'support/models_rig.dart';

HubRepoFile f(String path, int size) => HubRepoFile(path: path, size: size, lfsSha256: 'a' * 64, lfsSize: size);

void main() {
  test('the projector is paired like llama.cpp does and counted in the download size', () {
    const repo = 'ggml-org/gemma-3-4b-it-GGUF';
    final d = fixtureDetails(repo, [
      f('gemma-3-4b-it-Q4_K_M.gguf', 2489757856),
      f('gemma-3-4b-it-Q8_0.gguf', 4130401920),
      f('mmproj-gemma-3-4b-it-f16.gguf', 851251104),
      f('pytorch_model.bin', 1000),
    ]);
    final a = assessVariants(d, phone12, shape: llama1bShape);
    final q4 = a.rows.firstWhere((r) => r.label == 'Q4_K_M');
    expect(q4.mmproj?.path, 'mmproj-gemma-3-4b-it-f16.gguf');
    expect(q4.downloadBytes, 2489757856 + 851251104);
    expect(q4.fit!.breakdown.mmprojBytes, 851251104, reason: 'the projector counts toward memory too');
    final pickle = a.rows.firstWhere((r) => r.variant.weights.first.path == 'pytorch_model.bin');
    expect(pickle.kind, FitBadgeKind.blocked, reason: 'listed, greyed, never downloadable');
    expect(pickle.reason.toLowerCase(), contains('pickle'));
    expect(a.rows.last, same(pickle), reason: 'blocked rows sort last');
    expect(a.otherFiles.map((o) => o.$1.path), isNot(contains('mmproj-gemma-3-4b-it-f16.gguf')));
  });

  test('MLX is gated to iOS; the summary names quant labels, not paths', () {
    const repo = 'mlx-community/Qwen3-0.6B-4bit';
    final d = fixtureDetails(repo, [
      f('model.safetensors', 335000000),
      const HubRepoFile(path: 'config.json', size: 900, oid: 'b'),
    ]);
    final android = assessVariants(d, phone12);
    expect(android.rows.single.kind, FitBadgeKind.blocked);
    expect(android.rows.single.reason, contains('iPhone and iPad only'));
    expect(android.rows.single.canDownload, isFalse);
    const ios = DeviceProfile(platform: DevicePlatform.ios, totalRamBytes: 8 * gib);
    final onIos = assessVariants(d, ios);
    expect(onIos.rows.single.kind, FitBadgeKind.fits, reason: 'sized from its files');
    expect(onIos.rows.single.needsConfirm, isFalse);
    expect(onIos.rows.single.fit!.breakdown.weightsBytes, 335000000);
    expect(onIos.rows.single.reason, isNot(contains('header')));
    expect(onIos.summary, contains('estimated from its file sizes'));
    expect(fitBreakdown(onIos.rows.single.fit!, runtime: SherpaRuntime.mlx), contains('KV cache (not known yet)'));
    // With the repo's config.json the KV cache is counted too.
    final withConfig = assessVariants(d, ios, mlxConfig: const {
      'model_type': 'qwen3',
      'num_hidden_layers': 28,
      'num_attention_heads': 16,
      'num_key_value_heads': 8,
      'head_dim': 128,
      'max_position_embeddings': 40960,
    });
    final fit = withConfig.rows.single.fit!;
    expect(fit.breakdown.kvBytes, greaterThan(0));
    expect(fit.recommendedMaxContext, isNotNull);
    expect(fitBreakdown(fit, runtime: SherpaRuntime.mlx), contains('8-bit'));

    final gguf = assessVariants(fixtureDetails(llama1b, llama1bFiles), phone12, shape: llama1bShape);
    expect(gguf.summary, startsWith('Q8_0 is the best quality'));
  });

  test('LiteRT on Android: the file plus its CPU weight cache, for memory and storage', () {
    const repo = 'litert-community/Gemma3-1B-IT';
    final d = fixtureDetails(repo, [f('gemma3-1b-it-int4.litertlm', 584 << 20)]);
    final row = assessVariants(d, phone12).rows.single;
    expect(row.variant.runtime, SherpaRuntime.litert);
    expect(row.kind, FitBadgeKind.fits);
    expect(row.fit!.breakdown.repackBytes, 584 << 20);
    expect(row.runtimeCacheBytes, 584 << 20);
    expect(fitBreakdown(row.fit!, runtime: SherpaRuntime.litert), contains('CPU weight cache'));
    final onIos = assessVariants(d, const DeviceProfile(platform: DevicePlatform.ios, totalRamBytes: 8 * gib)).rows.single;
    expect(onIos.kind, FitBadgeKind.blocked, reason: 'LiteRT on iOS stays blocked');
    expect(onIos.reason, 'LiteRT-LM models run on Android only.');
  });

  test('breakdown and formatting explain the numbers', () {
    final a = assessVariants(fixtureDetails(llama1b, llama1bFiles), phone12, shape: llama1bShape);
    final q4 = a.rows.firstWhere((r) => r.label == 'Q4_K_M');
    final text = fitBreakdown(q4.fit!);
    expect(text, allOf(contains('Weights 770 MB'), contains('KV cache'), contains('4K context, q8_0'), contains('estimated from total RAM')));
    expect(contextExplanation(q4.fit!, trained: 131072), contains('trained for 128K'));
    expect(formatBytes(807694464), '770 MB');
    expect(formatBytes(2479595360), '2.3 GB');
    expect(formatBytesOf(1 << 30, 3 << 30), '1.0 of 3.0 GB');
    expect(formatEta(const Duration(minutes: 80)), '1 h 20 min left');
    expect(formatCount(155390), '155K');
    expect(formatParams(1235814400), '1.2B');
    expect(formatContext(32768), '32K');
  });

  test('live progress moves from the first megabytes; finished sizes read the same', () {
    const mb = 1 << 20;
    const gb = 1 << 30;
    final total = (1.7 * gb).round();
    expect(formatBytesOf(0, total), '0 MB of 1.7 GB');
    expect(formatBytesOf(3 * mb, total), '3 MB of 1.7 GB', reason: 'not "0.0 of 1.7 GB" until 50 MB arrive');
    expect(formatBytesOf(48 * mb, total), '48 MB of 1.7 GB');
    expect(formatBytesOf(900 * mb, total), '900 MB of 1.7 GB');
    expect(formatBytesOf((1.2 * gb).round(), (2.3 * gb).round()), '1.2 of 2.3 GB', reason: 'past 1 GB both in GB');
    expect(formatBytesOf(512 * mb, 18 * gb), '512 MB of 18 GB');
    expect(formatBytesOf(5 * gb, 18 * gb), '5 of 18 GB');
    expect(formatBytesOf(12 * mb, 812 * mb), '12 of 812 MB');
    expect(formatBytes(total), '1.7 GB', reason: 'a finished size');
  });

  test('card estimates come from the parameter count and say so', () {
    final e = entry('unsloth/Qwen3-8B-GGUF');
    final small = estimateCardFit(e, phone4)!;
    expect(small.verdict, FitVerdict.wontFit);
    expect(small.explanation, contains('Estimated from 8B parameters'));
    expect(estimateCardFit(e, phone12)!.estimatedBytes, small.estimatedBytes);
    expect(estimateCardFit(entry('google/gemma-3n-E2B-it-litert-lm', tags: const ['litert-lm']), phone12), isNull,
        reason: 'effective-parameter labels are not raw sizes');
  });
}
