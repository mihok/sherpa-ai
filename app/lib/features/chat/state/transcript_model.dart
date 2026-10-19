import 'package:flutter/foundation.dart';
import 'package:sherpa_core/sherpa_core.dart';

/// Position of a message among its siblings (branches created by edit or
/// retry), for the "‹ 2/3 ›" switcher.
@immutable
final class BranchInfo {
  const BranchInfo({required this.messageId, required this.index, required this.count});

  /// The message the switcher acts on.
  final String messageId;

  /// Zero-based position among siblings of the same role, oldest first.
  final int index;
  final int count;

  bool get hasSiblings => count > 1;
  bool get canGoBack => index > 0;
  bool get canGoForward => index < count - 1;

  @override
  bool operator ==(Object other) =>
      other is BranchInfo && other.messageId == messageId && other.index == index && other.count == count;

  @override
  int get hashCode => Object.hash(messageId, index, count);
}

/// One row of the transcript. Items are immutable and the controller reuses
/// the same instance while a message is unchanged, so widgets can be cached
/// by identity and finished messages never rebuild while a reply streams.
@immutable
sealed class ChatItem {
  const ChatItem();

  /// Stable widget key across rebuilds.
  String get key;

  /// Changes whenever anything the item renders changes.
  String get signature;
}

/// `Message.metadata` key of the MCP prompt a message came from:
/// `{serverId, name, serverName, command}` (the composer adds the last two).
const String kMcpPromptKey = 'mcpPrompt';

/// `Message.metadata` key listing the MCP resources the user attached with
/// `@`: `[{uri, serverId, serverName, mention}]`, so the transcript can say
/// which server each one came from.
const String kMcpResourcesKey = 'mcpResources';

/// `Message.metadata` key of an assistant step's performance sample (a
/// client-only display hint, [ReplyPerf.toJson]).
const String kReplyPerfKey = 'perf';

/// Where a message written by an MCP server's prompt came from.
@immutable
final class PromptSource {
  const PromptSource({required this.serverName, required this.command, required this.untrusted});

  /// [kMcpPromptKey] of [m], or null for a message the user typed.
  static PromptSource? of(Message m) {
    final p = m.metadata[kMcpPromptKey];
    if (p is! Map) return null;
    final server = p['serverName'] ?? p['serverId'];
    final command = p['command'] ?? p['name'];
    return PromptSource(
      serverName: server is String ? server : 'a tool server',
      command: command is String ? command : '',
      untrusted: m.metadata[UntrustedData.messageMetadataKey] == true,
    );
  }

  final String serverName;

  /// `server:prompt`, without the slash.
  final String command;

  /// The server is not trusted: the agent loop counts the text as
  /// untrusted content.
  final bool untrusted;

  /// "From Example tools · /example:review" (+ " · untrusted").
  String get label => [
        'From $serverName',
        if (command.isNotEmpty) '/$command',
        if (untrusted) 'untrusted',
      ].join(' · ');

  String get semanticLabel =>
      'Written by the $serverName prompt${command.isEmpty ? '' : ' /$command'}${untrusted ? ', from an untrusted server' : ''}';
}

/// A resource attached to a message (an `@` mention, or part of a prompt).
@immutable
final class AttachedResource {
  const AttachedResource({required this.uri, required this.label, this.serverName, this.embedded = false});

  final String uri;
  final String label;

  /// Null when the message doesn't say (e.g. an imported transcript).
  final String? serverName;

  /// The text was read into the message (else only a link was attached).
  final bool embedded;

  /// The resources among [m]'s parts, with server names from
  /// [kMcpResourcesKey] (or the prompt's server).
  static List<AttachedResource> of(Message m) {
    final servers = <String, String>{};
    final labels = <String, String>{};
    final listed = m.metadata[kMcpResourcesKey];
    if (listed is List) {
      for (final e in listed) {
        if (e is! Map || e['uri'] is! String) continue;
        final uri = e['uri'] as String;
        if (e['serverName'] is String) servers[uri] = e['serverName'] as String;
        if (e['name'] is String) labels[uri] = e['name'] as String;
      }
    }
    final prompt = PromptSource.of(m)?.serverName;
    return [
      for (final p in m.content)
        switch (p) {
          EmbeddedResourcePart(:final uri) => AttachedResource(
              uri: uri,
              label: labels[uri] ?? _shortName(uri),
              serverName: servers[uri] ?? prompt,
              embedded: true,
            ),
          ResourceLinkPart(:final uri, :final name, :final title) => AttachedResource(
              uri: uri,
              label: labels[uri] ?? title ?? name ?? _shortName(uri),
              serverName: servers[uri] ?? prompt,
            ),
          _ => null,
        },
    ].nonNulls.toList();
  }

  /// `notes://work/today.md` → `today.md`; `notes://today.md` → `today.md`.
  static String _shortName(String uri) {
    final u = Uri.tryParse(uri);
    if (u == null) return uri;
    final seg = u.pathSegments.where((s) => s.isNotEmpty).lastOrNull;
    if (seg != null) return seg;
    return u.host.isNotEmpty ? u.host : uri;
  }
}

/// How fast a local (or timing-reporting) reply was produced, from the
/// provider's [PerfSample]. Persisted as a display hint under
/// [kReplyPerfKey].
@immutable
final class ReplyPerf {
  const ReplyPerf({this.ttftMs, this.decodeTps, this.prefillTps, this.draftAcceptRate});

  factory ReplyPerf.fromSample(PerfSample s) => ReplyPerf(
        ttftMs: s.timeToFirstTokenMs,
        decodeTps: s.decodeTokensPerSec,
        prefillTps: s.prefillTokensPerSec,
        draftAcceptRate: s.draftAcceptRate,
      );

  static ReplyPerf? fromJson(Object? j) {
    if (j is! Map) return null;
    double? d(String k) => j[k] is num ? (j[k] as num).toDouble() : null;
    final p = ReplyPerf(ttftMs: d('ttftMs'), decodeTps: d('decodeTps'), prefillTps: d('prefillTps'), draftAcceptRate: d('draftAcceptRate'));
    return p.isEmpty ? null : p;
  }

  final double? ttftMs;
  final double? decodeTps;
  final double? prefillTps;
  final double? draftAcceptRate;

  bool get isEmpty => (decodeTps == null || decodeTps! <= 0) && (ttftMs == null || ttftMs! <= 0);

  JsonMap toJson() => {
        if (ttftMs != null) 'ttftMs': ttftMs,
        if (decodeTps != null) 'decodeTps': decodeTps,
        if (prefillTps != null) 'prefillTps': prefillTps,
        if (draftAcceptRate != null) 'draftAcceptRate': draftAcceptRate,
      };

  /// "42 tok/s · TTFT 0.4 s".
  String get label => [
        if (decodeTps != null && decodeTps! > 0) '${_rate(decodeTps!)} tok/s',
        if (ttftMs != null && ttftMs! > 0) 'TTFT ${_seconds(ttftMs!)}',
      ].join(' · ');

  /// The same, spelled out, plus prefill and draft acceptance.
  String get semanticLabel => [
        if (decodeTps != null && decodeTps! > 0) 'Generated at ${_rate(decodeTps!)} tokens per second',
        if (ttftMs != null && ttftMs! > 0) 'first token after ${_seconds(ttftMs!, spoken: true)}',
        if (prefillTps != null && prefillTps! > 0) 'read the conversation at ${_rate(prefillTps!)} tokens per second',
        if (draftAcceptRate != null) '${(draftAcceptRate! * 100).round()}% of drafted tokens accepted',
      ].join(', ');

  static String _rate(double v) => v >= 10 ? '${v.round()}' : v.toStringAsFixed(1);

  static String _seconds(double ms, {bool spoken = false}) {
    if (ms < 100) return spoken ? '${ms.round()} milliseconds' : '${ms.round()} ms';
    final s = (ms / 1000).toStringAsFixed(ms < 10000 ? 1 : 0);
    return spoken ? '$s seconds' : '$s s';
  }

  @override
  bool operator ==(Object other) =>
      other is ReplyPerf &&
      other.ttftMs == ttftMs &&
      other.decodeTps == decodeTps &&
      other.prefillTps == prefillTps &&
      other.draftAcceptRate == draftAcceptRate;

  @override
  int get hashCode => Object.hash(ttftMs, decodeTps, prefillTps, draftAcceptRate);
}

/// A message the user sent.
final class UserItem extends ChatItem {
  UserItem({required this.message, required this.branch})
      : signature = '${message.id}|${message.text.hashCode}|${branch.index}/${branch.count}';

  final Message message;
  final BranchInfo branch;

  @override
  final String signature;

  @override
  String get key => 'u:${message.id}';

  String get text => message.text;

  /// Set on messages created with "edit", so the bubble can say "Edited".
  bool get isEdit => message.metadata['editOf'] != null;

  /// Set when an MCP prompt wrote this message, not the user.
  PromptSource? get promptSource => PromptSource.of(message);

  /// Resources attached to the message.
  List<AttachedResource> get resources => AttachedResource.of(message);
}

/// Optimistic stand-in for the message being sent, shown until the runner
/// has persisted the real one (a few microtasks later).
final class PendingUserItem extends ChatItem {
  PendingUserItem(this.text) : signature = 'pending|${text.hashCode}';

  final String text;

  @override
  final String signature;

  @override
  String get key => 'u:pending';
}

/// Everything the assistant did between two user messages: every model step
/// (reasoning, text, tool calls) with tool results folded into their calls.
final class AssistantTurnItem extends ChatItem {
  AssistantTurnItem({
    required this.key,
    required this.steps,
    required this.blocks,
    required this.branch,
    required this.live,
    required this.showActions,
  }) : signature = _signatureOf(key, steps, blocks, branch, live, showActions);

  @override
  final String key;

  /// The assistant messages of this turn, in order.
  final List<Message> steps;
  final List<TurnBlock> blocks;

  /// Siblings of the first step: retries of this turn.
  final BranchInfo? branch;

  /// A run is producing this turn right now; the live draft renders at its
  /// end and the action row is hidden.
  final bool live;

  /// Copy/share/retry are offered on finished turns only.
  final bool showActions;

  @override
  final String signature;

  String? get firstMessageId => steps.isEmpty ? null : steps.first.id;

  /// Text the user sees as "the reply": every text block of the turn.
  String get copyText => blocks.whereType<TextBlock>().map((b) => b.text.trim()).where((t) => t.isNotEmpty).join('\n\n');

  /// Model of the final step, for the per-turn model label.
  String? get modelId => steps.isEmpty ? null : steps.last.modelId;

  /// Error recorded on a partially streamed reply that failed.
  String? get errorText {
    final e = steps.isEmpty ? null : steps.last.metadata['error'];
    return e is String ? e : null;
  }

  /// The reply was cut off by the user or the token limit.
  String? get finishReason => steps.isEmpty ? null : steps.last.finishReason;

  /// How fast the final step was generated, when the provider said.
  ReplyPerf? get perf => steps.isEmpty ? null : ReplyPerf.fromJson(steps.last.metadata[kReplyPerfKey]);

  /// Set when an MCP prompt supplied this turn (an example reply).
  PromptSource? get promptSource => steps.isEmpty ? null : PromptSource.of(steps.first);

  static String _signatureOf(
    String key,
    List<Message> steps,
    List<TurnBlock> blocks,
    BranchInfo? branch,
    bool live,
    bool showActions,
  ) {
    final b = StringBuffer('$key|$live|$showActions|${branch?.index}/${branch?.count}');
    for (final m in steps) {
      b.write('|${m.id}:${m.content.length}:${m.finishReason}:${m.text.length}:${m.metadata['reasoningMs']}'
          ':${m.metadata[kReplyPerfKey] != null}');
    }
    b.write('|${blocks.length}');
    return b.toString();
  }
}

/// A displayable piece of an assistant turn.
@immutable
sealed class TurnBlock {
  const TurnBlock();
  String get key;
}

final class ReasoningBlock extends TurnBlock {
  const ReasoningBlock({
    required this.key,
    required this.messageId,
    required this.text,
    this.redacted = false,
    this.duration,
  });

  @override
  final String key;
  final String messageId;
  final String text;

  /// Encrypted reasoning: the header shows, the body has nothing to read.
  final bool redacted;

  /// Known for replies streamed on this device (persisted as a client hint).
  final Duration? duration;
}

final class TextBlock extends TurnBlock {
  const TextBlock({required this.key, required this.messageId, required this.text});

  @override
  final String key;
  final String messageId;
  final String text;
}

/// A resource in an assistant message (an MCP prompt's example reply).
final class ResourceBlock extends TurnBlock {
  const ResourceBlock({required this.key, required this.messageId, required this.resource});

  @override
  final String key;
  final String messageId;
  final AttachedResource resource;
}

/// Consecutive tool calls with nothing visible between them, rendered as
/// one "Ran 3 tools" group (a single call renders as a plain card).
final class ToolGroupBlock extends TurnBlock {
  const ToolGroupBlock({required this.key, required this.calls});

  @override
  final String key;
  final List<ToolCall> calls;
}

/// Lifecycle of one tool call as the user sees it.
enum ToolRunStatus {
  /// Arguments still streaming from the model.
  preparing,

  /// Waiting its turn (approval of an earlier call, or the parallel pool).
  pending,
  awaitingApproval,
  running,
  succeeded,
  failed,
  denied,
  cancelled,
}

extension ToolRunStatusX on ToolRunStatus {
  bool get isActive =>
      this == ToolRunStatus.preparing ||
      this == ToolRunStatus.pending ||
      this == ToolRunStatus.awaitingApproval ||
      this == ToolRunStatus.running;

  bool get isProblem => this == ToolRunStatus.failed;
}

/// Execution state of one tool call.
@immutable
final class ToolExecutionView {
  const ToolExecutionView({
    required this.callId,
    required this.toolName,
    required this.displayName,
    required this.status,
    this.sourceLabel,
    this.progress,
    this.progressMessage,
    this.startedAt,
    this.duration,
    this.resultText,
    this.structured,
    this.errorText,
  });

  final String callId;
  final String toolName;
  final String displayName;
  final ToolRunStatus status;
  final String? sourceLabel;

  /// 0..1 when the tool reports a total; null for indeterminate progress.
  final double? progress;
  final String? progressMessage;
  final DateTime? startedAt;
  final Duration? duration;
  final String? resultText;
  final JsonMap? structured;
  final String? errorText;

  ToolExecutionView copyWith({
    ToolRunStatus? status,
    double? progress,
    String? progressMessage,
    DateTime? startedAt,
  }) =>
      ToolExecutionView(
        callId: callId,
        toolName: toolName,
        displayName: displayName,
        status: status ?? this.status,
        sourceLabel: sourceLabel,
        progress: progress ?? this.progress,
        progressMessage: progressMessage ?? this.progressMessage,
        startedAt: startedAt ?? this.startedAt,
        duration: duration,
        resultText: resultText,
        structured: structured,
        errorText: errorText,
      );

  bool sameAs(ToolExecutionView o) =>
      o.callId == callId &&
      o.status == status &&
      o.progress == progress &&
      o.progressMessage == progressMessage &&
      o.duration == duration &&
      o.resultText == resultText &&
      o.errorText == errorText &&
      o.displayName == displayName;
}

/// Prefixes of the error results `AgentRunner` writes for calls that never
/// ran. Results carry no structured "denied" flag, so the transcript is the
/// only durable record; keep these in sync with agent_runner.dart.
const String _declinedPrefix = 'The user declined';
const String _cancelledPrefix = 'Cancelled by the user';

/// Builds display items from the active path.
///
/// Pure and synchronous: [siblings] maps a parent id to its non-draft
/// children (oldest first) and must already contain every parent on the
/// path that the caller wants branch counts for; missing entries count as
/// "no siblings". [previous] items with an identical signature are reused
/// so widget caches keyed by identity stay valid.
List<ChatItem> buildTranscriptItems({
  required List<Message> path,
  required Map<String?, List<Message>> siblings,
  required bool runActive,
  required List<ChatItem> previous,
  String? pendingUserText,
}) {
  final old = {for (final i in previous) i.key: i};
  T reuse<T extends ChatItem>(T fresh) {
    final o = old[fresh.key];
    return o is T && o.signature == fresh.signature ? o : fresh;
  }

  BranchInfo branchOf(Message m) {
    final sibs = (siblings[m.parentId] ?? const <Message>[]).where((s) => s.role == m.role).toList();
    final index = sibs.indexWhere((s) => s.id == m.id);
    return BranchInfo(messageId: m.id, index: index < 0 ? 0 : index, count: index < 0 ? 1 : sibs.length);
  }

  final items = <ChatItem>[];
  var i = 0;
  while (i < path.length) {
    final m = path[i];
    if (m.role == Role.system) {
      i++;
      continue;
    }
    if (m.role == Role.user) {
      items.add(reuse(UserItem(message: m, branch: branchOf(m))));
      i++;
      continue;
    }
    final turnKey = 'turn:${m.parentId ?? 'root'}';
    final steps = <Message>[];
    while (i < path.length && path[i].role != Role.user) {
      if (path[i].role == Role.assistant) steps.add(path[i]);
      i++;
    }
    items.add(AssistantTurnItem(
      key: turnKey,
      steps: steps,
      blocks: buildTurnBlocks(steps),
      branch: steps.isEmpty ? null : branchOf(steps.first),
      live: false,
      showActions: steps.isNotEmpty,
    ));
  }

  if (pendingUserText != null) items.add(PendingUserItem(pendingUserText));

  if (runActive) {
    final last = items.isEmpty ? null : items.last;
    if (last is AssistantTurnItem) {
      items[items.length - 1] = AssistantTurnItem(
        key: last.key,
        steps: last.steps,
        blocks: last.blocks,
        branch: last.branch,
        live: true,
        showActions: false,
      );
    } else {
      final anchor = pendingUserText != null ? 'pending' : (path.isEmpty ? 'root' : path.last.id);
      items.add(AssistantTurnItem(
        key: 'turn:$anchor',
        steps: const [],
        blocks: const [],
        branch: null,
        live: true,
        showActions: false,
      ));
    }
  }

  return [for (final item in items) item is AssistantTurnItem ? reuse(item) : item];
}

/// Flattens a turn's steps into display blocks, merging adjacent text or
/// reasoning of one message and grouping consecutive tool calls across
/// steps (nothing visible between them → one group).
List<TurnBlock> buildTurnBlocks(List<Message> steps) {
  final blocks = <TurnBlock>[];
  for (final m in steps) {
    final ms = m.metadata['reasoningMs'];
    final duration = ms is num ? Duration(milliseconds: ms.round()) : null;
    for (final (pi, part) in m.content.indexed) {
      final last = blocks.isEmpty ? null : blocks.last;
      switch (part) {
        case ReasoningPart(:final text, :final isRedacted):
          if (text.isEmpty && !isRedacted) continue;
          if (last is ReasoningBlock && last.messageId == m.id) {
            blocks[blocks.length - 1] = ReasoningBlock(
              key: last.key,
              messageId: m.id,
              text: last.text.isEmpty ? text : (text.isEmpty ? last.text : '${last.text}\n\n$text'),
              redacted: last.redacted && isRedacted,
              duration: duration,
            );
          } else {
            blocks.add(ReasoningBlock(
              key: 'r:${m.id}:$pi',
              messageId: m.id,
              text: text,
              redacted: isRedacted && text.isEmpty,
              duration: duration,
            ));
          }
        case TextPart(:final text):
          if (text.trim().isEmpty) continue;
          if (last is TextBlock && last.messageId == m.id) {
            blocks[blocks.length - 1] = TextBlock(key: last.key, messageId: m.id, text: last.text + text);
          } else {
            blocks.add(TextBlock(key: 't:${m.id}:$pi', messageId: m.id, text: text));
          }
        case ToolCallPart(:final call):
          if (last is ToolGroupBlock) {
            blocks[blocks.length - 1] = ToolGroupBlock(key: last.key, calls: [...last.calls, call]);
          } else {
            blocks.add(ToolGroupBlock(key: 'g:${call.id}', calls: [call]));
          }
        case EmbeddedResourcePart() || ResourceLinkPart():
          final resources = AttachedResource.of(m.copyWith(content: [part]));
          if (resources.isEmpty) continue;
          blocks.add(ResourceBlock(key: 'res:${m.id}:$pi', messageId: m.id, resource: resources.single));
        default:
          // Images and MCP Apps views arrive in later milestones.
          continue;
      }
    }
  }
  return blocks;
}

/// Reconstructs finished tool executions from the tool messages on [path].
/// Calls without a result yet are left to the live event stream.
Map<String, ToolExecutionView> toolViewsFromPath(
  List<Message> path, {
  required ToolDefinition? Function(String name) lookup,
  String Function(ToolSource? source)? sourceLabel,
  Map<String, ToolExecutionView> previous = const {},
}) {
  final out = <String, ToolExecutionView>{};
  for (final m in path) {
    if (m.role != Role.tool) continue;
    for (final r in m.toolResults) {
      // A proxied call (`call_tool`) names the tool that actually ran.
      final target = r.meta[ToolResultPart.metaTool];
      final def = target is String ? lookup(target) : lookup(r.toolName);
      final text = r.text;
      final status = !r.isError
          ? ToolRunStatus.succeeded
          : text.startsWith(_declinedPrefix)
              ? ToolRunStatus.denied
              : text.startsWith(_cancelledPrefix)
                  ? ToolRunStatus.cancelled
                  : ToolRunStatus.failed;
      final view = ToolExecutionView(
        callId: r.callId,
        toolName: r.toolName,
        displayName: def?.displayName ?? (target is String ? target : r.toolName),
        sourceLabel: sourceLabel?.call(def?.source),
        status: status,
        duration: r.durationMs == null ? null : Duration(milliseconds: r.durationMs!),
        resultText: r.isError ? null : text,
        structured: r.structured,
        errorText: r.isError ? text : null,
      );
      final prev = previous[r.callId];
      out[r.callId] = prev != null && prev.sameAs(view) ? prev : view;
    }
  }
  return out;
}
