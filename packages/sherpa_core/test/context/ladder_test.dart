import 'dart:convert';

import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_core/testing.dart';
import 'package:test/test.dart';

import 'helpers.dart';

LadderContextManager ladder({
  ContextStrategy strategy = const ExtractiveContextStrategy(),
  ContextStrategy fallback = const ExtractiveContextStrategy(),
}) => LadderContextManager(strategy: strategy, fallbackStrategy: fallback, clock: FakeClock());

/// Persists [prepared] overlays onto [overlays] (what the runner does).
List<ContextOverlay> persisted(List<ContextOverlay> overlays, PreparedContext prepared) => [
  ...overlays,
  ...prepared.newOverlays,
];

void main() {
  group('stage 1: elide stale tool results', () {
    Conv conversation() {
      final c = Conv()..user('read the files');
      c.toolTurn('c1', 'read_file', {'path': '/w/a.txt'}, lines(400));
      c.assistant('a is long');
      c.user('next one');
      c.toolTurn('c2', 'read_file', {'path': '/w/b.txt'}, lines(400));
      c.assistant('b is long too');
      c.user('and the small ones');
      for (final id in ['c3', 'c4', 'c5']) {
        c.toolTurn(id, 'read_file', {'path': '/w/$id.txt'}, 'tiny $id');
      }
      c.assistant('done');
      c.user('what now?');
      return c;
    }

    test('elides the oldest large result first and stops once below the target', () async {
      final c = conversation();
      final r = req(c.messages, tools: const [readFile]);
      final before = ladder().inspect(r).budget.ratio;
      expect(before, greaterThan(0.55), reason: 'test setup: above the 8K prune threshold');
      final p = await ladder().prepare(r);
      final elided = p.newOverlays.whereType<ToolOutputElided>().toList();
      expect(elided.map((o) => o.callId), ['c1'], reason: 'c1 alone brings the ratio below prune − 0.10');
      expect(elided.single.id, 'ctx-elide:m3:c1');
      expect(p.budget.ratio, lessThanOrEqualTo(0.45));
      final toolMsg = p.messages.firstWhere((m) => m.id == 'm3');
      final stub = toolMsg.toolResults.single.text;
      expect(stub, startsWith('[tool result elided: read_file, 2,'));
      expect(stub, contains('tokens, call c1; call the tool again if needed]'));
      expect(stub, contains('line 0 of the payload text'));
      expect(stub, contains('line 399 of the payload text'));
      expect(stub, contains('lines omitted'));
      expect(stub, isNot(contains('line 200 of')));
      // The call and the result shell stay, so pairing holds.
      expect(p.messages.firstWhere((m) => m.id == 'm2').toolCalls.single.id, 'c1');
      expect(toolMsg.toolResults.single.callId, 'c1');
      expectProviderInvariants(p.messages);
      expect(elided.single.reason, contains('stale read_file result'));
      expect(p.level, ContextLevel.healthy);
      expect(p.recommendation, isNull);
    });

    test('below the prune threshold nothing is touched', () async {
      final c = conversation();
      final p = await ladder().prepare(req(c.messages, window: 65536));
      expect(p.newOverlays, isEmpty);
      expect(p.messages, same(c.messages), reason: 'unchanged path is passed through as is');
    });
  });

  group('never-elide rules', () {
    Conv conversation() {
      final c = Conv()..user('start');
      c.toolTurn('c1', 'read_file', {'path': '/w/big.txt'}, lines(400)); // large → elide
      c.toolTurn('c2', 'read_file', {'path': '/w/stale.txt'}, lines(40)); // small but stale → elide
      c.toolTurn('c3', 'shell', {'cmd': 'x'}, 'error:\n${lines(30)}', isError: true); // small error → keep
      c.toolTurn('c4', 'shell', {'cmd': 'y'}, 'error:\n${lines(120)}', isError: true); // large error → elide
      c.toolTurn('c5', 'update_plan', {'items': []}, 'Plan updated\n${lines(100)}'); // latest plan → keep
      c.toolTurn('c6', 'read_file', {'path': '/w/ref.txt'}, lines(400)); // referenced → keep
      c.toolTurn('c7', 'search', {'q': 'docs'}, lines(400)); // excluded tool → keep
      c.toolTurn('c11', 'read_file', {'path': '/w/pinned.txt'}, lines(400), pinned: true); // pinned → keep
      c.assistant('ok');
      c.user('ok');
      c.assistant('fine');
      c.user('more');
      c.toolTurn('c8', 'read_file', {'path': '/w/8'}, 'small');
      c.toolTurn('c9', 'read_file', {'path': '/w/9'}, lines(400)); // last 3 calls → keep
      c.toolTurn('c10', 'read_file', {'path': '/w/10'}, 'small');
      c.assistant('done');
      c.user('Please look at /w/ref.txt again.');
      return c;
    }

    test('only eligible results are elided, even when every stage runs', () async {
      final c = conversation();
      final p = await ladder().prepare(
        req(
          c.messages,
          window: 32768,
          settings: ContextSettings(profile: pruneEverything, excludedTools: const {'search'}),
        ),
      );
      final elided = p.newOverlays.whereType<ToolOutputElided>().map((o) => o.callId).toSet();
      expect(elided, {'c1', 'c2', 'c4'});
      expectProviderInvariants(p.messages);
      final pinned = c.messages.firstWhere((m) => m.pinned);
      expect(jsonEncode(p.messages.firstWhere((m) => m.id == pinned.id).toJson()), jsonEncode(pinned.toJson()));
    });

    test('keepRecentToolCalls and smallErrorResultTokens are settings', () async {
      final c = conversation();
      final p = await ladder().prepare(
        req(
          c.messages,
          window: 32768,
          settings: ContextSettings(
            profile: pruneEverything,
            keepRecentToolCalls: 1,
            smallErrorResultTokens: 0,
            excludedTools: const {'search'},
          ),
        ),
      );
      final elided = p.newOverlays.whereType<ToolOutputElided>().map((o) => o.callId).toSet();
      expect(elided, containsAll(['c3', 'c9']));
      expect(elided, isNot(contains('c10')));
    });
  });

  group('stage 2: clear large tool inputs', () {
    test('keeps keys and argsDigest, elides big values, keeps pairing', () async {
      final c = Conv()..user('write it');
      final body = 'x' * 9000;
      c.toolTurn('w1', 'write_file', {'path': '/w/out.txt', 'content': body}, 'written');
      c.assistant('written');
      c.user('again');
      for (final id in ['r1', 'r2', 'r3']) {
        c.toolTurn(id, 'read_file', {'path': '/w/$id'}, 'ok');
      }
      c.user('thanks');
      final p = await ladder().prepare(req(c.messages, settings: ContextSettings(profile: pruneEverything)));
      final t = p.newOverlays.whereType<PayloadTruncated>().single;
      expect(t.messageId, 'm2');
      expect(t.partIndex, 0);
      final call = p.messages.firstWhere((m) => m.id == 'm2').toolCalls.single;
      expect(call.id, 'w1');
      expect(call.name, 'write_file');
      expect(call.arguments['path'], '/w/out.txt');
      expect(call.arguments['content'], contains('9,000 chars elided'));
      expect(call.arguments['_sherpa'], contains('argsDigest ${Digest.args({'path': '/w/out.txt', 'content': body})}'));
      expect(t.tokensSaved, greaterThan(2000));
      expectProviderInvariants(p.messages);
    });
  });

  group('stage 3: compaction', () {
    Conv chat(int turns, {int words = 600}) {
      final c = Conv()..user('Build the importer. You must never use tabs. I prefer short answers.');
      c.assistant('Starting.');
      for (var i = 1; i < turns; i++) {
        c.user('Turn $i: ${'word ' * words}');
        c.assistant('Reply $i.');
      }
      c.user('Latest request: finish the importer.');
      return c;
    }

    test('summarizes before the oldest of the last K user turns, rendered first', () async {
      final c = chat(8);
      final r = req(c.messages);
      expect(ladder().inspect(r).budget.ratio, greaterThan(0.70));
      final p = await ladder().prepare(r);
      final o = p.newOverlays.whereType<CompactedRange>().single;
      expect(o.fromMessageId, 'm1');
      // K = 2 on 8K: the tail starts at the second-to-last user turn.
      final tailStart = c.messages[c.messages.length - 3];
      expect(tailStart.role, Role.user);
      expect(o.toMessageId, c.messages[c.messages.length - 4].id);
      expect(o.strategyId, 'extractive');
      expect(o.summary.compactionCount, 1);
      expect(o.summary.constraints.join(), contains('You must never use tabs.'));
      expect(o.summary.userPreferences.join(), contains('I prefer short answers.'));
      expect(o.tokensSaved, greaterThan(0));
      expect(p.messages.first.kind, MessageKind.summary);
      expect(p.messages.first.text, startsWith(CompactionSummary.header));
      expect(p.messages[1].role, Role.assistant, reason: 'ack keeps roles alternating');
      expect(p.messages[2].id, tailStart.id);
      expect(p.budget.ratio, lessThan(0.70));
      expect(o.reason, contains('kept the last 2 user turns'));
      expectProviderInvariants(p.messages);
    });

    test('kept tail is capped at the kept-tail fraction of W by shrinking K', () async {
      final c = Conv()..user('start');
      c.assistant('ok');
      for (var i = 0; i < 8; i++) {
        c.user('Turn $i ${'word ' * 2720}');
        c.assistant('ok $i');
      }
      final p = await ladder().prepare(req(c.messages, window: 32768));
      final o = p.newOverlays.whereType<CompactedRange>().single;
      // K is 3 on 32K, but three 3.4K-token turns exceed 30% of W.
      expect(o.toMessageId, c.messages[c.messages.length - 5].id);
      expect(o.reason, contains('kept the last 2 user turns'));
    });

    test('pinned messages inside the range survive verbatim', () async {
      final c = Conv()..user('Pinned instructions: answer in French.', pinned: true);
      c.assistant('ok');
      for (var i = 0; i < 7; i++) {
        c.user('Turn $i ${'word ' * 700}');
        c.assistant('ok $i');
      }
      c.user('latest');
      final p = await ladder().prepare(req(c.messages));
      expect(p.newOverlays.whereType<CompactedRange>(), hasLength(1));
      expect(p.messages.where((m) => m.id == 'm1').single.text, 'Pinned instructions: answer in French.');
      expect(p.messages.first.kind, MessageKind.summary);
    });

    test('the ≤ 4K tier uses the deterministic summary and recommends a handoff', () async {
      final provider = ScriptedProvider(const []);
      final c = Conv()..user('Goal: tidy notes.');
      c.assistant('ok');
      for (var i = 0; i < 4; i++) {
        c.user('note $i ${'word ' * 600}');
        c.assistant('ok');
      }
      c.user('done?');
      final m = ladder(
        strategy: ModelContextStrategy(provider: provider, modelId: 'tiny'),
      );
      final p = await m.prepare(req(c.messages, window: 4096, maxOutput: 256));
      final o = p.newOverlays.whereType<CompactedRange>().single;
      expect(o.strategyId, 'extractive');
      expect(provider.requests, isEmpty, reason: 'no LLM compaction on ≤ 4K windows');
      expect(p.recommendation?.kind, ContextRecommendationKind.handoff);
      expect(p.recommendation!.message, contains('too small'));
    });

    test('an oversized summary is rejected and nothing is compacted', () async {
      final c = chat(8);
      final primary = _BloatedStrategy();
      final fallback = _BloatedStrategy();
      final p = await ladder(strategy: primary, fallback: fallback).prepare(req(c.messages));
      expect(p.newOverlays.whereType<CompactedRange>(), isEmpty);
      expect([primary.calls, fallback.calls], [1, 1], reason: 'primary and fallback both tried');
      expect(p.level, ContextLevel.compacting);
      final same = _BloatedStrategy();
      await ladder(strategy: same, fallback: same).prepare(req(c.messages));
      expect(same.calls, 1, reason: 'the same strategy is not retried as its own fallback');
    });

    test('an oversized model summary falls back to the extractive one', () async {
      final c = chat(8);
      final p = await ladder(strategy: _BloatedStrategy()).prepare(req(c.messages));
      expect(p.newOverlays.whereType<CompactedRange>().single.strategyId, 'extractive');
    });

    test('autoCompact=false skips compaction', () async {
      final p = await ladder().prepare(req(chat(8).messages, settings: const ContextSettings(autoCompact: false)));
      expect(p.newOverlays, isEmpty);
      expect(p.level, ContextLevel.compacting);
    });
  });

  group('stages 4–6: rescue, handoff, hard stop', () {
    test('a fresh oversized result is truncated (head/tail) only when nothing else fits', () async {
      final c = Conv()..user('read the log');
      c.toolTurn('c1', 'read_file', {'path': '/var/log/big.log'}, lines(1500));
      final r = req(c.messages);
      expect(ladder().inspect(r).budget.fits, isFalse);
      final p = await ladder().prepare(r);
      final t = p.newOverlays.whereType<PayloadTruncated>().single;
      expect(t.reason, contains('would not fit'));
      final text = p.messages.last.toolResults.single.text;
      expect(text, startsWith('[tool result truncated: read_file,'));
      expect(text, contains('line 0 of'));
      expect(text, contains('line 1499 of'));
      expect(p.budget.fits, isTrue);
      expect(p.recommendation?.kind, isNot(ContextRecommendationKind.hardStop));
      expectProviderInvariants(p.messages);
    });

    test('JSON results keep their shape when truncated', () async {
      final c = Conv()..user('list');
      final items = [
        for (var i = 0; i < 400; i++) {'id': 'item-$i', 'body': 'b' * 200},
      ];
      c.toolTurn('c1', 'list_items', const {}, jsonEncode({'items': items, 'next_cursor': 'abc'}));
      final p = await ladder().prepare(req(c.messages));
      final text = p.messages.last.toolResults.single.text;
      final json = jsonDecode(text.substring(text.indexOf('\n') + 1)) as Map<String, Object?>;
      expect(json.keys, containsAll(['items', 'next_cursor']));
      expect(json['next_cursor'], 'abc');
      expect((json['items']! as List).last, contains('more items elided'));
    });

    test('a user message larger than the window is a hard stop', () async {
      final c = Conv()..user('hi');
      c.assistant('hello');
      c.user('word ' * 9000);
      final p = await ladder().prepare(req(c.messages));
      expect(p.recommendation?.kind, ContextRecommendationKind.hardStop);
      expect(p.recommendation!.message, contains('no longer fits'));
      expect(p.level, ContextLevel.overflow);
    });

    test('handoff is recommended after a poor compaction', () async {
      final c = Conv()..user('start');
      c.assistant('ok');
      for (var i = 0; i < 8; i++) {
        c.user('Turn $i ${'word ' * 600}');
        c.assistant('ok');
      }
      Future<ContextRecommendation?> run(ContextSettings s) async =>
          (await ladder().prepare(req(c.messages, settings: s))).recommendation;
      expect(await run(const ContextSettings()), isNull);
      expect((await run(const ContextSettings(handoffAfterCompactions: 1)))!.message, contains('summarized 1 times'));
      expect((await run(const ContextSettings(minCompactionGain: 0.99)))!.message, contains('freed only'));
      expect((await run(const ContextSettings(maxPostCompactionRatio: 0.01)))!.message, contains('still'));
    });

    test('handoff is recommended at the handoff threshold', () async {
      final c = Conv()..user('word ' * 5600);
      final p = await ladder().prepare(req(c.messages));
      expect(p.budget.ratio, greaterThan(0.90));
      expect(p.recommendation?.kind, ContextRecommendationKind.handoff);
      expect(p.level, ContextLevel.handoff);
    });
  });

  group('append-only segments', () {
    Conv loop({required bool endsWithUser}) {
      final c = Conv()..user('start');
      c.toolTurn('c1', 'read_file', {'path': '/a'}, lines(400));
      c.assistant('read a');
      c.user('go on');
      c.toolTurn('c2', 'read_file', {'path': '/b'}, lines(400));
      c.toolTurn('c3', 'read_file', {'path': '/c'}, 'small');
      c.toolTurn('c4', 'read_file', {'path': '/d'}, 'small');
      c.toolTurn('c5', 'read_file', {'path': '/e'}, lines(200));
      if (endsWithUser) {
        c.assistant('done');
        c.user('next');
      }
      return c;
    }

    test('never rewrites in the middle of a tool loop', () async {
      final c = loop(endsWithUser: false);
      final r = req(c.messages, policy: HistoryPolicy.appendOnly);
      expect(ladder().inspect(r).budget.ratio, greaterThan(0.55));
      final p = await ladder().prepare(r);
      expect(p.newOverlays, isEmpty);
      final mutable = await ladder().prepare(req(c.messages));
      expect(mutable.newOverlays, isNotEmpty, reason: 'mutable models may be rewritten mid-loop');
    });

    test('overflow mid tool loop is a hard stop that explains the segment rule', () async {
      final c = loop(endsWithUser: false);
      c.toolTurn('c6', 'read_file', {'path': '/f'}, lines(1500));
      final p = await ladder().prepare(req(c.messages, policy: HistoryPolicy.appendOnly));
      expect(p.newOverlays, isEmpty);
      expect(p.recommendation?.kind, ContextRecommendationKind.hardStop);
      expect(p.recommendation!.message, contains('middle of a tool loop'));
    });

    test('rewrites at a user turn and drops reasoning from the old prefix', () async {
      final c = Conv()..user('start');
      const system = 'You are a test assistant.';
      final oldKey = PassthroughContextManager.prefixKeyOf(system, const [], const []);
      c.assistant(
        '',
        calls: [
          const ToolCall(id: 'c1', name: 'read_file', arguments: {'path': '/a'}),
        ],
        reasoning: 'think 1',
        prefixKey: oldKey,
      );
      c.results([
        ToolResultPart(callId: 'c1', toolName: 'read_file', content: [TextPart(lines(400))]),
      ]);
      for (final id in ['c2', 'c3', 'c4']) {
        c.toolTurn(id, 'read_file', {'path': '/$id'}, 'small');
      }
      c.assistant('done', reasoning: 'think 2', prefixKey: oldKey);
      c.user('next');
      c.user('and more');
      // Small window: the old result must go.
      final r = req(c.messages, window: 4096, policy: HistoryPolicy.appendOnly);
      final p = await ladder().prepare(r);
      expect(p.newOverlays, isNotEmpty);
      expect(p.prefixKey, isNot(oldKey));
      expect(p.messages.expand((m) => m.reasoning), isEmpty);
      // Without a rewrite the same-prefix reasoning is replayed.
      final roomy = await ladder().prepare(req(c.messages, window: 65536, policy: HistoryPolicy.appendOnly));
      expect(roomy.newOverlays, isEmpty);
      expect(roomy.prefixKey, oldKey);
      expect(roomy.messages.expand((m) => m.reasoning).map((r) => r.signature), hasLength(2));
    });
  });

  group('idempotency', () {
    test('recomputing with the persisted overlays creates nothing new', () async {
      final c = Conv()..user('go');
      for (var i = 0; i < 6; i++) {
        c.toolTurn('c$i', 'read_file', {'path': '/f$i'}, lines(150));
        c.assistant('read $i');
        c.user('Turn $i ${'word ' * 300}');
      }
      final m = ladder();
      final first = await m.prepare(req(c.messages));
      expect(first.newOverlays, isNotEmpty);
      final overlays = persisted(const [], first);
      final second = await m.prepare(req(c.messages, overlays: overlays));
      expect(second.newOverlays, isEmpty);
      expect(second.prefixKey, first.prefixKey);
      expect(
        jsonEncode([for (final x in second.messages) x.toJson()]),
        jsonEncode([for (final x in first.messages) x.toJson()]),
      );
      // Overlay ids are deterministic: a re-run without persistence
      // produces the same ids, so a racing double-write cannot duplicate.
      final again = await m.prepare(req(c.messages));
      expect([for (final o in again.newOverlays) o.id], [for (final o in first.newOverlays) o.id]);
    });

    test('rolling compaction: the second summary integrates the first', () async {
      final c = Conv()..user('Task: migrate the DB. Never drop the users table.');
      c.assistant('ok');
      for (var i = 0; i < 8; i++) {
        c.user('Turn $i ${'word ' * 600}');
        c.assistant('ok $i');
      }
      final m = ladder();
      final first = await m.prepare(req(c.messages));
      final o1 = first.newOverlays.whereType<CompactedRange>().single;
      for (var i = 8; i < 13; i++) {
        c.user('Turn $i ${'word ' * 600}');
        c.assistant('ok $i');
      }
      final second = await m.prepare(req(c.messages, overlays: persisted(const [], first)));
      final o2 = second.newOverlays.whereType<CompactedRange>().single;
      expect(o2.fromMessageId, o1.fromMessageId);
      expect(o2.summary.compactionCount, 2);
      expect(o2.summary.constraints.join(), contains('Never drop the users table.'));
      expect(second.messages.where((x) => x.kind == MessageKind.summary && x.role == Role.user), hasLength(1));
      expect(second.messages.first.metadata['overlayId'], o2.id, reason: 'widest range wins');
    });
  });
}

/// Returns a summary far larger than any range it replaces.
final class _BloatedStrategy implements ContextStrategy {
  int calls = 0;

  @override
  String get id => 'bloated';

  @override
  Future<CompactionSummary> summarize(CompactionInput input, {CancellationToken? cancel}) async {
    calls++;
    return CompactionSummary(goal: 'g', keyFacts: [for (var i = 0; i < 16; i++) '[model] ${'fact $i ' * 200}']);
  }
}
