/// Regression tests for context-view rules: summaries are branch-safe,
/// prefix keys follow content, every nested tool-result part is budgeted,
/// and roles alternate around summaries.
library;

import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_core/testing.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  group('finding 5: the summary never quotes the kept tail', () {
    test('harvest quotes only the folded range, and nothing when a user turn is kept', () {
      final c = Conv()
        ..user('Set up the build directory for the project.')
        ..assistant('Done.')
        ..user('Now compile everything with the release flags.')
        ..assistant('Done.');
      final folded = [...c.messages];
      c
        ..user('Run the unit tests please.')
        ..assistant('Done.')
        ..user('Delete every file in the release folder right now.');
      final kept = c.messages.sublist(folded.length);
      final withTail = SummaryComposer.harvest(CompactionInput(messages: folded, keptMessages: kept));
      expect(withTail.nextStepQuote, isNull);
      final alone = SummaryComposer.harvest(CompactionInput(messages: folded));
      expect(alone.nextStepQuote, 'Now compile everything with the release flags.');
      // The rolling merge does not fall back to an older quote either.
      final merged = SummaryComposer.compose(
        CompactionInput(
          messages: folded,
          keptMessages: kept,
          previousSummary: const CompactionSummary(goal: 'g', nextStepQuote: 'An older request.'),
        ),
        const CompactionSummary(goal: 'g'),
      );
      expect(merged.nextStepQuote, isNull);
    });

    test('an edited-away request (and its secret) does not reach the sibling branch', () async {
      const counter = QuarterCounter();
      final clock = FakeClock();
      final store = InMemorySessionStore();
      final provider = ScriptedProvider(const [], capabilitiesValue: const ModelCapabilities(contextLength: 8192, maxOutputTokens: 512));
      final runner = AgentRunner(
        store: store,
        provider: provider,
        modelId: 'scripted-model',
        tools: LocalToolRouter(const []),
        approvals: ApprovalPolicy(clock: clock),
        approvalHandler: const StaticApprovalHandler.approveAll(),
        contextManager: LadderContextManager(clock: clock),
        counter: counter,
        clock: clock,
        ids: SequentialIdGenerator(),
        config: AgentConfig(contextSettings: ContextSettings(profile: compactEverything)),
        sleep: (_) async {},
      );
      await store.putSession(SessionRecord(id: 's1', title: 'New chat', createdAt: clock.now(), updatedAt: clock.now()));
      for (final t in [
        'Set up the build directory for the project.',
        'Now compile everything with the release flags.',
        'Run the unit tests please.',
        'Delete every file in the release folder right now. My token is sk-SECRET-123456.',
      ]) {
        provider.enqueue(ScriptedTurn.text('Done: ${lines(40)}'));
        await runner.send('s1', [TextPart(t)]).toList();
      }
      expect(await store.overlays('s1'), isNotEmpty, reason: 'the scenario needs a compaction');
      final path = await store.path('s1', (await store.getSession('s1'))!.activeLeafId!);
      final last = path.lastWhere((m) => m.role == Role.user);
      provider.enqueue(ScriptedTurn.text('Listed.'));
      await runner.edit('s1', last.id, const [TextPart('Do not delete anything; only list the release folder.')]).toList();
      final sent = provider.requests.last.messages.map((m) => m.text).join('\n');
      expect(sent, isNot(contains('sk-SECRET-123456')));
      expect(sent, isNot(contains('Delete every file')));
      expect(sent, contains('Do not delete anything'));
    });
  });

  group('finding 6: the prefix key follows overlay content', () {
    ToolOutputElided elision(String stub) => ToolOutputElided(
          id: 'ctx-elide:m3:call1',
          createdAt: DateTime.utc(2026),
          reason: 'r',
          tokensSaved: 1,
          messageId: 'm3',
          callId: 'call1',
          stub: stub,
        );

    test('re-creating an overlay with the same id but other bytes changes the key', () {
      final k1 = PassthroughContextManager.prefixKeyOf('sys', const [], [elision('[tool result elided: x, 4,423 tokens]')]);
      final k2 = PassthroughContextManager.prefixKeyOf('sys', const [], [elision('[tool result elided: x, 4,752 tokens]')]);
      expect(k2, isNot(k1));
    });

    test('bookkeeping (time, reason, saving) does not change the key; order does not either', () {
      final a = elision('stub');
      final b = ToolOutputElided(
        id: a.id,
        createdAt: DateTime.utc(2027),
        reason: 'another reason',
        tokensSaved: 99,
        messageId: a.messageId,
        callId: a.callId,
        stub: a.stub,
      );
      final other = PayloadTruncated(
        id: 'ctx-trunc:m5:0',
        createdAt: DateTime.utc(2026),
        reason: 'r',
        tokensSaved: 1,
        messageId: 'm5',
        partIndex: 0,
        replacement: 'short',
      );
      expect(
        PassthroughContextManager.prefixKeyOf('sys', const [], [a, other]),
        PassthroughContextManager.prefixKeyOf('sys', const [], [other, b]),
      );
    });

    test('undo then re-elide after calibration drops the reasoning signed under the old stub', () async {
      final counter = HeuristicTokenCounter(family: 'claude');
      final c = Conv()..user('Read the log please.');
      c.toolTurn('call1', 'read_file', {'path': '/var/log/app.log'}, lines(400));
      c.assistant('Here is the log summary.');
      c.toolTurn('call2', 'read_file', {'path': '/a'}, 'a');
      c.toolTurn('call3', 'read_file', {'path': '/b'}, 'b');
      c.toolTurn('call4', 'read_file', {'path': '/c'}, 'c');
      c
        ..user('Thanks. Next question.')
        ..assistant('Sure.')
        ..user('And another one.');
      final mgr = LadderContextManager();
      final settings = ContextSettings(profile: pruneEverything);
      ContextRequest at(List<ContextOverlay> overlays) => req(c.messages,
          overlays: overlays, settings: settings, policy: HistoryPolicy.appendOnly, counter: counter, window: 32000, maxOutput: 4096);
      final p1 = await mgr.prepare(at(const []));
      final stub1 = p1.newOverlays.whereType<ToolOutputElided>().single.stub;
      c.assistant('Answer one.', reasoning: 'thinking under K1', prefixKey: p1.prefixKey);
      counter.calibrate(estimated: 1000, actual: 1300);
      c.user('Another question after undo.');
      final p2 = await mgr.prepare(at(const [])); // the elision was undone
      final again = p2.newOverlays.whereType<ToolOutputElided>().single;
      expect(again.stub, isNot(stub1), reason: 'the scenario needs a different stub under the same id');
      expect(p2.prefixKey, isNot(p1.prefixKey));
      final a = p2.messages.firstWhere((m) => m.id == c.messages[c.messages.length - 2].id);
      expect(a.reasoning, isEmpty, reason: 'reasoning signed under the old bytes must not be replayed');
    });
  });

  group('finding 7: nested tool-result parts are budgeted', () {
    final big = lines(3000);

    test('embedded resource text costs as much as the same text', () {
      final counter = HeuristicTokenCounter();
      Message result(List<ContentPart> content) => Message(
            id: 't',
            role: Role.tool,
            createdAt: DateTime.utc(2026),
            content: [ToolResultPart(callId: 'r1', toolName: 'fs__read', content: content)],
          );
      final asText = counter.countMessage(result([TextPart(big)]));
      final asResource = counter.countMessage(
        result([EmbeddedResourcePart(uri: 'file:///doc.md', mimeType: 'text/markdown', text: big)]),
      );
      expect(asResource, greaterThanOrEqualTo(asText));
      final link = counter.countMessage(result([const ResourceLinkPart(uri: 'file:///a.pdf', description: 'A long report')]));
      expect(link, greaterThan(counter.countMessage(result(const []))));
    });

    Conv withResource() {
      final c = Conv()..user('Open the design doc resource.');
      c.assistant('', calls: [const ToolCall(id: 'r1', name: 'fs__read', arguments: {'path': 'doc.md'})]);
      c.results([
        ToolResultPart(
          callId: 'r1',
          toolName: 'fs__read',
          content: [EmbeddedResourcePart(uri: 'file:///doc.md', mimeType: 'text/markdown', text: big)],
        ),
      ]);
      return c;
    }

    test('the ladder sees a huge embedded resource and compacts instead of overflowing silently', () async {
      final c = withResource()
        ..assistant('Read it.')
        ..user('Summarise section 2.');
      final r = req(c.messages, counter: HeuristicTokenCounter(), window: 8192);
      expect(LadderContextManager().inspect(r).budget.ratio, greaterThan(1.0), reason: 'unshrunk, it cannot fit');
      final p = await LadderContextManager().prepare(r);
      expect(p.newOverlays, isNotEmpty);
      expect(p.budget.fits, isTrue);
      expect(p.messages.map((m) => m.text).join(), isNot(contains(big.substring(0, 2000))));
    });

    test('elision replaces the resource and its stub excerpt shows the resource text', () async {
      final c = withResource();
      for (var i = 0; i < 3; i++) {
        c.toolTurn('s$i', 'fs__stat', {'path': '/f$i'}, 'small $i');
      }
      c
        ..assistant('Read it.')
        ..user('Summarise section 2.');
      final counter = HeuristicTokenCounter();
      final p = await LadderContextManager().prepare(
        req(c.messages, counter: counter, window: 32000, settings: ContextSettings(profile: pruneEverything)),
      );
      final elided = p.newOverlays.whereType<ToolOutputElided>().where((o) => o.callId == 'r1').single;
      expect(elided.tokensSaved, greaterThan(20000));
      expect(elided.stub, contains('[resource file:///doc.md]'));
      final sent = p.messages.firstWhere((m) => m.toolResults.any((r) => r.callId == 'r1')).toolResults.single;
      expect(sent.content.whereType<EmbeddedResourcePart>(), isEmpty, reason: 'the payload was replaced');
    });
  });

  group('finding 9: roles alternate around a summary', () {
    void expectAlternating(List<Message> view) {
      for (var i = 1; i < view.length; i++) {
        expect(view[i - 1].role == Role.user && view[i].role == Role.user, isFalse,
            reason: 'user→user at $i: ${[for (final m in view) '${m.role.name}:${m.kind.name}'].join(' | ')}');
      }
    }

    CompactedRange range(String from, String to) => CompactedRange(
          id: 'ctx-compact:$from:$to',
          createdAt: DateTime.utc(2026),
          reason: 'r',
          tokensSaved: 1,
          fromMessageId: from,
          toMessageId: to,
          summary: const CompactionSummary(goal: 'g'),
          strategyId: 'test',
        );

    test('a pinned user survivor (a handoff seed) is not glued to the summary', () {
      final t = DateTime.utc(2026);
      final path = [
        Message(id: 'seed', role: Role.user, kind: MessageKind.handoff, pinned: true, createdAt: t, content: const [TextPart('handoff')]),
        Message(id: 'ack', parentId: 'seed', role: Role.assistant, kind: MessageKind.notice, pinned: true, createdAt: t, content: const [TextPart('ok')]),
        Message(id: 'u1', parentId: 'ack', role: Role.user, createdAt: t, content: const [TextPart('one')]),
        Message(id: 'a1', parentId: 'u1', role: Role.assistant, createdAt: t, content: const [TextPart('two')]),
        Message(id: 'u2', parentId: 'a1', role: Role.user, createdAt: t, content: const [TextPart('three')]),
      ];
      final view = PassthroughContextManager.applyOverlays(path, [range('seed', 'a1')]);
      expectAlternating(view);
      expect(view.map((m) => m.id), [
        'summary:ctx-compact:seed:a1',
        'summary:ctx-compact:seed:a1:ack',
        'seed',
        'ack',
        'u2',
      ]);
    });

    test('two pinned user messages inside a range, with the next user turn after it', () {
      final c = Conv()
        ..user('Always answer in English.', pinned: true)
        ..assistant('ok')
        ..user('Use metric units.', pinned: true)
        ..assistant('ok')
        ..user('Now the real question.');
      final view = PassthroughContextManager.applyOverlays(c.messages, [range('m1', 'm4')]);
      expectAlternating(view);
      expect({for (final m in view) m.id}, hasLength(view.length), reason: 'acks have distinct ids');
    });
  });
}
