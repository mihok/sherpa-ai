import 'package:sherpa_core/sherpa_core.dart';

import '../../../services/inference/local_model_provider.dart' show kEngineCrashNoticeCode;
import 'chat_view_state.dart';

// What the transcript says about runner and provider notices. Their own
// text is written for logs and models (`rateLimited: retrying in 800 ms`,
// JSON-schema keywords); the chat shows a calm sentence instead.

/// The chat notice for a runner [RunNotice].
ChatNotice runNoticeFor(String code, String message) => switch (code) {
      'retrying' => ChatNotice(code: code, message: _retryingCopy(message), kind: ChatNoticeKind.progress),
      // The ladder's advice comes with the way to act on it.
      'handoff_recommended' => ChatNotice(code: code, message: message, action: ChatNoticeAction.handOff),
      'untrusted_content' => ChatNotice(
          code: code,
          message: 'This chat now includes content from tools or servers outside Sherpa, which could try to '
              'steer the model. Sherpa will ask you before any action that changes data or reaches the internet.',
          dismissible: true,
        ),
      'tool_call_truncated' => ChatNotice(
          code: code,
          message: "The reply hit its length limit in the middle of a tool call, so Sherpa didn't run that call. "
              'The model was asked to try again with shorter input.',
          dismissible: true,
        ),
      'tool_interrupted' => ChatNotice(
          code: code,
          message: '${_toolOf(message)} was interrupted when the app closed. Its outcome is unknown, so Sherpa '
              "didn't run it again. Check whether it finished before asking for it again.",
          dismissible: true,
        ),
      _ => ChatNotice(code: code, message: message),
    };

/// The chat notice for a provider's [ProviderNotice], or null for the many
/// that are diagnostics only (cache hits, dropped headers…).
ChatNotice? providerNoticeFor(ProviderNotice notice) => switch (notice.code) {
      'tool_args_truncated' => ChatNotice(
          code: notice.code,
          message: 'A tool call was cut off ${_cutoffCopy(notice.data['cutoff'])} before its input was complete, '
              "so Sherpa didn't run it.",
          dismissible: true,
        ),
      // Delivered once, with the first on-device reply after a crash.
      kEngineCrashNoticeCode => ChatNotice(
          code: notice.code,
          message: _crashCopy(notice.message),
          kind: ChatNoticeKind.warning,
          dismissible: true,
        ),
      'anthropic.schema_relaxed' => ChatNotice(
          code: notice.code,
          message: "Anthropic can't enforce every rule of the requested output format"
              '${_relaxedCopy(notice.message)}, so the reply may not follow them exactly.',
          dismissible: true,
        ),
      _ => null,
    };

/// The crash report's sentence ("The app was stopped (possibly by the system
/// for using too much memory) while generating a reply with X (8192-token
/// context).") with what it means and what to do.
String _crashCopy(String report) {
  final what = report.trim();
  return [
    'The on-device model stopped unexpectedly last time.',
    if (what.isNotEmpty) what.endsWith('.') ? what : '$what.',
    'Your chats are safe. If it happens again, try a smaller model or close other apps.',
  ].join(' ');
}

String _retryingCopy(String message) {
  if (message.startsWith('${ProviderErrorKind.rateLimited.name}:')) return 'Rate limited — retrying shortly…';
  if (message.startsWith('${ProviderErrorKind.overloaded.name}:')) return 'The server is busy — retrying…';
  return 'Connection problem — retrying…';
}

/// `<display name> was interrupted while running; …` → the display name.
String _toolOf(String message) {
  final i = message.indexOf(' was interrupted');
  return i > 0 ? message.substring(0, i) : 'A tool';
}

String _cutoffCopy(Object? cutoff) => switch (cutoff) {
      'tokenLimit' => "by the reply's length limit",
      'contentFilter' => "by the provider's content filter",
      'contextWindow' => 'when the context window filled up',
      _ => 'when the reply ended early',
    };

/// `…: minLength, pattern (2x).` → ` (minLength, pattern)`.
String _relaxedCopy(String message) {
  final i = message.lastIndexOf(': ');
  if (i < 0) return '';
  var list = message.substring(i + 2).trim();
  if (list.endsWith('.')) list = list.substring(0, list.length - 1);
  return list.isEmpty ? '' : ' ($list)';
}
