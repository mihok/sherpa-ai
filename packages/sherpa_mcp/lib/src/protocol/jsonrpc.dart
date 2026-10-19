/// JSON-RPC 2.0 as MCP profiles it.
///
/// MCP basic/index.md §Messages: ids are `string | number` and MUST NOT be
/// `null`; notifications carry no id and are never answered; every result
/// is an object. Batching was removed in 2025-06-18, so Sherpa never sends
/// arrays — [JsonRpcMessage.decodeBody] only tolerates an array body when
/// a caller explicitly allows it for a 2025-03-26 peer (R01 §2).
library;

import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart' show JsonMap, normalizeJson;

/// Thrown when bytes on the wire are not a valid MCP JSON-RPC message.
final class JsonRpcFormatException implements Exception {
  const JsonRpcFormatException(this.message);

  final String message;

  @override
  String toString() => 'JsonRpcFormatException: $message';
}

/// A request id: a string or an integer (MCP forbids `null`).
///
/// Integral JSON numbers decode to `int`, so `1` and `1.0` are the same id.
/// Fractional ids are accepted from peers (JSON-RPC only says they SHOULD
/// NOT be used) but Sherpa never mints them.
@immutable
final class JsonRpcId {
  const JsonRpcId._(this.value);

  const JsonRpcId.string(String this.value);

  const JsonRpcId.int(int this.value);

  /// Parses an id field; returns null for `null`, absent or non-scalar ids.
  static JsonRpcId? tryParse(Object? raw) => switch (raw) {
        final String s => JsonRpcId._(s),
        final int i => JsonRpcId._(i),
        final double d when d.isFinite => JsonRpcId._(d == d.truncateToDouble() ? d.toInt() : d),
        _ => null,
      };

  /// `String`, `int` or (from peers only) a fractional `double`.
  final Object value;

  Object toJson() => value;

  @override
  bool operator ==(Object other) => other is JsonRpcId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value is String ? '"$value"' : '$value';
}

/// A JSON-RPC error object (`{code, message, data?}`).
@immutable
final class JsonRpcError {
  const JsonRpcError(this.code, this.message, {this.data});

  factory JsonRpcError.fromJson(JsonMap j) {
    final code = j['code'];
    if (code is! num || code != code.truncate()) {
      throw const JsonRpcFormatException('error.code must be an integer');
    }
    final message = j['message'];
    return JsonRpcError(code.toInt(), message is String ? message : '', data: j['data']);
  }

  // JSON-RPC 2.0 reserved codes.
  static const int parseError = -32700;
  static const int invalidRequest = -32600;
  static const int methodNotFound = -32601;
  static const int invalidParams = -32602;
  static const int internalError = -32603;

  /// 2026-07-28 §Error codes: header/body mismatch (HTTP 400).
  static const int headerMismatch = -32020;

  /// 2026-07-28: `data.requiredCapabilities` names what was missing (HTTP 400).
  static const int missingRequiredClientCapability = -32021;

  /// 2026-07-28: `data: {supported: string[], requested: string}` (HTTP 400).
  static const int unsupportedProtocolVersion = -32022;

  /// Legacy (≤ 2025-11-25) resource-not-found; modern servers use -32602.
  static const int legacyResourceNotFound = -32002;

  /// 2025-11-25 only: URL elicitation required (`data.elicitations[]`).
  static const int urlElicitationRequired = -32042;

  /// The conventional "user rejected" code for declined sampling (spec
  /// client/sampling.md §Error Handling example).
  static const int userRejected = -1;

  final int code;
  final String message;
  final Object? data;

  JsonMap toJson() => {'code': code, 'message': message, if (data != null) 'data': data};

  @override
  String toString() => 'JsonRpcError($code, $message)';
}

/// One MCP JSON-RPC message.
@immutable
sealed class JsonRpcMessage {
  const JsonRpcMessage();

  JsonMap toJson();

  /// Compact JSON with no raw newlines (safe for newline-delimited framing).
  String encode() => jsonEncode(toJson());

  /// Validates a decoded JSON value as a single message.
  static JsonRpcMessage fromJson(Object? json) {
    if (json is! Map) throw const JsonRpcFormatException('message is not a JSON object');
    final m = (normalizeJson(json)! as Map).cast<String, Object?>();
    if (m['jsonrpc'] != '2.0') throw const JsonRpcFormatException('jsonrpc must be "2.0"');
    final method = m['method'];
    final params = m['params'];
    if (params != null && params is! Map) {
      throw const JsonRpcFormatException('params must be an object');
    }
    final p = (params as Map?)?.cast<String, Object?>();
    if (method != null) {
      if (method is! String || method.isEmpty) throw const JsonRpcFormatException('method must be a string');
      if (!m.containsKey('id')) return JsonRpcNotification(method, p);
      final id = JsonRpcId.tryParse(m['id']);
      if (id == null) throw const JsonRpcFormatException('request id must be a string or number');
      return JsonRpcRequest(id, method, p);
    }
    final hasResult = m.containsKey('result');
    final hasError = m.containsKey('error');
    if (hasResult == hasError) {
      throw const JsonRpcFormatException('response must carry exactly one of result or error');
    }
    if (hasError) {
      final e = m['error'];
      if (e is! Map) throw const JsonRpcFormatException('error must be an object');
      return JsonRpcErrorResponse(JsonRpcId.tryParse(m['id']), JsonRpcError.fromJson(e.cast<String, Object?>()));
    }
    final id = JsonRpcId.tryParse(m['id']);
    if (id == null) throw const JsonRpcFormatException('result response needs a string or number id');
    final r = m['result'];
    if (r is! Map) throw const JsonRpcFormatException('MCP results are objects');
    return JsonRpcResult(id, r.cast<String, Object?>());
  }

  /// Decodes one message from [text].
  static JsonRpcMessage decode(String text) {
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException catch (e) {
      throw JsonRpcFormatException('invalid JSON: ${e.message}');
    }
    return fromJson(json);
  }

  /// Decodes an HTTP or SSE body. A JSON array is accepted only when
  /// [allowBatch] is set (a 2025-03-26 peer may batch); Sherpa itself
  /// never sends one.
  static List<JsonRpcMessage> decodeBody(String text, {bool allowBatch = false}) {
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException catch (e) {
      throw JsonRpcFormatException('invalid JSON: ${e.message}');
    }
    if (json is List) {
      if (!allowBatch) throw const JsonRpcFormatException('JSON-RPC batches are not allowed');
      return [for (final e in json) fromJson(e)];
    }
    return [fromJson(json)];
  }
}

final class JsonRpcRequest extends JsonRpcMessage {
  const JsonRpcRequest(this.id, this.method, [this.params]);

  final JsonRpcId id;
  final String method;
  final JsonMap? params;

  @override
  JsonMap toJson() => {'jsonrpc': '2.0', 'id': id.toJson(), 'method': method, if (params != null) 'params': params};

  @override
  String toString() => 'JsonRpcRequest($id, $method)';
}

final class JsonRpcNotification extends JsonRpcMessage {
  const JsonRpcNotification(this.method, [this.params]);

  final String method;
  final JsonMap? params;

  @override
  JsonMap toJson() => {'jsonrpc': '2.0', 'method': method, if (params != null) 'params': params};

  @override
  String toString() => 'JsonRpcNotification($method)';
}

/// A response: [JsonRpcResult] or [JsonRpcErrorResponse].
sealed class JsonRpcResponse extends JsonRpcMessage {
  const JsonRpcResponse();

  /// Null only on an error response whose request id was unreadable.
  JsonRpcId? get id;
}

final class JsonRpcResult extends JsonRpcResponse {
  const JsonRpcResult(this.id, this.result);

  @override
  final JsonRpcId id;
  final JsonMap result;

  @override
  JsonMap toJson() => {'jsonrpc': '2.0', 'id': id.toJson(), 'result': result};

  @override
  String toString() => 'JsonRpcResult($id)';
}

final class JsonRpcErrorResponse extends JsonRpcResponse {
  const JsonRpcErrorResponse(this.id, this.error);

  @override
  final JsonRpcId? id;
  final JsonRpcError error;

  @override
  JsonMap toJson() => {'jsonrpc': '2.0', 'id': id?.toJson(), 'error': error.toJson()};

  @override
  String toString() => 'JsonRpcErrorResponse($id, ${error.code})';
}
