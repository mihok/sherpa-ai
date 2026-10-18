import 'dart:math';

import '../common/cancellation.dart';
import '../common/clock.dart';
import '../common/ids.dart';
import '../context/compaction.dart';
import '../context/digest.dart';
import '../context/extractive_strategy.dart';
import '../context/text.dart';
import '../context/turns.dart';
import '../context/untrusted.dart';
import '../model/content.dart';
import '../model/message.dart';
import '../model/tool.dart';
import '../provider/model_provider.dart';
import '../session/checkpoint.dart';
import '../session/session_store.dart';
import 'handoff_bundle.dart';

/// Removes secrets from a free-text field. The app passes `sherpa_net`'s
/// `Redactor.text`; [HandoffScrubbers.basic] is the core's fallback.
typedef SecretScrubber = String Function(String text);

abstract final class HandoffScrubbers {
  static const String mask = '«redacted»';

  static final List<RegExp> _tokens = [
    RegExp(r'\bsk-(?:ant-|proj-)?[A-Za-z0-9_-]{12,}'),
    RegExp(r'\bhf_[A-Za-z0-9]{20,}'),
    RegExp(r'\bgh[pousr]_[A-Za-z0-9]{20,}'),
    RegExp(r'\bAIza[0-9A-Za-z_-]{30,}'),
    RegExp(r'\bxox[abprs]-[A-Za-z0-9-]{10,}'),
    RegExp(r'\bAKIA[0-9A-Z]{16}\b'),
    RegExp(r'\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}'),
  ];
  static final RegExp _bearer = RegExp(r'(Bearer\s+)[A-Za-z0-9._~+/=-]{8,}', caseSensitive: false);
  static final RegExp _assignment = RegExp(
    r'\b(api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|password|passwd|secret|token)'
    r'''(\s*[:=]\s*["']?)[^\s"'&,;]{4,}''',
    caseSensitive: false,
  );
  static final RegExp _query = RegExp(
    r'([?&](?:api[_-]?key|key|token|access_token|refresh_token|sig|signature|code|secret|password)=)[^&\s#]+',
    caseSensitive: false,
  );

  /// Token-shaped strings, bearer values, `key=value` secrets and secret
  /// query parameters. Defense in depth only: it cannot know every format.
  static String basic(String text) {
    var out = text.replaceAllMapped(_bearer, (m) => '${m[1]}$mask');
    for (final r in _tokens) {
      out = out.replaceAll(r, mask);
    }
    out = out.replaceAllMapped(_assignment, (m) => '${m[1]}${m[2]}$mask');
    return out.replaceAllMapped(_query, (m) => '${m[1]}$mask');
  }
}

/// Builds a [HandoffBundle] from a stored session.
///
/// The summary covers the whole active branch: the latest compaction summary
/// (if any) merged with everything after it, so the bundle stands on its
/// own. Every free-text field goes through [scrub], connection URLs lose
/// user info, query and fragment, and the result is clipped to [limits] so
/// [HandoffBundle.parse] accepts what this produces.
final class HandoffBuilder {
  HandoffBuilder({
    required this.store,
    this.strategy = const ExtractiveContextStrategy(),
    this.scrub = HandoffScrubbers.basic,
    this.clock = const SystemClock(),
    this.counter,
    this.limits = const HandoffLimits(),
  });

  final SessionStore store;
  final ContextStrategy strategy;
  final SecretScrubber scrub;
  final Clock clock;
  final TokenCounter? counter;
  final HandoffLimits limits;

  Future<HandoffBundle> build({
    required String sessionId,
    required HandoffSource source,
    List<HandoffConnection> connections = const [],
    List<HandoffArtifact> artifacts = const [],
    int recentUserTurns = 0,
    String? notes,
    List<ToolDefinition> tools = const [],
    ToolDefinition? Function(String name)? toolLookup,
    CancellationToken? cancel,
  }) async {
    final session = await store.getSession(sessionId);
    if (session == null) throw StateError('unknown session $sessionId');
    final leaf = session.activeLeafId;
    final path = leaf == null ? const <Message>[] : await store.path(sessionId, leaf);
    final overlays = await store.overlays(sessionId);
    final plan = await store.getPlan(sessionId);
    final checkpoint = await store.getCheckpoint(sessionId);
    final active = activeCompactions(path, overlays);
    final latest = active.isEmpty ? null : active.reduce((a, b) => a.to >= b.to ? a : b);
    bool hidden(int i) => active.any((r) => i >= r.from && i <= r.to);
    final fresh = [
      for (final (i, m) in path.indexed)
        if (!hidden(i) && !m.pinned) m,
    ];
    final firstUser = path.where((m) => isRealUserTurn(m) && m.text.trim().isNotEmpty).firstOrNull;
    final task = plan?.task ?? latest?.overlay.summary.task ?? firstUser?.text.trim() ?? session.title;
    final summary = fresh.isEmpty && latest != null
        ? latest.overlay.summary
        : await strategy.summarize(
            CompactionInput(
              messages: fresh,
              previousSummary: latest?.overlay.summary,
              taskStatement: clipText(task, CompactionSummary.maxTaskChars),
              plan: plan,
              tools: tools,
              toolLookup: toolLookup,
              counter: counter,
              pendingApprovals: _pending(checkpoint),
            ),
            cancel: cancel,
          );
    final bundle = HandoffBundle(
      createdAt: clock.now(),
      source: HandoffSource(
        appVersion: source.appVersion,
        providerKind: source.providerKind,
        modelId: source.modelId,
        location: source.location,
        sessionId: source.sessionId ?? sessionId,
      ),
      task: task,
      plan: plan,
      // Message ids and the wrapper nonce mean nothing to the next session.
      summary: summary.copyWith(coveredMessageIds: const [], clearNonce: true),
      pinned: [
        for (final m in path)
          if (m.pinned && m.kind != MessageKind.summary) ...turnsOf(m),
      ].take(limits.maxPinned).toList(),
      recentTurns: _recent(path, recentUserTurns),
      connections: connections.take(limits.maxConnections).toList(),
      artifacts: artifacts.take(limits.maxArtifacts).toList(),
      notes: notes,
    );
    return bundle.mapText((s) => clipText(scrub(s), limits.maxStringChars));
  }

  List<HandoffTurn> _recent(List<Message> path, int userTurns) {
    if (userTurns <= 0) return const [];
    var seen = 0;
    var start = path.length;
    for (var i = path.length - 1; i >= 0 && seen < userTurns; i--) {
      if (isRealUserTurn(path[i])) {
        seen++;
        start = i;
      }
    }
    final turns = [for (final m in path.skip(start)) ...turnsOf(m)];
    return turns.length <= limits.maxRecentTurns ? turns : turns.sublist(turns.length - limits.maxRecentTurns);
  }

  static List<String> _pending(RunCheckpoint? cp) => cp == null || cp.isTerminal
      ? const []
      : [
          for (final p in cp.pendingCalls)
            if (p.status == PendingCallStatus.pending || p.status == PendingCallStatus.approved)
              '${p.toolName} (call ${p.callId})',
        ];

  /// A message as provider-neutral text turns: reasoning and signatures are
  /// dropped, tool calls become a line of text, each tool result its own
  /// (untrusted) turn.
  static List<HandoffTurn> turnsOf(Message m) {
    switch (m.role) {
      case Role.tool:
        return [
          for (final r in m.toolResults)
            HandoffTurn(
              role: Role.tool,
              toolName: r.toolName,
              text: clipText('${r.isError ? '(error) ' : ''}${r.text}', 4000),
            ),
        ];
      case Role.assistant:
        final calls = [
          for (final c in m.toolCalls) '[called ${c.name} ${clipText(Digest.canonicalJson(c.arguments), 300)}]',
        ];
        final text = [if (m.text.trim().isNotEmpty) m.text.trim(), ...calls].join('\n');
        return text.isEmpty ? const [] : [HandoffTurn(role: Role.assistant, text: clipText(text, 4000))];
      case Role.user || Role.system:
        final text = m.text.trim();
        return text.isEmpty ? const [] : [HandoffTurn(role: Role.user, text: clipText(text, 4000))];
    }
  }
}

/// Starts a new session from [bundle]: a [SessionRecord] with
/// `handoffFromSessionId` set, seeded with a pinned `MessageKind.handoff`
/// user message (the rendered bundle with its pinned items and plan) and a
/// fixed assistant acknowledgement, plus the plan in the store.
///
/// The seed is pinned, so the new session's context manager never prunes
/// or compacts it; it is not a "real" user turn, so no cut point lands
/// before it.
Future<SessionRecord> startSessionFromHandoff({
  required SessionStore store,
  required HandoffBundle bundle,
  required String sessionId,
  required IdGenerator ids,
  Clock clock = const SystemClock(),
  String? fromSessionId,
  String? title,
  String? systemPrompt,
  String? providerId,
  String? modelId,
  String? nonce,
  Random? random,
}) async {
  final now = clock.now();
  final from = fromSessionId ?? bundle.source.sessionId ?? 'bundle:${Digest.fnv64(bundle.encode())}';
  final seed = Message(
    id: ids.next('msg'),
    role: Role.user,
    kind: MessageKind.handoff,
    pinned: true,
    createdAt: now,
    content: [TextPart(bundle.renderForModel(nonce: nonce ?? UntrustedData.newNonce(random)))],
    metadata: {
      'handoff': {
        'format': HandoffBundle.format,
        'version': HandoffBundle.version,
        'createdAt': bundle.createdAt.toUtc().toIso8601String(),
        'fromSessionId': from,
      },
    },
  );
  final ack = Message(
    id: ids.next('msg'),
    parentId: seed.id,
    role: Role.assistant,
    kind: MessageKind.notice,
    pinned: true,
    createdAt: now,
    content: const [TextPart('Understood. I have the handoff and will continue the task from there.')],
  );
  final session = SessionRecord(
    id: sessionId,
    title: title ?? clipText(firstLine(bundle.task).isEmpty ? 'Handoff' : firstLine(bundle.task), 60),
    createdAt: now,
    updatedAt: now,
    providerId: providerId,
    modelId: modelId,
    activeLeafId: ack.id,
    systemPrompt: systemPrompt,
    handoffFromSessionId: from,
  );
  await store.putSession(session);
  await store.putMessage(sessionId, seed);
  await store.putMessage(sessionId, ack);
  final plan = bundle.plan ?? bundle.summary.plan;
  if (plan != null) await store.putPlan(sessionId, plan);
  await store.appendAudit(
    AuditEntry(
      id: ids.next('aud'),
      sessionId: sessionId,
      at: now,
      kind: AuditKind.handoff,
      summary: 'Started from a handoff of $from',
      data: {'bundleCreatedAt': bundle.createdAt.toUtc().toIso8601String(), 'sourceModel': bundle.source.modelId},
    ),
  );
  return session;
}
