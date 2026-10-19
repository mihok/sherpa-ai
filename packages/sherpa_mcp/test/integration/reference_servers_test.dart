/// Conformance against the official reference servers, run under Node:
///
/// * `@modelcontextprotocol/server-everything@1.0.0` (TS SDK v1.32.1) in
///   `streamableHttp` mode — the stateful 2025-11-25 era — and in `sse`
///   mode (2024-11-05 HTTP+SSE);
/// * `test/integration/servers/modern_server.mjs` on
///   `@modelcontextprotocol/server@2.3.1` serving 2026-07-28 (strict
///   modern-only, and dual-era with the SDK's stateless legacy fallback).
///
/// Install the packages with `tool/install_test_servers.sh`; without them
/// (or without node) these tests skip.
library;

import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_mcp/sherpa_mcp.dart';
import 'package:test/test.dart';

import '../support/helpers.dart';
import 'node_server.dart';

const _everything = 'everything/node_modules/@modelcontextprotocol/server-everything/dist/index.js';
const _modernPkg = 'modern/node_modules/@modelcontextprotocol/server/package.json';

String _text(McpCallToolResult r) => [for (final c in r.content) if (c is McpTextContent) c.text].join('\n');

void main() {
  final everythingSkip = skipUnless([_everything]);
  final modernSkip = skipUnless([_modernPkg]);

  group('server-everything 1.0.0, Streamable HTTP (legacy era)', skip: everythingSkip, () {
    late NodeServer srv;
    late McpConnection c;
    late ScriptedHandler handler;

    setUpAll(() async {
      srv = await NodeServer.start(
        cwd: '$serversRoot/everything',
        script: 'node_modules/@modelcontextprotocol/server-everything/dist/index.js',
        args: ['streamableHttp'],
        ready: RegExp('listening on port'),
      );
    });
    tearDownAll(() => srv.stop());

    setUp(() async {
      handler = ScriptedHandler(
        onElicit: (r, _) => r.mode == McpElicitMode.url
            ? const McpElicitResult.accept()
            : const McpElicitResult.accept({'name': 'Ada Lovelace', 'check': true}),
        onSample: (r, _) => McpSamplingResult(
          content: [McpTextContent('echo: ${(r.messages.first.content.first as McpTextContent).text}')],
          model: 'sherpa-local-test',
          stopReason: 'endTurn',
        ),
      );
      c = await McpConnection.connect(
        serverConfig(srv.url('/mcp')),
        options: options(handler: handler, capabilities: const McpClientCapabilities(sampling: true)),
      );
    });
    tearDown(() => c.close());

    Future<List<McpTool>> toolsIncluding(String name) async {
      // Conditional tools are registered after `initialized` (list_changed).
      for (var i = 0; i < 50; i++) {
        final tools = await c.listTools(refresh: true);
        if (tools.any((t) => t.name == name)) return tools;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      fail('tool $name never appeared');
    }

    test('era detection: 400 -32000 from TS v1 → initialize at 2025-11-25 with a session', () {
      expect(c.era, McpEra.legacy);
      expect(c.transportKind, McpTransportKind.legacyStreamableHttp);
      expect(c.protocolVersion, '2025-11-25');
      expect(c.serverInfo?.name, 'mcp-servers/everything');
      expect(c.capabilities.resourcesSubscribe, isTrue);
      expect(c.capabilities.logging, isTrue);
      expect(c.instructions, isNotEmpty);
      expect(c.probeLog.first, contains('-32000'));
    });

    test('tools: list (incl. capability-gated ones), echo, sum, structured content, image, links', () async {
      final tools = await toolsIncluding('trigger-sampling-request');
      final names = {for (final t in tools) t.name};
      expect(names, containsAll(['echo', 'get-sum', 'trigger-long-running-operation', 'trigger-elicitation-request']));
      expect(names, isNot(contains('get-roots-list')), reason: 'roots not declared');
      final longOp = tools.firstWhere((t) => t.name == 'trigger-long-running-operation');
      expect(longOp.annotations.isReadOnly, isTrue);
      expect(longOp.annotations.isIdempotent, isTrue);

      expect(_text(await c.callTool('echo', arguments: {'message': 'hello'})), 'Echo: hello');
      expect(_text(await c.callTool('get-sum', arguments: {'a': 2, 'b': 3})), contains('5'));
      final structured = await c.callTool('get-structured-content', arguments: {'location': 'New York'});
      expect(structured.structuredContent, isA<Map<String, Object?>>());
      final image = await c.callTool('get-tiny-image');
      expect(image.content.whereType<McpImageContent>().single.bytes, isNotEmpty);
      final links = await c.callTool('get-resource-links', arguments: {'count': 2});
      expect(links.content.whereType<McpResourceLink>(), hasLength(2));
    });

    test('progress notifications from trigger-long-running-operation', () async {
      final progress = <ToolProgress>[];
      final r = await c.callTool('trigger-long-running-operation',
          arguments: {'duration': 1, 'steps': 4}, onProgress: progress.add);
      expect(_text(r), contains('completed'));
      expect([for (final p in progress) p.progress], [1, 2, 3, 4]);
      expect(progress.last.fraction, 1);
    });

    test('sampling round-trip (server → client request on the POST stream)', () async {
      await toolsIncluding('trigger-sampling-request');
      final r = await c.callTool('trigger-sampling-request', arguments: {'prompt': 'capital of France?', 'maxTokens': 20});
      expect(_text(r), contains('sherpa-local-test'));
      expect(handler.samplings.single.maxTokens, 20);
      expect(handler.samplings.single.systemPrompt, isNotEmpty);
      expect(handler.contexts.last.originName, 'trigger-sampling-request');
    });

    test('form elicitation round-trip', () async {
      await toolsIncluding('trigger-elicitation-request');
      final r = await c.callTool('trigger-elicitation-request');
      expect(_text(r), contains('Ada Lovelace'));
      final req = handler.elicitations.single;
      expect(req.mode, McpElicitMode.form);
      expect((req.requestedSchema!['required']! as List), contains('name'));
    });

    test('URL elicitation: request path and the -32042 error path', () async {
      await toolsIncluding('trigger-url-elicitation');
      final ok = await c.callTool('trigger-url-elicitation',
          arguments: {'url': 'https://example.com/authorize', 'message': 'Authorize Sherpa'});
      expect(_text(ok), isNotEmpty);
      expect(handler.elicitations.last.url, Uri.parse('https://example.com/authorize'));
      expect(handler.elicitations.last.elicitationId, isNotNull);

      final viaError = await c.callTool('trigger-url-elicitation',
          arguments: {'url': 'https://example.com/second', 'message': 'Authorize', 'errorPath': true});
      expect(viaError.isError, isFalse);
      final urls = [for (final e in handler.elicitations) e.url.toString()];
      expect(urls, containsAllInOrder(['https://modelcontextprotocol.io', 'https://example.com/second']));
    });

    test('resources: list, templates, read, subscribe → updated over the GET stream', () async {
      final resources = await c.listResources();
      expect(resources, isNotEmpty);
      final templates = await c.listResourceTemplates();
      expect(templates.map((t) => t.uriTemplate), contains(startsWith('demo://resource/dynamic/text')));
      final read = await c.readResource(resources.first.uri);
      expect(read.contents, isNotEmpty);
      final dynamicText = await c.readResource('demo://resource/dynamic/text/1');
      expect(dynamicText.contents.single, isA<McpTextResourceContents>());

      final events = <McpChange>[];
      final sub = c.changes.listen(events.add);
      final s = await c.subscribeResource(resources.first.uri);
      expect(c.isListening, isTrue);
      await c.callTool('toggle-subscriber-updates');
      await eventually(() => events.whereType<McpResourceUpdated>().any((e) => e.uri == resources.first.uri),
          timeout: const Duration(seconds: 10));
      await c.callTool('toggle-subscriber-updates');
      await s.cancel();
      await sub.cancel();
    });

    test('prompts and completion (with context)', () async {
      final prompts = await c.listPrompts();
      expect(prompts.map((p) => p.name), containsAll(['simple-prompt', 'args-prompt', 'completable-prompt']));
      final simple = await c.getPrompt('simple-prompt');
      expect(simple.messages, isNotEmpty);
      final args = await c.getPrompt('args-prompt', arguments: {'city': 'Paris', 'state': 'TX'});
      expect((args.messages.first.content as McpTextContent).text, contains('Paris'));
      final dept = await c.complete(const McpPromptRef('completable-prompt'), argument: 'department', value: 'E');
      expect(dept.values, ['Engineering']);
      final name = await c.complete(const McpPromptRef('completable-prompt'),
          argument: 'name', value: 'A', context: {'department': 'Engineering'});
      expect(name.values, ['Alice']);
    });

    test('logging/setLevel and simulated log messages', () async {
      final logs = <McpLogMessage>[];
      final sub = c.logs.listen(logs.add);
      await c.setLogLevel(McpLogLevel.debug);
      await c.listen();
      await c.callTool('toggle-simulated-logging');
      await eventually(() => logs.isNotEmpty, timeout: const Duration(seconds: 12));
      await c.callTool('toggle-simulated-logging');
      await sub.cancel();
      expect(logs.first.data, isA<String>());
    });

    test('cancellation sends notifications/cancelled; close() DELETEs the session', () async {
      final token = CancellationToken();
      final call = c.callTool('trigger-long-running-operation', arguments: {'duration': 5, 'steps': 5}, cancel: token);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final sw = Stopwatch()..start();
      token.cancel('stop');
      await expectLater(call, throwsA(isA<CancelledException>()));
      expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
      final before = srv.output.length;
      await c.close();
      await eventually(() => srv.output.skip(before).any((l) => l.contains('session termination')));
    });
  });

  group('server-everything 1.0.0, HTTP+SSE (2024-11-05)', skip: everythingSkip, () {
    late NodeServer srv;
    setUpAll(() async {
      srv = await NodeServer.start(
        cwd: '$serversRoot/everything',
        script: 'node_modules/@modelcontextprotocol/server-everything/dist/index.js',
        args: ['sse'],
        ready: RegExp('listening on port|running on port', caseSensitive: false),
      );
    });
    tearDownAll(() => srv.stop());

    test('falls back to GET + endpoint event and works end to end', () async {
      final handler = ScriptedHandler(onElicit: (r, _) => const McpElicitResult.accept({'name': 'Grace'}));
      final c = await McpConnection.connect(serverConfig(srv.url('/sse')), options: options(handler: handler));
      try {
        expect(c.transportKind, McpTransportKind.legacySse);
        expect(c.era, McpEra.legacy);
        expect(c.probeLog.join(' '), contains('HTTP+SSE'));
        expect(_text(await c.callTool('echo', arguments: {'message': 'over sse'})), 'Echo: over sse');
        final progress = <ToolProgress>[];
        await c.callTool('trigger-long-running-operation',
            arguments: {'duration': 0.4, 'steps': 2}, onProgress: progress.add);
        expect(progress, hasLength(2));
        for (var i = 0; i < 50 && !(await c.listTools(refresh: true)).any((t) => t.name == 'trigger-elicitation-request'); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(_text(await c.callTool('trigger-elicitation-request')), contains('Grace'));
      } finally {
        await c.close();
      }
    });
  });

  group('TS SDK v2 server, 2026-07-28 (modern era)', skip: modernSkip, () {
    late NodeServer strict;
    late NodeServer dual;
    late McpConnection c;
    late ScriptedHandler handler;

    Future<NodeServer> startModern(String legacy) {
      // Node resolves imports next to the script, so it runs beside node_modules.
      final target = File('$serversRoot/modern/modern_server.mjs');
      File('test/integration/servers/modern_server.mjs').copySync(target.path);
      return NodeServer.start(
        cwd: '$serversRoot/modern',
        script: 'modern_server.mjs',
        env: {'LEGACY': legacy},
        ready: RegExp(r'^listening \d+'),
      );
    }

    setUpAll(() async {
      strict = await startModern('reject');
      dual = await startModern('stateless');
    });
    tearDownAll(() async {
      await strict.stop();
      await dual.stop();
    });

    setUp(() async {
      handler = ScriptedHandler(
        onElicit: (r, _) => const McpElicitResult.accept({'confirm': true}),
        onSample: (r, _) => const McpSamplingResult(content: [McpTextContent('Paris')], model: 'sherpa-test'),
      );
      c = await McpConnection.connect(
        serverConfig(strict.url('/mcp')),
        options: options(
            handler: handler, capabilities: const McpClientCapabilities(sampling: true), logLevel: McpLogLevel.info),
      );
    });
    tearDown(() => c.close());

    test('server/discover: modern, no initialize, caching hints honoured', () async {
      expect(c.era, McpEra.modern);
      expect(c.transportKind, McpTransportKind.modernHttp);
      expect(c.protocolVersion, '2026-07-28');
      expect(c.serverInfo?.name, 'sherpa-modern-test');
      expect(c.instructions, 'Modern conformance server.');
      expect(c.capabilities.completions, isTrue);
      expect(c.probeLog, ['server/discover: modern 2026-07-28']);
      final d = await c.discover(refresh: true);
      expect(d.protocolVersion, '2026-07-28');
    });

    test('tools: list, call, x-mcp-header mirrored into Mcp-Param-Region (SDK validates)', () async {
      final tools = await c.listTools();
      expect(tools.map((t) => t.name), containsAll(['echo', 'weather', 'confirm', 'ask-model', 'progress', 'slow']));
      expect(c.rejectedTools, isEmpty);
      final weather = tools.firstWhere((t) => t.name == 'weather');
      expect(weather.headerParams.single.headerName, 'Region');
      expect(_text(await c.callTool('echo', arguments: {'message': 'hi'})), 'Echo: hi');
      final w = await c.callTool('weather', arguments: {'region': 'Zürich'});
      expect(_text(w), 'Sunny in Zürich');
      expect(w.structuredContent, {'region': 'Zürich', 'temp': 21});
    });

    test('MRTR elicitation: accept and decline', () async {
      final ok = await c.callTool('confirm', arguments: {'action': 'deploy'});
      expect(_text(ok), 'confirmed deploy (state round-1)');
      expect(handler.elicitations.single.message, 'Really deploy?');
      handler.onElicit = (r, _) => const McpElicitResult.decline();
      expect(_text(await c.callTool('confirm', arguments: {'action': 'delete'})), 'decline delete');
    });

    test('MRTR sampling', () async {
      final r = await c.callTool('ask-model', arguments: {'question': 'Capital of France?'});
      expect(_text(r), 'model sherpa-test said: Paris');
      expect(handler.samplings.single.maxTokens, 64);
    });

    test('progress over the request SSE stream, per-request log level', () async {
      final progress = <ToolProgress>[];
      final logs = <McpLogMessage>[];
      final sub = c.logs.listen(logs.add);
      final r = await c.callTool('progress', arguments: {'steps': 3}, onProgress: progress.add);
      expect(_text(r), 'did 3 steps');
      expect([for (final p in progress) p.progress], [1, 2, 3]);
      await eventually(() => logs.isNotEmpty);
      await sub.cancel();
      expect(logs.single.data, 'finished 3 steps');
      expect(logs.single.level, McpLogLevel.info);
    });

    test('cancellation closes the stream and the server handler observes the abort', () async {
      final token = CancellationToken();
      final call = c.callTool('slow', cancel: token);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      token.cancel();
      await expectLater(call, throwsA(isA<CancelledException>()));
      final client = http.Client();
      try {
        for (var i = 0; i < 50; i++) {
          final n = int.parse((await client.get(strict.url('/control/cancelled'))).body);
          if (n > 0) return;
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        fail('server never saw the cancellation');
      } finally {
        client.close();
      }
    });

    test('resources, prompts, completion', () async {
      expect((await c.listResources()).single.uri, 'file:///config.json');
      final r = await c.readResource('file:///config.json');
      expect((r.contents.single as McpTextResourceContents).text, '{"v":1}');
      await expectLater(c.readResource('file:///nope'),
          throwsA(isA<McpRpcException>().having((e) => e.isResourceNotFound, 'not found', true)));
      final p = await c.getPrompt('greet', arguments: {'who': 'Ada'});
      expect((p.messages.single.content as McpTextContent).text, 'Hello Ada');
      expect((await c.complete(const McpPromptRef('greet'), argument: 'who', value: 'b')).values, ['bob']);
    });

    test('subscriptions/listen: ack, tools list_changed, resource updated', () async {
      final events = <McpChange>[];
      final sub = c.changes.listen(events.add);
      final ack = await c.listen();
      expect(ack.toolsListChanged, isTrue);
      final client = http.Client();
      try {
        await client.get(strict.url('/control/tools-changed'));
        await eventually(() => events.whereType<McpToolsListChanged>().isNotEmpty);
        await c.subscribeResource('file:///config.json');
        await client.get(strict.url('/control/resource-updated'));
        await eventually(() => events.whereType<McpResourceUpdated>().any((e) => e.uri == 'file:///config.json'));
      } finally {
        client.close();
        await sub.cancel();
        await c.stopListening();
      }
    });

    test('a dual-era server is still detected as modern; strict server rejects initialize', () async {
      final d = await McpConnection.connect(serverConfig(dual.url('/mcp')), options: options());
      expect(d.era, McpEra.modern);
      await d.close();
      await expectLater(
        McpConnection.connect(serverConfig(strict.url('/mcp'), transport: McpTransportPreference.legacyStreamableHttp),
            options: options()),
        throwsA(isA<McpEraNegotiationException>()),
      );
    });

    test('a forced legacy connection works against the SDK stateless fallback', () async {
      final l = await McpConnection.connect(
          serverConfig(dual.url('/mcp'), transport: McpTransportPreference.legacyStreamableHttp),
          options: options());
      try {
        expect(l.era, McpEra.legacy);
        expect(_text(await l.callTool('echo', arguments: {'message': 'old'})), 'Echo: old');
      } finally {
        await l.close();
      }
    });
  });
}
