/// L4 — compaction fidelity (R11 §9.9): scripted 40–80-turn sessions with
/// planted constraints, preferences, paths, handles and completed side
/// effects, driven through the real `AgentRunner`, `LadderContextManager`
/// and MCP stack. After 0 (control), 1, 2 and 4 forced compactions the
/// suite probes what the model would see next:
///
/// * retention per field: is the planted item still in the model-visible
///   context (summary + kept tail)?
/// * duplicate side effects: a checklist turn whose scripted model redoes
///   every completed action it cannot see as done (a faithful agent with no
///   memory beyond its context); the stateful servers count re-applied
///   effects;
/// * handle probes: act on the oldest note / event, which needs its id;
///   without an id attributable to it in context the model must search;
/// * summary token cost (and summarizer call tokens for model strategies).
library;

import 'dart:convert';

import 'package:sherpa_core/sherpa_core.dart';

import '../data.dart';
import '../report.dart';
import '../runtime/agent.dart';
import '../runtime/conv.dart' show QuarterCounter;
import '../runtime/mcp_env.dart';
import '../runtime/models.dart';
import '../runtime/state_servers.dart';
import '../stats.dart';
import 'suite.dart';

/// Retention fields, in report order.
const List<String> l4Fields = ['constraints', 'preferences', 'paths', 'handles', 'side_effects'];

/// The smallest model window a real-model L4 run accepts (the sessions are
/// sized for it: autoCompact is off, so a smaller window hard-stops).
const int l4MinModelWindow = 16384;

/// Compaction counts the suite forces (0 is the control).
const List<int> l4CompactionCounts = [0, 1, 2, 4];

/// How the session's tools reach the model and how the context manager is
/// wired.
enum L4Variant {
  /// On-device tool budget: the 16 tools exceed it, so the router defers
  /// and every call goes through `call_tool`. Wiring as
  /// `app/lib/bootstrap.dart`: `toolLookup` plus
  /// `ApprovalPolicy.annotationsFor` (trust-aware hints).
  deferred,

  /// Deferred, `toolLookup` only (no trust-aware view: every MCP hint is
  /// untrusted, so declared reads stay in the ledger). The harness must
  /// still never let them push out a completed write.
  deferredLookupOnly,

  /// Remote tool budget (20 tools): direct calls; wiring as the app.
  directApp,

  /// Direct calls, `toolLookup` only.
  directLookupOnly;

  /// Whether `annotationsFor` is wired into the ladder (as the app does).
  bool get trustAware => this == deferred || this == directApp;

  /// Remote tool budget: direct calls.
  bool get direct => this == directApp || this == directLookupOnly;
}

/// Tools that never change state.
const Set<String> l4ReadTools = {
  'files__read_file',
  'files__list_dir',
  'notes__search_notes',
  'notes__get_note',
  'calendar__find_events',
  'calendar__list_events',
};

final class L4Plant {
  L4Plant(this.j)
      : kind = j['kind']! as String,
        turn = j['turn']! as int;

  final JsonMap j;
  final String kind;
  final int turn;

  String s(String k) => j[k]! as String;

  bool get isEffect => const {'note', 'event', 'write', 'append'}.contains(kind);

  /// The model-facing tool and arguments of the planted action.
  (String, JsonMap)? get action => switch (kind) {
        'note' => ('notes__create_note', {'title': s('title'), 'body': s('body')}),
        'event' => ('calendar__create_event', {'title': s('title'), 'date': s('date'), 'time': s('time'), 'duration_min': 60}),
        'write' => ('files__write_file', {'path': s('path'), 'content': s('content')}),
        'append' => ('files__append_file', {'path': s('path'), 'text': s('text')}),
        'read' => ('files__read_file', {'path': s('path')}),
        _ => null,
      };

  /// Values that name this action unambiguously (its key argument).
  List<String> get keys => switch (kind) {
        'note' || 'event' => [s('title')],
        'write' => [s('path')],
        'append' => [s('text')],
        _ => const [],
      };

  /// [keys] plus what a careful reader could match against the user's
  /// request: the first 40 characters of a note body or file content.
  List<String> get needles => [
        ...keys,
        if (kind == 'note') s('body').substring(0, 40),
        if (kind == 'write') s('content').substring(0, 40),
      ];

  String userText() => switch (kind) {
        'constraint' => 'Something to keep in mind from now on: ${s('text')}',
        'preference' => 'By the way: ${s('text')}',
        'note' => 'Create a note titled "${s('title')}" with this text: ${s('body')}',
        'event' => 'Put "${s('title')}" in my calendar on ${s('date')} at ${s('time')}.',
        'write' => 'Save this to ${s('path')}: ${s('content')}',
        'append' => "Add the line '${s('text')}' to ${s('path')}.",
        'read' => 'Read ${s('path')} and give me the gist.',
        _ => throw StateError('unknown plant kind $kind'),
      };

  /// Checklist wording for the duplicate-effect probe.
  String checklistItem() => switch (kind) {
        'note' => 'the note "${s('title')}" exists',
        'event' => '"${s('title')}" is in the calendar on ${s('date')} at ${s('time')}',
        'write' => '${s('path')} is saved',
        'append' => "'${s('text')}' is in ${s('path')}",
        _ => '',
      };
}

final class L4Session {
  L4Session(JsonMap j)
      : id = j['id']! as String,
        turns = j['turns']! as int,
        plants = [for (final p in objectList(j['plants'])) L4Plant(p)];

  final String id;
  final int turns;
  final List<L4Plant> plants;

  L4Plant? at(int turn) => plants.where((p) => p.turn == turn).firstOrNull;

  List<L4Plant> get effects => [for (final p in plants) if (p.isEffect) p];

  static String fillerPath(int turn) => '/home/ana/archive/doc_$turn.txt';

  String userText(int turn) => '#$turn ${at(turn)?.userText() ?? 'What does ${fillerPath(turn)} say?'}';

  /// The call id of turn [turn]'s action.
  static String callId(int turn) => 't${turn}c0';

  (String, JsonMap) action(int turn) => at(turn)?.action ?? ('files__read_file', {'path': fillerPath(turn)});

  /// The servers' initial state: every document the session reads, and
  /// the files it appends to.
  void seed(World w) {
    for (var t = 1; t <= turns; t++) {
      if (at(t) == null) {
        w.files[fillerPath(t)] = [
          for (var i = 0; i < 24; i++) 'Archive document $t, line $i: household paperwork, receipts and notes (ref A$t-$i).',
        ].join('\n');
      }
    }
    for (final p in plants) {
      if (p.kind == 'read') {
        w.files[p.s('path')] = [for (var i = 0; i < 30; i++) '${p.s('path')} section $i: terms, dates and amounts.'].join('\n');
      }
      if (p.kind == 'append') w.files.putIfAbsent(p.s('path'), () => '# ${p.s('path').split('/').last}\n');
    }
  }

  /// The turns before which compaction is forced for [n] compactions,
  /// evenly spread (never the first turn).
  List<int> compactBefore(int n) => [for (var i = 1; i <= n; i++) 2 + ((turns - 2) * i / (n + 1)).round()];
}

/// Everything a model request shows, one string per message (texts,
/// tool-call arguments, tool results), plus the system prompt.
List<String> visibleTexts(ModelRequest r) => [
      r.systemPrompt ?? '',
      for (final m in r.messages)
        [
          for (final p in m.content)
            switch (p) {
              TextPart(:final text) => text,
              ToolCallPart(:final call) => '${call.name} ${jsonEncode(call.arguments)}',
              ToolResultPart() => p.text,
              _ => '',
            },
        ].join('\n'),
    ];

String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

bool _visible(List<String> texts, String needle) {
  final n = _norm(needle);
  return texts.any((t) => _norm(t).contains(n));
}

/// [v] as it appears inside JSON (quotes and newlines escaped, no quotes).
String _inJson(String v) {
  final e = jsonEncode(v);
  return e.substring(1, e.length - 1);
}

/// Whether [p]'s action is visible as DONE in [r]: its call and a
/// successful result in the kept transcript, or a summary ledger line
/// ("… → done") with an identifying value. [strict] also requires the
/// line to name the tool and accepts only [L4Plant.keys] (no content
/// matching): what a reader who does not cross-check the earlier user
/// messages could rely on.
bool doneVisible(ModelRequest r, L4Plant p, {bool strict = false}) {
  final (tool, _) = p.action!;
  final ok = <String>{
    for (final m in r.messages)
      for (final res in m.toolResults)
        if (!res.isError) res.callId,
  };
  final values = strict ? p.keys : p.needles;
  for (final m in r.messages) {
    for (final c in m.toolCalls) {
      final proxied = c.name == 'call_tool';
      final target = proxied ? c.arguments['name'] : c.name;
      final args = jsonEncode(proxied ? c.arguments['arguments'] : c.arguments);
      if (target == tool && ok.contains(c.id) && values.any((n) => args.contains(_inJson(n)))) return true;
    }
  }
  for (final m in r.messages) {
    for (final line in m.text.split('\n')) {
      if (!line.contains('→ done')) continue;
      if (strict && !line.contains(tool)) continue;
      if (values.any((n) => line.contains(n) || line.contains(_inJson(n)))) return true;
    }
  }
  return false;
}

/// An id for [title] that the context attributes to it: a JSON object
/// (tool result) with that title and an id of [prefix], or a text line
/// holding both. A bare handle without its title does not count: with
/// several notes the model cannot tell which id is which.
String? attributedHandle(ModelRequest r, String title, String prefix) {
  final id = RegExp('\\b${prefix}_[a-z0-9]{4}\\b');
  String? walk(Object? v) {
    if (v is Map) {
      if (v['title'] == title) {
        for (final e in v.values) {
          if (e is String && id.hasMatch(e)) return e;
        }
      }
      for (final x in v.values) {
        final found = walk(x);
        if (found != null) return found;
      }
    } else if (v is List) {
      for (final x in v) {
        final found = walk(x);
        if (found != null) return found;
      }
    }
    return null;
  }

  for (final t in visibleTexts(r)) {
    for (final line in t.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.startsWith('{')) {
        try {
          final found = walk(jsonDecode(trimmed));
          if (found != null) return found;
          continue;
        } on FormatException {
          // Not JSON: fall through to the line heuristic.
        }
      }
      if (line.contains(title) || line.contains(_inJson(title))) {
        final m = id.allMatches(line).toList();
        if (m.length == 1) return m.single[0];
      }
    }
  }
  return null;
}

/// A provider wrapper that sums the usage of every stream (summarizer cost).
final class MeteredProvider implements ModelProvider {
  MeteredProvider(this.inner);

  final ModelProvider inner;
  int calls = 0;
  Usage usage = Usage.zero;

  @override
  ProviderInfo get info => inner.info;

  @override
  Future<ModelCapabilities> capabilities(String modelId) => inner.capabilities(modelId);

  @override
  Future<List<ModelDescriptor>> listModels() => inner.listModels();

  @override
  Stream<ModelEvent> stream(ModelRequest request, {CancellationToken? cancel}) {
    calls++;
    return inner.stream(request, cancel: cancel).map((e) {
      if (e is UsageUpdate) usage += e.usage;
      return e;
    });
  }
}

/// One session run with [compactions] forced compactions.
final class L4Run {
  L4Run(this.session, this.compactions, this.variant, this.strategy);

  final String session;
  final int compactions;
  final L4Variant variant;
  final String strategy;
  int compacted = 0;
  final List<String> skipped = [];
  final Map<String, (int, int)> retention = {};
  (int, int) strictEffects = (0, 0);
  final List<String> lost = [];
  int effects = 0;
  int duplicated = 0;
  int duplicatedNonIdempotent = 0;
  final List<String> duplicates = [];
  int handleProbes = 0;
  int handleProbesOk = 0;
  int handleLookups = 0;
  final List<int> summaryTokens = [];
  int summarizerCalls = 0;
  Usage summarizerUsage = Usage.zero;
  int usedFallback = 0;
  int ledgerEntries = 0;
  int ledgerReadOnly = 0;
  int ledgerUnnamed = 0;
  int ledgerFolded = 0;
  int effectsEvicted = 0;
  int unhandled = 0;
  final List<String> problems = [];

  String get key => '${variant.name}.$session.c$compactions';

  bool get taskSuccess => duplicated == 0 && handleProbesOk == handleProbes && problems.isEmpty;

  Map<String, Object?> toJson() => {
        'compacted': compacted,
        if (skipped.isNotEmpty) 'skipped': skipped,
        'retention': {for (final e in retention.entries) e.key: '${e.value.$1}/${e.value.$2}'},
        'sideEffectsStrict': '${strictEffects.$1}/${strictEffects.$2}',
        if (lost.isNotEmpty) 'lost': lost,
        'effects': effects,
        'duplicated': duplicated,
        if (duplicates.isNotEmpty) 'duplicates': duplicates,
        'handleProbes': '$handleProbesOk/$handleProbes',
        'handleLookups': handleLookups,
        'summaryTokens': summaryTokens,
        if (summarizerCalls > 0)
          'summarizer': {'calls': summarizerCalls, 'in': summarizerUsage.inputTokens, 'out': summarizerUsage.outputTokens},
        if (usedFallback > 0) 'usedFallback': usedFallback,
        'ledger': {
          'entries': ledgerEntries,
          'readOnly': ledgerReadOnly,
          'unnamedTargets': ledgerUnnamed,
          'foldedCalls': ledgerFolded,
          'effectsEvicted': effectsEvicted,
        },
        if (problems.isNotEmpty) 'problems': problems,
      };
}

const String _l4System = 'You are Sherpa, a household assistant. Use the tools to do what the user asks.';

/// Runs [s] once.
Future<L4Run> runL4Session(
  L4Session s, {
  required int compactions,
  L4Variant variant = L4Variant.deferred,
  ContextStrategy strategy = const ExtractiveContextStrategy(),
  MeteredProvider? summarizer,
  int window = 65536,
  void Function(ModelRequest probe)? onProbe,
}) async {
  final run = L4Run(s.id, compactions, variant, strategy.id);
  final world = World(seed: 40 + s.turns);
  s.seed(world);
  final clock = FakeClock(DateTime.utc(2026, 10, 19, 8));
  final env = McpEnv(clock: clock);
  for (final e in stateServers(world, ['notes', 'calendar', 'files']).entries) {
    env.add(e.key, e.value);
  }
  await env.reviewAll();
  final approvals = ApprovalPolicy(clock: clock, trustedServers: env.trustedServerIds);
  final ladder = LadderContextManager(
    strategy: strategy,
    clock: clock,
    toolLookup: env.router.lookup,
    annotationsFor: variant.trustAware ? approvals.annotationsFor : null,
  );
  // Thresholds out of reach: only the forced compactions happen.
  const settings = ContextSettings(autoCompact: false);
  final caps = ModelCapabilities(contextLength: window);
  final remote = variant.direct;
  final state = _PolicyState();
  final provider = policyProvider(
    (r) => _sessionPolicy(s, r, state),
    capabilities: caps,
    maxTurns: s.turns * 3 + 40,
    info: ProviderInfo(
      id: 'scripted',
      kind: ProviderKind.fake,
      displayName: 'Scripted',
      location: remote ? ExecutionLocation.remote : ExecutionLocation.onDevice,
    ),
  );
  final hints = ToolSelectionHints(onDevice: !remote);
  final store = InMemorySessionStore();
  const sid = 'l4';
  await newSession(store, sid, clock);
  final counter = HeuristicTokenCounter();
  final runner = AgentRunner(
    store: store,
    provider: provider,
    modelId: 'scripted',
    tools: env.router,
    approvals: approvals,
    approvalHandler: ScriptedUser(),
    contextManager: ladder,
    counter: counter,
    clock: clock,
    ids: SequentialIdGenerator(),
    config: const AgentConfig(maxSteps: 6, contextSettings: settings, defaultSystemPrompt: _l4System),
    sleep: (_) async {},
  );

  Future<void> say(String text) async {
    final (events, errors) = await guarded(() => drive(runner.send(sid, [TextPart(text)])));
    run.unhandled += errors.length;
    final fin = finishedOf(events ?? const []);
    if (fin?.outcome != RunOutcome.completed) {
      run.problems.add('"${text.length > 30 ? text.substring(0, 30) : text}…" ended ${fin?.outcome.name}: ${fin?.detail ?? fin?.error}');
    }
    for (final e in errors) {
      run.problems.add('unhandled: $e');
    }
  }

  final compactAt = s.compactBefore(compactions).toSet();
  for (var t = 1; t <= s.turns; t++) {
    if (compactAt.contains(t)) {
      // The request AgentRunner would build for the next call (as the
      // app's "Compact now" does), then the overlay is persisted.
      final session = (await store.getSession(sid))!;
      final req = ContextRequest(
        sessionId: sid,
        path: await store.path(sid, session.activeLeafId!),
        overlays: await store.overlays(sid),
        tools: await env.router.toolsForTurn(sessionId: sid, hints: hints),
        capabilities: caps,
        counter: counter,
        systemPrompt: PromptBoundary.compose(_l4System),
        settings: settings,
        location: provider.info.location,
        boundaryNonce: session.settings.opt<String>('boundaryNonce'),
      );
      final out = await ladder.compactNow(req);
      if (out.overlay == null) {
        run.skipped.add('before #$t: ${out.skippedReason}');
      } else {
        await store.putOverlay(sid, out.overlay!);
        run.compacted++;
        if (out.usedFallback) run.usedFallback++;
        run.summaryTokens.add(const QuarterCounter().countText(out.overlay!.summary.render()));
      }
    }
    await say(s.userText(t));
  }
  if (run.compacted != compactions) run.problems.add('forced $compactions compactions, ${run.compacted} happened');
  final note = s.plants.where((p) => p.kind == 'note').firstOrNull;
  final event = s.plants.where((p) => p.kind == 'event').firstOrNull;
  final noteId = note == null ? null : world.notesTitled(note.s('title')).singleOrNull?.id;
  final eventId = event == null ? null : world.events.values.where((e) => e.title == event.s('title')).singleOrNull?.id;
  final handles = {
    for (final p in s.plants)
      if (p.kind == 'note')
        p: world.notesTitled(p.s('title')).firstOrNull?.id
      else if (p.kind == 'event')
        p: world.events.values.where((e) => e.title == p.s('title')).firstOrNull?.id,
  };

  // Probe 1: the checklist (duplicate side effects); its first request is
  // also the retention probe.
  final effects = s.effects;
  final mark = state.probes.length;
  await say('#P Before we finish, go through this checklist and make sure each item is done, '
      'without redoing anything that is already done: ${[for (final p in effects) p.checklistItem()].join('; ')}.');
  if (state.probes.length > mark) {
    final probe = state.probes[mark];
    _retention(run, s, handles, probe);
    await _ledger(run, s, store, sid, probe);
    onProbe?.call(probe);
  }

  // Probes 2–3: act on the oldest note and event (their handles).
  if (note != null) {
    run.handleProbes++;
    await say('#H1 Append the line "status: reviewed" to my note "${note.s('title')}".');
    final reviewed = [for (final x in world.notes.values) if (x.body.contains('status: reviewed')) x.id];
    if (noteId != null && reviewed.length == 1 && reviewed.single == noteId && world.notes[noteId]!.body.endsWith('status: reviewed')) {
      run.handleProbesOk++;
    } else {
      run.problems.add('note handle probe failed (updated $reviewed, wanted $noteId)');
    }
  }
  if (event != null) {
    run.handleProbes++;
    await say('#H2 Move "${event.s('title')}" to 2026-12-01 at 16:00.');
    final moved = [for (final e in world.events.values) if (e.date == '2026-12-01') e.id];
    if (eventId != null && moved.length == 1 && moved.single == eventId && world.events[eventId]!.time == '16:00') {
      run.handleProbesOk++;
    } else {
      run.problems.add('event handle probe failed (moved $moved, wanted $eventId)');
    }
  }
  run.handleLookups = state.lookups;

  // Duplicates: the same state-changing call applied more than once.
  final counts = <String, int>{};
  for (final e in world.effects) {
    final k = '${e.tool} ${Digest.canonicalJson(e.args)}';
    counts[k] = (counts[k] ?? 0) + 1;
  }
  run.effects = effects.length;
  for (final e in counts.entries.where((e) => e.value > 1)) {
    run.duplicated++;
    // write_file of the same content is idempotent at the server.
    if (!e.key.startsWith('write_file ')) run.duplicatedNonIdempotent++;
    run.duplicates.add('${e.key.length > 90 ? '${e.key.substring(0, 90)}…' : e.key} ×${e.value}');
  }
  if (summarizer != null) {
    run.summarizerCalls = summarizer.calls;
    run.summarizerUsage = summarizer.usage;
  }
  await env.close();
  return run;
}

final class _PolicyState {
  /// The first request of each checklist probe (what the model saw).
  final List<ModelRequest> probes = [];

  /// Handle probes that had to search for the id.
  int lookups = 0;
}

void _retention(L4Run run, L4Session s, Map<L4Plant, String?> handles, ModelRequest r) {
  final texts = visibleTexts(r);
  void count(String field, bool kept, String what) {
    final (k, n) = run.retention[field] ?? (0, 0);
    run.retention[field] = (k + (kept ? 1 : 0), n + 1);
    if (!kept) run.lost.add('$field: $what');
  }

  final paths = <String>{};
  for (final p in s.plants) {
    switch (p.kind) {
      case 'constraint':
        count('constraints', _visible(texts, p.s('text')), p.s('text'));
      case 'preference':
        count('preferences', _visible(texts, p.s('text')), p.s('text'));
      case 'write' || 'append' || 'read':
        if (paths.add(p.s('path'))) count('paths', _visible(texts, p.s('path')), p.s('path'));
      case 'note' || 'event':
        final id = handles[p];
        count('handles', id != null && _visible(texts, id), '${p.kind} id of "${p.s('title')}"');
    }
    if (p.isEffect) {
      count('side_effects', doneVisible(r, p), '${p.kind} ${p.keys.first}');
      final strict = doneVisible(r, p, strict: true);
      run.strictEffects = (run.strictEffects.$1 + (strict ? 1 : 0), run.strictEffects.$2 + 1);
    }
  }
}

/// Ledger diagnostics from the latest summary: read-only calls in it,
/// entries whose rendered line does not name the tool that ran, calls
/// folded into per-tool aggregate lines, and completed effects in neither
/// the ledger nor the kept transcript.
Future<void> _ledger(L4Run run, L4Session s, SessionStore store, String sid, ModelRequest probe) async {
  final ranges = (await store.overlays(sid)).whereType<CompactedRange>().toList();
  if (ranges.isEmpty) return;
  final summary = ranges.reduce((a, b) => a.summary.compactionCount >= b.summary.compactionCount ? a : b).summary;
  final session = (await store.getSession(sid))!;
  final target = <String, String>{
    for (final m in await store.path(sid, session.activeLeafId!))
      for (final c in m.toolCalls) c.id: c.name == 'call_tool' ? '${c.arguments['name']}' : c.name,
  };
  final rendered = summary.render().split('\n');
  final ledgered = <String>{};
  for (final e in summary.sideEffectLedger) {
    ledgered.addAll(e.allCallIds);
    run.ledgerEntries++;
    final tool = target[e.callId] ?? e.tool;
    if (l4ReadTools.contains(tool)) run.ledgerReadOnly += e.count;
    if (e.isAggregate) run.ledgerFolded += e.count;
    final marker = e.isAggregate ? '${e.allCallIds.first} … ${e.allCallIds.last})' : '(call ${e.callId},';
    final line = rendered.firstWhere((l) => l.contains(marker), orElse: () => '');
    if (!line.contains(tool)) run.ledgerUnnamed++;
  }
  final tail = {for (final m in probe.messages) ...m.toolCalls.map((c) => c.id)};
  for (final p in s.effects) {
    final id = L4Session.callId(p.turn);
    if (!ledgered.contains(id) && !tail.contains(id)) run.effectsEvicted++;
  }
}

/// The scripted model of an L4 session: performs each turn's planned call,
/// and in the probes acts only on what its context shows.
List<ModelEvent> _sessionPolicy(L4Session s, ModelRequest r, _PolicyState state) {
  final last = lastUserText(r);
  final tag = RegExp(r'^#(\w+)').firstMatch(last)?[1] ?? '';
  final issued = {for (final c in callsIn(r)) c.id};
  final offered = {for (final x in r.tools) x.name};
  ToolCall call(String id, String tool, JsonMap args) => offered.contains(tool) || !offered.contains('call_tool')
      ? ToolCall(id: id, name: tool, arguments: args)
      : ToolCall(id: id, name: 'call_tool', arguments: {'name': tool, 'arguments': args});

  final turn = int.tryParse(tag);
  if (turn != null) {
    if (issued.contains(L4Session.callId(turn))) return textEvents('Done with #$turn. ${'Noted for later. ' * 3}');
    final (tool, args) = s.action(turn);
    return toolCallEvents([call(L4Session.callId(turn), tool, args)]);
  }
  if (tag == 'P') {
    if (issued.any((id) => id.startsWith('p'))) return textEvents('Checklist reviewed.');
    state.probes.add(r);
    final redo = [
      for (final (i, p) in s.effects.indexed)
        if (!doneVisible(r, p)) call('p$i', p.action!.$1, p.action!.$2),
    ];
    return redo.isEmpty ? textEvents('Everything on the checklist is already done.') : toolCallEvents(redo);
  }
  if (tag == 'H1' || tag == 'H2') {
    final note = tag == 'H1';
    final t = tag.toLowerCase();
    final title = RegExp(r'"([^"]+)"').allMatches(last).map((m) => m[1]!).toList().last;
    if (issued.contains('${t}u')) return textEvents('Done.');
    final id = attributedHandle(r, title, note ? 'note' : 'evt');
    if (id != null) {
      return toolCallEvents([
        call('${t}u', note ? 'notes__update_note' : 'calendar__update_event',
            note ? {'note_id': id, 'append': 'status: reviewed'} : {'event_id': id, 'date': '2026-12-01', 'time': '16:00'}),
      ]);
    }
    if (issued.contains('${t}s')) return textEvents('I could not find "$title".');
    state.lookups++;
    return toolCallEvents([call('${t}s', note ? 'notes__search_notes' : 'calendar__find_events', {'query': title})]);
  }
  return textEvents('OK.');
}

/// Weaknesses this suite found and documents rather than hides
/// (`data/l4/known_issues.json`, package README "Findings"): such a case
/// does not fail the gate, and passing anyway is reported so the entry
/// gets removed.
final Map<String, String> l4KnownIssues = {
  for (final i in objectList(loadData('l4/known_issues.json')['issues']))
    for (final c in (i['cases']! as List).cast<String>()) c: '${i['id']}: ${i['knownIssue']}',
};

String? l4KnownIssue(L4Run r) => l4KnownIssues[r.key];

final class L4Suite implements EvalSuite {
  const L4Suite();

  @override
  String get id => 'L4';

  @override
  String get title => 'Compaction fidelity';

  @override
  bool supports(ModelSpec model) => true;

  @override
  Future<SuiteReport> run(EvalContext ctx) async {
    final sessions = ctx.select([for (final j in objectList(loadData('l4/sessions.json')['sessions'])) L4Session(j)], (s) => s.id);
    final report = SuiteReport(
      suite: id,
      title: title,
      model: ctx.scripted ? 'scripted sessions, extractive summarizer' : 'scripted sessions, ${ctx.model.label} summarizer',
      casePolicy: ctx.scripted ? CasePolicy.all : CasePolicy.none,
    );
    final runs = <L4Run>[];
    final variants = ctx.scripted ? L4Variant.values : const [L4Variant.deferred];
    // A model summarizer costs about a minute of prefill per compaction on
    // a phone-class CPU: real runs default to the 40-turn session, once.
    final counts = ctx.scripted ? l4CompactionCounts : const [0, 1];
    final selected = ctx.scripted || ctx.only != null ? sessions : sessions.where((s) => s.id == 'household_40').toList();
    if (ctx.runtime != null) {
      final window = (await ctx.runtime!.provider.capabilities(ctx.runtime!.modelId)).contextLength;
      if (window < l4MinModelWindow) {
        report.notes.add('Skipped: a model summarizer needs --context $l4MinModelWindow or more '
            '(the 40-turn session does not fit $window tokens without compaction).');
        return report;
      }
    }
    for (final variant in variants) {
      for (final s in selected) {
        for (final n in counts) {
          MeteredProvider? metered;
          ContextStrategy strategy = const ExtractiveContextStrategy();
          var window = 65536;
          if (ctx.runtime != null) {
            // The local model summarizes a session sized to its own window.
            window = (await ctx.runtime!.provider.capabilities(ctx.runtime!.modelId)).contextLength;
            if (n > 0) {
              metered = MeteredProvider(ctx.runtime!.provider);
              strategy = ModelContextStrategy(
                provider: metered,
                modelId: ctx.runtime!.modelId,
                params: const GenerationParams(temperature: 0, seed: 42, reasoning: ReasoningEffort.off),
                counter: ctx.runtime!.counter,
              );
            }
          }
          final r = await runL4Session(s, compactions: n, variant: variant, strategy: strategy, summarizer: metered, window: window);
          runs.add(r);
          ctx.log('  ${r.key}: ${r.compacted} compactions, ${r.duplicated} duplicates, retention '
              '${[for (final f in l4Fields) '${f.split('_').first} ${r.retention[f]?.$1 ?? 0}/${r.retention[f]?.$2 ?? 0}'].join(', ')}'
              '${r.handleLookups > 0 ? ', ${r.handleLookups} handle lookups' : ''}');
          report.cases.add(_case(r));
        }
      }
    }
    _metrics(report, runs, gate: ctx.scripted);
    report.extra['runs'] = {for (final r in runs) r.key: r.toJson()};
    return report;
  }

  static CaseResult _case(L4Run r) {
    final problems = [
      ...r.problems,
      if (r.duplicated > 0) '${r.duplicated} duplicated side effect(s): ${r.duplicates.take(3).join('; ')}',
      for (final f in const ['constraints', 'preferences'])
        if ((r.retention[f]?.$1 ?? 0) != (r.retention[f]?.$2 ?? 0)) '$f lost: ${r.lost.where((x) => x.startsWith(f)).take(2).join('; ')}',
    ];
    return CaseResult(
      id: r.key,
      group: r.variant.name,
      pass: problems.isEmpty,
      detail: problems.isEmpty
          ? '${r.compacted} compactions: no duplicates, handles ${r.handleProbesOk}/${r.handleProbes}'
              '${r.handleLookups > 0 ? ' (${r.handleLookups} searched)' : ''}'
          : problems.join('; '),
      knownIssue: l4KnownIssue(r),
      data: r.toJson(),
    );
  }

  static void _metrics(SuiteReport report, List<L4Run> runs, {required bool gate}) {
    double ratio(Iterable<L4Run> rs, String f) {
      var k = 0;
      var n = 0;
      for (final r in rs) {
        k += r.retention[f]?.$1 ?? 0;
        n += r.retention[f]?.$2 ?? 0;
      }
      return n == 0 ? 1 : k / n;
    }

    int sum(Iterable<L4Run> rs, int Function(L4Run r) f) => rs.fold(0, (s, r) => s + f(r));

    final compacted = runs.where((r) => r.compactions > 0).toList();
    final control = runs.where((r) => r.compactions == 0).toList();
    // Known issues are reported, not gated (like L0's documented divergences).
    final gated = compacted.where((r) => l4KnownIssue(r) == null).toList();
    final strictK = sum(compacted, (r) => r.strictEffects.$1);
    final strictN = sum(compacted, (r) => r.strictEffects.$2);
    final tokens = [for (final r in compacted) ...r.summaryTokens];
    report.metrics.addAll([
      for (final f in l4Fields)
        Metric('retention_$f', ratio(compacted, f), unit: 'ratio', better: Better.higher,
            min: gate && (f == 'constraints' || f == 'preferences') ? 1 : null,
            description: 'planted $f visible to the model after compaction (runs with ≥ 1 compaction)'),
      Metric('retention_side_effects_strict', strictN == 0 ? 1 : strictK / strictN, unit: 'ratio', better: Better.higher,
          description: 'completed actions shown as done on a line that names the tool and its key argument'),
      Metric.ratio('duplicate_side_effect_rate', sum(compacted, (r) => r.duplicated), sum(compacted, (r) => r.effects),
          better: Better.lower, description: 'completed actions re-applied by a faithful agent that cannot see them as done'),
      Metric('duplicate_side_effects', sum(gated, (r) => r.duplicated).toDouble(), unit: 'count', better: Better.lower,
          max: gate ? 0 : null, description: 'duplicates outside documented known issues (gated)'),
      Metric('duplicate_side_effects_all', sum(compacted, (r) => r.duplicated).toDouble(), unit: 'count', better: Better.lower),
      Metric('duplicate_non_idempotent', sum(compacted, (r) => r.duplicatedNonIdempotent).toDouble(), unit: 'count',
          better: Better.lower, description: 'duplicates that changed state (a second note/event, a repeated append)'),
      Metric.ratio('task_success', compacted.where((r) => r.taskSuccess).length, compacted.length, better: Better.higher,
          whenEmpty: 1, description: 'compacted runs with no duplicate and both handle probes done'),
      Metric.ratio('task_success_control', control.where((r) => r.taskSuccess).length, control.length, better: Better.higher,
          whenEmpty: 1, min: gate ? 1 : null, description: 'the same probes without compaction'),
      Metric('handle_lookups', sum(compacted, (r) => r.handleLookups).toDouble(), unit: 'count', better: Better.lower,
          description: 'handle probes that needed a search because no id was attributable in context'),
      Metric('ledger_read_only_entries', sum(compacted, (r) => r.ledgerReadOnly).toDouble(), unit: 'count', better: Better.lower,
          description: 'read-only calls recorded as side effects in the final summaries'),
      Metric('ledger_unnamed_targets', sum(compacted, (r) => r.ledgerUnnamed).toDouble(), unit: 'count', better: Better.lower,
          description: 'ledger lines that do not name the tool that actually ran'),
      Metric('ledger_evicted_effects', sum(compacted, (r) => r.effectsEvicted).toDouble(), unit: 'count', better: Better.lower,
          description: 'completed actions in neither the ledger nor the kept transcript'),
      Metric('ledger_folded_calls', sum(compacted, (r) => r.ledgerFolded).toDouble(), unit: 'count',
          description: 'calls the ledger folded into per-tool aggregate lines (count and key arguments) to fit its cap'),
      Metric('summary_tokens_mean', tokens.isEmpty ? 0 : mean(tokens), unit: 'tokens', better: Better.lower,
          description: 'rendered summary size per compaction (4 chars per token)'),
      Metric('summary_tokens_max', tokens.isEmpty ? 0 : tokens.reduce((a, b) => a > b ? a : b).toDouble(), unit: 'tokens'),
      Metric('compactions_skipped', runs.fold(0, (s, r) => s + r.skipped.length).toDouble(), unit: 'count',
          better: Better.lower, max: gate ? 0 : null),
      Metric('unhandled_errors', sum(runs, (r) => r.unhandled).toDouble(), unit: 'count', better: Better.lower, max: 0),
      if (runs.any((r) => r.summarizerCalls > 0)) ...[
        Metric('summarizer_calls', sum(compacted, (r) => r.summarizerCalls).toDouble(), unit: 'count'),
        Metric('summarizer_input_tokens', sum(compacted, (r) => r.summarizerUsage.inputTokens).toDouble(), unit: 'tokens'),
        Metric('summarizer_output_tokens', sum(compacted, (r) => r.summarizerUsage.outputTokens).toDouble(), unit: 'tokens'),
        Metric('summarizer_fallbacks', sum(compacted, (r) => r.usedFallback).toDouble(), unit: 'count',
            description: 'compactions where the model summary failed or was rejected and the extractive one was used'),
      ],
    ]);
    final groups = <String, List<L4Run>>{};
    for (final r in runs) {
      (groups['${r.variant.name}.c${r.compactions}'] ??= []).add(r);
    }
    for (final e in groups.entries) {
      final rs = e.value;
      report.metrics.addAll([
        for (final f in l4Fields) Metric(f, ratio(rs, f), unit: 'ratio', group: e.key, better: Better.higher),
        Metric('duplicates', sum(rs, (r) => r.duplicated).toDouble(), unit: 'count', group: e.key, better: Better.lower),
        Metric('lookups', sum(rs, (r) => r.handleLookups).toDouble(), unit: 'count', group: e.key),
        Metric('ledger_reads', sum(rs, (r) => r.ledgerReadOnly).toDouble(), unit: 'count', group: e.key),
        Metric('evicted', sum(rs, (r) => r.effectsEvicted).toDouble(), unit: 'count', group: e.key),
      ]);
    }
  }
}
