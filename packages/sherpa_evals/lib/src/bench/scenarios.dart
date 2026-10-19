/// The host benchmark scenarios (`dart run sherpa_evals:bench`).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_markdown/parse.dart';
import 'package:sherpa_mcp/sherpa_mcp.dart';
import 'package:sherpa_net/sherpa_net.dart';

import '../runtime/conv.dart';
import '../runtime/mcp_env.dart';
import '../runtime/models.dart';
import '../stats.dart';
import 'bench.dart';

/// All scenarios, in run order.
List<BenchScenario> allBenchScenarios() => [
      MarkdownStreamBench(),
      ContextPrepareBench(),
      SseDecodeBench(),
      RouterToolsForTurnBench(),
      HandoffBench(),
      EngineBench(),
    ];

/// A ~4K-token assistant reply with every block kind the renderer handles.
String benchMarkdown({int sections = 12}) {
  final b = StringBuffer();
  for (var i = 0; i < sections; i++) {
    b
      ..writeln('## Section $i: what changed and why')
      ..writeln()
      ..writeln('The **context ladder** prunes stale tool output first, then compacts at a legal cut point '
          '(`keepRecentUserTurns = 3`), and only then truncates. See [the design notes](https://example.org/notes/$i) '
          'and *R11 §9.2* for the thresholds; inline math like \$r = n / W\$ stays inline.')
      ..writeln()
      ..writeln('- Elide results older than two user turns')
      ..writeln('- Clear large tool inputs, keeping `argsDigest`')
      ..writeln('  - nested: keep the pairing invariant')
      ..writeln('1. Compact with the extractive strategy')
      ..writeln('2. Recommend a handoff above **92%**')
      ..writeln()
      ..writeln('```dart')
      ..writeln('final prepared = await manager.prepare(ContextRequest(')
      ..writeln("  sessionId: 's$i',")
      ..writeln('  path: path,')
      ..writeln('  tools: tools,')
      ..writeln('));')
      ..writeln('print(prepared.budget.ratio);')
      ..writeln('```')
      ..writeln()
      ..writeln('| stage | trigger | effect |')
      ..writeln('|---|---:|---|')
      ..writeln('| prune | 0.60 | stub old results |')
      ..writeln('| compact | 0.80 | rolling summary |')
      ..writeln('| handoff | 0.92 | new session |')
      ..writeln()
      ..writeln('> Note: summaries never nest; constraints are carried forward by code, not by the model.')
      ..writeln();
  }
  return b.toString();
}

/// Streaming markdown parse: the reply arrives in ~4-character tokens and
/// the parser re-parses after each one (what the chat bubble does).
final class MarkdownStreamBench extends BenchScenario {
  late final String _doc;
  late final List<int> _cuts;

  @override
  String get id => 'markdown_stream';

  @override
  String get description => 'IncrementalMarkdownParser.update per streamed token over a ~4K-token reply';

  @override
  Future<void> setUp() async {
    _doc = benchMarkdown();
    final rnd = Random(7);
    final cuts = <int>[];
    for (var i = 0; i < _doc.length;) {
      i = min(_doc.length, i + 1 + rnd.nextInt(7)); // 1–7 chars, ~4 on average
      cuts.add(i);
    }
    _cuts = cuts;
  }

  @override
  Future<Map<String, BenchValue>> sample() async {
    final parser = IncrementalMarkdownParser();
    final us = <double>[];
    final sw = Stopwatch();
    final total = Stopwatch()..start();
    for (final c in _cuts) {
      sw
        ..reset()
        ..start();
      parser.update(_doc.substring(0, c));
      us.add(sw.elapsedTicks * 1e6 / sw.frequency);
    }
    parser.update(_doc, complete: true);
    total.stop();
    return {
      'tokens_per_s': BenchValue(_cuts.length / (total.elapsedMicroseconds / 1e6), unit: 'tokens/s', better: BenchBetter.higher),
      'p50_us_per_token': BenchValue(percentile(us, 0.5), unit: 'us'),
      'p90_us_per_token': BenchValue(percentile(us, 0.9), unit: 'us'),
      'p99_us_per_token': BenchValue(percentile(us, 0.99), unit: 'us'),
    };
  }
}

const List<ToolDefinition> _benchTools = [
  ToolDefinition(
    name: 'read_file',
    description: 'Read a file',
    inputSchema: {'type': 'object', 'properties': {'path': {'type': 'string'}}},
    annotations: ToolAnnotations(readOnlyHint: true, openWorldHint: false),
  ),
  ToolDefinition(
    name: 'write_file',
    description: 'Write a file',
    inputSchema: {'type': 'object', 'properties': {'path': {'type': 'string'}, 'content': {'type': 'string'}}},
    annotations: ToolAnnotations(destructiveHint: true),
  ),
];

/// A 200-message session: 50 turns of user → read call → result → reply,
/// with a large result every fourth turn (elision candidates) and a
/// constraint every tenth.
List<Message> benchSession({int turns = 50}) {
  final c = Conv();
  for (var t = 0; t < turns; t++) {
    c
      ..user('Turn $t: look at module $t.${t % 10 == 0 ? ' You must never touch legacy_$t.py.' : ''}')
      ..toolTurn('r$t', 'read_file', {'path': '/proj/src/module_$t.py'}, filler(t % 4 == 0 ? 220 : 12, prefix: 'code $t'))
      ..assistant('Module $t reviewed: ${'it looks fine and the tests pass. ' * 3}');
  }
  return c.messages;
}

/// `LadderContextManager.prepare` on a 200-message session: cold (the
/// ladder elides and compacts) and steady (overlays already persisted, the
/// per-turn cost).
final class ContextPrepareBench extends BenchScenario {
  late final List<Message> _path;

  @override
  String get id => 'context_prepare_200';

  @override
  String get description => 'LadderContextManager.prepare on a 200-message session (16K window)';

  @override
  Future<void> setUp() async => _path = benchSession();

  ContextRequest _request(List<ContextOverlay> overlays) =>
      contextRequest(_path, overlays: overlays, window: 16384, tools: _benchTools, counter: HeuristicTokenCounter());

  @override
  Future<Map<String, BenchValue>> sample() async {
    final manager = LadderContextManager(clock: FakeClock(), random: Random(1));
    var overlays = <ContextOverlay>[];
    final cold = await timeMedianUs(() async {
      final out = await manager.prepare(_request(const []));
      overlays = out.newOverlays;
    }, reps: 3);
    if (overlays.isEmpty) throw StateError('the ladder did nothing: the scenario no longer exercises it');
    final steady = await timeMedianUs(() => manager.prepare(_request(overlays)), reps: 15);
    return {
      'prepare_cold_ms': BenchValue(cold / 1000, unit: 'ms'),
      'prepare_steady_ms': BenchValue(steady / 1000, unit: 'ms'),
    };
  }
}

/// SSE decoding of a long chat-completions stream from network-sized byte
/// chunks (`SseDecoder`, the provider path).
final class SseDecodeBench extends BenchScenario {
  late final List<List<int>> _chunks;
  late final int _bytes;
  late final int _events;

  @override
  String get id => 'sse_decode';

  @override
  String get description => 'SseDecoder over a 20,000-event chat-completions stream in 4 KiB chunks';

  @override
  Future<void> setUp() async {
    final b = StringBuffer();
    const n = 20000;
    for (var i = 0; i < n; i++) {
      b
        ..write('data: ')
        ..write(jsonEncode({
          'id': 'chatcmpl-1',
          'object': 'chat.completion.chunk',
          'choices': [
            {'index': 0, 'delta': {'content': 'token $i '}, 'finish_reason': null},
          ],
        }))
        ..write('\n\n');
    }
    b.write('data: [DONE]\n\n');
    final bytes = utf8.encode(b.toString());
    _bytes = bytes.length;
    _events = n + 1;
    _chunks = [for (var i = 0; i < bytes.length; i += 4096) bytes.sublist(i, min(bytes.length, i + 4096))];
  }

  @override
  Future<Map<String, BenchValue>> sample() async {
    final us = await timeMedianUs(() async {
      final got = await Stream<List<int>>.fromIterable(_chunks).transform(const SseDecoder()).length;
      if (got != _events) throw StateError('decoded $got events, expected $_events');
    });
    final s = us / 1e6;
    return {
      'events_per_s': BenchValue(_events / s, unit: 'events/s', better: BenchBetter.higher),
      'mb_per_s': BenchValue(_bytes / s / (1 << 20), unit: 'MiB/s', better: BenchBetter.higher),
    };
  }
}

const List<String> _domains = ['crm', 'mail', 'calendar', 'files', 'tickets', 'billing', 'docs', 'chat', 'maps', 'music'];
const List<String> _verbs = ['create', 'get', 'list', 'update', 'delete', 'search', 'archive', 'export', 'share', 'tag'];
const List<String> _nouns = ['item', 'record'];

/// `McpToolRouter.toolsForTurn` with 200 tools on 10 in-process servers:
/// the session goes deferred (core set + `tool_search`/`call_tool`), and a
/// new segment ranks the turn's query with BM25.
final class RouterToolsForTurnBench extends BenchScenario {
  late McpEnv _env;
  int _session = 0;
  static const List<String> _queries = [
    'create a new ticket for the login bug',
    'search my mail for the invoice',
    'share the quarterly report document',
    'list calendar events tomorrow',
    'export billing records as csv',
  ];

  @override
  String get id => 'router_tools_for_turn_200';

  @override
  String get description => 'McpToolRouter.toolsForTurn, 200 tools in deferred mode (new segment per call)';

  @override
  Future<void> setUp() async {
    _env = McpEnv(maxCatalogAge: const Duration(hours: 1));
    for (final d in _domains) {
      _env.add(
        d,
        DartMcpServer(
          info: McpImplementation(name: d, version: '1'),
          tools: [
            for (final v in _verbs)
              for (final n in _nouns)
                mcpTool(
                  '${v}_${d}_$n',
                  description: '${v[0].toUpperCase()}${v.substring(1)} a $d $n by id or by query; '
                      'returns the $n with its fields, owner and timestamps.',
                  annotations: v == 'get' || v == 'list' || v == 'search' ? Hints.read : Hints.write,
                  properties: {
                    '${n}_id': {'type': 'string', 'description': 'The $n id'},
                    'query': {'type': 'string', 'description': 'Free-text filter'},
                    'limit': {'type': 'integer', 'minimum': 1, 'maximum': 100},
                  },
                  handler: (a, ctx) async => DartToolResult.text('ok'),
                ),
          ],
        ),
      );
    }
    await _env.reviewAll();
    final tools = await _env.router.toolsForTurn(sessionId: 'probe', query: _queries.first, hints: _hints);
    if (_env.router.catalog.length != 200 || !_env.router.isDeferred('probe')) {
      throw StateError('expected 200 tools in deferred mode, got ${_env.router.catalog.length} (${tools.length} offered)');
    }
  }

  static const ToolSelectionHints _hints = ToolSelectionHints(onDevice: true, parameterBillions: 4);

  @override
  Future<Map<String, BenchValue>> sample() async {
    final turn = <double>[];
    for (var i = 0; i < 40; i++) {
      final sid = 's${_session++}';
      final sw = Stopwatch()..start();
      await _env.router.toolsForTurn(sessionId: sid, query: _queries[i % _queries.length], hints: _hints);
      turn.add(sw.elapsedMicroseconds.toDouble());
    }
    final search = <double>[];
    for (var i = 0; i < 40; i++) {
      final sw = Stopwatch()..start();
      final r = await _env.router.execute(
        ToolCall(id: 'q$i', name: McpToolRouter.searchToolName, arguments: {'query': _queries[i % _queries.length]}),
        ToolExecutionContext(sessionId: 's0', cancel: CancellationToken()),
      );
      search.add(sw.elapsedMicroseconds.toDouble());
      if (r.isError) throw StateError('tool_search failed: ${r.content}');
    }
    return {
      'tools_for_turn_ms': BenchValue(median(turn) / 1000, unit: 'ms'),
      'tool_search_ms': BenchValue(median(search) / 1000, unit: 'ms'),
    };
  }

  @override
  Future<void> tearDown() => _env.close();
}

/// Handoff: build a bundle from a 200-message session with one compacted
/// range (extractive), and strictly parse it back.
final class HandoffBench extends BenchScenario {
  late final InMemorySessionStore _store;
  late final String _encoded;
  static const String _sid = 'h';
  static const HandoffSource _source = HandoffSource(
    appVersion: '0.1.0',
    providerKind: 'localLlamaCpp',
    modelId: 'qwen3-0.6b',
    location: ExecutionLocation.onDevice,
  );

  @override
  String get id => 'handoff';

  @override
  String get description => 'HandoffBuilder.build + HandoffBundle.parse, 200-message session with a summary';

  @override
  Future<void> setUp() async {
    _store = InMemorySessionStore();
    final path = benchSession();
    final clock = FakeClock();
    await _store.putSession(SessionRecord(id: _sid, title: 'bench', createdAt: clock.now(), updatedAt: clock.now()));
    for (final m in path) {
      await _store.putMessage(_sid, m);
    }
    await _store.putSession((await _store.getSession(_sid))!.copyWith(activeLeafId: path.last.id));
    final half = path.sublist(0, 100)..add(path[100]);
    final out = await LadderContextManager(clock: clock, random: Random(1)).compactNow(contextRequest(half, tools: _benchTools));
    if (out.overlay == null) throw StateError('no compaction: ${out.skippedReason}');
    await _store.putOverlay(_sid, out.overlay!);
    _encoded = (await _build()).encode();
  }

  Future<HandoffBundle> _build() => HandoffBuilder(store: _store, clock: FakeClock()).build(
        sessionId: _sid,
        source: _source,
        recentUserTurns: 2,
        tools: _benchTools,
      );

  @override
  Future<Map<String, BenchValue>> sample() async {
    final build = await timeMedianUs(_build, reps: 5);
    final parse = await timeMedianUs(() async => HandoffBundle.parse(_encoded), reps: 20);
    return {
      'build_ms': BenchValue(build / 1000, unit: 'ms'),
      'parse_ms': BenchValue(parse / 1000, unit: 'ms'),
      'bundle_kib': BenchValue(utf8.encode(_encoded).length / 1024, unit: 'KiB'),
    };
  }
}

/// The on-device engine on the host: time to first token, prefill and
/// decode speed for a fresh ~300-token prompt and 64 output tokens.
/// Skipped without the engine library or the model.
final class EngineBench extends BenchScenario {
  LocalEngineRuntime? _rt;
  int _n = 0;

  static String get modelPath => Platform.environment['SHERPA_BENCH_MODEL'] ?? '/opt/models/Qwen3-0.6B-Q4_K_M.gguf';

  @override
  String get id => 'engine_qwen3_0_6b';

  @override
  String get description => 'LlamaCppProvider on the host engine: TTFT, prefill and decode (Qwen3-0.6B Q4_K_M)';

  @override
  String? get skipReason {
    if (engineLibraryPath() == null) return 'no engine library (set SHERPA_ENGINE_LIB)';
    if (!File(modelPath).existsSync()) return 'no model at $modelPath (set SHERPA_BENCH_MODEL)';
    return null;
  }

  @override
  Future<void> setUp() async => _rt = await LocalEngineRuntime.open(modelPath, context: 2048, maxOutputTokens: 64);

  @override
  Future<Map<String, BenchValue>> sample() async {
    final rt = _rt!;
    // A distinct first line per sample: no KV prefix reuse between samples.
    final prompt = 'Request ${_n++}: summarize this changelog in one sentence.\n${filler(28, prefix: 'change')}';
    PerfSample? perf;
    await for (final e in rt.provider.stream(ModelRequest(
      modelId: rt.modelId,
      messages: [Message(id: 'u', role: Role.user, content: [TextPart(prompt)], createdAt: DateTime.utc(2026))],
      params: const GenerationParams(temperature: 0, seed: 42, maxOutputTokens: 64, reasoning: ReasoningEffort.off),
    ))) {
      if (e is PerfSample) perf = e;
    }
    final p = perf ?? (throw StateError('no PerfSample from the engine'));
    return {
      'ttft_ms': BenchValue(p.timeToFirstTokenMs ?? double.nan, unit: 'ms'),
      'prefill_tps': BenchValue(p.prefillTokensPerSec ?? double.nan, unit: 't/s', better: BenchBetter.higher),
      'decode_tps': BenchValue(p.decodeTokensPerSec ?? double.nan, unit: 't/s', better: BenchBetter.higher),
    };
  }

  @override
  Future<void> tearDown() async => _rt?.dispose();
}
