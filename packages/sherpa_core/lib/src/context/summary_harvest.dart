import 'dart:convert';

import 'package:meta/meta.dart';

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
    final ledgerIds = {for (final s in prev?.sideEffectLedger ?? const <SideEffectRecord>[]) s.callId};
    final taintSources = {for (final t in prev?.taint ?? const <TaintRecord>[]) t.source};
    final covered = {...?prev?.coveredMessageIds};
    return CompactionSummary(
      goal: model.goal.trim().isNotEmpty ? model.goal : (prev?.goal ?? input.taskStatement ?? ''),
      constraints: carryForward(prev?.constraints ?? const [], model.constraints.where((s) => !Provenance.isTool(s)),
          cap: CompactionSummary.listLimits['constraints']!.$1),
      userPreferences: carryForward(
          prev?.userPreferences ?? const [], model.userPreferences.where((s) => !Provenance.isTool(s)),
          cap: CompactionSummary.listLimits['userPreferences']!.$1),
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
      nextStepQuote: h.nextStepQuote ?? prev?.nextStepQuote,
      artifacts: _newestFirst(h.artifacts, prev?.artifacts ?? const [], (a) => a, CompactionSummary.maxArtifacts),
      stateHandles: _newestFirst(
          h.stateHandles, prev?.stateHandles ?? const [], (s) => s.dedupeKey, CompactionSummary.maxStateHandles),
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
            final def = lookup(p.toolName);
            artifacts.addAll(_artifactsInResult(p));
            handles.addAll(_handlesInResult(p));
            final source = _taintSource(p.toolName, def);
            if (source != null) taint.add(TaintRecord(source: source, firstMessageId: m.id));
            final effect = call == null ? null : _sideEffect(call, p, def);
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
      nextStepQuote: _nextStepQuote([...input.messages, ...input.keptMessages]),
      artifacts: _dedupe(artifacts.reversed).toList(),
      stateHandles: _dedupeBy(handles.reversed, (h) => h.dedupeKey).toList(),
      sideEffects: effects,
      taint: _dedupeBy(taint, (t) => t.source).toList(),
      coveredMessageIds: [for (final m in input.messages) if (!isSyntheticView(m)) m.id],
    );
  }

  // ---------------------------------------------------------------------------
  // User intent

  static List<String> _userMessages(CompactionInput input, TokenCounter counter) => _collectUserMessages(
        [for (final m in input.messages.reversed) if (isRealUserTurn(m) && m.text.trim().isNotEmpty) m.text.trim()],
        input.previousSummary?.userMessages ?? const [],
        input.userMessageTokens,
        counter,
      );

  static List<String> _collectUserMessages(
    List<String> fresh,
    List<String> older,
    int budget,
    TokenCounter counter,
  ) {
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
  static final RegExp _relPath =
      RegExp(r'''(?<![\w.:/~@%-])(?:[\w@+-][\w.@+-]*/)+[\w@+-][\w.@+-]*\.[A-Za-z][A-Za-z0-9]{0,7}(?![\w/])''');
  static final RegExp _artifactKey =
      RegExp(r'(path|file|filename|dir|directory|folder|uri|url|href|src|dest|destination|target)$', caseSensitive: false);
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
      String() when key != null && _artifactKey.hasMatch(key) && value.isNotEmpty && !value.contains('\n') =>
        [clipText(value.trim(), CompactionSummary.maxArtifactChars)],
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
      r'^(id|uuid|guid|handle|cursor|next_?cursor|ref)$|(_id|Id|ID|_uuid|Uuid|_handle|Handle|_ref|Ref)$');
  static final RegExp _secretKey = RegExp(
      r'(token|secret|passw|signature|credential|api_?key|apikey|auth|cookie|private|otp|pin$)',
      caseSensitive: false);
  static final RegExp _secretValue = RegExp(r'^(sk-|ghp_|gho_|ghs_|hf_|xox[abprs]-|eyJ|AKIA|AIza)');
  static final RegExp _handleText =
      RegExp(r'''\b([A-Za-z][\w-]{0,40}?(?:_id|Id|ID|_handle|Handle|_ref))\b["']?\s*[:=]\s*["']?([\w.:/#-]{1,120})''');
  static const int _handlesPerResult = 6;

  /// Ids and handles in a tool result (structured content, JSON text, or
  /// `foo_id: value` patterns in prose). Secret-looking keys and values are
  /// never collected: summaries end up in handoff bundles.
  static List<StateHandle> _handlesInResult(ToolResultPart p) {
    final out = <StateHandle>[];
    void add(String key, Object? v) {
      if (out.length >= _handlesPerResult) return;
      if (!_handleKey.hasMatch(key) || _secretKey.hasMatch(key)) return;
      final value = switch (v) {
        String() => v.trim(),
        int() => '$v',
        _ => null,
      };
      if (value == null || value.isEmpty || value.length > 160 || value.contains(RegExp(r'\s'))) return;
      if (_secretValue.hasMatch(value)) return;
      out.add(StateHandle(key: key, value: value, tool: p.toolName, callId: p.callId));
    }

    void walk(Object? v, int depth) {
      if (depth > 3 || out.length >= _handlesPerResult) return;
      if (v is Map<Object?, Object?>) {
        for (final e in v.entries) {
          add(e.key.toString(), e.value);
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
      for (final m in _handleText.allMatches(text.length > _scanLimit ? text.substring(0, _scanLimit) : text)) {
        add(m[1]!, m[2]);
      }
    }
    return out;
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

  /// Error texts the agent loop writes for calls that never executed; such
  /// calls are not side effects (mirrors `AgentRunner` and `ToolPairing`).
  static const List<String> _notExecuted = [
    'The user declined',
    'Cancelled by the user before it ran',
    'Unknown tool',
    'Invalid arguments',
    'not executed: context was compacted',
  ];

  static SideEffectRecord? _sideEffect(ToolCall call, ToolResultPart result, ToolDefinition? def) {
    if (call.name == UpdatePlanTool.toolName) return null;
    // Unknown definitions count as side effects: wrongly listing a read as
    // "done" costs a re-read, wrongly omitting a write can repeat it.
    if (def != null && def.annotations.isReadOnly) return null;
    if (result.isError && _notExecuted.any(result.text.trimLeft().startsWith)) return null;
    return SideEffectRecord(
      callId: call.id,
      tool: call.name,
      server: def?.source.serverId,
      argsDigest: Digest.args(call.arguments),
      outcome: result.isError ? SideEffectOutcome.error : SideEffectOutcome.ok,
      argsPreview: call.arguments.isEmpty ? null : clipText(Digest.canonicalJson(call.arguments), 120),
    );
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
