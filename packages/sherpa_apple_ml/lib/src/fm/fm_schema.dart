import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart';

/// A JSON Schema converted for Foundation Models, plus what was lost.
@immutable
final class FmSchemaResult {
  const FmSchemaResult(this.ir, this.warnings);

  /// `{"root": node, "dependencies": [node, ...]}`; see [FmSchemaConverter].
  final JsonMap ir;
  final List<String> warnings;

  String encode() => jsonEncode(ir);
}

/// Converts a tool's JSON Schema (MCP / OpenAI style) into the small IR the
/// Swift side maps 1:1 onto `DynamicGenerationSchema` and
/// `GenerationSchema(root:dependencies:)` (iOS 26, R06 §3.3).
///
/// IR nodes (`kind`):
/// * `object` {name, description?, properties: [{name, description?,
///   optional, schema}]} → `DynamicGenerationSchema(name:description:properties:)`;
/// * `string` {anyOf? | constant? | pattern?} → `(type: String.self,
///   guides: [.anyOf] | [.constant] | [.pattern(Regex)])`;
/// * `integer` / `number` {minimum?, maximum?} → `(type: Int.self /
///   Double.self, guides: [.minimum, .maximum])`;
/// * `boolean` → `(type: Bool.self)`;
/// * `array` {items, minItems?, maxItems?} → `(arrayOf:minimumElements:maximumElements:)`;
/// * `anyOf` {name, description?, choices} → `(name:description:anyOf:)`;
/// * `ref` {name} → `(referenceTo:)`, the target is in `dependencies`.
///
/// Lossy on purpose, with a warning for each loss: Foundation Models
/// generates only what its schema can express. Dynamic keys
/// (`additionalProperties`, `patternProperties`) and untyped values become
/// strings; `allOf` objects are merged; numeric enums lose their guide;
/// `null` in a type union makes the property optional; descriptions of array
/// items and primitives outside properties have nowhere to go.
final class FmSchemaConverter {
  FmSchemaConverter({this.maxDepth = 8});

  final int maxDepth;

  final List<String> _warnings = [];
  final List<JsonMap> _dependencies = [];
  final Set<String> _names = {};
  final Map<String, String> _defNames = {};
  final Set<String> _converting = {};
  Map<String, Object?> _defs = const {};

  FmSchemaResult convert(JsonMap schema, {required String rootName}) {
    _warnings.clear();
    _dependencies.clear();
    _names.clear();
    _defNames.clear();
    _converting.clear();
    _defs = {
      ...?(schema[r'$defs'] as Map?)?.cast<String, Object?>(),
      ...?(schema['definitions'] as Map?)?.cast<String, Object?>(),
    };
    var root = _node(schema, _sanitize(rootName), 0, path: rootName);
    if (root['kind'] != 'object') {
      // Tool arguments are always an object: wrap anything else.
      _warnings.add('$rootName: arguments schema is not an object; wrapped as {"value": …}');
      root = {
        'kind': 'object',
        'name': _unique(_sanitize(rootName)),
        'properties': [
          {'name': 'value', 'optional': false, 'schema': root},
        ],
      };
    }
    return FmSchemaResult({'root': root, 'dependencies': List<JsonMap>.of(_dependencies)}, List.of(_warnings));
  }

  JsonMap _node(Object? raw, String name, int depth, {required String path, bool exactName = false}) {
    if (raw is bool) return raw ? _string(path, 'accepts any value') : _string(path, 'schema is false');
    if (raw is! Map) return _string(path, 'missing schema');
    final s = raw.cast<String, Object?>();
    if (depth > maxDepth) return _string(path, 'nested deeper than $maxDepth levels');

    final ref = s[r'$ref'];
    if (ref is String) return _ref(ref, depth, path: path);

    for (final key in const ['anyOf', 'oneOf']) {
      final choices = s[key];
      if (choices is List && choices.isNotEmpty) {
        return _anyOf(s, choices, name, depth, path: path, exactName: exactName);
      }
    }
    final allOf = s['allOf'];
    if (allOf is List && allOf.isNotEmpty) return _allOf(s, allOf, name, depth, path: path, exactName: exactName);

    final (type, _) = _type(s);
    switch (type) {
      case 'object':
        return _object(s, name, depth, path: path, exactName: exactName);
      case 'array':
        final items = s['items'];
        final node = <String, Object?>{
          'kind': 'array',
          'items': items == null
              ? _string('$path[]', 'array items have no schema')
              : _node(items is List ? items.first : items, '${name}_item', depth + 1, path: '$path[]'),
        };
        if (s['minItems'] is num) node['minItems'] = (s['minItems']! as num).toInt();
        if (s['maxItems'] is num) node['maxItems'] = (s['maxItems']! as num).toInt();
        return node;
      case 'integer':
      case 'number':
        final node = <String, Object?>{'kind': type};
        final enumValues = s['enum'];
        if (enumValues is List) _warnings.add('$path: numeric enum ${jsonEncode(enumValues)} is not enforced');
        num? min = s['minimum'] as num?;
        num? max = s['maximum'] as num?;
        final exMin = s['exclusiveMinimum'], exMax = s['exclusiveMaximum'];
        if (exMin is num) min = type == 'integer' ? exMin + 1 : exMin;
        if (exMax is num) max = type == 'integer' ? exMax - 1 : exMax;
        if (type == 'number' && (exMin is num || exMax is num)) {
          _warnings.add('$path: exclusive bounds are applied as inclusive');
        }
        if (min != null) node['minimum'] = type == 'integer' ? min.ceil() : min;
        if (max != null) node['maximum'] = type == 'integer' ? max.floor() : max;
        return node;
      case 'boolean':
        return {'kind': 'boolean'};
      case 'string':
        final node = <String, Object?>{'kind': 'string'};
        final enumValues = s['enum'];
        final constant = s['const'];
        if (enumValues is List) {
          final strings = [
            for (final v in enumValues)
              if (v is String) v,
          ];
          if (strings.length != enumValues.length) _warnings.add('$path: non-string enum values dropped');
          if (strings.isNotEmpty) node['anyOf'] = strings;
        } else if (constant is String) {
          node['constant'] = constant;
        } else if (s['pattern'] is String) {
          node['pattern'] = s['pattern'];
        }
        return node;
      default:
        return _string(path, type == null ? 'no type given, treated as text' : 'type "$type" treated as text');
    }
  }

  /// The schema's single non-null type and whether `null` was allowed.
  (String?, bool) _type(Map<String, Object?> s) {
    final t = s['type'];
    if (t is String) return (t == 'null' ? null : t, t == 'null' || s['nullable'] == true);
    if (t is List) {
      final types = [
        for (final x in t)
          if (x is String && x != 'null') x,
      ];
      if (types.length > 1) _warnings.add('type union ${jsonEncode(t)}: using "${types.first}"');
      return (types.isEmpty ? null : types.first, t.contains('null'));
    }
    if (s['properties'] is Map) return ('object', s['nullable'] == true);
    if (s['items'] != null) return ('array', s['nullable'] == true);
    if (s['enum'] is List || s['const'] is String) return ('string', s['nullable'] == true);
    return (null, s['nullable'] == true);
  }

  JsonMap _object(Map<String, Object?> s, String name, int depth, {required String path, bool exactName = false}) {
    final props = (s['properties'] as Map?)?.cast<String, Object?>() ?? const {};
    final required = {for (final r in (s['required'] as List?) ?? const []) '$r'};
    if (s['additionalProperties'] is Map || s['patternProperties'] is Map) {
      _warnings.add('$path: dynamic keys (additionalProperties/patternProperties) cannot be generated');
    }
    final unique = exactName ? name : _unique(name);
    return {
      'kind': 'object',
      'name': unique,
      if (s['description'] is String) 'description': s['description'],
      'properties': [
        for (final e in props.entries)
          {
            'name': e.key,
            if (e.value is Map && (e.value! as Map)['description'] is String)
              'description': (e.value! as Map)['description'],
            'optional': !required.contains(e.key) || (e.value is Map && _type((e.value! as Map).cast()).$2),
            'schema': _node(e.value, '${unique}_${_sanitize(e.key)}', depth + 1, path: '$path.${e.key}'),
          },
      ],
    };
  }

  JsonMap _anyOf(
    Map<String, Object?> s,
    List<Object?> choices,
    String name,
    int depth, {
    required String path,
    bool exactName = false,
  }) {
    final nonNull = [
      for (final c in choices)
        if (!(c is Map && c['type'] == 'null')) c,
    ];
    // anyOf of string constants = one string with an anyOf guide.
    final consts = <String>[];
    for (final c in nonNull) {
      if (c is Map && c['const'] is String) {
        consts.add(c['const']! as String);
      } else if (c is Map && c['enum'] is List && (c['enum']! as List).every((v) => v is String)) {
        consts.addAll((c['enum']! as List).cast<String>());
      } else {
        consts.clear();
        break;
      }
    }
    if (consts.isNotEmpty) return {'kind': 'string', 'anyOf': consts};
    if (nonNull.length == 1) return _node(nonNull.single, name, depth, path: path);
    final unique = exactName ? name : _unique(name);
    return {
      'kind': 'anyOf',
      'name': unique,
      if (s['description'] is String) 'description': s['description'],
      'choices': [
        for (var i = 0; i < nonNull.length; i++) _node(nonNull[i], '${unique}_$i', depth + 1, path: '$path|$i'),
      ],
    };
  }

  JsonMap _allOf(
    Map<String, Object?> s,
    List<Object?> parts,
    String name,
    int depth, {
    required String path,
    bool exactName = false,
  }) {
    if (parts.length == 1 && s['properties'] == null) return _node(parts.single, name, depth, path: path);
    final merged = <String, Object?>{'type': 'object', 'properties': <String, Object?>{}, 'required': <Object?>[]};
    for (final part in [s, ...parts]) {
      var p = part is Map ? part.cast<String, Object?>() : const <String, Object?>{};
      final ref = p[r'$ref'];
      if (ref is String) p = (_defs[_defKey(ref)] as Map?)?.cast<String, Object?>() ?? const {};
      (merged['properties']! as Map<String, Object?>).addAll(
        (p['properties'] as Map?)?.cast<String, Object?>() ?? const {},
      );
      (merged['required']! as List<Object?>).addAll((p['required'] as List?) ?? const []);
      if (p['description'] is String) merged['description'] ??= p['description'];
    }
    _warnings.add('$path: allOf merged into one object');
    return _object(merged, name, depth, path: path, exactName: exactName);
  }

  JsonMap _ref(String ref, int depth, {required String path}) {
    final key = _defKey(ref);
    final def = _defs[key];
    if (def == null) return _string(path, 'unresolved \$ref $ref');
    final known = _defNames[key];
    if (known != null) return {'kind': 'ref', 'name': known};
    final looksNamed =
        def is Map &&
        (def['properties'] is Map || def['type'] == 'object' || def['anyOf'] is List || def['oneOf'] is List);
    if (looksNamed) {
      // Named schemas (objects, anyOf) become dependencies; the name is
      // reserved first so a recursive $ref resolves to it.
      final n = _unique(_sanitize(key));
      _defNames[key] = n;
      final node = _node(def, n, depth + 1, path: '#$key', exactName: true);
      if (node['kind'] == 'object' || node['kind'] == 'anyOf') {
        _dependencies.add(node);
        return {'kind': 'ref', 'name': n};
      }
      _defNames.remove(key);
      return node;
    }
    // Primitive definitions have no name in DynamicGenerationSchema: inline.
    if (!_converting.add(key)) return _string(path, 'recursive \$ref $ref');
    final node = _node(def, _sanitize(key), depth + 1, path: '#$key');
    _converting.remove(key);
    return node;
  }

  static String _defKey(String ref) => ref.split('/').last;

  JsonMap _string(String path, String why) {
    _warnings.add('$path: $why');
    return {'kind': 'string'};
  }

  String _unique(String name) {
    var n = name;
    var i = 2;
    while (!_names.add(n)) {
      n = '${name}_${i++}';
    }
    return n;
  }

  static String _sanitize(String s) {
    final out = s.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');
    return out.isEmpty ? 'Schema' : out;
  }
}
