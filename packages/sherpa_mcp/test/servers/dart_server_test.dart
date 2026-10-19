import 'dart:async';

import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_mcp/sherpa_mcp.dart';
import 'package:test/test.dart';

import '../support/helpers.dart' show eventually;

final _config = McpServerConfig(
  id: 'local',
  name: 'Local',
  url: Uri.parse('sherpa-inprocess://local'),
  transport: McpTransportPreference.inProcess,
);

const _options = McpClientOptions(
  logLevel: McpLogLevel.info,
  timeouts: McpTimeouts(request: Duration(seconds: 5), inProcessProbe: Duration(milliseconds: 500)),
);

DartMcpServer _server({List<DartMcpTool>? tools}) => DartMcpServer(
      info: const McpImplementation(name: 'local', title: 'Local', version: '2.0'),
      instructions: 'Local test server.',
      tools: tools ??
          [
            DartMcpTool(
              name: 'add',
              description: 'Adds two numbers.',
              inputSchema: const {
                'type': 'object',
                'properties': {
                  'a': {'type': 'number'},
                  'b': {'type': 'number'},
                },
                'required': ['a', 'b'],
              },
              annotations: const ToolAnnotations(readOnlyHint: true, openWorldHint: false),
              handler: (args, ctx) async {
                ctx
                  ..progress(1, total: 1, message: 'done')
                  ..log(McpLogLevel.info, 'adding')
                  ..log(McpLogLevel.debug, 'below the requested level');
                return DartToolResult.json({'sum': (args['a']! as num) + (args['b']! as num)});
              },
            ),
            DartMcpTool(
              name: 'wait',
              description: 'Waits until cancelled.',
              inputSchema: const {'type': 'object'},
              handler: (args, ctx) async {
                await ctx.cancel.whenCancelled;
                throw const CancelledException();
              },
            ),
            DartMcpTool(
              name: 'boom',
              description: 'Throws.',
              inputSchema: const {'type': 'object'},
              handler: (args, ctx) async => throw const FormatException('bad state'),
            ),
          ],
      resources: [
        DartMcpResource(
          uri: 'memo://today',
          name: 'today',
          mimeType: 'text/plain',
          read: () async => const [McpTextResourceContents(uri: 'memo://today', text: 'hello')],
        ),
      ],
      prompts: [
        DartMcpPrompt(
          name: 'greet',
          arguments: const [McpPromptArgument(name: 'who', required: true)],
          get: (args) async => [McpPromptMessage(role: 'user', content: McpTextContent('Hi ${args['who']}'))],
        ),
      ],
    );

void main() {
  DartMcpServer? server;
  McpConnection? conn;

  Future<(DartMcpServer, McpConnection)> start() async {
    final s = server = _server();
    final (client, channel) = InProcessTransport.pair();
    s.serve(channel);
    final c = conn = await McpConnection.connect(_config, options: _options, transport: client);
    return (s, c);
  }

  tearDown(() async {
    await conn?.close();
    await server?.close();
    conn = null;
    server = null;
  });

  test('speaks the modern era: discover, tools, call with progress and request-scoped logs', () async {
    final (_, c) = await start();
    expect(c.era, McpEra.modern);
    expect(c.serverInfo?.title, 'Local');
    expect(c.instructions, 'Local test server.');
    expect(c.capabilities.toolsListChanged, isTrue);
    expect(c.capabilities.resources, isTrue);
    final tools = await c.listTools();
    expect([for (final t in tools) t.name], ['add', 'wait', 'boom']);
    expect(tools.first.annotations.readOnlyHint, isTrue);
    final logs = <McpLogMessage>[];
    final sub = c.logs.listen(logs.add);
    final progress = <ToolProgress>[];
    final r = await c.callTool('add', arguments: {'a': 2, 'b': '3'}, onProgress: progress.add);
    expect(r.structuredContent, {'sum': 5});
    expect((r.content.single as McpTextContent).text, '{"sum":5}');
    expect(progress.single.message, 'done');
    await eventually(() => logs.isNotEmpty);
    expect(logs.single.data, 'adding');
    await sub.cancel();
  });

  test('invalid arguments and handler failures are isError results; unknown tools are protocol errors', () async {
    final (_, c) = await start();
    final bad = await c.callTool('add', arguments: {'a': 1});
    expect(bad.isError, isTrue);
    expect((bad.content.single as McpTextContent).text, contains('missing required property "b"'));
    final boom = await c.callTool('boom');
    expect(boom.isError, isTrue);
    expect((boom.content.single as McpTextContent).text, 'boom failed: bad state');
    await expectLater(c.callTool('nope'), throwsA(isA<McpRpcException>().having((e) => e.isInvalidParams, 'invalid', isTrue)));
  });

  test('cancellation reaches the handler through notifications/cancelled', () async {
    final (_, c) = await start();
    final token = CancellationToken();
    final call = c.callTool('wait', cancel: token);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    token.cancel();
    await expectLater(call, throwsA(isA<CancelledException>()));
  });

  test('resources and prompts', () async {
    final (_, c) = await start();
    expect([for (final r in await c.listResources()) r.uri], ['memo://today']);
    final read = await c.readResource('memo://today');
    expect((read.contents.single as McpTextResourceContents).text, 'hello');
    await expectLater(c.readResource('memo://nope'), throwsA(isA<McpRpcException>().having((e) => e.isResourceNotFound, 'nf', isTrue)));
    final p = await c.getPrompt('greet', arguments: {'who': 'Ana'});
    expect((p.messages.single.content as McpTextContent).text, 'Hi Ana');
    await expectLater(c.getPrompt('greet'), throwsA(isA<McpRpcException>()));
    expect([for (final x in await c.listPrompts()) x.name], ['greet']);
  });

  test('subscriptions/listen delivers list_changed and resource updates', () async {
    final (server, c) = await start();
    final changes = <McpChange>[];
    final sub = c.changes.listen(changes.add);
    final ack = await c.listen();
    expect(ack.toolsListChanged, isTrue);
    server.setTools([...server.tools.take(1)]);
    await eventually(() => changes.whereType<McpToolsListChanged>().isNotEmpty);
    expect([for (final t in await c.listTools()) t.name], ['add']);
    final rs = await c.subscribeResource('memo://today');
    server.notifyResourceUpdated('memo://today');
    await eventually(() => changes.whereType<McpResourceUpdated>().isNotEmpty);
    await rs.cancel();
    await sub.cancel();
  });

  test('raw protocol: unsupported version → -32022, initialize → method not found, server close ends the session',
      () async {
    final s = server = _server();
    final (client, channel) = InProcessTransport.pair();
    final session = s.serve(channel);
    await client.start();
    final wrong = await client.request(const JsonRpcRequest(JsonRpcId.int(1), 'tools/list', {
      '_meta': {McpMetaKeys.protocolVersion: '2099-01-01'},
    }));
    expect((wrong as JsonRpcErrorResponse).error.code, JsonRpcError.unsupportedProtocolVersion);
    final init = await client.request(const JsonRpcRequest(JsonRpcId.int(2), 'initialize', {}));
    expect((init as JsonRpcErrorResponse).error.code, JsonRpcError.methodNotFound);
    expect(s.sessionCount, 1);
    await s.close();
    await session.done;
    expect(s.sessionCount, 0);
    await client.close();
  });

  test('rejects tool lists the protocol forbids', () {
    DartMcpTool t(String name, Map<String, Object?> schema) =>
        DartMcpTool(name: name, description: '', inputSchema: schema, handler: (a, c) async => DartToolResult.text(''));
    const info = McpImplementation(name: 'x', version: '1');
    expect(() => DartMcpServer(info: info, tools: [t('a', const {'type': 'string'})]), throwsArgumentError);
    expect(() => DartMcpServer(info: info, tools: [t('a', const {'type': 'object'}), t('a', const {'type': 'object'})]),
        throwsArgumentError);
  });
}
