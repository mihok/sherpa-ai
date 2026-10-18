import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa/state/connectivity.dart';

import '../support/harness.dart';

void main() {
  test('only "no interfaces" counts as offline', () {
    expect(statusFor([ConnectivityResult.none]), NetworkStatus.offline);
    expect(statusFor([]), NetworkStatus.offline);
    expect(statusFor([ConnectivityResult.wifi]), NetworkStatus.online);
    expect(statusFor([ConnectivityResult.vpn, ConnectivityResult.none]), NetworkStatus.online);
  });

  testWidgets('the banner follows connectivity on every screen', (tester) async {
    final h = Harness();
    await pumpApp(tester, h);
    const label = "You're offline · remote models are unavailable";
    expect(find.text(label), findsNothing);

    h.connectivity.add([ConnectivityResult.none]);
    await tester.pumpAndSettle();
    expect(find.text(label), findsOneWidget);

    await goTo(tester, '/settings');
    expect(find.text(label), findsOneWidget, reason: 'global, above the navigator');

    h.connectivity.add([ConnectivityResult.wifi]);
    await tester.pumpAndSettle();
    expect(find.text(label), findsNothing);
  });

  testWidgets('a failing connectivity plugin never shows the banner', (tester) async {
    final h = Harness();
    await pumpApp(tester, h);
    h.connectivity.addError(StateError('plugin missing'));
    await tester.pumpAndSettle();
    expect(find.textContaining("You're offline"), findsNothing);
  });
}
