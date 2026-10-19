import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa/services/mcp/input/elicitation_form.dart';

ElicitationForm parse(Map<String, Object?> props, {List<String> required = const []}) =>
    ElicitationForm.parse({'type': 'object', 'properties': props, 'required': required});

void main() {
  group('schema → fields', () {
    test('every primitive type of the spec, with defaults and required', () {
      final f = parse({
        'name': {'type': 'string', 'title': 'Your name', 'minLength': 2, 'maxLength': 5, 'default': 'Ada'},
        'email': {'type': 'string', 'format': 'email'},
        'site': {'type': 'string', 'format': 'uri'},
        'born': {'type': 'string', 'format': 'date'},
        'at': {'type': 'string', 'format': 'date-time'},
        'age': {'type': 'integer', 'minimum': 0, 'maximum': 150, 'default': 36},
        'score': {'type': 'number', 'minimum': 0.5},
        'agree': {'type': 'boolean', 'default': true},
        'color': {'type': 'string', 'enum': ['red', 'green'], 'default': 'green'},
        'size': {'type': 'string', 'enum': ['s', 'm'], 'enumNames': ['Small', 'Medium']},
        'plan': {
          'type': 'string',
          'oneOf': [
            {'const': 'free', 'title': 'Free'},
            {'const': 'pro', 'title': 'Pro'},
          ],
        },
        'tags': {
          'type': 'array',
          'minItems': 1,
          'maxItems': 2,
          'items': {'type': 'string', 'enum': ['a', 'b', 'c']},
          'default': ['a', 'zzz'],
        },
        'langs': {
          'type': 'array',
          'items': {
            'anyOf': [
              {'const': 'en', 'title': 'English'},
              {'const': 'pt', 'title': 'Portuguese'},
            ],
          },
        },
      }, required: ['name', 'agree', 'tags']);
      final byKey = {for (final x in f.fields) x.key: x};
      expect(f.fields, hasLength(13));
      expect(f.unsupported, isEmpty);
      expect(f.canAccept, isTrue);
      expect(byKey['name']!.kind, ElicitationFieldKind.text);
      expect(byKey['name']!.label, 'Your name');
      expect(byKey['name']!.required, isTrue);
      expect(byKey['email']!.format, ElicitationTextFormat.email);
      expect(byKey['site']!.format, ElicitationTextFormat.uri);
      expect(byKey['born']!.format, ElicitationTextFormat.date);
      expect(byKey['at']!.format, ElicitationTextFormat.dateTime);
      expect(byKey['age']!.kind, ElicitationFieldKind.integer);
      expect(byKey['score']!.kind, ElicitationFieldKind.number);
      expect(byKey['agree']!.kind, ElicitationFieldKind.boolean);
      expect(byKey['color']!.kind, ElicitationFieldKind.singleChoice);
      expect([for (final o in byKey['size']!.options) o.label], ['Small', 'Medium'], reason: 'legacy enumNames');
      expect([for (final o in byKey['plan']!.options) (o.value, o.label)], [('free', 'Free'), ('pro', 'Pro')]);
      expect(byKey['tags']!.kind, ElicitationFieldKind.multiChoice);
      expect([for (final o in byKey['langs']!.options) o.label], ['English', 'Portuguese']);

      final init = f.initialValues();
      expect(init['name'], 'Ada', reason: 'defaults are pre-filled');
      expect(init['age'], '36');
      expect(init['agree'], isTrue);
      expect(init['color'], 'green');
      expect(init['tags'], ['a'], reason: 'unknown default items dropped');
      expect(init['email'], isNull);
      expect(f.validate(init), isEmpty);
      expect(f.content(init), {'name': 'Ada', 'age': 36, 'agree': true, 'color': 'green', 'tags': ['a']});
    });

    test('nested objects and arrays of objects are not shown; a required one blocks sending', () {
      final optional = parse({
        'ok': {'type': 'string'},
        'nested': {'type': 'object', 'properties': <String, Object?>{}},
      });
      expect(optional.unsupported, ['nested']);
      expect(optional.canAccept, isTrue);
      final blocking = parse({
        'rows': {
          'type': 'array',
          'items': {'type': 'object'},
        },
      }, required: ['rows']);
      expect(blocking.unsupportedRequired, ['rows']);
      expect(blocking.canAccept, isFalse);
    });
  });

  group('validation', () {
    final f = parse({
      'name': {'type': 'string', 'minLength': 2, 'maxLength': 5},
      'email': {'type': 'string', 'format': 'email'},
      'site': {'type': 'string', 'format': 'uri'},
      'born': {'type': 'string', 'format': 'date'},
      'at': {'type': 'string', 'format': 'date-time'},
      'age': {'type': 'integer', 'minimum': 0, 'maximum': 150},
      'score': {'type': 'number', 'maximum': 1},
      'color': {'type': 'string', 'enum': ['red', 'green']},
      'tags': {
        'type': 'array',
        'minItems': 1,
        'maxItems': 2,
        'items': {'type': 'string', 'enum': ['a', 'b', 'c']},
      },
    }, required: ['name', 'color', 'tags']);

    test('required, lengths, formats, ranges and item counts', () {
      final errors = f.validate({
        'name': 'A',
        'email': 'not-an-email',
        'site': 'example.com',
        'born': '2026-13-45',
        'at': 'yesterday',
        'age': '1.5',
        'score': '2',
        'color': null,
        'tags': ['a', 'b', 'c'],
      });
      expect(errors.keys, containsAll(['name', 'email', 'site', 'born', 'at', 'age', 'score', 'color', 'tags']));
      expect(errors['name'], 'At least 2 characters.');
      expect(errors['age'], 'Enter a whole number.');
      expect(errors['score'], 'At most 1.');
      expect(errors['tags'], 'Choose at most 2.');
      expect(f.validate({'name': '', 'color': null, 'tags': <String>[]}), {
        'name': 'Required.',
        'color': 'Choose one.',
        'tags': 'Choose at least one.',
      });
    });

    test('valid answers become typed content; empty optional fields are left out', () {
      final values = {
        'name': ' Ada ',
        'email': 'ada@example.com',
        'site': 'https://example.com',
        'born': '1815-12-10',
        'at': '2026-10-19T12:00',
        'age': '36',
        'score': '0.5',
        'color': 'red',
        'tags': ['b'],
      };
      expect(f.validate(values), isEmpty);
      expect(f.content(values), {
        'name': 'Ada',
        'email': 'ada@example.com',
        'site': 'https://example.com',
        'born': '1815-12-10',
        'at': '2026-10-19T12:00',
        'age': 36,
        'score': 0.5,
        'color': 'red',
        'tags': ['b'],
      });
      expect(f.content({'name': 'Ada', 'color': 'red', 'tags': ['a'], 'email': '  '}).containsKey('email'), isFalse);
    });
  });

  group('secrets are refused (servers MUST NOT ask for them in form mode)', () {
    for (final (key, prop) in [
      ('password', <String, Object?>{'type': 'string'}),
      ('apiKey', <String, Object?>{'type': 'string'}),
      ('api_key', <String, Object?>{'type': 'string'}),
      ('accessToken', <String, Object?>{'type': 'string'}),
      ('field1', <String, Object?>{'type': 'string', 'title': 'Credit card number'}),
      ('cvv', <String, Object?>{'type': 'string'}),
      ('iban', <String, Object?>{'type': 'string'}),
      ('otp', <String, Object?>{'type': 'string'}),
      ('pin', <String, Object?>{'type': 'integer'}),
      ('x', <String, Object?>{'type': 'string', 'format': 'password'}),
      ('y', <String, Object?>{'type': 'string', 'writeOnly': true}),
      ('clientSecret', <String, Object?>{'type': 'string'}),
    ]) {
      test('$key ${prop['title'] ?? prop['format'] ?? ''}', () {
        final f = parse({
          'name': {'type': 'string'},
          key: prop,
        });
        expect(f.asksForSecret, isTrue, reason: key);
        expect(f.canAccept, isFalse);
      });
    }

    test('ordinary fields and reassuring descriptions are not secrets', () {
      final f = parse({
        'name': {'type': 'string', 'description': 'We will never ask for your password.'},
        'username': {'type': 'string'},
        'spinCount': {'type': 'integer'},
        'shipping': {'type': 'string'},
        'opinion': {'type': 'string'},
      });
      expect(f.asksForSecret, isFalse);
    });
  });
}
