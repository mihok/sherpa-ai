/// JSON Schema normalization for weak local models (R11 §(c), §9.6.5).
library;

import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart' show JsonMap;

import 'canonical.dart';

/// Tunables for [SchemaNormalizer]; the defaults are R11 §9.6.5's numbers.
@immutable
final class SchemaNormalizationOptions {
  const SchemaNormalizationOptions({
    this.maxToolDescription = 200,
    this.maxParamDescription = 80,
    this.maxEnumValues = 32,
    this.enumHintValues = 10,
    this.maxRefDepth = 4,
    this.maxDepth = 8,
  });

  /// "Trim tool descriptions to about 200 chars (first sentence plus key
  /// constraint)".
  final int maxToolDescription;

  /// "… and parameter descriptions to about 80 chars."
  final int maxParamDescription;

  /// "Enums: keep up to 32 values; above that, use string plus 'one of:
  /// `<top 10>…`' and validate after decoding."
  final int maxEnumValues;
  final int enumHintValues;

  /// How many nested `$ref` expansions one path may take (recursive
  /// schemas would otherwise expand forever).
  final int maxRefDepth;

  /// Subschemas deeper than this collapse to a bare type.
  final int maxDepth;
}

/// Rewrites MCP input schemas into the subset small local models and
/// llama.cpp's grammar converter handle reliably.
///
/// Why: llama.cpp skips unsupported keywords silently, breaks on nested
/// `$ref`s and `prefixItems`, cannot mix `properties` with `anyOf`/`oneOf`,
/// applies numeric bounds to integers only and needs anchored patterns
/// (R11 §(c) "Schema limits of the llama.cpp grammar converter"); weak
/// models additionally lose accuracy on long descriptions and huge enums.
///
/// The output is for RENDERING only: keys are never renamed (so no
/// un-mapping is needed) and the original schema stays the one arguments
/// are validated against ([validateArguments]), which is where the
/// precision dropped here (bounds on numbers, unanchored patterns,
/// alternatives collapsed to `string`, big enums) is enforced again.
/// Pure and deterministic: the same input always renders the same bytes,
/// which keeps KV prefixes reusable.
abstract final class SchemaNormalizer {
  static const Set<String> _dropped = {
    'title',
    'examples',
    r'$schema',
    r'$id',
    r'$anchor',
    r'$comment',
    r'$defs',
    'definitions',
    'uniqueItems',
    'contains',
    'minContains',
    'maxContains',
    'patternProperties',
    'propertyNames',
    'prefixItems',
    'additionalItems',
    'dependentSchemas',
    'dependentRequired',
    'dependencies',
    'if',
    'then',
    'else',
    'not',
    'unevaluatedProperties',
    'unevaluatedItems',
    'readOnly',
    'writeOnly',
    'deprecated',
    'contentMediaType',
    'contentEncoding',
    'contentSchema',
    r'$dynamicRef',
    r'$dynamicAnchor',
    r'$recursiveRef',
    r'$recursiveAnchor',
    'x-mcp-header',
  };

  /// Formats llama.cpp's converter understands; the rest (`uri`, `email`,
  /// `hostname`, …) are dropped and re-checked by validation (R11 §9.6.5).
  static const Set<String> _keptFormats = {'date', 'time', 'date-time', 'uuid'};

  static const Set<String> _primitives = {'string', 'number', 'integer', 'boolean'};

  /// The normalized form of a tool's `inputSchema`. The root is always an
  /// object schema with a `properties` map.
  static JsonMap normalize(JsonMap schema, {SchemaNormalizationOptions options = const SchemaNormalizationOptions()}) {
    final ctx = _Ctx(schema, options);
    final out = ctx.node(schema, depth: 0, refDepth: 0, describe: false);
    final root = <String, Object?>{...out, 'type': 'object'};
    root['properties'] ??= <String, Object?>{};
    root.remove('description');
    return root;
  }

  /// A tool description trimmed for a small model: the first sentence,
  /// plus the next one if it still fits, cut at a word boundary.
  static String trimDescription(String text, {int max = 200}) => _trimText(text, max);

  static String _trimText(String text, int max) {
    final t = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.length <= max) return t;
    final sentences = RegExp(r'[^.!?]+[.!?]+(?=\s|$)').allMatches(t).map((m) => m.group(0)!.trim()).toList();
    if (sentences.isNotEmpty && sentences.first.length <= max) {
      var out = sentences.first;
      for (final s in sentences.skip(1)) {
        if (out.length + 1 + s.length > max) break;
        out = '$out $s';
      }
      return out;
    }
    final cut = t.substring(0, max - 1);
    final space = cut.lastIndexOf(' ');
    return '${space > max ~/ 2 ? cut.substring(0, space) : cut}…';
  }
}

final class _Ctx {
  _Ctx(this.root, this.o);

  final JsonMap root;
  final SchemaNormalizationOptions o;

  /// Resolves a local JSON pointer (`#`, `#/$defs/x`, `#/definitions/x`).
  /// External refs are never fetched (R01 §2.3: MUST NOT auto-dereference).
  JsonMap? resolve(String ref) {
    if (!ref.startsWith('#')) return null;
    if (ref == '#') return root;
    if (!ref.startsWith('#/')) return null;
    Object? cur = root;
    for (final raw in ref.substring(2).split('/')) {
      final token = Uri.decodeComponent(raw).replaceAll('~1', '/').replaceAll('~0', '~');
      if (cur is Map) {
        cur = cur[token];
      } else if (cur is List) {
        final i = int.tryParse(token);
        cur = i == null || i < 0 || i >= cur.length ? null : cur[i];
      } else {
        return null;
      }
    }
    return cur is Map ? cur.cast<String, Object?>() : null;
  }

  /// Whether [raw] accepts `null` (its type includes null, or one of its
  /// alternatives / enum values does).
  bool allowsNull(Object? raw, int refDepth) {
    if (raw is! Map) return raw == true;
    final s = raw.cast<String, Object?>();
    final ref = s[r'$ref'];
    if (ref is String) {
      final t = refDepth < o.maxRefDepth ? resolve(ref) : null;
      return t != null && allowsNull(t, refDepth + 1);
    }
    final t = s['type'];
    if (t == 'null' || (t is List && t.contains('null'))) return true;
    for (final k in const ['anyOf', 'oneOf']) {
      final alts = s[k];
      if (alts is List && alts.any((a) => allowsNull(a, refDepth))) return true;
    }
    final e = s['enum'];
    return e is List && e.contains(null);
  }

  JsonMap node(Object? raw, {required int depth, required int refDepth, bool describe = true}) {
    if (raw is bool) return raw ? <String, Object?>{} : <String, Object?>{'type': 'null'};
    if (raw is! Map) return <String, Object?>{};
    var s = raw.cast<String, Object?>();

    // Inline $ref (nested refs break llama.cpp); siblings override.
    final ref = s[r'$ref'];
    if (ref is String) {
      final target = refDepth < o.maxRefDepth ? resolve(ref) : null;
      final siblings = {...s}..remove(r'$ref');
      if (target == null) {
        // Unresolvable (external, missing, or too deep): render a permissive
        // node; validation skips it, hygiene flags external refs.
        return _finish({...siblings, if (!siblings.containsKey('type')) 'type': 'object'}, depth: depth, describe: describe);
      }
      final inlined = node(target, depth: depth, refDepth: refDepth + 1, describe: describe);
      final rest = node(siblings, depth: depth, refDepth: refDepth, describe: describe);
      return {...inlined, ...rest};
    }

    if (depth > o.maxDepth) {
      final t = _typeOf(s);
      return {'type': t == null || t == 'null' ? 'string' : t};
    }

    s = {...s};
    // const → single-value enum.
    if (s.containsKey('const') && !s.containsKey('enum')) s['enum'] = [s.remove('const')];
    s.remove('const');

    // allOf: merge the branches into one schema.
    final allOf = s.remove('allOf');
    if (allOf is List && allOf.isNotEmpty) {
      var merged = <String, Object?>{};
      for (final b in allOf) {
        merged = _merge(merged, node(b, depth: depth, refDepth: refDepth, describe: describe));
      }
      s = _merge(merged, s);
    }

    // anyOf / oneOf.
    for (final key in const ['anyOf', 'oneOf']) {
      final alts = s.remove(key);
      if (alts is! List || alts.isEmpty) continue;
      final branches = [for (final a in alts) node(a, depth: depth, refDepth: refDepth, describe: describe)];
      s = _merge(_collapse(branches), s);
    }

    // type: ["string", "null"] → "string"; ["string","integer"] → string.
    final type = s['type'];
    if (type is List) {
      final nonNull = [for (final t in type) if (t is String && t != 'null') t];
      if (nonNull.isEmpty) {
        s['type'] = 'null';
      } else if (nonNull.length == 1) {
        s['type'] = nonNull.single;
      } else if (nonNull.every(SchemaNormalizer._primitives.contains)) {
        s['type'] = 'string';
        s['description'] = _join(s['description'], 'Accepts ${nonNull.join(' or ')}.');
      } else {
        s['type'] = nonNull.contains('object') ? 'object' : nonNull.first;
      }
    }

    return _finish(_recurse(s, depth: depth, refDepth: refDepth), depth: depth, describe: describe);
  }

  JsonMap _recurse(JsonMap s, {required int depth, required int refDepth}) {
    final props = s['properties'];
    // `anyOf [T, null]` renders as an OPTIONAL T (R11 §9.6.5); validation
    // fills such a property with null when the model omits it.
    final nullable = <String>{
      if (props is Map)
        for (final e in props.entries)
          if (allowsNull(e.value, 0)) '${e.key}',
    };
    if (props is Map) {
      s['properties'] = <String, Object?>{
        for (final e in props.entries) '${e.key}': node(e.value, depth: depth + 1, refDepth: refDepth),
      };
      s['type'] ??= 'object';
    }
    final items = s['items'];
    if (items is Map || items is bool) {
      s['items'] = node(items, depth: depth + 1, refDepth: refDepth);
    } else if (items is List) {
      // Tuple-style items (draft 7): llama.cpp handles prefixItems badly, so
      // render the first item schema for all.
      s['items'] = items.isEmpty ? <String, Object?>{} : node(items.first, depth: depth + 1, refDepth: refDepth);
    }
    final ap = s['additionalProperties'];
    if (ap is Map) s['additionalProperties'] = node(ap, depth: depth + 1, refDepth: refDepth);
    final req = s['required'];
    if (req is List) {
      final names = [for (final r in req) if (r is String) r];
      final declared = s['properties'];
      s['required'] = declared is Map
          ? [for (final n in names) if (declared.containsKey(n) && !nullable.contains(n)) n]
          : names;
      if ((s['required']! as List).isEmpty) s.remove('required');
    } else {
      s.remove('required');
    }
    return s;
  }

  /// Drops unsupported keywords, applies the integer-only bounds rule, the
  /// anchored-pattern rule, the enum cap and the description trims.
  JsonMap _finish(JsonMap s, {required int depth, required bool describe}) {
    final out = <String, Object?>{};
    final type = s['type'];
    final hints = <String>[];
    var bigEnum = false;
    for (final e in s.entries) {
      final k = e.key;
      final v = e.value;
      if (SchemaNormalizer._dropped.contains(k) || k.startsWith(r'$')) continue;
      switch (k) {
        case 'format':
          if (v is String && SchemaNormalizer._keptFormats.contains(v)) out[k] = v;
        case 'minimum' || 'maximum' || 'exclusiveMinimum' || 'exclusiveMaximum' || 'multipleOf':
          if (type == 'integer' && v is num) out[k] = v;
        case 'pattern':
          if (v is String && _anchored(v)) out[k] = v;
        case 'default':
          hints.add('Default: ${_short(v)}.');
        case 'enum':
          if (v is! List) continue;
          if (v.length <= o.maxEnumValues) {
            out[k] = v;
          } else {
            final shown = v.take(o.enumHintValues).map(_short).join(', ');
            hints.add('One of: $shown, …');
            bigEnum = true;
          }
        case 'description':
          continue; // handled below
        default:
          out[k] = v;
      }
    }
    if (bigEnum) out['type'] = 'string';
    if (out['enum'] case final List<Object?> e when type == null) {
      final kinds = e.map(_jsonType).toSet();
      if (kinds.length == 1 && kinds.single != 'null') out['type'] = kinds.single;
    }
    if (describe) {
      final d = s['description'];
      final text = [if (d is String && d.trim().isNotEmpty) d.trim(), ...hints].join(' ');
      if (text.isNotEmpty) out['description'] = SchemaNormalizer._trimText(text, o.maxParamDescription);
    }
    return out;
  }

  static bool _anchored(String p) => p.startsWith('^') && p.endsWith(r'$') && !p.endsWith(r'\$');

  static String _short(Object? v) {
    final s = v is String ? v : jsonEncode(v);
    return s.length > 24 ? '${s.substring(0, 23)}…' : s;
  }

  static String _jsonType(Object? v) => switch (v) {
        null => 'null',
        bool() => 'boolean',
        int() => 'integer',
        num() => 'number',
        String() => 'string',
        List() => 'array',
        _ => 'object',
      };

  static String? _typeOf(JsonMap s) {
    final t = s['type'];
    if (t is String) return t;
    if (t is List) return t.whereType<String>().where((x) => x != 'null').firstOrNull;
    if (s['properties'] is Map) return 'object';
    if (s.containsKey('items')) return 'array';
    return null;
  }

  static String _join(Object? a, String b) => a is String && a.isNotEmpty ? '$a $b' : b;

  /// One schema for a set of alternatives (R11 §9.6.5):
  /// `[T, null]` → T; all primitives → `string` (+ a hint); all objects →
  /// one object with the union of properties and the intersection of
  /// `required`; otherwise the first non-null branch.
  JsonMap _collapse(List<JsonMap> branches) {
    final nonNull = [for (final b in branches) if (b['type'] != 'null') b];
    if (nonNull.isEmpty) return {'type': 'null'};
    if (nonNull.length == 1) return nonNull.single;
    final types = [for (final b in nonNull) _typeOf(b)];
    if (types.every((t) => t != null && SchemaNormalizer._primitives.contains(t))) {
      final distinct = {...types.cast<String>()};
      if (distinct.length == 1) {
        final enums = [
          for (final b in nonNull)
            if (b['enum'] is List) ...(b['enum']! as List) else null,
        ];
        return {'type': distinct.single, if (!enums.contains(null)) 'enum': {...enums}.toList()};
      }
      return {'type': 'string', 'description': 'Accepts ${distinct.join(' or ')}.'};
    }
    if (types.every((t) => t == 'object')) {
      final props = <String, Object?>{};
      Set<String>? required;
      for (final b in nonNull) {
        final p = b['properties'];
        if (p is Map) {
          for (final e in p.entries) {
            props.putIfAbsent('${e.key}', () => e.value);
          }
        }
        final r = {...(b['required'] as List?)?.whereType<String>() ?? const <String>[]};
        required = required == null ? r : required.intersection(r);
      }
      return {
        'type': 'object',
        'properties': props,
        if (required != null && required.isNotEmpty) 'required': required.toList(),
      };
    }
    return nonNull.firstWhere((b) => _typeOf(b) != null, orElse: () => nonNull.first);
  }

  /// Shallow merge for `allOf`: properties union, required union, other
  /// keywords from [b] win.
  static JsonMap _merge(JsonMap a, JsonMap b) {
    final out = <String, Object?>{...a, ...b};
    final pa = a['properties'];
    final pb = b['properties'];
    if (pa is Map || pb is Map) {
      out['properties'] = <String, Object?>{
        if (pa is Map) ...pa.cast<String, Object?>(),
        if (pb is Map) ...pb.cast<String, Object?>(),
      };
    }
    final ra = a['required'];
    final rb = b['required'];
    if (ra is List || rb is List) {
      out['required'] = {
        if (ra is List) ...ra.whereType<String>(),
        if (rb is List) ...rb.whereType<String>(),
      }.toList();
    }
    if (a['description'] is String && b['description'] is String) {
      out['description'] = '${a['description']} ${b['description']}';
    }
    return out;
  }
}

/// Outcome of [validateArguments].
@immutable
final class ArgumentValidation {
  const ArgumentValidation({required this.value, required this.errors, required this.coercions});

  /// The arguments after the safe coercions (send these to the server).
  final JsonMap value;

  /// 1-line problems, `$.path: message`; empty when valid. Fed back to the
  /// model as an `isError` result for self-correction (R11 §9.6.6).
  final List<String> errors;

  /// What was coerced, e.g. `$.limit: "5" → 5` (for repair metrics).
  final List<String> coercions;

  bool get isValid => errors.isEmpty;

  bool get coerced => coercions.isNotEmpty;
}

/// Validates [args] against a tool's ORIGINAL [schema] (draft-07 /
/// 2020-12 subset: `type`, `properties`, `required`, `additionalProperties`,
/// `items`, `enum`, `const`, numeric and length bounds, `pattern`,
/// `anyOf`/`oneOf`/`allOf`, local `$ref`), applying only the safe
/// coercions of R11 §9.6.6:
///
/// * `"5"` → `5` for `integer` (and `"2.5"` → `2.5` for `number`; `5.0`
///   → `5` for `integer`);
/// * a scalar → `[scalar]` for `array`;
/// * `"true"` / `"false"` → booleans;
/// * a JSON string holding an object/array where one is expected (the
///   "stringified arguments decoded twice" repair);
/// * a missing required property whose schema allows `null` → `null`
///   (the normalizer renders `anyOf [T, null]` as an optional T).
///
/// Unknown keywords are ignored rather than failed, external `$ref`s are
/// not followed (R01 §2.3) and validator cost is bounded by depth and an
/// error cap, so a hostile schema cannot make this expensive.
ArgumentValidation validateArguments(JsonMap schema, JsonMap args, {int maxErrors = 5}) {
  final v = _Validator(schema, maxErrors);
  final value = v.check(schema, deepCopyMap(args), r'$', 0, 0);
  return ArgumentValidation(
    value: value is Map ? value.cast<String, Object?>() : args,
    errors: List.unmodifiable(v.errors),
    coercions: List.unmodifiable(v.coercions),
  );
}

final class _Validator {
  _Validator(this.root, this.maxErrors) : ctx = _Ctx(root, const SchemaNormalizationOptions());

  final JsonMap root;
  final int maxErrors;
  final _Ctx ctx;
  final List<String> errors = [];
  final List<String> coercions = [];

  static const int _maxDepth = 32;

  void _err(String path, String msg) {
    if (errors.length < maxErrors) errors.add('$path: $msg');
  }

  static String _show(Object? v) {
    final s = jsonEncode(v);
    return s.length > 40 ? '${s.substring(0, 39)}…' : s;
  }

  static String _kind(Object? v) => switch (v) {
        null => 'null',
        bool() => 'boolean',
        int() => 'integer',
        double(:final isFinite) when isFinite && v == v.truncateToDouble() => 'integer',
        num() => 'number',
        String() => 'string',
        List() => 'array',
        Map() => 'object',
        _ => 'unknown',
      };

  static bool _isType(Object? v, String t) => switch (t) {
        'null' => v == null,
        'boolean' => v is bool,
        'integer' => v is int || (v is double && v.isFinite && v == v.truncateToDouble()),
        'number' => v is num,
        'string' => v is String,
        'array' => v is List,
        'object' => v is Map,
        _ => true,
      };

  static List<String>? _types(JsonMap s) {
    final t = s['type'];
    if (t is String) return [t];
    if (t is List) return t.whereType<String>().toList();
    return null;
  }

  /// Returns the (possibly coerced) value.
  Object? check(Object? raw, Object? value, String path, int depth, int refDepth) {
    if (depth > _maxDepth || errors.length >= maxErrors) return value;
    if (raw is bool) {
      if (!raw) _err(path, 'no value is allowed here');
      return value;
    }
    if (raw is! Map) return value;
    final s = raw.cast<String, Object?>();

    final ref = s[r'$ref'];
    if (ref is String) {
      final target = refDepth < 8 ? ctx.resolve(ref) : null;
      if (target != null) value = check(target, value, path, depth + 1, refDepth + 1);
      // An unresolvable (e.g. external) ref is not followed: skip.
    }

    final allOf = s['allOf'];
    if (allOf is List) {
      for (final b in allOf) {
        value = check(b, value, path, depth + 1, refDepth);
      }
    }
    for (final k in const ['anyOf', 'oneOf']) {
      final alts = s[k];
      if (alts is! List || alts.isEmpty) continue;
      Object? accepted;
      var ok = false;
      for (final a in alts) {
        final sub = _Validator(root, 1);
        final out = sub.check(a, deepCopyJson(value), path, depth + 1, refDepth);
        if (sub.errors.isEmpty) {
          ok = true;
          accepted = out;
          coercions.addAll(sub.coercions);
          break;
        }
      }
      if (ok) {
        value = accepted;
      } else {
        _err(path, 'does not match any allowed form (got ${_show(value)})');
        return value;
      }
    }

    final types = _types(s);
    if (types != null && types.isNotEmpty && !types.any((t) => _isType(value, t))) {
      final coerced = _coerce(value, types);
      if (coerced.$1) {
        coercions.add('$path: ${_show(value)} → ${_show(coerced.$2)}');
        value = coerced.$2;
      } else {
        _err(path, 'expected ${types.join(' or ')}, got ${_kind(value)} ${_show(value)}');
        return value;
      }
    }
    if (value is double && (types?.contains('integer') ?? false) && !(types?.contains('number') ?? false)) {
      value = value.toInt();
    }

    final en = s['enum'];
    if (en is List && !en.any((e) => canonicalJson(e) == canonicalJson(value))) {
      final shown = en.take(8).map(_show).join(', ');
      _err(path, 'must be one of $shown${en.length > 8 ? ', …' : ''} (got ${_show(value)})');
    }
    if (s.containsKey('const') && canonicalJson(s['const']) != canonicalJson(value)) {
      _err(path, 'must be ${_show(s['const'])}');
    }

    switch (value) {
      case final num n:
        _bounds(s, n, path);
      case final String str:
        final minL = s['minLength'];
        final maxL = s['maxLength'];
        final len = str.runes.length;
        if (minL is int && len < minL) _err(path, 'must be at least $minL characters');
        if (maxL is int && len > maxL) _err(path, 'must be at most $maxL characters (got $len)');
        final p = s['pattern'];
        if (p is String) {
          RegExp? re;
          try {
            re = RegExp(p, unicode: true);
          } on FormatException {
            re = null; // a dialect we cannot evaluate: leave it to the server
          }
          if (re != null && !re.hasMatch(str)) _err(path, 'does not match the pattern $p');
        }
      case final List<Object?> list:
        final minI = s['minItems'];
        final maxI = s['maxItems'];
        if (minI is int && list.length < minI) _err(path, 'needs at least $minI items');
        if (maxI is int && list.length > maxI) _err(path, 'allows at most $maxI items (got ${list.length})');
        final items = s['items'];
        if (items is Map || items is bool) {
          for (var i = 0; i < list.length; i++) {
            list[i] = check(items, list[i], '$path[$i]', depth + 1, refDepth);
          }
        }
      case final Map<Object?, Object?> map:
        _object(s, map.cast<String, Object?>(), path, depth, refDepth);
    }
    return value;
  }

  void _bounds(JsonMap s, num n, String path) {
    final min = s['minimum'];
    final max = s['maximum'];
    final xmin = s['exclusiveMinimum'];
    final xmax = s['exclusiveMaximum'];
    if (min is num && n < min) _err(path, 'must be ≥ $min (got $n)');
    if (max is num && n > max) _err(path, 'must be ≤ $max (got $n)');
    if (xmin is num && n <= xmin) _err(path, 'must be > $xmin (got $n)');
    if (xmax is num && n >= xmax) _err(path, 'must be < $xmax (got $n)');
  }

  void _object(JsonMap s, JsonMap map, String path, int depth, int refDepth) {
    final props = s['properties'];
    final declared = props is Map ? props.cast<String, Object?>() : const <String, Object?>{};
    final req = s['required'];
    if (req is List) {
      for (final r in req.whereType<String>()) {
        if (map.containsKey(r)) continue;
        if (declared.containsKey(r) && ctx.allowsNull(declared[r], refDepth)) {
          map[r] = null;
          coercions.add('$path.$r: missing → null');
          continue;
        }
        _err(path, 'missing required property "$r"');
      }
    }
    for (final e in declared.entries) {
      if (!map.containsKey(e.key)) continue;
      map[e.key] = check(e.value, map[e.key], '$path.${e.key}', depth + 1, refDepth);
    }
    final ap = s['additionalProperties'];
    final extra = [for (final k in map.keys) if (!declared.containsKey(k)) k];
    if (ap == false && extra.isNotEmpty) {
      final known = declared.keys.take(12).join(', ');
      _err(path, 'unknown propert${extra.length == 1 ? 'y' : 'ies'} ${extra.map((k) => '"$k"').join(', ')}'
          '${known.isEmpty ? '' : ' (allowed: $known)'}');
    } else if (ap is Map) {
      for (final k in extra) {
        map[k] = check(ap, map[k], '$path.$k', depth + 1, refDepth);
      }
    }
  }

  /// The safe coercions; returns (applied, value).
  static (bool, Object?) _coerce(Object? v, List<String> types) {
    for (final t in types) {
      switch (t) {
        case 'integer' when v is String:
          final i = int.tryParse(v.trim());
          if (i != null) return (true, i);
          final d = double.tryParse(v.trim());
          if (d != null && d.isFinite && d == d.truncateToDouble()) return (true, d.toInt());
        case 'integer' when v is double && v.isFinite && v == v.truncateToDouble():
          return (true, v.toInt());
        case 'number' when v is String:
          final d = num.tryParse(v.trim());
          if (d != null && d.isFinite) return (true, d);
        case 'boolean' when v is String:
          final l = v.trim().toLowerCase();
          if (l == 'true') return (true, true);
          if (l == 'false') return (true, false);
        case 'array' when v is String && v.trim().startsWith('['):
          final d = _tryJson(v);
          if (d is List) return (true, d);
          return (true, [v]);
        case 'array' when v != null && v is! List && v is! Map:
          return (true, [v]);
        case 'object' when v is String && v.trim().startsWith('{'):
          final d = _tryJson(v);
          if (d is Map) return (true, deepCopyJson(d));
      }
    }
    return (false, v);
  }

  static Object? _tryJson(String s) {
    try {
      return deepCopyJson(jsonDecode(s));
    } on FormatException {
      return null;
    }
  }
}
