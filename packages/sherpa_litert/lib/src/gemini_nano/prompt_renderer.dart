import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../common/prompted_tools.dart';

/// A request flattened for the stateless Prompt API.
@immutable
final class RenderedNanoPrompt {
  const RenderedNanoPrompt({
    required this.systemInstruction,
    required this.prompt,
    required this.images,
    required this.notices,
    required this.toolNames,
    required this.continuation,
  });

  /// For `SystemInstruction` (null when folded into [prompt]).
  final String? systemInstruction;
  final String prompt;
  final List<Uint8List> images;
  final List<ProviderNotice> notices;

  /// Tools offered in the prompted format (empty = none).
  final Set<String> toolNames;

  /// [prompt] ends inside an assistant turn the model continues.
  final bool continuation;

  bool get promptedTools => toolNames.isNotEmpty;
}

/// Renders a core [ModelRequest] into one Prompt API request.
///
/// History policy: the Prompt API keeps no conversation (each
/// `generateContent` is a single prompt; `Content` has no roles), so every
/// request resends the full transcript, rendered as text. Edits, branches
/// and compaction need nothing special: whatever the request holds is what
/// the model sees.
///
/// * One plain user message and no tools: the prompt is just its text (best
///   quality for the short tasks Nano suits: summaries, titles, rewrites).
/// * Otherwise a transcript of `User:` / `Assistant:` turns ending with an
///   open `Assistant:` turn; a trailing (paused) assistant message is left
///   open so the model continues it.
/// * Tools use [PromptedToolFormat]; results are untrusted-data blocks.
/// * The system prompt goes into `SystemInstruction` when AICore supports it
///   (`isSystemPromptAvailable`), else it heads the prompt.
/// * Images: only the last user message's, and only with vision enabled.
///   Reasoning is never replayed.
final class NanoPromptRenderer {
  const NanoPromptRenderer({required this.systemPromptSupported, required this.vision, required this.toolCalling});

  final bool systemPromptSupported;
  final bool vision;
  final bool toolCalling;

  static const String _transcriptRule = 'The conversation so far is written as a transcript. Write only the next '
      'Assistant reply: do not write "User:" or "Assistant:" lines.';

  RenderedNanoPrompt render(ModelRequest request) {
    final notices = <ProviderNotice>[];
    final p = request.params;
    final toolsActive = toolCalling && request.tools.isNotEmpty && p.toolChoice is! ToolChoiceNone;
    if (request.tools.isNotEmpty && !toolCalling) {
      notices.add(const ProviderNotice('tools_disabled', 'Tool calling is turned off for Gemini Nano.'));
    }
    if (p.stop.isNotEmpty) {
      notices.add(const ProviderNotice('stop_ignored', 'Gemini Nano has no stop sequences; they were not applied.'));
    }
    if (p.jsonSchema != null) {
      notices.add(const ProviderNotice('json_schema_dropped',
          'Structured output is not used with Gemini Nano here; the schema was not applied.'));
    }

    final system = <String>[];
    final base = request.systemPrompt?.trim() ?? '';
    if (base.isNotEmpty) system.add(base);
    final messages = <Message>[];
    for (final m in request.messages) {
      if (m.role == Role.system && messages.isEmpty) {
        final t = m.text.trim();
        if (t.isNotEmpty) system.add(t);
      } else {
        messages.add(m);
      }
    }
    if (toolsActive) system.add(PromptedToolFormat.instructions(request.tools, p.toolChoice));

    final lastUser = messages.lastIndexWhere((m) => m.role == Role.user);
    final images = <Uint8List>[];
    final single = !toolsActive &&
        messages.length == 1 &&
        messages.single.role == Role.user &&
        messages.single.toolResults.isEmpty;

    final turns = <String>[];
    var continuation = false;
    for (final (i, m) in messages.indexed) {
      switch (m.role) {
        case Role.system:
          final t = m.text.trim();
          if (t.isNotEmpty) turns.add('System note: $t');
        case Role.user:
          if (m.toolResults.isNotEmpty) turns.add(PromptedToolFormat.results(m.toolResults));
          final text = _userText(m, notices, takeImages: i == lastUser ? images : null);
          if (text.isNotEmpty) turns.add(single ? text : 'User: $text');
        case Role.assistant:
          final calls = m.toolCalls;
          final body = [
            if (m.text.isNotEmpty) m.text,
            if (calls.isNotEmpty) PromptedToolFormat.envelope(calls),
          ].join('\n');
          if (body.isEmpty) continue;
          turns.add('Assistant: $body');
          // A reply that stopped mid-way (paused) is left open to continue.
          if (i == messages.length - 1 && calls.isEmpty) continuation = true;
        case Role.tool:
          if (m.toolResults.isNotEmpty) turns.add(PromptedToolFormat.results(m.toolResults));
      }
    }

    String prompt;
    if (single) {
      prompt = turns.isEmpty ? '' : turns.single;
    } else {
      system.add(_transcriptRule);
      prompt = turns.join('\n\n');
      if (!continuation) prompt = prompt.isEmpty ? 'Assistant:' : '$prompt\n\nAssistant:';
    }
    if (continuation) {
      notices.add(const ProviderNotice('continue_reply', 'Continuing the interrupted reply.'));
    }

    final systemText = system.isEmpty ? null : system.join('\n\n');
    if (systemText != null && !systemPromptSupported) {
      prompt = 'Instructions:\n$systemText\n\n$prompt';
    }
    return RenderedNanoPrompt(
      systemInstruction: systemPromptSupported ? systemText : null,
      prompt: prompt,
      images: images,
      notices: notices,
      toolNames: toolsActive ? {for (final t in request.tools) t.name} : const {},
      continuation: continuation,
    );
  }

  String _userText(Message m, List<ProviderNotice> notices, {List<Uint8List>? takeImages}) {
    final lines = <String>[];
    for (final c in m.content) {
      switch (c) {
        case TextPart(:final text):
          lines.add(text);
        case EmbeddedResourcePart(:final uri, :final text?):
          lines.add('[resource $uri]\n$text');
        case ResourceLinkPart(:final uri, :final name):
          lines.add('[resource link${name == null ? '' : ' "$name"'}: $uri]');
        case ImagePart(:final data?) when vision && takeImages != null:
          takeImages.add(data);
        case MediaPart(:final mimeType):
          notices.add(ProviderNotice('content_dropped', 'An attachment ($mimeType) was not sent to Gemini Nano.',
              data: {'kind': mimeType}));
        default:
          break;
      }
    }
    return lines.join('\n');
  }
}
