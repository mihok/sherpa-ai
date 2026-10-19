import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_hub/sherpa_hub.dart' show ModelFormat;
import 'package:sherpa_litert/sherpa_litert.dart';
import 'package:sherpa_litert/src/common/errors.dart';
import 'package:sherpa_litert/src/common/fingerprint.dart';
import 'package:sherpa_litert/testing.dart';

import 'support.dart';

LiteRtModelInfo info({List<String> backends = const ['gpu', 'cpu'], String? brand, String? soc}) =>
    LiteRtModelInfo.fromMsg(FakeLiteRtBackend.modelInfo(backends: backends, npuBrand: brand, socName: soc));

void main() {
  group('planBackends', () {
    const pixel = LiteRtDevice(apiLevel: 36, socModel: 'Tensor G5', socManufacturer: 'Google');
    const s25 = LiteRtDevice(apiLevel: 35, socModel: 'SM8750', socManufacturer: 'QTI');

    test('GPU before CPU; unknown support tries both', () {
      expect(planBackends(info(), pixel), ['gpu', 'cpu']);
      expect(planBackends(info(backends: const ['cpu']), pixel), ['cpu']);
      expect(planBackends(info(backends: const []), pixel), ['gpu', 'cpu']);
    });

    test('NPU first only on the SoC the file is built for', () {
      final qc = info(backends: const ['npu', 'cpu'], brand: 'qualcomm', soc: 'sm8750');
      expect(planBackends(qc, s25), ['npu', 'cpu']);
      expect(planBackends(qc, pixel), ['cpu']);
      expect(planBackends(info(backends: const ['npu'], brand: 'qualcomm', soc: 'sm8750'), pixel), isEmpty);
      expect(planBackends(qc, const LiteRtDevice(apiLevel: 30, socModel: 'SM8750')), ['cpu'], reason: 'NPU needs API 31');
    });

    test('brand-only NPU files match the SoC manufacturer', () {
      final tensor = info(backends: const ['npu'], brand: 'google_tensor');
      expect(npuMatches(LiteRtModelInfo.fromMsg(FakeLiteRtBackend.modelInfo(npuBrand: 'google_tensor')), pixel), isTrue);
      expect(planBackends(tensor, s25), isEmpty);
    });
  });

  test('runtimeTooOld and tokenizer guesses', () {
    expect(runtimeTooOld('0.18.0'), isFalse);
    expect(runtimeTooOld('0.17.1'), isFalse);
    expect(runtimeTooOld('0.19.0'), isTrue);
    expect(runtimeTooOld('1.0'), isTrue);
    expect(runtimeTooOld(null), isFalse);
    expect(guessTokenizerFamily('/x/Qwen3-0.6B.litertlm'), 'qwen');
    expect(guessTokenizerFamily('/x/SmolLM2_135M_Instruct.litertlm'), 'llama3');
    expect(guessTokenizerFamily('/x/Phi-4-mini.litertlm'), 'phi');
    expect(guessTokenizerFamily('/x/unknown.litertlm'), isNull);
    expect(LiteRtLmProvider.supportsFile('/m/A.LiteRTLM'), isTrue);
    expect(LiteRtLmProvider.supportsFile('/m/a.gguf'), isFalse);
    expect(LiteRtLmProvider.supportsFormat(ModelFormat.litert), isTrue);
    expect(LiteRtLmProvider.supportsFormat(ModelFormat.gguf), isFalse);
  });

  test('fingerprints are deterministic, order-independent for maps and sensitive to content', () {
    expect(fingerprint({'a': 1, 'b': [1, 2]}), fingerprint({'b': [1, 2], 'a': 1}));
    expect(fingerprint({'a': 1}), isNot(fingerprint({'a': 2})));
    expect(fingerprint(Uint8List.fromList([1, 2])), isNot(fingerprint(Uint8List.fromList([2, 1]))));
    expect(fingerprintBytes(const []), 'cbf29ce484222325', reason: 'FNV-1a 64 offset basis');
    expect(fingerprintBytes('a'.codeUnits), 'af63dc4c8601ec8c', reason: 'FNV-1a 64 of "a"');
    expect(newToolCallId(), matches(RegExp(r'^call_[0-9a-z]{16}$')));
  });

  group('event router', () {
    test('routes by stream id, credits delivered batches, ends after the terminal event', () async {
      final backend = FakeLiteRtBackend();
      final router = LiteRtEventRouter(backend, firstStreamId: 7);
      final s = router.open();
      expect(s.id, 7);
      final got = <LiteRtEvent>[];
      final done = Completer<void>();
      s.events.listen(got.add, onDone: done.complete);
      backend.deliver(7, [LiteRtEvent(kind: EventKind.textDelta, text: 'a')]);
      backend.deliver(99, [LiteRtEvent(kind: EventKind.textDelta, text: 'not mine')]);
      backend.deliver(7, [LiteRtEvent(kind: EventKind.done)]);
      await done.future;
      expect(got.map((e) => e.kind), [EventKind.textDelta, EventKind.done]);
      expect(backend.credits, [(streamId: 7, batches: 1)]);
      expect(router.openStreams, 0);
      await router.dispose();
      await backend.dispose();
    });

    test('global events go to globalEvents', () async {
      final backend = FakeLiteRtBackend();
      final router = LiteRtEventRouter(backend);
      final f = router.globalEvents.first;
      backend.emitGlobal(LiteRtEvent(kind: EventKind.trimMemory, value: 40));
      expect((await f).value, 40);
      await router.dispose();
      await backend.dispose();
    });
  });

  group('error classification', () {
    test('host errors', () {
      expect(hostError(MissingPluginException(), providerId: 'p').kind, ProviderErrorKind.unsupported);
      expect(hostError(PlatformException(code: 'unsupported'), providerId: 'p').kind, ProviderErrorKind.unsupported);
      expect(hostError(PlatformException(code: 'litert_status', message: 'model file not found', details: [5]),
              providerId: 'p')
          .kind, ProviderErrorKind.modelNotFound);
      expect(hostError(PlatformException(code: 'nano_error', message: 'busy', details: [9, 500]), providerId: 'p').retryAfter,
          const Duration(milliseconds: 500));
      expect(hostError(StateError('x'), providerId: 'p').kind, ProviderErrorKind.unknown);
    });

    test('a busy engine is retryable', () {
      final e = liteRtError(ErrorMsg(source: 'state', code: 9, message: 'another reply is being generated'), providerId: 'p');
      expect(e.kind, ProviderErrorKind.overloaded);
      expect(e.isRetryable, isTrue);
    });
  });

  group('off Android', () {
    test('the unsupported backend makes both providers report unsupported without crashing', () async {
      const backend = UnsupportedLiteRtBackend();
      final fg = FakeForeground();
      final lm = LiteRtLmProvider(
        backend: backend,
        foreground: fg,
        models: const [LiteRtModelSpec(id: 'g', path: '/m/g.litertlm')],
      );
      final nano = GeminiNanoProvider(backend: backend, foreground: fg);
      expect((await lm.availability('/m/g.litertlm')).code, 'not_android');
      expect((await nano.status()).code, 'not_android');
      final r1 = await collect(lm.stream(request([user('x')], modelId: 'g')));
      expect((r1.error! as ProviderException).kind, ProviderErrorKind.unsupported);
      final r2 = await collect(nano.stream(request([user('x')], modelId: GeminiNanoProvider.modelId)));
      expect((r2.error! as ProviderException).kind, ProviderErrorKind.unsupported);
      await expectLater(lm.capabilities('g'), throwsA(isA<ProviderException>()));
      expect((await lm.listModels()).single.id, 'g');
      await lm.release();
      final dl = await nano.download().toList();
      expect(dl.single, isA<NanoDownloadFailed>());
      await lm.dispose();
      await fg.dispose();
    });

    test('the shared backend is Pigeon on Android and unsupported elsewhere', () {
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        SherpaLitert.backend = null;
      });
      for (final (platform, supported) in [
        (TargetPlatform.android, true),
        (TargetPlatform.iOS, false),
        (TargetPlatform.linux, false),
        (TargetPlatform.macOS, false),
      ]) {
        debugDefaultTargetPlatformOverride = platform;
        SherpaLitert.backend = null;
        expect(SherpaLitert.backend.isSupported, supported, reason: '$platform');
      }
    });
  });
}
