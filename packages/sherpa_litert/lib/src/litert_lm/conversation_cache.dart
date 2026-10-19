import 'package:flutter/foundation.dart' show listEquals;
import 'package:meta/meta.dart';

import 'request_mapper.dart';

/// Why a native conversation is (re)built.
enum RebuildReason {
  /// No native conversation for this chat yet (or it was evicted).
  fresh,

  /// Another model is loaded now.
  modelChanged,

  /// System prompt, tool set, sampler or response format changed (fixed at
  /// conversation creation in LiteRT-LM).
  configChanged,

  /// The request's history is not exactly what the native conversation
  /// holds: an edit, a branch switch, a retry, a compaction overlay, or a
  /// reply stored differently from how it streamed.
  historyDiverged,

  /// The last turn did not end cleanly (cancel, pause, error, a continue
  /// nudge): LiteRT-LM cannot roll a conversation back, so its state is
  /// unknown.
  interrupted,
}

sealed class ConversationPlan {
  const ConversationPlan(this.conversationId);

  final String conversationId;
}

/// Send only the tail into the live conversation.
final class ReuseConversation extends ConversationPlan {
  const ReuseConversation(super.conversationId);
}

/// Create (or replace) the conversation from `initialMessages` = the
/// request's history, closing [close] (evicted conversations) first.
final class RebuildConversation extends ConversationPlan {
  const RebuildConversation(super.conversationId, this.reason, {this.close = const []});

  final RebuildReason reason;

  /// Other native conversations to close first (LRU evictions).
  final List<String> close;
}

/// The history/branch policy of [LiteRtLmProvider]: "mirror and verify,
/// rebuild on divergence".
///
/// LiteRT-LM's `Conversation` keeps the transcript and its KV cache
/// natively and can only be appended to (one message per `sendMessage`);
/// Sherpa's transcript is a tree (edits, retries and branches create
/// siblings) and the context manager may rewrite older turns. So the native
/// conversation is treated as a cache of one exact prefix:
///
/// * Each live conversation remembers the fingerprints of the messages it
///   holds ([commit] after a clean turn: history + tail + the reply as it
///   streamed) and the config it was created with.
/// * A request reuses it only when its history (everything before the
///   message to send) is exactly that list and the config is unchanged;
///   then only the new message is sent and the KV cache is reused.
/// * Anything else rebuilds: the conversation is closed and created again
///   with `initialMessages` = the request's history (re-prefilled), then the
///   tail is sent. The provider never patches native state in place.
/// * A turn that ended any other way than `done` [invalidate]s the entry
///   (LiteRT-LM has no rollback; b/450903294 in its sources).
/// * At most [maxLive] native conversations stay open (each holds a KV
///   cache); the least recently used are closed.
final class ConversationCache {
  ConversationCache({this.maxLive = 1}) : assert(maxLive >= 1);

  final int maxLive;
  final Map<String, _Entry> _bySession = {};
  int _seq = 0;

  /// Session keys with a live native conversation, least recent first.
  List<String> get liveSessions => _bySession.keys.toList();

  @visibleForTesting
  List<String>? committedKeys(String sessionKey) => _bySession[sessionKey]?.committed;

  ConversationPlan plan({required String sessionKey, required String modelId, required MappedLiteRtTurn turn}) {
    final e = _bySession.remove(sessionKey);
    if (e != null) _bySession[sessionKey] = e; // most recent last
    if (e != null) {
      final reason = e.dirty
          ? RebuildReason.interrupted
          : e.modelId != modelId
              ? RebuildReason.modelChanged
              : e.configKey != turn.configKey
                  ? RebuildReason.configChanged
                  : !listEquals(e.committed, turn.historyKeys)
                      ? RebuildReason.historyDiverged
                      : null;
      if (reason == null) return ReuseConversation(e.conversationId);
      // openConversation replaces a native conversation with the same id.
      return RebuildConversation(e.conversationId, reason, close: _evictions(sessionKey));
    }
    final id = 'c${++_seq}';
    return RebuildConversation(id, RebuildReason.fresh, close: _evictions(sessionKey));
  }

  List<String> _evictions(String keep) {
    final others = _bySession.keys.where((k) => k != keep).toList();
    final excess = others.length - (maxLive - 1);
    if (excess <= 0) return const [];
    final evicted = others.take(excess).toList();
    return [for (final k in evicted) _bySession.remove(k)!.conversationId];
  }

  /// The native conversation [conversationId] now holds [turn.history]
  /// (rebuilt), not yet the tail.
  void opened({
    required String sessionKey,
    required String conversationId,
    required String modelId,
    required MappedLiteRtTurn turn,
  }) {
    _bySession.remove(sessionKey);
    _bySession[sessionKey] = _Entry(conversationId, modelId, turn.configKey, [...turn.historyKeys]);
  }

  /// A turn ended cleanly: the conversation holds history + tail + reply
  /// ([replyKey] null for an empty reply, which the next request will not
  /// contain either).
  void commit({required String sessionKey, required MappedLiteRtTurn turn, required String? replyKey}) {
    final e = _bySession[sessionKey];
    if (e == null) return;
    if (turn.continuation) {
      // The nudge is in the native conversation but not in Sherpa's
      // transcript: the next request cannot match it.
      e.dirty = true;
      return;
    }
    e.committed = [...turn.historyKeys, turn.tailKey, ?replyKey];
    e.dirty = false;
  }

  /// The last turn of [sessionKey] did not end cleanly.
  void invalidate(String sessionKey) => _bySession[sessionKey]?.dirty = true;

  /// Forgets [sessionKey] (its native conversation is gone or unknown, e.g.
  /// opening it failed).
  void forget(String sessionKey) => _bySession.remove(sessionKey);

  /// The engine was released or reloaded: no native conversation survives.
  void clear() => _bySession.clear();
}

final class _Entry {
  _Entry(this.conversationId, this.modelId, this.configKey, this.committed);

  final String conversationId;
  final String modelId;
  final String configKey;
  List<String> committed;
  bool dirty = false;
}
