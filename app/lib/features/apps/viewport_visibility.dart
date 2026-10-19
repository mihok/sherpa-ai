import 'dart:async';

import 'package:material_ui/material_ui.dart';

/// Reports whether [child] is on screen: inside its scroll view's viewport
/// (or the screen, outside one) and on a route that is not covered.
/// WebViews cannot see native scrolling (`IntersectionObserver` inside a
/// View doesn't), so the host must decide (R03 §11.6.9).
class ViewportVisibility extends StatefulWidget {
  const ViewportVisibility({super.key, required this.onChanged, required this.child});

  final ValueChanged<bool> onChanged;
  final Widget child;

  @override
  State<ViewportVisibility> createState() => _ViewportVisibilityState();
}

class _ViewportVisibilityState extends State<ViewportVisibility> with WidgetsBindingObserver {
  ScrollPosition? _position;
  bool? _last;
  bool _scheduled = false;

  /// False while the route is covered by an opaque page (the Overlay keeps
  /// it offstage with tickers off).
  bool _onstage = true;
  Size _screen = Size.zero;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _onstage = TickerMode.valuesOf(context).enabled;
    _screen = MediaQuery.sizeOf(context);
    final p = Scrollable.maybeOf(context)?.position;
    if (!identical(p, _position)) {
      _position?.removeListener(_schedule);
      _position = p;
      _position?.addListener(_schedule);
    }
    _schedule();
  }

  @override
  void didUpdateWidget(ViewportVisibility old) {
    super.didUpdateWidget(old);
    _schedule();
  }

  @override
  void didChangeMetrics() => _schedule();

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _position?.removeListener(_schedule);
    // Not now: the tree is locked while it unmounts.
    final report = widget.onChanged;
    if (_last == true) scheduleMicrotask(() => report(false));
    super.dispose();
  }

  void _schedule() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted) _check();
    });
  }

  void _check() {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return;
    var visible = _onstage;
    if (visible) {
      final viewport = _viewportRect();
      final rect = box.localToGlobal(Offset.zero) & box.size;
      final overlap = rect.intersect(viewport);
      visible = overlap.width > 0 && overlap.height > 0;
    }
    if (visible != _last) {
      _last = visible;
      widget.onChanged(visible);
    }
  }

  Rect _viewportRect() {
    final scroll = Scrollable.maybeOf(context)?.context.findRenderObject();
    if (scroll is RenderBox && scroll.attached && scroll.hasSize) return scroll.localToGlobal(Offset.zero) & scroll.size;
    return Offset.zero & _screen;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
