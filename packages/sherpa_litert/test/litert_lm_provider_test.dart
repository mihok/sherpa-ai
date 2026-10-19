import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_litert/sherpa_litert.dart';
import 'package:sherpa_litert/testing.dart';

import 'support.dart';

const _path = '/data/models/gemma-4-E2B-it.litertlm';

void main() {
  late FakeLiteRtBackend backend;
  late FakeForeground fg;
  late LiteRtLmProvider provider;

  LiteRtLmProvider make({ModelInfoMsg? model, LiteRtModelSpec? spec, Duration grace = const Duration(seconds: 2)}) {
    backend.models[_path] = model ?? FakeLiteRtBackend.modelInfo();
    return LiteRtLmProvider(
      backend: backend,
      foreground: fg,
      models: [spec ?? const LiteRtModelSpec(id: 'gemma', path: _path, displayName: 'Gemma 4 E2B')],
      cancelGrace: grace,
    );
  }

  setUp(() {
    backend = FakeLiteRtBackend();
    fg = FakeForeground();
    provider = make();
  });

  tearDown(() async {
    await provider.dispose();
    await backend.dispose();
    await fg.dispose();
  });

  void script(FakeScript s) => backend.scripts.add(s);

  test('info and capabilities are honest', () async {
    expect(provider.info.kind, ProviderKind.localLiteRt);
    expect(provider.info.location, ExecutionLocation.onDevice);
    expect(provider.info.dataLeavesDevice, isFalse);
    final caps = await provider.capabilities('gemma');
    expect(caps.contextLength, kDefaultLiteRtContext);
    expect(caps.toolCallFormat, ToolCallFormat.native);
    expect(caps.historyPolicy, HistoryPolicy.appendOnly);
    expect(caps.supportsPromptCache, isTrue);
    expect(caps.vision, isFalse);
    expect(caps.tokenizerFamily, 'gemma');
    expect(caps.reasoning, ReasoningSupport.none);

    final prompted = make(
      model: FakeLiteRtBackend.modelInfo(functionCalling: false, thinking: true, vision: true, maxContext: 4096),
      spec: const LiteRtModelSpec(id: 'gemma', path: _path, vision: true, contextLength: 32768),
    );
    final p = await prompted.capabilities('gemma');
    expect(p.toolCallFormat, ToolCallFormat.prompted);
    expect(p.contextLength, 4096, reason: 'capped by the model');
    expect(p.vision, isTrue);
    expect(p.reasoning, ReasoningSupport.optional);
    await prompted.dispose();

    expect(() => provider.capabilities('nope'), throwsA(isA<ProviderException>()));
  });

  test('streams text, usage and perf, then Finish(stop); loads once with GPU first', () async {
    script((s) {
      s.text('Hel');
      s.text('lo!');
      s.done(GenerationStatsMsg(
        prefillTokens: 12,
        decodeTokens: 3,
        timeToFirstTokenMs: 210,
        prefillTokensPerSec: 900,
        decodeTokensPerSec: 40,
        kvTokensBefore: 0,
        kvTokensAfter: 15,
        backend: 'gpu',
      ));
    });
    final r = await collect(provider.stream(request([user('Hi')])));
    expect(r.error, isNull);
    expect(textOf(r.events), 'Hello!');
    final usage = r.events.whereType<UsageUpdate>().single.usage;
    expect([usage.inputTokens, usage.outputTokens, usage.cacheReadTokens], [12, 3, 0]);
    final perf = r.events.whereType<PerfSample>().single;
    expect(perf.timeToFirstTokenMs, 210);
    expect(perf.backend, 'gpu');
    expect(finishOf(r.events)!.reason, FinishReason.stop);
    expect(r.events.whereType<Finish>(), hasLength(1));
    expect(r.events.whereType<ProviderNotice>().map((n) => n.code), contains('engine_loaded'));

    expect(backend.trimPolicies, [40]);
    expect(backend.releases, ['attach']);
    expect(backend.loads.single.backends, ['gpu', 'cpu']);
    expect(backend.loads.single.maxNumTokens, kDefaultLiteRtContext);
    expect(backend.loads.single.cacheDir, '/data/user/0/app/cache');
    expect(backend.opened.single.history, isEmpty);
    expect(backend.opened.single.systemInstruction, 'You are Sherpa.');
    expect(backend.sends.single.message.text, 'Hi');
    expect(backend.totalCredits, greaterThan(0), reason: 'each delivered batch is credited back');
  });

  test('native tool calls: start, arguments, complete with fresh ids; Finish(toolCalls)', () async {
    script((s) {
      s.toolCalls([
        ToolCallMsg(name: 'get_weather', argumentsJson: '{"city":"Oslo"}'),
        ToolCallMsg(name: 'search', argumentsJson: '{"q":"news","n":3}'),
      ]);
      s.done();
    });
    final r = await collect(provider.stream(request([user('Weather?')], tools: [weatherTool, searchTool])));
    final calls = callsOf(r.events);
    expect(calls.map((c) => c.name), ['get_weather', 'search']);
    expect(calls[1].arguments, {'q': 'news', 'n': 3});
    expect(calls.every((c) => c.id.startsWith('call_')), isTrue);
    expect(calls.map((c) => c.id).toSet(), hasLength(2));
    expect(calls.every((c) => !c.repaired), isTrue);
    expect(r.events.whereType<ToolCallStart>().map((e) => e.index), [0, 1]);
    expect(finishOf(r.events)!.reason, FinishReason.toolCalls);
    expect(backend.opened.single.toolsJson, hasLength(2));
  });

  test('prompted tool calls are parsed from text when the file has no function calling', () async {
    final p = make(model: FakeLiteRtBackend.modelInfo(functionCalling: false));
    script((s) {
      s.text('{"tool_calls": [{"name": "get_weather", ');
      s.text('"arguments": {"city": "Rome"}}]}');
      s.done();
    });
    final r = await collect(p.stream(request([user('Weather in Rome?')], tools: [weatherTool])));
    expect(textOf(r.events), isEmpty);
    expect(callsOf(r.events).single.arguments, {'city': 'Rome'});
    expect(finishOf(r.events)!.reason, FinishReason.toolCalls);
    expect(backend.opened.single.toolsJson, isEmpty);
    expect(backend.opened.single.systemInstruction, contains('"tool_calls"'));
    await p.dispose();
  });

  test('the load-time template probe decides native vs prompted tools, over the metadata flag', () async {
    // Qwen3-0.6B on the host: metadata says no function calling, the template renders tools.
    backend.templateRendersTools = true;
    final qwen = make(model: FakeLiteRtBackend.modelInfo(functionCalling: false));
    expect((await qwen.capabilities('gemma')).toolCallFormat, ToolCallFormat.prompted, reason: 'before the first load');
    await collect(qwen.stream(request([user('Weather?')], tools: [weatherTool])));
    expect(backend.opened.last.toolsJson, hasLength(1));
    expect(backend.opened.last.systemInstruction, isNot(contains('## Tools')));
    expect((await qwen.capabilities('gemma')).toolCallFormat, ToolCallFormat.native);
    await qwen.release();
    await qwen.dispose();

    // SmolLM2: the template drops tools, so they go into the prompt.
    backend.templateRendersTools = false;
    final smol = make(model: FakeLiteRtBackend.modelInfo(functionCalling: true));
    await collect(smol.stream(request([user('Weather?')], tools: [weatherTool])));
    expect(backend.opened.last.toolsJson, isEmpty);
    expect(backend.opened.last.systemInstruction, contains('## Tools'));
    expect((await smol.capabilities('gemma')).toolCallFormat, ToolCallFormat.prompted);
    await smol.dispose();
  });

  test('history policy: appended turns reuse the conversation, an edit rebuilds it', () async {
    script((s) {
      s.text('Hello!');
      s.done(GenerationStatsMsg(prefillTokens: 10, decodeTokens: 2, kvTokensBefore: 0));
    });
    final u1 = user('Hi');
    final r1 = await collect(provider.stream(request([u1])));
    final a1 = replyFrom(r1.events);

    script((s) {
      s.text('Fine.');
      s.done(GenerationStatsMsg(prefillTokens: 6, decodeTokens: 2, kvTokensBefore: 12));
    });
    final r2 = await collect(provider.stream(request([u1, a1, user('How are you?')])));
    expect(backend.opened, hasLength(1), reason: 'reused: no new conversation');
    expect(backend.sends.last.message.text, 'How are you?');
    expect(backend.sends.last.conversationId, backend.sends.first.conversationId);
    final usage = r2.events.whereType<UsageUpdate>().single.usage;
    expect(usage.cacheReadTokens, 12, reason: 'KV tokens the conversation already held');
    expect(usage.inputTokens, 6);

    // Edit-and-resubmit of the first message (a sibling branch).
    script((s) {
      s.text('Hey.');
      s.done();
    });
    final r3 = await collect(provider.stream(request([user('Hi there'), a1, user('How are you?')])));
    expect(r3.error, isNull);
    expect(backend.opened, hasLength(2));
    expect(backend.opened.last.history.map((m) => m.text), ['Hi there', 'Hello!']);
    expect(backend.sends.last.message.text, 'How are you?');
    final notice = r3.events.whereType<ProviderNotice>().firstWhere((n) => n.code == 'conversation_rebuilt');
    expect(notice.data['reason'], 'historyDiverged');
  });

  test('a tool loop reuses the conversation: tool results go in as the tail', () async {
    script((s) {
      s.toolCalls([ToolCallMsg(name: 'get_weather', argumentsJson: '{"city":"Oslo"}')]);
      s.done();
    });
    final u1 = user('Weather?');
    final r1 = await collect(provider.stream(request([u1], tools: [weatherTool])));
    final a1 = replyFrom(r1.events);
    final callId = callsOf(r1.events).single.id;

    script((s) {
      s.text('Sunny in Oslo.');
      s.done();
    });
    await collect(provider.stream(request([u1, a1, toolResults([result(callId, 'get_weather', 'Sunny, 21C')])],
        tools: [weatherTool])));
    expect(backend.opened, hasLength(1));
    final tail = backend.sends.last.message;
    expect(tail.role, 'tool');
    expect(tail.toolResponses!.single.name, 'get_weather');
    expect(tail.toolResponses!.single.responseJson, '"Sunny, 21C"');
  });

  test('cancel through the token stops at the next token and ends with Finish(cancelled)', () async {
    final token = CancellationToken();
    script((s) async {
      s.text('Once upon');
      await settle();
      token.cancel();
      // Kotlin answers the cancel (FakeLiteRtBackend.answerCancel).
    });
    final r = await collect(provider.stream(request([user('Story')]), cancel: token));
    expect(r.error, isNull);
    expect(textOf(r.events), 'Once upon');
    expect(finishOf(r.events)!.reason, FinishReason.cancelled);
    expect(backend.cancels.single.reason, 'user');

    // The native conversation state is unknown after a cancel: rebuild.
    script((s) {
      s.text('ok');
      s.done();
    });
    await collect(provider.stream(request([user('Story'), assistant('Once upon'), user('Again')])));
    expect(backend.opened, hasLength(2));
  });

  test('cancelling the subscription cancels the native turn', () async {
    final started = Completer<void>();
    script((s) {
      s.text('a');
      started.complete();
    });
    final sub = provider.stream(request([user('x')])).listen((_) {});
    await started.future;
    await settle();
    await sub.cancel();
    await settle();
    expect(backend.cancels.single.reason, 'user');
  });

  test('an engine that never answers a cancel still ends after the grace period', () async {
    final p = make(grace: const Duration(milliseconds: 50));
    backend.answerCancel = false;
    final token = CancellationToken();
    script((s) async {
      s.text('…');
      await settle();
      token.cancel();
    });
    final r = await collect(p.stream(request([user('x')]), cancel: token));
    expect(finishOf(r.events)!.reason, FinishReason.cancelled);
    await p.dispose();
  });

  test('memory pressure: the turn pauses at a token boundary, the engine is freed and reloads in the foreground',
      () async {
    script((s) async {
      s.text('Partial');
      await settle();
      fg.foreground = false;
      backend.trimRelease(streamId: s.id);
    });
    final r = await collect(provider.stream(request([user('Long answer please')])));
    expect(r.error, isNull);
    final finish = finishOf(r.events)!;
    expect(finish.reason, FinishReason.pause);
    expect(finish.rawReason, 'memory_pressure');
    expect(provider.loadedBackend, isNull);

    // The agent loop continues the paused reply: it waits for the foreground.
    script((s) {
      s.text(' answer.');
      s.done();
    });
    final next = collect(provider.stream(request([user('Long answer please'), assistant('Partial', finishReason: 'pause')])));
    await settle(10);
    expect(backend.loads, hasLength(1), reason: 'no reload in the background');
    fg.foreground = true;
    final r2 = await next;
    expect(r2.error, isNull);
    expect(backend.loads, hasLength(2));
    expect(r2.events.whereType<ProviderNotice>().map((n) => n.code), containsAll(['waiting_for_foreground', 'continue_prompted']));
    expect(backend.sends.last.message.text, kContinueNudge);
    expect(textOf(r2.events), ' answer.');
  });

  test('a cancel nobody asked for (a stuck native conversation) is a retryable error and rebuilds', () async {
    script((s) => s.cancelledWith('cancelled'));
    final r = await collect(provider.stream(request([user('x')])));
    final e = r.error! as ProviderException;
    expect(e.kind, ProviderErrorKind.engineCrashed);
    expect(e.isRetryable, isTrue);
    script((s) => s.done());
    await collect(provider.stream(request([user('x')])));
    expect(backend.opened, hasLength(2));
  });

  test('a memory-pressure pause is enough to reload, even before the engineReleased event', () async {
    script((s) async {
      s.text('Partial');
      await settle();
      // Only the terminal event: the global release has not arrived yet.
      s.cancelledWith('memory_pressure');
    });
    final r = await collect(provider.stream(request([user('x')])));
    expect(finishOf(r.events)!.reason, FinishReason.pause);
    expect(provider.loadedBackend, isNull);
    script((s) => s.done());
    await collect(provider.stream(request([user('x'), assistant('Partial', finishReason: 'pause')])));
    expect(backend.loads, hasLength(1), reason: 'the fake still holds the engine, so the reload is reused');
    expect(backend.opened, hasLength(2), reason: 'the conversation is rebuilt, not reused');
  });

  test('a conversation the engine lost is a retryable error', () async {
    backend.failNext['openConversation'] =
        PlatformException(code: 'litert_status', message: 'no model is loaded', details: [9]);
    final r = await collect(provider.stream(request([user('x')])));
    final e = r.error! as ProviderException;
    expect(e.kind, ProviderErrorKind.engineCrashed);
    expect(e.isRetryable, isTrue);
    expect(provider.loadedBackend, isNull);
  });

  test('length finish when the output budget was used up', () async {
    script((s) {
      s.text('a b c d');
      s.done(GenerationStatsMsg(decodeTokens: 4, prefillTokens: 3));
    });
    final r = await collect(provider.stream(request([user('x')], params: const GenerationParams(maxOutputTokens: 4))));
    expect(finishOf(r.events)!.reason, FinishReason.length);
    expect(backend.sends.single.maxOutputTokens, 4);
  });

  group('errors map to ProviderException kinds', () {
    Future<ProviderException> failWith(ErrorMsg e) async {
      script((s) => s.error(e));
      final r = await collect(provider.stream(request([user('x')])));
      return r.error! as ProviderException;
    }

    test('RESOURCE_EXHAUSTED is outOfMemory', () async {
      final e = await failWith(ErrorMsg(source: 'litert', code: 8, message: 'Failed to allocate KV cache'));
      expect(e.kind, ProviderErrorKind.outOfMemory);
    });

    test('a too-long prompt is contextOverflow', () async {
      final e = await failWith(ErrorMsg(source: 'litert', code: 3, message: 'Input token ids are too long'));
      expect(e.kind, ProviderErrorKind.contextOverflow);
    });

    test('INTERNAL is engineCrashed (retryable)', () async {
      final e = await failWith(ErrorMsg(source: 'litert', code: 13, message: 'decode failed'));
      expect(e.kind, ProviderErrorKind.engineCrashed);
      expect(e.isRetryable, isTrue);
    });

    test('a load where every backend failed is reported with the attempts', () async {
      backend.onLoad = (_) => throw PlatformException(
            code: 'load_failed',
            message: 'no backend could load the model',
            details: [8, ['gpu: OpenCL not found', 'cpu: out of memory']],
          );
      final r = await collect(provider.stream(request([user('x')])));
      final e = r.error! as ProviderException;
      expect(e.kind, ProviderErrorKind.outOfMemory);
      expect(e.message, contains('gpu: OpenCL not found'));
    });

    test('an unknown model is modelNotFound', () async {
      final r = await collect(provider.stream(request([user('x')], modelId: 'missing')));
      expect((r.error! as ProviderException).kind, ProviderErrorKind.modelNotFound);
    });

    test('a failed turn invalidates the conversation', () async {
      await failWith(ErrorMsg(source: 'litert', code: 13, message: 'boom'));
      script((s) => s.done());
      await collect(provider.stream(request([user('x')])));
      expect(backend.opened, hasLength(2));
    });
  });

  test('a backend fallback is reported', () async {
    backend.onLoad = (r) => LoadResultMsg(backend: 'cpu', failures: const ['gpu: no OpenCL'], initMs: 4000, reused: false);
    final r = await collect(provider.stream(request([user('x')])));
    final n = r.events.whereType<ProviderNotice>().firstWhere((n) => n.code == 'backend_fallback');
    expect(n.data['backend'], 'cpu');
    expect(provider.loadedBackend, 'cpu');
  });

  test('pausing the subscription stops crediting; resuming pays what is owed', () async {
    final paused = Completer<void>();
    final release = Completer<void>();
    script((s) async {
      await paused.future;
      for (var i = 0; i < 6; i++) {
        s.text('t$i ');
      }
      await release.future;
      s.done();
    });
    final events = <ModelEvent>[];
    final sub = provider.stream(request([user('x')])).listen(events.add);
    while (backend.sends.isEmpty) {
      await settle();
    }
    sub.pause();
    paused.complete();
    await settle(10);
    final streamId = backend.sends.single.streamId;
    final whilePaused = backend.credits.where((c) => c.streamId == streamId).fold(0, (a, c) => a + c.batches);
    expect(whilePaused, 0, reason: 'batches delivered to a paused listener are owed, not credited');
    sub.resume();
    await settle(10);
    final after = backend.credits.where((c) => c.streamId == streamId).fold(0, (a, c) => a + c.batches);
    expect(after, 6);
    release.complete();
    await settle(10);
    expect(textOf(events), 't0 t1 t2 t3 t4 t5 ');
    await sub.cancel();
  });

  test('turns run one at a time', () async {
    final gate = Completer<void>();
    script((s) async {
      s.text('first');
      await gate.future;
      s.done();
    });
    script((s) => s.done());
    final a = collect(provider.stream(request([user('a')], session: 'A')));
    final b = collect(provider.stream(request([user('b')], session: 'B')));
    await settle(10);
    expect(backend.sends, hasLength(1));
    gate.complete();
    await a;
    await b;
    expect(backend.sends, hasLength(2));
    expect(backend.closed, hasLength(1), reason: 'one live conversation: the other chat is evicted');
  });

  group('availability', () {
    test('available with the backend plan', () async {
      final a = await provider.availability(_path);
      expect(a.state, AvailabilityState.available);
      expect(a.details['backends'], ['gpu', 'cpu']);
      expect(a.reason, contains('GPU'));
    });

    test('NPU file for this SoC goes first; for another SoC it is unsupported', () async {
      backend.models['/m/npu.litertlm'] =
          FakeLiteRtBackend.modelInfo(backends: const ['npu'], npuBrand: 'google_tensor', socName: 'Tensor_G5');
      final ok = await provider.availability('/m/npu.litertlm');
      expect(ok.details['backends'], ['npu']);
      backend.platform = FakeLiteRtBackend.androidPlatform(socModel: 'SM8750');
      final p2 = make();
      final wrong = await p2.availability('/m/npu.litertlm');
      expect(wrong.code, 'wrong_soc');
      await p2.dispose();
    });

    test('missing file, wrong format, not an LLM, too-new file, missing runtime', () async {
      expect((await provider.availability('/m/none.litertlm')).code, 'file_missing');
      expect((await provider.availability('/m/model.task')).code, 'unsupported_format');
      backend.models['/m/emb.litertlm'] = FakeLiteRtBackend.modelInfo(modelType: 'embedding');
      expect((await provider.availability('/m/emb.litertlm')).code, 'not_an_llm');
      backend.models['/m/new.litertlm'] = FakeLiteRtBackend.modelInfo(minRuntimeVersion: '0.21.0');
      expect((await provider.availability('/m/new.litertlm')).code, 'runtime_too_old');
      backend.platform = FakeLiteRtBackend.androidPlatform(liteRtAvailable: false);
      final p2 = make();
      expect((await p2.availability(_path)).code, 'runtime_missing');
      await p2.dispose();
    });
  });

  test('release frees the engine; the next turn reloads', () async {
    await collect(provider.stream(request([user('x')])));
    await provider.release();
    expect(backend.releases.last, 'app');
    await collect(provider.stream(request([user('y')])));
    expect(backend.loads, hasLength(2));
  });
}
