import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_providers/src/anthropic/anthropic.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// In-process tool that records its calls.
final class RecordingTool implements LocalTool {
  RecordingTool(this.name, this.output, {this.delay = Duration.zero});

  final String name;
  final String output;
  final Duration delay;
  final List<Map<String, Object?>> calls = [];

  @override
  ToolDefinition get definition => ToolDefinition(
        name: name,
        description: 'Test tool $name.',
        inputSchema: const {'type': 'object', 'properties': {}},
        annotations: const ToolAnnotations(readOnlyHint: true, openWorldHint: false),
      );

  @override
  Future<ToolResult> run(Map<String, Object?> arguments, ToolExecutionContext context) async {
    calls.add(arguments);
    await Future<void>.delayed(delay);
    return ToolResult.text(output);
  }
}

/// AgentRunner + AnthropicProvider over a scripted HTTP client: every
/// `POST /v1/messages` answers with the next fixture and records the body.
final class Harness {
  Harness(List<String> fixtures, {List<LocalTool> tools = const [], String model = 'claude-opus-5-5'})
      : _script = [...fixtures] {
    final client = MockClient.streaming((request, body) async {
      final text = await utf8.decodeStream(body);
      if (request.method == 'GET') {
        // No models endpoint: the provider falls back to its family table.
        return http.StreamedResponse(
          Stream.value(utf8.encode('{"type":"error","error":{"type":"not_found_error","message":"n/a"}}')),
          404,
          headers: {'content-type': 'application/json'},
        );
      }
      bodies.add((jsonDecode(text) as Map).cast<String, Object?>());
      final sse = _script.removeAt(0);
      return http.StreamedResponse(
        Stream.fromIterable([for (final e in sse.split('\n\n')) if (e.trim().isNotEmpty) utf8.encode('$e\n\n')]),
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    });
    provider = AnthropicProvider(
      config: testConfig(baseUrl: Uri.parse('http://127.0.0.1:9')),
      apiKey: 'sk-ant-test',
      client: client,
      clock: clock,
    );
    runner = AgentRunner(
      store: store,
      provider: provider,
      modelId: model,
      tools: LocalToolRouter(tools),
      approvals: ApprovalPolicy(clock: clock),
      approvalHandler: const StaticApprovalHandler.approveAll(),
      clock: clock,
      ids: SequentialIdGenerator(),
      sleep: (_) async {},
    );
  }

  final List<String> _script;
  final List<JsonMap> bodies = [];
  final store = InMemorySessionStore();
  final clock = FakeClock(DateTime.utc(2026, 10, 18));
  late final AnthropicProvider provider;
  late final AgentRunner runner;
  final List<AgentEvent> events = [];

  Future<RunFinished> send(String text) async {
    await store.getSession('s1') ??
        await store.putSession(SessionRecord(
          id: 's1',
          title: defaultSessionTitle,
          createdAt: clock.now(),
          updatedAt: clock.now(),
        ));
    final run = await runner.send('s1', [TextPart(text)]).toList();
    events.addAll(run);
    return run.whereType<RunFinished>().single;
  }

  List<Object?> messages(int request) => stripCache(bodies[request]['messages'])! as List<Object?>;

  Iterable<String> get noticeCodes => events
      .whereType<ModelStreamed>()
      .map((e) => e.event)
      .whereType<ProviderNotice>()
      .map((n) => n.code);
}

/// Asserts that [next] starts with every turn of [prev], byte for byte.
void expectAppendOnly(Harness h, int prev, int next) {
  final a = h.messages(prev);
  final b = h.messages(next);
  expect(b.length, greaterThan(a.length));
  for (var i = 0; i < a.length; i++) {
    expect(jsonEncode(b[i]), jsonEncode(a[i]), reason: 'request $next changed turn $i of request $prev');
  }
  expect(jsonEncode(h.bodies[next]['system']), jsonEncode(h.bodies[prev]['system']));
  expect(jsonEncode(h.bodies[next]['tools']), jsonEncode(h.bodies[prev]['tools']));
}

void main() {
  test('F4 through AgentRunner: thinking replayed verbatim, results grouped, prefixes byte-identical', () async {
    final weather = RecordingTool('get_weather', '18°C, cloudy', delay: const Duration(milliseconds: 30));
    final time = RecordingTool('get_time', '21:04 JST');
    final h = Harness(
      [fixture('parallel_tool_use'), fixture('text'), fixture('thinking_signature')],
      tools: [weather, time],
    );
    expect((await h.send('Weather in Paris and the time in Tokyo?')).outcome, RunOutcome.completed);
    expect(weather.calls, [
      {'city': 'Paris'},
    ]);
    expect(time.calls, [
      {'timezone': 'Asia/Tokyo'},
    ]);
    await h.send('Thanks!');
    expect(h.bodies, hasLength(3));

    expect(h.messages(1)[1], {
      'role': 'assistant',
      'content': [
        {
          'type': 'thinking',
          'thinking': 'Two independent lookups: Paris weather and Tokyo time. Both can run in parallel.',
          'signature': 'EqQBCgIYAhIM1gbcDa9GJwZA2b3hGgxBdjrkzLoky3dl1pkiMOYds',
        },
        {'type': 'text', 'text': 'Checking both now.'},
        {
          'type': 'tool_use',
          'id': 'toolu_01AbCdEf',
          'name': 'get_weather',
          'input': {'city': 'Paris'},
        },
        {
          'type': 'tool_use',
          'id': 'toolu_01GhIjKl',
          'name': 'get_time',
          'input': {'timezone': 'Asia/Tokyo'},
        },
      ],
    });
    expect(h.messages(1)[2], {
      'role': 'user',
      'content': [
        {'type': 'tool_result', 'tool_use_id': 'toolu_01AbCdEf', 'content': '18°C, cloudy'},
        {'type': 'tool_result', 'tool_use_id': 'toolu_01GhIjKl', 'content': '21:04 JST'},
      ],
    });
    expect(h.messages(2).sublist(3), [
      {
        'role': 'assistant',
        'content': [
          {'type': 'text', 'text': 'Hello from Tōkyō, 18°C 日本'},
        ],
      },
      {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': 'Thanks!'},
        ],
      },
    ]);
    expectAppendOnly(h, 0, 1);
    expectAppendOnly(h, 1, 2);
    // The cache tail moves forward with the conversation.
    expect(cachePaths(h.bodies[2]['messages']), [r'$[4].content[0]']);
    expect(h.noticeCodes, isNot(contains('anthropic.prefix_changed')));
    // Anthropic sessions are append-only for the context manager.
    expect((await h.provider.capabilities('claude-opus-5-5')).historyPolicy, HistoryPolicy.appendOnly);
  });

  test('interleaved progress-update thinking + sanitized tool names survive the runner round trip', () async {
    final read = RecordingTool('fs/read', '# Sherpa');
    final list = RecordingTool('fs/list', 'README.md');
    final h = Harness([fixture('interleaved'), fixture('text')], tools: [read, list]);
    await h.send('Summarize the repo');
    expect(read.calls, [
      {'path': 'README.md'},
    ]);
    expect(list.calls, [
      {'dir': '.'},
    ]);
    expect(h.bodies[0]['tools'], [
      {
        'name': 'fs_read',
        'description': 'Test tool fs/read.',
        'input_schema': {'type': 'object', 'properties': <String, Object?>{}},
      },
      {
        'name': 'fs_list',
        'description': 'Test tool fs/list.',
        'input_schema': {'type': 'object', 'properties': <String, Object?>{}},
        'cache_control': {'type': 'ephemeral'},
      },
    ]);
    expect(h.messages(1)[1], {
      'role': 'assistant',
      'content': [
        {'type': 'thinking', 'thinking': 'Plan: read the file, then list the folder.', 'signature': 'SIG_A'},
        {'type': 'text', 'text': 'Let me look.'},
        {'type': 'thinking', 'thinking': 'Reading README first.', 'signature': 'SIG_B'},
        {
          'type': 'tool_use',
          'id': 'toolu_01Read',
          'name': 'fs_read',
          'input': {'path': 'README.md'},
        },
        {'type': 'thinking', 'thinking': 'Then the folder listing.', 'signature': 'SIG_C'},
        {
          'type': 'tool_use',
          'id': 'toolu_01List',
          'name': 'fs_list',
          'input': {'dir': '.'},
        },
      ],
    });
    expectAppendOnly(h, 0, 1);
  });

  test('redacted thinking followed by thinking stays two blocks after the runner accumulates them', () async {
    final h = Harness([fixture('redacted_thinking'), fixture('text')], model: 'claude-opus-4-6');
    await h.send('one');
    await h.send('two');
    expect((h.messages(1)[1]! as Map)['content'], [
      {'type': 'redacted_thinking', 'data': 'EmwKAhgBEgy3va3pzix/LafPsn4aDFIT2Xlxh0L5L8rLVyIwxtE3rAFBa8cr3qpP'},
      {'type': 'thinking', 'thinking': 'Visible part of the reasoning.', 'signature': 'SIG_AFTER_REDACTED'},
      {'type': 'text', 'text': 'Done.'},
    ]);
    expectAppendOnly(h, 0, 1);
  });

  test('refusal: the turn\'s tool never runs and the refused turn is not replayed', () async {
    final shell = RecordingTool('shell', 'should not run');
    final h = Harness([fixture('refusal'), fixture('text')], tools: [shell]);
    await h.send('scan the network');
    expect(shell.calls, isEmpty);
    final path = await h.store.path('s1', (await h.store.getSession('s1'))!.activeLeafId!);
    expect(path.last.finishReason, FinishReason.refusal.name);
    expect(path.last.hasToolCalls, isFalse);
    expect(h.noticeCodes, contains('anthropic.refusal'));

    await h.send('ok, something else');
    expect(h.messages(1), [
      {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': 'scan the network'},
          {'type': 'text', 'text': 'ok, something else'},
        ],
      },
    ]);
  });

  test('stop mid-stream: Finish(cancelled) reaches the runner and the run ends cancelled', () async {
    final gate = Completer<void>();
    final sse = fixture('thinking_signature');
    final parts = [for (final e in sse.split('\n\n')) if (e.trim().isNotEmpty) '$e\n\n'];
    final client = MockClient.streaming((request, body) async {
      await body.drain<void>();
      if (request.method == 'GET') return http.StreamedResponse(const Stream.empty(), 404);
      final out = StreamController<List<int>>();
      for (final p in parts.take(3)) {
        out.add(utf8.encode(p));
      }
      unawaited(gate.future.then((_) => out.close()));
      return http.StreamedResponse(out.stream, 200, headers: {'content-type': 'text/event-stream'});
    });
    final store = InMemorySessionStore();
    final clock = FakeClock();
    final runner = AgentRunner(
      store: store,
      provider: AnthropicProvider(config: testConfig(baseUrl: Uri.parse('http://127.0.0.1:9')), client: client, clock: clock),
      modelId: 'claude-opus-5-5',
      tools: LocalToolRouter(const []),
      approvals: ApprovalPolicy(clock: clock),
      approvalHandler: const StaticApprovalHandler.approveAll(),
      clock: clock,
      ids: SequentialIdGenerator(),
      sleep: (_) async {},
    );
    await store.putSession(SessionRecord(id: 's1', title: 't', createdAt: clock.now(), updatedAt: clock.now()));
    final events = <AgentEvent>[];
    final done = Completer<void>();
    runner.send('s1', [const TextPart('go')]).listen(events.add, onDone: done.complete);
    await eventually(() => events.whereType<ModelStreamed>().any((e) => e.event is ReasoningDelta));
    runner.cancel();
    await done.future.timeout(const Duration(seconds: 5));
    gate.complete();
    expect(events.whereType<RunFinished>().single.outcome, RunOutcome.cancelled);
  });
}
