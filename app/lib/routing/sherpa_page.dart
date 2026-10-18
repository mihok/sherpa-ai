import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';

import '../design/tokens.dart';
import '../shell/shell_layout.dart';

/// The page type for every route in the app.
///
/// It behaves like a [MaterialPage] (platform transitions: predictive back
/// on Android, the Cupertino swipe on iOS) with three adjustments that a
/// stock page can't make:
/// - Reduced motion: programmatic transitions take zero time, while the
///   back *gesture* still tracks the finger (users drive that motion).
/// - Pane roots: in the two-pane layout the chat (or settings) page fills
///   the detail pane only. It cross-fades instead of sliding the whole
///   window, and it doesn't imply a back button, because the list on the
///   left is the navigation.
/// - The route type never changes with window size, so a fold/unfold keeps
///   the page's state.
class SherpaPage<T> extends Page<T> {
  const SherpaPage({
    required this.child,
    this.role = PaneRole.page,
    super.key,
    super.name,
    super.arguments,
    super.restorationId,
  });

  final Widget child;

  final PaneRole role;

  @override
  Route<T> createRoute(BuildContext context) => _SherpaPageRoute<T>(page: this);
}

/// How a page relates to the adaptive shell.
enum PaneRole {
  /// An ordinary pushed page (forms, sub-settings): normal transitions,
  /// back button.
  page,

  /// Fills the detail pane next to the sessions list (a chat).
  detail,

  /// A rail destination's root (settings): the rail is the navigation.
  destination,
}

class _SherpaPageRoute<T> extends PageRoute<T> with MaterialRouteTransitionMixin<T> {
  _SherpaPageRoute({required SherpaPage<T> page}) : super(settings: page);

  SherpaPage<T> get _page => settings as SherpaPage<T>;

  bool? _lastInPane;

  bool _inPane(BuildContext context, {bool listen = false}) {
    final layout = listen ? ShellLayout.maybeOf(context) : ShellLayout.peek(context);
    if (layout == null) return false;
    return switch (_page.role) {
      PaneRole.page => false,
      PaneRole.detail => layout.twoPane,
      PaneRole.destination => layout.rail,
    };
  }

  bool get _reducedMotion {
    final ctx = navigator?.context;
    return ctx != null && (SherpaTokens.maybeOf(ctx)?.motion.reduced ?? false);
  }

  @override
  Widget buildContent(BuildContext context) => _page.child;

  @override
  bool get maintainState => true;

  @override
  bool get fullscreenDialog => false;

  @override
  Duration get transitionDuration {
    if (_reducedMotion) return Duration.zero;
    final ctx = navigator?.context;
    if (ctx != null && _inPane(ctx)) return SherpaTokens.of(ctx).motion.medium;
    return super.transitionDuration;
  }

  @override
  Duration get reverseTransitionDuration {
    if (_reducedMotion) return Duration.zero;
    final ctx = navigator?.context;
    if (ctx != null && _inPane(ctx)) return SherpaTokens.of(ctx).motion.medium;
    return super.reverseTransitionDuration;
  }

  @override
  bool get impliesAppBarDismissal {
    final ctx = navigator?.context;
    if (ctx != null && _inPane(ctx)) return false;
    return super.impliesAppBarDismissal;
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final inPane = _inPane(context, listen: true);
    if (_lastInPane != null && _lastInPane != inPane) {
      // The window crossed the two-pane breakpoint: the back button rule
      // changed, so let AppBars below re-read impliesAppBarDismissal.
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (isActive) changedInternalState();
      });
    }
    _lastInPane = inPane;
    if (inPane) {
      final motion = SherpaTokens.of(context).motion;
      return FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: motion.decelerate, reverseCurve: motion.accelerate),
        child: child,
      );
    }
    return super.buildTransitions(context, animation, secondaryAnimation, child);
  }

  @override
  String get debugLabel => '${super.debugLabel}(${_page.name})';
}
