import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_markdown/sherpa_markdown.dart';

import '../../../design/tokens.dart';
import '../state/chat_controller.dart';
import '../state/chat_view_state.dart';
import '../state/transcript_model.dart';
import 'chat_style.dart';
import 'message_actions.dart';
import 'reasoning_region.dart';
import 'tool_call_card.dart';
import 'transcript.dart';

/// Callbacks an assistant turn needs from the screen.
@immutable
class AssistantTurnCallbacks {
  const AssistantTurnCallbacks({
    required this.onCopy,
    required this.onShare,
    required this.onRetry,
    required this.onSwitch,
    required this.onLinkTap,
    required this.onCopyCode,
  });

  final void Function(AssistantTurnItem item) onCopy;
  final void Function(AssistantTurnItem item) onShare;
  final void Function(AssistantTurnItem item) onRetry;
  final void Function(AssistantTurnItem item, bool forward) onSwitch;
  final void Function(Uri uri) onLinkTap;
  final void Function(String code) onCopyCode;
}

/// Everything the assistant did for one user message.
///
/// Finished blocks sit behind a [RepaintBoundary] and only rebuild when the
/// turn's structure changes; the streaming tail is a separate
/// [LiveDraftView] that alone rebuilds every frame.
class AssistantTurnTile extends StatelessWidget {
  const AssistantTurnTile({
    super.key,
    required this.sessionId,
    required this.item,
    required this.callbacks,
  });

  final String sessionId;
  final AssistantTurnItem item;
  final AssistantTurnCallbacks callbacks;

  /// Test hook: counts builds per turn to prove finished turns are not
  /// rebuilt while a reply streams.
  @visibleForTesting
  static void Function(String turnKey)? debugOnBuild;

  @override
  Widget build(BuildContext context) {
    debugOnBuild?.call(item.key);
    final runActive = ChatRunScope.runningOf(context);
    final tokens = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final finished = <Widget>[
      for (final block in item.blocks)
        Padding(
          key: ValueKey(block.key),
          padding: EdgeInsets.only(bottom: tokens.space.sm),
          child: switch (block) {
            ReasoningBlock() => ReasoningRegion(
                storageKey: block.key,
                text: block.text,
                duration: block.duration,
                redacted: block.redacted,
              ),
            TextBlock() => StreamingMarkdown(
                text: block.text,
                style: chatMarkdownStyle(context),
                onLinkTap: callbacks.onLinkTap,
                onCopyCode: callbacks.onCopyCode,
              ),
            ToolGroupBlock() => ToolGroupView(sessionId: sessionId, groupKey: block.key, calls: block.calls),
          },
        ),
      if (!item.live && item.finishReason == FinishReason.cancelled.name && item.blocks.isNotEmpty)
        _Footnote(icon: Icons.stop_circle_outlined, text: 'Stopped early'),
      if (!item.live && item.errorText != null)
        _Footnote(icon: Icons.error_outline_rounded, text: 'This reply was interrupted by an error.'),
    ];
    return RepaintBoundary(
      child: ReadableWidth(
        child: Padding(
          padding: EdgeInsets.only(top: tokens.space.md, bottom: tokens.space.xs),
          child: Semantics(
            container: true,
            explicitChildNodes: true,
            headingLevel: 2,
            label: 'Sherpa',
            customSemanticsActions: item.showActions
                ? {
                    const CustomSemanticsAction(label: 'Copy reply'): () => callbacks.onCopy(item),
                    if (!runActive) const CustomSemanticsAction(label: 'Retry'): () => callbacks.onRetry(item),
                  }
                : null,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (finished.isNotEmpty)
                  RepaintBoundary(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: finished),
                  ),
                if (item.live)
                  LiveDraftView(sessionId: sessionId, callbacks: callbacks)
                else if (item.showActions)
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: AssistantActions(
                      enabled: !runActive,
                      onCopy: () => callbacks.onCopy(item),
                      onShare: () => callbacks.onShare(item),
                      onRetry: () => callbacks.onRetry(item),
                      branch: item.branch,
                      onPrevious: () => callbacks.onSwitch(item, false),
                      onNext: () => callbacks.onSwitch(item, true),
                    ),
                  ),
                if (!item.live && !item.showActions && item.blocks.isEmpty)
                  Text(
                    'No reply',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Footnote extends StatelessWidget {
  const _Footnote({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final tokens = SherpaTokens.of(context);
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: EdgeInsets.only(bottom: tokens.space.sm),
      child: Row(
        children: [
          Icon(icon, size: ChatIconSize.small, color: color),
          SizedBox(width: tokens.space.xs),
          Flexible(child: Text(text, style: Theme.of(context).textTheme.labelMedium?.copyWith(color: color))),
        ],
      ),
    );
  }
}

/// The message being streamed right now. The only part of the transcript
/// that rebuilds per frame.
class LiveDraftView extends ConsumerWidget {
  const LiveDraftView({super.key, required this.sessionId, required this.callbacks});

  final String sessionId;
  final AssistantTurnCallbacks callbacks;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (draft, status) = ref.watch(chatControllerProvider(sessionId).select((s) => (s.draft, s.status)));
    final tokens = SherpaTokens.of(context);
    if (draft == null || draft.isEmpty) {
      // Before the first token: a calm "Thinking…" line. During tool
      // execution the tool cards carry the status instead.
      if (status != ChatRunStatus.streaming) return const SizedBox.shrink();
      return const Align(
        alignment: AlignmentDirectional.centerStart,
        child: ReasoningRegion(storageKey: 'live', text: '', live: true),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (draft.hasReasoning)
          Padding(
            padding: EdgeInsets.only(bottom: tokens.space.sm),
            child: ReasoningRegion(
              key: ValueKey('r:${draft.messageId}'),
              storageKey: 'r:${draft.messageId}',
              text: draft.reasoning,
              live: draft.isThinking,
              duration: draft.reasoningDuration,
              redacted: draft.reasoningRedacted,
            ),
          ),
        if (draft.text.isNotEmpty)
          Padding(
            padding: EdgeInsets.only(bottom: tokens.space.sm),
            child: _StreamingText(text: draft.text, callbacks: callbacks),
          ),
        for (final c in draft.toolCalls)
          Padding(
            padding: EdgeInsets.only(bottom: tokens.space.sm),
            child: ToolCallCard(
              key: ValueKey('tool:${c.id}'),
              sessionId: sessionId,
              callId: c.id,
              toolName: c.name,
              draftArgs: c.complete ? null : c.argsText,
            ),
          ),
      ],
    );
  }
}

/// Streaming Markdown, safe for screen readers.
///
/// The streaming text is never a live region (it would re-announce the
/// whole message on every token). With TalkBack/VoiceOver on, the node only
/// exposes text up to the last finished sentence, so a focused user doesn't
/// hear it rewrite under them (docs/research/12 §1.8).
class _StreamingText extends StatelessWidget {
  const _StreamingText({required this.text, required this.callbacks});

  final String text;
  final AssistantTurnCallbacks callbacks;

  static final RegExp _sentenceEnd = RegExp(r'[.!?…。！？](\s|$)|\n\n');

  @override
  Widget build(BuildContext context) {
    final markdown = StreamingMarkdown(
      text: text,
      streaming: true,
      selectable: false,
      style: chatMarkdownStyle(context),
      onLinkTap: callbacks.onLinkTap,
      onCopyCode: callbacks.onCopyCode,
    );
    if (!MediaQuery.accessibleNavigationOf(context)) return markdown;
    var stable = 0;
    for (final m in _sentenceEnd.allMatches(text)) {
      stable = m.end;
    }
    return Semantics(
      label: text.substring(0, stable).trim(),
      child: ExcludeSemantics(child: markdown),
    );
  }
}
