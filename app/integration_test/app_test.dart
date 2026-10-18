import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sherpa/app.dart';
import 'package:sherpa/bootstrap.dart';

/// On-device smoke test: the real bootstrap (today: in-memory services and
/// unwired adapters) boots into onboarding, and "Skip for now" reaches the
/// home screen. Run with `flutter test integration_test -d <device>`.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('boots into onboarding and skips to home', (tester) async {
    final overrides = await bootstrap();
    await tester.pumpWidget(ProviderScope(overrides: overrides, retry: noRetry, child: const SherpaApp()));
    await tester.pumpAndSettle();
    expect(find.text('Meet Sherpa'), findsOneWidget);

    await tester.tap(find.text('Skip for now'));
    await tester.pumpAndSettle();
    expect(find.text('Connect a model to start'), findsOneWidget);
  });
}
