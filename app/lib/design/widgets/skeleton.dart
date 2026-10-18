import 'package:material_ui/material_ui.dart';

import '../tokens.dart';

/// Placeholder block with a slow, low-contrast pulse.
///
/// Skeletons keep layout stable while content loads (no jump when it
/// arrives). Under reduced motion the pulse stops and a static block shows.
class Skeleton extends StatefulWidget {
  const Skeleton({super.key, this.width, this.height = 14, this.radius});

  final double? width;
  final double height;
  final double? radius;

  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final period = SherpaTokens.of(context).motion.ambient;
    if (period == Duration.zero) {
      _controller
        ..stop()
        ..value = 0.5;
    } else if (!_controller.isAnimating || _controller.duration != period) {
      _controller
        ..duration = period
        ..repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          color: Color.lerp(scheme.surfaceContainerHigh, scheme.surfaceContainerHighest, _controller.value),
          borderRadius: BorderRadius.circular(widget.radius ?? t.radius.sm),
        ),
      ),
    );
  }
}

/// A list row's worth of skeleton: title line + subtitle line.
class SkeletonListTile extends StatelessWidget {
  const SkeletonListTile({super.key, this.titleWidthFactor = 0.6});

  final double titleWidthFactor;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: t.space.lg, vertical: t.space.md),
      child: LayoutBuilder(
        builder: (context, c) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Skeleton(width: c.maxWidth * titleWidthFactor, height: 16),
            SizedBox(height: t.space.sm),
            Skeleton(width: c.maxWidth * 0.35, height: 12),
          ],
        ),
      ),
    );
  }
}

/// Several skeleton rows, announced once as "Loading" to screen readers.
class SkeletonList extends StatelessWidget {
  const SkeletonList({super.key, this.count = 6, this.label = 'Loading'});

  final int count;
  final String label;

  @override
  Widget build(BuildContext context) => Semantics(
        label: label,
        excludeSemantics: true,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < count; i++) SkeletonListTile(titleWidthFactor: i.isEven ? 0.62 : 0.48),
          ],
        ),
      );
}
