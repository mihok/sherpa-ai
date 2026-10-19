// Real engine with a vision projector: the host-built shared
// libsherpa_engine.so (an mtmd build, tool/build_host_engine.sh) and a small
// VLM + mmproj (test/support/engine_env.dart visionModelPaths). Skips
// cleanly when any of them is missing.
@Tags(['engine'])
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_inference/sherpa_inference.dart';

import '../support/engine_env.dart';

const _vlm = 'smolvlm';
const _text = 'qwen3';

/// A [w]×[h] 24-bit BMP of one colour (the engine decodes BMP, PNG, JPEG, GIF).
Uint8List _bmp(int w, int h, int r, int g, int b) {
  final row = (w * 3 + 3) & ~3;
  final out = ByteData(54 + row * h)
    ..setUint8(0, 0x42)
    ..setUint8(1, 0x4D)
    ..setUint32(2, 54 + row * h, Endian.little)
    ..setUint32(10, 54, Endian.little)
    ..setUint32(14, 40, Endian.little)
    ..setInt32(18, w, Endian.little)
    ..setInt32(22, h, Endian.little)
    ..setUint16(26, 1, Endian.little)
    ..setUint16(28, 24, Endian.little)
    ..setUint32(34, row * h, Endian.little);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final o = 54 + y * row + x * 3;
      out
        ..setUint8(o, b)
        ..setUint8(o + 1, g)
        ..setUint8(o + 2, r);
    }
  }
  return out.buffer.asUint8List();
}

Message _user(String id, List<ContentPart> content) =>
    Message(id: id, role: Role.user, content: content, createdAt: DateTime.utc(2026, 10, 19));

const _params = GenerationParams(temperature: 0, seed: 7, maxOutputTokens: 8, reasoning: ReasoningEffort.off);

void main() {
  final vision = visionModelPaths();
  final skip = engineSkipReason() ?? (vision == null ? 'no vision model (set SHERPA_TEST_VLM and SHERPA_TEST_MMPROJ)' : null);
  late FfiEngineHost host;
  late ModelLifecycleManager lifecycle;
  late LlamaCppProvider provider;

  setUpAll(() async {
    if (skip != null) return;
    host = FfiEngineHost(libraryPath: engineLibraryPath());
    lifecycle = ModelLifecycleManager(host: host)
      ..register(LocalModelSpec(
        id: _vlm,
        path: vision!.$1,
        mmprojPath: vision.$2,
        preferredContext: 4096,
        minContext: 1024,
        sessionDefaults: SessionConfig(nThreads: testThreads, nThreadsBatch: testThreads, seed: 7),
      ))
      ..register(LocalModelSpec(
        id: _text,
        path: testModelPath()!,
        preferredContext: 2048,
        minContext: 1024,
        sessionDefaults: SessionConfig(nThreads: testThreads, nThreadsBatch: testThreads, seed: 7),
      ));
    await lifecycle.start();
    provider = LlamaCppProvider(lifecycle: lifecycle);
  });

  tearDownAll(() async {
    if (skip != null) return;
    await lifecycle.dispose();
    await host.dispose();
  });

  Future<(String, List<ModelEvent>)> ask(String modelId, List<Message> messages) async {
    final events = await provider
        .stream(ModelRequest(modelId: modelId, messages: messages, params: _params, cache: const CacheHints(sessionId: 'v')))
        .toList();
    return (events.whereType<TextDelta>().map((d) => d.text).join(), events);
  }

  test('a model with a projector reports vision and sees the image; the next turn reuses its KV', () async {
    final caps = await provider.capabilities(_vlm);
    expect(caps.vision, isTrue);
    const q = 'What colour is this image? Answer with one word.';
    final first = [_user('u1', [const TextPart(q), ImagePart(mimeType: 'image/bmp', data: _bmp(64, 64, 230, 20, 20))])];
    final (red, e1) = await ask(_vlm, first);
    expect(red.toLowerCase(), contains('red'));
    expect(e1.whereType<ProviderNotice>().where((n) => n.code == 'content_dropped'), isEmpty);
    final u1 = e1.whereType<UsageUpdate>().last.usage;
    expect(u1.inputTokens, greaterThan(64), reason: 'image tokens are in the prompt');

    final second = [
      ...first,
      Message(id: 'a1', role: Role.assistant, content: [TextPart(red)], createdAt: DateTime.utc(2026, 10, 19)),
      _user('u2', [const TextPart(q), ImagePart(mimeType: 'image/bmp', data: _bmp(64, 64, 20, 40, 230))]),
    ];
    final (blue, e2) = await ask(_vlm, second);
    expect(blue.toLowerCase(), contains('blue'));
    final u2 = e2.whereType<UsageUpdate>().last.usage;
    expect(u2.cacheReadTokens, greaterThanOrEqualTo(u1.inputTokens - 1), reason: 'the first image is not re-encoded');
  }, skip: skip, timeout: const Timeout(Duration(minutes: 4)));

  test('a model without a projector drops the image with a notice and still answers', () async {
    expect((await provider.capabilities(_text)).vision, isFalse);
    final (_, events) = await ask(_text, [
      _user('u', [const TextPart('Say hi.'), ImagePart(mimeType: 'image/bmp', data: _bmp(8, 8, 0, 0, 0))]),
    ]);
    final dropped = events.whereType<ProviderNotice>().where((n) => n.code == 'content_dropped');
    expect(dropped.single.message, contains('no vision projector'));
    expect(events.whereType<Finish>(), hasLength(1));
  }, skip: skip, timeout: const Timeout(Duration(minutes: 4)));
}
