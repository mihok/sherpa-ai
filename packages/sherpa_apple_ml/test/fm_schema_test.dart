import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa_apple_ml/sherpa_apple_ml.dart';
import 'package:sherpa_core/sherpa_core.dart';

JsonMap prop(JsonMap object, String name) =>
    ((object['properties']! as List).cast<JsonMap>()).firstWhere((p) => p['name'] == name);

void main() {
  final c = FmSchemaConverter();

  test('object properties, required → optional flags, primitives with guides', () {
    final r = c.convert({
      'type': 'object',
      'description': 'Args',
      'properties': {
        'city': {'type': 'string', 'description': 'City'},
        'unit': {
          'type': 'string',
          'enum': ['c', 'f'],
        },
        'days': {'type': 'integer', 'minimum': 1, 'exclusiveMaximum': 8},
        'ratio': {'type': 'number', 'maximum': 1.5},
        'exact': {'type': 'boolean'},
        'code': {'type': 'string', 'pattern': r'^[A-Z]{3}$'},
        'kind': {'const': 'weather'},
      },
      'required': ['city', 'days'],
    }, rootName: 'get_weather');
    final root = r.ir['root']! as JsonMap;
    expect(root['kind'], 'object');
    expect(root['name'], 'get_weather');
    expect(root['description'], 'Args');
    expect(prop(root, 'city')['optional'], isFalse);
    expect(prop(root, 'city')['description'], 'City');
    expect(prop(root, 'unit')['optional'], isTrue);
    expect((prop(root, 'unit')['schema']! as JsonMap)['anyOf'], ['c', 'f']);
    expect(prop(root, 'days')['schema'], {'kind': 'integer', 'minimum': 1, 'maximum': 7});
    expect(prop(root, 'ratio')['schema'], {'kind': 'number', 'maximum': 1.5});
    expect(prop(root, 'exact')['schema'], {'kind': 'boolean'});
    expect((prop(root, 'code')['schema']! as JsonMap)['pattern'], r'^[A-Z]{3}$');
    expect((prop(root, 'kind')['schema']! as JsonMap)['constant'], 'weather');
    expect(r.warnings, isEmpty);
  });

  test('nested objects get unique names; arrays keep bounds; null unions are optional', () {
    final r = c.convert({
      'type': 'object',
      'properties': {
        'a': {
          'type': 'object',
          'properties': {
            'b': {'type': 'object', 'properties': <String, Object?>{}},
          },
        },
        'tags': {
          'type': 'array',
          'items': {'type': 'string'},
          'minItems': 1,
          'maxItems': 3,
        },
        'note': {
          'type': ['string', 'null'],
        },
      },
      'required': ['a', 'tags', 'note'],
    }, rootName: 't');
    final root = r.ir['root']! as JsonMap;
    final a = prop(root, 'a')['schema']! as JsonMap;
    expect(a['name'], 't_a');
    expect((prop(a, 'b')['schema']! as JsonMap)['name'], 't_a_b');
    expect(prop(root, 'tags')['schema'], {
      'kind': 'array',
      'items': {'kind': 'string'},
      'minItems': 1,
      'maxItems': 3,
    });
    expect(prop(root, 'note')['optional'], isTrue);
  });

  test(r'$ref to an object becomes a dependency (recursion works); primitive refs are inlined', () {
    final r = c.convert({
      'type': 'object',
      r'$defs': {
        'Node': {
          'type': 'object',
          'properties': {
            'children': {
              'type': 'array',
              'items': {r'$ref': r'#/$defs/Node'},
            },
          },
        },
        'Color': {
          'type': 'string',
          'enum': ['red', 'blue'],
        },
      },
      'properties': {
        'tree': {r'$ref': r'#/$defs/Node'},
        'color': {r'$ref': r'#/$defs/Color'},
      },
    }, rootName: 'draw');
    final root = r.ir['root']! as JsonMap;
    expect(prop(root, 'tree')['schema'], {'kind': 'ref', 'name': 'Node'});
    expect((prop(root, 'color')['schema']! as JsonMap)['anyOf'], ['red', 'blue']);
    final deps = (r.ir['dependencies']! as List).cast<JsonMap>();
    expect(deps.single['name'], 'Node');
    final children = prop(deps.single, 'children')['schema']! as JsonMap;
    expect(children['items'], {'kind': 'ref', 'name': 'Node'});
  });

  test('anyOf: constants collapse to a string guide; objects become a named choice', () {
    final r = c.convert({
      'type': 'object',
      'properties': {
        'mode': {
          'anyOf': [
            {'const': 'fast'},
            {'const': 'slow'},
          ],
        },
        'target': {
          'oneOf': [
            {
              'type': 'object',
              'properties': {
                'url': {'type': 'string'},
              },
            },
            {
              'type': 'object',
              'properties': {
                'path': {'type': 'string'},
              },
            },
          ],
        },
      },
    }, rootName: 'open');
    final root = r.ir['root']! as JsonMap;
    expect(prop(root, 'mode')['schema'], {
      'kind': 'string',
      'anyOf': ['fast', 'slow'],
    });
    final target = prop(root, 'target')['schema']! as JsonMap;
    expect(target['kind'], 'anyOf');
    expect((target['choices']! as List).cast<JsonMap>().map((x) => x['name']), ['open_target_0', 'open_target_1']);
  });

  test('lossy constructs are converted conservatively, with warnings', () {
    final r = c.convert({
      'type': 'object',
      'properties': {
        'meta': {
          'type': 'object',
          'additionalProperties': {'type': 'string'},
        },
        'anything': <String, Object?>{},
        'count': {
          'type': 'integer',
          'enum': [1, 2],
        },
        'both': {
          'allOf': [
            {
              'type': 'object',
              'properties': {
                'x': {'type': 'string'},
              },
            },
            {
              'properties': {
                'y': {'type': 'string'},
              },
              'required': ['y'],
            },
          ],
        },
      },
    }, rootName: 'odd');
    final root = r.ir['root']! as JsonMap;
    expect((prop(root, 'anything')['schema']! as JsonMap)['kind'], 'string');
    final both = prop(root, 'both')['schema']! as JsonMap;
    expect((both['properties']! as List).cast<JsonMap>().map((p) => p['name']), ['x', 'y']);
    expect(prop(both, 'y')['optional'], isFalse);
    expect(
      r.warnings.join('\n'),
      allOf(contains('dynamic keys'), contains('treated as text'), contains('numeric enum'), contains('allOf merged')),
    );
  });

  test('a non-object root is wrapped', () {
    final r = c.convert({'type': 'string'}, rootName: 'echo');
    final root = r.ir['root']! as JsonMap;
    expect(root['kind'], 'object');
    expect(prop(root, 'value')['schema'], {'kind': 'string'});
    expect(r.warnings.single, contains('wrapped'));
  });
}
