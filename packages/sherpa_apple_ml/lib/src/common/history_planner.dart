import 'package:meta/meta.dart';

import '../messages.pigeon.dart';
import 'wire.dart';

/// What a native engine can append to a live session in one request.
enum AppendShape {
  /// MLX `ChatSession.streamDetails(to: [Chat.Message])`: any roles, as long
  /// as the last message is something to answer (user or tool).
  anyRoles,

  /// Foundation Models `streamResponse(to: prompt)`: exactly one user turn.
  singleUserPrompt,
}

/// The decision for one request (see [HistoryPlanner]).
@immutable
final class HistoryPlan {
  const HistoryPlan(this.mode, this.history, this.pending, {required this.reason, this.partialAssistant});

  final AmHistoryMode mode;

  /// Messages the native session must be (re)built from. Empty for append.
  final List<AmWireMessage> history;

  /// Messages to send in this request.
  final List<AmWireMessage> pending;

  /// [AmHistoryMode.continueAssistant]: the paused reply to continue.
  final String? partialAssistant;

  /// Why (`new_session`, `config_changed`, `history_changed`,
  /// `native_state_lost`, `paused_reply`, `appended`).
  final String reason;

  @override
  String toString() => 'HistoryPlan(${mode.name}, history: ${history.length}, pending: ${pending.length}, $reason)';
}

/// What Dart believes a native session holds.
final class SessionLedger {
  SessionLedger(this.configKey, this.committed);

  /// Things the session cannot change in place (MLX: the model; FM: the
  /// instructions and tool set, which `LanguageModelSession` fixes at init).
  final String configKey;

  /// Fingerprints of the wire messages in the native transcript, in order
  /// (the system prompt is not a message; it is part of the request).
  final List<String> committed;
}

/// The history policy shared by both engines.
///
/// Sherpa's transcript is a tree (edits and retries create branches,
/// compaction and truncation are overlays), but MLX `ChatSession` and FM
/// `LanguageModelSession` each hold ONE linear transcript plus KV/model
/// state. Per Sherpa session the planner remembers, as fingerprints, what
/// the native session holds ([SessionLedger]) and decides per request:
///
/// * **append** when the native transcript is a prefix of the request and
///   what follows has an [AppendShape] the engine accepts. MLX re-renders
///   the full chat template every turn and reuses the longest common token
///   prefix, so a changed system prompt or tool list is still an append
///   (the session's `instructions`/`tools` are updated in place);
/// * **rebuild** otherwise (a new branch, an edited or compacted message, a
///   different model, or a native state that was invalidated): the session
///   is recreated from the request's history (MLX
///   `ChatSession(history:)`, FM `LanguageModelSession(transcript:)`) and
///   the new turn is sent. A rebuild re-prefills the whole prompt;
/// * **continueAssistant** when the request ends with an assistant message,
///   i.e. the agent loop continues a reply that was paused at a token
///   boundary (iOS backgrounding). MLX renders the history plus the partial
///   reply and keeps generating; the session is rebuilt on the next turn.
///
/// After each generation the provider [commit]s what the native session now
/// holds, or [invalidate]s it when the native side did not record the turn
/// (cancelled, paused, failed, rejected tool call, empty reply).
final class HistoryPlanner {
  HistoryPlanner({required this.appendShape});

  final AppendShape appendShape;
  final Map<String, SessionLedger> _ledgers = {};

  SessionLedger? ledger(String sessionKey) => _ledgers[sessionKey];

  HistoryPlan plan({required String sessionKey, required String configKey, required List<AmWireMessage> messages}) {
    if (messages.isEmpty) {
      return HistoryPlan(AmHistoryMode.rebuild, const [], [
        AmWireMessage(role: 'user', content: ''),
      ], reason: 'empty_request');
    }
    if (messages.last.role == 'assistant') {
      return HistoryPlan(
        AmHistoryMode.continueAssistant,
        messages.sublist(0, messages.length - 1),
        const [],
        partialAssistant: messages.last.content,
        reason: 'paused_reply',
      );
    }
    final fps = [for (final m in messages) wireFingerprint(m)];
    final ledger = _ledgers[sessionKey];
    if (ledger != null && ledger.configKey == configKey && _isPrefix(ledger.committed, fps)) {
      final suffix = messages.sublist(ledger.committed.length);
      if (_appendable(suffix)) return HistoryPlan(AmHistoryMode.append, const [], suffix, reason: 'appended');
    }
    final reason = ledger == null
        ? 'new_session'
        : ledger.configKey != configKey
        ? 'config_changed'
        : 'history_changed';
    // The native session is rebuilt from everything before the trailing
    // block it has to answer.
    final start = _trailingStart(messages);
    return HistoryPlan(AmHistoryMode.rebuild, messages.sublist(0, start), messages.sublist(start), reason: reason);
  }

  bool _appendable(List<AmWireMessage> suffix) {
    if (suffix.isEmpty) return false;
    switch (appendShape) {
      case AppendShape.anyRoles:
        return suffix.last.role == 'user' || suffix.last.role == 'tool';
      case AppendShape.singleUserPrompt:
        return suffix.length == 1 && suffix.single.role == 'user';
    }
  }

  /// Index where the final run of messages to answer begins: after the last
  /// assistant message for MLX (user and tool messages), the last message
  /// for FM (one prompt).
  int _trailingStart(List<AmWireMessage> messages) {
    if (appendShape == AppendShape.singleUserPrompt) return messages.length - 1;
    var i = messages.length;
    while (i > 0 && messages[i - 1].role != 'assistant') {
      i--;
    }
    return i == messages.length ? messages.length - 1 : i;
  }

  static bool _isPrefix(List<String> prefix, List<String> of) {
    if (prefix.length > of.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (prefix[i] != of[i]) return false;
    }
    return true;
  }

  /// The native session now holds [sent] followed by [produced].
  void commit(String sessionKey, String configKey, List<AmWireMessage> sent, AmWireMessage produced) {
    _ledgers[sessionKey] = SessionLedger(configKey, [
      for (final m in sent) wireFingerprint(m),
      wireFingerprint(produced),
    ]);
  }

  /// The native session holds exactly [messages] (FM: a turn suspended on
  /// tool calls is accounted for by the provider, not here).
  void commitExact(String sessionKey, String configKey, List<AmWireMessage> messages) {
    _ledgers[sessionKey] = SessionLedger(configKey, [for (final m in messages) wireFingerprint(m)]);
  }

  /// The native transcript is unknown: the next request rebuilds.
  void invalidate(String sessionKey) => _ledgers.remove(sessionKey);

  void clear() => _ledgers.clear();
}
