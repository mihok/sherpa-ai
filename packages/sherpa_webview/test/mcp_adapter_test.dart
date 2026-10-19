import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_mcp/sherpa_mcp.dart';
import 'package:sherpa_webview/mcp.dart';
import 'package:sherpa_webview/sherpa_webview.dart';
import 'package:sherpa_webview/testing.dart';

const _view = '<!DOCTYPE html><html><body>weather</body></html>';

DartMcpTool _tool(String name, {Map<String, Object?>? meta, ToolAnnotations annotations = const ToolAnnotations()}) =>
    DartMcpTool(
      name: name,
      description: 'Does $name things.',
      inputSchema: const {'type': 'object', 'properties': <String, Object?>{}},
      annotations: annotations,
      meta: meta,
      handler: (args, ctx) async => DartToolResult.json({'tool': name, 'args': args}),
    );

/// An in-process MCP server ("weather") with a UI resource, an app-only
/// tool, a model-only tool and an ordinary tool, behind the real manager
/// and router.
final class _Rig {
  _Rig() {
    server = DartMcpServer(
      info: const McpImplementation(name: 'weather', version: '1'),
      tools: [
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
        _tool('delete_everything', annotations: const ToolAnnotations(destructiveHint: true)),
      ],
      resources: [
        DartMcpResource(
          uri: 'ui://weather/view',
          name: 'view',
          mimeType: mcpAppMimeType,
          read: () async => [
            McpTextResourceContents(
              uri: 'ui://weather/view',
              mimeType: mcpAppMimeType,
              text: _view,
              meta: const {
                'ui': {
                  'csp': {
                    'connectDomains': ['https://api.open-meteo.example'],
                  },
                },
              },
            ),
          ],
        ),
      ],
    );
    manager = McpServerManager(
      servers: [
        McpServerConfig(
          id: 'weather',
          name: 'Weather',
          url: Uri.parse('sherpa-inprocess://weather'),
          transport: McpTransportPreference.inProcess,
          trusted: true,
        ),
      ],
      transportFactory: (c) {
        final (client, channel) = InProcessTransport.pair();
        server.serve(channel);
        return client;
      },
    );
    router = McpToolRouter(manager: manager);
  }

  late final DartMcpServer server;
  late final McpServerManager manager;
  late final McpToolRouter router;

  Future<void> close() async {
    await router.dispose();
    await manager.dispose();
    await server.close();
  }
}

Future<void> _settle() async {
  for (var i = 0; i < 40; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('mcpAppResourceFromRead: one item, mime, python meta quirk, listing fallback', () {
    McpReadResourceResult read(List<Map<String, Object?>> contents) =>
        McpReadResourceResult.fromJson({'contents': contents});
    final quirk = mcpAppResourceFromRead(
      read([
        {
          'uri': 'ui://a/v',
          'mimeType': mcpAppMimeType,
          'text': '<p>',
          'meta': {
            'ui': {
              'csp': {
                'connectDomains': ['https://python.example.com'],
              },
            },
          },
        },
      ]),
      uri: 'ui://a/v',
    );
    expect([for (final o in quirk.declared.connect) o.source], ['https://python.example.com']);
    final listed = mcpAppResourceFromRead(
      read([
        {'uri': 'ui://a/v', 'mimeType': mcpAppMimeType, 'blob': base64.encode(utf8.encode('<p>é'))},
      ]),
      uri: 'ui://a/v',
      listing: McpResource.fromJson({
        'uri': 'ui://a/v',
        'name': 'v',
        '_meta': {
          'ui': {
            'csp': {
              'resourceDomains': ['https://cdn.example.com'],
            },
          },
        },
      }),
    );
    expect(listed.html, '<p>é');
    expect([for (final o in listed.declared.resource) o.source], ['https://cdn.example.com']);
    for (final bad in [
      <Map<String, Object?>>[],
      [
        {'uri': 'ui://a/v', 'mimeType': mcpAppMimeType, 'text': '1'},
        {'uri': 'ui://a/v', 'mimeType': mcpAppMimeType, 'text': '2'},
      ],
      [
        {'uri': 'ui://a/other', 'mimeType': mcpAppMimeType, 'text': '1'},
      ],
      [
        {'uri': 'ui://a/v', 'mimeType': 'text/html', 'text': '1'},
      ],
    ]) {
      expect(() => mcpAppResourceFromRead(read(bad), uri: 'ui://a/v'), throwsA(isA<McpAppResourceException>()));
    }
  });

  test('end to end: resource load, router-backed callbacks, visibility and approval', () async {
    final rig = _Rig();
    addTearDown(rig.close);
    final resource = await loadMcpAppResource(rig.manager, serverId: 'weather', uri: 'ui://weather/view');
    expect(resource.html, _view);
    expect([for (final o in resource.declared.connect) o.source], ['https://api.open-meteo.example']);
    // The router must have listed the server before executeForApp finds its tools.
    await rig.router.toolsForTurn(sessionId: 's');
    final approvals = <McpAppToolCallRequest>[];
    var allow = true;
    final callbacks = mcpRouterAppCallbacks(
      router: rig.router,
      manager: rig.manager,
      serverId: 'weather',
      sessionId: 's',
      approveToolCall: (r) async {
        approvals.add(r);
        return allow;
      },
    );
    final channel = FakeMcpAppChannel();
    final bridge = McpAppsBridge(
      channel: channel,
      session: McpAppSession(
        serverId: 'weather',
        serverName: 'Weather',
        resource: resource,
        tool: await mcpToolJson(rig.manager, 'weather', 'get_weather'),
      ),
      callbacks: callbacks,
      csp: McpAppCsp.build(),
    );
    addTearDown(bridge.dispose);
    channel
      ..shellReady()
      ..handshake();
    await _settle();
    final init = channel.responseTo('init')!;
    expect(((init['result']! as Map)['hostContext']! as Map)['toolInfo'], {
      'tool': containsPair('name', 'get_weather'),
    });

    Future<Map<String, Object?>> call(Object id, String name) async {
      channel.viewRequest(id, 'tools/call', {
        'name': name,
        'arguments': {'city': 'Lisbon'},
      });
      for (var i = 0; i < 200 && channel.responseTo(id) == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      return channel.responseTo(id)!;
    }

    // App-only tool: callable from the app (never offered to the model).
    expect(rig.router.lookup('weather__refresh')!.modelVisible, isFalse);
    final ok = await call(1, 'refresh');
    final result = (ok['result']! as Map).cast<String, Object?>();
    expect(result['structuredContent'], {
      'tool': 'refresh',
      'args': {'city': 'Lisbon'},
    });
    expect(approvals.single.tool.visibility, ['app']);
    expect(approvals.single.tool.definition, isNotNull);

    // Model-only: refused by the bridge before approval.
    final refused = await call(2, 'model_only');
    expect((refused['error']! as Map)['code'], RpcCode.invalidParams);
    expect(approvals, hasLength(1));

    // Ordinary tool, default visibility: app-callable, but the approval
    // policy decides (destructive here).
    allow = false;
    final denied = await call(3, 'delete_everything');
    expect((denied['result']! as Map)['isError'], isTrue);
    expect(approvals.last.tool.annotations.destructiveHint, isTrue);

    // Unknown on this server.
    expect(((await call(4, 'nope'))['error']! as Map)['code'], RpcCode.invalidParams);
  });

  test('app tool lookups come from the router cache, not a tools/list per call', () async {
    final rig = _Rig();
    addTearDown(rig.close);
    await rig.router.toolsForTurn(sessionId: 's');
    expect(rig.router.appTool('weather', 'refresh')?.uiVisibility, ['app']);
    expect(rig.router.appTool('weather', 'model_only')?.uiVisibility, ['model'], reason: 'any visibility');
    expect(rig.router.appTool('weather', 'nope'), isNull);
    expect(rig.router.appTool('other', 'refresh'), isNull);
    final callbacks = mcpRouterAppCallbacks(
      router: rig.router,
      manager: rig.manager,
      serverId: 'weather',
      sessionId: 's',
      approveToolCall: (_) async => true,
    );
    // A server that would fail any further listing: lookups still work.
    final conn = await rig.manager.connection('weather');
    rig.server.setTools(const []);
    await _settle();
    final tool = await callbacks.lookupTool('refresh');
    expect(tool?.visibility, ['app']);
    expect(tool?.definition, isNotNull);
    expect(await mcpToolJson(rig.manager, 'weather', 'get_weather', router: rig.router), containsPair('name', 'get_weather'));
    expect(conn.isClosed, isFalse);
  });
}
