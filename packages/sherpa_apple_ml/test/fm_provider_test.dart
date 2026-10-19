import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa_apple_ml/sherpa_apple_ml.dart';
import 'package:sherpa_apple_ml/testing.dart';
import 'package:sherpa_core/sherpa_core.dart';

import 'support/harness.dart';

const _model = AppleFoundationModelsProvider.systemModelId;

void main() {
  late FakeAppleMlBackend fake;
  late AppleFoundationModelsProvider provider;

  AppleFoundationModelsProvider make({FmProviderConfig config = const FmProviderConfig()}) =>
      AppleFoundationModelsProvider(backend: fake, config: config, ids: SequentialIdGenerator());

  setUp(() {
    fake = FakeAppleMlBackend();
    provider = make();
  });

  tearDown(() async {
    await provider.dispose();
    await fake.close();
  });

  ModelRequest req(
    List<Message> m, {
    List<ToolDefinition> tools = const [],
    GenerationParams? params,
    String? session = 's1',
  }) => request(m, model: _model, tools: tools, params: params ?? const GenerationParams(), session: session);

  group('status', () {
    test('maps SystemLanguageModel availability onto available / downloadable / unsupported', () async {
      Future<AppleMlAvailability> s(AmFmAvailability a) =>
          AppleFoundationModelsProvider.status(backend: FakeAppleMlBackend(fm: a));
      AmFmAvailability no(AmFmUnavailableReason r) =>
          AmFmAvailability(available: false, reason: r, localeSupported: false);

      final ok = await s(
        AmFmAvailability(available: true, reason: AmFmUnavailableReason.none, localeSupported: true)
          ..contextSize = 4096,
      );
      expect(ok.status, AppleMlStatus.available);
      expect(ok.details['contextSize'], 4096);
      for (final (reason, status, mapped) in [
        (AmFmUnavailableReason.deviceNotEligible, AppleMlStatus.unsupported, AppleMlReason.deviceNotEligible),
        (
          AmFmUnavailableReason.appleIntelligenceNotEnabled,
          AppleMlStatus.downloadable,
          AppleMlReason.appleIntelligenceNotEnabled,
        ),
        (AmFmUnavailableReason.modelNotReady, AppleMlStatus.downloadable, AppleMlReason.modelNotReady),
        (AmFmUnavailableReason.osTooOld, AppleMlStatus.unsupported, AppleMlReason.osTooOld),
        (AmFmUnavailableReason.frameworkMissing, AppleMlStatus.unsupported, AppleMlReason.notCompiled),
        (AmFmUnavailableReason.unknown, AppleMlStatus.unsupported, AppleMlReason.unknown),
      ]) {
        final v = await s(no(reason));
        expect((v.status, v.reason), (status, mapped), reason: reason.name);
      }
      final off = await AppleFoundationModelsProvider.status(backend: const UnsupportedAppleMlBackend());
      expect((off.status, off.reason), (AppleMlStatus.unsupported, AppleMlReason.notIos));
    });

    test('capabilities and models', () async {
      final caps = await provider.capabilities(_model);
      expect(caps.contextLength, 4096);
      expect(caps.toolCallFormat, ToolCallFormat.native);
      expect(caps.historyPolicy, HistoryPolicy.appendOnly);
      expect((await provider.listModels()).single.id, _model);
      expect(provider.info.kind, ProviderKind.localSystem);
      expect(provider.info.dataLeavesDevice, isFalse);
      fake.fm = AmFmAvailability(
        available: false,
        reason: AmFmUnavailableReason.deviceNotEligible,
        localeSupported: false,
      );
      expect(await make().listModels(), isEmpty);
    });

    test('a request while the model is not ready fails as unsupported', () async {
      fake.fm = AmFmAvailability(available: false, reason: AmFmUnavailableReason.modelNotReady, localeSupported: false);
      final (_, error) = await collect(provider.stream(req([user('u1', 'hi')])));
      expect(error, isA<ProviderException>().having((e) => e.kind, 'kind', ProviderErrorKind.unsupported));
      expect(fake.fmRequests, isEmpty);
    });
  });

  group('generation', () {
    test('request mapping, streamed deltas, usage and append on the next turn', () async {
      fake.onGenerate = (g) {
        g.text('Hello');
        g.text(' there');
        g.info(prompt: 40, cached: 10, generated: 3);
        g.finish();
      };
      final (e1, err) = await collect(
        provider.stream(req([user('u1', 'Hi')], params: const GenerationParams(temperature: 0))),
      );
      expect(err, isNull);
      final r1 = fake.fmRequests.single;
      expect(r1.mode, AmHistoryMode.rebuild);
      expect(r1.instructions, 'You are Sherpa.');
      expect(r1.prompt, 'Hi');
      expect(r1.history, isEmpty);
      expect(r1.greedy, isTrue);
      expect(textOf(e1), 'Hello there');
      final usage = e1.whereType<UsageUpdate>().single.usage;
      expect((usage.inputTokens, usage.cacheReadTokens, usage.outputTokens), (30, 10, 3));
      expect(finishOf(e1).reason, FinishReason.stop);

      fake.onGenerate = (g) {
        g.text('Sure.');
        g.finish();
      };
      await collect(provider.stream(req([user('u1', 'Hi'), storedReply('a1', e1), user('u2', 'More?')])));
      final r2 = fake.fmRequests[1];
      expect(r2.mode, AmHistoryMode.append);
      expect(r2.prompt, 'More?');
      expect(r2.history, isEmpty);
      expect(r2.sessionKey, 's1');
    });

    test('consecutive user turns join into one prompt; edits rebuild from a transcript', () async {
      fake.onGenerate = (g) => g.finish();
      await collect(provider.stream(req([user('u1', 'One'), user('u2', 'Two')])));
      expect(fake.fmRequests.single.prompt, 'One\n\nTwo');
      await collect(provider.stream(req([user('u1', 'Edited'), assistant('a1', 'x'), user('u3', 'Three')])));
      final r = fake.fmRequests[1];
      expect(r.mode, AmHistoryMode.rebuild);
      expect([for (final m in r.history) m.role], ['user', 'assistant']);
      expect(r.prompt, 'Three');
    });

    test('a changed tool set rebuilds (LanguageModelSession fixes tools at init)', () async {
      fake.onGenerate = (g) {
        g.text('a');
        g.finish();
      };
      final (e1, _) = await collect(provider.stream(req([user('u1', 'Hi')])));
      await collect(
        provider.stream(req([user('u1', 'Hi'), storedReply('a1', e1), user('u2', 'x')], tools: [weatherTool])),
      );
      expect(fake.fmRequests[1].mode, AmHistoryMode.rebuild);
      final tool = fake.fmRequests[1].tools.single;
      expect(tool.name, 'get_weather');
      expect(tool.summary, 'Current weather for a city.');
      final ir = jsonDecode(tool.schemaJson) as Map;
      expect((ir['root'] as Map)['kind'], 'object');
    });

    test('guided generation sends the schema IR', () async {
      fake.onGenerate = (g) {
        g.text('{"title":"x"}');
        g.finish();
      };
      final (events, _) = await collect(
        provider.stream(
          req(
            [user('u1', 'Title?')],
            params: const GenerationParams(
              jsonSchema: {
                'type': 'object',
                'properties': {
                  'title': {'type': 'string'},
                },
                'required': ['title'],
              },
            ),
          ),
        ),
      );
      final ir = jsonDecode(fake.fmRequests.single.responseSchemaJson!) as Map;
      final root = ir['root'] as Map;
      expect(root['name'], 'Response');
      expect(((root['properties'] as List).single as Map)['optional'], isFalse);
      expect(textOf(events), '{"title":"x"}');
    });

    test('more tools than Apple recommends are truncated with a notice', () async {
      fake.onGenerate = (g) => g.finish();
      final tools = [
        for (var i = 0; i < 7; i++)
          ToolDefinition(name: 't$i', description: 'd', inputSchema: const {'type': 'object', 'properties': {}}),
      ];
      final (events, _) = await collect(provider.stream(req([user('u1', 'x')], tools: tools)));
      expect(fake.fmRequests.single.tools, hasLength(5));
      final n = events.whereType<ProviderNotice>().firstWhere((n) => n.code == 'tools_truncated');
      expect(n.data['dropped'], ['t5', 't6']);
    });

    test('errors and refusals', () async {
      for (final (code, kind) in [
        (AppleMlErrorCode.contextOverflow, ProviderErrorKind.contextOverflow),
        (AppleMlErrorCode.rateLimited, ProviderErrorKind.rateLimited),
        (AppleMlErrorCode.busy, ProviderErrorKind.overloaded),
        (AppleMlErrorCode.assetsUnavailable, ProviderErrorKind.unsupported),
        (AppleMlErrorCode.unsupportedLanguage, ProviderErrorKind.invalidRequest),
        (AppleMlErrorCode.timeout, ProviderErrorKind.timeout),
      ]) {
        fake.onGenerate = (g) => g.error(code, 'x');
        final (_, e) = await collect(provider.stream(req([user('u1', 'q')], session: null)));
        expect((e! as ProviderException).kind, kind, reason: code);
      }
      expect(
        const ProviderException(ProviderErrorKind.rateLimited, '').isRetryable,
        isTrue,
        reason: 'background rate limits are retried',
      );

      fake.onGenerate = (g) => g.finish('refusal');
      expect(
        finishOf((await collect(provider.stream(req([user('u1', 'q')], session: null)))).$1).reason,
        FinishReason.refusal,
      );
      fake.onGenerate = (g) => g.finish('guardrail');
      expect(
        finishOf((await collect(provider.stream(req([user('u1', 'q')], session: null)))).$1).reason,
        FinishReason.contentFilter,
      );
    });

    test('an error invalidates the session: the next request rebuilds', () async {
      fake.onGenerate = (g) {
        g.text('Hi');
        g.finish();
      };
      final (e1, _) = await collect(provider.stream(req([user('u1', 'Hello')])));
      fake.onGenerate = (g) => g.error(AppleMlErrorCode.server, 'decoding failure');
      await collect(provider.stream(req([user('u1', 'Hello'), storedReply('a1', e1), user('u2', 'x')])));
      fake.onGenerate = (g) => g.finish();
      await collect(provider.stream(req([user('u1', 'Hello'), storedReply('a1', e1), user('u2', 'x')])));
      expect(fake.fmRequests.last.mode, AmHistoryMode.rebuild);
    });

    test('sessionLost on append is retried once as a rebuild', () async {
      fake.onGenerate = (g) {
        g.text('Hi');
        g.finish();
      };
      final (e1, _) = await collect(provider.stream(req([user('u1', 'Hello')])));
      fake.generateError = PlatformException(code: AppleMlErrorCode.sessionLost);
      final (_, err) = await collect(
        provider.stream(req([user('u1', 'Hello'), storedReply('a1', e1), user('u2', 'x')])),
      );
      expect(err, isNull);
      expect(fake.fmRequests.last.mode, AmHistoryMode.rebuild);
      expect(fake.fmRequests.last.history, hasLength(2));
    });

    test('cancel stops the native response', () async {
      fake.onGenerate = (g) => g.text('partial');
      final token = CancellationToken();
      final events = <ModelEvent>[];
      final done = provider.stream(req([user('u1', 'q')]), cancel: token).listen(events.add).asFuture<void>();
      await until(() => events.isNotEmpty);
      token.cancel();
      await done;
      expect(fake.cancels, isNotEmpty);
      expect(finishOf(events).reason, FinishReason.cancelled);
    });
  });

  group('tool round trip (Swift Tool.call suspended until Dart answers)', () {
    test('request → Finish(toolCalls) → results resume the SAME native turn → final answer → append', () async {
      fake.onGenerate = (g) {
        g.text('Let me check. ');
        g.toolRequest('fm_1', 'get_weather', '{"city":"Paris"}');
        // Swift now waits in Tool.call; when Dart answers, the model goes on.
        unawaited(
          g.toolResults.then((results) {
            expect(results.single.callId, 'fm_1');
            expect(results.single.output, '22 °C');
            expect(results.single.isError, isFalse);
            g.text('It is 22 °C.');
            g.info(prompt: 80, generated: 6);
            g.finish();
          }),
        );
      };
      final m1 = [user('u1', 'Weather in Paris?')];
      final (e1, err1) = await collect(provider.stream(req(m1, tools: [weatherTool])));
      expect(err1, isNull);
      expect(textOf(e1), 'Let me check. ');
      final call = e1.whereType<ToolCallComplete>().single.call;
      expect((call.id, call.name), ('fm_1', 'get_weather'));
      expect(call.arguments, {'city': 'Paris'});
      expect(finishOf(e1).reason, FinishReason.toolCalls);
      expect(fake.cancels, isEmpty, reason: 'the native turn stays suspended');
      expect(fake.fmRequests, hasLength(1));

      // The agent loop ran the tool (approvals and all) and asks again.
      final a1 = storedReply('a1', e1);
      final m2 = [...m1, a1, toolResult('t1', 'fm_1', 'get_weather', '22 °C')];
      final (e2, err2) = await collect(provider.stream(req(m2, tools: [weatherTool])));
      expect(err2, isNull);
      expect(fake.fmRequests, hasLength(1), reason: 'resumed, not regenerated');
      expect(fake.submittedToolResults.single.$1, 'fmgen_1');
      expect(textOf(e2), 'It is 22 °C.');
      expect(finishOf(e2).reason, FinishReason.stop);
      expect(e2.whereType<UsageUpdate>(), hasLength(1));

      // The native transcript now ends with that answer: the next turn appends.
      fake.onGenerate = (g) => g.finish();
      await collect(provider.stream(req([...m2, storedReply('a2', e2), user('u2', 'Thanks')], tools: [weatherTool])));
      expect(fake.fmRequests[1].mode, AmHistoryMode.append);
      expect(fake.fmRequests[1].prompt, 'Thanks');
    });

    test('parallel tool requests settle into one Finish(toolCalls); errors go back as text', () async {
      late FakeGeneration gen;
      fake.onGenerate = (g) {
        gen = g;
        g.toolRequest('fm_a', 'get_weather', '{"city":"Rome"}');
        g.toolRequest('fm_b', 'get_weather', '{"city":"Oslo"}');
      };
      final (e1, _) = await collect(provider.stream(req([user('u1', 'Rome and Oslo?')], tools: [weatherTool])));
      expect(e1.whereType<ToolCallComplete>().map((e) => e.call.id), ['fm_a', 'fm_b']);
      expect(e1.whereType<ToolCallComplete>().map((e) => e.index), [0, 1]);
      final results = gen.toolResults;
      final m2 = [
        user('u1', 'Rome and Oslo?'),
        storedReply('a1', e1),
        toolResult('t1', 'fm_a', 'get_weather', 'sunny'),
        toolResult('t2', 'fm_b', 'get_weather', 'denied by user', isError: true),
      ];
      final second = collect(provider.stream(req(m2, tools: [weatherTool])));
      final submitted = await results;
      expect(submitted.map((r) => (r.callId, r.isError)), [('fm_a', false), ('fm_b', true)]);
      expect(submitted[1].output, '[tool error] denied by user');
      gen.text('Rome is sunny; I could not check Oslo.');
      gen.finish();
      final (e2, _) = await second;
      expect(finishOf(e2).reason, FinishReason.stop);
    });

    test('a request that does not answer the suspended call cancels that turn and rebuilds', () async {
      fake.onGenerate = (g) => g.toolRequest('fm_1', 'get_weather', '{"city":"Paris"}');
      final (e1, _) = await collect(provider.stream(req([user('u1', 'Weather?')], tools: [weatherTool])));
      expect(finishOf(e1).reason, FinishReason.toolCalls);
      fake.onGenerate = (g) => g.finish();
      // The user edited the question instead (a new branch).
      final (e2, _) = await collect(provider.stream(req([user('u1b', 'Never mind, hi')], tools: [weatherTool])));
      expect(fake.cancels, ['fmgen_1']);
      expect(e2.whereType<ProviderNotice>().map((n) => n.code), contains('fm_tool_turn_abandoned'));
      expect(fake.fmRequests[1].mode, AmHistoryMode.rebuild);
      expect(fake.submittedToolResults, isEmpty);
    });

    test('a suspended turn holds its credits, also with an MLX provider on the same backend', () async {
      final mlx = MlxProvider(backend: fake); // shares the event stream
      late FakeGeneration gen;
      fake.onGenerate = (g) {
        gen = g;
        g.toolRequest('fm_1', 'get_weather', '{}');
      };
      await collect(provider.stream(req([user('u1', 'Weather?')], tools: [weatherTool])));
      // Swift keeps streaming (e.g. text after the call) while Dart is between
      // streams: nobody may ack, so at most 4 batches are in flight.
      for (var i = 0; i < 10; i++) {
        gen.notice('n$i', 'x');
        await pumpEventQueue();
      }
      expect(gen.outstanding, lessThanOrEqualTo(4));
      expect(gen.queued, greaterThan(0), reason: 'the rest waits natively');
      await mlx.dispose();
    });

    test('an unanswered suspended call expires', () async {
      final quick = make(config: const FmProviderConfig(toolResultTimeout: Duration(milliseconds: 30)));
      fake.onGenerate = (g) => g.toolRequest('fm_1', 'get_weather', '{}');
      await collect(quick.stream(req([user('u1', 'Weather?')], tools: [weatherTool])));
      await until(() => fake.cancels.contains('fmgen_1'));
      await quick.dispose();
    });

    test('tool results without a live turn (e.g. after a restart) rebuild with a continue prompt', () async {
      fake.onGenerate = (g) => g.finish();
      final call = ToolCall(
        id: 'fm_9',
        name: 'get_weather',
        arguments: const {'city': 'Rome'},
        rawArguments: '{"city":"Rome"}',
      );
      final (events, _) = await collect(
        provider.stream(
          req(
            [
              user('u1', 'Weather?'),
              assistant('a1', '', calls: [call]),
              toolResult('t1', 'fm_9', 'get_weather', 'sunny'),
            ],
            tools: [weatherTool],
          ),
        ),
      );
      final r = fake.fmRequests.single;
      expect(r.mode, AmHistoryMode.rebuild);
      expect([for (final m in r.history) m.role], ['user', 'assistant', 'tool']);
      expect(r.history[1].toolCalls!.single.id, 'fm_9');
      expect(r.prompt, const FmProviderConfig().continuePrompt);
      expect(events.whereType<ProviderNotice>().map((n) => n.code), contains('fm_synthetic_prompt'));
    });
  });

  test('forgetConversation and prewarm reach Swift', () async {
    await provider.prewarm(instructions: 'Be brief.');
    expect(fake.prewarms, ['Be brief.']);
    await provider.forgetConversation('s1');
    expect(fake.drops.single, (AmEngine.foundationModels, 's1'));
  });
}
