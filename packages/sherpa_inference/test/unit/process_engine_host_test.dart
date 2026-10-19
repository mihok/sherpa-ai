import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_inference/sherpa_inference.dart';
import 'package:sherpa_inference/testing.dart';

import '../support/fake_inference_service.dart';

const _model = ModelLoadOptions(path: '/models/qwen3.gguf', modelId: 'sha256:0123456789abcdef');
const _request = '{"messages":[{"role":"user","content":"hi"}]}';

String _text(List<EngineEvent> events) =>
    events.where((e) => e.type == EngineEventType.textDelta).map((e) => e.text).join();

void main() {
  late FakeInferenceService service;
  late ProcessEngineHost host;

  ProcessEngineHost newHost({
    String? breadcrumb,
    ProcessRestartPolicy restartPolicy = const ProcessRestartPolicy(initialDelay: Duration(milliseconds: 1)),
    Duration? idleUnbindAfter,
    Duration busyHold = const Duration(seconds: 2),
  }) =>
      ProcessEngineHost(
        transport: service,
        crashBreadcrumbPath: breadcrumb,
        backendDir: '/backends',
        restartPolicy: restartPolicy,
        idleUnbindAfter: idleUnbindAfter,
        busyHold: busyHold,
      );

  setUp(() {
    service = FakeInferenceService();
    host = newHost();
  });

  tearDown(() async {
    await host.dispose();
    await service.close();
  });

  Future<(EngineModel, EngineSession)> loaded() async {
    final m = await host.loadModel(_model);
    final s = await host.createSession(m.ref, const SessionConfig(nCtx: 4096));
    return (m, s);
  }

  group('start', () {
    test('binds, opens the engine in the service and is idempotent', () async {
      final info = await host.start();
      expect(info.hostKind, EngineHostKind.isolatedProcess);
      expect(info.abiVersion, 1);
      expect(info.libraryLocator, contains('pid ${service.pid}'));
      expect(await host.start(), same(info));
      expect(service.connects, [BindPolicy.adaptive]);
      final start = service.sent.whereType<StartCall>().single;
      expect(start.library, 'libsherpa_engine.so');
      expect(start.backendDir, '/backends');
      expect(host.kind, EngineHostKind.isolatedProcess);
      expect(host.pid, service.pid);
    });

    test('a missing engine library in the service is "engine unavailable"', () async {
      service.startError = SeStatus.unsupported;
      await expectLater(
          host.start(),
          throwsA(isA<EngineUnavailableException>()
              .having((e) => e.message, 'message', contains('dlopen'))
              .having((e) => e.cause, 'cause', isNull)));
    });

    test('a bind failure is "engine unavailable" with an EngineHostBindException cause', () async {
      service.bindFails = true;
      await expectLater(
          host.start(),
          throwsA(isA<EngineUnavailableException>()
              .having((e) => e.cause, 'cause', isA<EngineHostBindException>())));
    });
  });

  group('createDefaultEngineHost', () {
    test('Android with a bindable service: the process host', () async {
      final h = await createDefaultEngineHost(isAndroid: true, transport: service, ffiHost: FakeEngineHost.new);
      expect(h, isA<ProcessEngineHost>());
      await h.dispose();
    });

    test('Android without a service or plugin: falls back to the in-process host', () async {
      service.bindFails = true;
      final fallback = FakeEngineHost();
      expect(await createDefaultEngineHost(isAndroid: true, transport: service, ffiHost: () => fallback), same(fallback));
      service.bindFails = false;
      service.connectThrowsMissingPlugin = true;
      expect(await createDefaultEngineHost(isAndroid: true, transport: service, ffiHost: () => fallback), same(fallback));
    });

    test('elsewhere, or opted out: the in-process host', () async {
      expect(await createDefaultEngineHost(isAndroid: false, transport: service), isA<FfiEngineHost>());
      expect(await createDefaultEngineHost(isAndroid: true, useProcessHost: false, transport: service),
          isA<FfiEngineHost>());
      expect(service.connects, isEmpty);
    });
  });

  group('calls', () {
    test('handles carry the epoch; syncTokenizer is null; countBatch is one hop', () async {
      final (m, s) = await loaded();
      expect(m.ref.epoch, 0);
      expect(s.ref.epoch, 0);
      expect(m.infoJson, contains('qwen3'));
      expect(host.syncTokenizer(m.ref), isNull);
      final before = service.sent.length;
      expect(await host.countBatch(m.ref, texts: ['ab', 'abcd'], chatRequests: ['{}']), [2, 4, 2]);
      expect(service.sent.length - before, 1);
      expect(await host.tokenize(m.ref, 'abc'), [0, 1, 2]);
      expect(await host.detokenize(m.ref, [1, 2]), 'xx');
      expect(await host.countChatTokens(m.ref, '{"a":1}'), 7);
      expect(await host.saveState(s.ref, '/x.kv'), 1234);
      expect(await host.loadState(s.ref, '/x.kv'), 42);
      expect((await host.estimateMemory(_model, const SessionConfig(nCtx: 2048))).nCtx, 2048);
      expect((await host.sessionMemory(s.ref)).totalBytes, 10);
      expect((await host.bench(m.ref, const BenchConfig(nPrompt: 8, nGen: 2))).nPrompt, 8);
      final lora = await host.loadLora(m.ref, '/l.gguf');
      await host.setLoras(s.ref, [(lora, 0.5)]);
      expect(service.sent.whereType<SetLorasCall>().single.scales, [0.5]);
      await host.freeLora(lora);
    });

    test('model options and session config reach the service field for field', () async {
      await host.loadModel(const ModelLoadOptions(path: '/m.gguf', modelId: 'sha256:aa', nGpuLayers: 0,
          loadMode: LoadMode.mmap, vocabOnly: true, chatTemplateOverride: '{{x}}'));
      final o = service.sent.whereType<LoadModelCall>().single.options;
      expect((o.path, o.modelId, o.nGpuLayers, o.loadMode, o.vocabOnly, o.chatTemplateOverride),
          ('/m.gguf', 'sha256:aa', 0, 1, true, '{{x}}'));
      final m = (await host.loadModel(_model)).ref;
      await host.createSession(m, const SessionConfig(nCtx: 8192, typeK: KvType.q8_0, typeV: KvType.q8_0,
          flashAttention: FlashAttention.on, seed: 7, eventCapacity: 8));
      final c = service.sent.whereType<CreateSessionCall>().single.config;
      expect((c.nCtx, c.typeK, c.typeV, c.flashAttention, c.seed, c.eventCapacity), (8192, 8, 8, 1, 7, 8));
    });

    test('engine errors keep their status code', () async {
      final (m, s) = await loaded();
      await expectLater(host.loadModel(const ModelLoadOptions(path: '/missing.gguf')),
          throwsA(isA<EngineException>().having((e) => e.code, 'code', SeStatus.io)));
      await host.freeModel(m.ref);
      await expectLater(host.createSession(m.ref, const SessionConfig()),
          throwsA(isA<EngineException>().having((e) => e.code, 'code', SeStatus.invalidArg)));
      expect(s.ref.epoch, host.epoch);
    });

    test('calls keep their order across request/response and fire-and-forget messages', () async {
      final (_, s) = await loaded();
      service.sent.clear();
      unawaited(host.resetSession(s.ref));
      final events = host.generate(s.ref, _request).toList();
      unawaited(host.cancelGeneration(s.ref));
      await events;
      expect(service.sent.map((c) => c.runtimeType).take(3), [ResetSessionCall, GenerateCall, CancelSessionCall]);
    });

    test('load progress and a cancellation token reach the service', () async {
      final progress = <double>[];
      final token = CancellationToken();
      await host.loadModel(_model, cancel: token, onProgress: progress.add);
      expect(progress, [0.0, 0.5, 1.0]);
      final load = service.sent.whereType<LoadModelCall>().single;
      expect(load.progress, isTrue);
      expect(load.cancelId, isNot(0));
      expect(load.phaseTag, 'sha256:01234567');
      token.cancel();
      await pumpEventQueue();
      expect(service.sent.whereType<CancelCall>().single.cancelId, load.cancelId);
    });

    test('a token cancelled before the call is sent still cancels it', () async {
      final token = CancellationToken();
      final load = host.loadModel(_model, cancel: token); // not started: queued behind start()
      token.cancel();
      await load;
      final call = service.sent.whereType<LoadModelCall>().single;
      expect(service.sent.whereType<CancelCall>().single.cancelId, call.cancelId);
      await expectLater(host.loadModel(_model, cancel: token), throwsA(isA<CancelledException>()));
    });

    test('phase tags never contain the path', () {
      expect(ProcessEngineHost.phaseTagFor(const ModelLoadOptions(path: '/data/user/0/app/files/My Model.gguf')),
          matches(RegExp(r'^f[0-9a-f]{8}$')));
    });
  });

  group('generation', () {
    test('cold, ordered, exactly one FINISH preceded by USAGE and PERF', () async {
      final (_, s) = await loaded();
      final stream = host.generate(s.ref, _request);
      await pumpEventQueue();
      expect(service.sent.whereType<GenerateCall>(), isEmpty, reason: 'cold: nothing starts before listen');
      final events = await stream.toList();
      expect(_text(events), 'Hello world');
      expect(events.where((e) => e.isFinish), hasLength(1));
      expect(events.last.isFinish, isTrue);
      final types = events.map((e) => e.type).toList();
      expect(types.indexOf(EngineEventType.usage), lessThan(types.indexOf(EngineEventType.finish)));
      expect(types.indexOf(EngineEventType.perf), lessThan(types.indexOf(EngineEventType.finish)));
      expect(events.first.generationId, greaterThan(0));
    });

    test('a paused subscription withholds credits: at most 4 batches outstanding, nothing lost', () async {
      final deltas = [for (var i = 0; i < 40; i++) 't$i '];
      service.script = (_) => FakeInferenceService.reply(deltas);
      final (_, s) = await loaded();
      final received = <EngineEvent>[];
      final done = Completer<void>();
      late StreamSubscription<EngineEvent> sub;
      sub = host.generate(s.ref, _request).listen((e) {
        received.add(e);
        if (received.length == 1) sub.pause();
      }, onDone: done.complete);
      await pumpEventQueue();
      final gen = service.gens.values.single;
      // The first batch's credit went back before the listener paused (as in
      // FfiEngineHost); after that the paused stream returns none.
      final credited = gen.credited;
      expect(credited, lessThanOrEqualTo(1));
      expect(gen.sent - gen.credited, 4, reason: 'the service stops at 4 outstanding batches');
      expect(received, hasLength(1), reason: 'buffered events stay in the paused stream');
      await pumpEventQueue();
      expect(gen.credited, credited, reason: 'no credit while paused');
      expect(gen.sent - gen.credited, 4);
      sub.resume();
      await done.future;
      await sub.cancel();
      expect(_text(received), deltas.join());
      expect(service.maxOutstanding, lessThanOrEqualTo(4));
      expect(received.where((e) => e.isFinish), hasLength(1));
    });

    test('cancelling the subscription cancels the stream in the service; the session stays usable', () async {
      service.script = (_) => FakeInferenceService.reply([for (var i = 0; i < 50; i++) 'x']);
      final (_, s) = await loaded();
      late StreamSubscription<EngineEvent> sub;
      final first = Completer<void>();
      sub = host.generate(s.ref, _request).listen((_) {
        if (!first.isCompleted) first.complete();
      });
      await first.future;
      await sub.cancel();
      await pumpEventQueue();
      final gen = service.sent.whereType<GenerateCall>().single;
      expect(service.sent.whereType<CancelStreamCall>().single.streamId, gen.streamId);
      service.script = (_) => FakeInferenceService.reply(['ok']);
      expect(_text(await host.generate(s.ref, _request).toList()), 'ok');
    });

    test('cancelGeneration ends the stream with FINISH(cancelled)', () async {
      service.script = (_) => FakeInferenceService.reply([for (var i = 0; i < 50; i++) 'x']);
      final (_, s) = await loaded();
      final events = <EngineEvent>[];
      late StreamSubscription<EngineEvent> sub;
      final done = Completer<void>();
      sub = host.generate(s.ref, _request).listen((e) {
        events.add(e);
        if (events.length == 2) {
          sub.pause();
          unawaited(host.cancelGeneration(s.ref).then((_) => sub.resume()));
        }
      }, onDone: done.complete);
      await done.future;
      await sub.cancel();
      expect(events.last.isFinish, isTrue);
      expect(events.last.name, 'cancelled');
      expect(events.where((e) => e.isFinish), hasLength(1));
    });

    test('a refused start is a stream error', () async {
      final (_, s) = await loaded();
      await expectLater(host.generate(s.ref, 'busy').toList(),
          throwsA(isA<EngineException>().having((e) => e.code, 'code', SeStatus.busy)));
    });

    test('freeing a session fails its open stream', () async {
      service.script = (_) => FakeInferenceService.reply([for (var i = 0; i < 50; i++) 'x']);
      final (_, s) = await loaded();
      final errors = <Object>[];
      final done = Completer<void>();
      late StreamSubscription<EngineEvent> sub;
      var first = true;
      sub = host.generate(s.ref, _request).listen((_) {
        if (first) sub.pause();
        first = false;
      }, onError: errors.add, onDone: done.complete);
      await pumpEventQueue();
      await host.freeSession(s.ref);
      sub.resume();
      await done.future;
      await sub.cancel();
      expect(errors.single, isA<EngineException>().having((e) => e.code, 'code', SeStatus.invalidArg));
    });
  });

  group('crashes', () {
    test('pending calls and streams fail, the epoch bumps, the report is precise, the host restarts', () async {
      final dir = await Directory.systemTemp.createTemp('process_host');
      addTearDown(() => dir.delete(recursive: true));
      final breadcrumb = File('${dir.path}/engine_crash.txt')
        ..writeAsStringSync('ggml.c:1234: GGML_ASSERT(ne0 == ne1) failed\n');
      await host.dispose();
      host = newHost(breadcrumb: breadcrumb.path);
      final hostEvents = <EngineHostEvent>[];
      host.events.listen(hostEvents.add);
      final reports = <EngineProcessCrash>[];
      host.crashes.listen(reports.add);
      service.script = (_) => FakeInferenceService.reply([for (var i = 0; i < 50; i++) 'x']);
      final (m, s) = await loaded();
      final streamErrors = <Object>[];
      final streamDone = Completer<void>();
      late StreamSubscription<EngineEvent> sub;
      var first = true;
      sub = host.generate(s.ref, _request).listen((_) {
        if (first) sub.pause();
        first = false;
      }, onError: streamErrors.add, onDone: streamDone.complete);
      await pumpEventQueue();
      service.holdReplies = 1;
      final pending = host.sessionInfoJson(s.ref).then<Object?>((v) => v, onError: (Object e) => e);

      final restarted = host.events.firstWhere((e) => e is EngineHostRestarted);
      service.crash(
        summary: '{"v":1,"p":"generating","m":"sha256:01234567","c":4096,"k":"f16/f16","h":"proc"}',
        tombstone: 'signal 6 (SIGABRT)\nabort: ggml.c:1234: GGML_ASSERT(ne0 == ne1) failed\n#00 libc.so (abort+164) pc 0x4e8f0',
      );
      expect(await pending, isA<EngineCrashedException>());
      sub.resume();
      await streamDone.future;
      await sub.cancel();
      expect(streamErrors.single, isA<EngineCrashedException>());
      expect(host.epoch, 1);
      expect(() => host.tokenize(m.ref, 'x'), throwsA(isA<StaleHandleException>()));
      await expectLater(host.sessionInfoJson(s.ref), throwsA(isA<StaleHandleException>()));
      await expectLater(host.generate(s.ref, _request).toList(), throwsA(isA<StaleHandleException>()));

      await restarted;
      final crashed = hostEvents.whereType<EngineHostCrashed>().single;
      expect(crashed.nativeStateLost, isTrue);
      expect(crashed.epoch, 0);
      expect(crashed.reason, contains('native crash (SIGABRT)'));
      expect(crashed.reason, contains('while generating (4096-token context, KV f16/f16)'));
      expect(crashed.reason, contains('GGML_ASSERT(ne0 == ne1)'));
      expect(hostEvents.last, isA<EngineHostRestarted>().having((e) => e.epoch, 'epoch', 1));
      expect(hostEvents.indexOf(crashed), lessThan(hostEvents.length - 1), reason: 'crashed before restarted');

      final report = reports.single;
      expect(report.isNativeCrash, isTrue);
      expect(report.exit!.kind, EngineExitKind.nativeCrash);
      expect(report.phase!.phase, InferencePhase.generating);
      expect(report.phase!.nCtx, 4096);
      expect(report.exit!.tombstone, contains('#00 libc.so'));
      expect(report.engineMessage, contains('GGML_ASSERT'));
      expect(host.lastCrash, same(report));
      expect(breadcrumb.existsSync(), isFalse, reason: 'consumed: EngineForensics will not report it again');

      // A fresh incarnation serves new handles.
      final (m2, s2) = await loaded();
      expect(m2.ref.epoch, 1);
      expect(_text(await host.generate(s2.ref, _request).toList()), hasLength(50));
      expect(service.connects, hasLength(2));
    });

    test('a memory kill without a phase reads as such; no exit record still reports', () async {
      final reasons = <String>[];
      host.events.listen((e) {
        if (e is EngineHostCrashed) reasons.add(e.reason);
      });
      await loaded();
      final restarted = host.events.firstWhere((e) => e is EngineHostRestarted);
      service.crash(classification: 'likelyLowMemory', reason: 2, status: 9);
      await restarted;
      expect(reasons.single, 'The on-device engine process killed by the system to free memory');
      final again = host.events.firstWhere((e) => e is EngineHostRestarted);
      service.crash(classification: null);
      await again;
      expect(reasons.last, contains('died (no exit record)'));
      expect(host.lastCrash!.isMemoryKill, isFalse);
    });

    test('calls without handles issued during the restart wait for it', () async {
      await loaded();
      service.crash();
      await pumpEventQueue();
      expect(host.epoch, 1, reason: 'the death was processed');
      final m = await host.loadModel(_model);
      expect(m.ref.epoch, 1);
      expect(service.connects, hasLength(2));
    });

    test('restarts back off and a crash loop gives up until retry()', () {
      fakeAsync((async) {
        final policy = const ProcessRestartPolicy(
          initialDelay: Duration(milliseconds: 100),
          maxCrashes: 4,
          window: Duration(minutes: 5),
        );
        final h = newHost(restartPolicy: policy);
        final events = <EngineHostEvent>[];
        h.events.listen(events.add);
        h.start();
        async.flushMicrotasks();
        expect(service.connects, hasLength(1));
        final connectTimes = <Duration>[];
        service.crashOnStart = 100; // every restart dies while starting
        service.crash();
        for (var i = 0; i < 20; i++) {
          final before = service.connects.length;
          async.elapse(const Duration(milliseconds: 50));
          if (service.connects.length > before) connectTimes.add(async.elapsed);
        }
        // Delays 100, 200, 400 ms between the crash reports and the reconnects.
        expect(connectTimes, hasLength(3));
        final gaps = [for (var i = 1; i < connectTimes.length; i++) connectTimes[i] - connectTimes[i - 1]];
        expect(gaps[1], greaterThan(gaps[0]));
        async.elapse(const Duration(seconds: 30));
        expect(service.connects, hasLength(4), reason: 'no restart after the crash loop limit');
        final crashes = events.whereType<EngineHostCrashed>().toList();
        expect(crashes, hasLength(4));
        expect(crashes.last.reason, contains('keeps crashing'));
        expect(h.terminalReason, isNotNull);
        Object? error;
        h.loadModel(_model).catchError((Object e) {
          error = e;
          return EngineModel(ref: const ModelRef(0, 0), infoJson: '', options: _model);
        });
        async.flushMicrotasks();
        expect(error, isA<EngineUnavailableException>().having((e) => e.message, 'message', contains('keeps crashing')));
        // The user retries: back in business.
        service.crashOnStart = 0;
        EngineInfo? info;
        h.retry().then((i) => info = i);
        async.flushMicrotasks();
        expect(info, isNotNull);
        expect(events.last, isA<EngineHostRestarted>());
        h.dispose();
        async.flushMicrotasks();
      });
    });

    test('a process that stayed up resets the backoff', () {
      fakeAsync((async) {
        var now = DateTime(2026);
        final h = ProcessEngineHost(
          transport: service,
          restartPolicy: const ProcessRestartPolicy(initialDelay: Duration(seconds: 1), stableAfter: Duration(minutes: 1)),
          now: () => now,
        );
        h.start();
        async.flushMicrotasks();
        for (var round = 0; round < 3; round++) {
          final before = service.connects.length;
          service.crash();
          async.flushMicrotasks();
          async.elapse(const Duration(milliseconds: 999));
          expect(service.connects.length, before, reason: 'round $round: not before the initial delay');
          async.elapse(const Duration(milliseconds: 2));
          expect(service.connects.length, before + 1, reason: 'round $round: initial delay again');
          now = now.add(const Duration(minutes: 2));
        }
        h.dispose();
        async.flushMicrotasks();
      });
    });
  });

  group('importance and idle', () {
    test('busy while work is in flight, released after busyHold; idle unbind without handles', () {
      fakeAsync((async) {
        final h = newHost(idleUnbindAfter: const Duration(seconds: 60), busyHold: const Duration(seconds: 2));
        h.start();
        async.flushMicrotasks();
        expect(service.busyCalls.first, (1, true), reason: 'the start call itself is work');
        async.elapse(const Duration(seconds: 3));
        expect(service.busyCalls.last, (1, false));
        expect(h.debugBusy, isFalse);
        // A loaded model keeps the binding (but not the busy one).
        EngineModel? m;
        h.loadModel(_model).then((v) => m = v);
        async.flushMicrotasks();
        async.elapse(const Duration(minutes: 5));
        expect(service.disconnects, isEmpty);
        h.freeModel(m!.ref);
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 61));
        expect(service.disconnects, [1], reason: 'no handles for 60 s: unbind');
        // The next call reconnects transparently, same epoch.
        String? info;
        h.systemInfoJson().then((v) => info = v);
        async.flushMicrotasks();
        expect(info, contains('CPU'));
        expect(service.connects, hasLength(2));
        expect(h.epoch, 0);
        h.dispose();
        async.flushMicrotasks();
      });
    });
  });

  test('dispose fails what is in flight and unbinds', () async {
    final (_, s) = await loaded();
    service.holdReplies = 1;
    final pending = host.sessionInfoJson(s.ref).then<Object?>((v) => v, onError: (Object e) => e);
    await pumpEventQueue();
    await host.dispose();
    expect(await pending, isA<EngineCrashedException>());
    expect(service.disconnects, [1]);
  });

  test('the lifecycle manager reloads after a process crash', () async {
    final lifecycle = ModelLifecycleManager(host: host, backgroundPolicy: BackgroundPolicy.none)
      ..register(const LocalModelSpec(id: 'q', path: '/models/qwen3.gguf', preferredContext: 4096));
    final lease = await lifecycle.acquire('q');
    expect(lease.model.epoch, 0);
    lease.release();
    final restarted = host.events.firstWhere((e) => e is EngineHostRestarted);
    service.crash(classification: 'memoryLimiter', reason: 13, status: 0);
    await restarted;
    final again = await lifecycle.acquire('q');
    expect(again.model.epoch, 1);
    expect(again.loaded.sessionInfo.nCtx, 4096);
    again.release();
    await lifecycle.dispose();
  });
}
