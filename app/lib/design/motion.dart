import 'package:material_ui/material_ui.dart';

import 'tokens.dart';

/// True when the user asked the OS for less motion.
///
/// Two independent signals, and we need both:
/// - Android "Remove animations" sets `MediaQuery.disableAnimations`;
/// - iOS "Reduce Motion" only appears as `AccessibilityFeatures.reduceMotion`
///   and never reaches MediaQuery (docs/research/12 §0 fact 8).
bool platformPrefersReducedMotion(BuildContext context) {
  final disable = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
  final view = View.maybeOf(context);
  final reduce = view?.platformDispatcher.accessibilityFeatures.reduceMotion ?? false;
  return disable || reduce;
}

/// [MotionTokens.style] of the ambient theme: pass it to every sheet,
/// dialog and expansion tile (`sheetAnimationStyle:`, `animationStyle:`,
/// `expansionAnimationStyle:`), which ignore reduced motion otherwise.
AnimationStyle? motionStyleOf(BuildContext context) => SherpaTokens.maybeOf(context)?.motion.style;

/// A [MaterialPageRoute] for the few pages pushed imperatively (camera
/// scanners, the diagnostics preview). Like `SherpaPage`, it keeps the
/// platform transition but takes zero time under reduced motion; the back
/// gesture still tracks the finger, because the user drives that motion.
class MotionPageRoute<T> extends MaterialPageRoute<T> {
  MotionPageRoute({required super.builder, super.settings});

  bool get _reduced {
    final ctx = navigator?.context;
    return ctx != null && (SherpaTokens.maybeOf(ctx)?.motion.reduced ?? false);
  }

  @override
  Duration get transitionDuration => _reduced ? Duration.zero : super.transitionDuration;

  @override
  Duration get reverseTransitionDuration => _reduced ? Duration.zero : super.reverseTransitionDuration;
}

/// Re-publishes the theme with [MotionTokens.reduced] resolved from the
/// platform, so every `SherpaTokens.of(context).motion` read below it is
/// already correct and feature code never checks accessibility flags itself.
///
/// Place it in `MaterialApp.builder` (above the Navigator, below the theme).
/// It listens to `didChangeAccessibilityFeatures` because a change to
/// `reduceMotion` alone leaves MediaQueryData equal and would not rebuild us.
class MotionScope extends StatefulWidget {
  const MotionScope({super.key, required this.child});

  final Widget child;

  @override
  State<MotionScope> createState() => _MotionScopeState();
}

class _MotionScopeState extends State<MotionScope> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAccessibilityFeatures() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<SherpaTokens>();
    final reduced = platformPrefersReducedMotion(context);
    if (tokens == null || tokens.motion.reduced == reduced) return widget.child;
    final extensions = {...theme.extensions}..[SherpaTokens] = tokens.copyWith(motion: MotionTokens(reduced: reduced));
    return Theme(data: theme.copyWith(extensions: extensions.values), child: widget.child);
  }
}
