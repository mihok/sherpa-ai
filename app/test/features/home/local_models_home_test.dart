import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa/design/widgets/privacy_badge.dart';
import 'package:sherpa/state/services.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../../support/harness.dart';

/// On-device models on the home screen and in settings.
void main() {
  const qwen = ModelChoice(providerId: localProviderId, modelId: 'lib-qwen3-4b');

  Harness withLocal({List<ModelDescriptor>? installed, ModelChoice? defaultModel, bool remote = false}) => Harness(
        providers: [if (remote) openAiConfig()],
        defaultModel: defaultModel,
        wrapRegistry: (inner) =>
            WithLocalModels(inner, installed ?? [WithLocalModels.model('lib-qwen3-4b', 'Qwen3 4B')]),
      );

  Finder onDeviceBadge() =>
      find.byWidgetPredicate((w) => w is PrivacyBadge && w.location == ExecutionLocation.onDevice);

  testWidgets('a local chat shows the model name and the on-device badge, not "Provider removed"', (tester) async {
    final h = withLocal();
    await h.addSession('Offline notes', providerId: localProviderId, modelId: 'lib-qwen3-4b');
    await pumpApp(tester, h);
    expect(find.text('Qwen3 4B · On this device'), findsOneWidget);
    expect(find.text('Provider removed'), findsNothing);
    expect(find.textContaining('lib-qwen3-4b'), findsNothing, reason: 'never the library id');
    expect(onDeviceBadge(), findsOneWidget);
  });

  testWidgets('no provider but a model on this phone: home offers a chat, with the default line', (tester) async {
    final h = withLocal(defaultModel: qwen);
    await pumpApp(tester, h);
    expect(find.text('Connect a model to start'), findsNothing);
    expect(find.text('Start your first chat'), findsOneWidget);
    expect(find.textContaining('The model on this phone is ready'), findsOneWidget);
    expect(find.text('New chats use Qwen3 4B'), findsOneWidget);
    expect(onDeviceBadge(), findsOneWidget);
  });

  testWidgets('nothing at all: still "Connect a model"', (tester) async {
    final h = withLocal(installed: const []);
    await pumpApp(tester, h);
    expect(find.text('Connect a model to start'), findsOneWidget);
  });

  testWidgets('privacy: on-device models are listed, the default is named, and summaries are opt-in', (tester) async {
    final h = withLocal(
      defaultModel: qwen,
      installed: [WithLocalModels.model('lib-qwen3-4b', 'Qwen3 4B'), WithLocalModels.model('lib-gemma', 'Gemma 3 1B')],
    );
    await pumpApp(tester, h);
    await goTo(tester, '/settings/privacy');
    expect(find.text('New chats use Qwen3 4B.'), findsOneWidget);
    expect(find.text('2 on-device models'), findsOneWidget);
    expect(find.text('Qwen3 4B, Gemma 3 1B'), findsOneWidget);
    expect(onDeviceBadge(), findsWidgets);

    final toggle = find.widgetWithText(SwitchListTile, "Let the chat's model write summaries");
    await tester.scrollUntilVisible(toggle, 200, scrollable: find.byType(Scrollable).first);
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse, reason: 'off by default');
    expect(find.textContaining('sent to the chat\'s provider once more to be summarized'), findsOneWidget);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(h.ui.settings.modelSummaries, isTrue);
  });

  testWidgets('providers settings list the built-in on-device provider', (tester) async {
    final h = withLocal(remote: true);
    await pumpApp(tester, h);
    await goTo(tester, '/settings/providers');
    expect(find.text('On this device'), findsOneWidget);
    expect(find.text('Built in · 1 model'), findsOneWidget);
  });
}
