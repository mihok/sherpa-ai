// Real engine: the host-built shared libsherpa_engine.so + a Qwen3-0.6B GGUF.
// Skips cleanly when either is missing (test/support/engine_env.dart).
@Tags(['engine'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_inference/sherpa_inference.dart';

import '../support/engine_env.dart';

const _modelId = 'qwen3-0.6b';
const _timeout = Timeout(Duration(minutes: 4));

final class _PerfRow {
  _PerfRow(this.scenario, this.sample);
  final String scenario;
  final PerfSample sample;
}

final _perf = <_PerfRow>[];
int? _cancelLatencyMs;

/// Read-only weather tool for the round-trip test.
final class WeatherTool implements LocalTool {
  final List<Map<String, Object?>> calls = [];

  @override
  ToolDefinition get definition => const ToolDefinition(
        name: 'get_weather',
        description: 'Get the current weather for a city',
        inputSchema: {
          'type': 'object',
          'properties': {
            'city': {'type': 'string', 'description': 'City name'},
          },
          'required': ['city'],
        },
        annotations: ToolAnnotations(readOnlyHint: true, openWorldHint: false),
      );

  @override
  Future<ToolResult> run(Map<String, Object?> arguments, ToolExecutionContext context) async {
    calls.add(arguments);
    return ToolResult.text(jsonEncode({'city': arguments['city'], 'temp_c': 21, 'sky': 'clear'}));
  }
}

LocalModelSpec _spec(String path, {int preferredContext = 4096}) => LocalModelSpec(
      id: _modelId,
      path: path,
      displayName: 'Qwen3 0.6B',
      preferredContext: preferredContext,
      minContext: 1024,
      sessionDefaults: SessionConfig(nThreads: testThreads, nThreadsBatch: testThreads, seed: 42),
    );

const _params = GenerationParams(
  temperature: 0,
  seed: 42,
  maxOutputTokens: 48,
  reasoning: ReasoningEffort.off,
);

final class _Harness {
  _Harness(this.host, this.lifecycle, this.provider);

  final FfiEngineHost host;
  final ModelLifecycleManager lifecycle;
  final LlamaCppProvider provider;
  final store = InMemorySessionStore();
  final clock = FakeClock();

  AgentRunner runner({List<LocalTool> tools = const [], GenerationParams params = _params}) => AgentRunner(
        store: store,
        provider: provider,
        modelId: _modelId,
        tools: LocalToolRouter(tools),
        approvals: ApprovalPolicy(clock: clock),
        approvalHandler: const StaticApprovalHandler.approveAll(),
        contextManager: const WarmingContextManager(PassthroughContextManager()),
        counter: provider.tokenCounter(_modelId),
        clock: clock,
        ids: SequentialIdGenerator(),
        config: AgentConfig(params: params, defaultSystemPrompt: 'You are a concise assistant.'),
        sleep: (_) async {},
      );

  Future<void> newSession(String id) => store.putSession(SessionRecord(
        id: id,
        title: defaultSessionTitle,
        createdAt: clock.now(),
        updatedAt: clock.now(),
      ));
}

void main() {
  final skip = engineSkipReason();
  late _Harness h;
  late Directory tmp;

  setUpAll(() async {
    if (skip != null) return;
    tmp = await Directory.systemTemp.createTemp('sherpa_inference_it');
    final forensics = EngineForensics(Directory('${tmp.path}/forensics'));
    final host = FfiEngineHost(libraryPath: engineLibraryPath(), crashBreadcrumbPath: forensics.engineBreadcrumbPath);
    final lifecycle = ModelLifecycleManager(
      host: host,
      forensics: forensics,
      prefixCache: PrefixCacheStore(directory: Directory('${tmp.path}/kv')),
      backgroundPolicy: BackgroundPolicy.pauseAndPersist,
      minTokensToPersist: 16,
    )..register(_spec(testModelPath()!));
    await lifecycle.start();
    h = _Harness(host, lifecycle, LlamaCppProvider(lifecycle: lifecycle));
  });

  tearDownAll(() async {
    if (skip != null) return;
    await h.lifecycle.dispose();
    await h.host.dispose();
    await tmp.delete(recursive: true);
    if (_perf.isNotEmpty) {
      final b = StringBuffer()
        ..writeln()
        ..writeln('sherpa_inference perf (host, $testThreads threads, ${File(testModelPath()!).uri.pathSegments.last})')
        ..writeln('| scenario | prompt | cached | TTFT ms | prefill t/s | decode t/s |')
        ..writeln('|---|---:|---:|---:|---:|---:|');
      for (final r in _perf) {
        final s = r.sample;
        b.writeln('| ${r.scenario} | ${s.promptTokens} | ${s.cachedPromptTokens} | '
            '${s.timeToFirstTokenMs?.toStringAsFixed(0)} | ${s.prefillTokensPerSec?.toStringAsFixed(1)} | '
            '${s.decodeTokensPerSec?.toStringAsFixed(1)} |');
      }
      if (_cancelLatencyMs != null) b.writeln('cancel → Finish(cancelled): $_cancelLatencyMs ms');
      // ignore: avoid_print
      print(b);
    }
  });

  List<PerfSample> perfOf(List<AgentEvent> events) =>
      [for (final e in events) if (e is ModelStreamed && e.event is PerfSample) e.event as PerfSample];

  List<Usage> usageOf(List<AgentEvent> events) =>
      [for (final e in events) if (e is ModelStreamed && e.event is UsageUpdate) (e.event as UsageUpdate).usage];

  test('capabilities come from the loaded model and session', () async {
    final caps = await h.provider.capabilities(_modelId);
    expect(caps.contextLength, 4096);
    expect(caps.toolCallFormat, ToolCallFormat.jsonGrammar);
    expect(caps.reasoning, ReasoningSupport.optional);
    expect(caps.parallelToolCalls, isFalse, reason: 'models under 8B keep parallel tool calls off');
    expect(caps.historyPolicy, HistoryPolicy.appendOnly);
    expect(caps.tokenizerFamily, 'qwen');
    expect(caps.quantization, contains('Q4_K'));
    expect(caps.ramEstimateBytes, greaterThan(300 * 1024 * 1024));
    expect(h.provider.info.location, ExecutionLocation.onDevice);
    expect(h.provider.info.dataLeavesDevice, isFalse);
  }, skip: skip, timeout: _timeout);

  test('streams a plain reply through AgentRunner', () async {
    await h.newSession('plain');
    final events = await h.runner().send('plain', [const TextPart('Say hello in five words.')]).toList();
    final finished = events.whereType<RunFinished>().single;
    expect(finished.outcome, RunOutcome.completed, reason: '${finished.error}');
    final reply = events.whereType<AssistantMessageCompleted>().single.message;
    expect(reply.text.trim(), isNotEmpty);
    expect(reply.finishReason, anyOf('stop', 'length'));
    expect(events.whereType<ModelStreamed>().where((e) => e.event is TextDelta), isNotEmpty);
    final perf = perfOf(events).single;
    expect(perf.timeToFirstTokenMs, greaterThan(0));
    _perf.add(_PerfRow('plain reply (cold)', perf));
  }, skip: skip, timeout: _timeout);

  test('a second turn reuses the KV prefix (cached tokens > 0)', () async {
    await h.newSession('prefix');
    final runner = h.runner();
    await runner.send('prefix', [const TextPart('My name is Ada. Reply with one word.')]).toList();
    final events = await runner.send('prefix', [const TextPart('What is my name? One word.')]).toList();
    expect(events.whereType<RunFinished>().single.outcome, RunOutcome.completed);
    final usage = usageOf(events).single;
    expect(usage.cacheReadTokens, greaterThan(0));
    expect(usage.inputTokens, lessThan(usage.cacheReadTokens), reason: 'only the new turn is prefilled');
    _perf.add(_PerfRow('turn 2, prefix cache', perfOf(events).single));
  }, skip: skip, timeout: _timeout);

  test('tool call round trip through AgentRunner with a LocalTool', () async {
    await h.newSession('tools');
    final tool = WeatherTool();
    final events = await h
        .runner(tools: [tool], params: _params.copyWith(maxOutputTokens: 96))
        .send('tools', [const TextPart("What's the weather in Paris right now? Use the tool.")]).toList();
    final finished = events.whereType<RunFinished>().single;
    expect(finished.outcome, RunOutcome.completed, reason: '${finished.error}');
    expect(tool.calls, hasLength(1));
    expect('${tool.calls.single['city']}', contains('Paris'));
    final streamed = [for (final e in events) if (e is ModelStreamed) e.event];
    expect(streamed.whereType<ToolCallStart>().single.name, 'get_weather');
    expect(streamed.whereType<ToolCallArgsDelta>(), isNotEmpty);
    final complete = streamed.whereType<ToolCallComplete>().single;
    expect(complete.call.isValid, isTrue);
    expect(complete.call.repaired, isFalse);
    final finishes = streamed.whereType<Finish>().map((f) => f.reason).toList();
    expect(finishes.first, FinishReason.toolCalls);
    expect(finishes.last, anyOf(FinishReason.stop, FinishReason.length));
    final path = await h.store.path('tools', (await h.store.getSession('tools'))!.activeLeafId!);
    expect(path.map((m) => m.role), [Role.user, Role.assistant, Role.tool, Role.assistant]);
    expect(path.last.text.trim(), isNotEmpty);
    final perf = perfOf(events);
    _perf
      ..add(_PerfRow('tool call (with tool schema)', perf.first))
      ..add(_PerfRow('after tool result', perf.last));
    expect(usageOf(events).last.cacheReadTokens, greaterThan(0), reason: 'the follow-up reuses the first step');
  }, skip: skip, timeout: _timeout);

  test('exact token counts equal USAGE prompt tokens', () async {
    final request = ModelRequest(
      modelId: _modelId,
      systemPrompt: 'You are terse.',
      messages: [
        Message(id: 'u1', role: Role.user, content: const [TextPart('Count to three.')], createdAt: DateTime.utc(2026)),
      ],
      tools: [WeatherTool().definition],
      params: _params.copyWith(maxOutputTokens: 4),
    );
    final exact = await h.provider.countPromptTokens(request);
    final events = await h.provider.stream(request).toList();
    final usage = events.whereType<UsageUpdate>().single.usage;
    expect(usage.inputTokens + usage.cacheReadTokens, exact);

    // The synchronous per-part counts (what the context manager sums) after
    // an off-isolate warm-up: never below the real prompt, and close to it.
    final counter = h.provider.tokenCounter(_modelId);
    await counter.warm(systemPrompt: request.systemPrompt, messages: request.messages, tools: request.tools);
    final misses = counter.misses;
    final sum = counter.countText(request.systemPrompt!) +
        counter.countTools(request.tools) +
        request.messages.map(counter.countMessage).fold(0, (a, b) => a + b);
    expect(counter.misses, misses, reason: 'warm() filled every entry');
    expect(counter.isExact, isTrue);
    expect(sum, greaterThanOrEqualTo(exact));
    expect(sum - exact, lessThanOrEqualTo(12));
  }, skip: skip, timeout: _timeout);

  test('cancel mid-generation returns promptly and frees the session', () async {
    final token = CancellationToken();
    final request = ModelRequest(
      modelId: _modelId,
      messages: [
        Message(
            id: 'u1',
            role: Role.user,
            content: const [TextPart('Write a long story about a lighthouse keeper.')],
            createdAt: DateTime.utc(2026)),
      ],
      params: _params.copyWith(maxOutputTokens: 400),
    );
    final events = <ModelEvent>[];
    final sw = Stopwatch();
    var deltas = 0;
    await for (final e in h.provider.stream(request, cancel: token)) {
      events.add(e);
      if (e is TextDelta && ++deltas == 3) {
        sw.start();
        token.cancel('test');
      }
    }
    sw.stop();
    _cancelLatencyMs = sw.elapsedMilliseconds;
    expect(events.last, isA<Finish>().having((f) => f.reason, 'reason', FinishReason.cancelled));
    expect(events.whereType<Finish>(), hasLength(1));
    expect(sw.elapsedMilliseconds, lessThan(1500), reason: 'se_cancel is observed between tokens');
    // The session is usable right away.
    final next = await h.provider.stream(request.copyWithParams(_params.copyWith(maxOutputTokens: 4))).toList();
    expect(next.whereType<Finish>().single.reason, anyOf(FinishReason.stop, FinishReason.length));
  }, skip: skip, timeout: _timeout);

  test('cancelling the subscription stops the engine', () async {
    final request = ModelRequest(
      modelId: _modelId,
      messages: [
        Message(id: 'u1', role: Role.user, content: const [TextPart('List twenty animals.')], createdAt: DateTime.utc(2026)),
      ],
      params: _params.copyWith(maxOutputTokens: 300),
    );
    final first = Completer<void>();
    final sub = h.provider.stream(request).listen((e) {
      if (e is TextDelta && !first.isCompleted) first.complete();
    });
    await first.future;
    final sw = Stopwatch()..start();
    await sub.cancel();
    final next = await h.provider.stream(request.copyWithParams(_params.copyWith(maxOutputTokens: 4))).toList();
    expect(next.whereType<Finish>().single.reason, anyOf(FinishReason.stop, FinishReason.length));
    expect(sw.elapsedMilliseconds, lessThan(8000));
  }, skip: skip, timeout: _timeout);

  test('a paused subscription applies backpressure without losing events', () async {
    final request = ModelRequest(
      modelId: _modelId,
      messages: [
        Message(
            id: 'u1', role: Role.user, content: const [TextPart('Name five colours.')], createdAt: DateTime.utc(2026)),
      ],
      params: _params.copyWith(maxOutputTokens: 40),
    );
    final reference = (await h.provider.stream(request).toList()).whereType<TextDelta>().map((d) => d.text).join();
    final text = StringBuffer();
    final done = Completer<void>();
    late StreamSubscription<ModelEvent> sub;
    var paused = false;
    sub = h.provider.stream(request).listen((e) {
      if (e is TextDelta) {
        text.write(e.text);
        if (!paused) {
          paused = true;
          sub.pause(Future<void>.delayed(const Duration(milliseconds: 1500)));
        }
      }
    }, onDone: done.complete);
    await done.future;
    await sub.cancel();
    expect(text.toString(), reference, reason: 'greedy decoding: same text, nothing dropped');
  }, skip: skip, timeout: _timeout);

  test('engine backpressure: a paused consumer blocks decoding (8-slot event ring)', () async {
    final lease = await h.lifecycle.acquire(_modelId);
    try {
      final s = await h.host.createSession(lease.model, SessionConfig(nCtx: 512, nThreads: testThreads, eventCapacity: 8, seed: 1));
      final body = jsonEncode({
        'messages': [
          {'role': 'user', 'content': 'Write the numbers from 1 to 40 separated by commas.'},
        ],
        'max_tokens': 40,
        'temperature': 0,
        'enable_thinking': false,
      });
      final reference = (await h.host.generate(s.ref, body).toList());
      await h.host.resetSession(s.ref);
      const pause = Duration(seconds: 3);
      final events = <EngineEvent>[];
      final done = Completer<void>();
      late StreamSubscription<EngineEvent> sub;
      sub = h.host.generate(s.ref, body).listen((e) {
        events.add(e);
        if (e.type == EngineEventType.textDelta && events.where((x) => x.type == EngineEventType.textDelta).length == 1) {
          sub.pause(Future<void>.delayed(pause));
        }
      }, onDone: done.complete);
      await done.future;
      await sub.cancel();
      String text(List<EngineEvent> ev) =>
          ev.where((e) => e.type == EngineEventType.textDelta).map((e) => e.text).join();
      expect(text(events), text(reference), reason: 'no event was dropped');
      final usage = events.firstWhere((e) => e.type == EngineEventType.usage);
      expect(usage.completionTokens, reference.firstWhere((e) => e.type == EngineEventType.usage).completionTokens);
      expect(usage.completionTokens, greaterThanOrEqualTo(30), reason: 'long enough to fill the ring');
      final perf = events.firstWhere((e) => e.type == EngineEventType.perf);
      final refPerf = reference.firstWhere((e) => e.type == EngineEventType.perf);
      // The engine's own decode clock includes the time its worker sat
      // blocked on the full ring.
      expect(perf.decodeMs, greaterThan(refPerf.decodeMs + pause.inMilliseconds * 0.5));
      await h.host.freeSession(s.ref);
    } finally {
      lease.release();
    }
  }, skip: skip, timeout: _timeout);

  test('state save → unload → reload restores the prefix from disk', () async {
    await h.newSession('persist');
    final runner = h.runner();
    await runner.send('persist', [const TextPart('Remember the number 7. Reply OK.')]).toList();
    final saved = h.lifecycle.events.firstWhere((e) => e is PrefixSavedEvent);
    await h.lifecycle.unload(reason: 'test');
    expect((await saved) as PrefixSavedEvent, isA<PrefixSavedEvent>().having((e) => e.bytes, 'bytes', greaterThan(0)));
    expect(h.lifecycle.loaded, isNull);
    final restored = h.lifecycle.events.firstWhere((e) => e is PrefixRestoredEvent);
    final events = await runner.send('persist', [const TextPart('Which number? One word.')]).toList();
    final r = (await restored) as PrefixRestoredEvent;
    expect(r.outcome, PrefixRestoreOutcome.restored);
    expect(r.tokens, greaterThan(0));
    final usage = usageOf(events).single;
    expect(usage.cacheReadTokens, greaterThan(0));
    _perf.add(_PerfRow('after reload, restored KV', perfOf(events).single));
  }, skip: skip, timeout: _timeout);

  test('host-level state save → new session → load restores the cache', () async {
    final lease = await h.lifecycle.acquire(_modelId);
    final path = '${tmp.path}/direct.kv';
    final body = jsonEncode({
      'messages': [
        {'role': 'user', 'content': 'The capital of France is'},
      ],
      'max_tokens': 2,
      'temperature': 0,
      'enable_thinking': false,
    });
    try {
      final model = lease.model;
      final s1 = await h.host.createSession(model, SessionConfig(nCtx: 1024, nThreads: testThreads, seed: 1));
      await h.host.generate(s1.ref, body).toList();
      final bytes = await h.host.saveState(s1.ref, path);
      expect(bytes, greaterThan(0));
      await h.host.freeSession(s1.ref);
      final s2 = await h.host.createSession(model, SessionConfig(nCtx: 1024, nThreads: testThreads, seed: 1));
      final n = await h.host.loadState(s2.ref, path);
      expect(n, greaterThan(0));
      final events = await h.host.generate(s2.ref, body).toList();
      final usage = events.firstWhere((e) => e.type == EngineEventType.usage);
      expect(usage.cachedTokens, greaterThan(0));
      // A session with another KV layout refuses the file.
      final s3 = await h.host.createSession(model, SessionConfig(nCtx: 1024, nThreads: testThreads, typeK: KvType.q8_0, typeV: KvType.q8_0));
      await expectLater(h.host.loadState(s3.ref, path),
          throwsA(isA<EngineException>().having((e) => e.code, 'code', -12)));
      await h.host.freeSession(s2.ref);
      await h.host.freeSession(s3.ref);
    } finally {
      lease.release();
    }
  }, skip: skip, timeout: _timeout);

  test('admission uses the memory estimate: shrinks the context or refuses', () async {
    final path = testModelPath()!;
    final opts = ModelLoadOptions(path: path);
    final base = SessionConfig(nThreads: testThreads);
    final big = await h.host.estimateMemory(opts, base.copyWith(nCtx: 8192, typeK: KvType.q8_0, typeV: KvType.q8_0));
    final small = await h.host.estimateMemory(opts, base.copyWith(nCtx: 2048, typeK: KvType.q8_0, typeV: KvType.q8_0));
    expect(big.totalBytes, greaterThan(small.totalBytes));
    expect(big.kvBytesPerToken, greaterThan(0));
    const policy = AdmissionPolicy(fitFraction: 1, safetyMarginBytes: 0);
    // Room for ~3k tokens of q8_0 KV but not 8k of any type.
    final available = small.totalBytes + 1200 * big.kvBytesPerToken;
    final memory = FakeMemoryMonitor(MemoryState(pressure: MemoryPressure.normal, availableBytes: available, source: 'test'));
    final lifecycle = ModelLifecycleManager(host: h.host, memory: memory, policy: policy)
      ..register(_spec(path, preferredContext: 8192));
    await lifecycle.start();
    final plan = await lifecycle.plan(_modelId);
    expect(plan.admitted, isTrue, reason: plan.refusal);
    expect(plan.config!.nCtx, inInclusiveRange(2048, 4096));
    expect(plan.config!.typeK, KvType.q8_0, reason: 'f16 at that context does not fit');
    expect(plan.estimate!.totalBytes, lessThanOrEqualTo(plan.budget.totalBytes!));
    expect(plan.notes.join(' '), contains('context reduced'));

    memory.emit(const MemoryState(pressure: MemoryPressure.normal, availableBytes: 200 * 1024 * 1024, source: 'test'));
    final refused = await lifecycle.plan(_modelId);
    expect(refused.admitted, isFalse);
    expect(refused.refusal, contains('Not enough memory'));
    await expectLater(lifecycle.acquire(_modelId), throwsA(isA<AdmissionRefusedException>()));
    await lifecycle.dispose();
    await memory.dispose();
  }, skip: skip, timeout: _timeout);

  test('autotune runs a tiny sweep, persists it and reuses it', () async {
    final info = await h.host.start();
    final system = EngineSystemInfo.parse(await h.host.systemInfoJson());
    expect(system.performanceCores, greaterThan(0));
    expect(system.backends, contains('CPU'));
    final store = InMemoryKeyValueStore();
    final tuner = Autotuner(
      host: h.host,
      store: store,
      environment: AutotuneEnvironment(
        deviceId: 'host',
        osVersion: Platform.operatingSystemVersion,
        appVersion: 'test',
        engineVersion: info.version,
        performanceCores: 2,
      ),
      sweep: const AutotuneSweep(
        threads: [1, 2],
        batchSizes: [64],
        kvVariants: [(KvType.f16, FlashAttention.auto), (KvType.q8_0, FlashAttention.on)],
        nPrompt: 32,
        nGen: 8,
        nReps: 1,
      ),
    );
    final lease = await h.lifecycle.acquire(_modelId);
    try {
      var benches = 0;
      final profile = await tuner.profileFor(model: lease.model, modelKey: _modelId, onSample: (_, _) => benches++);
      expect(profile.source, AutotuneSource.measured);
      expect(benches, greaterThanOrEqualTo(3));
      expect(profile.samples.every((s) => s.genTokensPerSec > 0 && s.promptTokensPerSec > 0), isTrue);
      expect([1, 2], contains(profile.candidate.nThreads));
      final again = await tuner.profileFor(model: lease.model, modelKey: _modelId, onSample: (_, _) => benches++);
      expect(again.candidate, profile.candidate);
      expect(benches, lessThanOrEqualTo(4), reason: 'the second call is served from the store');
      await tuner.setOverrides(_modelId, const AutotuneOverrides(nThreads: 1));
      expect((await tuner.cached(_modelId))!.candidate.nThreads, 1);
    } finally {
      lease.release();
    }
  }, skip: skip, timeout: _timeout);

  test('a draft model chosen by an override is loaded and drafts; lifecycle autotune reports progress', () async {
    // One model at a time: the harness's warm model goes first.
    await h.lifecycle.unload(reason: 'draft test');
    final info = await h.host.start();
    final store = InMemoryKeyValueStore();
    final records = <PhaseRecord>[];
    final lc = ModelLifecycleManager(
      host: h.host,
      store: store,
      backgroundPolicy: BackgroundPolicy.none,
      onPhase: records.add,
      autotuner: Autotuner(
        host: h.host,
        store: store,
        environment: AutotuneEnvironment(
          deviceId: 'host',
          osVersion: Platform.operatingSystemVersion,
          appVersion: 'test',
          engineVersion: info.version,
          performanceCores: 2,
        ),
        sweep: const AutotuneSweep(threads: [1, 2], batchSizes: [64], kvVariants: [(KvType.q8_0, FlashAttention.on)], nPrompt: 16, nGen: 4, nReps: 1),
      ),
    )
      ..register(_spec(testModelPath()!, preferredContext: 2048))
      // The same file registered as a second model: same vocabulary, so it
      // can draft for the first.
      ..register(LocalModelSpec(id: 'qwen3-draft', path: testModelPath()!, preferredContext: 2048, minContext: 1024));
    try {
      await lc.start();
      await lc.autotuner!.setOverrides(_modelId, const AutotuneOverrides(speculative: SpeculativeMode.draft, draftModelId: 'qwen3-draft'));
      final plan = await lc.plan(_modelId);
      expect(plan.admitted, isTrue, reason: plan.refusal);
      expect(plan.config!.speculative, SpeculativeMode.draft);
      final lease = await lc.acquire(_modelId);
      try {
        expect(lease.loaded.loadOptions.draftModelPath, testModelPath());
        expect(lease.loaded.config.speculative, SpeculativeMode.draft);
        final items = [for (var i = 1; i <= 12; i++) '$i. Parcel $i goes to dock ${i % 4 + 1}.'];
        final request = jsonEncode({
          'messages': [
            {'role': 'user', 'content': 'Copy this list exactly, with no other text:\n${items.join('\n')}'},
          ],
          'max_tokens': 48,
          'temperature': 0,
          'seed': 42,
          'enable_thinking': false,
          'cache_prompt': false,
        });
        final events = await h.host.generate(lease.session, request).toList();
        expect(events.where((e) => e.type == EngineEventType.error), isEmpty);
        final perf = events.lastWhere((e) => e.type == EngineEventType.perf);
        expect(perf.nDrafted, greaterThan(0), reason: 'the draft model proposed tokens');
        expect(perf.nAccepted, greaterThan(0), reason: 'a copy of itself agrees with the model');
      } finally {
        lease.release();
      }

      final progress = <AutotuneProgress>[];
      final profile = await lc.autotune(_modelId, force: true, onProgress: progress.add);
      expect(profile!.source, AutotuneSource.override);
      expect(profile.candidate.speculative, SpeculativeMode.draft, reason: 'the override survives the sweep');
      expect(progress.first.done, 0);
      expect(progress.last.done, lc.autotuner!.sweepSize);
      expect(progress.where((p) => p.step == AutotuneStep.measured), isNotEmpty);
      expect(records.map((r) => r.phase), contains(InferencePhase.benchmarking));
      expect(records.last.phase, InferencePhase.idle);
    } finally {
      await lc.dispose();
    }
  }, skip: skip, timeout: _timeout);

  test('a KV prefix saved with a draft model loads without one and back (the state identity has no draft)', () async {
    await h.lifecycle.unload(reason: 'draft state test');
    final path = testModelPath()!;
    final drafting = await h.host.loadModel(ModelLoadOptions(path: path, draftModelPath: path));
    final plain = await h.host.loadModel(ModelLoadOptions(path: path));
    final config = SessionConfig(nCtx: 1024, nThreads: testThreads, nThreadsBatch: testThreads, seed: 1);
    final a = await h.host.createSession(drafting.ref, config.copyWith(speculative: SpeculativeMode.draft));
    final b = await h.host.createSession(plain.ref, config);
    final body = {
      'messages': [
        {'role': 'user', 'content': 'List the days of the week, one per line.'},
      ],
      'max_tokens': 12,
      'temperature': 0,
      'enable_thinking': false,
    };
    int cached(List<EngineEvent> events) => events.firstWhere((e) => e.type == EngineEventType.usage).cachedTokens;
    try {
      final first = await h.host.generate(a.ref, jsonEncode(body)).toList();
      expect(first.where((e) => e.type == EngineEventType.error), isEmpty);
      final fromDraft = '${tmp.path}/drafting.kv';
      expect(await h.host.saveState(a.ref, fromDraft), greaterThan(0));
      expect(await h.host.loadState(b.ref, fromDraft), greaterThan(0), reason: 'no mismatch without the draft');
      expect(cached(await h.host.generate(b.ref, jsonEncode(body)).toList()), greaterThan(0));

      final fromPlain = '${tmp.path}/plain.kv';
      expect(await h.host.saveState(b.ref, fromPlain), greaterThan(0));
      expect(await h.host.loadState(a.ref, fromPlain), greaterThan(0), reason: 'nor with one');
      // The draft context has no KV of its own after a load, so a drafted
      // reply re-prefills (the engine keeps target and draft in lockstep);
      // without speculation the restored target KV is reused as is.
      final back = await h.host.generate(a.ref, jsonEncode({...body, 'speculative': false})).toList();
      expect(cached(back), greaterThan(0));
    } finally {
      await h.host.freeSession(a.ref);
      await h.host.freeSession(b.ref);
      await h.host.freeModel(drafting.ref);
      await h.host.freeModel(plain.ref);
    }
  }, skip: skip, timeout: _timeout);

  test('a dead worker isolate surfaces as engineCrashed and the host restarts', () async {
    final lease = await h.lifecycle.acquire(_modelId);
    try {
      // Attach the handler now: the call fails as soon as the worker dies.
      final pending = h.host
          .estimateMemory(ModelLoadOptions(path: testModelPath()!), const SessionConfig(nCtx: 2048))
          .then<Object?>((v) => v, onError: (Object e) => e);
      final crashed = h.host.events.firstWhere((e) => e is EngineHostCrashed);
      final restarted = h.host.events.firstWhere((e) => e is EngineHostRestarted);
      h.host.debugKillWorker();
      await crashed;
      final outcome = await pending;
      if (outcome is EngineCrashedException) {
        expect(providerErrorFor(outcome, providerId: 'x').kind, ProviderErrorKind.engineCrashed);
      } else {
        expect(outcome, isA<MemoryEstimate>(), reason: 'the call finished before the kill');
      }
      await restarted;
      // Native handles survive a Dart isolate restart.
      final n = await h.host.countChatTokens(lease.model, jsonEncode({
        'messages': [
          {'role': 'user', 'content': 'hi'},
        ],
      }));
      expect(n, greaterThan(0));
    } finally {
      lease.release();
    }
  }, skip: skip, timeout: _timeout);
}

extension on ModelRequest {
  ModelRequest copyWithParams(GenerationParams params) => ModelRequest(
        modelId: modelId,
        messages: messages,
        systemPrompt: systemPrompt,
        tools: tools,
        params: params,
        cache: cache,
      );
}
