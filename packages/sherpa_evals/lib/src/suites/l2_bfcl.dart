/// L2 — BFCL-style on-device function calling (R11 §9.9): a converted
/// BFCL v4 subset (simple, multiple, parallel, irrelevance) run through
/// Sherpa's own provider adapter (`ModelRequest` → provider → parsed
/// `ToolCallComplete` events) and scored by BFCL's AST checker.
///
/// With `--model scripted` an oracle answers every case with its ground
/// truth, which proves the conversion and the scorer (100% expected); real
/// numbers come from `--model local:<gguf>` on the host (a smoke number)
/// and from a device run (see the package README).
library;

import 'dart:io';

import 'package:sherpa_core/sherpa_core.dart';

import '../data.dart';
import '../report.dart';
import '../runtime/agent.dart';
import '../runtime/models.dart';
import '../stats.dart';
import 'l2_ast.dart';
import 'suite.dart';

const List<String> l2Categories = ['simple', 'multiple', 'parallel', 'irrelevance'];

/// The case's functions as Sherpa tool definitions.
List<ToolDefinition> bfclTools(JsonMap c) => [
      for (final f in objectList(c['functions']))
        ToolDefinition(
          name: f['name']! as String,
          description: (f['description'] as String?) ?? '',
          inputSchema: (f['parameters']! as Map).cast<String, Object?>(),
        ),
    ];

List<Message> _messages(JsonMap c) {
  final at = DateTime.utc(2026, 10, 19);
  return [
    for (final (i, m) in objectList(c['messages']).indexed)
      if (m['role'] != 'system')
        Message(
          id: 'q$i',
          role: m['role'] == 'assistant' ? Role.assistant : Role.user,
          content: [TextPart(m['content']! as String)],
          createdAt: at,
        ),
  ];
}

String? _system(JsonMap c) =>
    objectList(c['messages']).where((m) => m['role'] == 'system').map((m) => m['content']! as String).firstOrNull;

/// What one case produced.
final class BfclObservation {
  BfclObservation({required this.calls, required this.text, this.finish, this.perf, this.usage, this.error});

  final List<ToolCall> calls;
  final String text;
  final FinishReason? finish;
  final PerfSample? perf;
  final Usage? usage;
  final String? error;
}

/// Streams one case through [provider], exactly as the agent loop would
/// send a first turn.
Future<BfclObservation> observeBfcl(JsonMap c, ModelProvider provider, String modelId, GenerationParams params) async {
  final calls = <ToolCall>[];
  final text = StringBuffer();
  FinishReason? finish;
  PerfSample? perf;
  Usage? usage;
  String? error;
  try {
    final request = ModelRequest(
      modelId: modelId,
      systemPrompt: _system(c),
      messages: _messages(c),
      tools: bfclTools(c),
      params: params,
    );
    await for (final e in provider.stream(request)) {
      switch (e) {
        case ToolCallComplete(:final call):
          calls.add(call);
        case TextDelta(text: final t):
          text.write(t);
        case Finish(:final reason):
          finish = reason;
        case PerfSample():
          perf = e;
        case UsageUpdate(usage: final u):
          usage = u;
        default:
          break;
      }
    }
  } on Object catch (e) {
    error = '$e';
  }
  return BfclObservation(calls: calls, text: text.toString(), finish: finish, perf: perf, usage: usage, error: error);
}

/// The scripted oracle: answers with the ground truth (first possible
/// value of each parameter), or plain text for irrelevance cases.
ModelPolicy bfclOracle(Map<String, JsonMap> byQuestion) => (request) {
      final q = lastUserText(request);
      final c = byQuestion[q];
      if (c == null || c['category'] == 'irrelevance') return textEvents('None of the available functions can do that.');
      return toolCallEvents([
        for (final (i, a) in objectList(c['ground_truth']).indexed)
          () {
            final o = oracleCall(a);
            return ToolCall(id: 'call_$i', name: o.name, arguments: o.arguments);
          }(),
      ]);
    };

/// Runs [cases] against [provider] and scores them; pure (no file access),
/// so a device harness can call it with the subset bundled as a string.
Future<SuiteReport> runBfcl(
  List<JsonMap> cases, {
  required ModelProvider provider,
  required String modelId,
  required String modelLabel,
  required GenerationParams params,
  bool gate = false,
  void Function(String line)? log,
}) async {
  final report = SuiteReport(
    suite: 'L2',
    title: 'BFCL-style function calling',
    model: modelLabel,
    casePolicy: gate ? CasePolicy.all : CasePolicy.none,
  );
  final byCategory = <String, List<bool>>{};
  var calls = 0;
  var valid = 0;
  var repaired = 0;
  var invalidArgs = 0;
  var turnsWithCalls = 0;
  var needCalls = 0;
  final ttft = <double>[];
  final decode = <double>[];
  final prefill = <double>[];
  final outTokens = <int>[];
  final sw = Stopwatch()..start();
  for (final c in cases) {
    final id = c['id']! as String;
    final category = c['category']! as String;
    final obs = await observeBfcl(c, provider, modelId, params);
    final tools = {for (final t in bfclTools(c)) t.name: t};
    final asCalls = <AstCall>[
      for (final x in obs.calls)
        if (x.isValid) (name: x.name, arguments: x.arguments),
    ];
    for (final x in obs.calls) {
      calls++;
      if (x.repaired) repaired++;
      if (!x.isValid) invalidArgs++;
      final schema = tools[x.name]?.inputSchema;
      if (x.isValid && schema != null && !SchemaCheck.validate(schema, x.arguments).any((i) => i.fatal)) valid++;
    }
    if (category != 'irrelevance') {
      needCalls++;
      if (obs.calls.isNotEmpty) turnsWithCalls++;
    }
    final verdict = obs.error != null
        ? AstVerdict.fail('stream error: ${obs.error}')
        : checkCase(category, objectList(c['functions']), asCalls, objectList(c['ground_truth']));
    (byCategory[category] ??= []).add(verdict.valid);
    if (obs.perf?.timeToFirstTokenMs case final t?) ttft.add(t);
    if (obs.perf?.decodeTokensPerSec case final t? when t > 0) decode.add(t);
    if (obs.perf?.prefillTokensPerSec case final t? when t > 0) prefill.add(t);
    if (obs.usage?.outputTokens case final n?) outTokens.add(n);
    log?.call('  $id: ${verdict.valid ? 'pass' : 'FAIL ${verdict.error}'}');
    report.cases.add(CaseResult(
      id: id,
      group: category,
      pass: verdict.valid,
      detail: verdict.valid ? 'AST match' : verdict.error,
      data: {
        'calls': [for (final x in obs.calls) {'name': x.name, 'arguments': x.arguments, if (x.repaired) 'repaired': true, if (!x.isValid) 'error': x.argumentsError}],
        if (obs.calls.isEmpty && obs.text.isNotEmpty) 'text': obs.text.length > 160 ? '${obs.text.substring(0, 159)}…' : obs.text,
        'finish': obs.finish?.name,
      },
    ));
  }
  double acc(String cat) {
    final xs = byCategory[cat] ?? const [];
    return xs.isEmpty ? double.nan : xs.where((x) => x).length / xs.length;
  }

  final callCats = ['simple', 'multiple', 'parallel'].where(byCategory.containsKey).toList();
  final ast = [for (final cat in callCats) ...byCategory[cat]!];
  final present = l2Categories.where(byCategory.containsKey).toList();
  report.metrics.addAll([
    Metric('overall_accuracy', present.isEmpty ? 0 : mean([for (final c in present) acc(c)]), unit: 'ratio', better: Better.higher,
        min: gate ? 1 : null, description: 'unweighted mean of the category accuracies (BFCL non-live style)'),
    Metric.ratio('ast_accuracy', ast.where((x) => x).length, ast.length, better: Better.higher, min: gate ? 1 : null,
        description: 'simple + multiple + parallel cases whose calls pass the AST checker'),
    if (byCategory.containsKey('irrelevance'))
      Metric('irrelevance_accuracy', acc('irrelevance'), unit: 'ratio', better: Better.higher, min: gate ? 1 : null,
          description: 'cases where no function fits and none was called'),
    Metric.ratio('schema_valid_rate', valid, calls, better: Better.higher, whenEmpty: 1, min: gate ? 1 : null,
        description: 'calls whose arguments validate against the offered schema'),
    Metric.ratio('tool_call_rate', turnsWithCalls, needCalls, better: Better.higher, whenEmpty: 1,
        description: 'cases that need a call and produced at least one (tool-call grammar/parser triggered)'),
    Metric('repairs_per_100_calls', calls == 0 ? 0 : 100 * repaired / calls, better: Better.lower),
    Metric('invalid_argument_calls', invalidArgs.toDouble(), unit: 'count', better: Better.lower),
    Metric('cases', cases.length.toDouble(), unit: 'count'),
    if (ttft.isNotEmpty) ...[
      Metric('ttft_ms_median', median(ttft), unit: 'ms'),
      Metric('prefill_tps_median', median(prefill), unit: 't/s'),
      Metric('decode_tps_median', median(decode), unit: 't/s'),
      Metric('output_tokens_mean', mean(outTokens), unit: 'tokens'),
      Metric('peak_rss_mb', ProcessInfo.maxRss / (1 << 20), unit: 'MB', description: 'host process peak RSS (engine in-process)'),
      Metric('seconds_per_case', sw.elapsedMilliseconds / 1000 / cases.length, unit: 's'),
    ],
  ]);
  for (final cat in present) {
    report.metrics.add(Metric('accuracy', acc(cat), unit: 'ratio', group: cat, better: Better.higher));
  }
  return report;
}

final class L2BfclSuite implements EvalSuite {
  const L2BfclSuite();

  @override
  String get id => 'L2';

  @override
  String get title => 'BFCL-style function calling';

  @override
  bool supports(ModelSpec model) => true;

  @override
  Future<SuiteReport> run(EvalContext ctx) async {
    final data = loadData('l2/bfcl_subset.json');
    final cases = ctx.select(objectList(data['cases']), (c) => c['id']! as String);
    final ModelProvider provider;
    final String modelId;
    final GenerationParams params;
    final rt = ctx.runtime;
    if (rt == null) {
      final byQuestion = {for (final c in cases) objectList(c['messages']).last['content']! as String: c};
      provider = policyProvider(bfclOracle(byQuestion), maxTurns: cases.length + 1);
      modelId = 'scripted';
      params = const GenerationParams();
    } else {
      provider = rt.provider;
      modelId = rt.modelId;
      // BFCL runs greedy; parallel cases need room for several calls.
      params = const GenerationParams(temperature: 0, seed: 42, maxOutputTokens: 384, reasoning: ReasoningEffort.off);
    }
    final report = await runBfcl(
      cases,
      provider: provider,
      modelId: modelId,
      modelLabel: ctx.scripted ? 'scripted oracle (scorer self-check)' : ctx.model.label,
      params: params,
      gate: ctx.scripted,
      log: ctx.scripted ? null : ctx.log,
    );
    report.notes.add('Subset of ${data['source']}');
    if (ctx.scripted) {
      report.notes.add('The oracle answers with the ground truth: 100% proves the conversion and the AST checker, not a model.');
    } else {
      report.notes.add('Host smoke number on the shared CPU; real L2 numbers are per device (README: "L2 on a device").');
    }
    return report;
  }
}
