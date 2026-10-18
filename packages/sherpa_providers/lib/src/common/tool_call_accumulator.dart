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
///   to [ToolCall.argumentsError] rather than an exception.
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
  List<ModelEvent> addChatDeltas(List<Object?> toolCalls) {
    final out = <ModelEvent>[];
    for (final raw in toolCalls) {
      final tc = asJsonMap(raw);
      if (tc != null) out.addAll(_addChatDelta(tc));
    }
    return out;
  }

  List<ModelEvent> _addChatDelta(JsonMap tc) {
    final index = tc.integer('index');
    final id = tc.text('id');
    final fn = tc.child('function') ?? const <String, Object?>{};
    final name = fn.text('name')?.trim();
    final args = _argumentText(fn['arguments']);

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

  static String? _argumentText(Object? a) => switch (a) {
        String() => a,
        // Non-compliant servers send the arguments object itself.
        Map() || List() => jsonEncode(a),
        _ => null,
      };

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
  List<ModelEvent> completeAll() => [
        for (final slot in _slots)
          if (!slot.completed) ..._complete(slot),
      ];

  List<ModelEvent> _complete(_Slot slot) {
    final out = <ModelEvent>[];
    if (!slot.started) out.addAll(_start(slot));
    slot.completed = true;
    final raw = slot.args.toString();
    final parsed = ToolArgumentsRepair.parseArguments(raw);
    final missingName = slot.wireName == null;
    final call = ToolCall(
      id: slot.id!,
      name: _resolveName(slot.wireName ?? ''),
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
