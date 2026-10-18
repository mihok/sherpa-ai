import 'package:material_ui/material_ui.dart';
import 'package:sherpa_markdown/sherpa_markdown.dart';

import '../../../design/tokens.dart';

/// Longest comfortable line for reading prose on tablets and foldables.
/// Layout, not a style token: the transcript centers content at this width.
const double kChatReadableWidth = 760;

/// Chrome (badges, counters, chips in the app bar) may scale with the
/// user's text size only this far; message text is never clamped
/// (docs/research/12 §1.7).
const double kChromeMaxTextScale = 1.3;

/// Icon sizes for dense chat chrome (Material's default 24 is used
/// everywhere else).
abstract final class ChatIconSize {
  static const double small = 16;
  static const double medium = 20;
}

/// Motion for the chat, honouring every reduce-motion signal.
///
/// iOS Reduce Motion does not set `MediaQuery.disableAnimations` (only
/// Android's "Remove animations" does), so both flags are combined here on
/// top of whatever the design system already decided.
MotionTokens chatMotionOf(BuildContext context) {
  final tokens = SherpaTokens.of(context).motion;
  if (tokens.reduced) return tokens;
  final reduce = MediaQuery.disableAnimationsOf(context) ||
      View.of(context).platformDispatcher.accessibilityFeatures.reduceMotion;
  return reduce ? const MotionTokens(reduced: true) : tokens;
}

/// Monospace for arguments, results and code-like text.
TextStyle chatMonoStyle(BuildContext context, {Color? color}) {
  final base = Theme.of(context).textTheme.bodySmall!;
  return base.copyWith(
    fontFamily: 'monospace',
    fontFamilyFallback: const ['RobotoMono', 'Menlo', 'Courier New', 'Courier'],
    color: color ?? Theme.of(context).colorScheme.onSurface,
    height: 1.45,
  );
}

/// Markdown colors and text styles derived from the theme, so
/// `sherpa_markdown` never needs the app's tokens.
SherpaMarkdownStyle chatMarkdownStyle(BuildContext context, {Color? color, TextStyle? body}) {
  final theme = Theme.of(context);
  final tokens = SherpaTokens.of(context);
  final text = body ?? theme.textTheme.bodyLarge!;
  return SherpaMarkdownStyle(
    body: text.copyWith(color: color ?? theme.colorScheme.onSurface, height: 1.5),
    code: chatMonoStyle(context, color: color),
    codeBackground: tokens.semantic.codeSurface,
    quoteColor: theme.colorScheme.outlineVariant,
    linkColor: theme.colorScheme.primary,
    dividerColor: theme.colorScheme.outlineVariant,
  );
}

/// "0.4 s", "12 s", "2 min 5 s".
String formatToolDuration(Duration d) {
  final ms = d.inMilliseconds;
  if (ms < 10000) return '${(ms / 1000).toStringAsFixed(1)} s';
  if (d.inSeconds < 60) return '${d.inSeconds} s';
  final s = d.inSeconds % 60;
  return s == 0 ? '${d.inMinutes} min' : '${d.inMinutes} min $s s';
}

/// "Thought for 12s" style durations: whole seconds, minimum 1.
String formatThoughtDuration(Duration d) {
  final s = (d.inMilliseconds / 1000).round();
  if (s < 60) return '${s < 1 ? 1 : s}s';
  final m = s ~/ 60;
  final r = s % 60;
  return r == 0 ? '${m}m' : '${m}m ${r}s';
}

/// Centers [child] at [kChatReadableWidth] with the standard side gutter.
class ReadableWidth extends StatelessWidget {
  const ReadableWidth({super.key, required this.child, this.horizontalPadding});

  final Widget child;
  final double? horizontalPadding;

  @override
  Widget build(BuildContext context) {
    final space = SherpaTokens.of(context).space;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: kChatReadableWidth),
        // Full width up to the maximum, so end-aligned content (user
        // bubbles) really sits at the end instead of shrink-wrapping.
        child: SizedBox(
          width: double.infinity,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: horizontalPadding ?? space.lg),
            child: child,
          ),
        ),
      ),
    );
  }
}
