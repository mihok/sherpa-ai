import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_mcp/sherpa_mcp.dart';
import 'package:test/test.dart';

import '../support/fake_mcp_server.dart';
import '../support/helpers.dart';
import 'harness.dart';

/// A tool that asks for a name over MRTR (2026-07-28), then answers with it.
DartMcpTool _askTool({List<DartToolContext>? seen}) => tool(
      'ask',
      handler: (args, ctx) async {
        seen?.add(ctx);
        final answer = _map(ctx.inputResponses?['who']);
        if (answer == null) {
          return const DartToolResult.inputRequired({
            'who': {
              'method': 'elicitation/create',
              'params': {
                'mode': 'form',
                'message': 'Your name?',
                'requestedSchema': {
                  'type': 'object',
                  'properties': {
                    'name': {'type': 'string'},
                  },
                  'required': ['name'],
                },
              },
            },
          }, requestState: 'state-1');
        }
        return DartToolResult.text('hello ${_map(answer['content'])?['name']} (${ctx.requestState})');
      },
    );

JsonMap? _map(Object? v) => v is Map ? v.cast<String, Object?>() : null;

void main() {
  group('DartMcpServer MRTR', () {
    late Harness h;
    tearDown(() => h.close());

    test('input_required, then the retry carries inputResponses and the echoed requestState', () async {
      final handler = ScriptedHandler(onElicit: (r, ctx) => const McpElicitResult.accept({'name': 'Ada'}));
      h = Harness(options: fastOptions.copyWith(inputHandler: handler));
      final seen = <DartToolContext>[];
      h.add('srv', [_askTool(seen: seen)]);
      await h.names('s1');
      final r = await h.call('s1', 'srv__ask');
      expect(textOf(r), 'hello Ada (state-1)');
      expect(seen, hasLength(2));
      expect(seen.first.inputResponses, isNull);
      expect(seen.last.inputResponses?['who'], {
        'action': 'accept',
        'content': {'name': 'Ada'},
      });
      expect(seen.last.clientCapabilities['elicitation'], isNotNull, reason: 'declared per request');
      expect(handler.elicitations.single.message, 'Your name?');
    });

    test('the input context names the chat and tool behind the call (McpCallOrigin)', () async {
      final handler = ScriptedHandler(onElicit: (r, ctx) => const McpElicitResult.accept({'name': 'Grace'}));
      h = Harness(options: fastOptions.copyWith(inputHandler: handler));
      h.add('srv', [_askTool()]);
      await h.names('chat-7');
      await h.call('chat-7', 'srv__ask');
      final origin = handler.contexts.single.origin;
      expect(origin?.sessionId, 'chat-7');
      expect(origin?.toolName, 'srv__ask');
      expect(origin?.fromApp, isFalse);
      expect(handler.contexts.single.originName, 'ask');

      // A call from the server's app view is attributed to the app.
      final viaApp = await h.router.executeForApp(serverId: 'srv', toolName: 'ask', context: h.ctx('chat-8'));
      expect(textOf(viaApp), startsWith('hello Grace'));
      expect(handler.contexts.last.origin?.sessionId, 'chat-8');
      expect(handler.contexts.last.origin?.fromApp, isTrue);
      expect(McpCallOrigin.current, isNull, reason: 'the zone value does not leak');
    });

    test('appTool returns the cached tool of any visibility without listing', () async {
      h = Harness();
      h.add('srv', [
        tool('view_only', meta: const {
          'ui': {
            'visibility': ['app'],
          },
        }),
        tool('plain'),
      ]);
      expect(h.router.appTool('srv', 'view_only'), isNull, reason: 'not listed yet');
      await h.names('s');
      expect(h.router.appTool('srv', 'view_only')?.uiVisibility, ['app']);
      expect(h.router.appTool('srv', 'plain')?.appCallable, isTrue);
      expect(h.router.appTool('srv', 'missing'), isNull);
    });
  });

  group('legacy era', () {
    late FakeMcpServer server;
    McpConnection? conn;
    setUp(() async {
      server = await FakeMcpServer.start();
      server.modern = false;
    });
    tearDown(() async {
      await conn?.close();
      await server.close();
    });

    test('a server → client request inherits the origin of the request it relates to', () async {
      server.toolImpls['echo'] = (c) async {
        final r = await c.request('elicitation/create', {
          'message': 'Name?',
          'requestedSchema': {'type': 'object', 'properties': <String, Object?>{}},
        });
        return {
          'content': [
            {'type': 'text', 'text': '${(r! as Map)['action']}'},
          ],
        };
      };
      final handler = ScriptedHandler(onElicit: (r, ctx) => const McpElicitResult.decline());
      conn = await McpConnection.connect(serverConfig(server.url), options: options(handler: handler));
      final r = await McpCallOrigin.run(
        const McpCallOrigin(sessionId: 'legacy-chat', toolName: 'srv__echo'),
        () => conn!.callTool('echo'),
      );
      expect((r.content.single as McpTextContent).text, 'decline');
      final ctx = handler.contexts.single;
      expect(ctx.era, McpEra.legacy);
      expect(ctx.origin?.sessionId, 'legacy-chat');
      expect(ctx.origin?.toolName, 'srv__echo');
    });
  });

  test('McpClientOptions.copyWith keeps everything else', () {
    final h = ScriptedHandler();
    const base = McpClientOptions(logLevel: McpLogLevel.info, legacyListCacheTtl: Duration(seconds: 3));
    final o = base.copyWith(capabilities: const McpClientCapabilities(sampling: true, mcpApps: true), inputHandler: h);
    expect(o.logLevel, McpLogLevel.info);
    expect(o.legacyListCacheTtl, const Duration(seconds: 3));
    expect(o.capabilities.sampling, isTrue);
    expect(o.inputHandler, same(h));
    final caps = o.capabilities.copyWith(sampling: false);
    expect(caps.mcpApps, isTrue);
    expect(caps.toJson(era: McpEra.modern, hasHandler: true).containsKey('sampling'), isFalse);
  });
}
