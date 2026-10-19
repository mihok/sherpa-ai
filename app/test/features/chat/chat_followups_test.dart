import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa/features/chat/background/background_widgets.dart';
import 'package:sherpa/features/chat/links/reply_links.dart';
import 'package:sherpa/features/chat/state/chat_errors.dart';
import 'package:sherpa/features/chat/state/chat_view_state.dart' show ChatNoticeAction;
import 'package:sherpa/features/chat/state/model_selection.dart';
import 'package:sherpa/features/chat/state/notice_copy.dart';
import 'package:sherpa/features/mcp/input/url_elicitation_sheet.dart' show urlWarnings;
import 'package:sherpa/services/background/background_providers.dart';
import 'package:sherpa/services/background/run_activity.dart';
import 'package:sherpa/services/inference/on_device_ids.dart';
import 'package:sherpa/state/ui_preferences.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_platform/sherpa_platform.dart';
import 'package:sherpa_platform/testing.dart';

import 'support/harness.dart';

ModelSelection _onDevice(String providerId, String name) => ModelSelection(
      providerId: providerId,
      modelId: 'm',
      providerName: onDeviceProviderName(providerId)!,
      modelName: name,
      location: ExecutionLocation.onDevice,
    );

/// The chat honours every on-device provider (errors, notices), one set of
/// address warnings for links and URL elicitation, and the background
/// prompt and setting.
void main() {
  group('on-device errors', () {
    test('Gemini Nano refusing the background reads as its own sentence, with Try again', () {
      final e = chatErrorFrom(
        const ProviderException(
          ProviderErrorKind.unsupported,
          'Gemini Nano only runs while Sherpa is on screen: Android (AICore) blocks it in the background, '
          'even from a foreground service. Open Sherpa to continue, or use another model for background work.',
          providerId: geminiNanoProviderId,
        ),
        outcome: RunOutcome.failed,
        model: _onDevice(geminiNanoProviderId, 'Gemini Nano'),
      );
      expect(e.title, 'Gemini Nano only runs while Sherpa is on screen');
      expect(e.message, startsWith('Android (AICore) blocks it in the background'));
      expect(e.kind, ChatErrorKind.localEngine);
      expect(e.actions, [ChatErrorAction.retry, ChatErrorAction.changeModel]);
      expect(e.providerId, geminiNanoProviderId);
      expect(e.title, isNot(contains('rejected the request')));
    });

    test('MLX and Apple Intelligence: the reason as the title, a way forward as the message', () {
      final mlx = chatErrorFrom(
        const ProviderException(ProviderErrorKind.unsupported, 'MLX models run on iPhone and iPad only.',
            providerId: mlxProviderId),
        model: _onDevice(mlxProviderId, 'Gemma'),
      );
      expect(mlx.title, 'MLX models run on iPhone and iPad only');
      expect(mlx.message, contains('model library'));
      expect(mlx.actions, [ChatErrorAction.openModels, ChatErrorAction.changeModel]);

      final fm = chatErrorFrom(
        const ProviderException(ProviderErrorKind.unsupported, 'Apple Intelligence is turned off in Settings.',
            providerId: appleFmProviderId),
        model: _onDevice(appleFmProviderId, 'Apple Intelligence'),
      );
      expect(fm.title, 'Apple Intelligence is turned off in Settings');
      expect(fm.actions.first, ChatErrorAction.changeModel);

      // Other kinds name the engine, not "On this device (LiteRT)".
      final other = chatErrorFrom(const ProviderException(ProviderErrorKind.invalidRequest, 'bad'),
          model: _onDevice(liteRtProviderId, 'Gemma'));
      expect(other.title, 'The on-device model rejected the request');
      final nano = chatErrorFrom(const ProviderException(ProviderErrorKind.invalidRequest, 'bad'),
          model: _onDevice(geminiNanoProviderId, 'Gemini Nano'));
      expect(nano.title, 'Gemini Nano rejected the request');
    });
  });

  test('every on-device provider id counts as on-device', () {
    for (final id in onDeviceProviderIds) {
      expect(isOnDeviceProviderId(id), isTrue, reason: id);
    }
    expect(isOnDeviceProviderId('openai'), isFalse);
  });

  test('a waiting-for-foreground notice from LiteRT-LM says the model was unloaded', () {
    final n = providerNoticeFor(const ProviderNotice(kWaitingForForegroundNotice,
        'The on-device model was unloaded to free memory; it reloads when Sherpa is back on screen.'));
    expect(n!.message, startsWith('The on-device model was unloaded to free memory.'));
    final paused = backgroundPausedNotice();
    expect(paused.action, ChatNoticeAction.continueRun);
  });

  group('one set of address warnings for reply links and URL elicitation', () {
    test('non-ASCII hosts (percent-encoded by Uri) and decimal or hex IPs', () {
      for (final warn in [urlWarnings, replyLinkWarnings]) {
        final idn = warn(Uri.parse('https://exämple.com/pay'));
        expect(idn.single, contains('international characters'));
        expect(idn.single, contains('exämple.com'), reason: 'shown decoded');
        expect(warn(Uri.parse('https://xn--pple-43d.com/')).single, contains('international characters'));
        for (final ip in ['https://10.0.0.1/', 'https://2130706433/', 'https://0x7f000001/', 'https://[::1]/']) {
          expect(warn(Uri.parse(ip)), contains(contains('bare IP address')), reason: ip);
        }
        expect(warn(Uri.parse('https://example.com/')), isEmpty);
        expect(warn(Uri.parse('https://bank.example@evil.example/')).single, contains('user name'));
      }
    });
  });

  group('background widgets', () {
    late FakePlatformBackend backend;
    late RunActivity activity;
    late InMemoryUiPreferencesStore ui;

    Future<void> pump(WidgetTester tester, Widget child, {BackgroundPlatform platform = BackgroundPlatform.android}) async {
      backend = FakePlatformBackend()..notifications = false;
      ui = InMemoryUiPreferencesStore();
      // The app's own runActivityProvider, over fakes: it follows the setting.
      final container = ProviderContainer(overrides: [
        backgroundRunGuardProvider.overrideWithValue(
          BackgroundRunGuard(backend: backend, updateInterval: Duration.zero, random: Random(1)),
        ),
        backgroundForegroundProvider.overrideWithValue(FakeForegroundSource()),
        backgroundPlatformProvider.overrideWithValue(platform),
        uiPreferencesStoreProvider.overrideWithValue(ui),
      ]);
      addTearDown(container.dispose);
      activity = container.read(runActivityProvider);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: chatTestTheme(Brightness.light), home: Scaffold(body: ListView(children: [child]))),
      ));
    }

    testWidgets('the notifications prompt explains first, then Allow shows the system dialog once', (tester) async {
      await pump(tester, const BackgroundNotificationsPrompt());
      expect(find.text('Keep you posted?'), findsNothing, reason: 'nothing to ask yet');
      activity.start(sessionId: 's', title: 'Trip', providerId: 'cloud', onExpired: (_) {});
      await tester.pumpAndSettle();
      expect(find.text('Keep you posted?'), findsOneWidget);
      expect(find.textContaining('never its messages'), findsOneWidget);
      expect(backend.permissionRequests, 0);
      await tester.tap(find.text('Allow notifications'));
      await tester.pumpAndSettle();
      expect(backend.permissionRequests, 1);
      expect(find.text('Keep you posted?'), findsNothing);
    });

    testWidgets('the setting is on by default; on Android, turning it on asks for notifications', (tester) async {
      await pump(tester, const BackgroundRunsTile());
      final tile = find.widgetWithText(SwitchListTile, 'Keep working in the background');
      expect(tester.widget<SwitchListTile>(tile).value, isTrue);
      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(ui.settings.backgroundRuns, isFalse);
      expect(activity.enabled, isFalse, reason: 'RunActivity follows the setting');
      expect(backend.permissionRequests, 0);
      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(ui.settings.backgroundRuns, isTrue);
      expect(backend.permissionRequests, 1);
    });

    testWidgets('iOS explains that on-device models pause', (tester) async {
      await pump(tester, const BackgroundRunsTile(), platform: BackgroundPlatform.ios);
      expect(find.textContaining('pause until you come back'), findsOneWidget);
    });
  });
}
