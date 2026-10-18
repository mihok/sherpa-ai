import 'dart:async';
import 'dart:convert';

import '../common/cancellation.dart';
import '../model/message.dart';
import '../model/tool.dart';
import '../provider/capabilities.dart';
import '../provider/model_event.dart';
import '../provider/model_provider.dart';

/// One scripted model turn: either a fixed list of events or a function of
/// the request (so a script can branch on what the agent actually sent).
final class ScriptedTurn {
  ScriptedTurn(List<ModelEvent> events, {this.error}) : _build = ((_) => events);

  ScriptedTurn.dynamic(List<ModelEvent> Function(ModelRequest request) build)
      : _build = build,
        error = null;

  /// A plain text reply split into word-sized deltas.
  factory ScriptedTurn.text(String text, {Usage usage = const Usage(inputTokens: 10, outputTokens: 10)}) =>
      ScriptedTurn([
        for (final chunk in splitForStreaming(text)) TextDelta(chunk),
        UsageUpdate(usage),
        const Finish(FinishReason.stop),
      ]);

  /// One or more tool calls, streamed as start + argument fragments + complete.
  factory ScriptedTurn.toolCalls(List<ToolCall> calls, {String? preamble}) => ScriptedTurn([
        if (preamble != null) TextDelta(preamble),
        for (final (i, c) in calls.indexed) ...[
          ToolCallStart(index: i, id: c.id, name: c.name),
          for (final f in splitForStreaming(jsonEncode(c.arguments), size: 7))
            ToolCallArgsDelta(index: i, fragment: f),
          ToolCallComplete(index: i, call: c),
        ],
        const UsageUpdate(Usage(inputTokens: 20, outputTokens: 15)),
        const Finish(FinishReason.toolCalls),
      ]);

  /// Fails the stream with [error] after emitting [before].
  factory ScriptedTurn.error(Object error, {List<ModelEvent> before = const []}) =>
      ScriptedTurn(before, error: error);

  final List<ModelEvent> Function(ModelRequest request) _build;

  /// Delivered as a stream error after the events, when set.
  final Object? error;

  List<ModelEvent> eventsFor(ModelRequest request) => _build(request);
}

/// Splits text into small chunks to mimic token streaming.
List<String> splitForStreaming(String text, {int size = 4}) {
  if (text.isEmpty) return const [];
  final out = <String>[];
  for (var i = 0; i < text.length; i += size) {
    out.add(text.substring(i, i + size > text.length ? text.length : i + size));
  }
  return out;
}

/// Deterministic [ModelProvider] that replays scripted turns in order and
/// records every request, so agent-loop tests and evals can assert on
/// exactly what the model was shown.
///
/// [eventDelay] spaces events out (with a fake async gap) so tests can
/// cancel or pause mid-stream.
final class ScriptedProvider implements ModelProvider {
  ScriptedProvider(
    List<ScriptedTurn> turns, {
    this.capabilitiesValue = const ModelCapabilities(contextLength: 32768),
    this.eventDelay = Duration.zero,
    ProviderInfo? info,
  })  : _turns = [...turns],
        info = info ??
            const ProviderInfo(
              id: 'scripted',
              kind: ProviderKind.fake,
              displayName: 'Scripted',
              location: ExecutionLocation.onDevice,
            );

  @override
  final ProviderInfo info;
  final ModelCapabilities capabilitiesValue;
  final Duration eventDelay;
  final List<ScriptedTurn> _turns;

  final List<ModelRequest> requests = [];

  /// Number of streams whose subscription was cancelled before finishing.
  int cancelledStreams = 0;

  int get remainingTurns => _turns.length;

  void enqueue(ScriptedTurn turn) => _turns.add(turn);

  @override
  Future<List<ModelDescriptor>> listModels() async => [
        ModelDescriptor(
          id: 'scripted-model',
          providerId: info.id,
          displayName: 'Scripted model',
          capabilities: capabilitiesValue,
        ),
      ];

  @override
  Future<ModelCapabilities> capabilities(String modelId) async => capabilitiesValue;

  @override
  Stream<ModelEvent> stream(ModelRequest request, {CancellationToken? cancel}) {
    late final StreamController<ModelEvent> controller;
    var cancelled = false;
    Future<void> run() async {
      requests.add(request);
      if (_turns.isEmpty) {
        controller.addError(StateError('ScriptedProvider: no scripted turn left for request '
            '#${requests.length}'));
        await controller.close();
        return;
      }
      final turn = _turns.removeAt(0);
      final events = turn.eventsFor(request);
      for (final e in events) {
        if (cancelled) return;
        if (cancel?.isCancelled ?? false) {
          controller.add(const Finish(FinishReason.cancelled));
          await controller.close();
          return;
        }
        if (eventDelay > Duration.zero) {
          await Future<void>.delayed(eventDelay);
        } else {
          await Future<void>.value();
        }
        if (cancelled) return;
        controller.add(e);
      }
      if (turn.error != null && !cancelled) {
        await Future<void>.value();
        controller.addError(turn.error!);
      }
      await controller.close();
    }

    controller = StreamController<ModelEvent>(
      onListen: () => unawaited(run()),
      // Returning a future matters: under fake async (widget tests) a void
      // onCancel leaves the runner's `await sub.cancel()` pending forever.
      onCancel: () async {
        if (!controller.isClosed) cancelledStreams++;
        cancelled = true;
      },
    );
    return controller.stream;
  }
}
