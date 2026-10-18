import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../../../design/tokens.dart';
import '../../../state/providers.dart';
import '../state/chat_controller.dart';
import '../state/chat_dependencies.dart';
import '../state/transcript_model.dart';
import 'chat_style.dart';
import 'json_view.dart';

/// Status pill for a tool call: icon + label, never color alone.
class ToolStatusChip extends StatelessWidget {
  const ToolStatusChip({super.key, required this.status});

  final ToolRunStatus status;

  static String labelOf(ToolRunStatus s) => switch (s) {
        ToolRunStatus.preparing => 'Preparing',
        ToolRunStatus.pending => 'Queued',
        ToolRunStatus.awaitingApproval => 'Needs approval',
        ToolRunStatus.running => 'Running',
        ToolRunStatus.succeeded => 'Done',
        ToolRunStatus.failed => 'Failed',
        ToolRunStatus.denied => 'Denied',
        ToolRunStatus.cancelled => 'Cancelled',
      };

  @override
  Widget build(BuildContext context) {
    final tokens = SherpaTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final reduced = chatMotionOf(context).reduced;
    final color = switch (status) {
      ToolRunStatus.succeeded => tokens.semantic.success,
      ToolRunStatus.failed => tokens.semantic.danger,
      ToolRunStatus.awaitingApproval => tokens.semantic.warning,
      ToolRunStatus.running => scheme.primary,
      _ => scheme.onSurfaceVariant,
    };
    final Widget icon = status == ToolRunStatus.running && !reduced
        ? SizedBox.square(
            dimension: ChatIconSize.small - 2,
            child: CircularProgressIndicator(strokeWidth: 2, color: color),
          )
        : Icon(
            switch (status) {
              ToolRunStatus.preparing => Icons.more_horiz_rounded,
              ToolRunStatus.pending => Icons.schedule_rounded,
              ToolRunStatus.awaitingApproval => Icons.front_hand_outlined,
              ToolRunStatus.running => Icons.autorenew_rounded,
              ToolRunStatus.succeeded => Icons.check_circle_rounded,
              ToolRunStatus.failed => Icons.error_rounded,
              ToolRunStatus.denied => Icons.block_rounded,
              ToolRunStatus.cancelled => Icons.cancel_outlined,
            },
            size: ChatIconSize.small,
            color: color,
          );
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: kChromeMaxTextScale,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: tokens.space.sm, vertical: tokens.space.xxs),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(tokens.radius.pill),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            icon,
            SizedBox(width: tokens.space.xs),
            Text(
              labelOf(status),
              style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.onSurface),
            ),
          ],
        ),
      ),
    );
  }
}

/// One tool call as a first-class card.
///
/// Collapsed it is a single calm row (icon, name, status, duration);
/// expanded it shows the exact arguments, the result and any error. While
/// the model is still writing the call, [draftArgs] streams in raw.
class ToolCallCard extends ConsumerStatefulWidget {
  const ToolCallCard({
    super.key,
    required this.sessionId,
    required this.callId,
    required this.toolName,
    this.arguments,
    this.draftArgs,
  });

  final String sessionId;
  final String callId;
  final String toolName;
  final JsonMap? arguments;

  /// Raw JSON fragments while the call is being generated.
  final String? draftArgs;

  @override
  ConsumerState<ToolCallCard> createState() => _ToolCallCardState();
}

class _ToolCallCardState extends ConsumerState<ToolCallCard> {
  bool _expanded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final stored = PageStorage.maybeOf(context)?.readState(context, identifier: 'tool:${widget.callId}');
    if (stored is bool) _expanded = stored;
  }

  void _toggle() {
    setState(() => _expanded = !_expanded);
    PageStorage.maybeOf(context)?.writeState(context, _expanded, identifier: 'tool:${widget.callId}');
  }

  Future<void> _copy(String text) async {
    await ref.read(chatPlatformProvider).copyText(text);
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('Copied'), duration: Duration(seconds: 2)));
  }

  @override
  Widget build(BuildContext context) {
    final exec = ref.watch(chatControllerProvider(widget.sessionId).select((s) => s.tools[widget.callId]));
    final tokens = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final motion = chatMotionOf(context);
    final status = widget.draftArgs != null ? ToolRunStatus.preparing : (exec?.status ?? ToolRunStatus.pending);
    final name = exec?.displayName ?? ref.read(toolRouterProvider).lookup(widget.toolName)?.displayName ?? widget.toolName;
    final running = status == ToolRunStatus.running;
    final progress = exec?.progress;

    final header = InkWell(
      onTap: _toggle,
      borderRadius: BorderRadius.circular(tokens.radius.md),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: tokens.space.minTouchTarget),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: tokens.space.md, vertical: tokens.space.sm),
          child: Row(
            children: [
              Icon(
                widget.toolName == UpdatePlanTool.toolName ? Icons.checklist_rounded : Icons.handyman_outlined,
                size: ChatIconSize.medium,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              SizedBox(width: tokens.space.md),
              Expanded(
                child: Wrap(
                  spacing: tokens.space.sm,
                  runSpacing: tokens.space.xs,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall),
                    ToolStatusChip(status: status),
                    if (exec?.duration != null)
                      Text(
                        formatToolDuration(exec!.duration!),
                        style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                  ],
                ),
              ),
              AnimatedRotation(
                turns: _expanded ? 0.5 : 0,
                duration: motion.fast,
                curve: motion.standard,
                child: Icon(Icons.expand_more_rounded, color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );

    return Semantics(
      container: true,
      button: true,
      expanded: _expanded,
      label: 'Tool $name, ${ToolStatusChip.labelOf(status)}'
          '${exec?.duration == null ? '' : ', took ${formatToolDuration(exec!.duration!)}'}',
      hint: _expanded ? 'Hide details' : 'Show details',
      excludeSemantics: !_expanded,
      onTap: _toggle,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tokens.semantic.toolSurface,
          borderRadius: BorderRadius.circular(tokens.radius.md),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              if (running || (exec?.progressMessage != null && status.isActive))
                Padding(
                  padding: EdgeInsets.fromLTRB(tokens.space.md, 0, tokens.space.md, tokens.space.sm),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (exec?.progressMessage != null)
                        Padding(
                          padding: EdgeInsets.only(bottom: tokens.space.xs),
                          child: Text(
                            exec!.progressMessage!,
                            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                          ),
                        ),
                      if (running)
                        ClipRRect(
                          borderRadius: BorderRadius.circular(tokens.radius.pill),
                          child: LinearProgressIndicator(
                            value: progress,
                            minHeight: tokens.space.xs,
                            semanticsLabel: '$name progress',
                            semanticsValue: progress == null ? null : '${(progress * 100).round()}%',
                          ),
                        ),
                    ],
                  ),
                ),
              AnimatedSize(
                duration: motion.medium,
                curve: motion.standard,
                alignment: Alignment.topCenter,
                child: _expanded ? _details(context, exec) : const SizedBox(width: double.infinity),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _details(BuildContext context, ToolExecutionView? exec) {
    final tokens = SherpaTokens.of(context);
    final theme = Theme.of(context);
    Widget label(String text) => Padding(
          padding: EdgeInsets.only(top: tokens.space.md, bottom: tokens.space.xs),
          child: Text(text, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        );
    return Padding(
      padding: EdgeInsets.fromLTRB(tokens.space.md, 0, tokens.space.md, tokens.space.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (exec?.sourceLabel != null)
            Text(
              'Source: ${exec!.sourceLabel}',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          if (widget.draftArgs != null) ...[
            label('Arguments (writing…)'),
            _DraftArgs(text: widget.draftArgs!),
          ] else ...[
            label('Arguments'),
            JsonPreview(value: widget.arguments ?? const {}, onCopy: _copy, copyLabel: 'Copy arguments'),
          ],
          if (exec?.structured != null) ...[
            label('Result'),
            JsonPreview(value: exec!.structured, onCopy: _copy, copyLabel: 'Copy result'),
          ] else if (exec?.resultText != null && exec!.resultText!.isNotEmpty) ...[
            label('Result'),
            _ResultText(text: exec.resultText!, onCopy: _copy),
          ],
          if (exec?.errorText != null) ...[
            label(exec!.status == ToolRunStatus.failed ? 'Error' : 'Why it did not run'),
            SelectableText(
              exec.errorText!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: exec.status == ToolRunStatus.failed ? tokens.semantic.danger : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Arguments as they stream: the tail of the raw JSON, monospace.
class _DraftArgs extends StatelessWidget {
  const _DraftArgs({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final tokens = SherpaTokens.of(context);
    const tail = 600;
    final shown = text.length > tail ? '…${text.substring(text.length - tail)}' : text;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.semantic.codeSurface,
        borderRadius: BorderRadius.circular(tokens.radius.sm),
      ),
      child: Padding(
        padding: EdgeInsets.all(tokens.space.md),
        child: Text(shown.isEmpty ? ' ' : shown, style: chatMonoStyle(context)),
      ),
    );
  }
}

/// Plain-text tool output, shortened until expanded.
class _ResultText extends StatefulWidget {
  const _ResultText({required this.text, required this.onCopy});

  final String text;
  final void Function(String text) onCopy;

  @override
  State<_ResultText> createState() => _ResultTextState();
}

class _ResultTextState extends State<_ResultText> {
  static const int _preview = 1200;
  bool _all = false;

  @override
  Widget build(BuildContext context) {
    final tokens = SherpaTokens.of(context);
    final long = widget.text.length > _preview;
    final shown = _all || !long ? widget.text : '${widget.text.substring(0, _preview)}…';
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.semantic.codeSurface,
        borderRadius: BorderRadius.circular(tokens.radius.sm),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(tokens.space.md, tokens.space.sm, tokens.space.xs, tokens.space.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(top: tokens.space.xs),
                    child: SelectableText(shown, style: chatMonoStyle(context)),
                  ),
                ),
                IconButton(
                  tooltip: 'Copy result',
                  icon: const Icon(Icons.copy_rounded),
                  iconSize: ChatIconSize.medium,
                  onPressed: () => widget.onCopy(widget.text),
                ),
              ],
            ),
            if (long)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton(
                  onPressed: () => setState(() => _all = !_all),
                  child: Text(_all ? 'Show less' : 'Show all ${widget.text.length} characters'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Consecutive tool calls as one "Ran 3 tools" row (ChatGPT/Codex
/// pattern). Expanded by default while any call is still active so the
/// user watches live work; collapsed once everything finished, unless the
/// user chose otherwise.
class ToolGroupView extends ConsumerStatefulWidget {
  const ToolGroupView({super.key, required this.sessionId, required this.groupKey, required this.calls});

  final String sessionId;
  final String groupKey;
  final List<ToolCall> calls;

  @override
  ConsumerState<ToolGroupView> createState() => _ToolGroupViewState();
}

class _ToolGroupViewState extends ConsumerState<ToolGroupView> {
  bool? _override;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final stored = PageStorage.maybeOf(context)?.readState(context, identifier: 'group:${widget.groupKey}');
    if (stored is bool) _override = stored;
  }

  void _toggle(bool expanded) {
    setState(() => _override = !expanded);
    PageStorage.maybeOf(context)?.writeState(context, _override, identifier: 'group:${widget.groupKey}');
  }

  @override
  Widget build(BuildContext context) {
    final calls = widget.calls;
    if (calls.length == 1) {
      final c = calls.single;
      return ToolCallCard(
        key: ValueKey('tool:${c.id}'),
        sessionId: widget.sessionId,
        callId: c.id,
        toolName: c.name,
        arguments: c.arguments,
      );
    }
    final (active, failed, denied) = ref.watch(chatControllerProvider(widget.sessionId).select((s) {
      var a = 0, f = 0, d = 0;
      for (final c in calls) {
        final st = s.tools[c.id]?.status ?? ToolRunStatus.pending;
        if (st.isActive) a++;
        if (st == ToolRunStatus.failed) f++;
        if (st == ToolRunStatus.denied) d++;
      }
      return (a, f, d);
    }));
    final expanded = _override ?? active > 0;
    final tokens = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final motion = chatMotionOf(context);
    final n = calls.length;
    final title = active > 0 ? 'Running $n tools…' : 'Ran $n tools';
    final extra = [if (failed > 0) '$failed failed', if (denied > 0) '$denied denied'].join(' · ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          button: true,
          expanded: expanded,
          label: extra.isEmpty ? title : '$title, $extra',
          excludeSemantics: true,
          onTap: () => _toggle(expanded),
          child: InkWell(
            onTap: () => _toggle(expanded),
            borderRadius: BorderRadius.circular(tokens.radius.md),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: tokens.space.minTouchTarget),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: tokens.space.xs, vertical: tokens.space.sm),
                child: Row(
                  children: [
                    Icon(Icons.layers_outlined, size: ChatIconSize.medium, color: theme.colorScheme.onSurfaceVariant),
                    SizedBox(width: tokens.space.sm),
                    Flexible(
                      child: Text.rich(
                        TextSpan(children: [
                          TextSpan(text: title, style: theme.textTheme.titleSmall),
                          if (extra.isNotEmpty)
                            TextSpan(
                              text: '  ·  $extra',
                              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                            ),
                        ]),
                      ),
                    ),
                    AnimatedRotation(
                      turns: expanded ? 0.5 : 0,
                      duration: motion.fast,
                      child: Icon(Icons.expand_more_rounded, color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        AnimatedSize(
          duration: motion.medium,
          curve: motion.standard,
          alignment: Alignment.topCenter,
          child: expanded
              ? Padding(
                  padding: EdgeInsetsDirectional.only(start: tokens.space.lg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final c in calls)
                        Padding(
                          padding: EdgeInsets.only(bottom: tokens.space.sm),
                          child: ToolCallCard(
                            key: ValueKey('tool:${c.id}'),
                            sessionId: widget.sessionId,
                            callId: c.id,
                            toolName: c.name,
                            arguments: c.arguments,
                          ),
                        ),
                    ],
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}
