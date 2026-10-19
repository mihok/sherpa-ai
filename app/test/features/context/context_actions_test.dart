import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa/features/chat/state/chat_controller.dart';
import 'package:sherpa/features/chat/state/chat_view_state.dart';
import 'package:sherpa/features/context/state/context_actions.dart';
import 'package:sherpa/state/services.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_core/testing.dart';

import '../chat/support/fakes.dart';
import 'support/context_harness.dart';

String encode(List<Message> ms) => jsonEncode([for (final m in ms) m.toJson()]);

void main() {
  late ContextHarness h;
  tearDown(() => h.dispose());

  test('the inspection is exactly what the runner sent, with the overlays it persisted', () async {
    h = ContextHarness(turns: [textTurn('Summary: all quiet.')]);
    await h.seedConversation(turns: 9);
    final chat = await h.open();
    await chat.send('Summarize what changed this week.');

    final overlays = await h.store.overlays(kSession);
    expect(overlays, isNotEmpty, reason: 'the ladder had to make room in an 8K window');
    final audit = await h.store.audit(kSession);
    expect(audit.where((a) => a.kind == AuditKind.contextAction), hasLength(overlays.length));

    final snap = (await chat.inspectContext())!;
    expect(snap.overlays.map((o) => o.id), unorderedEquals(overlays.map((o) => o.id)));
    final sent = h.provider.requests.last.messages;
    final seen = snap.inspection.messages;
    // The view now also holds the reply that run produced.
    expect(seen.last.role, Role.assistant);
    expect(encode(seen.sublist(0, seen.length - 1)), encode(sent));
    expect(snap.inspection.systemPrompt, h.provider.requests.last.systemPrompt);
    expect(snap.inspection.items.fold(0, (n, i) => n + i.tokens),
        snap.budget.pinnedTokens + snap.budget.historyTokens);
  });

  test('Compact now persists a summary and an audit line, and refreshes the ring', () async {
    h = ContextHarness();
    await h.seedConversation(turns: 4, resultLines: 20);
    final chat = await h.open();
    final before = (await chat.inspectContext())!;
    expect(before.inspection.diffs, isEmpty);
    expect(before.inspection.level, ContextLevel.healthy);

    final outcome = (await chat.compactNow())!;
    expect(outcome.compacted, isTrue, reason: outcome.skippedReason);
    final stored = await h.store.overlays(kSession);
    expect(stored.single, isA<CompactedRange>());
    expect(stored.single.reason, startsWith('Compacted on request'));
    final audit = (await h.store.audit(kSession)).last;
    expect(audit.kind, AuditKind.contextAction);
    expect(audit.data['trigger'], 'user');
    expect(audit.data['overlay'], 'compact_range');

    final after = (await chat.inspectContext())!;
    expect(after.inspection.items.first.source, ContextItemSource.summary);
    expect(after.budget.inputTokens, lessThan(before.budget.inputTokens));
    expect(h.container.read(chatControllerProvider(kSession)).budget?.inputTokens, after.budget.inputTokens);
  });

  test('undo removes the overlay, and the next prepare sends the original text again', () async {
    h = ContextHarness();
    await h.seedConversation(turns: 4, resultLines: 20);
    final chat = await h.open();
    final overlay = (await chat.compactNow())!.overlay!;
    final original = (await h.activePath()).first.text;

    Future<PreparedContext> prepare() async {
      final actions = ContextActions(
        store: h.store,
        registry: h.registry,
        router: h.router,
        config: const AgentConfig(),
        manager: h.manager,
        clock: h.clock,
        ids: h.ids,
      );
      final r = await actions.request(kSession, const ModelChoice(providerId: kProviderId, modelId: kModelId));
      return h.manager.prepare(r);
    }

    final compacted = await prepare();
    expect(compacted.messages.first.id, 'summary:${overlay.id}');
    expect(compacted.messages.map((m) => m.text), isNot(contains(original)));

    final removed = await chat.undoContextChange(overlay.id);
    expect(removed, [overlay.id]);
    expect(await h.store.overlays(kSession), isEmpty);
    expect((await h.store.audit(kSession)).last.data['undo'], isTrue);

    final restored = await prepare();
    expect(restored.newOverlays, isEmpty, reason: 'a healthy context needs no new rewrite');
    expect(restored.messages.first.text, original);
    expect(encode(restored.messages), encode(await h.activePath()));
  });

  test('undoing a summary that a later one merged undoes both', () async {
    h = ContextHarness();
    await h.seedConversation(turns: 4, resultLines: 20);
    final chat = await h.open();
    final first = (await chat.compactNow())!.overlay!;
    for (var n = 5; n <= 8; n++) {
      await h.addTurn(n, resultLines: 20);
    }
    final second = (await chat.compactNow())!.overlay!;
    expect(second.summary.compactionCount, 2, reason: 'rolling merge, not nested');

    final snap = (await chat.inspectContext())!;
    final d1 = snap.inspection.diffFor(first.id)!;
    expect(d1.status, OverlayStatus.shadowed);
    expect(d1.dependents, [second.id]);
    expect(snap.inspection.undoSet(first.id), [first.id, second.id]);

    final removed = await chat.undoContextChange(first.id);
    expect(removed, unorderedEquals([first.id, second.id]));
    expect(await h.store.overlays(kSession), isEmpty);
  });

  test('context changes are refused while a reply is running', () async {
    final gate = Completer<void>();
    h = ContextHarness(
      tools: [
        FakeTool('slow_lookup', onRun: (args, ctx) async {
          await gate.future;
          return ToolResult.text('found it');
        }),
      ],
      turns: [
        ScriptedTurn.toolCalls(const [ToolCall(id: 'c-slow', name: 'slow_lookup', arguments: {})]),
        textTurn('Done.'),
      ],
    );
    await h.seedConversation(turns: 4, resultLines: 20);
    final chat = await h.open();
    final run = chat.send('Look it up.');
    await h.until(() => h.router.lookup('slow_lookup') != null && chat.isRunning);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(await chat.compactNow(), isNull);
    expect(await chat.undoContextChange('anything'), isNull);
    gate.complete();
    await run;
    expect(chat.isRunning, isFalse);
    expect(await h.store.overlays(kSession), isEmpty);
  });

  test("the runner's handoff advice in the chat comes with a Hand off action", () async {
    h = ContextHarness(turns: [textTurn('Noted.')]);
    await h.createSession();
    final chat = await h.open();
    // One huge first message: nothing to elide, no earlier turn to summarize,
    // so the ladder can only advise.
    await chat.send(lines(275));
    final notice = h.container
        .read(chatControllerProvider(kSession))
        .notices
        .where((n) => n.code == 'handoff_recommended')
        .single;
    expect(notice.action, ChatNoticeAction.handOff);
    expect(notice.message, contains('Consider continuing in a new session'));
  });

  test('advice: a handoff near the top of the window, a hard stop past it', () {
    ContextInspection inspect(int n) => LadderContextManager(clock: FakeClock()).inspect(
          ContextRequest(
            sessionId: 's',
            path: [Message(id: 'u', role: Role.user, content: [TextPart(lines(n))], createdAt: DateTime.utc(2026))],
            overlays: const [],
            tools: const [],
            capabilities: kSmallWindow,
            counter: HeuristicTokenCounter(),
          ),
        );
    var n = 10;
    while (inspect(n).budget.ratio < inspect(n).profile.thresholds.handoff) {
      n += 5;
    }
    final near = inspect(n);
    expect(near.budget.fits, isTrue);
    final rec = ContextActions.recommend(near, const [], const ContextSettings())!;
    expect(rec.kind, ContextRecommendationKind.handoff);
    expect(rec.message, contains('full'));

    final healthy = inspect(10);
    expect(ContextActions.recommend(healthy, const [], const ContextSettings()), isNull);

    final stop = ContextActions.recommend(inspect(n * 2), const [], const ContextSettings())!;
    expect(stop.kind, ContextRecommendationKind.hardStop);
    expect(stop.message, contains('no longer fits'));
  });
}
