import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:sherpa_hub/sherpa_hub.dart';
import 'package:test/test.dart';

import 'support/gguf_builder.dart';

const _realModel = '/opt/models/Qwen3-0.6B-Q4_K_M.gguf';

GgufHeader _parseOk(Uint8List bytes, {bool tensors = true}) {
  final r = GgufReader.parse(bytes, readTensorInfo: tensors);
  expect(r, isA<GgufHeader>());
  return r as GgufHeader;
}

GgufBuilder _qwenLike() => GgufBuilder()
  ..string('general.architecture', 'qwen3')
  ..string('general.name', 'Test')
  ..string('general.size_label', '0.6B')
  ..u32('general.file_type', 15)
  ..u32('qwen3.context_length', 40960)
  ..u32('qwen3.block_count', 4)
  ..u32('qwen3.embedding_length', 1024)
  ..u32('qwen3.feed_forward_length', 3072)
  ..u32('qwen3.attention.head_count', 16)
  ..u32('qwen3.attention.head_count_kv', 8)
  ..u32('qwen3.attention.key_length', 128)
  ..u32('qwen3.attention.value_length', 128)
  ..string('tokenizer.chat_template', '{% if tools %}<tool_call>{% endif %}<think>');

void main() {
  group('real Qwen3-0.6B-Q4_K_M.gguf (first bytes from disk)', () {
    final file = File(_realModel);
    final skip = file.existsSync() ? false : 'needs $_realModel';

    test('incremental parse matches llama.cpp PROBE-1 values (R04 §4)', () {
      final raf = file.openSync();
      addTearDown(raf.closeSync);
      final size = raf.lengthSync();
      expect(size, 396705472);
      var want = 1 << 20;
      var rounds = 0;
      late GgufHeader h;
      while (true) {
        rounds++;
        raf.setPositionSync(0);
        final bytes = raf.readSync(want);
        final r = GgufReader.parse(bytes, fileSize: size);
        if (r is GgufNeedMoreBytes) {
          expect(r.requiredBytes, greaterThan(r.availableBytes));
          want = max(r.requiredBytes, want * 2);
          continue;
        }
        h = r as GgufHeader;
        if (!h.hasTensorInfo) {
          want = max(h.tensorInfoRequiredBytes!, want * 2);
          continue;
        }
        break;
      }
      expect(rounds, lessThanOrEqualTo(5), reason: 'doubling from 1 MiB reaches the 5.9 MB header quickly');
      final m = h.metadata;
      expect(h.version, 3);
      expect(h.tensorCount, 310);
      expect(h.kvCount, 32);
      expect(m.architecture, 'qwen3');
      expect(m.name, 'Qwen3-0.6B');
      expect(m.sizeLabel, '0.6B');
      expect(m.blockCount, 28);
      expect(m.contextLength, 40960);
      expect(m.embeddingLength, 1024);
      expect(m.feedForwardLength, 3072);
      expect(m.headCount, 16);
      expect(m.headCountKv, 8);
      expect(m.headCountKvPerLayer, List.filled(28, 8));
      expect(m.keyLength, 128, reason: 'not n_embd/n_head = 64 (R04 §0.5)');
      expect(m.valueLength, 128);
      expect(m.slidingWindow, isNull);
      expect(m.fileType, 15);
      expect(m.fileTypeInfo, QuantTypes.q4_k_m);
      expect(m.ropeFreqBase, 1000000.0);
      expect(m.vocabSize, 151936);
      expect(m.tokenizerModel, 'gpt2');
      expect(m.eosTokenId, 151645);
      expect(m.usedImatrix, isTrue);
      expect(m.chatTemplate, hasLength(4905), reason: 'llama_model_meta_val_str length in PROBE-1');
      expect(m.chatTemplateMentionsTools, isTrue);
      expect(m.chatTemplateMentionsReasoning, isTrue);
      final tokens = m.array('tokenizer.ggml.tokens')!;
      expect(tokens.isSkipped, isTrue, reason: '152k strings are skipped, not materialized');
      expect(tokens.length, 151936);
      expect(m.array('tokenizer.ggml.merges')!.length, 151387);
      expect(h.kvEndOffset, 5933927);
      expect(h.parameterCount, 596049920, reason: 'llama_model_n_params (R04 PROBE-1)');
      expect(h.tensorDataBytes, 390753280, reason: 'llama_model_size (R04 PROBE-1)');
      expect(h.dataOffset, 5952192);
      expect(size - h.dataOffset!, h.tensorDataBytes);
      expect(h.tensorTypeCounts, {'F32': 113, 'Q4_K': 168, 'Q6_K': 29});
      expect(h.unknownTypeTensors, isEmpty);
    }, skip: skip);

    test('KV-only parse needs less than the tensor table', () {
      final raf = file.openSync();
      addTearDown(raf.closeSync);
      final bytes = raf.readSync(5933927);
      final h = _parseOk(bytes, tensors: false);
      expect(h.metadata.blockCount, 28);
      expect(h.hasTensorInfo, isFalse);
      final short = GgufReader.parse(Uint8List.sublistView(bytes, 0, 5933926));
      expect(short, isA<GgufNeedMoreBytes>());
      final withTensors = GgufReader.parse(bytes);
      expect((withTensors as GgufHeader).tensorInfoRequiredBytes, greaterThan(5933927));
    }, skip: skip);
  });

  group('synthetic headers', () {
    test('scalars, strings and typed accessors', () {
      final b = _qwenLike()
        ..f32('qwen3.rope.freq_base', 10000)
        ..string('qwen3.rope.scaling.type', 'yarn')
        ..f32('qwen3.rope.scaling.factor', 4)
        ..u32('qwen3.rope.scaling.original_context_length', 32768)
        ..u32('qwen3.expert_count', 128)
        ..u32('qwen3.expert_used_count', 8)
        ..u32('qwen3.expert_feed_forward_length', 768)
        ..u32('split.count', 3)
        ..u32('split.no', 0)
        ..u32('general.alignment', 64)
        ..boolean('tokenizer.ggml.add_bos_token', value: false);
      final m = _parseOk(b.build()).metadata;
      expect(m.ropeScalingType, 'yarn');
      expect(m.ropeScalingFactor, 4);
      expect(m.ropeScalingOriginalContextLength, 32768);
      expect(m.expertCount, 128);
      expect(m.expertUsedCount, 8);
      expect(m.isMoe, isTrue);
      expect(m.splitCount, 3);
      expect(m.splitNo, 0);
      expect(m.alignment, 64);
      expect(m.boolean('tokenizer.ggml.add_bos_token'), isFalse);
      expect(m.chatTemplateMentionsTools, isTrue);
    });

    test('per-layer KV heads, SWA bool pattern and SWA head sizes', () {
      final b = GgufBuilder()
        ..string('general.architecture', 'gemma4')
        ..u32('gemma4.block_count', 6)
        ..u32('gemma4.attention.head_count', 8)
        ..u32Array('gemma4.attention.head_count_kv', [2, 2, 2, 2, 2, 4])
        ..u32('gemma4.attention.key_length', 512)
        ..u32('gemma4.attention.key_length_swa', 256)
        ..u32('gemma4.attention.value_length_swa', 256)
        ..u32('gemma4.attention.sliding_window', 512)
        ..boolArray('gemma4.attention.sliding_window_pattern', [true, true, true, true, true, false]);
      final m = _parseOk(b.build()).metadata;
      expect(m.headCountKvPerLayer, [2, 2, 2, 2, 2, 4]);
      expect(m.headCountKv, 4);
      expect(m.keyLengthSwa, 256);
      expect(m.slidingWindow, 512);
      final p = m.slidingWindowPattern!;
      expect([for (var i = 0; i < 6; i++) p.isSwa(i)], [true, true, true, true, true, false]);
    });

    test('SWA period follows llama.cpp set_swa_pattern', () {
      const p = SwaPattern.period(6);
      expect([for (var i = 0; i < 12; i++) p.isSwa(i)],
          [true, true, true, true, true, false, true, true, true, true, true, false]);
      const dense = SwaPattern.period(4, denseFirst: true);
      expect([for (var i = 0; i < 8; i++) dense.isSwa(i)], [false, true, true, true, false, true, true, true]);
      expect(const SwaPattern.period(0).isSwa(3), isTrue);
    });

    test('key_length falls back to n_embd / n_head only when absent', () {
      final b = GgufBuilder()
        ..string('general.architecture', 'llama')
        ..u32('llama.block_count', 2)
        ..u32('llama.embedding_length', 2048)
        ..u32('llama.attention.head_count', 32);
      final m = _parseOk(b.build()).metadata;
      expect(m.keyLength, 64);
      expect(m.headCountKvPerLayer, [32, 32], reason: 'no GQA key → head_count');
    });

    test('v2 accepted; v1, wrong magic and big-endian rejected', () {
      expect(_parseOk((GgufBuilder(version: 2)..string('general.architecture', 'llama')).build()).version, 2);
      expect(() => GgufReader.parse((GgufBuilder(version: 1)..u32('a', 1)).build()),
          throwsA(isA<GgufFormatException>().having((e) => e.message, 'message', contains('v1'))));
      final notGguf = Uint8List.fromList('PK\x03\x04aaaaaaaaaaaaaaaaaaaaaaaa'.codeUnits);
      expect(() => GgufReader.parse(notGguf), throwsA(isA<GgufFormatException>()));
      expect(() => GgufReader.parse(_qwenLike().build(bigEndianVersion: true)),
          throwsA(isA<GgufFormatException>().having((e) => e.bigEndian, 'bigEndian', isTrue)));
    });

    test('every truncation point reports "need more bytes", never a crash', () {
      final bytes = (_qwenLike()..tensor('w', [1024, 4], 12, 0)).build();
      for (var n = 0; n < bytes.length; n++) {
        final r = GgufReader.parse(Uint8List.sublistView(bytes, 0, n), readTensorInfo: false);
        if (r is GgufNeedMoreBytes) {
          expect(r.requiredBytes, greaterThan(n));
          expect(r.requiredBytes, lessThanOrEqualTo(bytes.length));
        } else {
          expect((r as GgufHeader).kvEndOffset, lessThanOrEqualTo(n));
        }
      }
      expect(_parseOk(bytes).tensors!.single.byteSize, 4 * (1024 ~/ 256) * 144);
    });

    test('a length past the known file size is corruption, not "need more"', () {
      final bytes = _qwenLike().build();
      expect(() => GgufReader.parse(Uint8List.sublistView(bytes, 0, 40), fileSize: 40),
          throwsA(isA<GgufFormatException>()));
    });

    test('implausible counts, duplicate keys and unknown types are rejected', () {
      expect(() => GgufReader.parse(_qwenLike().build(kvCountOverride: 1 << 40)), throwsA(isA<GgufFormatException>()));
      final dup = GgufBuilder()
        ..u32('a', 1)
        ..u32('a', 2);
      expect(() => GgufReader.parse(dup.build()),
          throwsA(isA<GgufFormatException>().having((e) => e.message, 'message', contains('duplicate'))));
      final bad = GgufBuilder();
      bad.u32('x', 1);
      final bytes = bad.build();
      // Corrupt the value type (offset: 24 header + 8 len + 1 key byte).
      ByteData.sublistView(bytes).setUint32(33, 99, Endian.little);
      expect(() => GgufReader.parse(bytes), throwsA(isA<GgufFormatException>()));
    });

    test('long arrays are skipped (length kept), short ones retained', () {
      final b = GgufBuilder()
        ..string('general.architecture', 'llama')
        ..f32Array('tokenizer.ggml.scores', 20000)
        ..stringArray('tokenizer.ggml.tokens', List.generate(9000, (i) => 't$i'))
        ..stringArray('tokenizer.ggml.small', ['a', 'b']);
      final m = _parseOk(b.build()).metadata;
      expect(m.array('tokenizer.ggml.scores')!.isSkipped, isTrue);
      expect(m.array('tokenizer.ggml.scores')!.length, 20000);
      expect(m.vocabSize, 9000);
      expect(m.array('tokenizer.ggml.small')!.values, ['a', 'b']);
    });

    test('tensor info: removed ggml types are reported, not mis-sized', () {
      final b = GgufBuilder()
        ..string('general.architecture', 'llama')
        ..tensor('blk.0.ffn_up.weight', [4096, 4096], 31, 0) // Q4_0_4_4 (removed)
        ..tensor('token_embd.weight', [4096, 32000], 8, 1 << 20);
      final h = _parseOk(b.build());
      expect(h.unknownTypeTensors.map((t) => t.name), ['blk.0.ffn_up.weight']);
      expect(h.tensorDataBytes, isNull);
      expect(h.parameterCount, 4096 * 4096 + 4096 * 32000);
    });

    test('random corruption never escapes as anything but GgufFormatException', () {
      final base = (_qwenLike()..tensor('w', [256, 2], 12, 0)).build();
      final rnd = Random(42);
      for (var i = 0; i < 2000; i++) {
        final b = Uint8List.fromList(base);
        for (var k = 0; k < 1 + rnd.nextInt(6); k++) {
          b[8 + rnd.nextInt(b.length - 8)] = rnd.nextInt(256);
        }
        try {
          GgufReader.parse(b, fileSize: b.length);
        } on GgufFormatException {
          // expected for most mutations
        }
      }
    });
  });

  group('quant tables', () {
    test('ggml block sizes give the R08 §12 nominal bpw', () {
      expect(GgmlTypes.q4_k.bitsPerWeight, 4.5);
      expect(GgmlTypes.q6_k.bitsPerWeight, 6.5625);
      expect(GgmlTypes.q8_0.bitsPerWeight, 8.5);
      expect(GgmlTypes.iq4_xs.bitsPerWeight, 4.25);
      expect(GgmlTypes.iq2_xxs.bitsPerWeight, 2.0625);
      expect(GgmlTypes.tq1_0.bitsPerWeight, 1.6875);
      expect(GgmlTypes.nvfp4.bitsPerWeight, 4.5);
      expect(GgmlTypes.q1_0.bitsPerWeight, 1.125);
      expect(GgmlTypes.q2_0.bitsPerWeight, 2.25);
      expect(GgmlTypes.mxfp4.bitsPerWeight, 4.25);
      expect(GgmlTypes.byId(31), isNull, reason: 'Q4_0_4_4 tensors were removed');
    });

    test('every llama.cpp ftype round-trips through general.file_type', () {
      final ids = {for (final t in QuantTypes.all) if (t.ftype != null) t.ftype!};
      expect(ids, containsAll([for (var i = 0; i <= 41; i++) if (i != 4 && i != 5 && i != 6) i]));
      for (final t in QuantTypes.all) {
        if (t.ftype != null) expect(QuantTypes.byFtype(t.ftype!), same(t));
      }
      expect(QuantTypes.byFtype(1024), isNull, reason: 'GUESSED');
      expect(QuantTypes.byName('q4_k'), QuantTypes.q4_k_m);
      expect(QuantTypes.q4_k_m.explanation, 'Q4_K_M: 4-bit k-quant, medium; ~4.9 bits/weight; good quality/size balance '
          '(the usual default)');
    });
  });
}
