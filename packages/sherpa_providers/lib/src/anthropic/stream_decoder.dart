import 'dart:convert';

import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_net/sherpa_net.dart';

import 'errors.dart';
import 'tool_names.dart';

/// Turns Anthropic Messages SSE events into [ModelEvent]s.
///
/// Pure and synchronous (one SSE event in, zero or more model events out),
/// so golden fixtures can drive it without HTTP.
///
/// Ordering contract with `AgentRunner`'s accumulator: the runner builds
/// the assistant message from events in arrival order, attaching each
/// [ReasoningSignature] to the preceding unsigned reasoning segment. Since
/// Anthropic requires thinking blocks to be echoed back exactly and in
/// order, this decoder:
/// * emits a thinking block's signature once, at `content_block_stop`;
/// * emits a redacted block as `ReasoningSignature(redactedData:)`;
/// * inserts an empty [TextDelta] as a segment separator before a thinking
///   block that follows a redacted block, which the accumulator would
///   otherwise merge into one part (see the report's contract notes);
/// * numbers tool calls 0..n per message (block indexes include thinking
///   and text blocks, R10 F4 note).
///
/// Tool calls are held back until `message_delta` reveals the stop reason:
/// a `refusal` must never run the turn's tools (R10 §7.6), and the runner
/// turns every started call into a tool call. To keep block order intact,
/// everything after the first `tool_use` block is deferred together.
final class AnthropicStreamDecoder {
  AnthropicStreamDecoder({
    required this.providerId,
    this.toolNames = AnthropicToolNames.empty,
    this.requestedModel,
  });

  final String providerId;
  final AnthropicToolNames toolNames;

  /// When set, a `message_start` naming another model (server-side
  /// fallback) is reported with a notice.
  final String? requestedModel;

  final Map<int, _Block> _blocks = {};
  int _nextToolIndex = 0;

  /// Events after the first tool_use block, released at `message_delta`.
  List<ModelEvent>? _deferred;

  /// True while the accumulator's last segment is reasoning without a
  /// signature (an open thinking block, or a redacted block).
  bool _openReasoning = false;

  int _input = 0;
  int _cacheWrite = 0;
  int _cacheRead = 0;
  int _output = 0;
  int _thinkingTokens = 0;
  bool _sawUsage = false;

  String? _stopReason;
  String? _stopSequence;
  JsonMap? _stopDetails;
  String? _messageId;
  String? _model;
  bool _done = false;

  /// The message reached `message_stop` (the [Finish] was emitted).
  bool get isDone => _done;

  String? get stopReason => _stopReason;
  String? get stopSequence => _stopSequence;
  String? get messageId => _messageId;

  /// Totals so far, in core terms: `inputTokens` is every prompt token that
  /// was not a cache read (uncached + cache writes), so `inputTokens +
  /// cacheReadTokens` is the whole prompt, matching how the runner
  /// calibrates its estimator. `cacheWriteTokens` is the written subset.
  Usage get usage => Usage(
        inputTokens: _input + _cacheWrite,
        outputTokens: _output,
        cacheReadTokens: _cacheRead,
        cacheWriteTokens: _cacheWrite,
        reasoningTokens: _thinkingTokens,
      );

  /// Decodes one SSE event. Throws [AnthropicStreamFailure] for `error`
  /// frames and malformed data.
  List<ModelEvent> add(SseEvent sse) {
    if (_done) return const [];
    if (sse.data.isEmpty) return const [];
    final JsonMap data;
    try {
      final decoded = jsonDecode(sse.data);
      if (decoded is! Map) throw const FormatException('event data is not an object');
      data = decoded.cast<String, Object?>();
    } on FormatException catch (e) {
      final out = _Out(this);
      _release(out, dropToolCalls: true);
      throw AnthropicStreamFailure(
        out.events,
        ProviderException(
          ProviderErrorKind.server,
          'Anthropic sent a malformed stream event (${e.message})',
          providerId: providerId,
          cause: e,
        ),
      );
    }
    final type = data['type']?.toString() ?? sse.event;
    final out = _Out(this);
    switch (type) {
      case 'message_start':
        _messageStart(data.optObj('message') ?? const {}, out);
      case 'content_block_start':
        _blockStart(data.optInt('index') ?? -1, data.optObj('content_block') ?? const {}, out);
      case 'content_block_delta':
        _blockDelta(data.optInt('index') ?? -1, data.optObj('delta') ?? const {}, out);
      case 'content_block_stop':
        _blockStop(data.optInt('index') ?? -1, out);
      case 'message_delta':
        _messageDelta(data, out);
      case 'message_stop':
        _finish(out);
      case 'ping':
        break;
      case 'error':
        // Release what the user already saw (minus tool calls) so the runner
        // can keep the partial reply, then fail.
        _release(out, dropToolCalls: true);
        throw AnthropicStreamFailure(out.events, AnthropicErrors.fromStreamError(data, providerId: providerId));
      default:
        // Versioning policy: unknown event types are ignored.
        break;
    }
    return out.events;
  }

  /// Called when the byte stream ends. A stream that stops before
  /// `message_stop` is truncated (retryable network error) unless the stop
  /// reason already arrived, in which case the message is complete enough.
  List<ModelEvent> close() {
    if (_done) return const [];
    final out = _Out(this);
    if (_stopReason == null) {
      _release(out, dropToolCalls: true);
      throw AnthropicStreamFailure(
        out.events,
        ProviderException(
          ProviderErrorKind.network,
          'Anthropic stream ended before message_stop (connection dropped?)',
          providerId: providerId,
        ),
      );
    }
    _finish(out);
    return out.events;
  }

  void _messageStart(JsonMap message, _Out out) {
    _messageId = message.opt<String>('id');
    _model = message.opt<String>('model');
    final requested = requestedModel;
    if (requested != null && _model != null && _model != requested) {
      out.emit(
        ProviderNotice(
          'anthropic.model_fallback',
          'Answered by $_model instead of $requested.',
          data: {'requested': requested, 'served': _model},
        ),
        immediate: true,
      );
    }
    final u = message.optObj('usage');
    if (u != null) {
      _readUsage(u);
      out.emit(UsageUpdate(usage), immediate: true);
    }
  }

  /// The model the server actually used (differs from the request when a
  /// server-side fallback answered).
  String? get model => _model;

  void _blockStart(int index, JsonMap block, _Out out) {
    final type = block['type']?.toString() ?? '';
    switch (type) {
      case 'text':
        _blocks[index] = _Block(_Kind.text);
        final text = block.opt<String>('text') ?? '';
        if (text.isNotEmpty) out.emit(TextDelta(text));
      case 'thinking':
        _blocks[index] = _Block(_Kind.thinking);
        if (_openReasoning) out.emit(const TextDelta(''));
        final text = block.opt<String>('thinking') ?? '';
        if (text.isNotEmpty) out.emit(ReasoningDelta(text));
        final sig = block.opt<String>('signature') ?? '';
        if (sig.isNotEmpty) _blocks[index]!.signature.write(sig);
      case 'redacted_thinking':
        _blocks[index] = _Block(_Kind.redacted);
        out.emit(ReasoningSignature(redactedData: block.opt<String>('data') ?? ''));
      case 'tool_use':
        final b = _Block(_Kind.toolUse)
          ..toolIndex = _nextToolIndex++
          ..id = block.opt<String>('id') ?? 'toolu_missing_$index'
          ..name = toolNames.fromWire(block.opt<String>('name') ?? '')
          ..initialInput = block.optObj('input');
        _blocks[index] = b;
        _deferred ??= [];
        out.emit(ToolCallStart(index: b.toolIndex, id: b.id, name: b.name));
      default:
        // server_tool_use, *_tool_result, fallback markers and future block
        // types. The core has no event for "keep this block verbatim", so
        // they are skipped and reported (see contract notes).
        _blocks[index] = _Block(_Kind.ignored);
        out.emit(
          ProviderNotice(
            type == 'server_tool_use' || type.endsWith('_tool_result')
                ? 'anthropic.server_tool_ignored'
                : 'anthropic.unknown_block',
            'Ignored a "$type" content block that Sherpa does not handle.',
            data: {'type': type, if (block['name'] != null) 'name': block['name']},
          ),
          immediate: true,
        );
    }
  }

  void _blockDelta(int index, JsonMap delta, _Out out) {
    final b = _blocks[index];
    if (b == null) return;
    switch (delta['type']) {
      case 'text_delta':
        final text = delta.opt<String>('text') ?? '';
        if (text.isNotEmpty && b.kind == _Kind.text) out.emit(TextDelta(text));
      case 'thinking_delta':
        final text = delta.opt<String>('thinking') ?? '';
        if (text.isNotEmpty && b.kind == _Kind.thinking) out.emit(ReasoningDelta(text));
      case 'signature_delta':
        if (b.kind == _Kind.thinking) b.signature.write(delta.opt<String>('signature') ?? '');
      case 'input_json_delta':
        final fragment = delta.opt<String>('partial_json') ?? '';
        if (fragment.isEmpty || b.kind != _Kind.toolUse) return;
        b.json.write(fragment);
        out.emit(ToolCallArgsDelta(index: b.toolIndex, fragment: fragment));
      default:
        // citations_delta and unknown deltas carry nothing we replay.
        break;
    }
  }

  void _blockStop(int index, _Out out) {
    final b = _blocks[index];
    if (b == null) return;
    switch (b.kind) {
      case _Kind.thinking:
        // An unsigned block (never seen in practice) stays open; the next
        // thinking block then gets a separator, see [_blockStart].
        final sig = b.signature.toString();
        if (sig.isNotEmpty) out.emit(ReasoningSignature(signature: sig));
      case _Kind.toolUse:
        out.emit(ToolCallComplete(index: b.toolIndex, call: _parseCall(b)));
      case _Kind.text || _Kind.redacted || _Kind.ignored:
        break;
    }
  }

  ToolCall _parseCall(_Block b) {
    final raw = b.json.toString();
    if (raw.trim().isEmpty) {
      // No deltas: the input came whole in content_block_start (or is {}).
      return ToolCall(id: b.id, name: b.name, arguments: b.initialInput ?? const {}, rawArguments: raw);
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return ToolCall(
          id: b.id,
          name: b.name,
          arguments: (normalizeJson(decoded)! as Map).cast<String, Object?>(),
          rawArguments: raw,
        );
      }
      return ToolCall(
        id: b.id,
        name: b.name,
        arguments: const {},
        rawArguments: raw,
        argumentsError: 'tool input must be a JSON object',
      );
    } on FormatException catch (e) {
      // With eager input streaming the server does not validate input; an
      // interrupted or malformed object is reported back to the model.
      return ToolCall(
        id: b.id,
        name: b.name,
        arguments: const {},
        rawArguments: raw,
        argumentsError: 'malformed JSON (${e.message})',
      );
    }
  }

  void _messageDelta(JsonMap data, _Out out) {
    final delta = data.optObj('delta') ?? const {};
    _stopReason = delta.opt<String>('stop_reason') ?? _stopReason;
    _stopSequence = delta.opt<String>('stop_sequence') ?? _stopSequence;
    _stopDetails = delta.optObj('stop_details') ?? _stopDetails;
    final u = data.optObj('usage');
    if (u != null) _readUsage(u);
    final refused = _stopReason == 'refusal';
    _release(out, dropToolCalls: refused);
    if (refused) {
      final d = _stopDetails ?? const {};
      out.emit(ProviderNotice(
        'anthropic.refusal',
        d.opt<String>('explanation') ?? 'The model declined to continue this request.',
        data: compact({'category': d['category'], 'recommendedModel': d['recommended_model']}),
      ));
    }
    if (u != null) out.emit(UsageUpdate(usage));
  }

  void _finish(_Out out) {
    _release(out, dropToolCalls: _stopReason == 'refusal');
    _done = true;
    out.emit(Finish(mapStopReason(_stopReason), rawReason: _stopReason));
  }

  void _release(_Out out, {required bool dropToolCalls}) {
    final held = _deferred;
    if (held == null) return;
    _deferred = null;
    for (final e in held) {
      if (dropToolCalls && (e is ToolCallStart || e is ToolCallArgsDelta || e is ToolCallComplete)) continue;
      out.events.add(e);
    }
  }

  /// Usage is cumulative: later frames override fields they carry.
  void _readUsage(JsonMap u) {
    _sawUsage = true;
    _input = u.optInt('input_tokens') ?? _input;
    _cacheWrite = u.optInt('cache_creation_input_tokens') ?? _cacheWrite;
    _cacheRead = u.optInt('cache_read_input_tokens') ?? _cacheRead;
    _output = u.optInt('output_tokens') ?? _output;
    _thinkingTokens = u.optObj('output_tokens_details')?.optInt('thinking_tokens') ?? _thinkingTokens;
  }

  /// Whether any usage frame arrived.
  bool get hasUsage => _sawUsage;

  /// R10 §10 stop-reason table.
  static FinishReason mapStopReason(String? reason) => switch (reason) {
        'end_turn' || 'stop_sequence' || null => FinishReason.stop,
        'max_tokens' => FinishReason.length,
        'tool_use' => FinishReason.toolCalls,
        'pause_turn' => FinishReason.pause,
        'refusal' => FinishReason.refusal,
        'model_context_window_exceeded' => FinishReason.contextOverflow,
        _ => FinishReason.stop,
      };

  void _track(ModelEvent e) {
    switch (e) {
      case TextDelta() || ToolCallComplete():
        _openReasoning = false;
      case ReasoningDelta():
        _openReasoning = true;
      case ReasoningSignature(:final redactedData):
        _openReasoning = redactedData != null;
      default:
        break;
    }
  }
}

/// Thrown by [AnthropicStreamDecoder] when the stream fails: [before] must
/// be delivered first (partial reasoning/text the user already saw, minus
/// held-back tool calls), then [error] as the stream error.
final class AnthropicStreamFailure implements Exception {
  const AnthropicStreamFailure(this.before, this.error);
  final List<ModelEvent> before;
  final ProviderException error;

  @override
  String toString() => error.toString();
}

/// Collects one call's output, routing through the deferral buffer.
final class _Out {
  _Out(this._d);
  final AnthropicStreamDecoder _d;
  final List<ModelEvent> events = [];

  void emit(ModelEvent e, {bool immediate = false}) {
    _d._track(e);
    final held = _d._deferred;
    if (held != null && !immediate) {
      held.add(e);
    } else {
      events.add(e);
    }
  }
}

enum _Kind { text, thinking, redacted, toolUse, ignored }

final class _Block {
  _Block(this.kind);
  final _Kind kind;
  final StringBuffer signature = StringBuffer();
  final StringBuffer json = StringBuffer();
  int toolIndex = -1;
  String id = '';
  String name = '';
  JsonMap? initialInput;
}
