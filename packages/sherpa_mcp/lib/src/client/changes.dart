/// Events on `McpConnection.changes`.
library;

import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart' show JsonMap;

import '../protocol/jsonrpc.dart';
import '../protocol/tasks.dart';
import '../protocol/types.dart';

/// Something changed on the server, or about the connection.
@immutable
sealed class McpChange {
  const McpChange();
}

/// `notifications/tools/list_changed`. The cached list is already
/// invalidated; the router re-lists and re-checks its pinned hashes (it
/// should do so on every list, not only on this event: R11 §9.7).
/// [resync] marks a synthetic event after a listen stream was re-opened
/// (notifications may have been missed while it was down).
final class McpToolsListChanged extends McpChange {
  const McpToolsListChanged({this.resync = false});

  final bool resync;
}

final class McpPromptsListChanged extends McpChange {
  const McpPromptsListChanged({this.resync = false});

  final bool resync;
}

final class McpResourcesListChanged extends McpChange {
  const McpResourcesListChanged({this.resync = false});

  final bool resync;
}

/// `notifications/resources/updated`; [uri] may be a sub-resource of a
/// subscribed URI.
final class McpResourceUpdated extends McpChange {
  const McpResourceUpdated(this.uri);

  final String uri;
}

/// `notifications/message`. [data] is untrusted: never show it to the model.
final class McpLogMessage extends McpChange {
  const McpLogMessage({required this.level, required this.data, this.logger, this.requestId});

  final McpLogLevel level;
  final Object? data;
  final String? logger;

  /// The request whose stream carried it (2026-07-28 logs are request-scoped).
  final JsonRpcId? requestId;
}

/// A Tasks-extension status update (from polling or `notifications/tasks`).
final class McpTaskStatusChanged extends McpChange {
  const McpTaskStatusChanged(this.task);

  final McpTask task;
}

/// Legacy `notifications/elicitation/complete` for a URL elicitation.
final class McpElicitationCompleted extends McpChange {
  const McpElicitationCompleted(this.elicitationId);

  final String elicitationId;
}

/// What a listen stream delivers (the server's acknowledgement in M; the
/// advertised capabilities in L).
@immutable
final class McpListenAck {
  const McpListenAck({
    this.toolsListChanged = false,
    this.promptsListChanged = false,
    this.resourcesListChanged = false,
    this.resourceSubscriptions = const [],
  });

  final bool toolsListChanged;
  final bool promptsListChanged;
  final bool resourcesListChanged;
  final List<String> resourceSubscriptions;
}

/// The change feed started, stopped or was re-established.
final class McpListenStateChanged extends McpChange {
  const McpListenStateChanged({required this.active, this.ack, this.error});

  final bool active;
  final McpListenAck? ack;

  /// Why it stopped, when it was not asked to.
  final Object? error;
}

/// The transport went away (HTTP+SSE stream ended, in-process channel
/// closed). Pending requests failed; reconnect to continue.
final class McpConnectionLost extends McpChange {
  const McpConnectionLost(this.reason);

  final String reason;
}

/// Developer-facing information for the logs / debug console: dropped
/// tools, ignored protocol violations, re-initializations.
final class McpDiagnostic extends McpChange {
  const McpDiagnostic(this.message, {this.detail});

  final String message;
  final JsonMap? detail;
}
