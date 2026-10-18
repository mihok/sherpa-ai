import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

void main() {
  testWidgets('first launch opens onboarding', (tester) async {
    await pumpApp(tester, Harness(onboarded: false));
    expect(find.text('Meet Sherpa'), findsOneWidget);
  });

  testWidgets('onboarded with no providers shows the connect empty state', (tester) async {
    await pumpApp(tester, Harness());
    expect(find.text('Connect a model to start'), findsOneWidget);
  });
}
