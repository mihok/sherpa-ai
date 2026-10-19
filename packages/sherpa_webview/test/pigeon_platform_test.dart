import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa_webview/sherpa_webview.dart';
import 'package:sherpa_webview/src/platform/messages.pigeon.dart';

const _prefix = 'dev.flutter.pigeon.sherpa_webview';
const MessageCodec<Object?> _codec = McpAppHostApi.pigeonChannelCodec;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <String, List<Object?>>{};

  void host(String method, Object? Function(List<Object?> args) reply) {
    messenger.setMockMessageHandler('$_prefix.McpAppHostApi.$method', (data) async {
      final args = (_codec.decodeMessage(data) as List<Object?>?) ?? const [];
      calls[method] = args;
      return _codec.encodeMessage(<Object?>[reply(args)]);
    });
  }

  Future<void> fromNative(String method, List<Object?> args) async {
    await messenger.handlePlatformMessage('$_prefix.McpAppFlutterApi.$method', _codec.encodeMessage(args), (_) {});
  }

  setUp(() {
    calls.clear();
    host('support', (_) => NativeSupport(supported: true));
    host('createView', (_) => null);
    host('postToShell', (_) => null);
    host('disposeView', (_) => null);
    host('clearProfile', (_) => true);
  });

  test('createView sends the config; native messages and events reach the right view', () async {
    final platform = PigeonMcpAppPlatform.instance;
    expect((await platform.support()).supported, isTrue);
    final csp = McpAppCsp.build(DeclaredDomains.fromCsp({
      'connectDomains': ['https://api.example.com'],
    }));
    final a = await platform.createView(McpAppNativeViewConfig(
      csp: csp.policy,
      allowedOrigins: csp.allowedOrigins,
      profileKey: McpAppNativeViewConfig.profileKeyFor('weather'),
    ));
    final sent = calls['createView']!.single! as NativeViewConfig;
    expect(sent.viewId, a.viewId);
    expect(sent.csp, csp.policy);
    expect(sent.allowedOrigins, ['https://api.example.com']);
    expect(sent.profileKey, hasLength(24));
    expect(sent.debuggable, isFalse);

    final b = await platform.createView(const McpAppNativeViewConfig(csp: 'x', allowedOrigins: [], profileKey: 'k'));
    expect(b.viewId, isNot(a.viewId));

    final gotA = <String>[];
    final gotB = <String>[];
    a.channel.fromShell.listen(gotA.add);
    b.channel.fromShell.listen(gotB.add);
    final events = <McpAppNativeEvent>[];
    a.events.listen(events.add);

    await fromNative('onShellMessage', [a.viewId, '{"kind":"ready"}']);
    await fromNative('onShellMessage', [b.viewId, '{"kind":"other"}']);
    await fromNative('onShellMessage', [999, '{"kind":"nobody"}']);
    await fromNative('onViewEvent', [a.viewId, NativeViewEvent(kind: NativeViewEventKind.renderProcessGone, detail: 'crashed')]);
    await pumpEventQueue();
    expect(gotA, ['{"kind":"ready"}']);
    expect(gotB, ['{"kind":"other"}']);
    expect(events.single.kind, NativeViewEventKind.renderProcessGone);
    expect(events.single.detail, 'crashed');

    a.channel.toShell('{"kind":"post"}');
    await pumpEventQueue();
    expect(calls['postToShell'], [a.viewId, '{"kind":"post"}']);

    await a.dispose();
    expect(calls['disposeView'], [a.viewId]);
    calls.remove('postToShell');
    a.channel.toShell('{"kind":"late"}');
    await fromNative('onShellMessage', [a.viewId, '{"kind":"late"}']);
    await pumpEventQueue();
    expect(calls.containsKey('postToShell'), isFalse, reason: 'nothing is sent after dispose');
    expect(gotA, hasLength(1));

    await platform.clearServerData('k');
    expect(calls['clearProfile'], ['k']);
    await b.dispose();
  });

  test('a missing plugin reports unsupported instead of throwing', () async {
    messenger.setMockMessageHandler('$_prefix.McpAppHostApi.support', null);
    final s = await PigeonMcpAppPlatform.instance.support();
    expect(s.supported, isFalse);
  });
}
