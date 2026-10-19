import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_inference/sherpa_inference.dart';
import 'package:sherpa_inference/testing.dart';

const _mib = 1024 * 1024;

ModelRequest _req(String text, {String? session, List<ToolDefinition> tools = const [], Role lastRole = Role.user}) =>
    ModelRequest(
      modelId: 'm',
      messages: [
        if (lastRole == Role.tool) ...[
          Message(id: 'u0', role: Role.user, content: const [TextPart('go')], createdAt: DateTime.utc(2026)),
          Message(
              id: 'a0',
              role: Role.assistant,
              content: const [ToolCallPart(ToolCall(id: 'c1', name: 't', arguments: {}))],
              createdAt: DateTime.utc(2026)),
          Message(
              id: 't0',
              role: Role.tool,
              content: const [ToolResultPart(callId: 'c1', toolName: 't', content: [TextPart('r')])],
              createdAt: DateTime.utc(2026)),
        ] else
          Message(id: 'u1', role: Role.user, content: [TextPart(text)], createdAt: DateTime.utc(2026)),
      ],
      tools: tools,
      cache: CacheHints(sessionId: session),
    );

void main() {
  late FakeEngineHost host;
  late ModelLifecycleManager lifecycle;
  late LlamaCppProvider provider;
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('provider_test');
    host = FakeEngineHost();
    lifecycle = ModelLifecycleManager(
      host: host,
      prefixCache: PrefixCacheStore(directory: Directory('${tmp.path}/kv')),
      minTokensToPersist: 1,
    )..register(const LocalModelSpec(id: 'm', path: '/m.gguf', preferredContext: 4096));
    provider = LlamaCppProvider(lifecycle: lifecycle);
  });

  tearDown(() async {
    await lifecycle.dispose();
    await tmp.delete(recursive: true);
  });

  test('info and capabilities', () async {
    expect(provider.info.kind, ProviderKind.localLlamaCpp);
    expect(provider.info.location, ExecutionLocation.onDevice);
    final caps = await provider.capabilities('m');
    expect(caps.contextLength, 4096);
    expect(caps.toolCallFormat, ToolCallFormat.jsonGrammar);
    final models = await provider.listModels();
    expect(models.single.capabilities.contextLength, 4096);
    expect(lifecycle.loaded!.leases, 0, reason: 'capabilities() releases its lease');
  });

  test('streams mapped events and exactly one Finish', () async {
    host.scripts.add((_) => fakeReply('Hello world', promptTokens: 40, cachedTokens: 10));
    final events = await provider.stream(_req('hi')).toList();
    expect(events.whereType<TextDelta>().map((d) => d.text).join(), 'Hello world');
    expect(events.whereType<UsageUpdate>().single.usage.cacheReadTokens, 10);
    expect(events.whereType<PerfSample>().single.promptTokens, 40);
    expect(events.whereType<Finish>().single.reason, FinishReason.stop);
    expect(events.last, isA<Finish>());
    final sent = jsonDecode(host.requests.single) as Map;
    expect(sent['cache_prompt'], isTrue);
    expect((sent['messages'] as List).single, {'role': 'user', 'content': 'hi'});
  });

  test('a tool call completes with parsed arguments', () async {
    host.scripts.add((_) => fakeReply('', toolCalls: [(id: 'c9', name: 'get_weather', args: '{"city":"Paris"}')]));
    final events = await provider.stream(_req('weather')).toList();
    final call = events.whereType<ToolCallComplete>().single.call;
    expect(call.id, 'c9');
    expect(call.arguments, {'city': 'Paris'});
    expect(events.whereType<Finish>().single.reason, FinishReason.toolCalls);
  });

  test('cancel token stops the engine and ends with Finish(cancelled)', () async {
    final slow = FakeEngineHost(eventDelay: const Duration(milliseconds: 5));
    final lc = ModelLifecycleManager(host: slow)..register(const LocalModelSpec(id: 'm', path: '/m.gguf'));
    final p = LlamaCppProvider(lifecycle: lc);
    slow.scripts.add((_) => fakeReply('x' * 400, chunk: 1));
    final token = CancellationToken();
    final events = <ModelEvent>[];
    final sw = Stopwatch();
    await for (final e in p.stream(_req('long'), cancel: token)) {
      events.add(e);
      if (e is TextDelta && events.whereType<TextDelta>().length == 3) {
        sw.start();
        token.cancel();
      }
    }
    expect(events.whereType<Finish>().single.reason, FinishReason.cancelled);
    expect(events.whereType<TextDelta>().length, lessThan(10));
    expect(slow.cancels, greaterThan(0));
    expect(sw.elapsedMilliseconds, lessThan(500));
    await lc.dispose();
  });

  test('cancelling the subscription releases the model for the next request', () async {
    final slow = FakeEngineHost(eventDelay: const Duration(milliseconds: 2));
    final lc = ModelLifecycleManager(host: slow)..register(const LocalModelSpec(id: 'm', path: '/m.gguf'));
    final p = LlamaCppProvider(lifecycle: lc);
    slow.scripts.add((_) => fakeReply('y' * 400, chunk: 1));
    final first = Completer<void>();
    final sub = p.stream(_req('long')).listen((e) {
      if (e is TextDelta && !first.isCompleted) first.complete();
    });
    await first.future;
    await sub.cancel();
    final next = await p.stream(_req('short')).toList();
    expect(next.whereType<Finish>().single.reason, FinishReason.stop);
    expect(lc.loaded!.leases, 0);
    await lc.dispose();
  });

  test('pausing the subscription pauses the engine; nothing is lost', () async {
    host.scripts.add((_) => fakeReply('abcdefghijklmnop', chunk: 2));
    final text = StringBuffer();
    final done = Completer<void>();
    late StreamSubscription<ModelEvent> sub;
    var paused = false;
    var requestsWhilePaused = -1;
    sub = provider.stream(_req('x')).listen((e) {
      if (e is TextDelta) {
        text.write(e.text);
        if (!paused) {
          paused = true;
          sub.pause(Future<void>.delayed(const Duration(milliseconds: 50), () => requestsWhilePaused = text.length));
        }
      }
    }, onDone: done.complete);
    await done.future;
    await sub.cancel();
    expect(text.toString(), 'abcdefghijklmnop');
    expect(requestsWhilePaused, 2, reason: 'no deltas were delivered while paused');
  });

  test('a generation interrupted by backgrounding finishes with pause and resumes later', () async {
    final slow = FakeEngineHost(eventDelay: const Duration(milliseconds: 5));
    final lc = ModelLifecycleManager(host: slow)..register(const LocalModelSpec(id: 'm', path: '/m.gguf'));
    final p = LlamaCppProvider(lifecycle: lc);
    slow.scripts.add((_) => fakeReply('z' * 200, chunk: 1));
    final events = <ModelEvent>[];
    await for (final e in p.stream(_req('long'))) {
      events.add(e);
      if (e is TextDelta && events.whereType<TextDelta>().length == 2) unawaited(lc.onAppBackground());
    }
    final finish = events.whereType<Finish>().single;
    expect(finish.reason, FinishReason.pause);
    expect(finish.rawReason, 'app_background');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(lc.loaded, isNull);
    // The continuation waits for the foreground, then reloads.
    final cont = p.stream(ModelRequest(modelId: 'm', messages: [
      Message(id: 'u', role: Role.user, content: const [TextPart('long')], createdAt: DateTime.utc(2026)),
      Message(id: 'a', role: Role.assistant, content: const [TextPart('zz')], createdAt: DateTime.utc(2026)),
    ])).toList();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(slow.loads, hasLength(1));
    lc.onAppForeground();
    expect((await cont).whereType<Finish>().single.reason, FinishReason.stop);
    expect(slow.loads, hasLength(2));
    expect((jsonDecode(slow.requests.last) as Map)['continue_final_message'], isTrue);
    await lc.dispose();
  });

  test('engine errors become ProviderException kinds', () async {
    host.scripts.add((_) => fakeError(-2, 'ggml buffer allocation failed'));
    await expectLater(provider.stream(_req('x')).toList(),
        throwsA(isA<ProviderException>().having((e) => e.kind, 'kind', ProviderErrorKind.outOfMemory)));
    host.scripts.add((_) => fakeError(-6, 'prompt does not fit'));
    await expectLater(provider.stream(_req('x')).toList(),
        throwsA(isA<ProviderException>().having((e) => e.kind, 'kind', ProviderErrorKind.contextOverflow)));
  });

  test('an engine crash mid-stream is engineCrashed', () async {
    final slow = FakeEngineHost(eventDelay: const Duration(milliseconds: 5));
    final lc = ModelLifecycleManager(host: slow)..register(const LocalModelSpec(id: 'm', path: '/m.gguf'));
    final p = LlamaCppProvider(lifecycle: lc);
    slow.scripts.add((_) => fakeReply('w' * 100, chunk: 1));
    final out = p.stream(_req('x')).listen((e) {
      if (e is TextDelta) slow.simulateCrash();
    });
    final err = Completer<Object>();
    out.onError(err.complete);
    final e = await err.future;
    expect(e, isA<ProviderException>().having((x) => x.kind, 'kind', ProviderErrorKind.engineCrashed));
    expect((e as ProviderException).isRetryable, isTrue);
    await out.cancel();
    // The lifecycle reloads under the new epoch.
    final next = await p.stream(_req('again')).toList();
    expect(next.whereType<Finish>(), hasLength(1));
    expect(slow.loads, hasLength(2));
    await lc.dispose();
  });

  test('admission refusal and engine unavailability are clear errors', () async {
    final tight = ModelLifecycleManager(
      host: host,
      memory: FakeMemoryMonitor(const MemoryState(pressure: MemoryPressure.normal, availableBytes: 100 * _mib)),
    )..register(const LocalModelSpec(id: 'm', path: '/m.gguf'));
    await expectLater(
        LlamaCppProvider(lifecycle: tight).stream(_req('x')).toList(),
        throwsA(isA<ProviderException>()
            .having((e) => e.kind, 'kind', ProviderErrorKind.outOfMemory)
            .having((e) => e.message, 'message', contains('Not enough memory'))));
    final broken = FakeEngineHost()..startError = const EngineUnavailableException('libsherpa_engine.so not found');
    final lc = ModelLifecycleManager(host: broken)..register(const LocalModelSpec(id: 'm', path: '/m.gguf'));
    await expectLater(
        LlamaCppProvider(lifecycle: lc).stream(_req('x')).toList(),
        throwsA(isA<ProviderException>()
            .having((e) => e.kind, 'kind', ProviderErrorKind.unsupported)
            .having((e) => e.message, 'message', contains('unavailable'))));
    await expectLater(provider.stream(const ModelRequest(modelId: 'nope', messages: [])).toList(),
        throwsA(isA<ProviderException>().having((e) => e.kind, 'kind', ProviderErrorKind.modelNotFound)));
  });

  test('foreground work preempts a background stream that has not produced output yet', () async {
    final slow = FakeEngineHost(eventDelay: const Duration(milliseconds: 10));
    final lc = ModelLifecycleManager(host: slow)..register(const LocalModelSpec(id: 'm', path: '/m.gguf'));
    final p = LlamaCppProvider(lifecycle: lc);
    // The background job's first attempt is cancelled during "prefill".
    slow.scripts
      ..add((_) => [
            const EngineEvent(type: EngineEventType.promptProgress, progressDone: 1, progressTotal: 9),
            ...fakeReply('summary'),
          ])
      ..add((_) => fakeReply('chat reply'))
      ..add((_) => fakeReply('summary'));
    final background = p.withPriority(InferencePriority.background).stream(_req('summarize')).toList();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final fg = await p.stream(_req('hello')).toList();
    expect(fg.whereType<TextDelta>().map((d) => d.text).join(), 'chat reply');
    final bg = await background;
    expect(bg.whereType<TextDelta>().map((d) => d.text).join(), 'summary');
    expect(bg.whereType<Finish>().single.reason, FinishReason.stop);
    expect(slow.requests, hasLength(3), reason: 'the background request was re-run after the chat');
    await lc.dispose();
  });

  test('switching models from capabilities() preempts background work', () async {
    final slow = FakeEngineHost(eventDelay: const Duration(milliseconds: 10));
    final lc = ModelLifecycleManager(host: slow)
      ..register(const LocalModelSpec(id: 'm', path: '/m.gguf'))
      ..register(const LocalModelSpec(id: 'n', path: '/n.gguf'));
    final p = LlamaCppProvider(lifecycle: lc);
    slow.scripts
      ..add((_) => [
            const EngineEvent(type: EngineEventType.promptProgress, progressDone: 1, progressTotal: 9),
            ...fakeReply('summary'),
          ])
      ..add((_) => fakeReply('summary again'));
    final background = p.withPriority(InferencePriority.background).stream(_req('summarize')).toList();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final sw = Stopwatch()..start();
    final caps = await p.capabilities('n');
    expect(caps.contextLength, 8192);
    expect(lc.loaded!.spec.id, 'n');
    expect(sw.elapsedMilliseconds, lessThan(500), reason: 'did not wait for the background reply');
    // The re-queued background request then runs (on its own model again).
    expect((await background).whereType<TextDelta>().map((d) => d.text).join(), 'summary again');
    await lc.dispose();
  });

  test('priority inference: tool results are follow-ups', () {
    expect(LlamaCppProvider.inferPriority(_req('x')), InferencePriority.foreground);
    expect(LlamaCppProvider.inferPriority(_req('x', lastRole: Role.tool)), InferencePriority.toolFollowUp);
  });

  test('conversation switches persist and restore the KV prefix', () async {
    host.scripts
      ..add((_) => fakeReply('one', promptTokens: 50))
      ..add((_) => fakeReply('two', promptTokens: 60))
      ..add((_) => fakeReply('three', promptTokens: 70));
    await provider.stream(_req('a', session: 'c1')).toList();
    await provider.stream(_req('b', session: 'c2')).toList();
    expect(host.saved, hasLength(1), reason: 'c1 was saved when c2 took the session');
    final back = await provider.stream(_req('a', session: 'c1')).toList();
    final notice = back.whereType<ProviderNotice>().where((n) => n.code == 'prefix_restored').single;
    expect(notice.data['tokens'], greaterThan(0));
    expect(host.loaded, hasLength(1));
  });

  test('exact prompt counting goes through the engine template', () async {
    final n = await provider.countPromptTokens(_req('count me'));
    expect(n, FakeEngineHost.fakeChatCount(jsonEncode({
      'messages': [
        {'role': 'user', 'content': 'count me'},
      ],
    })));
  });
}
