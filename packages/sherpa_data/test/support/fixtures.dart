import 'dart:convert';
import 'dart:typed_data';

import 'package:sherpa_core/sherpa_core.dart';

/// Shared, deterministic test data. Times carry microseconds on purpose:
/// they must survive every store at full precision.
final DateTime t0 = DateTime.utc(2026, 10, 18, 12, 0, 0, 123, 456);

DateTime at(int seconds) => t0.add(Duration(seconds: seconds));

/// Canonical JSON text, for "is it byte-for-byte the same object" checks.
String canon(Object? json) => jsonEncode(json);

SessionRecord session(
  String id, {
  int updated = 0,
  bool archived = false,
  String title = 'Chat',
}) =>
    SessionRecord(
      id: id,
      title: title,
      createdAt: at(0),
      updatedAt: at(updated),
      archived: archived,
    );

Message msg(
  String id, {
  String? parent,
  int t = 0,
  String text = 'hello',
  Role role = Role.user,
}) =>
    Message(
      id: id,
      parentId: parent,
      role: role,
      content: [TextPart(text)],
      createdAt: at(t),
    );

/// A message using every content part type and every optional field.
Message richMessage(String id, {String? parent}) => Message(
      id: id,
      parentId: parent,
      role: Role.assistant,
      kind: MessageKind.summary,
      pinned: true,
      createdAt: at(7),
      providerId: 'anthropic',
      modelId: 'claude-x',
      finishReason: 'tool_use',
      usage: const Usage(
        inputTokens: 11,
        outputTokens: 22,
        cacheReadTokens: 3,
        cacheWriteTokens: 4,
        reasoningTokens: 5,
      ),
      metadata: const {
        'attachments': ['a.png', 'b.pdf'],
        'client': {'hint': 'x', 'n': 1.5, 'flag': false, 'none': null},
      },
      content: [
        const TextPart('plain, "quoted", back\\slash, nul\u0000, emoji 😀, RTL שלום, ☃'),
        ImagePart(mimeType: 'image/png', data: Uint8List.fromList([0, 1, 2, 254, 255])),
        ImagePart(mimeType: 'image/jpeg', uri: Uri.parse('file:///sandbox/img.jpg')),
        AudioPart(mimeType: 'audio/wav', uri: Uri.parse('file:///sandbox/a.wav')),
        AudioPart(mimeType: 'audio/ogg', data: Uint8List.fromList([9, 8, 7])),
        const ResourceLinkPart(
          uri: 'https://example.com/r',
          name: 'r',
          title: 'Resource',
          description: 'desc',
          mimeType: 'text/plain',
          size: 42,
        ),
        const EmbeddedResourcePart(uri: 'mem://text', mimeType: 'text/markdown', text: '# hi'),
        EmbeddedResourcePart(uri: 'mem://blob', blob: Uint8List.fromList([5, 6, 7])),
        const ReasoningPart(text: 'thinking…', signature: 'sig==', providerId: 'anthropic'),
        const ReasoningPart(text: '', redactedData: 'opaque-blob'),
        const ToolCallPart(ToolCall(
          id: 'call_1',
          name: 'search',
          arguments: {
            'q': 'dart',
            'filters': {'lang': ['en', 'de'], 'max': 10},
          },
        )),
        ToolResultPart(
          callId: 'call_1',
          toolName: 'search',
          content: [
            const TextPart('3 hits'),
            ImagePart(mimeType: 'image/gif', data: Uint8List.fromList([71, 73, 70])),
            const ResourceLinkPart(uri: 'file:///hit.txt'),
          ],
          structured: const {
            'hits': [
              {'title': 'a', 'score': 0.9},
            ],
          },
          isError: true,
          uiResourceUri: 'ui://search/view',
          durationMs: 1234,
        ),
        const UiResourcePart(resourceUri: 'ui://search/view', serverId: 'srv', callId: 'call_1'),
        const UnknownPart({
          'type': 'hologram',
          'payload': {'x': 1, 'y': [true, null]},
        }),
      ],
    );

List<ContextOverlay> sampleOverlays() => [
      ToolOutputElided(
        id: 'o-elide',
        createdAt: at(30),
        reason: 'stale tool output',
        tokensSaved: 1200,
        messageId: 'm1',
        callId: 'call_1',
        stub: '[elided]',
      ),
      PayloadTruncated(
        id: 'o-trunc',
        createdAt: at(10),
        reason: 'large payload',
        tokensSaved: 800,
        messageId: 'm2',
        partIndex: 2,
        replacement: 'head…tail',
      ),
      CompactedRange(
        id: 'o-compact',
        createdAt: at(20),
        reason: '80% of window',
        tokensSaved: 9000,
        fromMessageId: 'm1',
        toMessageId: 'm9',
        strategyId: 'llm',
        transcriptRef: 'transcripts/s1/o-compact.jsonl',
        // Only long-standing fields: the summary schema is still evolving in
        // sherpa_core, and the store persists whatever toJson() emits anyway.
        summary: const CompactionSummary(
          goal: 'ship M1',
          decisions: ['drift'],
          constraints: ['offline'],
          openTasks: ['tests'],
          keyFacts: ['sqlite3mc'],
          userPreferences: ['terse'],
          notes: 'n',
        ),
      ),
    ];

Plan samplePlan({String task = 'ship', int updated = 0}) => Plan(
      task: task,
      updatedAt: at(updated),
      items: const [
        PlanItem(id: 'p1', title: 'schema', status: PlanStatus.done),
        PlanItem(id: 'p2', title: 'store', status: PlanStatus.inProgress, notes: 'contract'),
        PlanItem(id: 'p3', title: 'docs'),
      ],
    );

RunCheckpoint sampleCheckpoint(String sessionId, {String runId = 'run_1', RunPhase phase = RunPhase.executingTools}) =>
    RunCheckpoint(
      sessionId: sessionId,
      runId: runId,
      phase: phase,
      step: 3,
      updatedAt: at(40),
      leafMessageId: 'm2',
      draftMessageId: 'm3',
      pendingCalls: const [
        PendingCall(callId: 'c1', toolName: 'search', status: PendingCallStatus.running),
        PendingCall(callId: 'c2', toolName: 'write', status: PendingCallStatus.approved),
      ],
      providerId: 'openai',
      modelId: 'gpt-x',
      error: phase == RunPhase.failed ? 'boom' : null,
    );

AuditEntry auditEntry(String sessionId, String id, int t, {AuditKind kind = AuditKind.toolCall}) => AuditEntry(
      id: id,
      sessionId: sessionId,
      at: at(t),
      kind: kind,
      summary: 'entry $id',
      data: {
        'tool': 'search',
        'args': {'q': id},
      },
    );
