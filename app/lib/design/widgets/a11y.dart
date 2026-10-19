import 'package:material_ui/material_ui.dart';

/// A heading for screen readers.
///
/// Sets both flags because they do different jobs since Flutter 3.47:
/// `headingLevel` is what TalkBack and VoiceOver announce and navigate as
/// a heading (Android `setHeading`, iOS `UIAccessibilityTraitHeader`);
/// `header: true` alone is not, but iOS scrolls a focused header into view
/// and Android reports it in list item info. Level 1 is the page title
/// (app bar), 2 a section, 3 a group inside one.
///
/// It is always its own node (`container`): otherwise the text that
/// follows it in the same column would be merged into it, and a screen
/// reader would read a paragraph as the heading.
///
/// [value] is spoken after the title without changing what is drawn, for
/// counts a sighted user reads off the list below ("3 models").
class Heading extends StatelessWidget {
  const Heading({super.key, required this.child, this.level = 2, this.value});

  final Widget child;
  final int level;
  final String? value;

  @override
  Widget build(BuildContext context) =>
      Semantics(container: true, header: true, headingLevel: level, value: value, child: child);
}

/// A group (a card, a section's column) with a [Heading] in it, read in
/// order: the heading, then each line and control as its own node.
///
/// Without it, the text and tiles next to a heading merge into one node
/// that wraps the heading's node, so a screen reader reads them first and
/// the heading last. (A `ListView` or scroll view already keeps its direct
/// children apart; a column inside one of its items does not.)
class HeadingGroup extends StatelessWidget {
  const HeadingGroup({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Semantics(container: true, explicitChildNodes: true, child: child);
}

/// A polite live region whose announcement changes only at milestones.
///
/// Screen readers announce a live region when its own label changes
/// (Android: `didChangeLabel` on an `IS_LIVE_REGION` node; iOS: the same
/// check in `nodeShouldTriggerAnnouncement`). Feeding it fast-moving text
/// (bytes downloaded, tokens per second) would talk over the user several
/// times a second, so [message] carries only what is worth an interruption
/// (a phase change, every 25 %; see [progressMilestone]). [child] keeps its
/// own semantics in separate nodes (`explicitChildNodes`), readable on focus
/// but never announced by itself.
class LiveAnnouncement extends StatelessWidget {
  const LiveAnnouncement({super.key, required this.message, required this.child});

  final String message;
  final Widget child;

  @override
  Widget build(BuildContext context) => Semantics(
        container: true,
        liveRegion: true,
        explicitChildNodes: true,
        label: message,
        child: child,
      );
}

/// The last [step] percent milestone [fraction] has reached (0, 25, 50, 75
/// or 100 by default); 0 when the progress is unknown.
int progressMilestone(double? fraction, {int step = 25}) {
  if (fraction == null || !fraction.isFinite) return 0;
  return ((fraction.clamp(0.0, 1.0) * 100).floor() ~/ step) * step;
}
