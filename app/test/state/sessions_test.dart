import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa/features/mcp/mcp_bootstrap.dart';
import 'package:sherpa/state/app_providers.dart';
import 'package:sherpa/state/services.dart';
import 'package:sherpa/state/sessions.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../services/mcp/support/mcp_fakes.dart';
import '../support/harness.dart';

void main() {
  ProviderContainer containerFor(Harness h) => ProviderContainer.test(overrides: h.overrides);

  test('create uses the default model and the shared title', () async {
    final h = Harness(defaultModel: const ModelChoice(providerId: 'openai', modelId: 'gpt-x'));
    final c = containerFor(h);
    final s = await c.read(sessionActionsProvider).create();
    expect(s.title, defaultSessionTitle);
    expect(s.providerId, 'openai');
    expect(s.modelId, 'gpt-x');
    expect((await h.store.getSession(s.id))?.title, defaultSessionTitle);
  });

  test('the list follows writes made anywhere through the observable store', () async {
    final h = Harness();
    final c = containerFor(h);
    final sub = c.listen(sessionListProvider, (_, _) {});
    await c.read(sessionListProvider.future);
    await h.addSession('From the agent loop');
    await Future<void>.delayed(Duration.zero);
    await c.read(sessionListProvider.notifier).refresh();
    expect(c.read(sessionListProvider).value!.map((s) => s.title), ['From the agent loop']);
    sub.close();
  });

  test('delete hides at once, undo restores, commit deletes', () async {
    final h = Harness();
    final c = containerFor(h);
    final sub = c.listen(visibleSessionsProvider, (_, _) {});
    final s = await h.addSession('Doomed');
    await c.read(sessionListProvider.notifier).refresh();
    final actions = c.read(sessionActionsProvider);

    final pending = actions.deleteWithUndo(s.id);
    expect(c.read(visibleSessionsProvider).value, isEmpty);
    await pending.undo();
    expect(c.read(visibleSessionsProvider).value!.single.id, s.id);
    expect(await h.store.getSession(s.id), isNotNull);

    final again = actions.deleteWithUndo(s.id);
    await again.commit();
    expect(await h.store.getSession(s.id), isNull);
    expect(c.read(visibleSessionsProvider).value, isEmpty);
    sub.close();
  });

  test('search matches title, model and provider name', () async {
    final h = Harness(providers: [openAiConfig()]);
    final c = containerFor(h);
    final sub = c.listen(visibleSessionsProvider, (_, _) {});
    await h.addSession('Trip to Lisbon', providerId: 'openai', modelId: 'gpt-x');
    await h.addSession('Fix the parser', providerId: 'ollama', modelId: 'qwen3:8b');
    await c.read(sessionListProvider.notifier).refresh();
    List<String> titles() => c.read(visibleSessionsProvider).value!.map((s) => s.title).toList();

    c.read(sessionQueryProvider.notifier).set('lisbon');
    expect(titles(), ['Trip to Lisbon']);
    c.read(sessionQueryProvider.notifier).set('QWEN');
    expect(titles(), ['Fix the parser']);
    c.read(sessionQueryProvider.notifier).set('openai');
    expect(titles(), ['Trip to Lisbon']);
    c.read(sessionQueryProvider.notifier).set('');
    expect(titles(), hasLength(2));
    sub.close();
  });

  test('archive hides from the default list and shows under archived', () async {
    final h = Harness();
    final c = containerFor(h);
    final sub = c.listen(visibleSessionsProvider, (_, _) {});
    final s = await h.addSession('Old');
    await c.read(sessionListProvider.notifier).refresh();
    await c.read(sessionActionsProvider).setArchived(s.id, archived: true);
    expect(c.read(visibleSessionsProvider).value, isEmpty);
    c.read(showArchivedProvider.notifier).toggle();
    await c.read(sessionListProvider.future);
    expect(c.read(visibleSessionsProvider).value!.single.archived, isTrue);
    sub.close();
  });

  test('a committed delete runs the clean-up hooks; an undone one does not', () async {
    final h = Harness();
    final forgotten = <String>[];
    final c = ProviderContainer.test(overrides: [
      ...h.overrides,
      sessionDeletedHooksProvider.overrideWithValue([
        (id) async => forgotten.add(id),
        (id) async => throw StateError('a failing hook is only logged'),
        (id) async => forgotten.add('again:$id'),
      ]),
    ]);
    final kept = await h.addSession('Kept');
    final doomed = await h.addSession('Doomed');
    final actions = c.read(sessionActionsProvider);
    await actions.deleteWithUndo(kept.id).undo();
    expect(forgotten, isEmpty);
    await actions.deleteWithUndo(doomed.id).commit();
    expect(forgotten, [doomed.id, 'again:${doomed.id}']);
    expect(await h.store.getSession(doomed.id), isNull);
  });

  test("MCP forgets a deleted chat's tool switches", () async {
    final h = Harness();
    final rt = await fakeRuntime();
    addTearDown(rt.dispose);
    final c = ProviderContainer.test(overrides: [...h.overrides, ...mcpRuntimeOverrides(rt)]);
    final s = await h.addSession('With tools');
    final server = rt.servers.first.id;
    await rt.enablement.setServerEnabled(server, false, sessionId: s.id);
    expect(rt.enablement.isServerEnabled(s.id, server), isFalse);
    await c.read(sessionActionsProvider).deleteWithUndo(s.id).commit();
    expect(rt.enablement.isServerEnabled(s.id, server), isTrue, reason: 'back to the global switch');
  });

  test('on-device chats: badge, display name, and search by that name', () async {
    final h = Harness(
      wrapRegistry: (inner) => WithLocalModels(inner, [WithLocalModels.model('lib-qwen3', 'Qwen3 4B')]),
    );
    final c = containerFor(h);
    expect(c.read(providerPrivacyProvider(localProviderId))?.location, ExecutionLocation.onDevice);
    expect(c.read(providerDisplayNameProvider(localProviderId)), 'On this device');
    await c.read(localModelsProvider.future);
    const choice = ModelChoice(providerId: localProviderId, modelId: 'lib-qwen3');
    expect(c.read(modelDisplayNameProvider(choice)), 'Qwen3 4B');
    expect(c.read(modelDisplayNameProvider(const ModelChoice(providerId: 'openai', modelId: 'gpt-x'))), 'gpt-x');

    final sub = c.listen(visibleSessionsProvider, (_, _) {});
    await h.addSession('Offline notes', providerId: localProviderId, modelId: 'lib-qwen3');
    await h.addSession('Cloud notes', providerId: 'openai', modelId: 'gpt-x');
    await c.read(sessionListProvider.notifier).refresh();
    c.read(sessionQueryProvider.notifier).set('qwen3 4b');
    expect(c.read(visibleSessionsProvider).value!.map((s) => s.title), ['Offline notes']);
    sub.close();
  });
}
