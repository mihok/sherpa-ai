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
    expect(onIos.rows.single.kind, FitBadgeKind.unknown, reason: 'no GGUF header to size it');
    expect(onIos.rows.single.needsConfirm, isTrue);

    final gguf = assessVariants(fixtureDetails(llama1b, llama1bFiles), phone12, shape: llama1bShape);
    expect(gguf.summary, startsWith('Q8_0 is the best quality'));
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
