import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_inference/sherpa_inference.dart';
import 'package:sherpa_inference/testing.dart';

void main() {
  group('EngineEventMapper', () {
    test('maps a full reply with a tool call', () {
      final m = EngineEventMapper(providerId: 'llama_cpp');
      final out = [
        for (final e in [
          const EngineEvent(type: EngineEventType.reasoningDelta, text: 'think'),
          ...fakeReply('Hi', promptTokens: 30, cachedTokens: 12, toolCalls: [(id: 'c1', name: 'f', args: '{"a":1}')]),
        ])
          ...m.map(e),
      ];
      expect(out[0], isA<ReasoningDelta>().having((d) => d.text, 'text', 'think'));
      expect(out[1], isA<TextDelta>().having((d) => d.text, 'text', 'Hi'));
      expect(out[2], isA<ToolCallStart>().having((s) => s.name, 'name', 'f'));
      expect(out[3], isA<ToolCallArgsDelta>().having((d) => d.fragment, 'fragment', '{"a":1}'));
      final done = out[4] as ToolCallComplete;
      expect(done.call.arguments, {'a': 1});
      expect(done.call.rawArguments, '{"a":1}');
      expect(done.call.isValid, isTrue);
      final usage = (out[5] as UsageUpdate).usage;
      expect(usage.inputTokens, 18, reason: 'uncached prompt tokens');
      expect(usage.cacheReadTokens, 12);
      expect(usage.inputTokens + usage.cacheReadTokens, 30);
      final perf = out[6] as PerfSample;
      expect(perf.promptTokens, 30);
      expect(perf.cachedPromptTokens, 12);
      expect(perf.backend, 'CPU');
      expect(perf.draftAcceptRate, isNull, reason: 'nothing was drafted');
      expect(out[7], isA<Finish>().having((f) => f.reason, 'reason', FinishReason.toolCalls));
      expect(m.finished, isTrue);
      expect(m.usage, usage);
    });

    test('finish reasons', () {
      FinishReason reason(int code) =>
          (EngineEventMapper(providerId: 'p').map(EngineEvent(type: EngineEventType.finish, code: code)).single as Finish)
              .reason;
      expect(reason(SeFinishCodes.stop), FinishReason.stop);
      expect(reason(SeFinishCodes.length), FinishReason.length);
      expect(reason(SeFinishCodes.toolCalls), FinishReason.toolCalls);
      expect(reason(SeFinishCodes.cancelled), FinishReason.cancelled);
    });

    test('ERROR + FINISH(error) becomes a ProviderException with the mapped kind', () {
      ProviderErrorKind kindFor(int status) {
        final m = EngineEventMapper(providerId: 'p');
        try {
          for (final e in fakeError(status, 'msg $status')) {
            m.map(e);
          }
        } on ProviderException catch (e) {
          expect(e.message, 'msg $status');
          expect(e.providerId, 'p');
          return e.kind;
        }
        fail('no exception');
      }

      expect(kindFor(-2), ProviderErrorKind.outOfMemory); // SE_ERR_OOM
      expect(kindFor(-5), ProviderErrorKind.outOfMemory); // SE_ERR_CONTEXT_CREATE
      expect(kindFor(-6), ProviderErrorKind.contextOverflow); // SE_ERR_CONTEXT_FULL
      expect(kindFor(-9), ProviderErrorKind.invalidRequest); // SE_ERR_TEMPLATE
      expect(kindFor(-10), ProviderErrorKind.invalidRequest); // SE_ERR_GRAMMAR
      expect(kindFor(-14), ProviderErrorKind.unsupported);
      expect(kindFor(-8), ProviderErrorKind.server); // SE_ERR_DECODE
      expect(kindFor(-99), ProviderErrorKind.unknown);
    });

    test('tool arguments: strict, repaired, invalid', () {
      expect(EngineEventMapper.parseToolCall('i', 'n', '').arguments, isEmpty);
      final repaired = EngineEventMapper.parseToolCall('i', 'n', "{'city': 'Paris',}");
      expect(repaired.repaired, isTrue);
      expect(repaired.arguments, {'city': 'Paris'});
      final notObject = EngineEventMapper.parseToolCall('i', 'n', '[1,2]');
      expect(notObject.isValid, isFalse);
      final broken = EngineEventMapper.parseToolCall('i', 'n', '}}}');
      expect(broken.isValid, isFalse);
      expect(broken.rawArguments, '}}}');
    });

    test('prompt progress becomes a notice', () {
      final out = EngineEventMapper(providerId: 'p')
          .map(const EngineEvent(type: EngineEventType.promptProgress, progressDone: 256, progressTotal: 1000));
      expect(out.single, isA<ProviderNotice>().having((n) => n.data['done'], 'done', 256));
    });
  });

  group('providerErrorFor', () {
    test('engine crashes and stale handles are engineCrashed (retryable)', () {
      final crash = providerErrorFor(const EngineCrashedException('gone'), providerId: 'p');
      expect(crash.kind, ProviderErrorKind.engineCrashed);
      expect(crash.isRetryable, isTrue);
      expect(providerErrorFor(const StaleHandleException(ModelRef(1, 0)), providerId: 'p').kind,
          ProviderErrorKind.engineCrashed);
      expect(providerErrorFor(const EngineException(-2, 'oom'), providerId: 'p').kind, ProviderErrorKind.outOfMemory);
      expect(providerErrorFor(StateError('x'), providerId: 'p').kind, ProviderErrorKind.unknown);
    });
  });

  group('EventCoalescer', () {
    test('merges adjacent deltas of the same kind, keeps order and everything else', () {
      final pending = <EngineEvent>[];
      for (final e in [
        const EngineEvent.text('a'),
        const EngineEvent.text('b'),
        const EngineEvent(type: EngineEventType.reasoningDelta, text: 'r1'),
        const EngineEvent(type: EngineEventType.reasoningDelta, text: 'r2'),
        const EngineEvent.text('c'),
        const EngineEvent(type: EngineEventType.toolCallStart, index: 0, id: 'x', name: 'f'),
        const EngineEvent(type: EngineEventType.toolCallArgsDelta, index: 0, text: '{"a"'),
        const EngineEvent(type: EngineEventType.toolCallArgsDelta, index: 0, text: ':1}'),
        const EngineEvent(type: EngineEventType.toolCallArgsDelta, index: 1, text: '{}'),
        const EngineEvent(type: EngineEventType.promptProgress, progressDone: 1, progressTotal: 9),
        const EngineEvent(type: EngineEventType.promptProgress, progressDone: 5, progressTotal: 9),
        const EngineEvent(type: EngineEventType.usage, promptTokens: 3),
        const EngineEvent(type: EngineEventType.finish, code: 1),
      ]) {
        EventCoalescer.append(pending, e);
      }
      expect(pending.map((e) => e.type), [
        EngineEventType.textDelta,
        EngineEventType.reasoningDelta,
        EngineEventType.textDelta,
        EngineEventType.toolCallStart,
        EngineEventType.toolCallArgsDelta,
        EngineEventType.toolCallArgsDelta,
        EngineEventType.promptProgress,
        EngineEventType.usage,
        EngineEventType.finish,
      ]);
      expect(pending[0].text, 'ab');
      expect(pending[1].text, 'r1r2');
      expect(pending[4].text, '{"a":1}');
      expect(pending[5].index, 1);
      expect(pending[6].progressDone, 5);
    });

    test('never merges across generations', () {
      final pending = <EngineEvent>[];
      EventCoalescer.append(pending, const EngineEvent.text('a', generationId: 1));
      EventCoalescer.append(pending, const EngineEvent.text('b', generationId: 2));
      expect(pending, hasLength(2));
    });
  });
}

/// `se_finish_reason` values (header).
abstract final class SeFinishCodes {
  static const stop = 1;
  static const length = 2;
  static const toolCalls = 3;
  static const cancelled = 4;
}
