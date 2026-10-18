import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa/design/motion.dart';
import 'package:sherpa/design/theme.dart';
import 'package:sherpa/design/tokens.dart';

void main() {
  test('reduced motion zeroes every duration token', () {
    const reduced = MotionTokens(reduced: true);
    expect([reduced.extraFast, reduced.fast, reduced.medium, reduced.slow, reduced.ambient], everyElement(Duration.zero));
    expect(reduced.scale(const Duration(seconds: 2)), Duration.zero);
    const normal = MotionTokens();
    expect(normal.fast, greaterThan(Duration.zero));
    expect(normal.medium, greaterThan(normal.fast));
    expect(normal.slow, greaterThan(normal.medium));
  });

  Widget probe(void Function(MotionTokens) read, {bool disableAnimations = false}) => MaterialApp(
        theme: SherpaTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: disableAnimations),
          child: MotionScope(child: child!),
        ),
        home: Builder(builder: (context) {
          read(SherpaTokens.of(context).motion);
          return const SizedBox();
        }),
      );

  testWidgets('Android "Remove animations" (MediaQuery.disableAnimations) reduces motion', (tester) async {
    late MotionTokens motion;
    await tester.pumpWidget(probe((m) => motion = m, disableAnimations: true));
    expect(motion.reduced, isTrue);
    expect(motion.medium, Duration.zero);
  });

  testWidgets('iOS "Reduce Motion" (AccessibilityFeatures.reduceMotion) reduces motion', (tester) async {
    late MotionTokens motion;
    await tester.pumpWidget(probe((m) => motion = m));
    expect(motion.reduced, isFalse);

    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(reduceMotion: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pump();
    expect(motion.reduced, isTrue, reason: 'MotionScope must react to the feature change alone');

    tester.platformDispatcher.clearAccessibilityFeaturesTestValue();
    await tester.pump();
    expect(motion.reduced, isFalse);
  });

  testWidgets('platformPrefersReducedMotion is false by default', (tester) async {
    late bool value;
    await tester.pumpWidget(Builder(builder: (context) {
      value = platformPrefersReducedMotion(context);
      return const SizedBox();
    }));
    expect(value, isFalse);
  });
}
