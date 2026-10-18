import 'package:sherpa_hub/sherpa_hub.dart';
import 'package:test/test.dart';

void main() {
  group('every llama.cpp quant type in a file name', () {
    for (final t in QuantTypes.all) {
      test(t.id, () {
        for (final spelling in [t.id, t.id.toLowerCase()]) {
          final p = parseModelName('someone/Foo-7B-GGUF', fileName: 'Foo-7B-Instruct-$spelling.gguf');
          final q = p.quant!.value;
          expect(q.ggufType, same(t), reason: spelling);
          expect(q.bpw, t.bpw);
          expect(p.size!.value.label, '7B');
          expect(p.flags.contains(NameFlag.removedQuant), t.isRemoved);
          expect(p.isPrimaryModel, !t.isRemoved);
          expect(q.explanation, startsWith('${t.id}: '));
        }
      });
    }
  });

  group('GGUF quant tags', () {
    test('suffix semantics (R08 §12 community labels)', () {
      QuantLabel q(String tag) => parseGgufQuantTag(tag)!;
      expect(q('Q4_K').ggufType, QuantTypes.q4_k_m);
      expect(q('Q4_K').explanation, contains('shorthand for Q4_K_M'));
      expect(q('Q3_K_XL').ggufType, QuantTypes.q3_k_l);
      expect(q('Q3_K_L').embedOutputQ8, isFalse, reason: 'a real file type');
      expect(q('Q5_K_L').ggufType, QuantTypes.q5_k_m);
      expect(q('Q5_K_L').embedOutputQ8, isTrue);
      expect(q('UD-Q6_K_M').ggufType, QuantTypes.q6_k);
      expect(q('UD-Q6_K_M').dynamic, isTrue);
      expect(q('UD-Q6_K_M').custom, isFalse);
      expect(q('i1-Q4_K_S').imatrix, isTrue);
      expect(q('fp16').label, 'F16');
      expect(q('FP32').ggufType, QuantTypes.f32);
      expect(q('IQ4_NL_4_4').isRemoved, isTrue);
      expect(q('Q9_Z').ggufType, isNull);
      expect(parseGgufQuantTag('Instruct'), isNull);
      expect(parseGgufQuantTag('32K'), isNull);
    });

    test('tooltips read like the spec example', () {
      final p = parseModelName('bartowski/Llama-3.2-1B-Instruct-GGUF', fileName: 'Llama-3.2-1B-Instruct-Q4_K_M.gguf');
      expect(p.quant!.explanation, 'Q4_K_M: 4-bit k-quant, medium; ~4.9 bits/weight; good quality/size balance (the usual default)');
      expect(p.size!.explanation, '1B: about 1 billion parameters');
      expect(p.variants.single.explanation, startsWith('Instruction-tuned'));
      final ud = parseModelName('unsloth/Qwen3.8-27B-GGUF', fileName: 'Qwen3.8-27B-UD-Q4_K_XL.gguf').quant!;
      expect(ud.explanation, contains('Unsloth Dynamic'));
      final moe = parseModelName('unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF');
      expect(moe.activeParams!.explanation, contains('~3B parameters active per token'));
      expect(moe.isMoe, isTrue);
      final eff = parseModelName('google/gemma-3n-E2B-it');
      expect(eff.size!.value.kind, ParamSizeKind.effective);
      expect(eff.size!.explanation, contains('raw weight count is much larger'));
      final build = parseModelName('Qwen/Qwen3-30B-A3B-Thinking-2507');
      expect(build.build!.explanation, contains('July 2025'));
      final ctx = parseModelName('unsloth/Qwen3-Coder-30B-A3B-Instruct-1M-GGUF');
      expect(ctx.contextHint!.explanation, contains('not a parameter count'));
      final it = parseModelName('google/gemma-4-E2B-it');
      expect(it.variants.single.explanation, startsWith('it: '));
    });
  });

  group('merging repo and file names (R08 §13.4)', () {
    test('the file wins, the repo fills gaps', () {
      final p = parseModelName('ggml-org/SmolLM3-3B-GGUF', fileName: 'SmolLM3-Q4_K_M.gguf');
      expect(p.family!.source, FieldSource.file);
      expect(p.size!.source, FieldSource.repo);
      expect(p.displayName, 'SmolLM 3 3B');
    });

    test('mradermacher -i1-GGUF repos mark every quant as imatrix', () {
      final p = parseModelName('mradermacher/Foo-7B-i1-GGUF', fileName: 'Foo-7B.Q4_K_M.gguf');
      expect(p.quant!.value.imatrix, isTrue);
      expect(p.quant!.value.label, 'Q4_K_M');
    });

    test('repo-only GGUF quant tag', () {
      final p = parseModelName('ggml-org/Qwen3-Reranker-0.6B-Q8_0-GGUF');
      expect(p.format, ModelFormat.gguf);
      expect(p.quant!.value.ggufType, QuantTypes.q8_0);
      expect(p.quant!.source, FieldSource.repo);
    });

    test('sidecars are not primary models', () {
      for (final f in ['mmproj-F16.gguf', 'MTP/mtp-Foo-7B-Q4_0.gguf', 'imatrix_unsloth.gguf', 'Foo.imatrix']) {
        expect(parseModelName('unsloth/Foo-7B-GGUF', fileName: f).isPrimaryModel, isFalse, reason: f);
      }
      expect(parseModelName('unsloth/Foo-7B-GGUF', fileName: 'Foo-7B-Q4_K_M.gguf').isPrimaryModel, isTrue);
    });

    test('safetensors shard spellings', () {
      ShardInfo s(String f) => parseModelName('a/B-7B', fileName: f).shard!.value;
      expect(s('model-00001-of-000002.safetensors').count, 2);
      expect(s('model.safetensors-00002-of-00002.safetensors').index, 2);
      expect(s('model-00003.safetensors').count, isNull);
      expect(s('x.Q8_0.gguf.part2of3').byteSplit, isTrue);
    });

    test('content-filter flag', () {
      expect(parseModelName('mradermacher/Llama-3.3-70B-Instruct-abliterated-GGUF').isUncensored, isTrue);
      expect(parseModelName('Qwen/Qwen3-8B').isUncensored, isFalse);
    });

    test('names without separators or identity degrade gracefully', () {
      final p = parseModelName('x/y', fileName: 'weights.bin');
      expect(p.format, ModelFormat.pickle);
      expect(p.isBlocked, isTrue);
      final q = parseModelName('solo');
      expect(q.owner, '');
      expect(q.displayName, isNotEmpty);
    });
  });
}
