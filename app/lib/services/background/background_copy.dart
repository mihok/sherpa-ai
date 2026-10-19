import 'package:sherpa_core/sherpa_core.dart' show RunOutcome, defaultSessionTitle;

/// What the ongoing notification (Android) or Live Activity (iOS) and the
/// finished notices say. Never message content: a chat's title at most
/// (people name chats, or the first words of their message do), and the
/// notifications carry a public version without it for locked screens that
/// hide sensitive content.

/// What a run is doing, for the notification text.
enum RunActivityPhase {
  /// Preparing context or streaming the model's reply.
  working,

  /// A tool call is running.
  usingTool,

  /// A tool call waits for the user's decision.
  awaitingApproval,

  /// The provider paused the reply until Sherpa is on screen again (iPhone
  /// GPU, Gemini Nano).
  waitingForApp,
}

/// The longest chat title a notification quotes.
const int kNotificationTitleChars = 40;

/// [title] as a notification quotes it: trimmed, on one line, shortened;
/// null for an untitled chat.
String? quotedChatTitle(String title) {
  final t = title.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (t.isEmpty || t == defaultSessionTitle) return null;
  final short = t.length > kNotificationTitleChars ? '${t.substring(0, kNotificationTitleChars - 1).trimRight()}…' : t;
  return '“$short”';
}

/// The lease's title (fixed for its lifetime).
String leaseTitle(List<String> chatTitles) {
  if (chatTitles.length > 1) return 'Sherpa is finishing replies in ${chatTitles.length} chats';
  final q = chatTitles.isEmpty ? null : quotedChatTitle(chatTitles.single);
  return q == null ? 'Sherpa is finishing a reply' : 'Sherpa is finishing a reply in $q';
}

/// Shown instead of progress while a run waits for the app.
const String kPausedOpenSherpa = 'Paused: open Sherpa to continue';

/// The lease's text for one run: its step and what it does now. [paused]
/// when it cannot go on until Sherpa is on screen.
String leaseText({required int step, required RunActivityPhase phase, required bool paused}) {
  if (paused || phase == RunActivityPhase.waitingForApp) return kPausedOpenSherpa;
  return switch (phase) {
    RunActivityPhase.awaitingApproval => 'Waiting for your approval: open Sherpa to decide',
    RunActivityPhase.usingTool => step > 0 ? 'Step $step · Using a tool' : 'Using a tool',
    _ => step > 1 ? 'Step $step · Writing' : 'Writing the reply',
  };
}

/// A notice when a run ended while Sherpa was away; null when there is
/// nothing to tell (the user stopped it).
({String title, String text})? finishedNotice(RunOutcome outcome, String chatTitle, {required bool paused}) {
  final q = quotedChatTitle(chatTitle);
  final inChat = q == null ? '' : ' in $q';
  if (paused) return (title: 'Paused$inChat', text: 'Sherpa had to stop in the background. Open it to continue.');
  return switch (outcome) {
    RunOutcome.completed => (title: 'Reply ready$inChat', text: 'Open Sherpa to read it.'),
    RunOutcome.maxSteps => (title: 'Sherpa paused$inChat to check in', text: 'Open Sherpa to continue or change course.'),
    RunOutcome.needsUserAction ||
    RunOutcome.failed =>
      (title: "A reply$inChat didn't finish", text: 'Open Sherpa to see what happened.'),
    RunOutcome.cancelled => null,
  };
}

/// The notice when every run waits for the app (the lease was released).
({String title, String text}) waitingNotice(String chatTitle) {
  final q = quotedChatTitle(chatTitle);
  return (title: q == null ? kPausedOpenSherpa : 'Paused in $q', text: 'The reply continues when Sherpa is on screen.');
}

/// The chat title the agent runner will give an untitled chat from its
/// first message (`AgentRunner._setLeaf`: whitespace collapsed, 60
/// characters at most), so a notification started with the run can name
/// the chat before the runner renames it.
String expectedChatTitle(String current, String? firstMessage) {
  if (current.isNotEmpty && current != defaultSessionTitle) return current;
  final hint = firstMessage?.trim();
  if (hint == null || hint.isEmpty) return current;
  final t = hint.replaceAll(RegExp(r'\s+'), ' ');
  return t.length > 60 ? '${t.substring(0, 57)}…' : t;
}
