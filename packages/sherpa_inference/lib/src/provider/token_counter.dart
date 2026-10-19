import 'dart:collection';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../engine/engine_host.dart';
import '../engine/engine_types.dart';
import 'request_mapper.dart';

/// Context-manager decorator that fills the [EngineTokenCounter] cache for
/// the whole request off-isolate before the inner manager counts
/// synchronously (see [EngineTokenCounter]).
final class WarmingContextManager implements ContextManager {
  const WarmingContextManager(this.inner);

  final ContextManager inner;

  @override
  Future<PreparedContext> prepare(ContextRequest request) async {
    final c = request.counter;
    if (c is EngineTokenCounter) {
      try {
        await c.warm(systemPrompt: request.systemPrompt, messages: request.path, tools: request.tools);
      } on Object {
        // Counting falls back to (pessimistic) estimates; the request itself
        // will surface any real engine failure.
      }
    }
    return inner.prepare(request);
  }
}

/// Exact token counts from the model's own tokenizer and chat template.
///
/// [TokenCounter] is synchronous (the context manager sums counts in tight
/// loops), but the engine lives behind an asynchronous [EngineHost] and FFI
/// must not run on the UI isolate. So counts come from a cache that is
/// filled off-isolate:
///
/// * [warm] counts every not-yet-cached message, the system prompt and the
///   tool block in ONE round trip to the engine worker
///   (`se_tokenize` / `se_count_chat_tokens`). [WarmingContextManager] calls
///   it right before each `prepare`, so the ladder's synchronous calls hit
///   the cache; [LlamaCppProvider] also warms with the transcript it just
///   served.
/// * A miss (a message synthesized during `prepare`, e.g. a compaction
///   summary) is answered by [SyncTokenizer] when one was given (direct FFI
///   in the calling isolate, for runners that live off the UI isolate), and
///   otherwise by a deliberately pessimistic estimate (+15 %), counted in
///   [misses].
///
/// What a count includes (verified against `USAGE.prompt_tokens` in the
/// integration tests):
/// * [countMessage]: the message rendered alone through the template
///   (`add_generation_prompt: false`), i.e. its role markers and scaffolding.
///   Messages are cached by the SHA-256 of their engine JSON, so editing a
///   message re-counts it. Templates that render context-dependent pieces
///   (Qwen3 shows `<think>` only for the current tool loop and groups
///   consecutive tool results) make the per-message sum slightly larger
///   than the full render, never smaller: an assistant reply's own
///   reasoning is always added.
/// * [countText]: raw text tokens (no special tokens).
/// * [countTools]: the tool block PLUS the prompt's fixed scaffolding (BOS,
///   system wrapper, generation prompt incl. an empty think block). The
///   context manager calls it exactly once per request, so the sum of
///   system text + tools + messages covers the whole prompt.
/// * [countRequest]: the exact prompt of a full request (one render).
final class EngineTokenCounter implements TokenCounter {
  /// [resolveModel] returns the loaded model to count with (loading it if
  /// needed); the counter outlives reloads of the same model file.
  /// [useSyncTokenizer] allows direct FFI in the calling isolate for cache
  /// misses: only for runners that do not live on the UI isolate.
  EngineTokenCounter({
    required EngineHost host,
    required String providerId,
    required Future<ModelRef> Function() resolveModel,
    bool useSyncTokenizer = false,
    String? tokenizerFamily,
    int maxEntries = 8192,
  })  : _host = host,
        _resolve = resolveModel,
        _mapper = EngineMessageMapper(providerId),
        _useSync = useSyncTokenizer,
        _estimator = HeuristicTokenCounter(family: tokenizerFamily),
        _maxEntries = maxEntries;

  final EngineHost _host;
  final Future<ModelRef> Function() _resolve;
  final EngineMessageMapper _mapper;
  final bool _useSync;
  final HeuristicTokenCounter _estimator;
  final int _maxEntries;
  ModelRef? _model;
  SyncTokenizer? _syncTokenizer;

  SyncTokenizer? get _sync {
    if (!_useSync) return null;
    final m = _model;
    if (m == null) return null;
    return _syncTokenizer ??= _host.syncTokenizer(m);
  }

  Future<ModelRef> _modelRef() async {
    final m = await _resolve();
    if (m != _model) {
      _model = m;
      _syncTokenizer = null;
    }
    return m;
  }

  // ignore: prefer_collection_literals
  final LinkedHashMap<String, int> _cache = LinkedHashMap<String, int>();
  bool _warmed = false;
  int _misses = 0;

  /// Synchronous lookups answered by an estimate.
  int get misses => _misses;

  int get cachedEntries => _cache.length;

  /// Exact once the cache is fed by [warm] (or a synchronous tokenizer is
  /// available); before that the context manager keeps its safety margin.
  @override
  bool get isExact => _warmed || _sync != null;

  static const double _pessimism = 1.15;

  /// Probe base used when a template refuses a lone message (templates that
  /// insist on user/assistant alternation).
  static const List<JsonMap> _base = [
    {'role': 'user', 'content': '.'},
  ];
  static const List<JsonMap> _emptySystem = [
    {'role': 'system', 'content': ''},
  ];

  // ---------------------------------------------------------------------------
  // TokenCounter

  @override
  int countText(String text) {
    if (text.isEmpty) return 0;
    final key = 't:${_hash(text)}';
    return _lookup(key) ?? _syncOr(key, () => _sync!.countText(text), () => _estimate(_estimator.countText(text)));
  }

  @override
  int countMessage(Message message) {
    final probe = _messageProbe(message);
    final cached = _lookup(probe.key);
    if (cached != null) return cached + probe.surcharge;
    final n = _syncOr(
      probe.key,
      () => _syncMessage(probe),
      () => _estimate(_estimator.countMessage(message)),
    );
    return n + probe.surcharge;
  }

  @override
  int countTools(List<ToolDefinition> tools) {
    final probe = _toolsProbe(tools);
    return _lookup(probe.key) ??
        _syncOr(probe.key, () => _syncTools(probe), () => _estimate(_estimator.countTools(tools)) + 16);
  }

  // ---------------------------------------------------------------------------
  // Async (exact) API

  /// Counts everything not yet cached in one hop to the engine worker.
  Future<void> warm({String? systemPrompt, List<Message> messages = const [], List<ToolDefinition> tools = const []}) async {
    final texts = <String>[];
    final textKeys = <String>[];
    final chats = <String>[];
    final chatSinks = <void Function(List<int> counts, int offset)>[];
    final pendingKeys = <String>{};

    void wantText(String text) {
      if (text.isEmpty) return;
      final key = 't:${_hash(text)}';
      if (_cache.containsKey(key) || !pendingKeys.add(key)) return;
      texts.add(text);
      textKeys.add(key);
    }

    if (systemPrompt != null) wantText(systemPrompt);
    for (final m in messages) {
      final probe = _messageProbe(m);
      if (probe.reasoning.isNotEmpty) wantText(probe.reasoning);
      if (_cache.containsKey(probe.key) || !pendingKeys.add(probe.key)) continue;
      final start = chats.length;
      chats
        ..add(jsonEncode({'messages': probe.messages, 'add_generation_prompt': false}))
        ..add(jsonEncode({'messages': [..._base, ...probe.messages], 'add_generation_prompt': false}));
      chatSinks.add((counts, offset) {
        final alone = counts[offset + start];
        final withBase = counts[offset + start + 1];
        final base = counts[offset + chats.length];
        if (alone >= 0) {
          _put(probe.key, alone);
        } else if (withBase >= 0 && base >= 0) {
          _put(probe.key, withBase - base);
        }
      });
    }
    final tp = _toolsProbe(tools);
    if (!_cache.containsKey(tp.key) && pendingKeys.add(tp.key)) {
      final start = chats.length;
      chats.addAll(tp.requests.map(jsonEncode));
      chatSinks.add((counts, offset) {
        final v = tp.combine([for (var i = 0; i < tp.requests.length; i++) counts[offset + start + i]]);
        if (v != null) _put(tp.key, v);
      });
    }
    if (texts.isEmpty && chats.isEmpty) {
      _warmed = true;
      return;
    }
    // The probe base is appended last; message sinks read it at `chats.length`.
    final requests = [...chats, jsonEncode({'messages': _base, 'add_generation_prompt': false})];
    final counts = await _host.countBatch(await _modelRef(), texts: texts, chatRequests: requests);
    for (var i = 0; i < texts.length; i++) {
      if (counts[i] >= 0) _put(textKeys[i], counts[i]);
    }
    for (final sink in chatSinks) {
      sink(counts, texts.length);
    }
    _warmed = true;
  }

  /// The exact prompt token count of an engine request (the JSON of
  /// `se_generate_start`, e.g. `EngineRequestMapper.map(...).encode()`).
  Future<int> countRequestJson(String requestJson) async => _host.countChatTokens(await _modelRef(), requestJson);

  // ---------------------------------------------------------------------------

  int? _lookup(String key) {
    final v = _cache.remove(key);
    if (v != null) _cache[key] = v; // LRU touch
    return v;
  }

  void _put(String key, int value) {
    _cache.remove(key);
    _cache[key] = value;
    while (_cache.length > _maxEntries) {
      _cache.remove(_cache.keys.first);
    }
  }

  int _syncOr(String key, int Function() sync, int Function() estimate) {
    if (_sync != null) {
      try {
        final v = sync();
        if (v >= 0) {
          _put(key, v);
          return v;
        }
      } on Object {
        // fall through to the estimate
      }
    }
    _misses++;
    return estimate();
  }

  int _estimate(int heuristic) => (heuristic * _pessimism).ceil();

  int _syncMessage(_MessageProbe p) {
    final s = _sync!;
    try {
      return s.countChat(jsonEncode({'messages': p.messages, 'add_generation_prompt': false}));
    } on Object {
      final withBase = s.countChat(jsonEncode({'messages': [..._base, ...p.messages], 'add_generation_prompt': false}));
      final base = s.countChat(jsonEncode({'messages': _base, 'add_generation_prompt': false}));
      return withBase - base;
    }
  }

  int _syncTools(_ToolsProbe p) {
    final s = _sync!;
    final counts = <int>[];
    for (final r in p.requests) {
      try {
        counts.add(s.countChat(jsonEncode(r)));
      } on Object {
        counts.add(-1);
      }
    }
    return p.combine(counts) ?? -1;
  }

  _MessageProbe _messageProbe(Message m) {
    final mapped = _mapper.mapMessage(m);
    final reasoning = m.role == Role.assistant
        ? m.reasoning.where((r) => r.providerId == _mapper.providerId).map((r) => r.text).join()
        : '';
    final messages = mapped.isEmpty ? [const <String, Object?>{'role': 'user', 'content': ''}] : mapped;
    final key = 'm:${_hash(jsonEncode(messages))}';
    // Templates may hide reasoning when the message is rendered alone; add
    // it (plus the think tags) so the count never undercounts.
    final surcharge = reasoning.isEmpty ? 0 : (_lookup('t:${_hash(reasoning)}') ?? _estimate(_estimator.countText(reasoning))) + 4;
    return _MessageProbe(key, messages, reasoning, surcharge);
  }

  _ToolsProbe _toolsProbe(List<ToolDefinition> tools) {
    final mapped = [for (final t in tools) EngineMessageMapper.mapTool(t)];
    final key = 'T:${_hash(jsonEncode(mapped))}';
    return _ToolsProbe(key, [
      // 0: fixed scaffolding incl. the generation prompt (thinking off adds
      //    an empty think block, the larger of the two variants).
      {'messages': _emptySystem, 'add_generation_prompt': true, 'enable_thinking': false},
      // 1, 2: the tool block as the difference of two renders.
      {'messages': _emptySystem, 'add_generation_prompt': false},
      if (mapped.isNotEmpty) {'messages': _emptySystem, 'tools': mapped, 'add_generation_prompt': false},
      // 3, 4: the same with a user base, for templates without a system role.
      {'messages': _base, 'add_generation_prompt': true, 'enable_thinking': false},
      {'messages': _base, 'add_generation_prompt': false},
      if (mapped.isNotEmpty) {'messages': _base, 'tools': mapped, 'add_generation_prompt': false},
    ], hasTools: mapped.isNotEmpty);
  }

  static String _hash(String s) => sha256.convert(utf8.encode(s)).toString();
}

final class _MessageProbe {
  const _MessageProbe(this.key, this.messages, this.reasoning, this.surcharge);
  final String key;
  final List<JsonMap> messages;
  final String reasoning;
  final int surcharge;
}

final class _ToolsProbe {
  const _ToolsProbe(this.key, this.requests, {required this.hasTools});
  final String key;
  final List<JsonMap> requests;
  final bool hasTools;

  /// Tool block + fixed scaffolding from the probe counts, or null.
  int? combine(List<int> c) {
    final half = c.length ~/ 2;
    for (final o in [0, half]) {
      final fixed = c[o];
      final plain = c[o + 1];
      final withTools = hasTools ? c[o + 2] : plain;
      if (fixed < 0 || plain < 0 || withTools < 0) continue;
      // With the user base, its wrapper (+ one '.' token) stands in for the
      // system wrapper: a slight overcount, never an undercount.
      return withTools - plain + fixed;
    }
    return null;
  }
}
