import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_hub/sherpa_hub.dart';
import 'package:test/test.dart';

const _commit = 'c03ac9c3bdc5ae949111acb945338933f396e4d7';
const _repo = 'unsloth/Qwen3.8-27B-GGUF';

/// Tree entries in the live response shape (R08 §4.1/§11); sizes follow the
/// real repos, hashes are synthetic.
List<HubRepoFile> _tree() => [
      for (final e in jsonDecode(File('test/fixtures/hub/tree_qwen38_gguf.json').readAsStringSync()) as List)
        HubRepoFile.fromTreeJson((e as Map).cast<String, Object?>()),
    ];

HubRepoFile _lfs(String path, int size) =>
    HubRepoFile(path: path, size: size, lfsSha256: 'a' * 64, lfsSize: size, xetHash: 'b' * 64, oid: 'c' * 40);

HubRepoFile _small(String path, int size) => HubRepoFile(path: path, size: size, oid: 'd' * 40);

T _ok<T extends PlanOutcome>(PlanOutcome o) {
  if (o is PlanRefused) fail('refused: ${o.reasons}');
  return o as T;
}

void main() {
  group('variant grouping', () {
    test('quants, shard sets and blocked variants of a GGUF repo', () {
      final vs = groupVariants(_repo, _tree());
      final byLabel = {for (final v in vs) v.label: v};
      expect(byLabel.keys, containsAll(['BF16', 'Q8_0', 'Q4_K_M', 'UD-Q4_K_XL', 'UD-IQ1_S', 'Q4_0_4_4', 'Q5_K_M']));
      expect(byLabel.keys.where((l) => l.contains('mmproj') || l.contains('mtp') || l.contains('imatrix')), isEmpty,
          reason: 'sidecars are not variants');
      expect(byLabel['BF16']!.weights.map((f) => f.path),
          ['BF16/Qwen3.8-27B-BF16-00001-of-00002.gguf', 'BF16/Qwen3.8-27B-BF16-00002-of-00002.gguf']);
      expect(byLabel['BF16']!.weightBytes, 49655154016 + 4440652032);
      expect(byLabel['BF16']!.id, 'BF16/Qwen3.8-27B-BF16');
      expect(byLabel['UD-IQ1_S']!.missingParts, [2]);
      expect(byLabel['UD-IQ1_S']!.usable, isFalse);
      expect(byLabel['Q4_0_4_4']!.blockedReasons.single, contains('removed'));
      expect(byLabel['Q5_K_M']!.blockedReasons.single, contains('flags'));
      expect(byLabel['Q8_0']!.usable, isTrue);
      expect(byLabel['Q8_0']!.warnings.single, contains('caution'));
      final pickle = vs.firstWhere((v) => v.format == ModelFormat.pickle);
      expect(pickle.usable, isFalse);
      expect(vs.takeWhile((v) => v.usable).map((v) => v.label), ['BF16', 'Q8_0', 'Q4_K_M', 'UD-Q4_K_XL'],
          reason: 'usable first, best quality first');
      expect(defaultVariant(vs)!.label, 'Q4_K_M', reason: "llama.cpp's -hf default");
    });

    test('MLX repo: one variant with its config/tokenizer files', () {
      final files = [
        _small('.gitattributes', 1519),
        _small('README.md', 3000),
        _small('config.json', 1200),
        _small('tokenizer_config.json', 9700),
        _lfs('tokenizer.json', 11422654),
        _lfs('model.safetensors', 4610000000),
        _small('model.safetensors.index.json', 64000),
      ];
      final vs = groupVariants('mlx-community/Qwen3-8B-4bit', files);
      expect(vs, hasLength(1));
      final v = vs.single;
      expect(v.format, ModelFormat.mlx);
      expect(v.runtime, SherpaRuntime.mlx);
      expect(v.usable, isTrue);
      expect(v.support.map((f) => f.path).toSet(),
          {'config.json', 'tokenizer_config.json', 'tokenizer.json', 'model.safetensors.index.json'});
      final plan = _ok<DownloadPlan>(planDownload(repo: 'mlx-community/Qwen3-8B-4bit', commit: _commit, files: files));
      expect(plan.files.first.path, 'model.safetensors');
      final cfg = plan.files.firstWhere((f) => f.path == 'config.json');
      expect(cfg.gitBlobSha1, 'd' * 40, reason: 'small files verify by git blob sha1');
      expect(cfg.sha256, isNull);
      expect(plan.totalBytes, 4610000000 + 11422654 + 1200 + 9700 + 64000);
    });

    test('formats Sherpa cannot run are kept but blocked', () {
      final gptq = groupVariants('Qwen/Qwen2.5-7B-Instruct-GPTQ-Int4',
          [_small('config.json', 900), _lfs('model-00001-of-00002.safetensors', 3e9.toInt()), _lfs('model-00002-of-00002.safetensors', 2e9.toInt())]);
      expect(gptq.single.usable, isFalse);
      expect(gptq.single.blockedReasons.join(), contains('CUDA'));
      expect(gptq.single.unsupportedFormat, "Sherpa can't run GPTQ weights (made for CUDA GPUs).");
      expect(gptq.single.fileProblems, isEmpty, reason: 'the CUDA-only flag only restates the format');
      final onnx = groupVariants('HuggingFaceTB/SmolLM2-135M-Instruct', [_lfs('onnx/model_q4f16.onnx', 1e8.toInt())]);
      expect(onnx.single.blockedReasons, ["Sherpa can't run ONNX models."]);
      final pickle = groupVariants('mistralai/Mistral-7B-Instruct-v0.1', [_lfs('pytorch_model.bin', 9)]).single;
      expect(pickle.unsupportedFormat, "Sherpa can't run PyTorch weights (.bin, .pt).");
      expect(pickle.fileProblems, isNotEmpty, reason: 'unsafe to load is a problem, not a format fact');
      expect(pickle.fileProblems, everyElement(contains(RegExp('pickle', caseSensitive: false))));
    });

    // Qwen/Qwen3-0.6B's own listing: plain Transformers weights.
    final transformers = [
      _small('config.json', 726),
      _small('generation_config.json', 239),
      _lfs('model.safetensors', 1503300328),
      _small('tokenizer_config.json', 9732),
      _lfs('tokenizer.json', 11422654),
      _small('merges.txt', 1671853),
      _small('vocab.json', 2776833),
    ];

    test('Transformers weights: blocked with a reason that names the format, and nothing about MLX names', () {
      final v = groupVariants('Qwen/Qwen3-0.6B', transformers).single;
      expect(v.runtime, SherpaRuntime.none);
      expect(v.usable, isFalse);
      expect(v.unsupportedFormat, "Sherpa can't run Transformers weights (safetensors).");
      expect(v.blockedReasons, [v.unsupportedFormat]);
      expect(v.fileProblems, isEmpty);
      expect(v.blockedReasons.join(), isNot(contains('MLX')));
      // Real problems stay problems next to it.
      final noConfig = groupVariants('Qwen/Qwen3-0.6B', [for (final f in transformers) if (f.path != 'config.json') f]).single;
      expect(noConfig.fileProblems, ['config.json is missing']);
      const sec = HubRepoSecurity(scansDone: true, filesWithIssues: {'model.safetensors': HubScanStatus.unsafe});
      expect(groupVariants('Qwen/Qwen3-0.6B', transformers, repoSecurity: sec).single.fileProblems.join(), contains('unsafe'));
      final refused = planDownload(repo: 'Qwen/Qwen3-0.6B', commit: _commit, files: transformers) as PlanRefused;
      expect(refused.reasons.join(), isNot(contains('MLX')));
    });

    test('an MLX conversion named without "mlx" is MLX by its Hub library_name or tags', () {
      // RecursiveSI/flint-int4: library_name mlx, tagged mlx; no "mlx" in the name.
      const repo = 'RecursiveSI/flint-int4';
      final files = [
        _small('config.json', 1100),
        _small('tokenizer_config.json', 9700),
        _lfs('tokenizer.json', 11422654),
        _lfs('model-00001-of-00002.safetensors', 2e9.toInt()),
        _lfs('model-00002-of-00002.safetensors', 1e9.toInt()),
      ];
      expect(groupVariants(repo, files).single.runtime, SherpaRuntime.none, reason: 'the names alone say safetensors');
      for (final hints in [
        hubFormatHints(libraryName: 'mlx', pipelineTag: 'text-generation', tags: const ['mlx', 'safetensors']),
        hubFormatHints(libraryName: 'mlx', tags: const ['mlx']),
        hubFormatHints(pipelineTag: 'image-text-to-text', tags: const ['mlx']),
      ]) {
        final v = groupVariants(repo, files, formatHints: hints).single;
        expect(v.format, ModelFormat.mlx, reason: '$hints');
        expect(v.runtime, SherpaRuntime.mlx);
        expect(v.usable, isTrue);
        expect(v.unsupportedFormat, isNull);
        expect(v.weights, hasLength(2));
        final plan = planDownload(repo: repo, commit: _commit, files: files, quant: v.id, formatHints: hints);
        expect(plan, isA<DownloadPlan>().having((p) => p.variant.format, 'format', ModelFormat.mlx));
      }
      final transformersHints = hubFormatHints(libraryName: 'transformers', pipelineTag: 'text-generation', tags: const [
        'transformers',
        'safetensors',
      ]);
      expect(groupVariants('Qwen/Qwen3-0.6B', transformers, formatHints: transformersHints).single.runtime,
          SherpaRuntime.none, reason: 'only an mlx hint makes safetensors MLX');
      final noConfig = groupVariants(repo, files.skip(1).toList(), formatHints: const {'mlx'}).single;
      expect(noConfig.fileProblems, ['config.json is missing'], reason: 'MLX still needs its config');
    });

    test("an MLX speech, voice or image model's mlx tag does not make it a model Sherpa runs", () {
      // theoracleguy/whisper-large-v3-turbo: library_name mlx, tagged mlx;
      // mlx-swift-lm's language-model factory cannot load it.
      const repo = 'theoracleguy/whisper-large-v3-turbo';
      final files = [_small('config.json', 1300), _lfs('weights.safetensors', 1617000000)];
      for (final (pipeline, library) in [
        ('automatic-speech-recognition', 'mlx'),
        ('text-to-speech', 'mlx'),
        ('feature-extraction', 'mlx'),
        ('text-to-image', 'mflux'),
        (null, 'mflux'),
      ]) {
        final hints = hubFormatHints(libraryName: library, pipelineTag: pipeline, tags: ['mlx', ?pipeline]);
        expect(hints, isEmpty, reason: '$library $pipeline');
        final v = groupVariants(repo, files, formatHints: hints).single;
        expect(v.runtime, SherpaRuntime.none, reason: '$library $pipeline');
        expect(v.usable, isFalse);
        expect(planDownload(repo: repo, commit: _commit, files: files, formatHints: hints), isA<PlanRefused>());
      }
    });

    test('a tag-only MLX nvfp4 conversion is read as MLX all the way, with no CUDA-only flag', () {
      // nativ-community/LFM2.5-24B-A2B-Preview-nvfp4: library_name mlx, tagged mlx, text-generation.
      final files = [
        _small('config.json', 2100),
        _small('tokenizer_config.json', 9700),
        _lfs('tokenizer.json', 4733000),
        _lfs('model-00001-of-00002.safetensors', 5e9.toInt()),
        _lfs('model-00002-of-00002.safetensors', 4e9.toInt()),
      ];
      final hints = hubFormatHints(libraryName: 'mlx', pipelineTag: 'text-generation', tags: const ['mlx']);
      final tagged = groupVariants('nativ-community/LFM2.5-24B-A2B-Preview-nvfp4', files, formatHints: hints).single;
      final named = groupVariants('mlx-community/LFM2.5-24B-A2B-Preview-nvfp4', files).single;
      expect(tagged.format, ModelFormat.mlx);
      expect(tagged.usable, isTrue, reason: '${tagged.blockedReasons}');
      expect(tagged.blockedReasons.join(), isNot(contains('CUDA')));
      expect(named.usable, isTrue);
      expect(tagged.label, named.label, reason: 'the same files under an mlx-community name');
      expect(parseModelName('nativ-community/LFM2.5-24B-A2B-Preview-nvfp4', repoHints: hints).format, ModelFormat.mlx,
          reason: "the repo's own name reads MLX too");
      expect(parseModelName('mradermacher/Qwen3.8-27B-OBLITERATED-GGUF', repoHints: const {'mlx'}).format, ModelFormat.gguf,
          reason: 'a format the name says wins over the tag');
    });

    test('an MLX folder holding two shard sets side by side is not offered as one model', () {
      // OBLITERATUS/Qwen3.8-27B-OBLITERATED (library_name mlx): -of-00018,
      // -of-00028 and an -of-00001 extra in one folder, next to GGUF files.
      final files = [
        _small('config.json', 3000),
        _small('tokenizer_config.json', 9700),
        _lfs('tokenizer.json', 11422654),
        for (var i = 1; i <= 18; i++) _lfs('model-${'$i'.padLeft(5, '0')}-of-00018.safetensors', 3e9.toInt()),
        for (var i = 1; i <= 28; i++) _lfs('model-${'$i'.padLeft(5, '0')}-of-00028.safetensors', 2e9.toInt()),
        _lfs('model-extra-00001-of-00001.safetensors', 1e8.toInt()),
        _lfs('Qwen3.8-27B-OBLITERATED-Q4_K_M.gguf', 16e9.toInt()),
      ];
      final hints = hubFormatHints(libraryName: 'mlx', pipelineTag: 'text-generation', tags: const ['mlx']);
      final vs = groupVariants('OBLITERATUS/Qwen3.8-27B-OBLITERATED', files, formatHints: hints);
      final mlx = vs.singleWhere((v) => v.format == ModelFormat.mlx);
      expect(mlx.usable, isFalse);
      expect(mlx.fileProblems, ['This folder holds more than one set of weights (in 18 and 28 parts).'],
          reason: 'the extra file is part of a set, not a third one');
      expect(vs.singleWhere((v) => v.label == 'Q4_K_M').usable, isTrue, reason: 'the GGUF next to it is fine');
      final one = groupVariants('OBLITERATUS/Qwen3.8-27B-OBLITERATED',
          [for (final f in files) if (!f.path.contains('-of-00028') && !f.path.contains('extra')) f],
          formatHints: hints);
      expect(one.singleWhere((v) => v.format == ModelFormat.mlx).usable, isTrue, reason: 'one set is one model');
    });

    test('one shard set and the extra file its index maps tensors to are one model', () {
      // OBLITERATUS/Qwen3.8-27B-OBLITERATED's model.safetensors.index.json
      // maps tensors to the 28-part set and model-extra-00001-of-00001.
      final files = [
        _small('config.json', 3000),
        _small('tokenizer_config.json', 9700),
        _lfs('tokenizer.json', 11422654),
        _small('model.safetensors.index.json', 120000),
        for (var i = 1; i <= 28; i++) _lfs('model-${'$i'.padLeft(5, '0')}-of-00028.safetensors', 2e9.toInt()),
        _lfs('model-extra-00001-of-00001.safetensors', 1e8.toInt()),
      ];
      final v = groupVariants('mlx-community/Some-27B-4bit', files).single;
      expect(v.usable, isTrue, reason: '${v.blockedReasons}');
      expect(v.weights, hasLength(29));
      // The extra file's "1 of 1" does not stand in for the set's part 1.
      final noFirst = groupVariants('mlx-community/Some-27B-4bit',
          [for (final f in files) if (f.path != 'model-00001-of-00028.safetensors') f]).single;
      expect(noFirst.missingParts, [1]);
      expect(noFirst.usable, isFalse);
    });

    test('a lone file of another stem that sorts first is not the set whose parts are checked', () {
      // `embeddings-00001-of-00001` sorts ahead of the set it sits next to;
      // its "1 of 1" must neither stand in for the set nor hide its part 1.
      final files = [
        _small('config.json', 3000),
        _lfs('tokenizer.json', 11422654),
        _small('model.safetensors.index.json', 120000),
        _lfs('embeddings-00001-of-00001.safetensors', 3e8.toInt()),
        for (var i = 2; i <= 3; i++) _lfs('model-0000$i-of-00003.safetensors', 2e9.toInt()),
      ];
      final v = groupVariants('mlx-community/Qwen3-8B-4bit', files).single;
      expect(v.missingParts, [1], reason: 'one set and its extra file, missing its part 1');
      expect(v.expectedParts, 3);
      expect(v.blockedReasons, isEmpty);
      expect(v.usable, isFalse);
      final plan = planDownload(repo: 'mlx-community/Qwen3-8B-4bit', commit: _commit, files: files, quant: v.id);
      expect(plan, isA<PlanRefused>().having((p) => p.reasons, 'reasons', ['Missing part(s) 1 of 3.']));
      final whole = groupVariants(
          'mlx-community/Qwen3-8B-4bit', [...files, _lfs('model-00001-of-00003.safetensors', 2e9.toInt())]).single;
      expect(whole.usable, isTrue, reason: '${whole.blockedReasons}');
      expect((whole.weights.length, whole.expectedParts), (4, 3));
    });

    test('two whole shard sets under different stems in one MLX folder are two sets', () {
      final v = groupVariants('mlx-community/Mistral-7B-4bit', [
        _small('config.json', 3000),
        _lfs('tokenizer.json', 1800000),
        for (var i = 1; i <= 3; i++) _lfs('consolidated-0000$i-of-00003.safetensors', 1e9.toInt()),
        for (var i = 1; i <= 2; i++) _lfs('model-0000$i-of-00002.safetensors', 15e8.toInt()),
      ]).single;
      expect(v.usable, isFalse, reason: 'MLX would load all five files as one model');
      expect(v.fileProblems, ['This folder holds more than one set of weights (in 2 and 3 parts).']);
    });

    test('a .bin or .npz the Hub flags is a problem with its file, not only a format nothing runs', () {
      const sec = HubRepoSecurity(scansDone: true, filesWithIssues: {'llama-2-7b.ggmlv3.q4_0.bin': HubScanStatus.unsafe});
      final ggml = groupVariants('TheBloke/Llama-2-7B-GGML', [_lfs('llama-2-7b.ggmlv3.q4_0.bin', 3825517184)],
          repoSecurity: sec).single;
      expect(ggml.fileProblems, ['The Hub flags llama-2-7b.ggmlv3.q4_0.bin as unsafe']);
      expect(ggml.hubFlags, ggml.fileProblems);
      expect(ggml.unsupportedFormat, "Sherpa can't run old GGML files (llama.cpp now reads GGUF).");
      // A per-file verdict (securityFileStatus) counts the same.
      const flagged = HubFileSecurity(status: HubScanStatus.suspicious);
      final npz = groupVariants('mlx-community/mistral-7B-v0.1', [
        HubRepoFile(path: 'weights.npz', size: 14483498434, lfsSha256: 'a' * 64, lfsSize: 14483498434, security: flagged),
        _small('config.json', 300),
      ]).single;
      expect(npz.fileProblems, ['The Hub flags weights.npz as suspicious']);
      // The gate reports the verdict; the extension alone only when nothing else is wrong.
      final verdict = FileSafety.check(_lfs('model.bin', 9),
          repoSecurity: const HubRepoSecurity(scansDone: true, filesWithIssues: {'model.bin': HubScanStatus.unsafe}));
      expect((verdict.allowed, verdict.byExtension, verdict.hubFlagged, verdict.reason),
          (false, false, true, 'The Hub flags model.bin as unsafe'));
      final named = FileSafety.check(_lfs('model.bin', 9));
      expect((named.allowed, named.byExtension, named.hubFlagged), (false, true, false));
      expect(groupVariants('TheBloke/Llama-2-7B-GGML', [_lfs('llama-2-7b.ggmlv3.q4_0.bin', 3825517184)]).single.hubFlags,
          isEmpty);
    });

    test("a LiteRT hint names LiteRT's own files: safetensors there stay safetensors, an .npz is not MLX", () {
      // litert-community/FunctionGemma_270M_Mobile_Actions (library_name
      // transformers): a Transformers fine-tune published by litert-community.
      final fg = groupVariants('litert-community/FunctionGemma_270M_Mobile_Actions', [
        _small('config.json', 1000),
        _lfs('model.safetensors', 536000000),
        _lfs('tokenizer.json', 33000000),
      ]).single;
      expect(fg.format, ModelFormat.safetensors);
      expect(fg.unsupportedFormat, "Sherpa can't run Transformers weights (safetensors).");
      // litert-community/Kev-0.8B-LiteRT: .tflite exports and a safetensors head.
      final kev = groupVariants('litert-community/Kev-0.8B-LiteRT', [
        _lfs('head/kev_0.8b_pointer_head.safetensors', 3200000),
        _lfs('kev-0.8b_rowprefill_L128_fp16fc_i8emb.tflite', 900000000),
      ]);
      final head = kev.singleWhere((v) => v.weights.single.path.endsWith('.safetensors'));
      expect(head.format, ModelFormat.safetensors);
      expect(head.unsupportedFormat, isNot(contains('.tflite')));
      expect(kev.singleWhere((v) => v.weights.single.path.endsWith('.tflite')).format, ModelFormat.litert);
      expect(parseModelName('acme/Gemma3-1B-LiteRT', fileName: 'model.safetensors').format, ModelFormat.safetensors);
      expect(parseModelName('acme/Gemma3-1B-LiteRT', fileName: 'gemma3.litertlm').format, ModelFormat.litert);
      expect(parseModelName('mlx-community/Gemma3-1B-4bit', fileName: 'model.safetensors').format, ModelFormat.mlx,
          reason: 'MLX weights are safetensors: an MLX hint still names them');
      expect(parseModelName('TheBloke/Llama-2-7B-GPTQ', fileName: 'model.safetensors').format, ModelFormat.gptq);

      // litert-community/Qwen3-TTS-12Hz-0.6B-Base: a lookup table among LiteRT files.
      final tts = groupVariants('litert-community/Qwen3-TTS-12Hz-0.6B-Base', [
        _lfs('qwen3_tts_int8.litertlm', 500000000),
        _lfs('legacy/tables/text_projection_fp32.npz', 4000000),
      ]);
      final table = tts.singleWhere((v) => v.format == ModelFormat.mlxNpz);
      expect(table.unsupportedFormat, "Sherpa can't run NumPy .npz files.");
      expect(table.blockedReasons, [table.unsupportedFormat], reason: 'not called a pickle either');
    });

    test('old GGML and MLX .npz files say why nothing runs them, not that they are pickles', () {
      final ggml = groupVariants('TheBloke/Llama-2-7B-GGML',
          [_lfs('llama-2-7b.ggmlv3.q4_0.bin', 3825517184), _small('config.json', 29)]).single;
      expect(ggml.format, ModelFormat.ggml);
      expect(ggml.blockedReasons, ["Sherpa can't run old GGML files (llama.cpp now reads GGUF)."]);
      expect(ggml.fileProblems, isEmpty);
      final npz = groupVariants('mlx-community/mistral-7B-v0.1', [_lfs('weights.npz', 14483498434), _small('config.json', 300)])
          .single;
      expect(npz.blockedReasons, ["Sherpa can't run old MLX .npz weights."]);
      // A real finding about the bytes is still a problem.
      final sniffed = groupVariants('TheBloke/Llama-2-7B-GGML', [_lfs('llama-2-7b.ggmlv3.q4_0.bin', 9)],
          sniffedHeads: {'llama-2-7b.ggmlv3.q4_0.bin': Uint8List.fromList([0x80, 0x02, 0x7d, 0x71])}).single;
      expect(sniffed.fileProblems.join(), contains('Python pickle'));
    });

    test('TensorFlow Lite and MediaPipe files are not LiteRT-LM: only .litertlm runs', () {
      final gpt2 = groupVariants('openai-community/gpt2', [
        _lfs('64.tflite', 248000000),
        _lfs('64-fp16.tflite', 124000000),
        _lfs('64-8bits.tflite', 125000000),
        _small('config.json', 665),
      ]);
      expect(gpt2, hasLength(3));
      for (final v in gpt2) {
        expect(v.runtime, SherpaRuntime.none, reason: v.id);
        expect(v.usable, isFalse);
        expect(v.unsupportedFormat, "Sherpa can't run TensorFlow Lite .tflite files.",
            reason: 'what runs on this device is the app\'s to say (LiteRT-LM is Android only)');
        expect(v.fileProblems, isEmpty);
      }
      final litert = groupVariants('litert-community/Qwen2.5-1.5B-Instruct', [
        _lfs('Qwen2.5-1.5B-Instruct_multi-prefill-seq_q8_ekv4096.task', 1598000000),
        _lfs('Qwen2.5-1.5B-Instruct_multi-prefill-seq_q8_ekv4096.litertlm', 1597000000),
      ]);
      final byExt = {for (final v in litert) v.weights.single.path.split('.').last: v};
      expect(byExt['litertlm']!.runtime, SherpaRuntime.litert);
      expect(byExt['litertlm']!.usable, isTrue);
      expect(byExt['task']!.runtime, SherpaRuntime.none);
      expect(byExt['task']!.unsupportedFormat, "Sherpa can't run MediaPipe .task bundles.");
      expect(
          planDownload(
              repo: 'litert-community/Qwen2.5-1.5B-Instruct', commit: _commit, files: [byExt['task']!.weights.single]),
          isA<PlanRefused>());
    });
  });

  group('plans', () {
    test('Q4_K_M + auto-paired mmproj, pinned and hashed', () {
      final plan = _ok<DownloadPlan>(planDownload(repo: _repo, commit: _commit, files: _tree(), quant: 'Q4_K_M'));
      expect(plan.files.map((f) => f.path), ['Qwen3.8-27B-Q4_K_M.gguf', 'mmproj-F16.gguf']);
      expect(plan.mmproj!.path, 'mmproj-F16.gguf', reason: 'closest bit width; F16 wins the BF16 tie; F32 never');
      expect(plan.files.every((f) => f.sha256 != null && f.sha256!.length == 64), isTrue);
      expect(plan.totalBytes, 16470000000 + 931000000);
      expect(plan.tempBytes, 0);
      expect(plan.variant.loadPath, 'Qwen3.8-27B-Q4_K_M.gguf');
      expect(planDownload(repo: _repo, commit: _commit, files: _tree(), quant: 'Q4_K_M', includeMmproj: false),
          isA<DownloadPlan>().having((p) => p.mmproj, 'mmproj', isNull));
    });

    test('sharded BF16 keeps every shard; the draft comes from MTP/', () {
      final plan = _ok<DownloadPlan>(
          planDownload(repo: _repo, commit: _commit, files: _tree(), quant: 'BF16', draft: DraftKind.mtp));
      expect(plan.files.where((f) => f.role == FileRole.model).map((f) => '${f.shardIndex}/${f.shardCount}'), ['1/2', '2/2']);
      expect(plan.mmproj!.path, 'mmproj-F16.gguf', reason: 'same bit width as the model; F16 preferred over BF16');
      expect(plan.draft!.path, 'MTP/mtp-Qwen3.8-27B-Q4_0.gguf');
      final records = plan.toRecords(now: DateTime.utc(2026, 10, 18), ids: SequentialIdGenerator());
      expect(records.map((r) => r.localPath).first, 'unsloth__Qwen3.8-27B-GGUF@c03ac9c3bdc5/BF16/Qwen3.8-27B-BF16-00001-of-00002.gguf');
      expect(records.map((r) => r.groupId).toSet(), {'dlg_1'});
      expect(records.every((r) => r.state == DownloadState.queued && r.commit == _commit), isTrue);
    });

    test('refusals are explicit', () {
      List<String> refused(PlanOutcome o) => (o as PlanRefused).reasons;
      expect(refused(planDownload(repo: _repo, commit: 'main', files: _tree())).single, contains('pinned'));
      expect(refused(planDownload(repo: _repo, commit: _commit, files: _tree(), quant: 'UD-IQ1_S')).join(), contains('Missing part'));
      expect(refused(planDownload(repo: _repo, commit: _commit, files: _tree(), quant: 'Q4_0_4_4')).join(), contains('removed'));
      expect(refused(planDownload(repo: _repo, commit: _commit, files: _tree(), quant: 'Q5_K_M')).join(), contains('unsafe'));
      expect(refused(planDownload(repo: _repo, commit: _commit, files: _tree(), quant: 'IQ2_XXS')).single, contains('No "IQ2_XXS"'));
      expect(
          refused(planDownload(repo: _repo, commit: _commit, files: _tree(), quant: 'Q4_K_M', unsupportedQuants: {'Q4_K_M'}))
              .join(),
          contains('newer llama.cpp'));
      final noHash = [HubRepoFile(path: 'X-7B-Q4_K_M.gguf', size: 100)];
      expect(refused(planDownload(repo: 'a/X-7B-GGUF', commit: _commit, files: noHash)).join(), contains('SHA-256'));
      final pickles = [_lfs('pytorch_model-00001-of-00002.bin', 9), _lfs('pytorch_model-00002-of-00002.bin', 9)];
      expect(refused(planDownload(repo: 'mistralai/Mistral-7B-Instruct-v0.2', commit: _commit, files: pickles, quant: 'pytorch_model'))
              .join(),
          contains('pickle'));
    });

    test('repo-level scan results block too (securityRepoStatus)', () {
      final files = [_lfs('Foo-7B-Q4_K_M.gguf', 4e9.toInt())];
      const sec = HubRepoSecurity(scansDone: true, filesWithIssues: {'Foo-7B-Q4_K_M.gguf': HubScanStatus.unsafe});
      expect(planDownload(repo: 'a/Foo-7B-GGUF', commit: _commit, files: files, repoSecurity: sec), isA<PlanRefused>());
    });

    test('byte-split parts are joined; temp space is the largest part', () {
      final files = [
        _lfs('Llama-3.3-70B-Instruct-abliterated.Q8_0.gguf.part1of2', 39000000000),
        _lfs('Llama-3.3-70B-Instruct-abliterated.Q8_0.gguf.part2of2', 35975790000),
        _lfs('Llama-3.3-70B-Instruct-abliterated.Q4_K_M.gguf', 42520000000),
      ];
      final plan = _ok<DownloadPlan>(planDownload(
          repo: 'mradermacher/Llama-3.3-70B-Instruct-abliterated-GGUF', commit: _commit, files: files, quant: 'Q8_0'));
      expect(plan.files.map((f) => f.joinInto).toSet(), {'Llama-3.3-70B-Instruct-abliterated.Q8_0.gguf'});
      expect(plan.tempBytes, 39000000000);
      expect(plan.variant.loadPath, 'Llama-3.3-70B-Instruct-abliterated.Q8_0.gguf');
      expect(plan.warnings.join(), contains('join'));
      final storage = assessStorage(downloadBytes: plan.totalBytes, tempBytes: plan.tempBytes, freeBytes: 80000000000);
      expect(storage.verdict, StorageVerdict.insufficient);
    });

    test('a .bin proven to be safetensors by its first bytes is allowed', () {
      final header = utf8.encode('{"__metadata__":{}}');
      final head = Uint8List(8 + header.length)
        ..buffer.asByteData().setUint64(0, header.length, Endian.little)
        ..setRange(8, 8 + header.length, header);
      final f = _lfs('weights.bin', 1000);
      expect(FileSafety.check(f).allowed, isFalse);
      final ok = FileSafety.check(f, head: head);
      expect(ok.allowed, isTrue);
      expect(ok.warnings.single, contains('safetensors'));
    });
  });

  group('format sniffing', () {
    Uint8List b(List<int> v) => Uint8List.fromList([...v, ...List.filled(16, 0)]);
    test('magic bytes', () {
      expect(sniffWeightFormat(b([0x47, 0x47, 0x55, 0x46, 3, 0, 0, 0])), SniffedFormat.gguf);
      expect(sniffWeightFormat(b([0x47, 0x47, 0x55, 0x46, 0, 0, 0, 3])), SniffedFormat.ggufBigEndian);
      expect(sniffWeightFormat(b([0x80, 0x04, 0x95])), SniffedFormat.pickle);
      expect(sniffWeightFormat(b([0x50, 0x4b, 0x03, 0x04])), SniffedFormat.zipArchive);
      expect(sniffWeightFormat(b('tjgg'.codeUnits)), SniffedFormat.legacyGgml);
      expect(sniffWeightFormat(b([1, 2, 3])), SniffedFormat.unknown);
      expect(FileSafety.check(_lfs('model.gguf', 1), head: b([0x80, 0x02])).allowed, isFalse);
      expect(FileSafety.check(_lfs('model.exe', 1)).allowed, isFalse);
      expect(FileSafety.extensionOf('a/b.Q8_0.gguf.part2of2'), '.gguf');
    });
  });

  group('DownloadRecord', () {
    final t0 = DateTime.utc(2026, 10, 18, 12);
    DownloadRecord rec() => DownloadRecord(
          id: 'dl_1',
          groupId: 'dlg_1',
          repo: _repo,
          commit: _commit,
          path: 'Qwen3.8-27B-Q4_K_M.gguf',
          localPath: 'x/Qwen3.8-27B-Q4_K_M.gguf',
          role: FileRole.model,
          expectedBytes: 1000,
          state: DownloadState.queued,
          createdAt: t0,
          updatedAt: t0,
          sha256: 'a' * 64,
          expectedXetHash: 'b' * 64,
        );
    ResolvedDownload resolved({String? xet, String? sha, int size = 1000, DateTime? expires}) => ResolvedDownload(
          repo: _repo,
          revision: _commit,
          path: 'Qwen3.8-27B-Q4_K_M.gguf',
          url: Uri.parse('https://us.aws.cdn.hf.co/xet-bridge-us/abc/${xet ?? 'b' * 64}?Expires=1&Signature=s'),
          sendAuthorization: false,
          statusCode: 302,
          size: size,
          linkedEtag: sha ?? 'a' * 64,
          xetHash: xet ?? 'b' * 64,
          expiresAt: expires ?? t0.add(const Duration(hours: 1)),
        );

    test('state machine', () {
      var r = rec().transition(DownloadState.resolving, at: t0);
      expect(r.attempts, 1);
      r = r.transition(DownloadState.downloading, at: t0);
      r = r.transition(DownloadState.resolving, at: t0); // 403 expired → re-resolve
      expect(r.attempts, 2);
      r = r.transition(DownloadState.downloading, at: t0).transition(DownloadState.verifying, at: t0);
      r = r.transition(DownloadState.done, at: t0);
      expect(r.state.isTerminal, isTrue);
      expect(() => r.transition(DownloadState.downloading, at: t0), throwsStateError);
      expect(() => rec().transition(DownloadState.done, at: t0), throwsStateError);
      final failed = rec().transition(DownloadState.failed, at: t0, error: 'disk full');
      expect(failed.error, 'disk full');
      expect(failed.transition(DownloadState.queued, at: t0).error, isNull);
    });

    test('resume only when the content identity is unchanged (If-Range is ignored)', () {
      final partial = rec().withProgress(600, at: t0);
      expect(partial.decideResume(resolved()).fromByte, 600);
      expect(partial.decideResume(resolved(xet: 'e' * 64)).restarts, isTrue);
      expect(partial.decideResume(resolved(sha: 'f' * 64)).restarts, isTrue);
      expect(partial.decideResume(resolved(size: 999)).restarts, isTrue);
      final (next, decision) = partial.applyResolve(resolved(xet: 'e' * 64), at: t0);
      expect(decision.reason, contains('Xet'));
      expect(next.bytesDownloaded, 0);
      expect(next.resolvedXetHash, 'e' * 64);
      expect(next.cdnUrlExpiry, t0.add(const Duration(hours: 1)));
    });

    test('signed URL expiry triggers a re-resolve', () {
      final (r, _) = rec().applyResolve(resolved(), at: t0);
      expect(r.needsResolve(t0), isFalse);
      expect(r.needsResolve(t0.add(const Duration(minutes: 59))), isTrue, reason: '2-minute skew');
      expect(rec().needsResolve(t0), isTrue);
    });

    test('JSON round-trip', () {
      final (r, _) = rec().withProgress(10, at: t0).applyResolve(resolved(), at: t0);
      final back = DownloadRecord.fromJson(jsonDecode(jsonEncode(r.toJson())) as Map<String, Object?>);
      expect(back.toJson(), r.toJson());
    });
  });

  group('integrity helpers', () {
    test('sha256 streaming and git blob sha1', () async {
      expect(await sha256Of(Stream.fromIterable([utf8.encode('a'), utf8.encode('bc')])),
          'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
      expect(await verifySha256(Stream.value(utf8.encode('abc')),
          'BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD'), isTrue);
      // `printf 'hello\n' | git hash-object --stdin`
      expect(gitBlobSha1(Uint8List.fromList(utf8.encode('hello\n'))), 'ce013625030ba8dba906f756967f9e9ca394464a');
    });
  });
}
