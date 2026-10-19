import 'package:material_ui/material_ui.dart';
import 'package:sherpa_markdown/sherpa_markdown.dart';

import '../../../design/tokens.dart';
import 'chat_style.dart';

/// The model's reasoning: one dimmed line, collapsed by default.
///
/// "Thinking…" while it streams, then "Thought for 12s"; expand to read.
/// Raw chain-of-thought is never expanded by default (docs/PLAN.md open
/// question 4; docs/research/12 §2), and the answer is never interleaved
/// with it.
class ReasoningRegion extends StatefulWidget {
  const ReasoningRegion({
    super.key,
    required this.storageKey,
    required this.text,
    this.live = false,
    this.duration,
    this.redacted = false,
  });

  /// Identifies this region for remembering expansion while scrolling.
  final String storageKey;
  final String text;
  final bool live;
  final Duration? duration;

  /// Encrypted by the provider: nothing to show beyond the fact.
  final bool redacted;

  @override
  State<ReasoningRegion> createState() => _ReasoningRegionState();
}

class _ReasoningRegionState extends State<ReasoningRegion> {
  bool _expanded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final stored = PageStorage.maybeOf(context)?.readState(context, identifier: 'reason:${widget.storageKey}');
    if (stored is bool) _expanded = stored;
  }

  bool get _canExpand => widget.text.trim().isNotEmpty;

  void _toggle() {
    if (!_canExpand) return;
    setState(() => _expanded = !_expanded);
    PageStorage.maybeOf(context)?.writeState(context, _expanded, identifier: 'reason:${widget.storageKey}');
  }

  String get _label {
    if (widget.live) return 'Thinking…';
    final d = widget.duration;
    final base = d == null ? 'Thought process' : 'Thought for ${formatThoughtDuration(d)}';
    return widget.redacted && !_canExpand ? '$base (hidden by the provider)' : base;
  }

  @override
  Widget build(BuildContext context) {
    final tokens = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final motion = chatMotionOf(context);
    final dim = tokens.semantic.reasoning;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          container: true,
          button: _canExpand,
          expanded: _canExpand ? _expanded : null,
          label: _label,
          hint: _canExpand ? (_expanded ? 'Hide reasoning' : 'Show reasoning') : null,
          excludeSemantics: true,
          onTap: _canExpand ? _toggle : null,
          child: InkWell(
            onTap: _canExpand ? _toggle : null,
            borderRadius: BorderRadius.circular(tokens.radius.sm),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: tokens.space.minTouchTarget),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: tokens.space.xs),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.live)
                      ThinkingPulse(color: dim)
                    else
                      Icon(Icons.lightbulb_outline_rounded, size: ChatIconSize.medium, color: dim),
                    SizedBox(width: tokens.space.sm),
                    Flexible(
                      child: Text(_label, style: theme.textTheme.labelLarge?.copyWith(color: dim)),
                    ),
                    if (_canExpand)
                      AnimatedRotation(
                        // The chevron mirrors in RTL (it points to the start
                        // edge), so it turns the other way to point down.
                        turns: _expanded ? (Directionality.of(context) == TextDirection.rtl ? -0.25 : 0.25) : 0,
                        duration: motion.fast,
                        child: Icon(Icons.chevron_right_rounded, size: ChatIconSize.medium, color: dim),
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
          child: _expanded && _canExpand
              ? Container(
                  margin: EdgeInsetsDirectional.only(start: tokens.space.md, bottom: tokens.space.sm),
                  padding: EdgeInsetsDirectional.only(start: tokens.space.md),
                  decoration: BoxDecoration(
                    border: BorderDirectional(start: BorderSide(color: theme.colorScheme.outlineVariant, width: 2)),
                  ),
                  child: StreamingMarkdown(
                    text: widget.text,
                    streaming: widget.live,
                    selectable: !widget.live,
                    style: chatMarkdownStyle(context, color: dim, body: theme.textTheme.bodyMedium),
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}

/// A slowly breathing dot: "the model is working", without per-token
/// motion. Static when the user asked for reduced motion.
class ThinkingPulse extends StatefulWidget {
  const ThinkingPulse({super.key, required this.color});

  final Color color;

  @override
  State<ThinkingPulse> createState() => _ThinkingPulseState();
}

class _ThinkingPulseState extends State<ThinkingPulse> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final motion = chatMotionOf(context);
    // A breath, not a blink: several "slow" steps per half-cycle.
    _c.duration = motion.slow * 3;
    if (motion.reduced) {
      _c
        ..stop()
        ..value = 1;
    } else if (!_c.isAnimating) {
      _c.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: ChatIconSize.medium,
      child: Center(
        child: FadeTransition(
          opacity: Tween<double>(begin: 0.35, end: 1).animate(CurvedAnimation(parent: _c, curve: Curves.easeInOut)),
          child: Container(
            width: ChatIconSize.small / 2,
            height: ChatIconSize.small / 2,
            decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
          ),
        ),
      ),
    );
  }
}
