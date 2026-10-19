import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa_apple_ml/sherpa_apple_ml.dart';
import 'package:sherpa_apple_ml/testing.dart';
import 'package:sherpa_core/sherpa_core.dart';

import 'support/harness.dart';

void main() {
  late FakeAppleMlBackend fake;
  late Directory dir;
  late MlxProvider provider;

  MlxProvider make({MlxProviderConfig config = const MlxProviderConfig(), MlxModelSpec? spec}) => MlxProvider(
    backend: fake,
    config: config,
    ids: SequentialIdGenerator(),
    models: [spec ?? MlxModelSpec(id: 'qwen3', directory: dir.path, displayName: 'Qwen3 4B')],
  );

  setUp(() {
    fake = FakeAppleMlBackend();
    dir = mlxModelDir();
    provider = make();
  });

  tearDown(() async {
    await provider.dispose();
    await fake.close();
    dir.deleteSync(recursive: true);
  });

  /// Answers every generation with [text] then `finished(stop)`.
  void answer(String text) {
    fake.onGenerate = (g) {
      g.text(text);
      g.info();
      g.finish();
    };
  }

  group('loading and capabilities', () {
    test('capabilities load the model with admission-chosen context and the resolved formats', () async {
      final caps = await provider.capabilities('qwen3');
      expect(fake.loads.single.directory, dir.path);
      expect(fake.loads.single.cacheLimitBytes, 32 << 20);
      expect(caps.contextLength, 8192, reason: 'preferred context fits the 0.6 × 6 GB budget');
      expect(caps.toolCallFormat, ToolCallFormat.prompted);
      expect(caps.reasoning, ReasoningSupport.optional);
      expect(caps.historyPolicy, HistoryPolicy.appendOnly);
      expect(caps.supportsPromptCache, isTrue);
      expect(caps.quantization, '4-bit');
      expect(provider.info.kind, ProviderKind.localMlx);
      expect(provider.info.dataLeavesDevice, isFalse);
      await provider.capabilities('qwen3');
      expect(fake.loads, hasLength(1), reason: 'loaded once');
    });

    test('admission shrinks the context to what fits, then refuses', () async {
      // 1 GiB available → budget 0.6 GiB; 416 MiB fixed (overhead + buffer
      // cache) leaves ~3.4k tokens of 8-bit KV at ~60 KB/token.
      fake.platform = FakeAppleMlBackend.iosDevice(available: 1 << 30);
      final caps = await provider.capabilities('qwen3');
      expect(caps.contextLength, lessThan(8192));
      expect(caps.contextLength, greaterThanOrEqualTo(2048));
      expect(caps.contextLength % 256, 0);

      final tight = make();
      fake.platform = FakeAppleMlBackend.iosDevice(available: 600 << 20);
      await expectLater(
        tight.capabilities('qwen3'),
        throwsA(isA<ProviderException>().having((e) => e.kind, 'kind', ProviderErrorKind.outOfMemory)),
      );
      await tight.dispose();
    });

    test('native load errors map to provider error kinds', () async {
      fake.loadError = PlatformException(code: 'unsupported', message: 'Unsupported model type: foo');
      await expectLater(
        provider.capabilities('qwen3'),
        throwsA(isA<ProviderException>().having((e) => e.kind, 'kind', ProviderErrorKind.unsupported)),
      );
      expect(
        () => provider.capabilities('nope'),
        throwsA(isA<ProviderException>().having((e) => e.kind, 'kind', ProviderErrorKind.modelNotFound)),
      );
    });
  });

  group('request mapping', () {
    test('system prompt, history, tools, sampling, KV and thinking switch reach Swift', () async {
      answer('ok');
      final call = ToolCall(
        id: 'c1',
        name: 'get_weather',
        arguments: const {'city': 'Oslo'},
        rawArguments: '{"city":"Oslo"}',
      );
      final (events, error) = await collect(
        provider.stream(
          request(
            [
              user('u1', 'Weather?'),
              assistant('a1', '', calls: [call]),
              toolResult('t1', 'c1', 'get_weather', 'Rain'),
              user('u2', 'And tomorrow?'),
            ],
            tools: [weatherTool],
            params: const GenerationParams(
              temperature: 0.2,
              topK: 20,
              maxOutputTokens: 256,
              seed: 7,
              reasoning: ReasoningEffort.off,
            ),
          ),
        ),
      );
      expect(error, isNull);
      final r = fake.mlxRequests.single;
      expect(r.instructions, 'You are Sherpa.');
      expect(r.mode, AmHistoryMode.rebuild);
      // Rebuilt from everything up to the last assistant turn; what follows
      // it is sent as the new input.
      expect([for (final m in r.history) m.role], ['user', 'assistant']);
      expect(r.history[1].toolCalls!.single.argumentsJson, '{"city":"Oslo"}', reason: 'exact model text is replayed');
      expect([for (final m in r.pending) m.role], ['tool', 'user']);
      expect(r.pending[0].toolCallId, 'c1');
      expect(r.pending[1].content, 'And tomorrow?');
      final tools = jsonDecode(r.toolsJson!) as List;
      final fn = (tools.single as Map)['function'] as Map;
      expect(fn['name'], 'get_weather');
      expect((fn['parameters'] as Map).containsKey('title'), isFalse, reason: 'annotation keywords dropped');
      expect((fn['parameters'] as Map).containsKey(r'$schema'), isFalse);
      expect(r.sampling.temperature, 0.2);
      expect(r.sampling.topK, 20);
      expect(r.sampling.maxTokens, 256);
      expect(r.sampling.seed, 7);
      expect(r.kv.kvBits, 8);
      expect(r.kv.maxKVSize, 8192);
      expect(r.thinkingKey, 'enable_thinking');
      expect(r.thinkingEnabled, isFalse);
      expect(r.ephemeral, isFalse);
      expect(r.sessionKey, 's1');
      expect(textOf(events), 'ok');
    });

    test('unsupported options produce notices; a one-off request gets an ephemeral session', () async {
      answer('x');
      final (events, _) = await collect(
        provider.stream(
          request(
            [user('u1', 'hi')],
            session: null,
            tools: [weatherTool],
            params: const GenerationParams(
              jsonSchema: {'type': 'object'},
              stop: ['END'],
              toolChoice: ToolChoice.required,
            ),
          ),
        ),
      );
      final codes = events.whereType<ProviderNotice>().map((n) => n.code).toSet();
      expect(codes, containsAll(['json_schema_unsupported', 'stop_unsupported', 'tool_choice_unsupported']));
      expect(fake.mlxRequests.single.ephemeral, isTrue);
      expect(fake.mlxRequests.single.sessionKey, startsWith('oneoff:'));
    });

    test('images are dropped with a notice', () async {
      answer('x');
      final m = Message(
        id: 'u1',
        role: Role.user,
        content: [
          const TextPart('look'),
          ImagePart(mimeType: 'image/png', uri: Uri.parse('file:///a.png')),
        ],
        createdAt: t0,
      );
      final (events, _) = await collect(provider.stream(request([m])));
      expect(events.whereType<ProviderNotice>().map((n) => n.code), contains('content_dropped'));
      expect(fake.mlxRequests.single.pending.single.content, 'look');
    });
  });

  group('event mapping', () {
    test('reasoning tags split across chunks, usage and perf', () async {
      fake.onGenerate = (g) {
        g.text('<thi');
        g.text('nk>plan it</th');
        g.text('ink>\nAnswer');
        g.info(prompt: 30, cached: 70, generated: 12, promptSec: 0.5, genSec: 1.0);
        g.finish();
      };
      final (events, _) = await collect(provider.stream(request([user('u1', 'q')])));
      expect(reasoningOf(events), 'plan it');
      expect(textOf(events), 'Answer');
      final usage = events.whereType<UsageUpdate>().single.usage;
      expect(usage.inputTokens, 30, reason: 'prefilled (uncached) prompt tokens');
      expect(usage.cacheReadTokens, 70);
      expect(usage.outputTokens, 12);
      final perf = events.whereType<PerfSample>().single;
      expect(perf.promptTokens, 100);
      expect(perf.prefillTokensPerSec, 60);
      expect(perf.decodeTokensPerSec, 12);
      expect(perf.backend, 'mlx-metal');
      expect(finishOf(events).reason, FinishReason.stop);
      expect(events.last, isA<Finish>());
    });

    test('a primed template (no opening tag) still separates reasoning', () async {
      fake.onLoad = (r) => FakeAppleMlBackend.qwen3Info(r.modelId)
        ..reasoningToggleKey = null
        ..reasoningAlwaysOn = true
        ..reasoningPrimed = true;
      fake.onGenerate = (g) {
        g.text('thinking...');
        g.text('</think>Done');
        g.finish();
      };
      final (events, _) = await collect(provider.stream(request([user('u1', 'q')])));
      expect(reasoningOf(events), 'thinking...');
      expect(textOf(events), 'Done');
    });

    test('tool calls: start + args at once, complete at the end, repaired when MLX recovered one', () async {
      fake.onGenerate = (g) {
        g.text('Checking.');
        g.toolCall('get_weather', '{"city":"Paris"}');
        g.info(recovered: 1);
        g.finish();
      };
      final (events, _) = await collect(provider.stream(request([user('u1', 'q')], tools: [weatherTool])));
      final start = events.whereType<ToolCallStart>().single;
      expect(start.name, 'get_weather');
      expect(start.index, 0);
      final complete = events.whereType<ToolCallComplete>().single;
      expect(complete.call.arguments, {'city': 'Paris'});
      expect(complete.call.repaired, isTrue);
      expect(complete.call.id, start.id);
      expect(events.indexOf(complete), greaterThan(events.indexOf(events.whereType<UsageUpdate>().single)));
      expect(finishOf(events).reason, FinishReason.toolCalls);
    });

    test('a rejected tool call is reported with argumentsError and invalidates the session', () async {
      fake.onGenerate = (g) {
        g.rejectedToolCall(
          'invalid_arguments',
          toolName: 'get_weather',
          preview: '{"city": 3}',
          detail: 'city must be a string',
        );
        g.finish();
      };
      final (events, _) = await collect(provider.stream(request([user('u1', 'q')], tools: [weatherTool])));
      expect(events.whereType<ProviderNotice>().map((n) => n.code), contains('tool_call_rejected'));
      final call = events.whereType<ToolCallComplete>().single.call;
      expect(call.isValid, isFalse);
      expect(call.argumentsError, contains('invalid_arguments'));
      final reply = storedReply('a1', events);
      answer('ok');
      await collect(
        provider.stream(
          request([
            user('u1', 'q'),
            reply,
            toolResult('t1', call.id, 'get_weather', '[tool error] bad args', isError: true),
          ]),
        ),
      );
      expect(fake.mlxRequests.last.mode, AmHistoryMode.rebuild, reason: 'ChatSession did not record a rejected turn');
    });

    test('native errors become ProviderExceptions of the right kind', () async {
      fake.onGenerate = (g) {
        g.text('par');
        g.error(AppleMlErrorCode.outOfMemory, '[METAL] Command buffer execution failed: Insufficient Memory');
      };
      final (events, error) = await collect(provider.stream(request([user('u1', 'q')])));
      expect(textOf(events), 'par');
      expect(error, isA<ProviderException>().having((e) => e.kind, 'kind', ProviderErrorKind.outOfMemory));
      expect(events.whereType<Finish>(), isEmpty);

      for (final (code, kind) in [
        (AppleMlErrorCode.engineError, ProviderErrorKind.engineCrashed),
        (AppleMlErrorCode.contextOverflow, ProviderErrorKind.contextOverflow),
        (AppleMlErrorCode.invalidRequest, ProviderErrorKind.invalidRequest),
        ('somethingNew', ProviderErrorKind.unknown),
      ]) {
        fake.onGenerate = (g) => g.error(code, 'x');
        final (_, e) = await collect(provider.stream(request([user('u1', 'q')], session: null)));
        expect((e! as ProviderException).kind, kind, reason: code);
      }
      expect(errorKindForCode(AppleMlErrorCode.engineError), ProviderErrorKind.engineCrashed);
      expect(const ProviderException(ProviderErrorKind.engineCrashed, '').isRetryable, isTrue);
    });
  });

  group('history policy', () {
    test('append while the native transcript is a prefix; rebuild on edits and branches', () async {
      answer('Hi!');
      final (e1, _) = await collect(provider.stream(request([user('u1', 'Hello')])));
      expect(fake.mlxRequests[0].mode, AmHistoryMode.rebuild);
      final a1 = storedReply('a1', e1);

      answer('Fine.');
      final (e2, _) = await collect(provider.stream(request([user('u1', 'Hello'), a1, user('u2', 'How are you?')])));
      expect(fake.mlxRequests[1].mode, AmHistoryMode.append);
      expect(fake.mlxRequests[1].pending.single.content, 'How are you?');
      expect(fake.mlxRequests[1].history, isEmpty);
      final a2 = storedReply('a2', e2);

      // A changed system prompt or tool list stays an append: ChatSession
      // re-renders the template and reuses the common token prefix.
      await collect(
        provider.stream(
          request(
            [user('u1', 'Hello'), a1, user('u2', 'How are you?'), a2, user('u3', 'More')],
            system: 'Be brief.',
            tools: [weatherTool],
          ),
        ),
      );
      expect(fake.mlxRequests[2].mode, AmHistoryMode.append);
      expect(fake.mlxRequests[2].instructions, 'Be brief.');

      // Edit of the first user message (a new branch from the root).
      await collect(provider.stream(request([user('u1b', 'Hello there')])));
      expect(fake.mlxRequests[3].mode, AmHistoryMode.rebuild);

      // Branch: retry of the second turn from a1.
      await collect(provider.stream(request([user('u1', 'Hello'), a1, user('u2b', 'What time is it?')])));
      final r = fake.mlxRequests[4];
      expect(r.mode, AmHistoryMode.rebuild);
      expect([for (final m in r.history) m.content], ['Hello', 'Hi!']);
      expect(r.pending.single.content, 'What time is it?');
    });

    test('a reply stored differently (another provider, compaction) rebuilds', () async {
      answer('Hi!');
      await collect(provider.stream(request([user('u1', 'Hello')])));
      answer('ok');
      await collect(
        provider.stream(request([user('u1', 'Hello'), assistant('a1', 'Hello! (from cloud)'), user('u2', 'x')])),
      );
      expect(fake.mlxRequests[1].mode, AmHistoryMode.rebuild);
    });

    test('appending a foreign assistant turn is allowed when the prefix matches', () async {
      answer('Hi!');
      final (e1, _) = await collect(provider.stream(request([user('u1', 'Hello')])));
      final a1 = storedReply('a1', e1);
      answer('ok');
      await collect(provider.stream(request([user('u1', 'Hello'), a1, user('u2', 'x')])));
      answer('ok2');
      // The native transcript holds u1 a1 u2 "ok"; Dart now has u2's reply
      // from a remote provider plus a new question: still a prefix up to u2.
      await collect(
        provider.stream(request([user('u1', 'Hello'), a1, user('u2', 'x'), assistant('a2', 'ok'), user('u3', 'y')])),
      );
      expect(fake.mlxRequests[2].mode, AmHistoryMode.append);
      expect(fake.mlxRequests[2].pending.single.content, 'y');
    });

    test('tool loop appends tool results to the warm session', () async {
      fake.onGenerate = (g) {
        g.toolCall('get_weather', '{"city":"Paris"}', id: 'call_1');
        g.finish();
      };
      final (e1, _) = await collect(provider.stream(request([user('u1', 'Weather?')], tools: [weatherTool])));
      final a1 = storedReply('a1', e1);
      answer('Sunny.');
      await collect(
        provider.stream(
          request(
            [user('u1', 'Weather?'), a1, toolResult('t1', 'call_1', 'get_weather', '22 °C')],
            tools: [weatherTool],
          ),
        ),
      );
      final r = fake.mlxRequests[1];
      expect(r.mode, AmHistoryMode.append);
      expect(r.pending.single.role, 'tool');
      expect(r.pending.single.toolCallId, 'call_1');
      expect(r.pending.single.content, '22 °C');
    });

    test('sessionLost (dropped natively) is retried once as a rebuild', () async {
      answer('Hi!');
      final (e1, _) = await collect(provider.stream(request([user('u1', 'Hello')])));
      fake.generateError = PlatformException(code: AppleMlErrorCode.sessionLost);
      answer('ok');
      final (e2, err) = await collect(
        provider.stream(request([user('u1', 'Hello'), storedReply('a1', e1), user('u2', 'x')])),
      );
      expect(err, isNull);
      expect(textOf(e2), 'ok');
      expect(fake.mlxRequests.last.mode, AmHistoryMode.rebuild);
    });

    test('a memory warning that dropped the session invalidates its ledger', () async {
      answer('Hi!');
      final (e1, _) = await collect(provider.stream(request([user('u1', 'Hello')])));
      fake.emitGlobal(AmEvent(kind: AmEventKind.memoryWarning)..text = 's1');
      await pumpEventQueue();
      await collect(provider.stream(request([user('u1', 'Hello'), storedReply('a1', e1), user('u2', 'x')])));
      expect(fake.mlxRequests.last.mode, AmHistoryMode.rebuild);
    });

    test('modelUnloaded after an MLX error reloads on the next request', () async {
      answer('Hi!');
      await collect(provider.stream(request([user('u1', 'Hello')])));
      fake.emitGlobal(
        AmEvent(kind: AmEventKind.notice)
          ..code = 'modelUnloaded'
          ..text = 'qwen3',
      );
      await pumpEventQueue();
      expect(provider.loaded, isNull);
      await collect(provider.stream(request([user('u1', 'Hello again')])));
      expect(fake.loads, hasLength(2));
    });
  });

  group('cancel and pause', () {
    test('cancelling the token stops native decoding and ends with Finish(cancelled)', () async {
      final token = CancellationToken();
      fake.onGenerate = (g) => g.text('partial');
      final events = <ModelEvent>[];
      final done = provider.stream(request([user('u1', 'q')]), cancel: token).listen(events.add).asFuture<void>();
      await until(() => textOf(events) == 'partial');
      token.cancel('user stop');
      await done;
      expect(fake.cancels, ['mlxgen_1']);
      expect(finishOf(events).reason, FinishReason.cancelled);
    });

    test('cancelling the subscription cancels natively', () async {
      fake.onGenerate = (g) => g.text('partial');
      final sub = provider.stream(request([user('u1', 'q')])).listen((_) {});
      await until(() => fake.mlxRequests.isNotEmpty && fake.lastGeneration.sentBatches > 0);
      await sub.cancel();
      await until(() => fake.cancels.isNotEmpty);
    });

    test('cancel grace: no native finish still ends the stream', () async {
      final quick = make(config: const MlxProviderConfig(cancelGrace: Duration(milliseconds: 20)));
      fake.finishOnCancel = false;
      fake.onGenerate = (g) => g.text('partial');
      final token = CancellationToken();
      final events = <ModelEvent>[];
      final done = quick.stream(request([user('u1', 'q')]), cancel: token).listen(events.add).asFuture<void>();
      await until(() => events.isNotEmpty);
      token.cancel();
      await done;
      expect(finishOf(events).reason, FinishReason.cancelled);
      await quick.dispose();
    });

    test('resign-active pause ends with Finish(pause); the continuation and merge follow', () async {
      fake.onGenerate = (g) => g.text('The answer is');
      final events = <ModelEvent>[];
      final done = provider.stream(request([user('u1', 'q')])).listen(events.add).asFuture<void>();
      await until(() => textOf(events) == 'The answer is');
      // What Swift does on willResignActive (LifecycleMonitor → pauseAll).
      await fake.interruptAll('app_inactive');
      await done;
      final f = finishOf(events);
      expect(f.reason, FinishReason.pause);
      expect(f.rawReason, 'app_inactive');

      // The agent loop continues the paused reply.
      final partial = storedReply('a1', events);
      answer(' 42.');
      final (e2, _) = await collect(provider.stream(request([user('u1', 'q'), partial])));
      final r = fake.mlxRequests[1];
      expect(r.mode, AmHistoryMode.continueAssistant);
      expect(r.partialAssistant, 'The answer is');
      expect([for (final m in r.history) m.content], ['q']);
      expect(textOf(e2), ' 42.');

      // Next turn: paused part + continuation are ONE assistant turn, and the
      // session (not recorded by ChatSession) is rebuilt.
      answer('ok');
      await collect(provider.stream(request([user('u1', 'q'), partial, storedReply('a2', e2), user('u2', 'next')])));
      final r3 = fake.mlxRequests[2];
      expect(r3.mode, AmHistoryMode.rebuild);
      expect([for (final m in r3.history) m.content], ['q', 'The answer is 42.']);
    });

    test('Dart-initiated interrupt (thermal policy) pauses too', () async {
      fake.onGenerate = (g) => g.text('x');
      final events = <ModelEvent>[];
      final done = provider.stream(request([user('u1', 'q')])).listen(events.add).asFuture<void>();
      await until(() => events.isNotEmpty);
      await provider.interrupt('thermal_critical');
      await done;
      expect(finishOf(events).rawReason, 'thermal_critical');
      expect(fake.interrupts, ['thermal_critical']);
    });

    test('a pause after complete tool calls ends with Finish(toolCalls)', () async {
      fake.onGenerate = (g) => g.toolCall('get_weather', '{"city":"Rome"}');
      final events = <ModelEvent>[];
      final done = provider
          .stream(request([user('u1', 'q')], tools: [weatherTool]))
          .listen(events.add)
          .asFuture<void>();
      await until(() => events.whereType<ToolCallStart>().isNotEmpty);
      await fake.interruptAll('app_inactive');
      await done;
      expect(finishOf(events).reason, FinishReason.toolCalls);
      expect(events.whereType<ToolCallComplete>(), hasLength(1));
    });

    test('waiting while backgrounded is surfaced as a notice', () async {
      fake.onGenerate = (g) {
        g.waiting();
        g.text('later');
        g.finish();
      };
      final (events, _) = await collect(provider.stream(request([user('u1', 'q')])));
      expect(events.whereType<ProviderNotice>().map((n) => n.code), contains('waiting_for_foreground'));
    });
  });

  group('flow control', () {
    test('a paused subscriber withholds credits; Swift coalesces; nothing is lost', () async {
      late FakeGeneration gen;
      fake.onGenerate = (g) => gen = g;
      final events = <ModelEvent>[];
      final sub = provider.stream(request([user('u1', 'q')])).listen(events.add);
      await until(() => fake.mlxRequests.isNotEmpty);
      sub.pause();
      for (var i = 0; i < 50; i++) {
        gen.text('$i,');
        await pumpEventQueue(times: 2);
      }
      expect(gen.outstanding, lessThanOrEqualTo(FakeAppleMlBackend().maxOutstanding));
      expect(gen.queued, 1, reason: 'pending text coalesced into one event');
      gen.finish();
      sub.resume();
      await sub.asFuture<void>();
      await sub.cancel();
      expect(textOf(events), [for (var i = 0; i < 50; i++) '$i,'].join());
      expect(finishOf(events).reason, FinishReason.stop);
      expect(gen.outstanding, 0, reason: 'every batch acked');
    });

    test('generations run one at a time', () async {
      final gens = <FakeGeneration>[];
      fake.onGenerate = gens.add;
      final a = collect(provider.stream(request([user('u1', 'a')], session: 'A')));
      final b = collect(provider.stream(request([user('u1', 'b')], session: 'B')));
      await until(() => gens.length == 1);
      await pumpEventQueue();
      expect(gens, hasLength(1), reason: 'B waits for A');
      gens[0].finish();
      await until(() => gens.length == 2);
      gens[1].finish();
      await Future.wait([a, b]);
    });
  });

  group('availability', () {
    test('verdicts for device and directory', () async {
      Future<AppleMlAvailability> check(String path, {AmPlatformInfo? platform, bool supported = true}) {
        final b = FakeAppleMlBackend(supported: supported, platform: platform);
        return MlxProvider.availability(path, backend: b);
      }

      expect((await check(dir.path, supported: false)).reason, AppleMlReason.notIos);
      expect(
        (await check(dir.path, platform: FakeAppleMlBackend.iosDevice(simulator: true))).reason,
        AppleMlReason.simulator,
      );
      expect(
        (await check(dir.path, platform: FakeAppleMlBackend.iosDevice(mlx: false))).reason,
        AppleMlReason.notCompiled,
      );
      expect(
        (await check(dir.path, platform: FakeAppleMlBackend.iosDevice(metal: false))).reason,
        AppleMlReason.noMetalDevice,
      );
      expect(
        (await check(dir.path, platform: FakeAppleMlBackend.iosDevice(osVersion: '16.7'))).reason,
        AppleMlReason.osTooOld,
      );

      final missing = await check('${dir.path}/nothing-here');
      expect((missing.status, missing.reason), (AppleMlStatus.downloadable, AppleMlReason.modelMissing));

      final partial = mlxModelDir(shardMissing: true);
      final p = await check(partial.path);
      expect((p.status, p.reason), (AppleMlStatus.downloadable, AppleMlReason.modelIncomplete));
      expect(p.details['missingWeights'], ['model-00002-of-00002.safetensors']);

      final noTok = mlxModelDir(tokenizer: false);
      expect((await check(noTok.path)).reason, AppleMlReason.modelIncomplete);

      final arch = mlxModelDir(modelType: 'whisper');
      final a = await check(arch.path);
      expect((a.status, a.reason), (AppleMlStatus.unsupported, AppleMlReason.unsupportedArchitecture));

      final npz = mlxModelDir(npzOnly: true);
      expect((await check(npz.path)).reason, AppleMlReason.legacyFormat);

      final base = mlxModelDir(template: false);
      expect((await check(base.path)).status, AppleMlStatus.unsupported);

      final huge = mlxModelDir(weightBytes: 4 << 20);
      final h = await check(huge.path, platform: FakeAppleMlBackend.iosDevice(available: 512 << 20));
      expect((h.status, h.reason), (AppleMlStatus.unsupported, AppleMlReason.insufficientMemory));

      // A file inside the directory (the library's loadPath) works too.
      final ok = await check('${dir.path}/model-00001-of-00002.safetensors');
      expect(ok.status, AppleMlStatus.available);
      expect(ok.details['modelType'], 'qwen3');
      expect(ok.details['contextLength'], 8192);

      for (final d in [partial, noTok, arch, npz, base, huge]) {
        d.deleteSync(recursive: true);
      }
    });

    test('off iOS everything reports unsupported and still runs', () async {
      final off = MlxProvider(
        backend: const UnsupportedAppleMlBackend(),
        models: [MlxModelSpec(id: 'qwen3', directory: dir.path)],
      );
      expect(
        (await MlxProvider.availability(dir.path, backend: const UnsupportedAppleMlBackend())).status,
        AppleMlStatus.unsupported,
      );
      final (events, error) = await collect(off.stream(request([user('u1', 'q')])));
      expect(events, isEmpty);
      expect(error, isA<ProviderException>().having((e) => e.kind, 'kind', ProviderErrorKind.unsupported));
      expect((await off.listModels()).single.id, 'qwen3');
      await off.forgetConversation('s1');
      await off.dispose();
    });
  });

  test('forgetConversation drops the native session; savePromptCache needs a live one', () async {
    expect(await provider.savePromptCache('s1', '${dir.path}/s1.safetensors'), isFalse);
    answer('Hi!');
    await collect(provider.stream(request([user('u1', 'Hello')])));
    expect(await provider.savePromptCache('s1', '${dir.path}/s1.safetensors'), isTrue);
    expect(fake.savedCaches.single, ('s1', '${dir.path}/s1.safetensors'));
    await provider.forgetConversation('s1');
    expect(fake.drops.single, (AmEngine.mlx, 's1'));
  });

  test('an opted-in prompt cache restores a tool-less rebuild of exactly the saved prefix', () async {
    final restoring = make(config: const MlxProviderConfig(restorePromptCaches: true));
    answer('Hi!');
    final (e1, _) = await collect(restoring.stream(request([user('u1', 'Hello')])));
    final path = '${dir.path}/s1.safetensors';
    expect(await restoring.savePromptCache('s1', path), isTrue);
    // The native session is gone (e.g. app restart → memory warning here).
    fake.emitGlobal(AmEvent(kind: AmEventKind.memoryWarning)..text = 's1');
    await pumpEventQueue();
    answer('ok');
    await collect(restoring.stream(request([user('u1', 'Hello'), storedReply('a1', e1), user('u2', 'x')])));
    final r = fake.mlxRequests.last;
    expect(r.mode, AmHistoryMode.restoreCache);
    expect(r.cachePath, path);
    expect(r.pending.single.content, 'x');
    await restoring.dispose();
  });
}
