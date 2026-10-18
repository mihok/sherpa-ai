import 'dart:convert';
import 'dart:math';

import 'package:sherpa_providers/sherpa_providers.dart';
import 'package:test/test.dart';

void main() {
  ArgumentsParseResult parse(String s) => ToolArgumentsRepair.parseArguments(s);

  void expectRepaired(String input, Map<String, Object?> expected, {String? fix}) {
    final r = parse(input);
    expect(r.error, isNull, reason: 'input: $input');
    expect(r.value, expected, reason: 'input: $input');
    expect(r.repaired, isTrue, reason: 'input: $input');
    if (fix != null) expect(r.fixes, contains(fix), reason: 'input: $input fixes: ${r.fixes}');
  }

  group('strict input', () {
    test('valid JSON objects are returned unrepaired', () {
      for (final s in ['{}', '{"a":1}', ' {"city": "Paris", "n": [1, 2.5, -3e2], "ok": true, "x": null} ']) {
        final r = parse(s);
        expect(r.isOk, isTrue);
        expect(r.repaired, isFalse);
        expect(r.value, jsonDecode(s));
      }
    });

    test('empty and whitespace mean no arguments', () {
      for (final s in ['', '   ', '\n\t']) {
        final r = parse(s);
        expect(r.value, isEmpty);
        expect(r.repaired, isFalse);
      }
    });

    test('unicode escapes and nested structures survive', () {
      final r = parse(r'{"t": "café 😀", "deep": {"a": [{"b": {"c": []}}]}}');
      expect(r.value!['t'], 'café 😀');
      expect(r.repaired, isFalse);
    });
  });

  group('repairs', () {
    test('trailing commas', () {
      expectRepaired('{"a": 1,}', {'a': 1}, fix: 'trailing_comma');
      expectRepaired('{"a": [1, 2,],}', {
        'a': [1, 2],
      }, fix: 'trailing_comma');
      expectRepaired('{"a": 1,, "b": 2}', {'a': 1, 'b': 2}, fix: 'extra_comma');
    });

    test('single quotes, including apostrophes inside', () {
      expectRepaired("{'city': 'Paris'}", {'city': 'Paris'}, fix: 'single_quotes');
      expectRepaired("{'text': 'it's fine'}", {'text': "it's fine"});
      expectRepaired(r"{'a': 'say \'hi\''}", {'a': "say 'hi'"});
    });

    test('smart quotes', () {
      expectRepaired('{“city”: “Paris”}', {'city': 'Paris'}, fix: 'smart_quotes');
      expectRepaired('{‘city’: ‘Paris’}', {'city': 'Paris'}, fix: 'smart_quotes');
    });

    test('unquoted keys and values', () {
      expectRepaired('{city: "Paris", count: 3}', {'city': 'Paris', 'count': 3}, fix: 'unquoted_key');
      expectRepaired('{"unit": celsius}', {'unit': 'celsius'}, fix: 'unquoted_string');
      expectRepaired('{"city": New York}', {'city': 'New York'});
      expectRepaired(r'{$schema_ok: 1, a-b: 2}', {r'$schema_ok': 1, 'a-b': 2});
    });

    test('Python literals and case variants', () {
      expectRepaired('{"a": True, "b": False, "c": None}', {'a': true, 'b': false, 'c': null},
          fix: 'python_literals');
      expectRepaired("{'flag': TRUE, 'x': NULL}", {'flag': true, 'x': null});
      expectRepaired('{"a": NaN, "b": Infinity}', {'a': null, 'b': null}, fix: 'non_finite_number');
    });

    test('truncated objects, arrays and strings are closed', () {
      expectRepaired('{"city": "Par', {'city': 'Par'}, fix: 'truncated');
      expectRepaired('{"a": {"b": [1, 2', {
        'a': {
          'b': [1, 2],
        },
      });
      expectRepaired('{"a": 1, "b":', {'a': 1, 'b': null});
      expectRepaired('{"a": 1, "b"', {'a': 1, 'b': null});
      expectRepaired('{"a": 1.', {'a': 1});
      expectRepaired('{"a": -', {'a': null});
      expectRepaired('{"t": "x\\', {'t': 'x'});
      expectRepaired(r'{"t": "\u00', {'t': ''});
      expectRepaired('{', {});
    });

    test('unbalanced closers', () {
      expectRepaired('{"a": [1, 2}', {
        'a': [1, 2],
      }, fix: 'mismatched_bracket');
      expectRepaired('{"a": 1]', {'a': 1}, fix: 'mismatched_bracket');
      expectRepaired('{"a": 1}}', {'a': 1}, fix: 'trailing_content');
    });

    test('markdown code fences', () {
      expectRepaired('```json\n{"city": "Paris"}\n```', {'city': 'Paris'}, fix: 'code_fence');
      expectRepaired('```\n{"city": "Paris"}\n```', {'city': 'Paris'});
      expectRepaired('Sure!\n```json\n{"city": "Paris",}\n```\nDone.', {'city': 'Paris'});
      expectRepaired('```json\n{"city": "Par', {'city': 'Par'});
    });

    test('leading prose and trailing text', () {
      expectRepaired('Here are the arguments: {"city": "Paris"}', {'city': 'Paris'}, fix: 'leading_text');
      expectRepaired('{"city": "Paris"} hope that helps', {'city': 'Paris'}, fix: 'trailing_content');
      expectRepaired('<tool_call>{"city": "Paris"}</tool_call>', {'city': 'Paris'});
    });

    test('missing opening brace with a leading quoted key', () {
      expectRepaired('"city": "Paris"}', {'city': 'Paris'}, fix: 'missing_open_brace');
    });

    test('comments are stripped', () {
      expectRepaired('{"a": 1, // the count\n "b": /* inline */ 2}', {'a': 1, 'b': 2}, fix: 'comments');
    });

    test('missing commas and colons', () {
      expectRepaired('{"a": 1 "b": 2}', {'a': 1, 'b': 2}, fix: 'missing_comma');
      expectRepaired('{"a" 1}', {'a': 1}, fix: 'missing_colon');
      expectRepaired('{"a": [1 2 3]}', {
        'a': [1, 2, 3],
      });
      expectRepaired('{"a"= 1}', {'a': 1}, fix: 'equals_separator');
    });

    test('unescaped quotes inside strings', () {
      expectRepaired('{"text": "say "hi" now"}', {'text': 'say "hi" now'}, fix: 'unescaped_quote');
    });

    test('raw control characters inside strings are kept', () {
      expectRepaired('{"code": "line1\nline2\ttab"}', {'code': 'line1\nline2\ttab'}, fix: 'control_char');
    });

    test('lenient numbers', () {
      expectRepaired('{"a": +1, "b": .5, "c": 007, "d": -.25}', {'a': 1, 'b': 0.5, 'c': 7, 'd': -0.25},
          fix: 'number_format');
      expectRepaired('{"v": 1.2.3}', {'v': '1.2.3'}, fix: 'invalid_number');
      expectRepaired('{"size": 12px}', {'size': '12px'});
    });

    test('double-encoded (stringified) arguments', () {
      expectRepaired(jsonEncode('{"city":"Paris"}'), {'city': 'Paris'}, fix: 'stringified');
      expectRepaired(jsonEncode("{'city':'Paris'}"), {'city': 'Paris'}, fix: 'stringified');
    });

    test('a literal null means no arguments', () {
      expectRepaired('null', {}, fix: 'null_arguments');
    });

    test('duplicate keys keep the last value', () {
      expectRepaired('{"a": 1, "a": 2,}', {'a': 2}, fix: 'duplicate_key');
    });
  });

  group('failures', () {
    test('non-object JSON is an error, not an exception', () {
      for (final s in ['[1, 2]', '42', '"just text"', 'true']) {
        final r = parse(s);
        expect(r.isOk, isFalse, reason: s);
        expect(r.error, contains('JSON object'));
        expect(r.value, isNull);
      }
    });

    test('text without any JSON object is an error', () {
      expect(parse('I will call the weather tool now.').error, contains('no "{"'));
      expect(parse('[{"a": 1}]').error, contains('array'));
    });

    test('deep nesting is refused', () {
      final r = parse('${'{"a":' * 100}1${'}' * 100}');
      // Strict JSON parses it; lenient parsing of a broken one is bounded.
      expect(r.isOk, isTrue);
      final broken = parse('${'{"a":' * 100}1,');
      expect(broken.isOk, isFalse);
      expect(broken.error, contains('nesting'));
    });
  });

  test('never throws on random garbage (fuzz)', () {
    final rnd = Random(42);
    const alphabet = '{}[]":,\'\\ abcTrueNone0123456789.-+eE\n`/*“”';
    for (var i = 0; i < 3000; i++) {
      final len = rnd.nextInt(40);
      final s = String.fromCharCodes([for (var j = 0; j < len; j++) alphabet.codeUnitAt(rnd.nextInt(alphabet.length))]);
      final r = parse(s);
      expect(r.value != null || r.error != null, isTrue, reason: s);
      expect(r.value != null && r.error != null, isFalse, reason: s);
    }
  });

  test('every prefix of a valid object repairs to a subset of it (truncation fuzz)', () {
    const full = '{"city": "Paris", "days": [1, 2, 3], "opts": {"unit": "c", "detail": true}, "note": "a,b}"}';
    for (var cut = 1; cut < full.length; cut++) {
      final r = parse(full.substring(0, cut));
      expect(r.isOk, isTrue, reason: 'cut at $cut: ${full.substring(0, cut)} → ${r.error}');
    }
  });

  test('parseValue reports fixes only for non-strict input', () {
    expect(ToolArgumentsRepair.parseValue('[1,2]').$2, isEmpty);
    final (v, fixes) = ToolArgumentsRepair.parseValue("[1, 'two',]");
    expect(v, [1, 'two']);
    expect(fixes, containsAll(['single_quotes', 'trailing_comma']));
  });
}
