import 'package:material_ui/material_ui.dart';

/// Sherpa's mark: two peaks and a trail, drawn from the color scheme so it
/// follows dynamic color and dark mode. Decorative, so excluded from
/// semantics; pair it with real text.
class SherpaMark extends StatelessWidget {
  const SherpaMark({super.key, this.size = 72});

  final double size;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: size,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: s.primaryContainer,
            borderRadius: BorderRadius.circular(size * 0.3),
          ),
          child: CustomPaint(
            painter: _PeaksPainter(front: s.primary, back: s.onPrimaryContainer.withValues(alpha: 0.35), trail: s.surface),
          ),
        ),
      ),
    );
  }
}

class _PeaksPainter extends CustomPainter {
  _PeaksPainter({required this.front, required this.back, required this.trail});

  final Color front;
  final Color back;
  final Color trail;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final backPeak = Path()
      ..moveTo(w * 0.44, h * 0.74)
      ..lineTo(w * 0.66, h * 0.34)
      ..lineTo(w * 0.86, h * 0.74)
      ..close();
    final frontPeak = Path()
      ..moveTo(w * 0.14, h * 0.74)
      ..lineTo(w * 0.42, h * 0.24)
      ..lineTo(w * 0.70, h * 0.74)
      ..close();
    canvas
      ..drawPath(backPeak, Paint()..color = back)
      ..drawPath(frontPeak, Paint()..color = front);
    final trailPaint = Paint()
      ..color = trail
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.035
      ..strokeCap = StrokeCap.round;
    final trailPath = Path()
      ..moveTo(w * 0.42, h * 0.30)
      ..quadraticBezierTo(w * 0.34, h * 0.46, w * 0.46, h * 0.54)
      ..quadraticBezierTo(w * 0.56, h * 0.62, w * 0.40, h * 0.72);
    canvas.drawPath(trailPath, trailPaint);
  }

  @override
  bool shouldRepaint(_PeaksPainter old) => old.front != front || old.back != back || old.trail != trail;
}
