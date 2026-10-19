import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa/design/theme.dart';
import 'package:sherpa/features/context/data/data_erase.dart';
import 'package:sherpa/features/context/data/data_export.dart';
import 'package:sherpa/features/settings/privacy_screen.dart';
import 'package:sherpa/state/ui_preferences.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_data/sherpa_data.dart' show databaseKeySecretName;

import 'support/context_harness.dart';

const String kApiKey = 'sk-ant-api03-Zx9Qw8Er7Ty6Ui5Op4As3Df2';

/// A token no pattern knows: only the secret-store net can catch it.
const String kOddToken = 'tok_9f8e7d6c5b4a3210zz';
const String kDbKey = 'db-key-0123456789abcdef0123456789abcdef';

void main() {
  late ContextHarness h;
  tearDown(() => h.dispose());

  /// A chat with two branches, a summary, a plan and secrets in the store
  /// (and, carelessly, in a message).
  Future<void> seed() async {
    h = ContextHarness();
    await h.secrets.write('provider/$kProviderId/api_key', kApiKey);
    await h.secrets.write('mcp/notes/oauth_token', kOddToken);
    await h.secrets.write(databaseKeySecretName, kDbKey);
    await h.seedConversation(turns: 4, resultLines: 10);
    await h.addTurn(5, userText: 'Use $kApiKey for staging, the notes token is $kOddToken, password=hunter2hunter2');
    final chat = await h.open();
    await chat.compactNow();
    await h.store.putPlan(
      kSession,
      Plan(task: 'Audit logs', updatedAt: h.clock.now(), items: const [PlanItem(id: 'p1', title: 'Read logs')]),
    );
    // An edit branch beside step 2's question.
    await h.store.putMessage(
      kSession,
      Message(
        id: 'branch-u',
        parentId: 't1-f',
        role: Role.user,
        content: const [TextPart('A different question on another branch.')],
        createdAt: h.clock.now(),
      ),
    );
    await h.store.putSession(
      SessionRecord(
        id: 'archived',
        title: 'Old chat',
        createdAt: h.clock.now(),
        updatedAt: h.clock.now(),
        archived: true,
      ),
    );
  }

  test('the export holds every chat, branch, overlay, plan and audit line, and no secret', () async {
    await seed();
    final exporter = h.container.read(dataExporterProvider);
    final text = utf8.decode(await exporter.archiveBytes());

    for (final secret in [kApiKey, kOddToken, kDbKey, 'hunter2hunter2']) {
      expect(text, isNot(contains(secret)), reason: 'leaked $secret');
    }
    expect(text, contains('«redacted»'));

    final j = jsonDecode(text) as Map<String, Object?>;
    expect(j['format'], 'sherpa.export');
    final sessions = (j['sessions']! as List).cast<Map<String, Object?>>();
    expect(sessions.map((s) => (s['session']! as Map)['id']), unorderedEquals([kSession, 'archived']));
    final chat = sessions.firstWhere((s) => (s['session']! as Map)['id'] == kSession);
    final ids = [for (final m in (chat['messages']! as List).cast<Map<String, Object?>>()) m['id']];
    expect(ids, containsAll(['t1-u', 't5-f', 'branch-u']), reason: 'all branches, not only the active one');
    expect(chat['overlays'], hasLength(1));
    expect((chat['plan']! as Map)['task'], 'Audit logs');
    expect((chat['audit']! as List), isNotEmpty);
    expect(exporter.fileName(), startsWith('sherpa-export-2026-10-18'));
  });

  test('delete all clears chats, providers, secrets (but the DB key) and preferences', () async {
    await seed();
    var hooked = 0;
    final eraser = DataEraser(
      sessions: h.store,
      providers: h.registry,
      preferences: h.prefs,
      secrets: h.secrets,
      ui: h.ui,
      platform: h.platform,
      hooks: [() async => hooked++],
    );
    await h.ui.save(const UiSettings(hapticsEnabled: false));
    final report = await eraser.eraseAll();

    expect(report.sessions, 2);
    expect(await h.store.listSessions(includeArchived: true), isEmpty);
    expect(await h.store.overlays(kSession), isEmpty);
    expect(await h.store.audit(kSession), isEmpty);
    expect(h.registry.configs, isEmpty);
    expect(await h.secrets.keys(), [databaseKeySecretName]);
    expect(await h.secrets.read(databaseKeySecretName), kDbKey);
    expect(h.prefs.defaultModel, isNull);
    expect(h.prefs.onboardingComplete, isFalse);
    expect(h.ui.settings, const UiSettings());
    expect(h.platform.cleared, 1, reason: 'old export files are removed too');
    expect(hooked, 1);
  });

  group('privacy dashboard', () {
    Future<GoRouter> pumpPrivacy(WidgetTester tester) async {
      tester.view.physicalSize = const Size(400, 860) * tester.view.devicePixelRatio;
      addTearDown(tester.view.resetPhysicalSize);
      final router = GoRouter(
        initialLocation: '/settings/privacy',
        routes: [
          GoRoute(path: '/settings/privacy', builder: (_, _) => const PrivacyScreen()),
          GoRoute(path: '/onboarding', builder: (_, _) => const Scaffold(body: Text('onboarding'))),
          GoRoute(path: '/handoff/import', builder: (_, _) => const Scaffold(body: Text('import'))),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: h.container,
        child: MaterialApp.router(theme: SherpaTheme.light(), routerConfig: router),
      ));
      await settle(tester);
      await tester.scrollUntilVisible(find.text('Delete all data'), 300, scrollable: find.byType(Scrollable).first);
      await tester.pump();
      return router;
    }

    testWidgets('Export explains the file, then shares it', (tester) async {
      await seed();
      await pumpPrivacy(tester);
      expect(find.text('All chats and settings as a JSON file, never keys'), findsOneWidget);
      await tester.tap(find.text('Export my data'));
      await settle(tester);
      expect(find.text('Export your data?'), findsOneWidget);
      expect(find.textContaining('API keys, tokens and passwords are never included'), findsOneWidget);
      await tester.tap(find.text('Export'));
      await settle(tester);
      final file = h.platform.shared.single;
      expect(file.name, endsWith('.json'));
      expect(utf8.decode(file.bytes), isNot(contains(kApiKey)));
      expect(find.textContaining('Export ready'), findsOneWidget);
    });

    testWidgets('Delete all data asks twice, then wipes and returns to setup', (tester) async {
      await seed();
      await pumpPrivacy(tester);
      await tester.tap(find.text('Delete all data'));
      await settle(tester);
      expect(find.text('Delete all data?'), findsOneWidget);
      expect(find.textContaining("It can't be undone"), findsOneWidget);

      // Backing out at the second step keeps everything.
      await tester.tap(find.text('Continue'));
      await settle(tester);
      expect(find.text('Are you sure?'), findsOneWidget);
      await tester.tap(find.text('Keep my data'));
      await settle(tester);
      expect(await h.store.listSessions(includeArchived: true), hasLength(2));

      await tester.tap(find.text('Delete all data'));
      await settle(tester);
      await tester.tap(find.text('Continue'));
      await settle(tester);
      await tester.tap(find.text('Delete everything'));
      await settle(tester);
      expect(find.text('onboarding'), findsOneWidget);
      expect(await h.store.listSessions(includeArchived: true), isEmpty);
      expect(await h.secrets.keys(), [databaseKeySecretName]);
      expect(h.prefs.onboardingComplete, isFalse);
    });

    testWidgets('Import a handoff opens the import flow', (tester) async {
      await seed();
      await pumpPrivacy(tester);
      await tester.tap(find.text('Import a handoff'));
      await settle(tester);
      expect(find.text('import'), findsOneWidget);
    });
  });
}
