import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa/features/chat/model_picker_sheet.dart';
import 'package:sherpa/features/diagnostics/diagnostics_screen.dart';
import 'package:sherpa/routing/chat_screen_binding.dart';
import 'package:sherpa/routing/routes.dart';
import 'package:sherpa/state/services.dart';

import '../support/harness.dart';

/// Under reduced motion (Android "Remove animations", iOS "Reduce Motion"),
/// the framework's own animations that ignore it by default (sheets,
/// dialogs, popup menus, expansion tiles, pages pushed outside the router)
/// take no time: each is fully open on the next frame. With normal motion they
/// still animate, so the check can tell the two apart.
void main() {
  Future<Harness> app(WidgetTester tester, {required bool reduced}) async {
    if (reduced) {
      tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    }
    final h = Harness(
      providers: [openAiConfig()],
      keys: {'provider/openai/api_key': 'sk-x'},
      endpoints: {'api.openai.com': const FakeEndpoint(models: ['gpt-a'])},
      defaultModel: const ModelChoice(providerId: 'openai', modelId: 'gpt-a'),
      chat: buildChatScreen,
    );
    await pumpApp(tester, h);
    return h;
  }

  /// A chat on the default model, listed on home; returns its id.
  Future<String> addChat(WidgetTester tester, Harness h) async {
    final s = await h.addSession('Plan three days in Lisbon', providerId: 'openai', modelId: 'gpt-a');
    await tester.pumpAndSettle();
    return s.id;
  }

  /// Taps [target] and reports whether what it opened was still moving one
  /// frame later: the new route's transition ([shown] is on it), or, for
  /// [grows], that widget's size. Spinners and ink ripples keep their own
  /// tickers, so `hasRunningAnimations` can't tell.
  Future<bool> animates(WidgetTester tester, Finder target, Finder shown, {Finder? grows, bool longPress = false}) async {
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    await (longPress ? tester.longPress(target) : tester.tap(target));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    bool moving;
    if (grows != null) {
      final early = tester.getSize(grows);
      await tester.pumpAndSettle();
      moving = tester.getSize(grows) != early;
    } else {
      final route = ModalRoute.of(tester.element(shown.first))!;
      moving = route.animation!.status != AnimationStatus.completed;
      await tester.pumpAndSettle();
    }
    expect(shown, findsWidgets);
    return moving;
  }

  final cases = <String, Future<bool> Function(WidgetTester tester, Harness h)>{
    'a bottom sheet (default model)': (tester, _) async {
      await goTo(tester, Routes.settings);
      return animates(tester, find.text('Default model'), find.byWidgetPredicate((w) => w is RadioListTile));
    },
    'a dialog (remove provider)': (tester, _) async {
      await goTo(tester, Routes.providers);
      await tester.tap(find.byTooltip('More for OpenAI'));
      await tester.pumpAndSettle();
      return animates(tester, find.text('Remove'), find.text('Remove OpenAI?'));
    },
    'an expansion tile (provider form, Advanced)': (tester, _) async {
      await goTo(tester, Routes.provider('openai'));
      await tester.scrollUntilVisible(find.text('Advanced'), 200, scrollable: find.byType(Scrollable).first);
      return animates(tester, find.text('Advanced'), find.text('Extra headers'), grows: find.byType(ExpansionTile));
    },
    'a page pushed outside the router (diagnostics)': (tester, _) async {
      await goTo(tester, Routes.about);
      return animates(tester, find.text(DiagnosticsScreen.title), find.byType(DiagnosticsScreen));
    },
    "a chat's sheet (the model picker)": (tester, h) async {
      await goTo(tester, Routes.chat(await addChat(tester, h)));
      return animates(tester, find.bySemanticsLabel(RegExp('^Model: ')), find.byType(ModelPickerSheet));
    },
    "a popup menu (the chat's More)": (tester, h) async {
      await goTo(tester, Routes.chat(await addChat(tester, h)));
      return animates(tester, find.byTooltip('More'), find.text('Context details'));
    },
    "a chat's actions (long press in the list)": (tester, h) async {
      await addChat(tester, h);
      return animates(tester, find.text('Plan three days in Lisbon'), find.text('Delete'), longPress: true);
    },
  };

  for (final c in cases.entries) {
    testWidgets('normal motion animates ${c.key}', (tester) async {
      final h = await app(tester, reduced: false);
      expect(await c.value(tester, h), isTrue);
    });

    testWidgets('reduced motion opens ${c.key} at once', (tester) async {
      final h = await app(tester, reduced: true);
      expect(await c.value(tester, h), isFalse);
    });
  }
}
