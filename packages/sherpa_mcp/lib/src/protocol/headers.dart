/// 2026-07-28 Streamable HTTP request headers derived from the body.
///
/// basic/transports/streamable-http.md §Standard Request Headers and
/// §Custom Headers (SEP-2243): `Mcp-Method` on every request, `Mcp-Name`
/// mirroring `params.name` / `params.uri` (and `params.taskId` for the
/// Tasks extension's methods), and one `Mcp-Param-{Name}` per present
/// `x-mcp-header` argument. Values that are not safe plain ASCII use the
/// `=?base64?…?=` sentinel encoding (§Value Encoding).
library;

import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart' show JsonMap;

/// Header names, as the spec spells them (HTTP names are case-insensitive).
abstract final class McpHeaders {
  static const String protocolVersion = 'MCP-Protocol-Version';
  static const String method = 'Mcp-Method';
  static const String name = 'Mcp-Name';
  static const String paramPrefix = 'Mcp-Param-';
  static const String sessionId = 'Mcp-Session-Id';
  static const String lastEventId = 'Last-Event-ID';

  /// Headers the transport derives itself; configuration and per-call
  /// headers may never set them (a mismatch is a 400 `-32020`).
  static const Set<String> reserved = {
    'accept',
    'authorization',
    'content-type',
    'content-length',
    'host',
    'last-event-id',
    'mcp-method',
    'mcp-name',
    'mcp-protocol-version',
    'mcp-session-id',
  };

  /// Whether a configured header [name] collides with one the transport owns.
  static bool isReserved(String name) {
    final n = name.toLowerCase();
    return reserved.contains(n) || n.startsWith('mcp-param-');
  }

  /// Methods whose `Mcp-Name` mirrors a params field (TS v2
  /// `MCP_NAME_HEADER_SOURCE`; the `tasks/*` rows come from SEP-2663).
  static const Map<String, String> nameSource = {
    'tools/call': 'name',
    'prompts/get': 'name',
    'resources/read': 'uri',
    'tasks/get': 'taskId',
    'tasks/update': 'taskId',
    'tasks/cancel': 'taskId',
  };
}

const String _sentinelPrefix = '=?base64?';
const String _sentinelSuffix = '?=';

/// Encodes [value] for an `Mcp-Name` / `Mcp-Param-*` header.
///
/// Passed through unchanged when it is non-empty visible ASCII (plus tab)
/// without leading/trailing whitespace and does not itself look like the
/// sentinel; otherwise `=?base64?<base64(utf8)>?=` with standard padded
/// base64. An empty value is encoded too, because intermediaries may drop
/// empty header fields (same choice as the TS v2 client).
String encodeMcpHeaderValue(String value) {
  if (_isPlainHeaderValue(value)) return value;
  return '$_sentinelPrefix${base64.encode(utf8.encode(value))}$_sentinelSuffix';
}

/// Inverse of [encodeMcpHeaderValue] (used by test servers).
String decodeMcpHeaderValue(String value) {
  if (value.startsWith(_sentinelPrefix) && value.endsWith(_sentinelSuffix) && value.length >= 11) {
    final b64 = value.substring(_sentinelPrefix.length, value.length - _sentinelSuffix.length);
    return utf8.decode(base64.decode(b64));
  }
  return value;
}

bool _isPlainHeaderValue(String s) {
  if (s.isEmpty) return false;
  if (s.startsWith(_sentinelPrefix) && s.endsWith(_sentinelSuffix)) return false;
  if (s.trim() != s) return false;
  for (final c in s.codeUnits) {
    if (c == 0x09 || (c >= 0x20 && c <= 0x7E)) continue;
    return false;
  }
  return true;
}

/// One `x-mcp-header` declaration found in a tool's `inputSchema`.
@immutable
final class McpHeaderParam {
  const McpHeaderParam({required this.path, required this.headerName, required this.type});

  /// `properties` keys from the schema root to the annotated argument.
  final List<String> path;

  /// The `{Name}` in `Mcp-Param-{Name}`.
  final String headerName;

  /// `string`, `integer` or `boolean`.
  final String type;

  @override
  String toString() => 'McpHeaderParam(${path.join('.')} → $headerName)';
}

/// The result of scanning a tool's `inputSchema` for `x-mcp-header`.
@immutable
final class McpHeaderScan {
  const McpHeaderScan.valid(this.params) : invalidReason = null;

  const McpHeaderScan.invalid(String this.invalidReason) : params = const [];

  final List<McpHeaderParam> params;

  /// Why the declarations are invalid; the client MUST then drop the tool
  /// from its `tools/list` view (streamable-http.md §Custom Headers).
  final String? invalidReason;

  bool get isValid => invalidReason == null;
}

final RegExp _tchar = RegExp(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$");

/// Subschema keywords an `x-mcp-header` may not sit beneath: the
/// annotated argument must be reachable from the root purely through a
/// chain of `properties` keys.
const List<String> _unreachableKeywords = [
  'items',
  'prefixItems',
  'contains',
  'additionalProperties',
  'unevaluatedProperties',
  'unevaluatedItems',
  'propertyNames',
  'patternProperties',
  'dependentSchemas',
  'oneOf',
  'anyOf',
  'allOf',
  'not',
  'if',
  'then',
  'else',
  r'$defs',
  'definitions',
];

const Set<String> _objectValuedKeywords = {'patternProperties', 'dependentSchemas', r'$defs', 'definitions'};

/// Validates every `x-mcp-header` in [inputSchema] (spec rules: non-empty
/// RFC 9110 token, no control characters, case-insensitively unique,
/// primitive `string` / `integer` / `boolean` type — `number` is
/// forbidden — and statically reachable through `properties` only).
///
/// Note: the TS v2 SDK also accepts `type: "number"` because the
/// conformance referee expects it; Sherpa follows the spec text.
McpHeaderScan scanMcpHeaderParams(JsonMap inputSchema) {
  final params = <McpHeaderParam>[];
  final seen = <String, String>{};

  String? visit(Object? node, List<String> path, {required bool reachable}) {
    if (node is! Map) return null;
    final schema = node.cast<String, Object?>();
    if (schema.containsKey('x-mcp-header')) {
      final where = path.isEmpty ? '<root>' : path.join('.');
      if (!reachable || path.isEmpty) {
        return '$where: x-mcp-header is only allowed on properties reachable through "properties" keys';
      }
      final raw = schema['x-mcp-header'];
      if (raw is! String || raw.isEmpty) return '$where: x-mcp-header must be a non-empty string';
      if (!_tchar.hasMatch(raw)) return '$where: x-mcp-header "$raw" is not an RFC 9110 token';
      final type = schema['type'];
      if (type is! String || !(type == 'string' || type == 'integer' || type == 'boolean')) {
        return '$where: x-mcp-header requires type string, integer or boolean (got ${type ?? 'none'})';
      }
      final prior = seen[raw.toLowerCase()];
      if (prior != null) return 'x-mcp-header "$raw" is not case-insensitively unique (also "$prior")';
      seen[raw.toLowerCase()] = raw;
      params.add(McpHeaderParam(path: List.unmodifiable(path), headerName: raw, type: type));
    }
    final properties = schema['properties'];
    if (properties is Map) {
      for (final e in properties.entries) {
        final fault = visit(e.value, [...path, '${e.key}'], reachable: reachable);
        if (fault != null) return fault;
      }
    }
    for (final k in _unreachableKeywords) {
      final sub = schema[k];
      if (sub == null) continue;
      final branches = sub is List
          ? sub
          : (sub is Map && _objectValuedKeywords.contains(k) ? sub.values.toList() : [sub]);
      for (final b in branches) {
        final fault = visit(b, [...path, '<$k>'], reachable: false);
        if (fault != null) return fault;
      }
    }
    return null;
  }

  final fault = visit(inputSchema, const [], reachable: true);
  return fault == null ? McpHeaderScan.valid(List.unmodifiable(params)) : McpHeaderScan.invalid(fault);
}

/// The largest integer a header may carry: ±(2^53 − 1).
const int _maxSafeInteger = 9007199254740991;

/// Builds the `Mcp-Param-*` headers for one `tools/call`.
///
/// A declaration whose argument is absent or `null` emits no header. A value
/// that is not a primitive of the declared type, or an integer outside the
/// safe range, is omitted rather than sent malformed. Integers are emitted
/// in canonical decimal (`42.0` → `42`).
Map<String, String> buildMcpParamHeaders(List<McpHeaderParam> params, JsonMap? arguments) {
  final out = <String, String>{};
  for (final p in params) {
    Object? v = arguments;
    for (final key in p.path) {
      v = v is Map ? v[key] : null;
    }
    final String? text = switch ((p.type, v)) {
      ('string', final String s) => s,
      ('boolean', final bool b) => b ? 'true' : 'false',
      ('integer', final int i) when i.abs() <= _maxSafeInteger => '$i',
      ('integer', final double d) when d.isFinite && d == d.truncateToDouble() && d.abs() <= _maxSafeInteger =>
        '${d.toInt()}',
      _ => null,
    };
    if (text != null) out['${McpHeaders.paramPrefix}${p.headerName}'] = encodeMcpHeaderValue(text);
  }
  return out;
}
