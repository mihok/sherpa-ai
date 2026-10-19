import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart';

/// A JSON Schema rewritten into the subset Anthropic structured outputs
/// (`output_config.format`) accept, plus what was relaxed on the way.
@immutable
final class AnthropicOutputSchema {
  const AnthropicOutputSchema._(this.schema, this.relaxed);

  /// Rewrites [schema] the way the official SDK helpers do
  /// (platform.claude.com, structured outputs, "How SDK transformation
  /// works"):
  ///
  /// * constraints the API rejects with a 400 (`minLength`/`maxLength`,
  ///   `minimum`/`maximum`/`exclusive*`/`multipleOf`, array constraints
  ///   beyond `minItems` 0 or 1, unsupported `format` values, and keywords
  ///   the documented subset does not include) are removed and appended to
  ///   the field's `description` (e.g. `{maxLength: 400}`), so the model
  ///   still sees them;
  /// * `oneOf` becomes `anyOf` (only `anyOf`/`allOf` are supported);
  /// * every object schema gets `additionalProperties: false`, which the
  ///   API requires; a different value is replaced.
  ///
  /// The result is deterministic for equal input. [relaxed] lists each
  /// constraint that is no longer enforced by the API, as
  /// `<JSON pointer>: <keyword>`; callers report it, since the reply may
  /// now violate the original schema.
  factory AnthropicOutputSchema.of(JsonMap schema) {
    final relaxed = <String>[];
    final out = _walk(schema, '#', relaxed);
    return AnthropicOutputSchema._(out is Map ? out.cast<String, Object?>() : schema, List.unmodifiable(relaxed));
  }

  final JsonMap schema;
  final List<String> relaxed;

  /// Per the documented "Not supported" list.
  static const Set<String> _unsupported = {
    'minLength', 'maxLength', // string constraints
    'minimum', 'maximum', 'exclusiveMinimum', 'exclusiveMaximum', 'multipleOf', // numeric
    'maxItems', 'uniqueItems', 'contains', 'minContains', 'maxContains', // arrays
    'minProperties', 'maxProperties', 'patternProperties', 'propertyNames', //
    'dependentRequired', 'dependentSchemas', 'dependencies', //
    'unevaluatedProperties', 'unevaluatedItems', 'not', 'if', 'then', 'else',
  };

  /// String formats the API supports.
  static const Set<String> _formats = {
    'date-time', 'time', 'date', 'duration', 'email', 'hostname', 'uri', 'ipv4', 'ipv6', 'uuid', //
  };

  /// Keywords whose value is a map of name to subschema.
  static const Set<String> _schemaMaps = {'properties', r'$defs', 'definitions'};

  /// Keywords whose value is a list of subschemas.
  static const Set<String> _schemaLists = {'anyOf', 'allOf', 'prefixItems'};

  static Object? _walk(Object? node, String path, List<String> relaxed) {
    if (node is! Map) return node;
    final out = <String, Object?>{};
    final moved = <String, Object?>{};
    void relax(String keyword, Object? value) {
      moved[keyword] = value;
      relaxed.add('$path: $keyword');
    }

    for (final e in node.entries) {
      final key = e.key.toString();
      final value = e.value;
      switch (key) {
        case _ when _schemaMaps.contains(key) && value is Map:
          out[key] = {
            for (final p in value.entries) p.key.toString(): _walk(p.value, '$path/$key/${p.key}', relaxed),
          };
        case _ when _schemaLists.contains(key) && value is List:
          out[key] = [for (var i = 0; i < value.length; i++) _walk(value[i], '$path/$key/$i', relaxed)];
        case 'oneOf' when value is List:
          relaxed.add('$path: oneOf (sent as anyOf)');
          final merged = [
            ...?(out['anyOf'] as List<Object?>?),
            for (var i = 0; i < value.length; i++) _walk(value[i], '$path/oneOf/$i', relaxed),
          ];
          out['anyOf'] = merged;
        case 'items' when value is Map:
          out[key] = _walk(value, '$path/items', relaxed);
        case 'items' when value is List:
          out[key] = [for (var i = 0; i < value.length; i++) _walk(value[i], '$path/items/$i', relaxed)];
        case 'additionalProperties':
          if (value != false) relax(key, value);
        case 'minItems':
          if (value is num && value <= 1) {
            out[key] = value;
          } else {
            relax(key, value);
          }
        case 'format':
          if (value is String && _formats.contains(value)) {
            out[key] = value;
          } else {
            relax(key, value);
          }
        case _ when _unsupported.contains(key):
          relax(key, value);
        default:
          out[key] = value;
      }
    }
    if (_isObject(out)) out['additionalProperties'] = false;
    if (moved.isNotEmpty) {
      final note = '{${[for (final m in moved.entries) '${m.key}: ${_render(m.value)}'].join(', ')}}';
      final existing = out['description'];
      out['description'] = existing is String && existing.isNotEmpty ? '$existing\n\n$note' : note;
    }
    return out;
  }

  static bool _isObject(Map<String, Object?> s) {
    final type = s['type'];
    if (type == 'object') return true;
    if (type is List && type.contains('object')) return true;
    return type == null && s['properties'] is Map;
  }

  static String _render(Object? v) => v is String ? v : jsonEncode(v);
}
