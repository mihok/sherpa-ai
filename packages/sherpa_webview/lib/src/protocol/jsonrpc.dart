/// JSON-RPC 2.0 messages exchanged with a View (R03 §6), validated
/// strictly on input: anything malformed is dropped, never repaired.
library;

import 'package:meta/meta.dart';

/// JSON-RPC error codes the bridge uses.
abstract final class RpcCode {
  static const int parseError = -32700;
  static const int invalidRequest = -32600;
  static const int methodNotFound = -32601;
  static const int invalidParams = -32602;
  static const int internalError = -32603;

  /// MCP Apps uses -32000 for host-side failures (`ui/open-link` etc.).
  static const int hostError = -32000;
}

/// A message from the View, after shape validation.
@immutable
sealed class ViewMessage {
  const ViewMessage();

  /// Validates [m]: `jsonrpc: "2.0"`, an id that is a string (≤ 128 chars)
  /// or a safe integer, a method name ≤ 128 chars, object params. Returns
  /// null for anything else.
  static ViewMessage? parse(Object? raw) {
    if (raw is! Map) return null;
    final m = raw.cast<Object?, Object?>();
    if (m['jsonrpc'] != '2.0') return null;
    final Object? method = m['method'];
    final hasId = m.containsKey('id');
    final Object? id = m['id'];
    if (hasId && !_validId(id)) return null;
    final Object? params = m['params'];
    if (params != null && params is! Map) return null;
    final p = params is Map ? params.cast<String, Object?>() : const <String, Object?>{};
    if (method != null) {
      if (method is! String || method.isEmpty || method.length > 128) return null;
      return hasId ? ViewRequest(id!, method, p) : ViewNotification(method, p);
    }
    if (!hasId) return null;
    if (m.containsKey('result')) {
      final Object? r = m['result'];
      return ViewResponse(id!, result: r is Map ? r.cast<String, Object?>() : const {});
    }
    final Object? e = m['error'];
    if (e is Map) {
      return ViewResponse(id!, error: e.cast<String, Object?>());
    }
    return null;
  }

  static bool _validId(Object? id) =>
      (id is String && id.isNotEmpty && id.length <= 128) ||
      (id is int && id.abs() <= 9007199254740991);
}

final class ViewRequest extends ViewMessage {
  const ViewRequest(this.id, this.method, this.params);
  final Object id;
  final String method;
  final Map<String, Object?> params;
}

final class ViewNotification extends ViewMessage {
  const ViewNotification(this.method, this.params);
  final String method;
  final Map<String, Object?> params;
}

final class ViewResponse extends ViewMessage {
  const ViewResponse(this.id, {this.result, this.error});
  final Object id;
  final Map<String, Object?>? result;
  final Map<String, Object?>? error;
}

/// Outbound message builders (strict SDK shapes, R03 §6.2).
abstract final class Rpc {
  static Map<String, Object?> result(Object id, Map<String, Object?> result) =>
      {'jsonrpc': '2.0', 'id': id, 'result': result};

  static Map<String, Object?> error(Object id, int code, String message) => {
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': code, 'message': message},
      };

  static Map<String, Object?> notification(String method, [Map<String, Object?>? params]) =>
      {'jsonrpc': '2.0', 'method': method, 'params': params ?? const <String, Object?>{}};

  static Map<String, Object?> request(Object id, String method, [Map<String, Object?>? params]) =>
      {'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params ?? const <String, Object?>{}};
}

/// Method names (`spec.types.d.ts` constants).
abstract final class McpAppMethods {
  static const String initialize = 'ui/initialize';
  static const String initialized = 'ui/notifications/initialized';
  static const String toolInput = 'ui/notifications/tool-input';
  static const String toolInputPartial = 'ui/notifications/tool-input-partial';
  static const String toolResult = 'ui/notifications/tool-result';
  static const String toolCancelled = 'ui/notifications/tool-cancelled';
  static const String hostContextChanged = 'ui/notifications/host-context-changed';
  static const String sizeChanged = 'ui/notifications/size-changed';
  static const String requestTeardown = 'ui/notifications/request-teardown';
  static const String resourceTeardown = 'ui/resource-teardown';
  static const String openLink = 'ui/open-link';
  static const String message = 'ui/message';
  static const String updateModelContext = 'ui/update-model-context';
  static const String requestDisplayMode = 'ui/request-display-mode';
  static const String downloadFile = 'ui/download-file';
  static const String toolsCall = 'tools/call';
  static const String resourcesRead = 'resources/read';
  static const String ping = 'ping';
  static const String log = 'notifications/message';
  static const String progress = 'notifications/progress';
  static const String cancelled = 'notifications/cancelled';

  /// Sent by the shell's View prelude when the user activates a plain
  /// `<a href>`: handled exactly like `ui/open-link` (scheme check, then the
  /// user's confirmation), but it has no response.
  static const String linkActivated = 'sherpa/notifications/link-activated';
}

/// The View↔Host protocol versions the bridge speaks.
const List<String> supportedProtocolVersions = ['2026-01-26'];
const String latestProtocolVersion = '2026-01-26';
