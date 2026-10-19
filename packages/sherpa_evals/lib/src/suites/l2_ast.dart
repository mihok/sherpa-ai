/// BFCL's AST checker (`bfcl_eval/eval_checker/ast_eval/ast_checker.py`,
/// Python semantics), ported for the L2 suite: name match, required
/// parameters, no unexpected parameters, type check (int accepted for
/// float), value in the possible answers (strings standardized), optional
/// parameters omitted only when `""` is a possible answer; parallel calls
/// match in any order; irrelevance passes when no call is made.
library;

import 'package:sherpa_core/sherpa_core.dart' show JsonMap;

/// One call as the model made it (name as offered to the model).
typedef AstCall = ({String name, JsonMap arguments});

/// A checker verdict.
final class AstVerdict {
  const AstVerdict.ok() : valid = true, error = null;

  const AstVerdict.fail(String this.error) : valid = false;

  final bool valid;
  final String? error;

  @override
  String toString() => valid ? 'valid' : 'invalid: $error';
}

/// BFCL's `standardize_string`: drop spaces and `,./-_*^`, lowercase, and
/// single quotes become double quotes.
String standardizeString(String s) => s.replaceAll(RegExp(r'[ ,./\-_*^]'), '').toLowerCase().replaceAll("'", '"');

/// Function names as offered to the model (dots are not valid there).
String offeredName(String bfclName) => bfclName.replaceAll('.', '_');

/// Checks one [call] against one ground-truth entry `{name: {param: [values]}}`
/// with the function's [description] (`name`, `parameters`).
AstVerdict checkSimple(JsonMap description, AstCall call, JsonMap answer) {
  final expected = answer.keys.single;
  final possible = (answer[expected]! as Map).cast<String, Object?>();
  if (call.name != offeredName(expected)) return AstVerdict.fail('wrong function: ${call.name}, wanted ${offeredName(expected)}');
  final params = (description['parameters']! as Map).cast<String, Object?>();
  final props = ((params['properties'] as Map?) ?? const {}).cast<String, Object?>();
  final required = ((params['required'] as List?) ?? const []).cast<String>();
  for (final r in required) {
    if (!call.arguments.containsKey(r)) return AstVerdict.fail('missing required parameter $r');
  }
  for (final e in call.arguments.entries) {
    final name = e.key;
    var value = e.value;
    if (!props.containsKey(name) || !possible.containsKey(name)) return AstVerdict.fail('unexpected parameter $name');
    final schema = (props[name]! as Map).cast<String, Object?>();
    final type = schema['type'] as String?;
    final itemType = ((schema['items'] as Map?)?['type']) as String?;
    if (type == 'number' && value is int) value = value.toDouble();
    if (!_typeOk(value, type, itemType)) return AstVerdict.fail('$name: wrong type ${value.runtimeType} for $type');
    final options = (possible[name]! as List).cast<Object?>();
    final ok = switch (type) {
      'object' => _dictOk(value, options),
      'array' when itemType == 'object' => _listOfDictsOk(value, options),
      'string' => _stringOk(value as String, options),
      'array' => _listOk(value! as List<Object?>, options),
      _ => options.any((o) => _numOrEq(o, value)),
    };
    if (!ok) return AstVerdict.fail('$name: value ${_show(value)} not in ${_show(options)}');
  }
  for (final e in possible.entries) {
    if (!call.arguments.containsKey(e.key) && !(e.value! as List).contains('')) {
      return AstVerdict.fail('optional parameter ${e.key} not provided');
    }
  }
  return const AstVerdict.ok();
}

/// `multiple`: exactly one call, against the one expected function.
AstVerdict checkMultiple(List<JsonMap> descriptions, List<AstCall> calls, List<JsonMap> answers) {
  if (calls.length != answers.length) return AstVerdict.fail('${calls.length} calls, wanted ${answers.length}');
  final d = _find(descriptions, answers.first.keys.single);
  if (d == null) return const AstVerdict.fail('ground truth names an unknown function');
  return checkSimple(d, calls.first, answers.first);
}

/// `parallel`: the same number of calls, each answer matched by a distinct
/// call, in any order.
AstVerdict checkParallel(List<JsonMap> descriptions, List<AstCall> calls, List<JsonMap> answers) {
  if (calls.length != answers.length) return AstVerdict.fail('${calls.length} calls, wanted ${answers.length}');
  final used = <int>{};
  for (final (i, a) in answers.indexed) {
    final d = _find(descriptions, a.keys.single);
    if (d == null) return const AstVerdict.fail('ground truth names an unknown function');
    String? last;
    var matched = false;
    for (var j = 0; j < calls.length; j++) {
      if (used.contains(j)) continue;
      final v = checkSimple(d, calls[j], a);
      if (v.valid) {
        used.add(j);
        matched = true;
        break;
      }
      last = v.error;
    }
    if (!matched) return AstVerdict.fail('no call matches expected #$i${last == null ? '' : ' ($last)'}');
  }
  return const AstVerdict.ok();
}

/// `irrelevance`: none of the functions fits, so no call may be made.
AstVerdict checkIrrelevance(List<AstCall> calls) =>
    calls.isEmpty ? const AstVerdict.ok() : AstVerdict.fail('called ${calls.map((c) => c.name).join(', ')}');

/// Dispatches on the BFCL [category].
AstVerdict checkCase(String category, List<JsonMap> descriptions, List<AstCall> calls, List<JsonMap> answers) => switch (category) {
      'simple' => calls.length != 1
          ? AstVerdict.fail('${calls.length} calls, wanted 1')
          : checkSimple(descriptions.single, calls.single, answers.single),
      'multiple' => checkMultiple(descriptions, calls, answers),
      'parallel' => checkParallel(descriptions, calls, answers),
      'irrelevance' => checkIrrelevance(calls),
      _ => throw ArgumentError.value(category, 'category'),
    };

JsonMap? _find(List<JsonMap> ds, String bfclName) =>
    ds.where((d) => d['bfclName'] == bfclName || d['name'] == offeredName(bfclName)).firstOrNull;

bool _typeOk(Object? v, String? type, String? itemType) => switch (type) {
      null => true,
      'string' => v is String,
      'integer' => v is int,
      'number' => v is num,
      'boolean' => v is bool,
      'object' => v is Map,
      'array' => v is List && (itemType == null || v.every((e) => _typeOk(e is int && itemType == 'number' ? e.toDouble() : e, itemType, null))),
      _ => true,
    };

bool _numOrEq(Object? a, Object? b) => a is num && b is num ? a == b : a == b;

bool _stringOk(String v, List<Object?> options) {
  final s = standardizeString(v);
  return options.any((o) => o is String && standardizeString(o) == s);
}

Object? _std(Object? v) => switch (v) {
      String() => standardizeString(v),
      List() => [for (final e in v) _std(e)],
      _ => v,
    };

bool _deepEq(Object? a, Object? b) {
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_deepEq(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    return a.keys.every((k) => b.containsKey(k) && _deepEq(a[k], b[k]));
  }
  return _numOrEq(a, b);
}

bool _listOk(List<Object?> v, List<Object?> options) {
  final s = _std(v);
  return options.any((o) => o is List && _deepEq(_std(o), s));
}

/// BFCL's `dict_checker`: some candidate dict accepts every key's value
/// and has `""` among the options of every key the model left out.
bool _dictOk(Object? v, List<Object?> options) {
  if (v is! Map) return false;
  for (final cand in options) {
    if (cand is! Map) continue;
    var ok = true;
    for (final e in v.entries) {
      final allowed = cand[e.key];
      if (allowed is! List) {
        ok = false;
        break;
      }
      final sv = _std(e.value);
      if (!allowed.any((x) => _deepEq(_std(x), sv))) {
        ok = false;
        break;
      }
    }
    for (final e in cand.entries) {
      if (!v.containsKey(e.key) && !(e.value is List && (e.value as List).contains(''))) ok = false;
    }
    if (ok) return true;
  }
  return false;
}

bool _listOfDictsOk(Object? v, List<Object?> options) {
  if (v is! List) return false;
  for (final cand in options) {
    if (cand is! List || cand.length != v.length) continue;
    var ok = true;
    for (var i = 0; i < v.length && ok; i++) {
      ok = _dictOk(v[i], [cand[i]]);
    }
    if (ok) return true;
  }
  return false;
}

String _show(Object? v) {
  final s = '$v';
  return s.length > 80 ? '${s.substring(0, 79)}…' : s;
}

/// The oracle answer for a ground-truth entry: the first non-empty possible
/// value of each parameter (recursively for dict values); a parameter whose
/// only option is `""` is omitted. (BFCL lists `""` first for some
/// required parameters.)
AstCall oracleCall(JsonMap answer) {
  final name = answer.keys.single;
  final params = (answer[name]! as Map).cast<String, Object?>();
  Object? first(List<Object?> options) => options.firstWhere((o) => o != '', orElse: () => '');
  Object? pick(Object? opt) => switch (opt) {
        Map() => {
            for (final e in opt.entries)
              if (e.value is List && first((e.value as List).cast<Object?>()) != '') e.key: pick(first((e.value as List).cast<Object?>())),
          },
        List() when opt.isNotEmpty && opt.first is Map => [for (final x in opt) pick(x)],
        _ => opt,
      };
  return (
    name: offeredName(name),
    arguments: {
      for (final e in params.entries)
        if (first((e.value! as List).cast<Object?>()) != '') e.key: pick(first((e.value! as List).cast<Object?>())),
    },
  );
}
