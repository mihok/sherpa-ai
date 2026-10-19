import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa/features/apps/app_view_pool.dart';
import 'package:sherpa/features/apps/mcp_app_message_view.dart';
import 'package:sherpa/features/apps/state/apps_providers.dart';
import 'package:sherpa/features/mcp/server_host_sections.dart';
import 'package:sherpa/services/mcp/input/host_settings.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_mcp/sherpa_mcp.dart';
import 'package:sherpa_webview/sherpa_webview.dart';
import 'package:sherpa_webview/testing.dart';

import '../mcp/support/input_rig.dart';

const _url = 'https://weather.example.com/mcp';
const _html = '<!DOCTYPE html><html><body>weather</body></html>';

DartMcpTool _tool(String name, {JsonMap? meta, ToolAnnotations annotations = const ToolAnnotations()}) => DartMcpTool(
      name: name,
      description: 'Does $name things.',
      inputSchema: const {'type': 'object', 'properties': <String, Object?>{}},
      annotations: annotations,
      meta: meta,
      handler: (args, ctx) async => DartToolResult.json({'tool': name, 'args': args}),
    );

FakeRemoteServers _weather({List<String> connect = const ['https://api.open-meteo.example']}) => FakeRemoteServers()
  ..add(_url, name: 'Weather', tools: [
    _tool('get_weather', meta: const {
      'ui': {'resourceUri': 'ui://weather/view'},
    }),
    _tool('refresh', meta: const {
      'ui': {
        'visibility': ['app'],
      },
    }),
    _tool('model_only', meta: const {
      'ui': {
        'visibility': ['model'],
      },
    }),
  ], resources: [
    DartMcpResource(
      uri: 'ui://weather/view',
      name: 'view',
      mimeType: mcpAppMimeType,
      read: () async => [
        McpTextResourceContents(
          uri: 'ui://weather/view',
          mimeType: mcpAppMimeType,
          text: _html,
          meta: {
            'ui': {
              'csp': {'connectDomains': connect},
            },
          },
        ),
      ],
    ),
  ]);

ToolResultPart _result(String serverId, {String callId = 'c1'}) => ToolResultPart(
      callId: callId,
      toolName: 'weather__get_weather',
      content: const [TextPart('Lisbon: 21°C, clear')],
      structured: const {'tempC': 21},
      uiResourceUri: 'ui://weather/view',
      meta: {ToolResultPart.metaServerId: serverId},
    );

final class _AppsRig {
  _AppsRig(this.rig, this.serverId);

  static Future<_AppsRig> create(WidgetTester tester, {FakeRemoteServers? remote, int maxLive = 3, Duration hiddenGrace = const Duration(seconds: 5)}) async {
    McpAppController.resetProfileCountsForTest();
    final rig = await InputRig.create(tester, remote: remote ?? _weather());
    late String id;
    await tester.runAsync(() async {
      final c = await rig.runtime.addServer(url: Uri.parse(_url), name: 'Weather');
      id = c.id;
      await rig.runtime.refresh();
      await rig.runtime.approveAll(id);
    });
    final apps = _AppsRig(rig, id);
    rig.extra = [
      mcpAppPlatformProvider.overrideWithValue(apps.platform),
      mcpAppMessageSinkProvider.overrideWithValue(apps.messages.add),
      mcpAppViewPoolProvider.overrideWith((ref) {
        final p = McpAppViewPool(ref, maxLive: maxLive, hiddenGrace: hiddenGrace);
        ref.onDispose(p.dispose);
        return p;
      }),
    ];
    return apps;
  }

  final InputRig rig;
  final String serverId;
  final FakeMcpAppPlatform platform = FakeMcpAppPlatform();
  final List<McpAppInsertedMessage> messages = [];

  Future<void> pump(WidgetTester tester, Widget home) async {
    await rig.pumpApp(tester, home: home);
    await settle(tester);
  }

  Future<void> settle(WidgetTester tester, {int rounds = 8}) => rig.settle(tester, rounds: rounds, andSettle: false);

  /// Unmounts everything and lets teardown timers run out.
  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  }
}

Future<Map<String, Object?>?> _response(WidgetTester tester, InputRig rig, FakeMcpAppChannel ch, Object id) async {
  for (var i = 0; i < 40 && ch.responseTo(id) == null; i++) {
    await rig.settle(tester, rounds: 2, andSettle: false);
  }
  return ch.responseTo(id);
}

void main() {
  testWidgets('renders the view with tool data; network consent is asked once and persisted per server + hash',
      (tester) async {
    final a = await _AppsRig.create(tester);
    final part = _result(a.serverId);
    await a.pump(
      tester,
      Scaffold(body: ListView(children: [McpAppMessageView(sessionId: 's1', result: part, toolArguments: const {'city': 'Lisbon'})])),
    );
    // The view declares a connect domain: consent first, nothing created yet.
    expect(find.text('Let this view use the internet?'), findsOneWidget);
    expect(find.text('• https://api.open-meteo.example'), findsOneWidget);
    expect(a.platform.views, isEmpty);
    await tester.tap(find.text('Allow'));
    await a.settle(tester);
    final view = a.platform.last;
    expect(view.config.allowedOrigins, ['https://api.open-meteo.example']);
    expect(view.config.csp, contains('connect-src https://api.open-meteo.example'));
    final sha = a.rig.runtime.hostSettings.consentsOf(a.serverId).single.resourceSha256;
    expect(a.rig.runtime.hostSettings.grantedOrigins(a.serverId, sha), {'https://api.open-meteo.example'});

    view.fake
      ..shellReady()
      ..handshake();
    await a.settle(tester);
    expect(find.text('Content from Weather'), findsOneWidget, reason: 'host chrome outside the WebView');
    expect(view.fake.commands('load').single['html'], _html);
    final init = (view.fake.responseTo('init')!['result']! as Map).cast<String, Object?>();
    final ctx = (init['hostContext']! as Map).cast<String, Object?>();
    expect((ctx['toolInfo']! as Map)['tool'], containsPair('name', 'get_weather'));
    expect(((ctx['styles']! as Map)['variables']! as Map)['--color-background-primary'], startsWith('light-dark('));
    expect(ctx['platform'], 'mobile');
    expect(view.fake.notifications('ui/notifications/tool-input').single['params'], {
      'arguments': {'city': 'Lisbon'},
    });
    expect((view.fake.notifications('ui/notifications/tool-result').single['params']! as Map)['structuredContent'], {'tempC': 21});

    // Another call's view of the same resource: no second question.
    await a.close(tester);
    await a.pump(
      tester,
      Scaffold(body: ListView(children: [McpAppMessageView(sessionId: 's1', result: _result(a.serverId, callId: 'c2'))])),
    );
    expect(find.text('Let this view use the internet?'), findsNothing);
    expect(a.platform.last.config.allowedOrigins, ['https://api.open-meteo.example']);

    // Revoking it from the server's settings closes the view; shown again it asks.
    await tester.runAsync(() => a.rig.runtime.hostSettings.revokeConsent(a.serverId, sha));
    await a.settle(tester);
    expect(find.text('Let this view use the internet?'), findsOneWidget);
    await tester.tap(find.text('Keep offline'));
    await a.settle(tester);
    expect(a.platform.last.config.allowedOrigins, isEmpty);
    expect(a.rig.runtime.hostSettings.grantedOrigins(a.serverId, sha), isEmpty, reason: '"offline" is remembered');
    await a.close(tester);
  });

  testWidgets('tool calls from the view: approval (tainted), visibility refusal, same server only', (tester) async {
    final a = await _AppsRig.create(tester, remote: _weather(connect: const []));
    await a.pump(tester, Scaffold(body: ListView(children: [McpAppMessageView(sessionId: 's1', result: _result(a.serverId))])));
    final ch = a.platform.last.fake
      ..shellReady()
      ..handshake(name: 'Weather Dashboard');
    await a.settle(tester);

    ch.viewRequest(1, 'tools/call', {
      'name': 'refresh',
      'arguments': {'city': 'Porto'},
    });
    await a.settle(tester);
    expect(find.text('Allow “refresh”?'), findsOneWidget, reason: 'an untrusted server: the user decides');
    expect(find.text('Requested by "Weather Dashboard", an app from Weather'), findsOneWidget);
    expect(find.textContaining('The app asked for this itself'), findsOneWidget);
    await tester.tap(find.text('Allow once'));
    final ok = await _response(tester, a.rig, ch, 1);
    expect(((ok!['result']! as Map)['structuredContent']! as Map)['tool'], 'refresh');

    ch.viewRequest(2, 'tools/call', {'name': 'refresh', 'arguments': <String, Object?>{}});
    await a.settle(tester);
    await tester.tap(find.text('Deny'));
    final denied = await _response(tester, a.rig, ch, 2);
    expect((denied!['result']! as Map)['isError'], isTrue);

    ch.viewRequest(3, 'tools/call', {'name': 'model_only', 'arguments': <String, Object?>{}});
    final refused = await _response(tester, a.rig, ch, 3);
    expect((refused!['error']! as Map)['code'], RpcCode.invalidParams);
    expect(find.text('Allow “model_only”?'), findsNothing, reason: 'refused before any approval');

    expect(a.rig.runtime.policy.grants, isEmpty, reason: '"Allow once" remembers nothing');
    await a.close(tester);
  });

  testWidgets('the chat can route app tool approvals to its own approval UI', (tester) async {
    final a = await _AppsRig.create(tester, remote: _weather(connect: const []));
    final asked = <(String, ToolCall, ToolDefinition?)>[];
    a.rig.extra = [
      ...a.rig.extra,
      mcpAppApprovalHandlerProvider.overrideWithValue((sessionId) => _RecordingApprovals((s, c, t) => asked.add((s, c, t)))),
    ];
    await a.pump(tester, Scaffold(body: ListView(children: [McpAppMessageView(sessionId: 's9', result: _result(a.serverId))])));
    final ch = a.platform.last.fake
      ..shellReady()
      ..handshake();
    await a.settle(tester);
    ch.viewRequest(1, 'tools/call', {'name': 'refresh', 'arguments': <String, Object?>{}});
    final r = await _response(tester, a.rig, ch, 1);
    expect((r!['result']! as Map)['isError'], isNot(true));
    expect(asked.single.$1, 's9');
    expect(asked.single.$2.name, 'weather__refresh');
    expect(asked.single.$3?.source.serverId, a.serverId);
    expect(find.text('Allow “refresh”?'), findsNothing, reason: "the chat's UI answered");
    await a.close(tester);
  });

  testWidgets('ui/message needs confirmation and goes to the chat; links open only after confirmation', (tester) async {
    final a = await _AppsRig.create(tester, remote: _weather(connect: const []));
    await a.pump(tester, Scaffold(body: ListView(children: [McpAppMessageView(sessionId: 's1', result: _result(a.serverId))])));
    final ch = a.platform.last.fake
      ..shellReady()
      ..handshake(name: 'Weather Dashboard');
    await a.settle(tester);
    final caps = (((ch.responseTo('init')!['result']! as Map)['hostCapabilities']) as Map);
    expect(caps.containsKey('message'), isTrue, reason: 'advertised because the chat accepts messages');
    expect(caps.containsKey('openLinks'), isTrue);

    ch.viewRequest(1, 'ui/message', {
      'role': 'user',
      'content': [
        {'type': 'text', 'text': 'Show me Porto too'},
      ],
    });
    await a.settle(tester);
    expect(find.text('Send this message?'), findsOneWidget);
    expect(find.text('Show me Porto too'), findsOneWidget);
    await tester.tap(find.text("Don't send"));
    final no = await _response(tester, a.rig, ch, 1);
    expect((no!['result']! as Map)['isError'], isTrue);
    expect(a.messages, isEmpty);

    ch.viewRequest(2, 'ui/message', {
      'role': 'user',
      'content': [
        {'type': 'text', 'text': 'Show me Porto too'},
      ],
    });
    await a.settle(tester);
    await tester.tap(find.text('Send'));
    await _response(tester, a.rig, ch, 2);
    expect(a.messages.single.text, 'Show me Porto too');
    expect(a.messages.single.sessionId, 's1');
    expect(a.messages.single.identity.appName, 'Weather Dashboard');
    expect(a.messages.single.callId, 'c1');

    ch.viewRequest(3, 'ui/open-link', {'url': 'https://forecast.example.com/porto?x=1'});
    await a.settle(tester);
    expect(find.text('Open this link?'), findsOneWidget);
    expect(find.text('forecast.example.com'), findsOneWidget);
    expect(find.text('https://forecast.example.com/porto?x=1'), findsOneWidget);
    expect(a.rig.opener.opened, isEmpty);
    await tester.tap(find.text('Cancel'));
    await _response(tester, a.rig, ch, 3);
    expect(a.rig.opener.opened, isEmpty, reason: 'nothing opens without confirmation');

    ch.viewRequest(4, 'ui/open-link', {'url': 'https://forecast.example.com/porto'});
    await a.settle(tester);
    await tester.tap(find.text('Open'));
    await _response(tester, a.rig, ch, 4);
    expect(a.rig.opener.opened.single.$1, Uri.parse('https://forecast.example.com/porto'));

    ch.viewRequest(5, 'ui/open-link', {'url': 'javascript:alert(1)'});
    await _response(tester, a.rig, ch, 5);
    expect(find.text('Open this link?'), findsNothing, reason: 'refused by the link policy before asking');
    await a.close(tester);
  });

  testWidgets('apps turned off for the server: text fallback and no WebView', (tester) async {
    final a = await _AppsRig.create(tester, remote: _weather(connect: const []));
    await tester.runAsync(() => a.rig.runtime.updateHostSettings(
        a.serverId, a.rig.runtime.hostSettingsOf(a.serverId).copyWith(appsEnabled: false)));
    await a.pump(tester, Scaffold(body: ListView(children: [McpAppMessageView(sessionId: 's1', result: _result(a.serverId))])));
    expect(find.text('Lisbon: 21°C, clear'), findsOneWidget);
    expect(find.text('Interactive content is turned off for this server.'), findsOneWidget);
    expect(a.platform.views, isEmpty);
    await a.close(tester);
  });

  testWidgets('a result without a view, or an invalid resource, shows the text', (tester) async {
    final a = await _AppsRig.create(tester, remote: _weather(connect: const []));
    final noView = ToolResultPart(callId: 'x', toolName: 't', content: const [TextPart('plain')]);
    final broken = ToolResultPart(
      callId: 'y',
      toolName: 'weather__get_weather',
      content: const [TextPart('fallback text')],
      uiResourceUri: 'ui://weather/missing',
      meta: {ToolResultPart.metaServerId: a.serverId},
    );
    await a.pump(
      tester,
      Scaffold(
        body: ListView(children: [
          McpAppMessageView(sessionId: 's1', result: noView),
          McpAppMessageView(sessionId: 's1', result: broken),
        ]),
      ),
    );
    expect(find.text('plain'), findsOneWidget);
    expect(find.text('fallback text'), findsOneWidget);
    expect(find.textContaining('could not be loaded'), findsOneWidget);
    expect(a.platform.views, isEmpty);
    await a.close(tester);
  });

  testWidgets('the pool keeps at most maxLive views and suspends the ones scrolled away', (tester) async {
    final a = await _AppsRig.create(tester, remote: _weather(connect: const []), maxLive: 2, hiddenGrace: const Duration(milliseconds: 100));
    final controller = ScrollController();
    await a.pump(
      tester,
      Scaffold(
        body: ListView(
          controller: controller,
          scrollCacheExtent: const ScrollCacheExtent.pixels(5000),
          children: [
            for (var i = 0; i < 4; i++) ...[
              SizedBox(height: 260, child: McpAppMessageView(sessionId: 's1', result: _result(a.serverId, callId: 'c$i'))),
              const SizedBox(height: 900),
            ],
          ],
        ),
      ),
    );
    final container = ProviderScope.containerOf(tester.element(find.byType(McpAppMessageView).first));
    final pool = container.read(mcpAppViewPoolProvider);
    expect(pool.entries, hasLength(4), reason: 'every view keeps its tool data');
    for (final v in a.platform.views) {
      v.fake
        ..shellReady()
        ..handshake();
    }
    await a.settle(tester);
    await tester.pump(const Duration(milliseconds: 200));
    await a.settle(tester);
    expect(pool.liveCount, lessThanOrEqualTo(2));
    final first = pool.entries.firstWhere((e) => e.spec.callId == 'c0');
    expect(first.visible, isTrue);
    expect(first.controller!.status, McpAppViewStatus.ready);

    // Scroll the first one away: it is suspended (teardown sent while mounted).
    controller.jumpTo(1200);
    await tester.pump();
    await a.settle(tester);
    await tester.pump(const Duration(milliseconds: 200));
    await a.settle(tester);
    await tester.pump(const Duration(seconds: 2));
    await a.settle(tester);
    expect(first.visible, isFalse);
    expect(first.controller!.status, McpAppViewStatus.suspended);
    expect(pool.liveCount, lessThanOrEqualTo(2));

    // Back: it re-renders from the stored tool data in a new WebView.
    final before = a.platform.views.length;
    controller.jumpTo(0);
    await tester.pump();
    await a.settle(tester);
    expect(a.platform.views.length, greaterThan(before));
    final again = a.platform.last.fake
      ..shellReady()
      ..handshake();
    await a.settle(tester);
    expect(again.notifications('ui/notifications/tool-result'), hasLength(1));
    await a.close(tester);
  });

  testWidgets('fullscreen keeps the same live view; the pool never suspends it while it is shown', (tester) async {
    final a = await _AppsRig.create(tester, remote: _weather(connect: const []), hiddenGrace: const Duration(milliseconds: 50));
    await a.pump(tester, Scaffold(body: ListView(children: [McpAppMessageView(sessionId: 's1', result: _result(a.serverId))])));
    final view = a.platform.last;
    view.fake
      ..shellReady()
      ..handshake();
    await a.settle(tester);
    await tester.tap(find.byTooltip('Open full screen'));
    await a.settle(tester);
    expect(find.byType(McpAppFullscreenPage), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 300));
    await a.settle(tester);
    final container = ProviderScope.containerOf(tester.element(find.byType(McpAppFullscreenPage)));
    final entry = container.read(mcpAppViewPoolProvider).entries.single;
    expect(entry.controller!.displayMode, McpAppDisplayMode.fullscreen);
    expect(entry.controller!.status, McpAppViewStatus.ready, reason: 'not suspended while full screen');
    expect(a.platform.views, hasLength(1), reason: 'the same WebView moved into the route');
    expect(view.mounts, 1);
    await tester.binding.handlePopRoute();
    await a.settle(tester);
    expect(entry.controller!.displayMode, McpAppDisplayMode.inline);
    await a.close(tester);
  });

  testWidgets('server detail: MCP Apps section lists consents with revoke and the apps switch', (tester) async {
    final a = await _AppsRig.create(tester);
    await tester.runAsync(() async {
      await a.rig.runtime.hostSettings.setGrantedOrigins(a.serverId, 'abc', {'https://api.open-meteo.example'}, resourceUri: 'ui://weather/view');
    });
    await a.pump(tester, Scaffold(body: ListView(children: [McpAppsSection(serverId: a.serverId), McpSamplingSection(serverId: a.serverId)])));
    expect(find.text('1 of its tools shows interactive content.'), findsOneWidget);
    expect(find.text('ui://weather/view'), findsOneWidget);
    expect(find.text('https://api.open-meteo.example'), findsOneWidget);
    await tester.tap(find.text('Revoke'));
    await a.settle(tester);
    expect(a.rig.runtime.hostSettings.consentsOf(a.serverId), isEmpty);
    expect(find.text('None granted. Views ask before they use the network.'), findsOneWidget);

    expect(a.rig.runtime.hostSettingsOf(a.serverId).sampling, McpSamplingMode.off, reason: 'off by default');
    await tester.tap(find.byKey(const ValueKey('mcp-sampling-ask')));
    await a.settle(tester);
    expect(a.rig.runtime.hostSettingsOf(a.serverId).sampling, McpSamplingMode.ask);
    expect(find.text('Longest answer'), findsOneWidget);
    await tester.tap(find.text('256 tokens'));
    await a.settle(tester);
    expect(a.rig.runtime.hostSettingsOf(a.serverId).samplingMaxTokens, 256);

    await tester.tap(find.byKey(const ValueKey('mcp-apps-switch')));
    await a.settle(tester);
    expect(a.rig.runtime.hostSettingsOf(a.serverId).appsEnabled, isFalse);
    await a.close(tester);
  });
}

final class _RecordingApprovals implements ApprovalHandler {
  _RecordingApprovals(this.onAsk);

  final void Function(String sessionId, ToolCall call, ToolDefinition? tool) onAsk;

  @override
  Future<ApprovalResponse> requestApproval({
    required String sessionId,
    required ToolCall call,
    required ToolDefinition? tool,
    required NeedsConfirmation requirement,
    required CancellationToken cancel,
  }) async {
    onAsk(sessionId, call, tool);
    return const ApprovalResponse(UserDecision.approve);
  }
}
