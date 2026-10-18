import 'dart:convert';

import '../common/json.dart';

/// Tolerant JSON decoding for model-written summaries.
///
/// Small local models and providers without structured output regularly
/// emit almost-JSON. The repair rules follow `josdejong/jsonrepair` and
/// `mangiucugna/json_repair` (R11 §d.3): strict parse first; then strip think
/// blocks and code fences, quote bare keys, normalise single and smart
/// quotes, map Python literals, drop comments and ellipses, add missing
/// commas, drop trailing ones, and close truncated strings and brackets.
/// Trailing text after the first complete value is ignored, and a value that
/// was stringified twice is decoded again.
///
/// Kept local to the core (rather than shared with `sherpa_providers`) so the
/// core keeps depending on nothing but `meta`.
abstract final class JsonRepair {
  static final RegExp _think = RegExp(r'<(think|thinking|reasoning)>[\s\S]*?</\1>', caseSensitive: false);
  static final RegExp _thinkClose = RegExp(r'</(think|thinking|reasoning)>', caseSensitive: false);
  static final RegExp _fence = RegExp(r'```[A-Za-z0-9_-]*[ \t]*\n?([\s\S]*?)(?:```|$)');

  /// The first JSON value in [raw], or null when nothing is recoverable.
  static Object? decode(String raw) {
    final whole = _tryDecode(raw.trim());
    if (whole.ok && whole.value is! num && whole.value is! bool && whole.value != null) {
      final v = _unwrapStringified(whole.value);
      if (v is Map || v is List) return v;
    }
    final text = extract(raw);
    if (text == null) return null;
    final strict = _tryDecode(text);
    if (strict.ok) return _unwrapStringified(strict.value);
    final repaired = _tryDecode(repair(text));
    return repaired.ok ? _unwrapStringified(repaired.value) : null;
  }

  /// Like [decode] but only accepts a JSON object.
  static JsonMap? decodeObject(String raw) {
    final v = decode(raw);
    return v is Map<Object?, Object?> ? normalizeJson(v)! as JsonMap : null;
  }

  /// Strips reasoning blocks and code fences and returns the text from the
  /// first `{` or `[` on, or null when there is none.
  static String? extract(String raw) {
    var text = raw.replaceAll(_think, '');
    // Templates that put the opening <think> in the prompt leave only the
    // closing tag in the output.
    final closes = _thinkClose.allMatches(text).toList();
    if (closes.isNotEmpty) text = text.substring(closes.last.end);
    for (final m in _fence.allMatches(text)) {
      final body = m[1] ?? '';
      if (body.contains('{') || body.contains('[')) {
        text = body;
        break;
      }
    }
    final brace = text.indexOf('{');
    final bracket = text.indexOf('[');
    final start = brace < 0 ? bracket : (bracket < 0 ? brace : (brace < bracket ? brace : bracket));
    return start < 0 ? null : text.substring(start);
  }

  /// Rewrites almost-JSON [input] into syntactically valid JSON text.
  static String repair(String input) => _Repairer(input).run();

  static ({bool ok, Object? value}) _tryDecode(String text) {
    try {
      return (ok: true, value: jsonDecode(text));
    } on FormatException {
      return (ok: false, value: null);
    }
  }

  static Object? _unwrapStringified(Object? value) {
    if (value is! String) return value;
    final t = value.trim();
    if (!(t.startsWith('{') || t.startsWith('['))) return value;
    final inner = _tryDecode(t);
    if (inner.ok) return inner.value;
    final repaired = _tryDecode(repair(t));
    return repaired.ok ? repaired.value : value;
  }
}

enum _Tok { openObj, openArr, closeObj, closeArr, colon, comma, string, number, word, end }

final class _Token {
  const _Token(this.type, [this.text = '']);
  final _Tok type;
  final String text;
}

/// One open container while rebuilding the output.
final class _Frame {
  _Frame({required this.isObject});
  final bool isObject;
  bool hasItems = false;

  /// For objects: 0 = expecting a key, 1 = expecting ':', 2 = expecting a value.
  int phase = 0;
}

final class _Repairer {
  _Repairer(this._s);

  final String _s;
  int _i = 0;
  final StringBuffer _out = StringBuffer();
  final List<_Frame> _stack = [];
  bool _done = false;
  bool _started = false;
  int _syntheticKeys = 0;

  static const String _structural = '{}[]:,';
  static const Map<String, String> _quotePairs = {
    '"': '"',
    "'": "'",
    '`': '`',
    '“': '”',
    '”': '”',
    '‘': '’',
    '’': '’',
  };

  String run() {
    while (!_done) {
      final t = _next();
      if (t.type == _Tok.end) break;
      _consume(t);
    }
    _closeAll();
    return _out.toString();
  }

  void _consume(_Token t) {
    switch (t.type) {
      case _Tok.comma:
        // Commas are re-derived from structure: this drops trailing and
        // duplicate commas and adds missing ones.
        break;
      case _Tok.colon:
        final top = _stack.lastOrNull;
        if (top != null && top.isObject && top.phase == 1) {
          _out.write(':');
          top.phase = 2;
        }
      case _Tok.closeObj || _Tok.closeArr:
        _close(t.type == _Tok.closeObj);
      case _Tok.openObj || _Tok.openArr:
        if (!_beginValue()) return;
        final obj = t.type == _Tok.openObj;
        _out.write(obj ? '{' : '[');
        _stack.add(_Frame(isObject: obj));
      case _Tok.string || _Tok.number || _Tok.word:
        _scalar(t);
      case _Tok.end:
        break;
    }
  }

  /// Prepares the output for a value in the current container. Returns false
  /// when the value must be dropped (trailing garbage after the top level).
  bool _beginValue() {
    final top = _stack.lastOrNull;
    if (top == null) {
      if (_started) {
        _done = true;
        return false;
      }
      _started = true;
      return true;
    }
    if (top.isObject) {
      if (top.phase == 0) {
        // A value where a key belongs: give it a synthetic key.
        if (top.hasItems) _out.write(',');
        top.hasItems = true;
        _out.write('"_${_syntheticKeys++}":');
      } else if (top.phase == 1) {
        _out.write(':');
      }
      top.phase = 0;
    } else {
      if (top.hasItems) _out.write(',');
      top.hasItems = true;
    }
    return true;
  }

  void _scalar(_Token t) {
    final top = _stack.lastOrNull;
    if (top != null && top.isObject && top.phase == 0) {
      if (top.hasItems) _out.write(',');
      top.hasItems = true;
      _out.write(jsonEncode(t.text));
      top.phase = 1;
      return;
    }
    if (!_beginValue()) return;
    _out.write(_renderValue(t));
    if (top == null) _done = true;
  }

  String _renderValue(_Token t) {
    switch (t.type) {
      case _Tok.string:
        return jsonEncode(t.text);
      case _Tok.number:
        final n = num.tryParse(t.text.startsWith('+') ? t.text.substring(1) : t.text);
        return n == null || n.isNaN || n.isInfinite ? jsonEncode(t.text) : jsonEncode(n);
      default:
        return switch (t.text.toLowerCase()) {
          'true' => 'true',
          'false' => 'false',
          'null' || 'none' || 'nil' || 'undefined' || 'nan' || 'infinity' => 'null',
          _ => jsonEncode(t.text),
        };
    }
  }

  void _close(bool object) {
    if (_stack.isEmpty) return;
    final depth = _stack.lastIndexWhere((f) => f.isObject == object);
    if (depth < 0) return;
    while (_stack.length > depth) {
      _closeTop();
    }
    if (_stack.isEmpty) _done = true;
  }

  void _closeTop() {
    final f = _stack.removeLast();
    if (f.isObject) {
      if (f.phase == 1) _out.write(':null');
      if (f.phase == 2) _out.write('null');
      _out.write('}');
    } else {
      _out.write(']');
    }
  }

  void _closeAll() {
    while (_stack.isNotEmpty) {
      _closeTop();
    }
  }

  // ---------------------------------------------------------------------------
  // Tokenizer

  _Token _next() {
    while (_i < _s.length) {
      final c = _s[_i];
      if (c.trim().isEmpty) {
        _i++;
        continue;
      }
      if (c == '/' && _i + 1 < _s.length && _s[_i + 1] == '/') {
        _skipLine();
        continue;
      }
      if (c == '/' && _i + 1 < _s.length && _s[_i + 1] == '*') {
        final end = _s.indexOf('*/', _i + 2);
        _i = end < 0 ? _s.length : end + 2;
        continue;
      }
      if (c == '#') {
        _skipLine();
        continue;
      }
      if (_s.startsWith('...', _i) || c == '…') {
        _i += c == '…' ? 1 : 3;
        continue;
      }
      if (_structural.contains(c)) {
        _i++;
        return _Token(switch (c) {
          '{' => _Tok.openObj,
          '[' => _Tok.openArr,
          '}' => _Tok.closeObj,
          ']' => _Tok.closeArr,
          ':' => _Tok.colon,
          _ => _Tok.comma,
        });
      }
      final closer = _quotePairs[c];
      if (closer != null) return _string(closer);
      if (c == '-' || c == '+' || c == '.' || (c.codeUnitAt(0) >= 0x30 && c.codeUnitAt(0) <= 0x39)) {
        return _number();
      }
      return _word();
    }
    return const _Token(_Tok.end);
  }

  void _skipLine() {
    final nl = _s.indexOf('\n', _i);
    _i = nl < 0 ? _s.length : nl + 1;
  }

  /// A quote only closes the string when what follows looks like structure
  /// (or the next string, when a comma is missing); otherwise it is content
  /// the model forgot to escape.
  bool _closesHere(int at) {
    var j = at + 1;
    while (j < _s.length && _s[j].trim().isEmpty) {
      j++;
    }
    return j >= _s.length || _structural.contains(_s[j]) || (j > at + 1 && _quotePairs.containsKey(_s[j]));
  }

  _Token _string(String closer) {
    final open = _s[_i];
    _i++;
    final b = StringBuffer();
    while (_i < _s.length) {
      final c = _s[_i];
      if (c == r'\' && _i + 1 < _s.length) {
        _i += _escape(b);
        continue;
      }
      final isCloser = c == closer || (open == '"' && c == '”') || (closer == '”' && c == '"');
      if (isCloser && _closesHere(_i)) {
        _i++;
        return _Token(_Tok.string, b.toString());
      }
      b.write(c);
      _i++;
    }
    return _Token(_Tok.string, b.toString());
  }

  /// Appends one escape sequence at [_i] to [b]; returns chars consumed.
  int _escape(StringBuffer b) {
    final e = _s[_i + 1];
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
        if (_i + 6 <= _s.length) {
          final code = int.tryParse(_s.substring(_i + 2, _i + 6), radix: 16);
          if (code != null) {
            b.writeCharCode(code);
            return 6;
          }
        }
        b.write('u');
      default:
        b.write(e);
    }
    return 2;
  }

  _Token _number() {
    final start = _i;
    while (_i < _s.length && '0123456789eE+-.xXabcdefABCDEF_'.contains(_s[_i])) {
      _i++;
    }
    return _Token(_Tok.number, _s.substring(start, _i));
  }

  _Token _word() {
    final start = _i;
    while (_i < _s.length) {
      final c = _s[_i];
      if (c.trim().isEmpty || _structural.contains(c) || _quotePairs.containsKey(c)) break;
      _i++;
    }
    if (_i == start) _i++;
    return _Token(_Tok.word, _s.substring(start, _i));
  }
}
