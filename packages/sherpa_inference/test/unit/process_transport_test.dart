import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa_inference/sherpa_inference.dart';
import 'package:sherpa_inference/testing.dart';

/// ProcessEngineHost over the real generated Pigeon channels, with the
/// platform side mocked at the BinaryMessenger: channel names, the codec
/// (sealed calls/messages, typed arrays), error envelopes.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const codec = InferenceHostApi.pigeonChannelCodec;
  const prefix = 'dev.flutter.pigeon.sherpa_inference.InferenceHostApi';
  const events = EventChannel('dev.flutter.pigeon.sherpa_inference.InferenceEventApi.inferenceMessages', pigeonMethodCodec);

  late MockStreamHandlerEventSink sink;
  late List<Object?> sent;
  var connectionAlive = true;

  setUp(() {
    sent = [];
    connectionAlive = true;
    messenger.setMockStreamHandler(events, MockStreamHandler.inline(onListen: (_, s) => sink = s));
    messenger.setMockMessageHandler('$prefix.connect', (data) async {
      final args = codec.decodeMessage(data)! as List<Object?>;
      expect(args.single, BindPolicy.adaptive);
      Future<void>.delayed(Duration.zero, () => sink.success(HostStatus(kind: HostStatusKind.connected, connection: 7, pid: 1234)));
      return codec.encodeMessage(<Object?>[7]);
    });
    messenger.setMockMessageHandler('$prefix.setBusy', (data) async => codec.encodeMessage(<Object?>[null]));
    messenger.setMockMessageHandler('$prefix.disconnect', (data) async => codec.encodeMessage(<Object?>[null]));
    messenger.setMockMessageHandler('$prefix.send', (data) async {
      final args = codec.decodeMessage(data)! as List<Object?>;
      final (connection, id, call) = (args[0]! as int, args[1]! as int, args[2]! as EngineCall);
      if (!connectionAlive) return codec.encodeMessage(<Object?>['not_connected', 'the inference process died', null]);
      expect(connection, 7);
      sent.add(call);
      Future<void>.delayed(Duration.zero, () {
        switch (call) {
          case StartCall():
            sink.success(CallResult(
                requestId: id, value: EngineInfoMsg(abiVersion: 1, version: 'v', systemInfoJson: '{}', pid: 1234)));
          case LoadModelCall():
            sink.success(LoadProgress(requestId: id, progress: 0.5));
            sink.success(CallResult(requestId: id, value: HandleInfoMsg(handle: (9 << 32) | 1, infoJson: '{"arch":"x"}')));
          case TokenizeCall(:final text):
            sink.success(CallResult(requestId: id, value: Int32List.fromList(List.filled(text.length, 3))));
          case CountChatCall():
            sink.success(CallError(requestId: id, code: -9, message: 'template'));
          default:
            sink.success(CallResult(requestId: id));
        }
      });
      return codec.encodeMessage(<Object?>[null]);
    });
  });

  tearDown(() {
    for (final m in ['connect', 'send', 'setBusy', 'disconnect']) {
      messenger.setMockMessageHandler('$prefix.$m', null);
    }
    messenger.setMockStreamHandler(events, null);
  });

  test('start, calls, typed results, errors and progress travel the generated channels', () async {
    final host = ProcessEngineHost(transport: PigeonInferenceTransport());
    final info = await host.start();
    expect(info.libraryLocator, contains('pid 1234'));
    expect((sent.single as StartCall).library, 'libsherpa_engine.so');
    final progress = <double>[];
    final m = await host.loadModel(const ModelLoadOptions(path: '/m.gguf'), onProgress: progress.add);
    expect(m.ref.id, (9 << 32) | 1);
    expect(progress, [0.5]);
    expect((sent.last as LoadModelCall).options.path, '/m.gguf');
    expect(await host.tokenize(m.ref, 'abcd'), [3, 3, 3, 3]);
    await expectLater(host.countChatTokens(m.ref, '{}'),
        throwsA(isA<EngineException>().having((e) => e.code, 'code', -9).having((e) => e.message, 'message', 'template')));
    connectionAlive = false;
    await expectLater(host.tokenize(m.ref, 'x'),
        throwsA(isA<EngineCrashedException>().having((e) => e.message, 'message', contains('not_connected'))));
    await host.dispose();
  });
}
