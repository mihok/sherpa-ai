import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa/services/downloads/downloads.dart';
import 'package:sherpa/services/inference/local_model_provider.dart';
import 'package:sherpa/services/inference/local_provider_registry.dart';
import 'package:sherpa/services/inference/record_key_value_store.dart';
import 'package:sherpa/services/inference/runner_extras.dart';
import 'package:sherpa/state/in_memory/in_memory_provider_registry.dart';
import 'package:sherpa/state/services.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_data/sherpa_data.dart' show DocumentCollections;
import 'package:sherpa_inference/sherpa_inference.dart';
import 'package:sherpa_providers/sherpa_providers.dart';

import '../../support/harness.dart' show FakeEndpoint, FakeModelProvider;
import 'support/local_rig.dart';

final ProviderConfig cloud = ProviderConfig(
  id: 'cloud',
  flavor: ApiFlavor.anthropic,
  displayName: 'Cloud',
  baseUrl: Uri.parse('https://api.example.com/v1'),
  defaultModelId: 'big',
);

void main() {
  late LocalRig rig;
  late InMemoryProviderRegistry inner;
  late LocalProviderRegistry registry;

  setUp(() async {
    rig = await LocalRig.create();
    inner = InMemoryProviderRegistry(
      secrets: InMemorySecretStore(),
      factory: (c, key) => FakeModelProvider(c, const FakeEndpoint(models: ['big']), key),
      initial: [cloud],
    );
    registry = LocalProviderRegistry(inner, rig.local);
  });

  tearDown(() async {
    await registry.dispose();
    await rig.dispose();
  });

  group('LocalProviderRegistry', () {
    test('remote configs pass through; the local provider has no config', () async {
      expect(registry.configs.map((c) => c.id), ['cloud']);
      expect((await registry.models('cloud')).single.id, 'big');
      expect((await registry.resolve('cloud')).info.id, 'cloud');
      expect(await registry.probe('cloud'), EndpointStatus.ok);
      expect(await registry.hasApiKey(localProviderId), isFalse);
    });

    test('resolves local to the on-device provider and lists the library', () async {
      await rig.add(libraryModel('m1', name: 'Qwen3 0.6B'));
      final p = await registry.resolve(localProviderId);
      expect(p, isA<LocalModelProvider>());
      expect(p.info.location, ExecutionLocation.onDevice);
      expect(p.info.displayName, kLocalProviderName);
      expect((p as LocalModelProvider).engine, isA<LlamaCppProvider>(), reason: 'resolve starts the engine');
      expect((await registry.models(localProviderId)).single.displayName, 'Qwen3 0.6B');
      expect(await registry.probe(localProviderId), EndpointStatus.ok);
      expect(await replyText(p, 'm1', 'hi'), 'ok');
    });

    test('reserves the local id', () async {
      final fake = ProviderConfig(
        id: localProviderId,
        flavor: ApiFlavor.openAiChat,
        displayName: 'Mine',
        baseUrl: Uri.parse('http://127.0.0.1:8080/v1'),
      );
      expect(() => registry.add(fake), throwsStateError);
      expect(() => registry.update(fake), throwsStateError);
      await registry.remove(localProviderId);
      expect(registry.configs, hasLength(1));
      await registry.remove('cloud');
      expect(registry.configs, isEmpty);
    });

    test('changes fire for config edits and for library changes', () async {
      final seen = <List<ProviderConfig>>[];
      final sub = registry.changes.listen(seen.add);
      addTearDown(sub.cancel);
      await rig.local.start();
      await registry.update(cloud);
      await rig.add(libraryModel('m1'));
      await until(() => seen.length >= 2);
      expect(seen.every((c) => c.single.id == 'cloud'), isTrue);
    });
  });

  group('runner extras', () {
    const choice = ModelChoice(providerId: localProviderId, modelId: 'm1');

    test('the local provider gets the exact counter and a warming context manager', () async {
      await rig.add(libraryModel('m1'));
      final p = await registry.resolve(localProviderId);
      const base = PassthroughContextManager();
      final e = localRunnerExtras(p, choice, base);
      expect(e.counter, isA<EngineTokenCounter>());
      expect(e.counter, same((p as LocalModelProvider).tokenCounter('m1')));
      expect(e.contextManager, isA<WarmingContextManager>());
      expect((e.contextManager! as WarmingContextManager).inner, same(base));
    });

    test('remote providers get nothing', () async {
      final p = await registry.resolve('cloud');
      expect(localRunnerExtras(p, const ModelChoice(providerId: 'cloud', modelId: 'big'), const PassthroughContextManager()),
          noRunnerExtras);
    });

    test('a local chat summarizes with its own model at background priority', () async {
      await rig.add(libraryModel('m1'));
      final p = await registry.resolve(localProviderId);
      final e = localRunnerExtras(p, choice, LadderContextManager());
      final ladder = (e.contextManager! as WarmingContextManager).inner as LadderContextManager;
      final s = ladder.strategy as ModelSummarizer;
      expect(modelSummarizerOf(e.contextManager!), same(s));
      expect(s.priority, InferencePriority.background);
      expect(s.provider, isNot(same(p)), reason: 'a background view, not the reply path');
      expect(s.provider.info.id, localProviderId);
      expect(s.modelId, 'm1');
      expect(s.timeout, localSummaryTimeout);
      expect(ladder.fallbackStrategy, isA<ExtractiveContextStrategy>());
      // A background summary is not a reply: it neither schedules autotune
      // nor carries the crash notice; it streams through the engine.
      expect(await replyText(s.provider, 'm1', 'summarize'), 'ok');
    });

    test('settings of a local summarizer are kept; a remote one is replaced (no remote compaction)', () async {
      await rig.add(libraryModel('m1'));
      final p = await registry.resolve(localProviderId);
      final configured = LadderContextManager(strategy: ModelContextStrategy(provider: p, modelId: 'm1', maxAttempts: 3));
      expect(modelSummarizerOf(localRunnerExtras(p, choice, configured).contextManager!)!.inner.maxAttempts, 3);

      final remote = await registry.resolve('cloud');
      final remoteLadder = LadderContextManager(strategy: ModelContextStrategy(provider: remote, modelId: 'big'));
      final s = modelSummarizerOf(localRunnerExtras(p, choice, remoteLadder).contextManager!)!;
      expect(s.provider.info.id, localProviderId);
      expect(s.modelId, 'm1');
    });
  });

  test('RecordKeyValueStore round-trips values and clears its collection only', () async {
    final records = InMemoryRecordStore();
    final store = RecordKeyValueStore(records);
    await records.put(DocumentCollections.modelLibrary, 'x', {'id': 'x'});
    expect(await store.read('a'), isNull);
    await store.write('a', {'n': 1, 'nested': {'k': 'v'}});
    await store.write('b', {'n': 2});
    expect(await store.read('a'), {'n': 1, 'nested': {'k': 'v'}});
    await store.delete('b');
    expect(await store.read('b'), isNull);
    await store.clear();
    expect(await store.read('a'), isNull);
    expect(await records.get(DocumentCollections.modelLibrary, 'x'), isNotNull);
  });
}
