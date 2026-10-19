import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa/services/downloads/downloads.dart';
import 'package:sherpa/services/inference/autotune_scheduler.dart';
import 'package:sherpa/services/inference/local_inference.dart';
import 'package:sherpa/services/inference/local_model_provider.dart';
import 'package:sherpa/services/inference/local_model_specs.dart';
import 'package:sherpa/services/inference/local_provider_registry.dart';
import 'package:sherpa/services/inference/runner_extras.dart';
import 'package:sherpa/state/services.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_data/sherpa_data.dart' show DocumentCollections;
import 'package:sherpa_hub/sherpa_hub.dart' show ModelFormat;
import 'package:sherpa_inference/sherpa_inference.dart';
import 'package:sherpa_inference/testing.dart';

import '../../features/chat/support/fakes.dart' show FakeProviderRegistry;
import 'support/local_rig.dart';

void main() {
  late LocalRig rig;

  tearDown(() async => rig.dispose());

  group('library → lifecycle registrations', () {
    test('registers runnable GGUFs with identity, projector and context defaults', () async {
      rig = await LocalRig.create();
      await rig.add(libraryModel('m1', defaultContext: 16384, mmproj: 'imported/m1/mmproj.gguf'));
      await rig.add(libraryModel('m2', defaultContext: null, toolUse: false, sha: null));
      await rig.add(libraryModel('broken', issue: LibraryIssue.missingFiles));
      await rig.add(libraryModel('mlx', format: ModelFormat.mlx));

      final status = await rig.local.start();
      expect(status.state, LocalEngineState.ready);
      final lc = rig.local.lifecycle!;
      expect(lc.models.map((s) => s.id), unorderedEquals(['m1', 'm2']));

      final m1 = lc.spec('m1')!;
      expect(m1.path, rig.layout.libraryPath('imported/m1/model.gguf'));
      expect(File(m1.path).isAbsolute, isTrue);
      expect(m1.identity, 'sha256:${'ab12cd34ef56' * 5}ab12');
      expect(m1.mmprojPath, rig.layout.libraryPath('imported/m1/mmproj.gguf'));
      expect(m1.preferredContext, 16384);
      expect(m1.trainContext, 40960);
      expect(m1.toolCalling, isTrue);
      expect(m1.displayName, 'Qwen3 0.6B');

      final m2 = lc.spec('m2')!;
      expect(m2.identity, isNull, reason: 'no verified hash: the engine fingerprints the file');
      expect(m2.preferredContext, kDefaultLocalContext);
      expect(m2.toolCalling, isFalse);
    });

    test('follows library changes: added, broken and deleted models; a deleted warm model unloads', () async {
      rig = await LocalRig.create();
      await rig.add(libraryModel('m1'));
      await rig.local.start();
      final lc = rig.local.lifecycle!;
      final changes = <void>[];
      final sub = rig.local.modelChanges.listen(changes.add);
      addTearDown(sub.cancel);

      await rig.add(libraryModel('m2', name: 'Second'));
      await until(() => lc.spec('m2') != null);
      expect(changes, isNotEmpty);

      // Warm m1, then delete it from the library.
      expect(await replyText(rig.local.provider, 'm1', 'hi'), 'ok');
      expect(rig.local.loadedModelId, 'm1');
      await rig.library.delete('m1');
      await until(() => lc.spec('m1') == null && lc.loaded == null);
      expect(rig.host.liveModels, isEmpty);

      // A file goes missing: the integrity check marks it, the engine stops offering it.
      await rig.add(libraryModel('m2', name: 'Second', issue: LibraryIssue.missingFiles));
      await until(() => lc.spec('m2') == null);
    });

    test('caps huge record defaults and honours the configured maximum', () {
      expect(preferredLocalContext(libraryModel('a', defaultContext: 131072, trainContext: 131072)), kMaxDefaultLocalContext);
      expect(preferredLocalContext(libraryModel('a', defaultContext: 131072), maxContext: 2048), 2048);
      expect(preferredLocalContext(libraryModel('a', defaultContext: 4096, trainContext: 2048)), 2048);
      expect(preferredLocalContext(libraryModel('a', defaultContext: 512, trainContext: 40960)), kMinLocalContext);
    });

    test('lists library models with capabilities before the engine starts', () async {
      rig = await LocalRig.create();
      await rig.add(libraryModel('m1', defaultContext: 8192));
      await rig.add(libraryModel('m2', toolUse: false, reasoning: false));
      await rig.add(libraryModel('broken', issue: LibraryIssue.sizeMismatch));
      final list = await rig.local.listModels();
      expect(rig.hosts, isEmpty, reason: 'listing never starts the engine');
      expect(list.map((d) => d.id), unorderedEquals(['m1', 'm2']));
      final m1 = list.firstWhere((d) => d.id == 'm1');
      expect(m1.providerId, localProviderId);
      expect(m1.displayName, 'Qwen3 0.6B');
      expect(m1.capabilities.contextLength, 8192);
      expect(m1.capabilities.toolCallFormat, ToolCallFormat.jsonGrammar);
      expect(m1.capabilities.reasoning, ReasoningSupport.optional);
      expect(m1.capabilities.historyPolicy, HistoryPolicy.appendOnly);
      final m2 = list.firstWhere((d) => d.id == 'm2');
      expect(m2.capabilities.canCallTools, isFalse);
    });
  });

  group('engine unavailable', () {
    test('degrades gracefully: a reason, failing requests, models still listed', () async {
      rig = await LocalRig.create(
        host: () => FakeEngineHost()
          ..startError = const EngineUnavailableException(
              'the on-device engine library could not be loaded (libsherpa_engine.so)'),
      );
      await rig.add(libraryModel('m1'));
      final status = await rig.local.start();
      expect(status.state, LocalEngineState.unavailable);
      expect(status.reason, contains('could not be loaded'));
      expect(status.unavailableMessage, startsWith('On-device models are unavailable: '));
      expect(rig.local.engine, isNull);

      final provider = rig.local.provider;
      expect(provider.info.location, ExecutionLocation.onDevice);
      await expectLater(
        provider.stream(request('m1', 'hi')).toList(),
        throwsA(isA<ProviderException>()
            .having((e) => e.kind, 'kind', ProviderErrorKind.unsupported)
            .having((e) => e.message, 'message', contains('could not be loaded'))),
      );
      await expectLater(provider.capabilities('m1'), throwsA(isA<ProviderException>()));
      expect((await provider.listModels()).single.id, 'm1');

      final registry = LocalProviderRegistry(FakeProviderRegistry(), rig.local);
      addTearDown(registry.dispose);
      expect(await registry.resolve(localProviderId), same(provider));
      expect(await registry.probe(localProviderId), EndpointStatus.error);
      expect(
        localRunnerExtras(provider, const ModelChoice(providerId: localProviderId, modelId: 'm1'), const PassthroughContextManager()),
        noRunnerExtras,
      );
    });

    test('a host that throws something unexpected is unavailable too', () async {
      rig = await LocalRig.create(host: () => FakeEngineHost()..startError = StateError('boom'));
      final status = await rig.local.start();
      expect(status.state, LocalEngineState.unavailable);
      expect(status.reason, contains('StateError'));
    });
  });

  group('crash report', () {
    test('a crash during the last run is reported once in status and once to the next reply', () async {
      rig = await LocalRig.create();
      await rig.add(libraryModel('m1', defaultContext: 8192));
      // The previous process died while generating with m1.
      final forensics = EngineForensics(Directory('${rig.dir.path}/support/engine'));
      await forensics.enter(PhaseRecord(
        phase: InferencePhase.generating,
        at: DateTime.utc(2026, 10, 18),
        modelId: 'm1',
        modelName: 'Qwen3 0.6B',
        nCtx: 8192,
      ));
      await forensics.flush();

      final status = await rig.local.start();
      final report = status.crashReport;
      expect(report, isNotNull);
      expect(report!.description, contains('while generating a reply with Qwen3 0.6B (8192-token context)'));
      // The lifecycle's own downgrade for that model.
      expect(await rig.local.lifecycle!.downgradeFor('m1'), 4096);

      final first = await rig.local.provider.stream(request('m1', 'hi')).toList();
      final notices = first.whereType<ProviderNotice>().where((n) => n.code == kEngineCrashNoticeCode).toList();
      expect(notices.single.message, report.description);
      final second = await rig.local.provider.stream(request('m1', 'again')).toList();
      expect(second.whereType<ProviderNotice>().where((n) => n.code == kEngineCrashNoticeCode), isEmpty);

      // The banner stays until dismissed.
      expect(rig.local.status.crashReport, isNotNull);
      final seen = <LocalEngineStatus>[];
      final sub = rig.local.statusChanges.listen(seen.add);
      addTearDown(sub.cancel);
      rig.local.acknowledgeCrashReport();
      expect(rig.local.status.crashReport, isNull);
      await Future<void>.delayed(Duration.zero);
      expect(seen.last.crashReport, isNull);

      // A relaunch with nothing new reports nothing.
      await rig.local.dispose();
      final again = rig.newService();
      addTearDown(again.dispose);
      expect((await again.start()).crashReport, isNull);
    });

    test('a live engine crash while generating caps that model and shows a report', () async {
      rig = await LocalRig.create(host: () => FakeEngineHost(eventDelay: const Duration(milliseconds: 5)));
      await rig.add(libraryModel('m1', defaultContext: 8192));
      await rig.local.start();
      final host = rig.host..defaultScript = (_) => fakeReply('a long reply ' * 40);

      final events = rig.local.provider.stream(request('m1', 'hi'));
      final errors = <Object>[];
      final done = Completer<void>();
      var deltas = 0;
      final sub = events.listen((e) {
        if (e is TextDelta && ++deltas == 2) host.simulateCrash();
      }, onError: errors.add, onDone: done.complete);
      addTearDown(sub.cancel);
      await done.future;
      expect(errors.single, isA<ProviderException>().having((e) => e.kind, 'kind', ProviderErrorKind.engineCrashed));

      await until(() => rig.local.status.crashReport != null);
      expect(rig.local.contextCapFor('m1'), 4096);
      expect(rig.local.lifecycle!.spec('m1')!.preferredContext, 4096);
      expect(rig.local.status.crashReport!.description, contains('Qwen3 0.6B'));
      final stored = await rig.records.get(DocumentCollections.inference, 'sherpa.app.context_cap.m1');
      expect((stored!['value']! as Map)['maxContext'], 4096);

      // The next reply reloads at the capped context.
      expect(await replyText(rig.local.provider, 'm1', 'hi'), 'a long reply ' * 40);
      expect(host.sessionConfigs.last.nCtx, lessThanOrEqualTo(4096));

      // ...and so does the next launch.
      await rig.local.dispose();
      final again = rig.newService();
      addTearDown(again.dispose);
      await again.start();
      expect(again.lifecycle!.spec('m1')!.preferredContext, 4096);
    });
  });

  group('app lifecycle', () {
    test('pause and resume are forwarded to the lifecycle manager', () async {
      rig = await LocalRig.create(backgroundPolicy: BackgroundPolicy.pauseAndPersist, observeAppLifecycle: true);
      await rig.add(libraryModel('m1'));
      final local = rig.local..attachAppLifecycle();
      await local.start();
      expect(await replyText(local.provider, 'm1', 'hi'), 'ok');
      expect(local.loadedModelId, 'm1');

      final binding = TestWidgetsFlutterBinding.instance;
      for (final s in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
        binding.handleAppLifecycleStateChanged(s);
      }
      await until(() => local.lifecycle!.isPaused && local.loadedModelId == null);
      expect(local.isBackgrounded, isTrue);

      for (final s in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
        binding.handleAppLifecycleStateChanged(s);
      }
      expect(local.lifecycle!.isPaused, isFalse);
      expect(local.isBackgrounded, isFalse);
      // Reloads on first use after coming back.
      expect(await replyText(local.provider, 'm1', 'back'), 'ok');
    });

    test('going to the background while the engine starts applies once it is ready', () async {
      rig = await LocalRig.create(backgroundPolicy: BackgroundPolicy.pauseAndPersist);
      await rig.add(libraryModel('m1'));
      final starting = rig.local.start();
      await rig.local.onAppBackground();
      await starting;
      await until(() => rig.local.lifecycle!.isPaused);
      rig.local.onAppForeground();
      expect(rig.local.lifecycle!.isPaused, isFalse);
    });
  });

  group('autotune', () {
    test('runs once, in the background, after the first successful reply', () async {
      rig = await LocalRig.create(autotune: const AutotunePolicy(quietPeriod: Duration(milliseconds: 10)));
      await rig.add(libraryModel('m1'));
      await rig.local.start();
      final host = rig.host;
      expect(host.benches, isEmpty);

      expect(await replyText(rig.local.provider, 'm1', 'hi'), 'ok');
      await until(() => host.benches.isNotEmpty && !rig.local.autotune!.isRunning);
      final runs = host.benches.length;
      expect(await rig.local.lifecycle!.autotuner!.cached('m1'), isNotNull);

      expect(await replyText(rig.local.provider, 'm1', 'again'), 'ok');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(host.benches.length, runs, reason: 'a tuned model is not benched again');
    });

    test('never runs during a reply: a reply in the quiet period postpones it', () async {
      rig = await LocalRig.create(
        host: () => FakeEngineHost(eventDelay: const Duration(milliseconds: 8)),
        autotune: const AutotunePolicy(quietPeriod: Duration(milliseconds: 60)),
      );
      await rig.add(libraryModel('m1'));
      await rig.local.start();
      final host = rig.host;

      expect(await replyText(rig.local.provider, 'm1', 'hi'), 'ok');
      // The user's next message arrives within the quiet period; it is slow.
      host.defaultScript = (_) => fakeReply('x' * 120);
      var sawBenchDuringReply = false;
      final reply = rig.local.provider.stream(request('m1', 'next')).listen((_) {
        if (host.benches.isNotEmpty) sawBenchDuringReply = true;
      });
      await reply.asFuture<void>();
      await reply.cancel();
      expect(sawBenchDuringReply, isFalse);
      expect(host.benches, isEmpty);
      await until(() => host.benches.isNotEmpty, timeout: const Duration(seconds: 3));
    });

    test('backgrounding the app cancels a pending sweep', () async {
      rig = await LocalRig.create(autotune: const AutotunePolicy(quietPeriod: Duration(milliseconds: 40)));
      await rig.add(libraryModel('m1'));
      await rig.local.start();
      expect(await replyText(rig.local.provider, 'm1', 'hi'), 'ok');
      expect(rig.local.autotune!.pendingModel, 'm1');
      await rig.local.onAppBackground();
      expect(rig.local.autotune!.pendingModel, isNull);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(rig.host.benches, isEmpty);
    });
  });

  group('data', () {
    test('a deleted chat forgets its KV prefix; erase clears prefixes and engine notes', () async {
      rig = await LocalRig.create();
      await rig.add(libraryModel('m1'));
      await rig.local.start();
      final cache = rig.local.prefixCache;
      await cache.open();
      final host = rig.host;
      final model = await host.loadModel(const ModelLoadOptions(path: 'x'));
      final s = await host.createSession(model.ref, const SessionConfig(nCtx: 1024));
      host.sessionTokens[s.ref.id] = 600;
      PrefixCacheKey key(String id) => PrefixCacheKey(sessionId: id, modelId: 'sha256:fake', nCtx: 1024, kvLayout: 'f16/f16', loraSet: '');
      await cache.save(host, s.ref, key('chat-a'), const ['a']);
      await cache.save(host, s.ref, key('chat-b'), const ['b']);
      expect(cache.entries, hasLength(2));

      await rig.local.forgetConversation('chat-a');
      expect(cache.entries.map((e) => e.key.sessionId), ['chat-b']);

      await rig.records.put(DocumentCollections.inference, 'k', {'key': 'k', 'value': <String, Object?>{'a': 1}});
      await rig.local.eraseAll();
      expect(cache.entries, isEmpty);
      expect(await rig.records.list(DocumentCollections.inference), isEmpty);
    });
  });
}
