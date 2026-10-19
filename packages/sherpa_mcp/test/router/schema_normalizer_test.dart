import 'package:sherpa_mcp/sherpa_mcp.dart';
import 'package:test/test.dart';

void main() {
  group('SchemaNormalizer.normalize (R11 §9.6.5)', () {
    test('inlines local \$refs and drops \$defs, also nested', () {
      final out = SchemaNormalizer.normalize({
        r'$schema': 'https://json-schema.org/draft/2020-12/schema',
        'type': 'object',
        r'$defs': {
          'point': {
            'type': 'object',
            'properties': {
              'x': {'type': 'number'},
              'y': {'type': 'number'},
            },
          },
          'line': {
            'type': 'object',
            'properties': {
              'from': {r'$ref': r'#/$defs/point'},
              'to': {r'$ref': r'#/$defs/point'},
            },
          },
        },
        'properties': {
          'line': {r'$ref': r'#/$defs/line', 'description': 'A segment'},
        },
      });
      expect(out.containsKey(r'$defs'), isFalse);
      expect(out.containsKey(r'$schema'), isFalse);
      final line = (out['properties']! as Map)['line']! as Map;
      expect(line['description'], 'A segment');
      expect(((line['properties']! as Map)['from']! as Map)['properties'], contains('x'));
      expect(out.toString(), isNot(contains(r'$ref')));
    });

    test('recursive refs stop at the depth cap; external refs are never followed', () {
      final out = SchemaNormalizer.normalize({
        'type': 'object',
        'properties': {
          'tree': {r'$ref': '#'},
          'remote': {r'$ref': 'https://example.com/schema.json'},
        },
      });
      expect(out.toString(), isNot(contains(r'$ref')));
      expect((out['properties']! as Map)['remote'], {'type': 'object'});
    });

    test('anyOf [T, null] becomes an optional T', () {
      final out = SchemaNormalizer.normalize({
        'type': 'object',
        'properties': {
          'name': {
            'anyOf': [
              {'type': 'string'},
              {'type': 'null'},
            ],
          },
          'n': {
            'type': ['integer', 'null'],
          },
          'must': {'type': 'string'},
        },
        'required': ['name', 'n', 'must'],
      });
      final p = out['properties']! as Map;
      expect(p['name'], {'type': 'string'});
      expect(p['n'], {'type': 'integer'});
      expect(out['required'], ['must']);
    });

    test('alternatives of primitives become string with a hint; objects are merged', () {
      final out = SchemaNormalizer.normalize({
        'type': 'object',
        'properties': {
          'id': {
            'oneOf': [
              {'type': 'string'},
              {'type': 'integer'},
            ],
          },
          'target': {
            'anyOf': [
              {
                'type': 'object',
                'properties': {'url': {'type': 'string'}},
                'required': ['url'],
              },
              {
                'type': 'object',
                'properties': {'path': {'type': 'string'}},
                'required': ['path'],
              },
            ],
          },
        },
      });
      final p = out['properties']! as Map;
      expect((p['id']! as Map)['type'], 'string');
      expect((p['id']! as Map)['description'], contains('integer'));
      final target = p['target']! as Map;
      expect(target['type'], 'object');
      expect((target['properties']! as Map).keys, containsAll(['url', 'path']));
      expect(target.containsKey('required'), isFalse, reason: 'intersection of required is empty');
    });

    test('drops unsupported keywords, keeps integer bounds only, anchors patterns or drops them', () {
      final out = SchemaNormalizer.normalize({
        'type': 'object',
        'title': 'Root',
        'properties': {
          'count': {'type': 'integer', 'minimum': 1, 'maximum': 10, 'title': 'Count', 'examples': [3]},
          'ratio': {'type': 'number', 'minimum': 0, 'maximum': 1},
          'url': {'type': 'string', 'format': 'uri'},
          'when': {'type': 'string', 'format': 'date-time'},
          'code': {'type': 'string', 'pattern': r'^[A-Z]{3}$'},
          'loose': {'type': 'string', 'pattern': '[a-z]+'},
          'tags': {'type': 'array', 'items': {'type': 'string'}, 'uniqueItems': true, 'contains': {'const': 'x'}},
          'map': {'type': 'object', 'patternProperties': {'^x': {'type': 'string'}}},
        },
      });
      final p = out['properties']! as Map;
      expect(out.containsKey('title'), isFalse);
      expect(p['count'], {'type': 'integer', 'minimum': 1, 'maximum': 10});
      expect(p['ratio'], {'type': 'number'});
      expect(p['url'], {'type': 'string'});
      expect(p['when'], {'type': 'string', 'format': 'date-time'});
      expect((p['code']! as Map)['pattern'], r'^[A-Z]{3}$');
      expect((p['loose']! as Map).containsKey('pattern'), isFalse);
      expect(p['tags'], {'type': 'array', 'items': {'type': 'string'}});
      expect(p['map'], {'type': 'object'});
    });

    test('defaults become description hints; descriptions are trimmed; const becomes enum', () {
      final out = SchemaNormalizer.normalize({
        'type': 'object',
        'properties': {
          'limit': {
            'type': 'integer',
            'default': 10,
            'description': 'How many results to return. This is a long explanation that keeps going and going '
                'well past the eighty character limit for parameters.',
          },
          'kind': {'const': 'issue'},
        },
      });
      final p = out['properties']! as Map;
      final limit = p['limit']! as Map;
      expect(limit.containsKey('default'), isFalse);
      expect((limit['description']! as String).length, lessThanOrEqualTo(80));
      expect(limit['description'], startsWith('How many results to return.'));
      expect(p['kind'], {'enum': ['issue'], 'type': 'string'});
    });

    test('enums over 32 values become string + "one of" hint', () {
      final values = [for (var i = 0; i < 40; i++) 'v$i'];
      final out = SchemaNormalizer.normalize({
        'type': 'object',
        'properties': {
          'big': {'type': 'string', 'enum': values},
          'small': {'type': 'string', 'enum': values.take(5).toList()},
        },
      });
      final p = out['properties']! as Map;
      expect((p['big']! as Map).containsKey('enum'), isFalse);
      expect((p['big']! as Map)['type'], 'string');
      expect((p['big']! as Map)['description'], contains('One of: v0, v1'));
      expect((p['small']! as Map)['enum'], hasLength(5));
    });

    test('never renames keys and is deterministic', () {
      final schema = {
        'type': 'object',
        'properties': {
          'Weird Key!': {'type': 'string'},
          'b': {'type': 'boolean'},
        },
        'required': ['Weird Key!'],
      };
      final a = SchemaNormalizer.normalize(schema);
      final b = SchemaNormalizer.normalize(schema);
      expect(canonicalJson(a), canonicalJson(b));
      expect((a['properties']! as Map).keys, ['Weird Key!', 'b']);
      expect(a['required'], ['Weird Key!']);
    });

    test('trimDescription keeps whole sentences within the limit', () {
      final d = 'Create an issue in a repository. Labels and assignees are optional. ${'x' * 300}';
      final t = SchemaNormalizer.trimDescription(d);
      expect(t, 'Create an issue in a repository. Labels and assignees are optional.');
      expect(SchemaNormalizer.trimDescription('short'), 'short');
      final noStop = SchemaNormalizer.trimDescription('word ' * 100, max: 50);
      expect(noStop.length, lessThanOrEqualTo(50));
      expect(noStop, endsWith('…'));
    });
  });

  group('validateArguments (R11 §9.6.6)', () {
    const schema = {
      'type': 'object',
      'properties': {
        'limit': {'type': 'integer', 'minimum': 1, 'maximum': 50},
        'ratio': {'type': 'number'},
        'tags': {'type': 'array', 'items': {'type': 'string'}},
        'draft': {'type': 'boolean'},
        'mode': {'type': 'string', 'enum': ['fast', 'slow']},
        'filter': {
          'type': 'object',
          'properties': {'q': {'type': 'string'}},
          'required': ['q'],
        },
        'note': {
          'anyOf': [
            {'type': 'string'},
            {'type': 'null'},
          ],
        },
      },
      'required': ['limit', 'note'],
      'additionalProperties': false,
    };

    test('safe coercions: "5"→5, scalar→[x], "true"→true, stringified object, missing nullable→null', () {
      final v = validateArguments(schema, {
        'limit': '5',
        'ratio': '2.5',
        'tags': 'urgent',
        'draft': 'true',
        'filter': '{"q":"bugs"}',
      });
      expect(v.errors, isEmpty);
      expect(v.value, {
        'limit': 5,
        'ratio': 2.5,
        'tags': ['urgent'],
        'draft': true,
        'filter': {'q': 'bugs'},
        'note': null,
      });
      expect(v.coercions, hasLength(6));
      expect(v.coerced, isTrue);
    });

    test('5.0 is an integer; the original args are not mutated', () {
      final args = {'limit': 5.0, 'note': 'x'};
      final v = validateArguments(schema, args);
      expect(v.isValid, isTrue);
      expect(v.value['limit'], 5);
      expect(v.value['limit'], isA<int>());
      expect(args['limit'], 5.0);
    });

    test('reports type, enum, bound, required and unknown-key errors as short paths', () {
      final v = validateArguments(schema, {
        'limit': 'many',
        'mode': 'medium',
        'filter': {'x': 1},
        'extra': true,
        'note': null,
      });
      expect(v.isValid, isFalse);
      final text = v.errors.join('\n');
      expect(text, contains(r'$.limit: expected integer'));
      expect(text, contains(r'$.mode: must be one of "fast", "slow"'));
      expect(text, contains(r'$.filter: missing required property "q"'));
      expect(text, contains('unknown property "extra"'));
      expect(validateArguments(schema, {'limit': 99, 'note': null}).errors.single, contains('must be ≤ 50'));
    });

    test('anyOf / allOf / local \$ref / pattern / lengths', () {
      const s = {
        'type': 'object',
        r'$defs': {
          'code': {'type': 'string', 'pattern': r'^[A-Z]{3}$'},
        },
        'properties': {
          'currency': {r'$ref': r'#/$defs/code'},
          'amount': {
            'allOf': [
              {'type': 'number'},
              {'minimum': 0},
            ],
          },
          'id': {
            'anyOf': [
              {'type': 'integer'},
              {'type': 'string', 'minLength': 3},
            ],
          },
          'items': {'type': 'array', 'maxItems': 2},
        },
      };
      expect(validateArguments(s, {'currency': 'EUR', 'amount': 3, 'id': 'abc', 'items': [1]}).errors, isEmpty);
      expect(validateArguments(s, {'id': '7'}).value['id'], 7, reason: 'first alternative accepts the coercion');
      final bad = validateArguments(s, {'currency': 'eur', 'amount': -1, 'id': true, 'items': [1, 2, 3]});
      expect(bad.errors, hasLength(4));
      expect(bad.errors.join(), contains('does not match the pattern'));
    });

    test('unknown keywords and external refs do not fail; error count is capped', () {
      const s = {
        'type': 'object',
        'properties': {
          'x': {r'$ref': 'https://example.com/x.json'},
          'y': {'type': 'string', 'x-vendor': 1},
        },
      };
      expect(validateArguments(s, {'x': 42, 'y': 'ok'}).errors, isEmpty);
      const many = {
        'type': 'object',
        'properties': {
          'a': {'type': 'string'},
          'b': {'type': 'string'},
          'c': {'type': 'string'},
          'd': {'type': 'string'},
          'e': {'type': 'string'},
          'f': {'type': 'string'},
        },
      };
      final v = validateArguments(many, {'a': 1, 'b': 1, 'c': 1, 'd': 1, 'e': 1, 'f': 1}, maxErrors: 3);
      expect(v.errors, hasLength(3));
    });
  });
}
