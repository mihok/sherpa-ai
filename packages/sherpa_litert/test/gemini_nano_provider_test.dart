import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_litert/sherpa_litert.dart';
import 'package:sherpa_litert/testing.dart';

import 'support.dart';

void main() {
  late FakeLiteRtBackend backend;
  late FakeForeground fg;
  late GeminiNanoProvider provider;

  GeminiNanoProvider make({GeminiNanoOptions options = const GeminiNanoOptions()}) =>
      GeminiNanoProvider(backend: backend, foreground: fg, options: options, cancelGrace: const Duration(milliseconds: 200));

  setUp(() {
    backend = FakeLiteRtBackend();
    fg = FakeForeground();
    provider = make();
  });

  tearDown(() async {
    await backend.dispose();
    await fg.dispose();
  });

  void script(FakeScript s) => backend.scripts.add(s);
  ModelRequest nanoRequest(List<Message> m, {List<ToolDefinition> tools = const [], GenerationParams? params}) =>
      request(m, modelId: GeminiNanoProvider.modelId, tools: tools, params: params ?? const GenerationParams());

  group('status', () {
    Future<ProviderAvailability> statusFor(NanoStatusMsg s) {
      backend.nano = s;
      return provider.status();
    }

    test('maps FeatureStatus', () async {
      final ok = await statusFor(NanoStatusMsg(featureStatus: 3, baseModelName: 'nano-v3', tokenLimit: 4000));
      expect(ok.state, AvailabilityState.available);
      expect(ok.reason, contains('nano-v3'));
      expect(ok.details['tokenLimit'], 4000);
      expect((await statusFor(NanoStatusMsg(featureStatus: 1))).state, AvailabilityState.downloadable);
      expect((await statusFor(NanoStatusMsg(featureStatus: 2))).state, AvailabilityState.downloading);
      final un = await statusFor(NanoStatusMsg(featureStatus: 0));
      expect(un.state, AvailabilityState.unsupported);
      expect(un.code, 'aicore_unavailable');
    });

    test('maps AICore errors to reasons', () async {
      Future<String> code(int c) async =>
          (await statusFor(NanoStatusMsg(featureStatus: -1, error: ErrorMsg(source: 'nano', code: c, message: 'x'))))
              .code;
      expect(await code(606), 'feature_not_found');
      expect(await code(601), 'aicore_binding_failed');
      expect(await code(604), 'needs_system_update');
      expect(await code(-101), 'aicore_incompatible');
      expect(await code(16), 'not_supported');
      expect(await code(42), 'status_error');
    });

    test('is unsupported off Android, without crashing', () async {
      backend.supported = false;
      final s = await provider.status();
      expect(s.code, 'not_android');
      expect(await provider.listModels(), isEmpty);
      final r = await collect(provider.stream(nanoRequest([user('hi')])));
      expect((r.error! as ProviderException).kind, ProviderErrorKind.unsupported);
    });
  });

  test('capabilities: input limit + output cap, prompted tools, mutable history, estimate family', () async {
    final caps = await provider.capabilities(GeminiNanoProvider.modelId);
    expect(caps.contextLength, 4000 + 1024);
    expect(caps.maxOutputTokens, 1024);
    expect(caps.toolCallFormat, ToolCallFormat.prompted);
    expect(caps.historyPolicy, HistoryPolicy.mutable);
    expect(caps.vision, isFalse);
    expect(caps.tokenizerFamily, 'gemma');
    expect(provider.info.kind, ProviderKind.localSystem);
    expect(provider.info.dataLeavesDevice, isFalse);
    final models = await provider.listModels();
    expect(models.single.id, GeminiNanoProvider.modelId);
    expect(models.single.displayName, 'Gemini Nano (nano-v3)');
  });

  test('streams a reply with usage; a single user message is sent as plain text', () async {
    script((s) {
      s.text('A short ');
      s.text('title');
      s.done(GenerationStatsMsg(finishReason: 0, promptTokens: 30, outputTokens: 3));
    });
    final r = await collect(provider.stream(nanoRequest([user('Title for: hiking trip')])));
    expect(r.error, isNull);
    expect(textOf(r.events), 'A short title');
    final u = r.events.whereType<UsageUpdate>().single.usage;
    expect([u.inputTokens, u.outputTokens], [30, 3]);
    expect(finishOf(r.events)!.reason, FinishReason.stop);
    final req = backend.nanoRequests.single;
    expect(req.prompt, 'Title for: hiking trip');
    expect(req.systemInstruction, 'You are Sherpa.');
    expect(req.maxOutputTokens, 1024);
    expect(req.countTokens, isTrue);
  });

  test('multi-turn requests are rendered as a full transcript every time (stateless)', () async {
    script((s) => s.done());
    await collect(provider.stream(nanoRequest([user('Hi'), assistant('Hello!'), user('Weather?')])));
    final prompt = backend.nanoRequests.single.prompt;
    expect(prompt, 'User: Hi\n\nAssistant: Hello!\n\nUser: Weather?\n\nAssistant:');
    expect(backend.nanoRequests.single.systemInstruction, contains('Write only the next Assistant reply'));
  });

  test('without system-prompt support the instructions head the prompt', () async {
    backend.nano = NanoStatusMsg(featureStatus: 3, systemPrompt: false);
    script((s) => s.done());
    await collect(provider.stream(nanoRequest([user('Hi')])));
    expect(backend.nanoRequests.single.systemInstruction, isNull);
    expect(backend.nanoRequests.single.prompt, 'Instructions:\nYou are Sherpa.\n\nHi');
  });

  test('prompted tool calls are parsed; results come back as untrusted data', () async {
    script((s) {
      s.text('{"tool_calls": [{"name": "get_weather", "arguments": {"city": "Oslo"}}]}');
      s.done(GenerationStatsMsg(finishReason: 0));
    });
    final r = await collect(provider.stream(nanoRequest([user('Weather in Oslo?')], tools: [weatherTool])));
    final call = callsOf(r.events).single;
    expect(call.arguments, {'city': 'Oslo'});
    expect(finishOf(r.events)!.reason, FinishReason.toolCalls);
    expect(backend.nanoRequests.single.systemInstruction, contains('## Tools'));

    script((s) => s.done());
    await collect(provider.stream(nanoRequest(
      [user('Weather in Oslo?'), replyFrom(r.events), toolResults([result(call.id, 'get_weather', 'Sunny')])],
      tools: [weatherTool],
    )));
    final prompt = backend.nanoRequests.last.prompt;
    expect(prompt, contains('Assistant: {"tool_calls":[{"name":"get_weather","arguments":{"city":"Oslo"}}]}'));
    expect(prompt, contains('<untrusted_data source="tool:get_weather">\nSunny\n</untrusted_data>'));
  });

  group('foreground only', () {
    test('a request in the background is refused with a clear unsupported error and never sent', () async {
      fg.foreground = false;
      final r = await collect(provider.stream(nanoRequest([user('hi')])));
      final e = r.error! as ProviderException;
      expect(e.kind, ProviderErrorKind.unsupported);
      expect(e.message, kNanoBackgroundMessage);
      expect(e.isRetryable, isFalse);
      expect(backend.nanoRequests, isEmpty);
    });

    test('leaving the app mid-reply pauses it; the continuation waits for the foreground', () async {
      script((s) async {
        s.text('Roses are');
        await settle();
        fg.foreground = false;
      });
      final r = await collect(provider.stream(nanoRequest([user('Poem')])));
      expect(r.error, isNull);
      final finish = finishOf(r.events)!;
      expect(finish.reason, FinishReason.pause);
      expect(finish.rawReason, 'background');
      expect(backend.cancels.single.reason, 'background');
      expect(textOf(r.events), 'Roses are');

      script((s) {
        s.text(' red.');
        s.done();
      });
      final next = collect(provider.stream(nanoRequest([user('Poem'), assistant('Roses are', finishReason: 'pause')])));
      await settle(10);
      expect(backend.nanoRequests, hasLength(1), reason: 'waits in the background');
      fg.foreground = true;
      final r2 = await next;
      expect(r2.error, isNull);
      expect(textOf(r2.events), ' red.');
      expect(backend.nanoRequests.last.prompt, 'User: Poem\n\nAssistant: Roses are');
      expect(r2.events.whereType<ProviderNotice>().map((n) => n.code), contains('waiting_for_foreground'));
    });

    test('BACKGROUND_USE_BLOCKED after some output pauses instead of failing', () async {
      script((s) {
        s.text('Partial');
        s.error(ErrorMsg(source: 'nano', code: 30, message: 'BACKGROUND_USE_BLOCKED'));
      });
      final r = await collect(provider.stream(nanoRequest([user('x')])));
      expect(r.error, isNull);
      expect(finishOf(r.events)!.reason, FinishReason.pause);
    });
  });

  group('errors', () {
    Future<ProviderException> failWith(int code, {int? retryMs}) async {
      script((s) => s.error(ErrorMsg(source: 'nano', code: code, message: 'err $code', retryAfterMs: retryMs)));
      final r = await collect(provider.stream(nanoRequest([user('x')])));
      return r.error! as ProviderException;
    }

    test('BUSY is retryable with AICore\'s delay', () async {
      final e = await failWith(9, retryMs: 1500);
      expect(e.kind, ProviderErrorKind.overloaded);
      expect(e.isRetryable, isTrue);
      expect(e.retryAfter, const Duration(milliseconds: 1500));
    });

    test('BUSY without a suggested delay leaves backoff to the agent loop', () async {
      final e = await failWith(9, retryMs: 0);
      expect(e.retryAfter, isNull);
      expect(e.isRetryable, isTrue);
    });

    test('the per-app battery quota is retryable', () async {
      final e = await failWith(27);
      expect(e.kind, ProviderErrorKind.rateLimited);
      expect(e.isRetryable, isTrue);
    });

    test('REQUEST_TOO_LARGE is contextOverflow; NOT_SUPPORTED is unsupported', () async {
      expect((await failWith(12)).kind, ProviderErrorKind.contextOverflow);
      expect((await failWith(16)).kind, ProviderErrorKind.unsupported);
      expect((await failWith(15)).kind, ProviderErrorKind.server);
    });

    test('a model that is not downloaded yet says so', () async {
      backend.nano = NanoStatusMsg(featureStatus: 1);
      final r = await collect(provider.stream(nanoRequest([user('x')])));
      final e = r.error! as ProviderException;
      expect(e.kind, ProviderErrorKind.modelNotFound);
      expect(e.message, contains('downloaded first'));
    });
  });

  test('cancel through the token ends with Finish(cancelled)', () async {
    final token = CancellationToken();
    script((s) async {
      s.text('Once');
      await settle();
      token.cancel();
    });
    final r = await collect(provider.stream(nanoRequest([user('x')]), cancel: token));
    expect(finishOf(r.events)!.reason, FinishReason.cancelled);
    expect(backend.cancels.single.reason, 'user');
  });

  test('MAX_TOKENS finishes with length', () async {
    script((s) {
      s.text('…');
      s.done(GenerationStatsMsg(finishReason: 1));
    });
    final r = await collect(provider.stream(nanoRequest([user('x')])));
    expect(finishOf(r.events)!.reason, FinishReason.length);
  });

  test('images of the last user message go along only with vision enabled', () async {
    final img = ImagePart(mimeType: 'image/jpeg', data: Uint8List.fromList([9, 9]));
    script((s) => s.done());
    final r = await collect(provider.stream(nanoRequest([user('What is it?', extra: [img])])));
    expect(backend.nanoRequests.single.images, isNull);
    expect(r.events.whereType<ProviderNotice>().map((n) => n.code), contains('content_dropped'));

    final vision = make(options: const GeminiNanoOptions(vision: true));
    script((s) => s.done());
    await collect(vision.stream(nanoRequest([user('What is it?', extra: [img])])));
    expect(backend.nanoRequests.last.images!.single, [9, 9]);
  });

  test('download reports progress and completion', () async {
    script((s) {
      s.batch([LiteRtEvent(kind: EventKind.downloadStarted, value: 1000)]);
      s.batch([LiteRtEvent(kind: EventKind.downloadProgress, value: 400)]);
      s.batch([LiteRtEvent(kind: EventKind.downloadCompleted)]);
    });
    final updates = await provider.download().toList();
    expect(updates[0], isA<NanoDownloadStarted>().having((u) => u.totalBytes, 'total', 1000));
    expect((updates[1] as NanoDownloadProgress).fraction, 0.4);
    expect(updates.last, isA<NanoDownloadCompleted>());
  });

  test('a failed download reports the error', () async {
    script((s) => s.batch([
          LiteRtEvent(kind: EventKind.downloadFailed, error: ErrorMsg(source: 'nano', code: 501, message: 'disk full')),
        ]));
    final updates = await provider.download().toList();
    final failed = updates.single as NanoDownloadFailed;
    expect(failed.error.kind, ProviderErrorKind.unsupported);
  });

  test('both providers share one stream-id space on one backend', () async {
    final lm = LiteRtLmProvider(backend: backend, foreground: fg);
    expect(identical(LiteRtLmProvider.routerFor(backend), LiteRtLmProvider.routerFor(backend)), isTrue);
    await lm.dispose();
  });

  test('a waiting continuation can be cancelled', () async {
    fg.foreground = false;
    final token = CancellationToken();
    final f = collect(provider.stream(nanoRequest([user('x'), assistant('y', finishReason: 'pause')]), cancel: token));
    await settle();
    token.cancel();
    final r = await f.timeout(const Duration(seconds: 2));
    expect(finishOf(r.events)!.reason, FinishReason.cancelled);
    expect(backend.nanoRequests, isEmpty);
  });
}
