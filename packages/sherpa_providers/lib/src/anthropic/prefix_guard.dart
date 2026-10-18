import 'dart:collection';
import 'dart:convert';

import 'package:sherpa_core/sherpa_core.dart';

/// Detects requests that would trip Anthropic's preserved-thinking check.
///
/// For each session it remembers a fingerprint of the previous request
/// (system + tools, then every block of every turn, with `cache_control`
/// removed because moving breakpoints is explicitly allowed). The next
/// request must start with exactly the same turns; only the previous last
/// turn may grow by appended blocks. When it does not, and a thinking block
/// is replayed at or after the first difference, the API would answer
/// 400 "Invalid `signature` in `thinking` block" — so this reports it
/// before the round trip, with the turn index that changed.
///
/// It is a development aid (PLAN §5 "debug assertion that diffs
/// consecutive request prefixes"): the provider only runs it when asserts
/// are enabled, so release builds pay nothing.
final class AnthropicPrefixGuard {
  AnthropicPrefixGuard({this.maxSessions = 32});

  final int maxSessions;
  final LinkedHashMap<String, _Snapshot> _sessions = LinkedHashMap();

  /// Records [body] for [sessionId] and returns a notice when it edits the
  /// prefix that replayed thinking depends on.
  ProviderNotice? check(String sessionId, JsonMap body) {
    final current = _Snapshot.of(body);
    final previous = _sessions.remove(sessionId);
    _sessions[sessionId] = current;
    while (_sessions.length > maxSessions) {
      _sessions.remove(_sessions.keys.first);
    }
    if (previous == null) return null;
    final at = _divergence(previous, current);
    if (at == null) return null;
    final replayedAfter = current.thinkingTurns.where((t) => t >= at).toList();
    if (replayedAfter.isEmpty) return null;
    final scope = at < 0 ? 'system prompt or tool list' : 'message turn $at';
    return ProviderNotice(
      'anthropic.prefix_changed',
      'The $scope changed since the previous request, but thinking produced after it is still '
      'replayed; Anthropic will reject this request (preserved thinking).',
      data: {'turn': at, 'thinkingTurns': replayedAfter},
    );
  }

  /// Index of the first turn that is not an append-only continuation of
  /// [a]; -1 when system/tools changed; null when [b] only appends.
  static int? _divergence(_Snapshot a, _Snapshot b) {
    if (a.head != b.head) return -1;
    final n = a.turns.length < b.turns.length ? a.turns.length : b.turns.length;
    for (var i = 0; i < n; i++) {
      final x = a.turns[i];
      final y = b.turns[i];
      final isLastOfA = i == a.turns.length - 1;
      if (x.role != y.role) return i;
      if (isLastOfA ? !_isPrefix(x.blocks, y.blocks) : !_equal(x.blocks, y.blocks)) return i;
    }
    // A shorter request is a different branch (regenerate / edit); nothing
    // it replays was produced after the cut, so it is not an edit.
    return null;
  }

  static bool _isPrefix(List<int> a, List<int> b) {
    if (a.length > b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _equal(List<int> a, List<int> b) => a.length == b.length && _isPrefix(a, b);
}

final class _Turn {
  const _Turn(this.role, this.blocks);
  final String role;
  final List<int> blocks;
}

final class _Snapshot {
  const _Snapshot(this.head, this.turns, this.thinkingTurns);

  factory _Snapshot.of(JsonMap body) {
    final head = _hash(jsonEncode({'system': _strip(body['system']), 'tools': _strip(body['tools'])}));
    final turns = <_Turn>[];
    final thinking = <int>[];
    final messages = body['messages'];
    if (messages is List) {
      for (final (i, m) in messages.indexed) {
        if (m is! Map) continue;
        final content = m['content'];
        final blocks = <int>[];
        if (content is List) {
          for (final block in content) {
            blocks.add(_hash(jsonEncode(_strip(block))));
            if (block is Map && (block['type'] == 'thinking' || block['type'] == 'redacted_thinking')) {
              if (thinking.isEmpty || thinking.last != i) thinking.add(i);
            }
          }
        } else {
          blocks.add(_hash(jsonEncode(content)));
        }
        turns.add(_Turn(m['role']?.toString() ?? '', blocks));
      }
    }
    return _Snapshot(head, turns, thinking);
  }

  final int head;
  final List<_Turn> turns;
  final List<int> thinkingTurns;

  static Object? _strip(Object? v) => switch (v) {
        Map<Object?, Object?>() => {
            for (final e in v.entries)
              if (e.key != 'cache_control') e.key.toString(): _strip(e.value),
          },
        List<Object?>() => [for (final e in v) _strip(e)],
        _ => v,
      };

  /// FNV-1a 64 (not a security hash; only detects change).
  static int _hash(String s) {
    var h = 0xcbf29ce484222325;
    for (final b in utf8.encode(s)) {
      h ^= b;
      h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    return h;
  }
}
