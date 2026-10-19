import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa/features/chat/state/chat_dependencies.dart';
import 'package:sherpa/services/inference/runner_extras.dart';
import 'package:sherpa/state/services.dart';
import 'package:sherpa/state/ui_preferences.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_core/testing.dart';

import 'support/context_harness.dart';

/// An exact counter (no estimate margin), like the engine's.
final class ExactCounter implements TokenCounter {
  @override
  bool get isExact => true;

  @override
  int countText(String text) => (text.length / 4).ceil();

  @override
  int countMessage(Message message) =>
      4 + message.content.fold(0, (n, p) => n + countText(jsonEncode(p.toJson())));

  @override
  int countTools(List<ToolDefinition> tools) => tools.fold(0, (n, t) => n + countText(jsonEncode(t.toJson())));
}

/// The extractive summary under another name, so a test can tell which
/// manager compacted.
final class NamedStrategy implements ContextStrategy {
  const NamedStrategy(this.id);

  @override
  final String id;

  @override
  Future<CompactionSummary> summarize(CompactionInput input, {CancellationToken? cancel}) =>
      const ExtractiveContextStrategy().summarize(input, cancel: cancel);
}

String validSummary() => jsonEncode({
      'schemaVersion': 2,
      'goal': 'Audit the logs',
      'constraints': ['[user] Never email customers'],
      'decisions': ['[model] Read one log per day'],
      'openTasks': ['[model] Read the next log'],
      'currentWork': 'Reading logs',
      'nextStep': 'Read the next log',
      'keyFacts': ['[tool:read_file] Traffic was steady'],
    });

const ModelChoice cloud = ModelChoice(providerId: kProviderId, modelId: kModelId);

void main() {
  late ContextHarness h;
  tearDown(() => h.dispose());

  group('ContextActions uses the runner extras (item 3)', () {
    test('the inspector counts with the extras counter; Compact now uses the extras manager', () async {
      final seen = <(String, ModelChoice)>[];
      final engine = ExactCounter();
      h = ContextHarness(extra: [
        chatRunnerExtrasProvider.overrideWithValue((provider, choice, base) {
          seen.add((provider.info.id, choice));
          return RunnerExtras(
            counter: engine,
            contextManager: LadderContextManager(strategy: const NamedStrategy('engine-summary')),
          );
        }),
      ]);
      await h.seedConversation(turns: 4, resultLines: 20);
      final chat = await h.open();

      final snap = (await chat.inspectContext())!;
      expect(seen.last, (kProviderId, cloud));
      expect(snap.budget.exact, isTrue, reason: 'counted with the extras counter');
      expect(snap.budget.safetyMargin, 0, reason: 'no estimate margin for an exact counter');
      expect(snap.canCompact, isTrue);

      final outcome = (await chat.compactNow())!;
      expect(outcome.compacted, isTrue, reason: outcome.skippedReason);
      expect(outcome.overlay!.strategyId, 'engine-summary', reason: "the extras' context manager compacted");
      expect(((await h.store.overlays(kSession)).single as CompactedRange).strategyId, 'engine-summary');
    });

    test('a passthrough manager from the extras measures only', () async {
      h = ContextHarness(extra: [
        chatRunnerExtrasProvider.overrideWithValue(
          (provider, choice, base) => const RunnerExtras(contextManager: PassthroughContextManager()),
        ),
      ]);
      await h.seedConversation(turns: 2, resultLines: 5);
      final chat = await h.open();
      expect((await chat.inspectContext())!.canCompact, isFalse);
    });
  });

  group('who writes summaries (item 5)', () {
    test('remote chats: extractive by default; opting in makes the chat model write them', () async {
      h = ContextHarness(turns: [textTurn(validSummary())]);
      await h.seedConversation(turns: 4, resultLines: 20);
      final chat = await h.open();
      final extras = h.container.read(chatContextExtrasProvider);
      final base = h.manager;
      final off = extras(h.provider, cloud, base);
      expect(off.contextManager, same(base));
      expect(modelSummarizerOf(off.contextManager!), isNull);

      await h.container.read(uiSettingsProvider.notifier).update((s) => s.copyWith(modelSummaries: true));
      final on = h.container.read(chatContextExtrasProvider)(h.provider, cloud, base);
      final s = modelSummarizerOf(on.contextManager!)!;
      expect(s.provider, same(h.provider));
      expect(s.modelId, kModelId);
      expect(s.timeout, remoteSummaryTimeout);
      expect(s.priority, isNull);

      // "Compact now" goes through the same manager: the model wrote it.
      final outcome = (await chat.compactNow())!;
      expect(outcome.compacted, isTrue, reason: outcome.skippedReason);
      expect(outcome.usedFallback, isFalse);
      expect(outcome.overlay!.strategyId, 'model:$kProviderId/$kModelId');
      expect(h.provider.requests.single.params.jsonSchema, isNotNull, reason: 'the summary request');
    });

    test('opted out, Compact now never calls the provider', () async {
      h = ContextHarness();
      await h.seedConversation(turns: 4, resultLines: 20);
      final chat = await h.open();
      final outcome = (await chat.compactNow())!;
      expect(outcome.overlay!.strategyId, 'extractive');
      expect(h.provider.requests, isEmpty);
    });

    test('a failed model summary falls back to the extractive one', () async {
      h = ContextHarness(turns: [textTurn('not json'), textTurn('still not json')]);
      await h.seedConversation(turns: 4, resultLines: 20);
      final chat = await h.open();
      await h.container.read(uiSettingsProvider.notifier).update((s) => s.copyWith(modelSummaries: true));
      final outcome = (await chat.compactNow())!;
      expect(h.provider.requests, hasLength(2));
      expect(outcome.usedFallback, isTrue);
      expect(outcome.overlay!.strategyId, 'extractive');
    });

    test('toggling the preference rebuilds the runner with the new manager', () async {
      final bases = <ContextManager>[];
      h = ContextHarness(turns: [textTurn('First.'), textTurn('Second.')], extra: [
        chatRunnerExtrasProvider.overrideWithValue((provider, choice, base) {
          bases.add(base);
          return const RunnerExtras();
        }),
      ]);
      await h.createSession();
      final chat = await h.open();
      await chat.send('One');
      expect(bases, hasLength(1));
      expect(modelSummarizerOf(bases.single), isNull);
      await chat.send('Two');
      expect(bases, hasLength(1), reason: 'the same runner while nothing changed');

      await h.container.read(uiSettingsProvider.notifier).update((s) => s.copyWith(modelSummaries: true));
      h.provider.enqueue(textTurn('Third.'));
      await chat.send('Three');
      expect(bases, hasLength(2), reason: 'the runner was rebuilt');
      expect(modelSummarizerOf(bases.last)!.provider, same(h.provider));
    });

    test('the on-device provider is never handed to the remote opt-in', () {
      h = ContextHarness();
      final extras = h.container.read(chatContextExtrasProvider);
      final local = ScriptedProvider(const []);
      final e = extras(local, const ModelChoice(providerId: localProviderId, modelId: 'm1'), h.manager);
      expect(e.contextManager, same(h.manager), reason: 'local extras are not wired here; the base stays');
    });
  });
}
