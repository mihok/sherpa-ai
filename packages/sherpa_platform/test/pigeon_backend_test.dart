
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa_platform/sherpa_platform.dart';
import 'package:sherpa_platform/src/messages.pigeon.dart' show SherpaPlatformHostApi, pigeonMethodCodec;

const _prefix = 'dev.flutter.pigeon.sherpa_platform.SherpaPlatformHostApi';
const _codec = SherpaPlatformHostApi.pigeonChannelCodec;

/// Exercises the generated Pigeon codec and channel names against a mocked
/// host, so a regenerated definition that drifts from the Dart wrapper fails
/// here rather than on a device.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void host(String method, Object? Function(List<Object?>? args) handler) {
    messenger.setMockMessageHandler('$_prefix.$method', (ByteData? message) async {
      final args = _codec.decodeMessage(message) as List<Object?>?;
      return _codec.encodeMessage(<Object?>[handler(args)]);
    });
  }

  tearDown(() {
    for (final m in [
      'sampleMemory',
      'beginLease',
      'setProcessStateSummary',
      'excludeFromBackup',
      'endLease',
      'requestNotificationsPermission',
      'notifyRunFinished',
      'clearFinishedNotices',
    ]) {
      messenger.setMockMessageHandler('$_prefix.$m', null);
    }
  });

  test('sampleMemory decodes every field', () async {
    host('sampleMemory', (_) => MemorySample(
          platform: 'android',
          timestampMs: 42,
          apiLevel: 37,
          availMemBytes: 1 << 32,
          thresholdBytes: 1 << 28,
          totalMemBytes: 8 << 30,
          advertisedMemBytes: 8 << 30,
          freeMemBytes: 1 << 29,
          lowMemory: false,
          lastTrimLevel: 20,
          rssBytes: 1 << 29,
          anonSwapBytes: 1 << 28,
          thermalStatus: 2,
          thermalHeadroom: 0.8,
          lowPowerMode: true,
        ));
    final s = await PigeonPlatformBackend().sampleMemory();
    expect(s.availMemBytes, 1 << 32, reason: '64-bit ints survive the codec');
    expect(s.lastTrimLevel, 20);
    expect(s.thermalHeadroom, 0.8);
    expect(s.lowPowerMode, isTrue);
    expect(s.procAvailableBytes, isNull);
  });

  test('beginLease sends the request and decodes the result', () async {
    late LeaseRequest seen;
    host('beginLease', (args) {
      seen = args!.single! as LeaseRequest;
      return LeaseResult(id: seen.id, mode: LeaseMode.iosContinuedProcessing, granted: true, notificationsVisible: true);
    });
    final r = await PigeonPlatformBackend().beginLease(LeaseRequest(
      id: 'abc',
      title: 'Agent run',
      reason: 'Step 2 of 5',
      long: true,
      iosContinuedTaskIdentifier: 'io.github.mihok.sherpa.agentrun.abc',
      iosRequestGpu: false,
    ));
    expect(seen.title, 'Agent run');
    expect(seen.iosContinuedTaskIdentifier, 'io.github.mihok.sherpa.agentrun.abc');
    expect(r.mode, LeaseMode.iosContinuedProcessing);
  });

  test('bytes and lists cross the channel', () async {
    host('setProcessStateSummary', (args) => (args!.single! as Uint8List).length == 3);
    host('excludeFromBackup', (args) => ['${args![0]}', if (args[1]! as bool) '${args[0]}-wal']);
    final b = PigeonPlatformBackend();
    expect(await b.setProcessStateSummary(Uint8List.fromList([1, 2, 3])), isTrue);
    expect(await b.excludeFromBackup('/db', includeSqliteSidecars: true), ['/db', '/db-wal']);
  });

  test('notification calls cross the channel', () async {
    late FinishedNotice seen;
    var cleared = 0;
    host('requestNotificationsPermission', (_) => true);
    host('notifyRunFinished', (args) {
      seen = args!.single! as FinishedNotice;
      return true;
    });
    host('clearFinishedNotices', (_) {
      cleared++;
      return null;
    });
    final b = PigeonPlatformBackend();
    expect(await b.requestNotificationsPermission(), isTrue);
    expect(
      await b.notifyRunFinished(FinishedNotice(tag: 's1', title: 'Reply ready', text: 'Open Sherpa', androidChannelName: 'Done')),
      isTrue,
    );
    expect((seen.tag, seen.title, seen.text, seen.androidChannelName), ('s1', 'Reply ready', 'Open Sherpa', 'Done'));
    await b.clearFinishedNotices();
    expect(cleared, 1);
  });

  test('native errors surface as PlatformException', () async {
    messenger.setMockMessageHandler('$_prefix.endLease', (_) async => _codec.encodeMessage(['Boom', 'bad', null]));
    await expectLater(PigeonPlatformBackend().endLease('x'), throwsA(isA<PlatformException>()));
  });

  test('one native event-channel listen is shared by every Dart listener', () async {
    var listens = 0;
    var cancels = 0;
    MockStreamHandlerEventSink? sink;
    messenger.setMockStreamHandler(
      const EventChannel('dev.flutter.pigeon.sherpa_platform.SherpaPlatformEventApi.signals', pigeonMethodCodec),
      MockStreamHandler.inline(
        onListen: (_, s) {
          listens++;
          sink = s;
        },
        onCancel: (_) => cancels++,
      ),
    );
    final backend = PigeonPlatformBackend();
    final a = <PlatformSignal>[];
    final b = <PlatformSignal>[];
    final subA = backend.signals().listen(a.add);
    final subB = backend.signals().listen(b.add);
    await pumpEventQueue();
    expect(listens, 1);
    sink!.success(PlatformSignal(kind: SignalKind.trimMemory, level: 40, timestampMs: 1));
    await pumpEventQueue();
    expect(a.single.level, 40);
    expect(b.single.kind, SignalKind.trimMemory);
    await subA.cancel();
    await pumpEventQueue();
    expect(cancels, 0);
    await subB.cancel();
    await pumpEventQueue();
    expect(cancels, 1);
    await backend.dispose();
  });
}
