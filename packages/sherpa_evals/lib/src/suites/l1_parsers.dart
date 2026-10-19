/// L1 — parser conformance corpus (R11 §9.9): golden raw outputs per
/// model family and parser path, well-formed and malformed, each with the
/// call a correct harness must execute or the reason it must not.
library;

import 'dart:convert';
import 'dart:math';

import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_inference/engine.dart';
import 'package:sherpa_net/sherpa_net.dart';
import 'package:sherpa_providers/sherpa_providers.dart';

import '../data.dart';
import '../report.dart';
import '../runtime/models.dart';
import 'suite.dart';

/// What a parser produced for one raw output, and what the agent loop
/// would do with it.
final class ParseObservation {
  ParseObservation({
    required this.calls,
    required this.finish,
    required this.text,
    this.streamError,
    this.notices = const [],
  });

  /// Every completed call, valid or not.
  final List<ToolCall> calls;
  final FinishReason? finish;
  final String text;
  final String? streamError;
  final List<String> notices;

  /// The calls `AgentRunner` would execute: valid arguments, a known tool
  /// name, and a turn that neither hit the output limit nor was refused.
  List<ToolCall> executable(Set<String> tools) {
    if (streamError != null) return const [];
    if (finish == FinishReason.length || finish == FinishReason.refusal) return const [];
    return [for (final c in calls) if (c.isValid && tools.contains(c.name)) c];
  }

  /// A stable fingerprint (chunk-split stability).
  String signature() => jsonEncode({
        'calls': [for (final c in calls) {'n': c.name, 'a': c.arguments, 'e': c.argumentsError != null, 'r': c.repaired}],
        'finish': finish?.name,
        'text': text,
        'error': streamError != null,
      });
}

/// Runs one corpus case through its real parser, with the SSE text fed in
/// the given [chunks].
Future<ParseObservation> observe(Map<String, Object?> c, {List<String>? chunks}) async {
  final path = c['path']! as String;
  final tools = [...(c['tools']! as List).cast<String>()];
  final events = <ModelEvent>[];
  String? error;
  try {
    switch (path) {
      case 'openai_chat':
        final parser = ChatStreamParser(
          names: ToolNameMapper(tools),
          quirks: ServerQuirks.of(_profile(c['profile'] as String?)),
          newCallId: (i) => 'gen_$i',
        );
        await for (final e in _sse(c, chunks)) {
          events.addAll(parser.addEvent(e));
        }
        events.addAll(parser.finish());
      case 'responses':
        final parser = ResponsesStreamParser(names: ToolNameMapper(tools), newCallId: (i) => 'gen_$i');
        await for (final e in _sse(c, chunks)) {
          events.addAll(parser.addEvent(e));
        }
        events.addAll(parser.finish());
      case 'anthropic':
        final decoder = AnthropicStreamDecoder(providerId: 'anthropic', toolNames: AnthropicToolNames(tools));
        try {
          await for (final e in _sse(c, chunks)) {
            events.addAll(decoder.add(e));
          }
          events.addAll(decoder.close());
        } on AnthropicStreamFailure catch (f) {
          events.addAll(f.before);
          throw f.error;
        }
      case 'engine':
        final mapper = EngineEventMapper(providerId: 'llama_cpp');
        for (final raw in objectList(c['events'])) {
          events.addAll(mapper.map(_engineEvent(raw)));
        }
      default:
        throw ArgumentError.value(path, 'path', 'unknown parser path');
    }
  } on ProviderException catch (e) {
    error = '${e.kind.name}: ${e.message}';
  }
  return ParseObservation(
    calls: [for (final e in events.whereType<ToolCallComplete>()) e.call],
    finish: events.whereType<Finish>().lastOrNull?.reason,
    text: events.whereType<TextDelta>().map((e) => e.text).join(),
    streamError: error,
    notices: [for (final e in events.whereType<ProviderNotice>()) e.code],
  );
}

ServerProfile _profile(String? name) => switch (name) {
      null || 'proxy' || 'proxy_no_id' => ServerProfile.generic,
      _ => ServerProfile.values.byName(name),
    };

Stream<SseEvent> _sse(Map<String, Object?> c, List<String>? chunks) =>
    Stream<String>.fromIterable(chunks ?? [c['sse']! as String]).transform(const SseTextDecoder());

EngineEvent _engineEvent(Map<String, Object?> j) {
  final type = EngineEventType.values.byName(j['type']! as String);
  final finish = switch (j['finish']) {
    'stop' => SeFinish.stop,
    'length' => SeFinish.length,
    'toolCalls' => SeFinish.toolCalls,
    'cancelled' => SeFinish.cancelled,
    'error' => SeFinish.error,
    _ => 0,
  };
  return EngineEvent(
    type: type,
    index: (j['index'] as int?) ?? -1,
    code: type == EngineEventType.finish ? finish : ((j['code'] as int?) ?? 0),
    text: (j['text'] as String?) ?? '',
    id: (j['id'] as String?) ?? '',
    name: (j['name'] as String?) ?? '',
    promptTokens: (j['promptTokens'] as int?) ?? 0,
    cachedTokens: (j['cachedTokens'] as int?) ?? 0,
    completionTokens: (j['completionTokens'] as int?) ?? 0,
    ttftMs: (j['ttftMs'] as num?)?.toDouble() ?? 0,
    prefillTps: (j['prefillTps'] as num?)?.toDouble() ?? 0,
    decodeTps: (j['decodeTps'] as num?)?.toDouble() ?? 0,
  );
}

/// The case's verdict against its expectation.
final class CaseVerdict {
  CaseVerdict({required this.pass, required this.detail, required this.executedWrongly, required this.unflaggedRepair});

  final bool pass;
  final String detail;

  /// Something executed that should not have (false repair / acceptance),
  /// or something other than the expected call executed.
  final bool executedWrongly;

  /// The expected call was recovered by repair but not marked `repaired`
  /// (the approval policy then skips its one-off confirmation).
  final bool unflaggedRepair;
}

/// Scores [obs] against the case's `expect`.
CaseVerdict score(Map<String, Object?> c, ParseObservation obs) {
  final expect = (c['expect']! as Map).cast<String, Object?>();
  final tools = {...(c['tools']! as List).cast<String>()};
  final exec = obs.executable(tools);
  final outcome = expect['outcome']! as String;
  String describe(List<ToolCall> calls) =>
      calls.isEmpty ? 'nothing' : calls.map((x) => '${x.name}(${jsonEncode(x.arguments)})${x.repaired ? '[repaired]' : ''}').join(', ');
  switch (outcome) {
    case 'calls':
      final want = objectList(expect['calls']);
      var ok = exec.length == want.length && obs.calls.length == want.length;
      var unflagged = false;
      for (var i = 0; ok && i < want.length; i++) {
        final w = want[i];
        ok = exec[i].name == w['name'] && _deepEquals(exec[i].arguments, w['arguments']);
        final rep = w['repaired'] as bool?;
        if (ok && rep != null && exec[i].repaired != rep) {
          ok = false;
          if (rep) unflagged = true;
        }
      }
      final wrong = !ok && exec.isNotEmpty && !unflagged;
      return CaseVerdict(
        pass: ok,
        detail: ok
            ? 'executes ${describe(exec)}'
            : 'expected ${want.map((w) => '${w['name']}(${jsonEncode(w['arguments'])})${w['repaired'] == true ? '[repaired]' : ''}').join(', ')}; '
                'would execute ${describe(exec)}${obs.streamError == null ? '' : ' (stream error: ${obs.streamError})'}'
                '${exec.length < obs.calls.length ? '; surfaced as invalid: ${[for (final x in obs.calls) if (!exec.contains(x)) '${x.name}: ${x.argumentsError ?? 'unknown tool'}'].join('; ')}' : ''}',
        executedWrongly: wrong,
        unflaggedRepair: unflagged,
      );
    case 'blocked':
      final ok = exec.isEmpty && obs.streamError == null;
      return CaseVerdict(
        pass: ok,
        detail: ok
            ? 'nothing executes (${obs.calls.isEmpty ? 'no call' : obs.calls.map((x) => x.argumentsError ?? 'turn ${obs.finish?.name}').join('; ')})'
            : exec.isNotEmpty
                ? 'must not execute, but would execute ${describe(exec)}'
                : 'unexpected stream error: ${obs.streamError}',
        executedWrongly: exec.isNotEmpty,
        unflaggedRepair: false,
      );
    case 'text':
      final contains = expect['contains'] as String? ?? '';
      final ok = obs.calls.isEmpty && obs.streamError == null && obs.text.contains(contains);
      return CaseVerdict(
        pass: ok,
        detail: ok ? 'text only' : 'expected text containing "$contains", got ${describe(obs.calls)} / "${_clip(obs.text)}"',
        executedWrongly: exec.isNotEmpty,
        unflaggedRepair: false,
      );
    case 'stream_error':
      final ok = obs.streamError != null && exec.isEmpty;
      return CaseVerdict(
        pass: ok,
        detail: ok ? 'stream error: ${obs.streamError}' : 'expected a stream error, got ${describe(exec)} / finish ${obs.finish?.name}',
        executedWrongly: exec.isNotEmpty,
        unflaggedRepair: false,
      );
    default:
      throw ArgumentError.value(outcome, 'outcome');
  }
}

String _clip(String s) => s.length > 60 ? '${s.substring(0, 59)}…' : s;

bool _deepEquals(Object? a, Object? b) {
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final k in a.keys) {
      if (!b.containsKey(k) || !_deepEquals(a[k], b[k])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_deepEquals(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is num && b is num) return a == b;
  return a == b;
}

/// Chunkings every SSE case is fed in: whole, fixed 17-char pieces, and
/// seeded random splits (results must not depend on network chunking).
List<List<String>> chunkings(String text, int seed) {
  final fixed = [for (var i = 0; i < text.length; i += 17) text.substring(i, min(text.length, i + 17))];
  final rnd = Random(seed);
  final random = <String>[];
  var i = 0;
  while (i < text.length) {
    final n = 1 + rnd.nextInt(40);
    random.add(text.substring(i, min(text.length, i + n)));
    i += n;
  }
  return [
    [text],
    fixed,
    random,
  ];
}

final class L1ParserSuite implements EvalSuite {
  const L1ParserSuite();

  @override
  String get id => 'L1';

  @override
  String get title => 'Parser conformance corpus';

  @override
  bool supports(ModelSpec model) => true;

  @override
  Future<SuiteReport> run(EvalContext ctx) async {
    final corpus = loadData('l1/corpus.json');
    final all = objectList(corpus['cases']);
    final cases = ctx.select(all, (c) => c['id']! as String);
    final report = SuiteReport(suite: id, title: title, model: 'parsers (model-independent)', casePolicy: CasePolicy.baseline);
    if (!ctx.scripted) report.notes.add('L1 replays recorded outputs; the --model argument does not change it.');

    final byOutcome = <String, List<bool>>{};
    final groupStats = <String, _Stats>{};
    var unstable = 0;
    var unflagged = 0;
    var silentRenames = 0;
    final all_ = _Stats();
    for (final c in cases) {
      final cid = c['id']! as String;
      final path = c['path']! as String;
      ParseObservation obs;
      var stable = true;
      if (c['sse'] != null) {
        final variants = [
          for (final chunks in chunkings(c['sse']! as String, cid.hashCode & 0xffff)) await observe(c, chunks: chunks),
        ];
        obs = variants.first;
        stable = variants.every((v) => v.signature() == obs.signature());
      } else {
        obs = await observe(c);
      }
      final v = score(c, obs);
      final pass = v.pass && stable;
      if (!stable) unstable++;
      if (v.unflaggedRepair) unflagged++;
      final expect = (c['expect']! as Map).cast<String, Object?>();
      final outcome = expect['outcome']! as String;
      final wantRepair = outcome == 'calls' && objectList(expect['calls']).any((w) => w['repaired'] == true);
      final wantClean = outcome == 'calls' && objectList(expect['calls']).every((w) => w['repaired'] == false);
      final tools = {...(c['tools']! as List).cast<String>()};
      for (final x in obs.executable(tools)) {
        if (!_wireNames(c).contains(x.name)) silentRenames++;
      }
      (byOutcome[outcome] ??= []).add(pass);
      final group = path == 'openai_chat' ? 'openai_chat.${c['profile']}' : path;
      for (final s in [all_, groupStats.putIfAbsent(group, _Stats.new)]) {
        s.add(outcome: outcome, pass: pass, wrong: v.executedWrongly, wantRepair: wantRepair, wantClean: wantClean);
      }
      report.cases.add(CaseResult(
        id: cid,
        pass: pass,
        group: group,
        detail: stable ? v.detail : '${v.detail}; result depends on SSE chunking',
        data: {'variant': c['variant'], 'family': c['family'], 'why': c['why']},
      ));
    }

    report.metrics.addAll([
      Metric.ratio('parse_rate', all_.callsPass, all_.calls, better: Better.higher,
          description: 'cases that must yield calls and yield exactly the expected executable calls'),
      Metric.ratio('clean_parse_rate', all_.cleanPass, all_.clean, better: Better.higher,
          description: 'well-formed outputs parsed exactly (no repair flag)'),
      Metric.ratio('repair_rate', all_.repairPass, all_.repair, better: Better.higher,
          description: 'malformed-but-recoverable outputs recovered and flagged repaired'),
      Metric.ratio('false_repair_rate', all_.falseRepairs, all_.noCall, better: Better.lower,
          description: 'outputs that must not execute (truncated, ambiguous, refused, text, broken stream) that would'),
      Metric.ratio('wrong_call_rate', all_.wrongCalls, all_.calls, better: Better.lower,
          description: 'cases where a call other than the expected one would execute'),
      Metric.ratio('block_rate', all_.noCallPass, all_.noCall, better: Better.higher,
          description: 'outputs that must not execute and do not'),
      Metric('unflagged_repairs', unflagged.toDouble(), better: Better.lower, unit: 'count',
          description: 'recovered calls not marked repaired (skip the one-off confirmation of R11 9.6.7)'),
      Metric('silent_name_corrections', silentRenames.toDouble(), unit: 'count',
          description: 'executable calls whose name differs from the wire name with no flag on the call'),
      Metric('chunking_instability', unstable.toDouble(), better: Better.equal, unit: 'count', max: 0,
          description: 'cases whose result changes with SSE chunk boundaries'),
      Metric.ratio('pass_rate', report.cases.where((c) => c.pass).length, report.cases.length, better: Better.higher),
      Metric('cases', cases.length.toDouble(), unit: 'count'),
    ]);
    for (final e in groupStats.entries) {
      final s = e.value;
      report.metrics.addAll([
        Metric.ratio('parse_rate', s.callsPass, s.calls, group: e.key, better: Better.higher),
        Metric.ratio('repair_rate', s.repairPass, s.repair, group: e.key, better: Better.higher, whenEmpty: 1),
        Metric.ratio('false_repair_rate', s.falseRepairs, s.noCall, group: e.key, better: Better.lower),
        Metric('cases', s.total.toDouble(), group: e.key, unit: 'count'),
      ]);
    }
    report.extra['outcomes'] = {
      for (final e in byOutcome.entries) e.key: {'cases': e.value.length, 'pass': e.value.where((x) => x).length},
    };
    return report;
  }

  /// Names as they appear on the wire in a case (for rename accounting).
  static Set<String> _wireNames(Map<String, Object?> c) {
    final names = <String>{};
    final sse = c['sse'] as String?;
    if (sse != null) {
      for (final m in RegExp(r'"name":\s*"([^"]*)"').allMatches(sse)) {
        names.add(m[1]!);
      }
    }
    for (final e in objectList(c['events'])) {
      if (e['name'] is String) names.add(e['name']! as String);
    }
    return names;
  }
}

final class _Stats {
  int total = 0;
  int calls = 0;
  int callsPass = 0;
  int clean = 0;
  int cleanPass = 0;
  int repair = 0;
  int repairPass = 0;
  int noCall = 0;
  int noCallPass = 0;
  int falseRepairs = 0;
  int wrongCalls = 0;

  void add({required String outcome, required bool pass, required bool wrong, required bool wantRepair, required bool wantClean}) {
    total++;
    if (outcome == 'calls') {
      calls++;
      if (pass) callsPass++;
      if (wrong) wrongCalls++;
      if (wantRepair) {
        repair++;
        if (pass) repairPass++;
      }
      if (wantClean) {
        clean++;
        if (pass) cleanPass++;
      }
    } else {
      noCall++;
      if (pass) noCallPass++;
      if (wrong) falseRepairs++;
    }
  }
}
