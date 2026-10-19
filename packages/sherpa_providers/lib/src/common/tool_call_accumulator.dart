import 'dart:convert';

import 'package:sherpa_core/sherpa_core.dart';

import 'json_read.dart';
import 'json_repair.dart';

/// One tool call being assembled from stream fragments.
final class _Slot {
  _Slot(this.ordinal);

  /// Position among this response's calls; the index Sherpa reports, so
  /// parallel calls get distinct 0..n indexes whatever the server used.
  final int ordinal;
  String? id;

  /// Whether [id] came from the server (a synthesized one must not make a
  /// later server id look like a different call).
  bool serverId = false;
  String? wireName;
  final StringBuffer args = StringBuffer();

  /// Argument text received before the name (emitted after the start).
  final StringBuffer pending = StringBuffer();
  bool started = false;
  bool completed = false;
}

/// Assembles streamed tool calls into [ToolCallStart] / [ToolCallArgsDelta]
/// events (for live UI) and one [ToolCallComplete] per call at the end.
///
/// The merge rules follow R10 §3.4 and are deliberately defensive:
/// * fragments are keyed by the server's `index`, and one chunk may carry
///   several fragments for the same index (openai-python `_deltas.py`);
/// * whole calls in one chunk (Ollama, vLLM `hf` parser) work naturally;
/// * names are set once and never concatenated, because LM Studio 0.3.16
///   appended an empty name after the first packet and other servers
///   resend the full name with every fragment;
/// * a missing `index` falls back to the `id`, then to the last open call;
/// * an index reused for a second call (new id or a different name after
///   arguments were received) opens a new call;
/// * missing ids are synthesized via [newId] (stable for the call's life);
/// * argument text is parsed with [ToolArgumentsRepair] at completion; failures go
///   to [ToolCall.argumentsError] rather than an exception;
/// * in a turn that was cut off (see [completeAll]'s `cutoff`), argument
///   text that is not strict JSON is reported as truncated, never repaired.
///
/// The same slot API serves the Responses adapter, which keys calls by
/// `output_index` and knows names up front.
final class ToolCallAccumulator {
  ToolCallAccumulator({required String Function(int ordinal) newId, String Function(String wireName)? resolveName})
      : _newId = newId,
        _resolveName = resolveName ?? _identity;

  static String _identity(String s) => s;

  final String Function(int ordinal) _newId;
  final String Function(String wireName) _resolveName;
  final List<_Slot> _slots = [];
  final Map<Object, _Slot> _byKey = {};
  final Map<String, _Slot> _byId = {};
  _Slot? _lastOpen;

  bool get isEmpty => _slots.isEmpty;

  int get length => _slots.length;

  /// Merges one chunk's `delta.tool_calls` array (OpenAI Chat semantics).
  ///
  /// [rawEvent] is the event's JSON text and [path] the location of
  /// [toolCalls] in it (`['choices', 0, 'delta', 'tool_calls']`). When a
  /// non-compliant server sends `function.arguments` as an object rather
  /// than a string, decoding the event has already collapsed its duplicate
  /// keys, so the call's argument text is taken from [rawEvent] instead and
  /// strict mode still refuses them. Without [rawEvent] such an object is
  /// re-encoded (duplicates are then lost). String arguments never look at
  /// [rawEvent].
  List<ModelEvent> addChatDeltas(List<Object?> toolCalls, {String? rawEvent, List<Object> path = const []}) {
    final out = <ModelEvent>[];
    for (var k = 0; k < toolCalls.length; k++) {
      final tc = asJsonMap(toolCalls[k]);
      if (tc != null) out.addAll(_addChatDelta(tc, rawEvent, path, k));
    }
    return out;
  }

  List<ModelEvent> _addChatDelta(JsonMap tc, String? rawEvent, List<Object> path, int position) {
    final index = tc.integer('index');
    final id = tc.text('id');
    final fn = tc.child('function') ?? const <String, Object?>{};
    final name = fn.text('name')?.trim();
    final a = fn['arguments'];
    final args = switch (a) {
      String() => a,
      // Non-compliant servers send the arguments object itself.
      Map() || List() =>
        ToolArgumentsRepair.objectArgumentsText(a, rawEvent, [...path, position, 'function', 'arguments']),
      _ => null,
    };

    final slot = _slotForChatDelta(index, id, name);
    if (id != null && slot.id == null && !slot.started) {
      slot
        ..id = id
        ..serverId = true;
    }
    if (id != null) _byId.putIfAbsent(id, () => slot);
    if (name != null && name.isNotEmpty && slot.wireName == null) slot.wireName = name;
    _lastOpen = slot;
    return _feed(slot, args);
  }

  _Slot _slotForChatDelta(int? index, String? id, String? name) {
    if (index != null) {
      final existing = _byKey[index];
      if (existing != null && !_isNewCallOn(existing, id, name)) return existing;
      final slot = _open();
      _byKey[index] = slot;
      return slot;
    }
    if (id != null) return _byId[id] ?? _open();
    return _lastOpen ?? _open();
  }

  /// Some compat proxies reuse index 0 for every call. A different id, or a
  /// different non-empty name once arguments have streamed, can only mean
  /// a new call; a repeated identical name (LM Studio) cannot.
  bool _isNewCallOn(_Slot slot, String? id, String? name) {
    if (slot.completed) return true;
    final hasArgs = slot.args.isNotEmpty || slot.pending.isNotEmpty;
    if (id != null && slot.serverId && id != slot.id && hasArgs) return true;
    if (name != null && name.isNotEmpty && slot.wireName != null && name != slot.wireName && hasArgs) return true;
    return false;
  }

  _Slot _open() {
    final slot = _Slot(_slots.length);
    _slots.add(slot);
    return slot;
  }

  List<ModelEvent> _feed(_Slot slot, String? args) {
    final out = <ModelEvent>[];
    if (!slot.started && slot.wireName != null) out.addAll(_start(slot));
    if (args != null && args.isNotEmpty) {
      if (slot.started) {
        slot.args.write(args);
        out.add(ToolCallArgsDelta(index: slot.ordinal, fragment: args));
      } else {
        slot.pending.write(args);
      }
    }
    return out;
  }

  List<ModelEvent> _start(_Slot slot) {
    slot.started = true;
    slot.id ??= _newId(slot.ordinal);
    final out = <ModelEvent>[
      ToolCallStart(index: slot.ordinal, id: slot.id!, name: _resolveName(slot.wireName ?? '')),
    ];
    if (slot.pending.isNotEmpty) {
      final p = slot.pending.toString();
      slot.pending.clear();
      slot.args.write(p);
      out.add(ToolCallArgsDelta(index: slot.ordinal, fragment: p));
    }
    return out;
  }

  /// Opens a call whose identity is known up front (Responses
  /// `response.output_item.added` with `call_id` and `name`).
  List<ModelEvent> open(Object key, {String? id, String? name, String? arguments}) {
    final existing = _byKey[key];
    if (existing != null && !existing.completed) {
      if (existing.wireName == null && name != null && name.isNotEmpty) existing.wireName = name;
      if (existing.id == null && id != null && id.isNotEmpty && !existing.started) {
        existing
          ..id = id
          ..serverId = true;
      }
      return _feed(existing, arguments);
    }
    final hasId = id != null && id.isNotEmpty;
    final slot = _open()
      ..id = hasId ? id : null
      ..serverId = hasId
      ..wireName = (name == null || name.isEmpty) ? null : name;
    _byKey[key] = slot;
    _lastOpen = slot;
    return _feed(slot, arguments);
  }

  /// Appends an argument fragment to the call opened under [key].
  List<ModelEvent> append(Object key, String fragment) {
    final slot = _byKey[key] ?? (() {
      final s = _open();
      _byKey[key] = s;
      return s;
    })();
    if (slot.completed) return const [];
    return _feed(slot, fragment);
  }

  /// Replaces the accumulated arguments with the authoritative final text
  /// (Responses `.done` events), in case a delta was lost or reordered.
  void setArguments(Object key, String full) {
    final slot = _byKey[key];
    if (slot == null || slot.completed) return;
    final current = slot.started ? slot.args.toString() : slot.pending.toString();
    if (current == full) return;
    final target = slot.started ? slot.args : slot.pending;
    target
      ..clear()
      ..write(full);
  }

  /// Completes the call opened under [key]; empty when unknown or done.
  List<ModelEvent> complete(Object key) {
    final slot = _byKey[key];
    if (slot == null || slot.completed) return const [];
    return _complete(slot);
  }

  /// Completes every open call in order. Called when the stream finishes.
  ///
  /// [cutoff] says the turn stopped while these calls were still open (Chat
  /// `finish_reason: length`, Responses `incomplete`, or a terminal event
  /// before a call's item finished). Then an open call whose argument text
  /// is not strict JSON is completed with [ToolCallCutoff.errorFor] as its
  /// [ToolCall.argumentsError] rather than repaired: closing the open
  /// strings of a half-written `write_file` would yield a valid call with
  /// silently truncated content. Repair stays for complete turns, where
  /// malformed JSON is a small model's syntax slip, not missing data.
  List<ModelEvent> completeAll({ToolCallCutoff? cutoff}) => [
        for (final slot in _slots)
          if (!slot.completed) ..._complete(slot, cutoff: cutoff),
      ];

  List<ModelEvent> _complete(_Slot slot, {ToolCallCutoff? cutoff}) {
    final out = <ModelEvent>[];
    if (!slot.started) out.addAll(_start(slot));
    slot.completed = true;
    final raw = slot.args.toString();
    final missingName = slot.wireName == null;
    final name = _resolveName(slot.wireName ?? '');
    if (cutoff?.errorFor(raw) case final truncated?) {
      return out
        ..add(ToolCallComplete(
          index: slot.ordinal,
          call: ToolCall(id: slot.id!, name: name, arguments: const {}, rawArguments: raw, argumentsError: truncated),
        ))
        ..add(cutoff!.notice(name, slot.ordinal, raw));
    }
    final parsed = ToolArgumentsRepair.parseArguments(raw);
    final call = ToolCall(
      id: slot.id!,
      name: name,
      arguments: parsed.value ?? const {},
      rawArguments: raw,
      argumentsError: missingName ? 'The tool call had no tool name.' : parsed.error,
      repaired: parsed.repaired,
    );
    out.add(ToolCallComplete(index: slot.ordinal, call: call));
    if (parsed.repaired) {
      out.add(ProviderNotice(
        'tool_args_repaired',
        'Repaired malformed JSON arguments for ${call.name}.',
        data: {'index': slot.ordinal, 'fixes': parsed.fixes.toList()..sort()},
      ));
    }
    return out;
  }
}

/// Why a turn stopped while a tool call's arguments were still streaming.
///
/// Every adapter uses it the same way: a call cut off mid-arguments becomes
/// an invalid call (never a repaired one), with an error the model can act
/// on. The agent runner, for its part, never executes calls from a turn
/// that finished with [FinishReason.length].
enum ToolCallCutoff {
  /// The output-token limit (`max_tokens`, Chat `length`, Responses
  /// `max_output_tokens`).
  tokenLimit('at the output-token limit'),

  /// The server's content filter stopped generating.
  contentFilter("by the server's content filter"),

  /// The context window filled up (Anthropic
  /// `model_context_window_exceeded`).
  contextWindow('when the context window filled up'),

  /// The response ended (or reported another stop) before the call's item
  /// was finished.
  unfinished('before the response finished');

  const ToolCallCutoff(this._where);

  final String _where;

  /// The [ToolCall.argumentsError] for a call whose argument text [raw] was
  /// cut off, or null when [raw] is complete, strict JSON (the call finished
  /// before the cut). Empty text counts as cut off: in a stopped turn it
  /// means the arguments never started.
  String? errorFor(String raw) {
    final String detail;
    if (raw.trim().isEmpty) {
      detail = 'no argument text arrived';
    } else {
      try {
        jsonDecode(raw);
        return null;
      } on FormatException catch (e) {
        detail = 'malformed JSON: ${e.message}';
      }
    }
    final hint = this == tokenLimit ? ' Retry with shorter arguments, for example by splitting a large write into parts.' : '';
    return 'The tool call arguments were truncated $_where ($detail), so the call was not run.$hint';
  }

  /// Tells the UI that call [index] ([name]) was dropped as truncated.
  ProviderNotice notice(String name, int index, String raw) => ProviderNotice(
        'tool_args_truncated',
        'The arguments for ${name.isEmpty ? 'a tool call' : name} were cut off $_where, so the call will not run.',
        data: {'index': index, 'cutoff': this.name, 'rawLength': raw.length},
      );
}
