import 'package:sherpa_evals/src/data.dart';
import 'package:sherpa_evals/src/runtime/models.dart';
import 'package:sherpa_evals/src/suites/l2_ast.dart';
import 'package:sherpa_evals/src/suites/l2_bfcl.dart';
import 'package:sherpa_evals/src/suites/suite.dart';
import 'package:test/test.dart';

const _fn = {
  'name': 'calculate_triangle_area',
  'bfclName': 'calculate_triangle_area',
  'parameters': {
    'type': 'object',
    'properties': {
      'base': {'type': 'integer'},
      'height': {'type': 'integer'},
      'unit': {'type': 'string'},
      'scale': {'type': 'number'},
      'tags': {'type': 'array', 'items': {'type': 'string'}},
    },
    'required': ['base', 'height'],
  },
};

const _answer = {
  'calculate_triangle_area': {
    'base': [10],
    'height': [5],
    'unit': ['units', ''],
    'scale': [1.0, ''],
    'tags': [
      ['Big', 'red'],
      '',
    ],
  },
};

AstVerdict _check(Map<String, Object?> args, {String name = 'calculate_triangle_area'}) =>
    checkSimple(_fn, (name: name, arguments: args), _answer);

void main() {
  group('AST checker (BFCL semantics)', () {
    test('exact and minimal answers pass', () {
      expect(_check({'base': 10, 'height': 5}).valid, isTrue);
      expect(_check({'base': 10, 'height': 5, 'unit': 'Units', 'scale': 1, 'tags': ['big', 'Red']}).valid, isTrue,
          reason: 'strings are standardized; int is accepted for a float');
    });

    test('wrong name, missing required, unexpected parameter, wrong value, wrong type', () {
      expect(_check({'base': 10, 'height': 5}, name: 'triangle_area').error, contains('wrong function'));
      expect(_check({'base': 10}).error, contains('missing required'));
      expect(_check({'base': 10, 'height': 5, 'color': 'red'}).error, contains('unexpected parameter'));
      expect(_check({'base': 11, 'height': 5}).error, contains('not in'));
      expect(_check({'base': '10', 'height': 5}).error, contains('wrong type'));
      expect(_check({'base': 10, 'height': 5, 'tags': ['red', 'big']}).valid, isFalse, reason: 'list order matters');
    });

    test('an optional parameter may be omitted only when "" is a possible answer', () {
      const strict = {
        'calculate_triangle_area': {
          'base': [10],
          'height': [5],
          'unit': ['cm'],
        },
      };
      expect(checkSimple(_fn, (name: 'calculate_triangle_area', arguments: {'base': 10, 'height': 5}), strict).error,
          contains('optional parameter unit'));
    });

    test('parallel calls match in any order, each answer once', () {
      final fns = [_fn];
      const a1 = {
        'calculate_triangle_area': {'base': [1], 'height': [2]},
      };
      const a2 = {
        'calculate_triangle_area': {'base': [3], 'height': [4]},
      };
      AstCall c(int b, int h) => (name: 'calculate_triangle_area', arguments: {'base': b, 'height': h});
      expect(checkParallel(fns, [c(3, 4), c(1, 2)], [a1, a2]).valid, isTrue);
      expect(checkParallel(fns, [c(1, 2), c(1, 2)], [a1, a2]).valid, isFalse);
      expect(checkParallel(fns, [c(1, 2)], [a1, a2]).error, contains('1 calls, wanted 2'));
    });

    test('dotted BFCL names are offered with underscores', () {
      expect(offeredName('math.factorial'), 'math_factorial');
      final v = checkSimple(
        {'name': 'math_factorial', 'bfclName': 'math.factorial', 'parameters': {'type': 'object', 'properties': {'number': {'type': 'integer'}}, 'required': ['number']}},
        (name: 'math_factorial', arguments: {'number': 5}),
        {'math.factorial': {'number': [5]}},
      );
      expect(v.valid, isTrue);
    });

    test('irrelevance passes only without calls', () {
      expect(checkIrrelevance(const []).valid, isTrue);
      expect(checkIrrelevance([(name: 'x', arguments: const {})]).valid, isFalse);
    });

    test('the oracle answer of every subset case passes the checker', () {
      for (final c in objectList(loadData('l2/bfcl_subset.json')['cases'])) {
        if (c['category'] == 'irrelevance') continue;
        final answers = objectList(c['ground_truth']);
        final v = checkCase(c['category']! as String, objectList(c['functions']), [for (final a in answers) oracleCall(a)], answers);
        expect(v.valid, isTrue, reason: '${c['id']}: $v');
      }
    });
  });

  test('scripted L2 run scores 100% and gates', () async {
    final r = await const L2BfclSuite().run(EvalContext(model: const ScriptedModelSpec()));
    expect(r.cases, hasLength(50));
    expect(r.metric('ast_accuracy')!.value, 1);
    expect(r.metric('irrelevance_accuracy')!.value, 1);
    expect(r.metric('schema_valid_rate')!.value, 1);
    expect({for (final c in r.cases) c.group}, {'simple', 'multiple', 'parallel', 'irrelevance'});
  });
}
