import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa/features/models/state/model_fit.dart';
import 'package:sherpa/features/models/state/variant_download.dart';
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
    expect(pickle.kind, FitBadgeKind.unsupported, reason: 'listed, greyed, never downloadable: nothing runs pickles');
    expect(pickle.reason, startsWith("Sherpa can't run PyTorch weights (.bin, .pt)."));
    expect(a.rows.last, same(pickle), reason: 'unavailable rows sort last');
    expect(a.otherFiles.map((o) => o.$1.path), isNot(contains('mmproj-gemma-3-4b-it-f16.gguf')));
  });

  test('MLX is gated to iOS; the summary names quant labels, not paths', () {
    const repo = 'mlx-community/Qwen3-0.6B-4bit';
    final d = fixtureDetails(repo, [
      f('model.safetensors', 335000000),
      const HubRepoFile(path: 'config.json', size: 900, oid: 'b'),
    ]);
    final android = assessVariants(d, phone12);
    expect(android.rows.single.kind, FitBadgeKind.unsupported, reason: 'not for this phone, but nothing is broken');
    expect(android.rows.single.reason, 'MLX models run on iPhone and iPad only.');
    expect(android.rows.single.canDownload, isFalse);
    expect(android.notForThisDevice, isTrue);
    expect(android.summary, startsWith('Nothing in this repository runs on Android.'));
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
    expect(onIos.kind, FitBadgeKind.unsupported, reason: 'LiteRT on iOS stays unavailable');
    expect(onIos.reason, 'LiteRT-LM models run on Android only.');
  });

  test('an MLX conversion known by its Hub tags fits an iPhone and its download is planned the same way', () {
    const repo = 'RecursiveSI/flint-int4';
    final d = fixtureDetails(repo, [
      f('model.safetensors', 2 << 30),
      const HubRepoFile(path: 'config.json', size: 900, oid: 'b'),
      const HubRepoFile(path: 'tokenizer_config.json', size: 9700, oid: 'c'),
    ], libraryName: 'mlx', tags: const ['mlx', 'safetensors']);
    final row = assessVariants(d, const DeviceProfile(platform: DevicePlatform.ios, totalRamBytes: 8 * gib)).rows.single;
    expect(row.variant.runtime, SherpaRuntime.mlx);
    expect(row.kind, FitBadgeKind.fits);
    final plan = planVariant(d, row);
    expect(plan, isA<DownloadPlan>().having((p) => p.variant.format, 'format', ModelFormat.mlx),
        reason: 'planned with the tags the page used, not refused as "No mlx variant"');
    expect(assessVariants(d, phone12).rows.single.reason, 'MLX models run on iPhone and iPad only.');
  });

  group('a format this device does not run', () {
    const iphone = DeviceProfile(platform: DevicePlatform.ios, totalRamBytes: 8 * gib);

    test('Transformers weights on Android: names the format and what Android runs, and points to GGUF', () {
      final a = assessVariants(fixtureDetails(llamaBase, llamaBaseFiles), phone12);
      final row = a.rows.single;
      expect(row.kind, FitBadgeKind.unsupported);
      expect(row.canDownload, isFalse);
      expect(row.unavailable, isTrue);
      expect(row.blockedReasons, isEmpty, reason: 'nothing is wrong with the files');
      expect(row.unsupportedReasons, ["Sherpa can't run Transformers weights (safetensors)."],
          reason: 'what runs here and what to look for are said once, in the summary');
      expect([row.reason, a.summary].join(), isNot(contains('MLX')), reason: 'nothing about iPhone-only formats');
      expect(a.notForThisDevice, isTrue);
      expect(a.summary,
          'Nothing in this repository runs on Android. Sherpa on Android runs GGUF and LiteRT-LM models. '
          'Look for a GGUF version of this model.');
    });

    test('on an iPhone the same repo names GGUF and MLX, and offers versions in both', () {
      final a = assessVariants(fixtureDetails(llamaBase, llamaBaseFiles), iphone);
      expect(a.rows.single.unsupportedReasons, ["Sherpa can't run Transformers weights (safetensors)."]);
      expect(a.summary,
          'Nothing in this repository runs on iPhone or iPad. Sherpa on iPhone and iPad runs GGUF and MLX models. '
          'Look for a GGUF or MLX version of this model.');
      expect(versionFormats(DevicePlatform.ios), [HubFormatFilter.gguf, HubFormatFilter.mlx]);
      expect(versionFormats(DevicePlatform.android), [HubFormatFilter.gguf]);
    });

    test('a repo of many unrunnable files says where to look once, not on every row', () {
      // onnx-community/Qwen3-0.6B-ONNX: one row per ONNX file.
      final d = fixtureDetails('onnx-community/Qwen3-0.6B-ONNX', [
        for (final q in ['model', 'model_fp16', 'model_int8', 'model_q4', 'model_q4f16']) f('onnx/$q.onnx', 600 << 20),
      ]);
      final a = assessVariants(d, phone12);
      expect(a.rows, hasLength(5));
      expect(a.notForThisDevice, isTrue);
      const lookFor = 'Look for a GGUF version of this model.';
      final said = [a.summary, for (final r in a.rows) ...r.unsupportedReasons, for (final r in a.rows) r.reason];
      expect(said.where((x) => x.contains(lookFor)), hasLength(1));
      expect(said.where((x) => x.contains('Sherpa on Android runs')), hasLength(1));
      expect(a.rows.first.reason, "Sherpa can't run ONNX models.");
    });

    test('a broken GGUF upload is not blamed on the platform', () {
      final d = fixtureDetails('acme/Thing-1B-GGUF', [f('Thing-1B-Q4_K_M-00001-of-00002.gguf', 400 << 20), f('pytorch_model.bin', 1000)]);
      final a = assessVariants(d, phone12);
      expect(a.rows.every((r) => r.unavailable), isTrue);
      expect(a.notForThisDevice, isFalse, reason: 'GGUF runs here; its missing part is the story');
      expect(a.summary, 'Nothing in this repository can run in Sherpa.');
      final gguf = a.rows.firstWhere((r) => r.variant.runtime == SherpaRuntime.llamaCpp);
      expect(gguf.kind, FitBadgeKind.blocked);
      expect(gguf.reason, 'Missing part(s) 2 of 2.');
    });

    test("old GGML files read as a format Sherpa can't run, not as pickles", () {
      final d = fixtureDetails('TheBloke/Llama-2-7B-GGML', [f('llama-2-7b.ggmlv3.q4_0.bin', 3825517184), f('llama-2-7b.ggmlv3.q8_0.bin', 7160799872)]);
      for (final device in [phone12, iphone]) {
        final a = assessVariants(d, device);
        for (final r in a.rows) {
          expect(r.kind, FitBadgeKind.unsupported, reason: '${device.platform} ${r.label}');
          expect(r.reason, "Sherpa can't run old GGML files (llama.cpp now reads GGUF).");
          expect(r.blockedReasons, isEmpty);
        }
      }
    });

    test('TensorFlow Lite files are not offered on Android as LiteRT-LM', () {
      final d = fixtureDetails('openai-community/gpt2', [
        f('64.tflite', 248000000),
        f('64-fp16.tflite', 124000000),
        f('model.safetensors', 548000000),
        const HubRepoFile(path: 'config.json', size: 665, oid: 'b'),
      ]);
      final a = assessVariants(d, phone12);
      expect(a.rows.where((r) => r.canDownload), isEmpty);
      expect(a.rows.where((r) => r.variant.weights.first.path.endsWith('.tflite')).map((r) => r.reason).toSet(),
          {"Sherpa can't run TensorFlow Lite .tflite files."});
      expect(a.summary, contains('Sherpa on Android runs GGUF and LiteRT-LM models.'),
          reason: 'what runs here is said for this device, by the summary');
      expect(a.notForThisDevice, isTrue);
      final onIos = assessVariants(d, iphone).rows.firstWhere((r) => r.variant.weights.first.path == '64.tflite');
      expect(onIos.reason, isNot(contains('Android only')), reason: 'they do not run on Android either');
      expect(onIos.reason, isNot(contains('LiteRT-LM')), reason: 'no advice about a format an iPhone never runs');
    });

    test("on Android an MLX folder's file problems are moot: the row says only that MLX runs on iPhone", () {
      // OBLITERATUS/Qwen3.8-27B-OBLITERATED (library_name mlx): two shard
      // sets in one folder, next to GGUF files.
      const repo = 'OBLITERATUS/Qwen3.8-27B-OBLITERATED';
      final files = [
        const HubRepoFile(path: 'config.json', size: 3000, oid: 'b'),
        for (var i = 1; i <= 2; i++) f('model-0000$i-of-00002.safetensors', 2 << 30),
        for (var i = 1; i <= 3; i++) f('model-0000$i-of-00003.safetensors', 1 << 30),
        f('Qwen3.8-27B-OBLITERATED-Q4_K_M.gguf', 16 << 30),
      ];
      CatalogModelDetails details({HubRepoSecurity? security}) => fixtureDetails(repo, files,
          libraryName: 'mlx', pipelineTag: 'text-generation', tags: const ['mlx'], security: security);
      VariantRow mlxRow(ModelAssessment a) => a.rows.singleWhere((r) => r.variant.runtime == SherpaRuntime.mlx);

      final android = mlxRow(assessVariants(details(), phone12));
      expect(android.kind, FitBadgeKind.unsupported);
      expect(android.blockedReasons, isEmpty, reason: 'nothing to fix on a phone that never loads it');
      expect(android.unsupportedReasons, ['MLX models run on iPhone and iPad only.']);
      expect(android.reason, 'MLX models run on iPhone and iPad only.', reason: 'what the badge and screen readers say');

      final ios = mlxRow(assessVariants(details(), iphone));
      expect(ios.kind, FitBadgeKind.blocked, reason: 'on an iPhone the problem is the story');
      expect(ios.blockedReasons, ['This folder holds more than one set of weights (in 2 and 3 parts).']);

      // The Hub's verdict on a file holds on any device.
      const sec = HubRepoSecurity(scansDone: true, filesWithIssues: {'model-00001-of-00002.safetensors': HubScanStatus.unsafe});
      final flagged = mlxRow(assessVariants(details(security: sec), phone12));
      expect(flagged.kind, FitBadgeKind.blocked);
      expect(flagged.blockedReasons, ['The Hub flags model-00001-of-00002.safetensors as unsafe']);
      expect(flagged.unsupportedReasons, ['MLX models run on iPhone and iPad only.']);

      // Nor are a pickle's (a format nothing runs): its name and its missing part.
      final pickles = assessVariants(
          fixtureDetails('acme/Thing-1B', [f('pytorch_model-00001-of-00002.bin', 1000), f('Thing-1B-Q4_K_M.gguf', 400 << 20)]),
          phone12);
      final pickle = pickles.rows.singleWhere((r) => r.variant.format == ModelFormat.pickle);
      expect(pickle.kind, FitBadgeKind.unsupported);
      expect(pickle.blockedReasons, isEmpty);
      expect(pickle.reason, "Sherpa can't run PyTorch weights (.bin, .pt). Sherpa on Android runs GGUF and LiteRT-LM models.");
    });

    test('an MLX speech model tagged mlx is not offered on an iPhone as a model MLX loads', () {
      final d = fixtureDetails('theoracleguy/whisper-large-v3-turbo', [
        f('weights.safetensors', 1617000000),
        const HubRepoFile(path: 'config.json', size: 1300, oid: 'b'),
      ], libraryName: 'mlx', pipelineTag: 'automatic-speech-recognition', tags: const ['mlx', 'automatic-speech-recognition']);
      final row = assessVariants(d, iphone).rows.single;
      expect(row.kind, FitBadgeKind.unsupported);
      expect(row.canDownload, isFalse);
    });

    test('a real problem stays a problem next to it; a repo with something that runs is not "not for this device"', () {
      const sec = HubRepoSecurity(scansDone: true, filesWithIssues: {'model.safetensors': HubScanStatus.unsafe});
      final unsafe = assessVariants(fixtureDetails(llamaBase, llamaBaseFiles, security: sec), phone12);
      expect(unsafe.rows.single.kind, FitBadgeKind.blocked);
      expect(unsafe.rows.single.blockedReasons.join(), contains('unsafe'));
      expect(unsafe.rows.single.unsupportedReasons, isNotEmpty);
      expect(unsafe.notForThisDevice, isTrue, reason: 'a GGUF version is still the way forward');

      final gguf = assessVariants(fixtureDetails(llama1b, [...llama1bFiles, f('pytorch_model.bin', 1000)]), phone12,
          shape: llama1bShape);
      expect(gguf.rows.last.unsupportedReasons.last, 'Sherpa on Android runs GGUF and LiteRT-LM models.',
          reason: 'the GGUF variants above are the answer, not another repo');
      expect(gguf.notForThisDevice, isFalse);
      expect(gguf.summary, startsWith('Q8_0 is the best quality'));
    });
  });

  test('a tag-only MLX nvfp4 conversion runs on an iPhone like its mlx-community twin', () {
    const iphone = DeviceProfile(platform: DevicePlatform.ios, totalRamBytes: 8 * gib);
    final files = [
      f('model.safetensors', 600 << 20),
      const HubRepoFile(path: 'config.json', size: 1300, oid: 'b'),
    ];
    final a = assessVariants(
        fixtureDetails('npario/MiniCPM-V-4.7-1B-nvfp4', files,
            libraryName: 'mlx', pipelineTag: 'text-generation', tags: const ['mlx', 'text-generation']),
        iphone);
    expect(a.rows.single.kind, FitBadgeKind.fits, reason: a.rows.single.reason);
    expect(a.summary, isNot(contains('Nothing')));
    expect(assessVariants(fixtureDetails('mlx-community/MiniCPM-V-4.7-1B-nvfp4', files), iphone).rows.single.kind,
        FitBadgeKind.fits);
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
