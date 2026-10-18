import 'package:meta/meta.dart';

import '../common/json.dart';
import '../context/overlay.dart';
import '../model/message.dart';
import 'checkpoint.dart';
import 'plan.dart';

@immutable
final class SessionRecord {
  const SessionRecord({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.providerId,
    this.modelId,
    this.activeLeafId,
    this.systemPrompt,
    this.handoffFromSessionId,
    this.archived = false,
    this.settings = const {},
  });

  factory SessionRecord.fromJson(JsonMap j) => SessionRecord(
        id: j.req<String>('id'),
        title: j.req<String>('title'),
        createdAt: DateTime.parse(j.req<String>('createdAt')),
        updatedAt: DateTime.parse(j.req<String>('updatedAt')),
        providerId: j.opt<String>('providerId'),
        modelId: j.opt<String>('modelId'),
        activeLeafId: j.opt<String>('activeLeafId'),
        systemPrompt: j.opt<String>('systemPrompt'),
        handoffFromSessionId: j.opt<String>('handoffFromSessionId'),
        archived: j.opt<bool>('archived') ?? false,
        settings: j.optObj('settings') ?? const {},
      );

  final String id;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? providerId;
  final String? modelId;

  /// Leaf of the currently selected branch.
  final String? activeLeafId;
  final String? systemPrompt;

  /// Set when this session was started from another session's handoff.
  final String? handoffFromSessionId;
  final bool archived;

  /// Per-session overrides (enabled tools, params, context settings).
  final JsonMap settings;

  SessionRecord copyWith({
    String? title,
    DateTime? updatedAt,
    String? providerId,
    String? modelId,
    String? activeLeafId,
    String? systemPrompt,
    bool? archived,
    JsonMap? settings,
  }) =>
      SessionRecord(
        id: id,
        title: title ?? this.title,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        providerId: providerId ?? this.providerId,
        modelId: modelId ?? this.modelId,
        activeLeafId: activeLeafId ?? this.activeLeafId,
        systemPrompt: systemPrompt ?? this.systemPrompt,
        handoffFromSessionId: handoffFromSessionId,
        archived: archived ?? this.archived,
        settings: settings ?? this.settings,
      );

  JsonMap toJson() => compact({
        'id': id,
        'title': title,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'updatedAt': updatedAt.toUtc().toIso8601String(),
        'providerId': providerId,
        'modelId': modelId,
        'activeLeafId': activeLeafId,
        'systemPrompt': systemPrompt,
        'handoffFromSessionId': handoffFromSessionId,
        'archived': archived ? true : null,
        'settings': settings.isEmpty ? null : settings,
      });
}

enum AuditKind {
  toolCall,
  approval,
  dataEgress,
  contextAction,
  sampling,
  elicitation,
  handoff,
  engine,
  error,
}

/// Append-only per-session audit trail. Never contains secrets.
@immutable
final class AuditEntry {
  const AuditEntry({
    required this.id,
    required this.sessionId,
    required this.at,
    required this.kind,
    required this.summary,
    this.data = const {},
  });

  factory AuditEntry.fromJson(JsonMap j) => AuditEntry(
        id: j.req<String>('id'),
        sessionId: j.req<String>('sessionId'),
        at: DateTime.parse(j.req<String>('at')),
        kind: AuditKind.values.byName(j.req<String>('kind')),
        summary: j.req<String>('summary'),
        data: j.optObj('data') ?? const {},
      );

  final String id;
  final String sessionId;
  final DateTime at;
  final AuditKind kind;
  final String summary;
  final JsonMap data;

  JsonMap toJson() => {
        'id': id,
        'sessionId': sessionId,
        'at': at.toUtc().toIso8601String(),
        'kind': kind.name,
        'summary': summary,
        if (data.isNotEmpty) 'data': data,
      };
}

/// Persistence boundary for sessions. Implemented with Drift/SQLite in
/// `sherpa_data`; [InMemorySessionStore] serves tests and evals.
///
/// All writes are durable when the returned future completes: the agent
/// loop relies on that for crash-safe checkpoints.
abstract interface class SessionStore {
  Future<SessionRecord> putSession(SessionRecord session);
  Future<SessionRecord?> getSession(String id);
  Future<List<SessionRecord>> listSessions({bool includeArchived = false});
  Future<void> deleteSession(String id);

  /// Upsert: streaming drafts are re-written in place until finalized.
  Future<void> putMessage(String sessionId, Message message);
  Future<Message?> getMessage(String sessionId, String messageId);

  /// Root → [leafId] along parent links.
  Future<List<Message>> path(String sessionId, String leafId);
  Future<List<Message>> children(String sessionId, String? parentId);

  Future<void> putOverlay(String sessionId, ContextOverlay overlay);
  Future<void> removeOverlay(String sessionId, String overlayId);
  Future<List<ContextOverlay>> overlays(String sessionId);

  Future<void> putPlan(String sessionId, Plan plan);
  Future<Plan?> getPlan(String sessionId);

  Future<void> putCheckpoint(RunCheckpoint checkpoint);
  Future<RunCheckpoint?> getCheckpoint(String sessionId);

  Future<void> appendAudit(AuditEntry entry);
  Future<List<AuditEntry>> audit(String sessionId, {int? limit});
}
