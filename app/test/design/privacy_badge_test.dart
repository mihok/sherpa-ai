import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa/design/theme.dart';
import 'package:sherpa/design/tokens.dart';
import 'package:sherpa/design/widgets/privacy_badge.dart';
import 'package:sherpa_core/sherpa_core.dart';

void main() {
  Future<void> pump(WidgetTester tester, Widget badge) => tester.pumpWidget(
        MaterialApp(theme: SherpaTheme.light(), home: Scaffold(body: Center(child: badge))),
      );

  testWidgets('on device: text, phone icon, on-device color', (tester) async {
    await pump(tester, const PrivacyBadge(location: ExecutionLocation.onDevice));
    expect(find.text('On device'), findsOneWidget);
    expect(find.byIcon(Icons.smartphone_outlined), findsOneWidget);
    final ctx = tester.element(find.text('On device'));
    expect(tester.widget<Text>(find.text('On device')).style?.color, SherpaTokens.of(ctx).semantic.onDevice);
  });

  testWidgets('leaves device: "Leaves device → host" with a drawn arrow', (tester) async {
    await pump(tester, const PrivacyBadge(location: ExecutionLocation.remote, host: 'api.openai.com'));
    expect(find.text('Leaves device'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_forward), findsOneWidget);
    expect(find.text('api.openai.com'), findsOneWidget);
  });

  testWidgets('compact shows only the host after the outward icon', (tester) async {
    await pump(
      tester,
      const PrivacyBadge(location: ExecutionLocation.remote, host: 'api.openai.com', size: PrivacyBadgeSize.compact),
    );
    expect(find.text('Leaves device'), findsNothing);
    expect(find.byIcon(Icons.arrow_outward), findsOneWidget);
    expect(find.text('api.openai.com'), findsOneWidget);
  });

  testWidgets('screen readers hear one full sentence', (tester) async {
    final handle = tester.ensureSemantics();
    await pump(tester, const PrivacyBadge(location: ExecutionLocation.localNetwork, host: '192.168.1.20'));
    expect(
      find.bySemanticsLabel('Leaves this device. Sent to 192.168.1.20 on your local network.'),
      findsOneWidget,
    );
    handle.dispose();
  });
}
