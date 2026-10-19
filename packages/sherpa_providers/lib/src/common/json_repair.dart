import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart';

/// Outcome of parsing a tool call's argument text.
///
/// Exactly one of [value] and [error] is set. [repaired] marks arguments
/// that were not valid JSON as produced, and [fixes] names the repair
/// classes for metrics.
///
/// Repair is for complete but malformed JSON (a small model's syntax slip).
/// It is not applied to calls cut off mid-arguments: the adapters complete
/// those as invalid calls ([ToolCallCutoff]). The agent runner then adds
/// two safety rules (R11 §7, §9.6.7): it never executes the calls of a turn
/// that finished with [FinishReason.length], and it always asks the user to
/// confirm a [ToolCall.repaired] call to a non-read-only tool, whatever the
/// session's grants.
@immutable
final class ArgumentsParseResult {
  const ArgumentsParseResult.ok(JsonMap this.value, {this.repaired = false, this.fixes = const {}}) : error = null;

  const ArgumentsParseResult.failed(String this.error, {this.fixes = const {}})
      : value = null,
        repaired = false;

  final JsonMap? value;
  final bool repaired;
  final String? error;
  final Set<String> fixes;

  bool get isOk => error == null;
}

/// Tolerant JSON parsing for model-produced tool arguments.
///
/// Follows the strategy of `json_repair`/`jsonrepair` summarised in R11
/// §d.3: try strict JSON first, then a lenient recursive-descent parse that
/// fixes trailing/missing commas, single and smart quotes, unquoted keys
/// and strings, Python `True/False/None`, comments, markdown fences, leading
/// prose, unescaped inner quotes, and truncated input (closing open strings,
/// arrays and objects). It never throws.
abstract final class ToolArgumentsRepair {
  static const int _maxDepth = 64;

  static final RegExp _fence = RegExp(r'```[A-Za-z0-9_+-]*[ \t]*\r?\n?([\s\S]*?)(?:```|$)');

  /// Parses [raw] as a JSON object of tool arguments.
  ///
  /// Empty or whitespace-only input means "no arguments" and yields `{}`
  /// unrepaired, since several servers stream no argument text at all for
  /// parameterless tools.
  static ArgumentsParseResult parseArguments(String raw) {
    try {
      return _parseArguments(raw);
    } on Object catch (e) {
      // Defensive: the parser is written not to throw, but a tool call
      // must never take the stream down.
      return ArgumentsParseResult.failed('Could not parse tool arguments: $e');
    }
  }

  /// Lenient parse of any JSON value. Returns the value and the fixes that
  /// were needed (empty when [text] was strict JSON); throws
  /// [FormatException] only when nothing value-like was found.
  static (Object?, Set<String>) parseValue(String text) {
    final strict = _strict(text);
    if (strict.$1) return (strict.$2, const <String>{});
    final p = _LenientParser(text);
    final v = p.parseDocument();
    return (v, p.fixes);
  }

  static ArgumentsParseResult _parseArguments(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return const ArgumentsParseResult.ok({});
    final strict = _strict(text);
    if (strict.$1) return _fromValue(strict.$2, const {});

    final fixes = <String>{};
    var body = text.startsWith('﻿') ? text.substring(1) : text;
    final fence = _fence.firstMatch(body);
    if (fence != null && !body.trimLeft().startsWith('{')) {
      body = fence.group(1)!.trim();
      fixes.add('code_fence');
    }
    final start = body.indexOf('{');
    if (start < 0) {
      final t = body.trimLeft();
      if ((t.startsWith('"') || t.startsWith("'")) && t.contains(':')) {
        // json_repair recovers a missing `{` only when a quoted key leads.
        body = '{$t';
        fixes.add('missing_open_brace');
      } else if (t.startsWith('[')) {
        return ArgumentsParseResult.failed('Tool arguments must be a JSON object, got an array', fixes: fixes);
      } else {
        return ArgumentsParseResult.failed('Tool arguments are not JSON: no "{" found', fixes: fixes);
      }
    } else if (start > 0) {
      final before = body.substring(0, start).trim();
      if (before.startsWith('[')) {
        return ArgumentsParseResult.failed('Tool arguments must be a JSON object, got an array', fixes: fixes);
      }
      if (before.isNotEmpty) fixes.add('leading_text');
      body = body.substring(start);
    }

    final parser = _LenientParser(body);
    final Object? value;
    try {
      value = parser.parseDocument();
    } on FormatException catch (e) {
      return ArgumentsParseResult.failed('Could not repair tool arguments: ${e.message}', fixes: {...fixes, ...parser.fixes});
    }
    return _fromValue(value, {...fixes, ...parser.fixes});
  }

  static ArgumentsParseResult _fromValue(Object? value, Set<String> fixes) {
    switch (value) {
      case Map():
        final map = normalizeJson(value)! as JsonMap;
        return ArgumentsParseResult.ok(map, repaired: fixes.isNotEmpty, fixes: fixes);
      case null:
        // A literal `null` from the model: treat as "no arguments".
        return ArgumentsParseResult.ok(const {}, repaired: true, fixes: {...fixes, 'null_arguments'});
      case String():
        // Arguments that were JSON-encoded twice ("stringified").
        final inner = value.trim();
        if (inner.startsWith('{') || inner.startsWith('```')) {
          final nested = _parseArguments(inner);
          if (nested.isOk) {
            return ArgumentsParseResult.ok(nested.value!, repaired: true, fixes: {...fixes, ...nested.fixes, 'stringified'});
          }
        }
        return ArgumentsParseResult.failed('Tool arguments must be a JSON object, got a string', fixes: fixes);
      case List():
        return ArgumentsParseResult.failed('Tool arguments must be a JSON object, got an array', fixes: fixes);
      default:
        return ArgumentsParseResult.failed('Tool arguments must be a JSON object, got ${value.runtimeType}',
            fixes: fixes);
    }
  }

  static (bool, Object?) _strict(String text) {
    try {
      return (true, jsonDecode(text));
    } on FormatException {
      return (false, null);
    }
  }
}

/// Thrown internally when input ends where a value must start.
final class _Truncated implements Exception {
  const _Truncated();
}

final class _LenientParser {
  _LenientParser(this._s);

  final String _s;
  int _i = 0;
  int _depth = 0;
  final Set<String> fixes = {};

  static final RegExp _strictNumber = RegExp(r'^-?(0|[1-9]\d*)(\.\d+)?([eE][+-]?\d+)?$');

  bool get _atEnd => _i >= _s.length;

  Object? parseDocument() {
    _skipWs();
    if (_atEnd) throw const FormatException('empty input');
    final Object? v;
    try {
      v = _value();
    } on _Truncated {
      throw const FormatException('unexpected end of input');
    }
    _skipWs();
    if (!_atEnd) fixes.add('trailing_content');
    return v;
  }

  void _skipWs() {
    while (_i < _s.length) {
      final c = _s.codeUnitAt(_i);
      if (c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 || c == 0xFEFF || c == 0xA0) {
        _i++;
        continue;
      }
      if (c == 0x2F && _i + 1 < _s.length) {
        final n = _s.codeUnitAt(_i + 1);
        if (n == 0x2F) {
          final nl = _s.indexOf('\n', _i);
          _i = nl < 0 ? _s.length : nl + 1;
          fixes.add('comments');
          continue;
        }
        if (n == 0x2A) {
          final end = _s.indexOf('*/', _i + 2);
          _i = end < 0 ? _s.length : end + 2;
          fixes.add('comments');
          continue;
        }
      }
      break;
    }
  }

  Object? _value() {
    _skipWs();
    while (!_atEnd && _isJunk(_s[_i])) {
      _i++;
      fixes.add('unexpected_char');
      _skipWs();
    }
    if (_atEnd) throw const _Truncated();
    final c = _s[_i];
    if (c == '{') return _object();
    if (c == '[') return _array();
    if (_closingQuote(c) != null) return _string();
    if (_isNumberStart(c)) return _number();
    return _bareValue();
  }

  void _enter() {
    if (++_depth > ToolArgumentsRepair._maxDepth) throw const FormatException('nesting too deep');
  }

  Map<String, Object?> _object() {
    _enter();
    _i++; // {
    final map = <String, Object?>{};
    var afterComma = false;
    while (true) {
      _skipWs();
      if (_atEnd) {
        fixes.add('truncated');
        break;
      }
      final c = _s[_i];
      if (c == '}') {
        if (afterComma) fixes.add('trailing_comma');
        _i++;
        break;
      }
      if (c == ']') {
        fixes.add('mismatched_bracket');
        _i++;
        break;
      }
      if (c == ',') {
        if (afterComma || map.isEmpty) fixes.add('extra_comma');
        afterComma = true;
        _i++;
        continue;
      }
      final key = _key();
      if (key == null) {
        _i++;
        fixes.add('unexpected_char');
        continue;
      }
      afterComma = false;
      if (map.containsKey(key)) fixes.add('duplicate_key');
      _skipWs();
      if (_atEnd) {
        fixes.add('truncated');
        map[key] = null;
        break;
      }
      final sep = _s[_i];
      if (sep == ':') {
        _i++;
      } else if (sep == '=') {
        _i++;
        fixes.add('equals_separator');
      } else {
        fixes.add('missing_colon');
      }
      _skipWs();
      if (_atEnd) {
        fixes.add('truncated');
        map[key] = null;
        break;
      }
      if (_s[_i] == ',' || _s[_i] == '}') {
        fixes.add('missing_value');
        map[key] = null;
        continue;
      }
      try {
        map[key] = _value();
      } on _Truncated {
        fixes.add('truncated');
        map[key] = null;
        break;
      }
      _skipWs();
      if (_atEnd) {
        fixes.add('truncated');
        break;
      }
      final d = _s[_i];
      if (d == ',') {
        afterComma = true;
        _i++;
      } else if (d == '}') {
        _i++;
        break;
      } else if (d == ']') {
        fixes.add('mismatched_bracket');
        _i++;
        break;
      } else {
        fixes.add('missing_comma');
      }
    }
    _depth--;
    return map;
  }

  List<Object?> _array() {
    _enter();
    _i++; // [
    final list = <Object?>[];
    var afterComma = false;
    while (true) {
      _skipWs();
      if (_atEnd) {
        fixes.add('truncated');
        break;
      }
      final c = _s[_i];
      if (c == ']') {
        if (afterComma) fixes.add('trailing_comma');
        _i++;
        break;
      }
      if (c == '}') {
        fixes.add('mismatched_bracket');
        _i++;
        break;
      }
      if (c == ',') {
        if (afterComma || list.isEmpty) fixes.add('extra_comma');
        afterComma = true;
        _i++;
        continue;
      }
      afterComma = false;
      try {
        list.add(_value());
      } on _Truncated {
        fixes.add('truncated');
        break;
      }
      _skipWs();
      if (_atEnd) {
        fixes.add('truncated');
        break;
      }
      final d = _s[_i];
      if (d == ',') {
        afterComma = true;
        _i++;
      } else if (d == ']') {
        _i++;
        break;
      } else if (d == '}') {
        fixes.add('mismatched_bracket');
        _i++;
        break;
      } else {
        fixes.add('missing_comma');
      }
    }
    _depth--;
    return list;
  }

  /// An object key: any quoted string, or an unquoted identifier-ish run.
  /// Null when no key could start here (caller skips the character).
  String? _key() {
    final c = _s[_i];
    if (_closingQuote(c) != null) return _string(key: true);
    final start = _i;
    while (!_atEnd && !_isKeyDelimiter(_s[_i])) {
      _i++;
    }
    if (_i == start) return null;
    fixes.add('unquoted_key');
    return _s.substring(start, _i);
  }

  String _string({bool key = false}) {
    final open = _s[_i];
    final close = _closingQuote(open)!;
    if (open == "'") {
      fixes.add('single_quotes');
    } else if (open != '"') {
      fixes.add('smart_quotes');
    }
    _i++;
    final b = StringBuffer();
    while (true) {
      if (_atEnd) {
        fixes.add('truncated');
        return b.toString();
      }
      final c = _s[_i];
      if (c == r'\') {
        if (_i + 1 >= _s.length) {
          _i++;
          fixes.add('truncated');
          return b.toString();
        }
        _escape(b);
        continue;
      }
      if (c == close || (close == '”' && c == '"')) {
        if (key ? _looksLikeKeyEnd(_i + 1) : _looksLikeStringEnd(_i + 1)) {
          _i++;
          return b.toString();
        }
        // A quote inside the text the model forgot to escape.
        fixes.add('unescaped_quote');
        b.write(c);
        _i++;
        continue;
      }
      if (c.codeUnitAt(0) < 0x20) fixes.add('control_char');
      b.write(c);
      _i++;
    }
  }

  void _escape(StringBuffer b) {
    final e = _s[_i + 1];
    _i += 2;
    switch (e) {
      case 'n':
        b.write('\n');
      case 't':
        b.write('\t');
      case 'r':
        b.write('\r');
      case 'b':
        b.write('\b');
      case 'f':
        b.write('\f');
      case 'u':
        final end = _i + 4 <= _s.length ? _i + 4 : _s.length;
        final hex = _s.substring(_i, end);
        final code = hex.length == 4 ? int.tryParse(hex, radix: 16) : null;
        if (code == null) {
          fixes.add(hex.length < 4 && end == _s.length ? 'truncated' : 'invalid_escape');
          _i = end;
        } else {
          b.writeCharCode(code);
          _i = end;
        }
      case '"' || r'\' || '/':
        b.write(e);
      default:
        if (e != "'") fixes.add('invalid_escape');
        b.write(e);
    }
  }

  /// After a would-be closing quote, a real string end is followed by a
  /// structural character (or nothing). Anything else (a letter, a digit)
  /// means the quote belonged to the text.
  bool _looksLikeStringEnd(int j) {
    var k = j;
    while (k < _s.length && (_s[k] == ' ' || _s[k] == '\t' || _s[k] == '\r' || _s[k] == '\n')) {
      k++;
    }
    if (k >= _s.length) return true;
    final c = _s[k];
    return c == ',' || c == '}' || c == ']' || c == ':' || c == '=' || _closingQuote(c) != null || c == '/' ||
        (k > j && (c == '{' || c == '['));
  }

  /// Keys rarely contain quotes, so a quote ends a key unless a word
  /// character follows it directly (`{"a" 1}` is a key and a value).
  bool _looksLikeKeyEnd(int j) => j >= _s.length || !_isWordChar(_s[j]);

  Object? _number() {
    final start = _i;
    while (!_atEnd && '+-0123456789.eE'.contains(_s[_i])) {
      _i++;
    }
    if (!_atEnd && _isWordChar(_s[_i])) {
      // `12abc`, `1st`: not a number after all.
      _i = start;
      return _bareValue();
    }
    final t = _s.substring(start, _i);
    if (_strictNumber.hasMatch(t)) return num.parse(t);
    var fixed = t.startsWith('+') ? t.substring(1) : t;
    if (fixed.startsWith('.')) fixed = '0$fixed';
    if (fixed.startsWith('-.')) fixed = '-0${fixed.substring(1)}';
    final parsed = num.tryParse(fixed);
    if (parsed != null) {
      fixes.add('number_format');
      return parsed;
    }
    final trimmed = fixed.replaceAll(RegExp(r'[.eE+-]+$'), '');
    if (trimmed.isEmpty && _atEnd) {
      fixes.add('truncated');
      return null;
    }
    final partial = num.tryParse(trimmed);
    if (partial != null) {
      fixes.add(_atEnd ? 'truncated' : 'number_format');
      return partial;
    }
    fixes.add('invalid_number');
    return t;
  }

  /// `true`/`false`/`null` in any case, Python `None`, or an unquoted
  /// string running to the next delimiter.
  Object? _bareValue() {
    final start = _i;
    while (!_atEnd && !_isValueDelimiter(_s[_i])) {
      _i++;
    }
    final word = _s.substring(start, _i).trimRight();
    if (word.isEmpty) {
      _i = start + 1;
      fixes.add('unexpected_char');
      return null;
    }
    switch (word) {
      case 'true':
        return true;
      case 'false':
        return false;
      case 'null':
        return null;
    }
    switch (word.toLowerCase()) {
      case 'true':
        fixes.add('python_literals');
        return true;
      case 'false':
        fixes.add('python_literals');
        return false;
      case 'none' || 'null' || 'nil' || 'undefined':
        fixes.add('python_literals');
        return null;
      case 'nan' || 'infinity' || '-infinity' || '+infinity':
        fixes.add('non_finite_number');
        return null;
    }
    fixes.add('unquoted_string');
    return word;
  }

  static String? _closingQuote(String c) => switch (c) {
        '"' => '"',
        "'" => "'",
        '“' || '”' => '”',
        '‘' || '’' => '’',
        _ => null,
      };

  static bool _isNumberStart(String c) => '-+.0123456789'.contains(c);

  static bool _isWordChar(String c) {
    final u = c.codeUnitAt(0);
    return (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A) || u == 0x5F;
  }

  static bool _isKeyDelimiter(String c) =>
      ':=,{}[] \t\r\n'.contains(c) || _closingQuote(c) != null;

  static bool _isValueDelimiter(String c) => ',}]\r\n'.contains(c);

  /// Characters that cannot start any value; skipped with a fix note.
  static bool _isJunk(String c) => c == ':' || c == ')' || c == '(' || c == ';';
}
