import 'dart:convert';

import 'package:meta/meta.dart';

import '../common/json.dart';
import '../model/content.dart';
import '../model/message.dart';
import '../model/tool.dart';
import '../provider/model_provider.dart';
import '../tools/plan_tool.dart';
import 'compaction.dart';
import 'digest.dart';
import 'text.dart';
import 'token_estimator.dart';
import 'turns.dart';

/// [H] fields extracted from one compacted range, before merging.
@immutable
final class SummaryHarvest {
  const SummaryHarvest({
    required this.userMessages,
    required this.nextStepQuote,
    required this.artifacts,
    required this.stateHandles,
    required this.sideEffects,
    required this.taint,
    required this.coveredMessageIds,
  });

  final List<String> userMessages;
  final String? nextStepQuote;
  final List<String> artifacts;
  final List<StateHandle> stateHandles;
  final List<SideEffectRecord> sideEffects;
  final List<TaintRecord> taint;
  final List<String> coveredMessageIds;
}

/// Fills the harness-owned [H] fields of a summary from the transcript and
/// performs the rolling merge with the previous summary (R11 §9.1).
///
/// Everything here is deterministic code, never model output: the fields a
/// small summarizer is most likely to drop (verbatim user intent, file paths,
/// handles, completed side effects) are exactly the ones whose loss makes the
/// agent repeat or contradict itself after compaction.
abstract final class SummaryComposer {
  /// Merges model-produced [model] fields with [input]'s previous summary
  /// and freshly harvested [H] fields, then normalizes to the schema caps.
  static CompactionSummary compose(CompactionInput input, CompactionSummary model) {
    final prev = input.previousSummary;
    final h = harvest(input);
    final toolConstraints = [
      ...model.constraints.where(Provenance.isTool),
      ...model.userPreferences.where(Provenance.isTool),
    ];
    final ledgerIds = {for (final s in prev?.sideEffectLedger ?? const <SideEffectRecord>[]) ...s.allCallIds};
    final taintSources = {for (final t in prev?.taint ?? const <TaintRecord>[]) t.source};
    final covered = {...?prev?.coveredMessageIds};
    return CompactionSummary(
      goal: model.goal.trim().isNotEmpty ? model.goal : (prev?.goal ?? input.taskStatement ?? ''),
      constraints: carryForward(
        prev?.constraints ?? const [],
        model.constraints.where((s) => !Provenance.isTool(s)),
        cap: CompactionSummary.listLimits['constraints']!.$1,
      ),
      userPreferences: carryForward(
        prev?.userPreferences ?? const [],
        model.userPreferences.where((s) => !Provenance.isTool(s)),
        cap: CompactionSummary.listLimits['userPreferences']!.$1,
      ),
      decisions: model.decisions,
      completed: model.completed,
      openTasks: model.openTasks,
      currentWork: model.currentWork,
      nextStep: model.nextStep,
      keyFacts: [...model.keyFacts, ...toolConstraints],
      failedApproaches: model.failedApproaches,
      notes: model.notes,
      task: input.taskStatement ?? prev?.task,
      userMessages: h.userMessages,
      // A user turn kept after the summary supersedes any older quote.
      nextStepQuote: h.nextStepQuote ?? (_userTurnFollows(input) ? null : prev?.nextStepQuote),
      artifacts: _newestFirst(h.artifacts, prev?.artifacts ?? const [], (a) => a, CompactionSummary.maxArtifacts),
      stateHandles: _mergeHandles(
        [...h.stateHandles, ...?prev?.stateHandles],
        cap: CompactionSummary.maxStateHandles,
      ),
      sideEffectLedger: [
        ...?prev?.sideEffectLedger,
        for (final s in h.sideEffects)
          if (ledgerIds.add(s.callId)) s,
      ],
      pendingApprovals: input.pendingApprovals,
      taint: [
        ...?prev?.taint,
        for (final t in h.taint)
          if (taintSources.add(t.source)) t,
      ],
      compactionCount: (prev?.compactionCount ?? 0) + 1,
      coveredMessageIds: [
        ...?prev?.coveredMessageIds,
        for (final id in h.coveredMessageIds)
          if (covered.add(id)) id,
      ],
      plan: input.plan ?? prev?.plan,
      nonce: input.nonce ?? prev?.nonce,
    ).normalized();
  }

  /// Union of [previous] and [next], deduped by [itemKey] with the newest
  /// wording and position winning, cut to the newest [cap] items. This is
  /// how constraints survive any number of compactions (R11 §9.1): the model
  /// can add to them but cannot drop them.
  static List<String> carryForward(Iterable<String> previous, Iterable<String> next, {required int cap}) {
    final byKey = <String, String>{};
    for (final s in [...previous, ...next]) {
      if (s.trim().isEmpty) continue;
      final k = itemKey(s);
      byKey.remove(k);
      byKey[k] = s.trim();
    }
    final all = byKey.values.toList();
    return all.length <= cap ? all : all.sublist(all.length - cap);
  }

  /// [newestFirst] deduped by [StateHandle.dedupeKey] (the newest wins),
  /// keeping a label an older sighting of the same handle had, cut to [cap].
  static List<StateHandle> _mergeHandles(Iterable<StateHandle> newestFirst, {int? cap}) {
    final byKey = <String, StateHandle>{};
    for (final h in newestFirst) {
      final seen = byKey[h.dedupeKey];
      if (seen == null) {
        if (cap == null || byKey.length < cap) byKey[h.dedupeKey] = h;
      } else {
        byKey[h.dedupeKey] = seen.orLabel(h.label);
      }
    }
    return byKey.values.toList();
  }

  static List<T> _newestFirst<T>(List<T> fresh, List<T> older, String Function(T) key, int cap) {
    final seen = <String>{};
    final out = <T>[];
    for (final e in [...fresh, ...older]) {
      if (out.length >= cap) break;
      if (seen.add(key(e))) out.add(e);
    }
    return out;
  }

  /// Extracts the [H] fields of [input.messages].
  static SummaryHarvest harvest(CompactionInput input) {
    final counter = input.counter ?? HeuristicTokenCounter();
    final defs = {for (final t in input.tools) t.name: t};
    ToolDefinition? lookup(String name) => defs[name] ?? input.toolLookup?.call(name);

    final artifacts = <String>[];
    final handles = <StateHandle>[];
    final effects = <SideEffectRecord>[];
    final taint = <TaintRecord>[];
    final calls = <String, ToolCall>{};
    for (final m in input.messages) {
      for (final p in m.content) {
        switch (p) {
          case ToolCallPart(:final call):
            calls[call.id] = call;
            artifacts.addAll(artifactsInJson(call.arguments));
          case ToolResultPart():
            final call = calls[p.callId];
            // A proxied call (`call_tool`) is judged, ledgered and
            // attributed as the tool that actually ran.
            final ran = _ran(p, call, lookup);
            artifacts.addAll(_artifactsInResult(p));
            handles.addAll(_handlesInResult(p, ran));
            final source = _taintSource(ran.name, ran.def);
            if (source != null) taint.add(TaintRecord(source: source, firstMessageId: m.id));
            final effect = call == null ? null : _sideEffect(call, ran, p, input.annotationsFor);
            if (effect != null) effects.add(effect);
          case ResourceLinkPart(:final uri) || EmbeddedResourcePart(:final uri):
            artifacts.add(uri);
            taint.add(TaintRecord(source: 'resource:${clipText(uri, 80)}', firstMessageId: m.id));
          default:
            break;
        }
      }
      if (m.role == Role.assistant) artifacts.addAll(extractArtifacts(m.text));
    }
    return SummaryHarvest(
      userMessages: _userMessages(input, counter),
      nextStepQuote: _userTurnFollows(input) ? null : _nextStepQuote(input.messages),
      artifacts: _dedupe(artifacts.reversed).toList(),
      stateHandles: _mergeHandles(handles.reversed),
      sideEffects: effects,
      taint: _dedupeBy(taint, (t) => t.source).toList(),
      coveredMessageIds: [
        for (final m in input.messages)
          if (!isSyntheticView(m)) m.id,
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // User intent

  static List<String> _userMessages(CompactionInput input, TokenCounter counter) => _collectUserMessages(
    [
      for (final m in input.messages.reversed)
        if (isRealUserTurn(m) && m.text.trim().isNotEmpty) m.text.trim(),
    ],
    input.previousSummary?.userMessages ?? const [],
    input.userMessageTokens,
    counter,
  );

  static List<String> _collectUserMessages(List<String> fresh, List<String> older, int budget, TokenCounter counter) {
    final out = <String>[];
    var left = budget;
    for (final text in [...fresh, ...older]) {
      if (out.length >= CompactionSummary.maxUserMessages || left <= 0) break;
      final n = counter.countText(text);
      if (n <= left) {
        out.add(text);
        left -= n;
        continue;
      }
      // Codex keeps the newest messages whole and truncates the oldest one.
      if (left >= 24) out.add(_fitTokens(text, left, counter));
      break;
    }
    return out;
  }

  static String _fitTokens(String text, int tokens, TokenCounter counter) {
    var chars = (text.length * tokens / counter.countText(text).clamp(1, 1 << 30)).floor();
    var cut = clipText(text, chars);
    while (chars > 8 && counter.countText(cut) > tokens) {
      chars = (chars * 0.85).floor();
      cut = clipText(text, chars);
    }
    return cut;
  }

  /// A real user turn is kept verbatim after the summary.
  ///
  /// Then the summary quotes nothing: the request the next step serves is
  /// right after it, and the summary overlay applies to every branch that
  /// shares the folded range. Quoting the kept tail would carry one
  /// branch's latest request (possibly one the user edited away, or a
  /// secret they removed) into its siblings as trusted user intent.
  static bool _userTurnFollows(CompactionInput input) => lastRealUserTurn(input.keptMessages) >= 0;

  /// The most recent user sentence of the folded range ([CompactionInput.messages] only).
  static String? _nextStepQuote(List<Message> messages) {
    final i = lastRealUserTurn(messages);
    if (i < 0) return null;
    final s = sentences(messages[i].text);
    if (s.isEmpty) return null;
    final quote = s.lastWhere((x) => x.split(' ').length >= 3, orElse: () => s.last);
    return clipText(quote, CompactionSummary.nextStepChars);
  }

  // ---------------------------------------------------------------------------
  // Artifacts

  static final RegExp _uri = RegExp(r'''\b[a-zA-Z][a-zA-Z0-9+.-]{1,15}://[^\s<>"'`)\]}|\\]+''');
  static final RegExp _absPath = RegExp(r'''(?<![\w.:/~@%-])(?:~|\.{1,2})?/(?:[\w.@+-]+/)*[\w.@+-]+''');
  static final RegExp _relPath = RegExp(
    r'''(?<![\w.:/~@%-])(?:[\w@+-][\w.@+-]*/)+[\w@+-][\w.@+-]*\.[A-Za-z][A-Za-z0-9]{0,7}(?![\w/])''',
  );
  static final RegExp _artifactKey = RegExp(
    r'(path|file|filename|dir|directory|folder|uri|url|href|src|dest|destination|target)$',
    caseSensitive: false,
  );
  static const String _trailingPunct = '.,;:!?\'")';
  static const int _scanLimit = 50000;

  /// File paths, URLs and resource URIs in free text, in order of appearance.
  static List<String> extractArtifacts(String text) {
    if (text.isEmpty) return const [];
    var t = text.length > _scanLimit ? text.substring(0, _scanLimit) : text;
    final out = <String>[];
    for (final m in _uri.allMatches(t)) {
      out.add(_trimPunct(m[0]!));
    }
    t = t.replaceAll(_uri, ' ');
    for (final m in _absPath.allMatches(t)) {
      final p = _trimPunct(m[0]!);
      final segments = p.split('/').where((s) => s.isNotEmpty).length;
      if (p.length >= 3 && (segments >= 2 || p.split('/').last.contains('.'))) out.add(p);
    }
    for (final m in _relPath.allMatches(t)) {
      out.add(_trimPunct(m[0]!));
    }
    return out;
  }

  /// Artifacts in a JSON value: values under path/url-like keys verbatim,
  /// plus whatever [extractArtifacts] finds in every string.
  static List<String> artifactsInJson(Object? value, {String? key, int depth = 0}) {
    if (depth > 6) return const [];
    return switch (value) {
      String() when key != null && _artifactKey.hasMatch(key) && value.isNotEmpty && !value.contains('\n') => [
        clipText(value.trim(), CompactionSummary.maxArtifactChars),
      ],
      String() => extractArtifacts(value),
      Map<Object?, Object?>() => [
        for (final e in value.entries) ...artifactsInJson(e.value, key: e.key.toString(), depth: depth + 1),
      ],
      List<Object?>() => [for (final e in value.take(50)) ...artifactsInJson(e, key: key, depth: depth + 1)],
      _ => const [],
    };
  }

  static List<String> _artifactsInResult(ToolResultPart p) => [
    ...extractArtifacts(p.text),
    if (p.structured != null) ...artifactsInJson(p.structured),
    for (final c in p.content)
      if (c is ResourceLinkPart) c.uri else if (c is EmbeddedResourcePart) c.uri,
  ];

  static String _trimPunct(String s) {
    var end = s.length;
    while (end > 0 && _trailingPunct.contains(s[end - 1])) {
      end--;
    }
    return s.substring(0, end);
  }

  // ---------------------------------------------------------------------------
  // State handles

  static final RegExp _handleKey = RegExp(
    r'^(id|uuid|guid|handle|cursor|next_?cursor|ref)$|(_id|Id|ID|_uuid|Uuid|_handle|Handle|_ref|Ref)$',
  );
  static final RegExp _secretValue = RegExp(r'^(sk-|ghp_|gho_|ghs_|hf_|xox[abprs]-|eyJ|AKIA|AIza)');
  static final RegExp _handleText = RegExp(
    r'''\b([A-Za-z][\w-]{0,40}?(?:_id|Id|ID|_handle|Handle|_ref))\b["']?\s*[:=]\s*["']?([\w.:/#-]{1,120})''',
  );
  static const int _handlesPerResult = 6;

  /// Keys whose value says what a handle's object is (a note's title, a
  /// file's path) in the result that returned it or the call that made it.
  static final RegExp _handleLabelKey = RegExp(
    r'^(title|name|subject|label|summary|display_?name|file_?name|path)$',
    caseSensitive: false,
  );

  /// Ids and handles in a tool result (structured content, JSON text, or
  /// `foo_id: value` patterns in prose), attributed to the tool that ran
  /// ([ran]) and labelled with what they identify: the title/name next to
  /// the first handle of an object, else (for the result's top level) the
  /// title/name argument of the call. Secret-looking keys and values are
  /// never collected: summaries end up in handoff bundles.
  static List<StateHandle> _handlesInResult(ToolResultPart p, _Ran ran) {
    final out = <StateHandle>[];
    final callLabel = _labelIn(ran.arguments);
    bool add(String key, Object? v, String? label) {
      if (out.length >= _handlesPerResult) return false;
      if (!_handleKey.hasMatch(key) || secretKey.hasMatch(key)) return false;
      final value = switch (v) {
        String() => v.trim(),
        int() => '$v',
        _ => null,
      };
      if (value == null || value.isEmpty || value.length > 160 || value.contains(RegExp(r'\s'))) return false;
      if (_secretValue.hasMatch(value)) return false;
      out.add(StateHandle(key: key, value: value, tool: ran.name, callId: p.callId, label: label));
      return true;
    }

    void walk(Object? v, int depth) {
      if (depth > 3 || out.length >= _handlesPerResult) return;
      if (v is Map<Object?, Object?>) {
        // The object's own id is (by convention) its first handle; other
        // handles in it (a folder id, a cursor) belong to other objects.
        String? label = _labelIn(v) ?? (depth == 0 ? callLabel : null);
        for (final e in v.entries) {
          if (add(e.key.toString(), e.value, label)) label = null;
        }
        for (final e in v.values) {
          if (e is Map || e is List) walk(e, depth + 1);
        }
      } else if (v is List<Object?>) {
        for (final e in v.take(3)) {
          walk(e, depth + 1);
        }
      }
    }

    if (p.structured != null) walk(p.structured, 0);
    final text = p.text.trim();
    final json = text.length < 200000 && (text.startsWith('{') || text.startsWith('[')) ? _tryJson(text) : null;
    if (json != null) {
      walk(json, 0);
    } else {
      final matches = _handleText.allMatches(text.length > _scanLimit ? text.substring(0, _scanLimit) : text).toList();
      for (final m in matches) {
        add(m[1]!, m[2], matches.length == 1 ? callLabel : null);
      }
    }
    return out;
  }

  /// A short label from [m]'s title/name-like string value, if any.
  static String? _labelIn(Map<Object?, Object?> m) {
    for (final e in m.entries) {
      final v = e.value;
      if (v is! String || !_handleLabelKey.hasMatch(e.key.toString()) || secretKey.hasMatch(e.key.toString())) continue;
      final label = squash(v);
      if (label.isEmpty || _secretValue.hasMatch(label)) continue;
      return clipText(label, CompactionSummary.maxHandleLabelChars);
    }
    return null;
  }

  static Object? _tryJson(String text) {
    try {
      return jsonDecode(text);
    } on FormatException {
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Side effects and taint

  /// [ToolResultPart.meta] key the agent loop sets to `true` on the result
  /// of a call it answered without running it (declined, invalid, refused,
  /// unknown, a duplicate of another call in the same reply, cut off, or
  /// cancelled before it started). Such calls are not side effects. An
  /// interrupted call (outcome unknown) is never marked.
  static const String metaNotRun = 'ai.sherpa/notRun';

  /// Error texts the agent loop writes for calls that never executed; such
  /// calls are not side effects (mirrors `AgentRunner` and `ToolPairing`).
  /// For transcripts written before [metaNotRun].
  static const List<String> _notExecuted = [
    'The user declined',
    'Cancelled by the user before it ran',
    'Unknown tool',
    'Invalid arguments',
    'not executed: context was compacted',
  ];

  /// The hints a decision may rely on: [annotationsFor] (the approval
  /// policy's trust-aware view) when given, else the declared ones for
  /// built-in tools only. An untrusted server's `readOnlyHint` is a claim,
  /// not a fact (R01 §6.2), so its calls stay in the ledger.
  static ToolAnnotations trustedAnnotations(ToolDefinition def, ToolAnnotations Function(ToolDefinition)? annotationsFor) =>
      annotationsFor?.call(def) ??
      (def.source.kind == ToolSourceKind.builtin ? def.annotations : def.annotations.untrustedDefaults);

  /// The model-facing name of the tool that produced [p]: for a call made
  /// through a proxy such as `call_tool`, its target
  /// ([ToolResultPart.metaTool], set by the agent loop), else
  /// [ToolResultPart.toolName]. Use it to attribute tool output (provenance
  /// tags, taint), never the proxy.
  static String toolThatRan(ToolResultPart p) {
    final target = p.meta[ToolResultPart.metaTool];
    return target is String && target.isNotEmpty ? target : p.toolName;
  }

  /// What produced [p]: for a call made through a proxy (`call_tool`), the
  /// tool that actually ran ([toolThatRan]), with its own arguments and
  /// definition; otherwise [call] itself.
  static _Ran _ran(ToolResultPart p, ToolCall? call, ToolDefinition? Function(String name) lookup) {
    final metaServer = p.meta[ToolResultPart.metaServerId];
    final server = metaServer is String && metaServer.isNotEmpty ? metaServer : null;
    final target = toolThatRan(p);
    if (target != p.toolName) {
      final def = lookup(target);
      return (name: target, arguments: _proxiedArguments(call), def: def, server: server ?? def?.source.serverId);
    }
    final def = lookup(p.toolName);
    return (name: p.toolName, arguments: call?.arguments ?? const {}, def: def, server: def?.source.serverId ?? server);
  }

  /// The target's arguments in a proxy call: `call_tool`'s `arguments`
  /// object, which the router also accepts as a JSON string.
  static JsonMap _proxiedArguments(ToolCall? call) {
    final a = call?.arguments['arguments'];
    if (a is Map<Object?, Object?>) return a.cast<String, Object?>();
    if (a is String && a.trim().startsWith('{')) {
      final v = _tryJson(a.trim());
      if (v is Map<Object?, Object?>) return v.cast<String, Object?>();
    }
    return const {};
  }

  static SideEffectRecord? _sideEffect(
    ToolCall call,
    _Ran ran,
    ToolResultPart result,
    ToolAnnotations Function(ToolDefinition)? annotationsFor,
  ) {
    if (call.name == UpdatePlanTool.toolName || ran.name == UpdatePlanTool.toolName) return null;
    if (result.meta[metaNotRun] == true) return null;
    // Unknown definitions count as side effects: wrongly listing a read as
    // "done" costs a re-read, wrongly omitting a write can repeat it.
    final def = ran.def;
    if (def != null && trustedAnnotations(def, annotationsFor).isReadOnly) return null;
    if (result.isError && _notExecuted.any(result.text.trimLeft().startsWith)) return null;
    // Summaries travel in handoff bundles: secret-named argument values are
    // masked before the preview is encoded, and the digest is taken over the
    // masked arguments too (a digest of a short password is a dictionary
    // attack away from the password).
    final masked = maskSecretValues(ran.arguments)! as Map<String, Object?>;
    final key = keyArgument(masked);
    return SideEffectRecord(
      callId: call.id,
      tool: ran.name,
      server: ran.server,
      argsDigest: Digest.args(masked),
      outcome: result.isError ? SideEffectOutcome.error : SideEffectOutcome.ok,
      argsPreview: masked.isEmpty ? null : argsPreview(masked),
      keyArgs: [?key],
      declaredReadOnly: def != null && def.annotations.isReadOnly,
    );
  }

  /// Keys that name what an action is about (besides paths and ids).
  static final RegExp _labelArgKey = RegExp(
    r'^(title|name|subject|label|summary|topic|display_?name|to|recipients?|email|query|q)$',
    caseSensitive: false,
  );

  /// How much an argument identifies its action (lower first): paths and
  /// URLs, then titles and names, then ids, then other short scalars, then
  /// long text, then nested values.
  static int _argRank(String key, Object? v) {
    if (v is String) {
      if (_artifactKey.hasMatch(key) && !v.contains('\n')) return 0;
      if (_labelArgKey.hasMatch(key)) return 1;
      if (_handleKey.hasMatch(key)) return 2;
      return v.length <= 60 && !v.contains('\n') ? 3 : 4;
    }
    if (v is num || v is bool || v == null) return _handleKey.hasMatch(key) ? 2 : 3;
    return 5;
  }

  static List<String> _rankedKeys(Map<String, Object?> args) {
    final keys = args.keys.toList();
    final rank = {for (final k in keys) k: _argRank(k, args[k])};
    return keys..sort((a, b) => rank[a] != rank[b] ? rank[a]!.compareTo(rank[b]!) : a.compareTo(b));
  }

  /// A bounded JSON-like excerpt of [args] with the key argument first
  /// (canonical JSON sorts keys, which put e.g. `arguments` before `name`
  /// and `content` before `path`, and the clip then cut the identifying
  /// part off). Long strings are clipped one by one, so one long body can't
  /// push the others out.
  static String argsPreview(Map<String, Object?> args, {int max = 160}) {
    final parts = <String>[];
    for (final k in _rankedKeys(args)) {
      final v = args[k];
      final rank = _argRank(k, v);
      final value = switch (v) {
        String() => jsonEncode(clipText(v, rank <= 2 ? 100 : 48)),
        Map<Object?, Object?>() || List<Object?>() => clipText(Digest.canonicalJson(v), 48),
        _ => jsonEncode(v),
      };
      parts.add('${jsonEncode(k)}:$value');
    }
    return clipText('{${parts.join(',')}}', max);
  }

  /// The one or two arguments that identify the action (`path="/a.txt"`,
  /// `title="Dentist" date="2026-11-03"`), for ledger aggregates; null when
  /// no argument is short enough to name it.
  static String? keyArgument(Map<String, Object?> args) {
    final out = <String>[];
    for (final k in _rankedKeys(args)) {
      final v = args[k];
      if (_argRank(k, v) > 3 || out.length == 2) break;
      if (v is String && v.trim().isEmpty) continue;
      out.add('$k=${jsonEncode(v is String ? clipText(v, out.isEmpty ? 80 : 40) : v)}');
    }
    return out.isEmpty ? null : out.join(' ');
  }

  static String? _taintSource(String toolName, ToolDefinition? def) {
    if (toolName == UpdatePlanTool.toolName) return null;
    if (def != null && def.source.kind == ToolSourceKind.builtin && !def.annotations.isOpenWorld) return null;
    if (def?.source.kind == ToolSourceKind.mcp && def?.source.serverId != null) {
      return 'mcp:${def!.source.serverId}/$toolName';
    }
    return 'tool:$toolName';
  }

  static Iterable<String> _dedupe(Iterable<String> items) => _dedupeBy(items, (s) => s);

  static Iterable<T> _dedupeBy<T>(Iterable<T> items, String Function(T) key) {
    final seen = <String>{};
    return items.where((e) => seen.add(key(e)));
  }
}

/// The tool behind a result: its model-facing name, the arguments it ran
/// with, its definition (when known) and its server.
typedef _Ran = ({String name, JsonMap arguments, ToolDefinition? def, String? server});
