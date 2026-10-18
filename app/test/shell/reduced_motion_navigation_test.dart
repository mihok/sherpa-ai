import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa/app.dart';
import 'package:sherpa/routing/router.dart';
import 'package:sherpa/routing/routes.dart';

import '../support/harness.dart';

/// Programmatic page transitions take zero time under reduced motion (the
/// back gesture still tracks the finger), on both platform signals.
void main() {
  Future<bool> transitionStillRunning(WidgetTester tester) async {
    final h = Harness();
    await pumpApp(tester, h);
    ProviderScope.containerOf(tester.element(find.byType(SherpaApp))).read(routerProvider).go(Routes.settings);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    final running = tester.hasRunningAnimations;
    await tester.pumpAndSettle();
    expect(find.text('Model providers'), findsOneWidget);
    return running;
  }

  testWidgets('normal motion animates the push', (tester) async {
    expect(await transitionStillRunning(tester), isTrue);
  });

  testWidgets('iOS Reduce Motion makes the push instant', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(reduceMotion: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    expect(await transitionStillRunning(tester), isFalse);
  });

  testWidgets('Android Remove animations makes the push instant', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    expect(await transitionStillRunning(tester), isFalse);
  });
}
