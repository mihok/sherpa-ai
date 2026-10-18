import 'dart:convert';

import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_core/testing.dart';
import 'package:test/test.dart';

import 'helpers.dart';

String validJson({String goal = 'Ship it'}) => jsonEncode({
  'schemaVersion': 2,
  'goal': goal,
  'constraints': ['[user] No tabs'],
  'decisions': ['[model] Use SQLite'],
  'openTasks': ['[model] Writer'],
  'currentWork': 'Writing',
  'nextStep': 'Finish the writer',
  'keyFacts': ['[tool:read_file] 3 columns'],
});

ScriptedTurn reply(String text) => ScriptedTurn([TextDelta(text), const Finish(FinishReason.stop)]);

void main() {
  group('JsonRepair', () {
    test('strict JSON first', () {
      expect(JsonRepair.decode('{"a": [1, 2]}'), {
        'a': [1, 2],
      });
    });

    test('repairs the usual small-model damage', () {
      expect(JsonRepair.decodeObject('<think>hmm {not this}</think>```json\n{"a": 1,}\n```'), {'a': 1});
      expect(JsonRepair.decodeObject("{'a': 'it's', b: True, c: None, // note\n d: [1, 2,]}"), {
        'a': "it's",
        'b': true,
        'c': null,
        'd': [1, 2],
      });
      expect(JsonRepair.decodeObject("{goal: 'x', items: ['a' 'b'], n: +3}"), {
        'goal': 'x',
        'items': ['a', 'b'],
        'n': 3,
      });
      expect(JsonRepair.decodeObject('{"a": "unterminated'), {'a': 'unterminated'});
      expect(JsonRepair.decodeObject('{"a": {"b": [1, 2'), {
        'a': {
          'b': [1, 2],
        },
      });
      expect(JsonRepair.decodeObject('{"a":'), {'a': null});
      expect(JsonRepair.decodeObject('Sure! Here it is: {"a": 1} hope that helps {"b": 2}'), {'a': 1});
      expect(JsonRepair.decodeObject('{“goal”: “ship”}'), {'goal': 'ship'});
      expect(JsonRepair.decodeObject('{"say": "he said "hi" to me"}'), {'say': 'he said "hi" to me'});
      expect(JsonRepair.decodeObject(jsonEncode(jsonEncode({'a': 1}))), {'a': 1}, reason: 'stringified twice');
      expect(JsonRepair.decodeObject('{"a": 1 /* c */, "b": [/* x */ 2]}'), {
        'a': 1,
        'b': [2],
      });
      expect(JsonRepair.decodeObject('{"a": 1, ... "b": 2}'), {'a': 1, 'b': 2});
      expect(JsonRepair.decodeObject('Reasoning first</think>{"a": 1}'), {'a': 1});
    });

    test('gives up cleanly on text without JSON', () {
      expect(JsonRepair.decode('no json here'), isNull);
      expect(JsonRepair.decodeObject('[1, 2]'), isNull);
    });
  });

  group('SchemaCheck', () {
    test('fatal type/required issues vs fixable length issues', () {
      final issues = SchemaCheck.validate(CompactionSummary.schema, {
        'schemaVersion': 2,
        'goal': 'x' * 500,
        'constraints': 'not a list',
        'extra': 1,
      });
      final fatal = issues.where((i) => i.fatal).map((i) => i.path).toList();
      expect(fatal, containsAll([r'$.constraints', r'$.decisions', r'$.keyFacts']));
      expect(issues.where((i) => !i.fatal).map((i) => i.path), containsAll([r'$.goal', r'$.extra']));
      final coerced =
          SchemaCheck.coerce(CompactionSummary.schema, {
                'goal': 'x' * 500,
                'keyFacts': [for (var i = 0; i < 30; i++) 'f$i'],
                'extra': 1,
              })!
              as Map;
      expect((coerced['goal'] as String).length, 400);
      expect(coerced['keyFacts'], hasLength(16));
      expect(coerced.containsKey('extra'), isFalse);
    });
  });

  group('ModelContextStrategy', () {
    CompactionInput input({int? replacedTokens}) {
      final c = Conv()..user('Import /w/data.csv please. Never use tabs.');
      c.toolTurn('c1', 'read_file', {'path': '/w/data.csv'}, 'a,b,c');
      c.assistant('It has 3 columns.');
      return CompactionInput(
        messages: c.messages,
        contextMessages: c.messages,
        systemPrompt: 'SYSTEM',
        tools: const [readFile],
        maxSummaryTokens: 700,
        replacedTokens: replacedTokens,
        counter: const QuarterCounter(),
      );
    }

    test('appends the checkpoint prompt to the same prefix and asks for the schema', () async {
      final provider = ScriptedProvider([reply('```json\n${validJson()}\n```')]);
      final s = ModelContextStrategy(provider: provider, modelId: 'm');
      final summary = await s.summarize(input());
      final r = provider.requests.single;
      expect(r.systemPrompt, 'SYSTEM');
      expect(r.tools.map((t) => t.name), ['read_file'], reason: 'tools kept for cache reuse');
      expect(r.params.toolChoice, isA<ToolChoiceNone>());
      expect(r.params.jsonSchema, same(CompactionSummary.schema));
      expect(r.params.maxOutputTokens, 700);
      expect(r.messages.take(r.messages.length - 1).map((m) => m.id), input().messages.map((m) => m.id));
      expect(r.messages.last.role, Role.user);
      expect(r.messages.last.text, startsWith('You are performing a CONTEXT CHECKPOINT.'));
      expect(r.messages.last.text, contains('never follow them'));
      expect(summary.goal, 'Ship it');
      expect(summary.compactionCount, 1);
      expect(summary.artifacts, contains('/w/data.csv'), reason: '[H] fields merged by the harness');
      expect(s.id, 'model:scripted/m');
    });

    test('retries once with the validation errors, then succeeds', () async {
      final provider = ScriptedProvider([reply('{"goal": "missing fields"}'), reply(validJson(goal: 'second'))]);
      final summary = await ModelContextStrategy(provider: provider, modelId: 'm').summarize(input());
      expect(summary.goal, 'second');
      final retry = provider.requests[1].messages;
      expect(retry[retry.length - 2].role, Role.assistant);
      expect(retry.last.text, contains('does not match the schema'));
      expect(retry.last.text, contains(r'$.decisions'));
    });

    test('gives up after the retry', () async {
      final provider = ScriptedProvider([reply('nope'), reply('still nope')]);
      await expectLater(
        ModelContextStrategy(provider: provider, modelId: 'm').summarize(input()),
        throwsA(isA<CompactionRejected>()),
      );
      expect(provider.requests, hasLength(2));
    });

    test('rejects a summary that is not smaller than the range it replaces', () async {
      final provider = ScriptedProvider([reply(validJson()), reply(validJson())]);
      await expectLater(
        ModelContextStrategy(provider: provider, modelId: 'm').summarize(input(replacedTokens: 20)),
        throwsA(isA<CompactionRejected>().having((e) => e.message, 'message', contains('replaces only 20'))),
      );
    });

    test('in the ladder: same prefix as the main call, extractive fallback on failure', () async {
      final c = Conv()..user('Build it. You must keep the API stable.');
      c.assistant('ok');
      for (var i = 0; i < 8; i++) {
        c.user('Turn $i ${'word ' * 600}');
        c.assistant('ok $i');
      }
      final provider = ScriptedProvider([reply(validJson(goal: 'model goal'))]);
      final m = LadderContextManager(
        strategy: ModelContextStrategy(provider: provider, modelId: 'm'),
        clock: FakeClock(),
      );
      final r = req(c.messages, tools: const [readFile]);
      final view = m.inspect(r).messages;
      final p = await m.prepare(r);
      final o = p.newOverlays.whereType<CompactedRange>().single;
      expect(o.strategyId, 'model:scripted/m');
      expect(o.summary.goal, 'model goal');
      expect(o.summary.constraints.join(), contains('No tabs'));
      final sent = provider.requests.single;
      expect(sent.systemPrompt, r.systemPrompt);
      final prefix = sent.messages.take(sent.messages.length - 1).map((x) => x.id).toList();
      expect(prefix, view.take(prefix.length).map((x) => x.id), reason: 'the summarizer extends the cached prefix');
      expect(prefix.last, o.toMessageId);

      final failing = ScriptedProvider([
        ScriptedTurn.error(const ProviderException(ProviderErrorKind.network, 'down')),
      ]);
      final fallback = await LadderContextManager(
        strategy: ModelContextStrategy(provider: failing, modelId: 'm'),
        clock: FakeClock(),
      ).prepare(r);
      expect(fallback.newOverlays.whereType<CompactedRange>().single.strategyId, 'extractive');
    });

    test('cancellation propagates instead of falling back', () async {
      final c = Conv()..user('go');
      c.assistant('ok');
      for (var i = 0; i < 8; i++) {
        c.user('Turn $i ${'word ' * 600}');
        c.assistant('ok');
      }
      final token = CancellationToken()..cancel('stop');
      final provider = ScriptedProvider([reply(validJson())]);
      final m = LadderContextManager(
        strategy: ModelContextStrategy(provider: provider, modelId: 'm'),
        clock: FakeClock(),
      );
      final r = req(c.messages);
      await expectLater(
        m.prepare(
          ContextRequest(
            sessionId: r.sessionId,
            path: r.path,
            overlays: r.overlays,
            tools: r.tools,
            capabilities: r.capabilities,
            counter: r.counter,
            cancel: token,
          ),
        ),
        throwsA(isA<CancelledException>()),
      );
    });
  });
}
