import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa_apple_ml/sherpa_apple_ml.dart';
import 'package:sherpa_apple_ml/src/common/event_router.dart';
import 'package:sherpa_apple_ml/src/common/serial_queue.dart';
import 'package:sherpa_apple_ml/testing.dart';
import 'package:sherpa_core/sherpa_core.dart';

const _prefix = 'dev.flutter.pigeon.sherpa_apple_ml.AppleMlHostApi';
const _codec = AppleMlHostApi.pigeonChannelCodec;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  group('Pigeon backend', () {
    tearDown(() {
      for (final m in ['platformInfo', 'mlxGenerate', 'fmSubmitToolResults']) {
        messenger.setMockMessageHandler('$_prefix.$m', null);
      }
    });

    test('generated codec round-trips a generate request and the platform facts', () async {
      late AmMlxGenerateRequest seen;
      messenger.setMockMessageHandler('$_prefix.mlxGenerate', (ByteData? message) async {
        seen = (_codec.decodeMessage(message)! as List<Object?>).single! as AmMlxGenerateRequest;
        return _codec.encodeMessage(<Object?>[null]);
      });
      messenger.setMockMessageHandler('$_prefix.platformInfo', (ByteData? message) async {
        return _codec.encodeMessage(<Object?>[FakeAppleMlBackend.iosDevice(available: 5 << 30)]);
      });
      final backend = PigeonAppleMlBackend();
      await backend.mlxGenerate(
        AmMlxGenerateRequest(
          generationId: 'g1',
          modelId: 'm',
          sessionKey: 's',
          ephemeral: false,
          mode: AmHistoryMode.append,
          history: const [],
          pending: [
            AmWireMessage(role: 'tool', content: 'ok')
              ..toolCallId = 'c1'
              ..toolName = 't',
          ],
          sampling: AmSampling()..temperature = 0.3,
          kv: AmKvConfig()..kvScheme = 'turbo8v3',
        ),
      );
      expect(seen.mode, AmHistoryMode.append);
      expect(seen.pending.single.toolCallId, 'c1');
      expect(seen.sampling.temperature, 0.3);
      expect(seen.kv.kvScheme, 'turbo8v3');
      final info = await backend.platformInfo();
      expect(info.procAvailableBytes, 5 << 30, reason: '64-bit ints survive the codec');
      await backend.dispose();
    });

    test('native errors arrive as PlatformException with the Swift code', () async {
      messenger.setMockMessageHandler('$_prefix.mlxGenerate', (ByteData? message) async {
        return _codec.encodeMessage(<Object?>['sessionLost', 'dropped', null]);
      });
      final backend = PigeonAppleMlBackend();
      await expectLater(
        backend.mlxGenerate(
          AmMlxGenerateRequest(
            generationId: 'g',
            modelId: 'm',
            sessionKey: 's',
            ephemeral: false,
            mode: AmHistoryMode.append,
            history: const [],
            pending: const [],
            sampling: AmSampling(),
            kv: AmKvConfig(),
          ),
        ),
        throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'sessionLost')),
      );
      await backend.dispose();
    });

    test('one native event subscription is shared by every listener', () async {
      final native = StreamController<AmEventBatch>.broadcast();
      var listens = 0;
      final backend = PigeonAppleMlBackend()
        ..nativeEvents = () {
          listens++;
          return native.stream;
        };
      final a = <AmEventBatch>[], b = <AmEventBatch>[];
      final sa = backend.events().listen(a.add);
      final sb = backend.events().listen(b.add);
      native.add(
        AmEventBatch(
          generationId: 'g',
          seq: 0,
          events: [AmEvent(kind: AmEventKind.text)..text = 'x'],
        ),
      );
      await pumpEventQueue();
      expect(listens, 1);
      expect((a.length, b.length), (1, 1));
      await sa.cancel();
      await sb.cancel();
      await backend.dispose();
      await native.close();
    });
  });

  group('EventRouter', () {
    test('routes by generation, replays early batches, acks late ones, forwards globals', () async {
      final fake = FakeAppleMlBackend();
      final router = EventRouter(fake);
      final globals = <AmEvent>[];
      final sub = router.global.listen(globals.add);
      final route = router.open('g1');
      final g = fakeGeneration(fake, 'g1');
      g.text('early');
      await pumpEventQueue();
      final got = <String>[];
      route.listen((b) {
        got.addAll(b.events.map((e) => e.text ?? e.kind.name));
        route.ack(b.seq);
      }, onError: (_) {});
      expect(got, ['early']);
      route.close();
      fakeGeneration(fake, 'g1').text('late'); // after close: acked, dropped
      await pumpEventQueue();
      expect(fake.acks.map((a) => a.$2), [0, 1], reason: 'the late batch is acked too');
      fake.emitGlobal(AmEvent(kind: AmEventKind.lifecycle)..code = 'inactive');
      await pumpEventQueue();
      expect(globals.single.code, 'inactive');
      await sub.cancel();
      await router.dispose();
      await fake.close();
    });

    test('a broken channel fails open routes', () async {
      final fake = FakeAppleMlBackend();
      final router = EventRouter(fake);
      final route = router.open('g1');
      Object? error;
      route.listen((_) {}, onError: (e) => error = e);
      fake.failChannel(StateError('channel'));
      await pumpEventQueue();
      expect(error, isA<StateError>());
      await router.dispose();
      await fake.close();
    });
  });

  group('SerialQueue', () {
    test('runs in order; a job cancelled while queued is skipped', () async {
      final q = SerialQueue();
      final order = <int>[];
      final gate = Completer<void>();
      final a = q.run(() async {
        await gate.future;
        order.add(1);
      });
      final token = CancellationToken();
      final b = q.run(() async => order.add(2), cancel: token);
      final c = q.run(() async => order.add(3));
      token.cancel('stop');
      await expectLater(b, throwsA(isA<CancelledException>()));
      gate.complete();
      await Future.wait([a, c]);
      expect(order, [1, 3]);
      expect(q.length, 0);
    });

    test('a failing job does not block the queue', () async {
      final q = SerialQueue();
      await expectLater(q.run<void>(() async => throw StateError('x')), throwsStateError);
      expect(await q.run(() async => 7), 7);
    });
  });

  test('UnsupportedAppleMlBackend: no native side, calls throw or no-op', () async {
    const b = UnsupportedAppleMlBackend();
    expect(b.isSupported, isFalse);
    await expectLater(b.platformInfo(), throwsUnsupportedError);
    await b.cancel('x');
    expect(await b.events().isEmpty, isTrue);
  });
}

/// Starts a fake generation outside a provider (router tests).
FakeGeneration fakeGeneration(FakeAppleMlBackend fake, String id) {
  final existing = fake.generations[id];
  if (existing != null) return existing;
  unawaited(
    fake.mlxGenerate(
      AmMlxGenerateRequest(
        generationId: id,
        modelId: 'm',
        sessionKey: 's',
        ephemeral: true,
        mode: AmHistoryMode.rebuild,
        history: const [],
        pending: const [],
        sampling: AmSampling(),
        kv: AmKvConfig(),
      ),
    ),
  );
  return fake.generations[id]!;
}
