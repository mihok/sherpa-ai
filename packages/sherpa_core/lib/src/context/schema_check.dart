import 'package:meta/meta.dart';

import '../common/json.dart';
import 'text.dart';

/// One way a value fails a schema.
@immutable
final class SchemaIssue {
  const SchemaIssue(this.path, this.message, {required this.fatal});

  /// JSON path of the offending value, e.g. `$.constraints[3]`.
  final String path;
  final String message;

  /// Fatal issues (wrong type, missing required field) mean the value is
  /// unusable. Non-fatal ones (too long, too many items, unknown keys) are
  /// fixed by [SchemaCheck.coerce].
  final bool fatal;

  @override
  String toString() => '$path: $message';
}

/// Validator for the small, grammar-friendly JSON-schema subset Sherpa uses
/// for constrained decoding: `type`, `properties`, `required`,
/// `additionalProperties: false`, `items`, `enum`, `maxItems`, `maxLength`.
///
/// No `$ref`/`anyOf` on purpose (R11 §9.1): llama.cpp's grammar converter
/// and several providers' structured-output modes handle only this subset
/// reliably, so a schema outside it is a bug in Sherpa, not in the model.
abstract final class SchemaCheck {
  static List<SchemaIssue> validate(JsonMap schema, Object? value) {
    final issues = <SchemaIssue>[];
    _check(schema, value, r'$', issues);
    return issues;
  }

  /// Returns [value] with the non-fatal issues fixed: strings cut to
  /// `maxLength`, arrays cut to `maxItems`, unknown keys dropped. Values that
  /// still fail fatally are returned unchanged.
  static Object? coerce(JsonMap schema, Object? value) {
    switch (schema['type']) {
      case 'object' when value is Map<Object?, Object?>:
        final props = (schema['properties'] as Map<Object?, Object?>?)?.cast<String, Object?>() ?? const {};
        final strict = schema['additionalProperties'] == false;
        return {
          for (final e in value.entries)
            if (!strict || props.containsKey(e.key))
              e.key.toString(): props[e.key] is Map<Object?, Object?>
                  ? coerce((props[e.key]! as Map<Object?, Object?>).cast<String, Object?>(), e.value)
                  : e.value,
        };
      case 'array' when value is List<Object?>:
        final max = (schema['maxItems'] as num?)?.toInt();
        final items = (schema['items'] as Map<Object?, Object?>?)?.cast<String, Object?>();
        final kept = max != null && value.length > max ? value.sublist(0, max) : value;
        return [for (final e in kept) items == null ? e : coerce(items, e)];
      case 'string' when value is String:
        final max = (schema['maxLength'] as num?)?.toInt();
        return max != null && value.length > max ? clipText(value, max) : value;
      default:
        return value;
    }
  }

  static void _check(JsonMap schema, Object? value, String path, List<SchemaIssue> out) {
    final type = schema['type'];
    if (type is String && !_hasType(type, value)) {
      out.add(SchemaIssue(path, 'expected $type, got ${_typeName(value)}', fatal: true));
      return;
    }
    final allowed = schema['enum'];
    if (allowed is List<Object?> && !allowed.contains(value)) {
      out.add(SchemaIssue(path, 'must be one of $allowed', fatal: true));
    }
    switch (value) {
      case Map<Object?, Object?>():
        _checkObject(schema, value, path, out);
      case List<Object?>():
        final max = (schema['maxItems'] as num?)?.toInt();
        if (max != null && value.length > max) {
          out.add(SchemaIssue(path, 'has ${value.length} items, max $max', fatal: false));
        }
        final items = schema['items'];
        if (items is Map<Object?, Object?>) {
          for (final (i, e) in value.indexed) {
            _check(items.cast<String, Object?>(), e, '$path[$i]', out);
          }
        }
      case String():
        final max = (schema['maxLength'] as num?)?.toInt();
        if (max != null && value.length > max) {
          out.add(SchemaIssue(path, 'is ${value.length} chars, max $max', fatal: false));
        }
      default:
        break;
    }
  }

  static void _checkObject(JsonMap schema, Map<Object?, Object?> value, String path, List<SchemaIssue> out) {
    final props = (schema['properties'] as Map<Object?, Object?>?)?.cast<String, Object?>() ?? const {};
    for (final r in (schema['required'] as List<Object?>?) ?? const <Object?>[]) {
      if (!value.containsKey(r)) out.add(SchemaIssue('$path.$r', 'is required', fatal: true));
    }
    for (final e in value.entries) {
      final sub = props[e.key];
      if (sub is Map<Object?, Object?>) {
        _check(sub.cast<String, Object?>(), e.value, '$path.${e.key}', out);
      } else if (schema['additionalProperties'] == false) {
        out.add(SchemaIssue('$path.${e.key}', 'is not allowed', fatal: false));
      }
    }
  }

  static bool _hasType(String type, Object? v) => switch (type) {
        'object' => v is Map<Object?, Object?>,
        'array' => v is List<Object?>,
        'string' => v is String,
        'integer' => v is int || (v is double && v == v.roundToDouble()),
        'number' => v is num,
        'boolean' => v is bool,
        'null' => v == null,
        _ => true,
      };

  static String _typeName(Object? v) => switch (v) {
        null => 'null',
        Map<Object?, Object?>() => 'object',
        List<Object?>() => 'array',
        String() => 'string',
        num() => 'number',
        bool() => 'boolean',
        _ => v.runtimeType.toString(),
      };
}
