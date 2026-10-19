/// The Tasks extension, `io.modelcontextprotocol/tasks` (ext-tasks schema
/// 2026-07-28; R01 §8): `CreateTaskResult` (`resultType: "task"`),
/// `tasks/get` polling honouring `pollIntervalMs`, `tasks/update` for input
/// and `tasks/cancel`. `tasks/list` and `tasks/result` do not exist in M.
library;

import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart' show FormatError, JsonMap, compact;

import 'json_read.dart';
import 'jsonrpc.dart';

enum McpTaskStatus {
  working,
  inputRequired,
  completed,
  failed,
  cancelled;

  static McpTaskStatus? tryParse(Object? v) => switch (v) {
        'working' => working,
        'input_required' => inputRequired,
        'completed' => completed,
        'failed' => failed,
        'cancelled' => cancelled,
        _ => null,
      };

  /// Terminal states never change.
  bool get isTerminal => this == completed || this == failed || this == cancelled;
}

/// A `Task` / `DetailedTask` as returned by `tasks/get` or carried flat on
/// a `CreateTaskResult`.
@immutable
final class McpTask {
  const McpTask({
    required this.taskId,
    required this.status,
    required this.raw,
    this.statusMessage,
    this.createdAt,
    this.lastUpdatedAt,
    this.ttlMs,
    this.pollIntervalMs,
    this.inputRequests,
    this.result,
    this.error,
  });

  factory McpTask.fromJson(JsonMap j) {
    final id = reqString(j, 'taskId', 'task');
    final status = McpTaskStatus.tryParse(j['status']);
    if (status == null) throw FormatError('task $id: unknown status ${j['status']}');
    final e = asMap(j['error']);
    return McpTask(
      taskId: id,
      status: status,
      statusMessage: asString(j['statusMessage']),
      createdAt: DateTime.tryParse(asString(j['createdAt']) ?? ''),
      lastUpdatedAt: DateTime.tryParse(asString(j['lastUpdatedAt']) ?? ''),
      ttlMs: asInt(j['ttlMs']),
      pollIntervalMs: asInt(j['pollIntervalMs']),
      inputRequests: asMap(j['inputRequests']),
      result: asMap(j['result']),
      error: e == null ? null : _error(e),
      raw: j,
    );
  }

  static JsonRpcError _error(JsonMap e) {
    try {
      return JsonRpcError.fromJson(e);
    } on JsonRpcFormatException {
      return JsonRpcError(JsonRpcError.internalError, asString(e['message']) ?? 'task failed', data: e['data']);
    }
  }

  final String taskId;
  final McpTaskStatus status;

  /// Untrusted server text.
  final String? statusMessage;
  final DateTime? createdAt;
  final DateTime? lastUpdatedAt;

  /// Null means unlimited.
  final int? ttlMs;
  final int? pollIntervalMs;

  /// `input_required` only.
  final JsonMap? inputRequests;

  /// `completed` only: the original request's result.
  final JsonMap? result;

  /// `failed` only.
  final JsonRpcError? error;
  final JsonMap raw;
}

/// A durable reference to a server-side task, for resuming after process
/// death (clients SHOULD persist task ids). Persist [toJson] before the app
/// can be suspended; [McpConnection.resumeToolTask] picks it up again.
@immutable
final class McpTaskHandle {
  const McpTaskHandle({
    required this.serverId,
    required this.taskId,
    required this.method,
    required this.createdAt,
    this.name,
    this.pollIntervalMs,
    this.ttlMs,
  });

  factory McpTaskHandle.fromJson(JsonMap j) => McpTaskHandle(
        serverId: reqString(j, 'serverId', 'task handle'),
        taskId: reqString(j, 'taskId', 'task handle'),
        method: reqString(j, 'method', 'task handle'),
        name: asString(j['name']),
        createdAt: DateTime.parse(reqString(j, 'createdAt', 'task handle')),
        pollIntervalMs: asInt(j['pollIntervalMs']),
        ttlMs: asInt(j['ttlMs']),
      );

  final String serverId;
  final String taskId;

  /// The request that created it (`tools/call`).
  final String method;

  /// Tool name for `tools/call`.
  final String? name;
  final DateTime createdAt;
  final int? pollIntervalMs;
  final int? ttlMs;

  JsonMap toJson() => compact({
        'serverId': serverId,
        'taskId': taskId,
        'method': method,
        'name': name,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'pollIntervalMs': pollIntervalMs,
        'ttlMs': ttlMs,
      });
}
