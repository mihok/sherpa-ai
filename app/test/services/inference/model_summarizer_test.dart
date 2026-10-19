import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa/services/inference/runner_extras.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_core/testing.dart';
import 'package:sherpa_inference/sherpa_inference.dart' show InferencePriority;

String validSummary() => jsonEncode({
      'schemaVersion': 2,
      'goal': 'Plan the trip',
      'constraints': ['[user] No flights'],
      'decisions': ['[model] Take the night train'],
      'openTasks': ['[model] Book seats'],
      'currentWork': 'Comparing trains',
      'nextStep': 'Book the train',
      'keyFacts': ['[user] Two travellers'],
    });

ScriptedTurn reply(String text) => ScriptedTurn([TextDelta(text), const Finish(FinishReason.stop)]);

/// A provider whose replies never arrive until cancelled.
final class HangingProvider implements ModelProvider {
  int cancelled = 0;

  @override
  ProviderInfo get info => const ProviderInfo(
        id: 'slow',
        kind: ProviderKind.fake,
        displayName: 'Slow',
        location: ExecutionLocation.remote,
      );

  @override
  Future<ModelCapabilities> capabilities(String modelId) async => const ModelCapabilities(contextLength: 32768);

  @override
  Future<List<ModelDescriptor>> listModels() async => const [];

  @override
  Stream<ModelEvent> stream(ModelRequest request, {CancellationToken? cancel}) async* {
    final reason = await cancel!.whenCancelled;
    cancelled++;
    throw CancelledException(reason);
  }
}

/// A long transcript worth compacting.
List<Message> longChat() {
  final out = <Message>[];
  var at = DateTime.utc(2026, 10, 19);
  for (var i = 0; i < 24; i++) {
    for (final role in [Role.user, Role.assistant]) {
      at = at.add(const Duration(seconds: 1));
      out.add(Message(
        id: 'm${out.length + 1}',
        parentId: out.isEmpty ? null : out.last.id,
        role: role,
        createdAt: at,
        content: [TextPart('${role.name} turn $i: ${'some words about the trip and the trains ' * 6}')],
        finishReason: role == Role.assistant ? 'stop' : null,
      ));
    }
  }
  return out;
}

ContextRequest request(List<Message> path, {CancellationToken? cancel}) => ContextRequest(
      sessionId: 's1',
      path: path,
      overlays: const [],
      tools: const [],
      capabilities: const ModelCapabilities(contextLength: 16384),
      counter: HeuristicTokenCounter(),
      systemPrompt: 'You are a test assistant.',
      boundaryNonce: 'nonce0123456789ab',
      cancel: cancel,
    );

void main() {
  group('ModelSummarizer', () {
    test('writes the summary with the model when it can', () async {
      final provider = ScriptedProvider([reply(validSummary())]);
      final ladder = withSummarizer(LadderContextManager(), ModelSummarizer(provider: provider, modelId: 'm')) as LadderContextManager;
      final outcome = await ladder.compactNow(request(longChat()));
      expect(outcome.compacted, isTrue);
      expect(outcome.usedFallback, isFalse);
      expect(outcome.overlay!.strategyId, 'model:scripted/m');
      expect(provider.requests, hasLength(1));
      expect(provider.requests.single.params.jsonSchema, isNotNull);
    });

    test('a model below the size floor is not asked; the extractive summary is used', () async {
      final provider = ScriptedProvider(
        [reply(validSummary())],
        capabilitiesValue: const ModelCapabilities(contextLength: 32768, parameterCount: 600000000),
      );
      final s = ModelSummarizer(provider: provider, modelId: 'tiny', minParameters: minSummarizerParameters);
      await expectLater(
        s.summarize(const CompactionInput(messages: [])),
        throwsA(isA<CompactionRejected>().having((e) => e.message, 'message', contains('too small'))),
      );
      final ladder = withSummarizer(LadderContextManager(), s) as LadderContextManager;
      final outcome = await ladder.compactNow(request(longChat()));
      expect(outcome.usedFallback, isTrue);
      expect(outcome.overlay!.strategyId, 'extractive');
      expect(provider.requests, isEmpty);
    });

    test('an unavailable engine falls back to the extractive summary', () async {
      final s = ModelSummarizer(provider: _BrokenProvider(), modelId: 'm', minParameters: minSummarizerParameters);
      final ladder = withSummarizer(LadderContextManager(), s) as LadderContextManager;
      final outcome = await ladder.compactNow(request(longChat()));
      expect(outcome.usedFallback, isTrue);
      expect(outcome.overlay!.strategyId, 'extractive');
    });

    test('a summary that fails validation twice falls back to the extractive one', () async {
      final provider = ScriptedProvider([reply('Sure, here is a summary!'), reply('{"goal": 7, "constraints": 3}')]);
      final ladder = withSummarizer(LadderContextManager(), ModelSummarizer(provider: provider, modelId: 'm')) as LadderContextManager;
      final outcome = await ladder.compactNow(request(longChat()));
      expect(provider.requests, hasLength(2), reason: 'one retry with the validation errors');
      expect(outcome.usedFallback, isTrue);
      expect(outcome.overlay!.strategyId, 'extractive');
    });

    test('a slow summary times out, is cancelled, and the extractive one is used', () async {
      final provider = HangingProvider();
      final s = ModelSummarizer(provider: provider, modelId: 'm', timeout: const Duration(milliseconds: 50));
      final ladder = withSummarizer(LadderContextManager(), s) as LadderContextManager;
      final run = CancellationToken();
      final outcome = await ladder.compactNow(request(longChat(), cancel: run));
      expect(outcome.usedFallback, isTrue);
      expect(outcome.overlay!.strategyId, 'extractive');
      await pumpEventQueue();
      expect(provider.cancelled, 1, reason: 'the abandoned request is cancelled');
      expect(run.isCancelled, isFalse, reason: "the run's own token is untouched");
    });

    test('stopping the run still cancels (never reported as a fallback)', () async {
      final s = ModelSummarizer(provider: HangingProvider(), modelId: 'm', timeout: const Duration(seconds: 30));
      final ladder = withSummarizer(LadderContextManager(), s) as LadderContextManager;
      final run = CancellationToken();
      final pending = ladder.compactNow(request(longChat(), cancel: run));
      await pumpEventQueue();
      run.cancel('stopped by user');
      await expectLater(pending, throwsA(isA<CancelledException>()));
    });
  });

  group('wiring', () {
    test('withSummarizer keeps the ladder settings and leaves other managers alone', () {
      ToolDefinition? lookup(String name) => null;
      ToolAnnotations annotations(ToolDefinition t) => const ToolAnnotations();
      final base = LadderContextManager(
        memoryPolicy: MemoryContextPolicy.none,
        location: ExecutionLocation.remote,
        toolLookup: lookup,
        annotationsFor: annotations,
      );
      final s = ModelSummarizer(provider: ScriptedProvider(const []), modelId: 'm');
      final rebuilt = withSummarizer(base, s) as LadderContextManager;
      expect(rebuilt.strategy, same(s));
      expect(rebuilt.fallbackStrategy, same(base.fallbackStrategy));
      expect(rebuilt.memoryPolicy, same(base.memoryPolicy));
      expect(rebuilt.location, ExecutionLocation.remote);
      expect(rebuilt.toolLookup, same(base.toolLookup));
      expect(rebuilt.annotationsFor, same(base.annotationsFor));
      expect(modelSummarizerOf(rebuilt), same(s));
      const passthrough = PassthroughContextManager();
      expect(withSummarizer(passthrough, s), same(passthrough));
      expect(modelSummarizerOf(passthrough), isNull);
      expect(modelSummarizerOf(base), isNull);
    });

    test('withLocalSummarizer: background priority, the size floor, the local timeout', () {
      final local = ScriptedProvider(const []);
      final m = withLocalSummarizer(LadderContextManager(), local, 'm1');
      final s = modelSummarizerOf(m)!;
      expect(s.priority, InferencePriority.background);
      expect(s.modelId, 'm1');
      expect(s.timeout, localSummaryTimeout);
      expect(s.minParameters, minSummarizerParameters);
      expect((m as LadderContextManager).fallbackStrategy, isA<ExtractiveContextStrategy>());
    });
  });
}

final class _BrokenProvider implements ModelProvider {
  @override
  ProviderInfo get info => const ProviderInfo(
        id: 'local',
        kind: ProviderKind.localLlamaCpp,
        displayName: 'On this device',
        location: ExecutionLocation.onDevice,
      );

  @override
  Future<ModelCapabilities> capabilities(String modelId) async =>
      throw const ProviderException(ProviderErrorKind.unsupported, 'On-device inference is unavailable: no engine');

  @override
  Future<List<ModelDescriptor>> listModels() async => const [];

  @override
  Stream<ModelEvent> stream(ModelRequest request, {CancellationToken? cancel}) =>
      Stream.error(const ProviderException(ProviderErrorKind.unsupported, 'no engine'));
}
