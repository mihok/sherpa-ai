import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa/features/context/data/data_erase.dart' show dataEraseHooksProvider;
import 'package:sherpa/features/mcp/mcp_bootstrap.dart';
import 'package:sherpa/features/mcp/state/mcp_providers.dart';
import 'package:sherpa/services/mcp/auth/mcp_oauth.dart' show McpSignedIn;
import 'package:sherpa/services/mcp/auth/oauth_platform.dart';
import 'package:sherpa/services/mcp/input/host_settings.dart';
import 'package:sherpa/services/mcp/input_handler.dart';
import 'package:sherpa/services/mcp/mcp_records.dart';
import 'package:sherpa/services/mcp/mcp_runtime.dart';
import 'package:sherpa/state/providers.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_data/sherpa_data.dart' show DocumentCollections;
import 'package:sherpa_mcp/sherpa_mcp.dart';

import 'support/mcp_fakes.dart';

void main() {
  const remoteUrl = 'https://tools.example.com/mcp';

  FakeRemoteServers remoteWith() => FakeRemoteServers()
    ..add(remoteUrl, name: 'Example tools', tools: [
      fakeTool('lookup', annotations: readOnlyHints),
      fakeTool('send', description: 'Sends a message.', annotations: const ToolAnnotations(destructiveHint: false)),
    ]);

  group('wiring', () {
    late McpRuntime rt;
    tearDown(() => rt.dispose());

    test('built-in servers are trusted, listed at start-up and behind the composite router', () async {
      rt = await fakeRuntime();
      await rt.start();
      expect(rt.servers.map((c) => c.id), [McpRuntime.memoryServerId, McpRuntime.deviceServerId]);
      expect(rt.servers.every((c) => c.trusted), isTrue);
      expect(rt.policy.isTrusted(rt.router.lookup('device__current_time')!), isTrue);
      final store = InMemorySessionStore();
      final router = rt.toolRouter(store);
      final names = (await router.toolsForTurn(sessionId: 's')).map((t) => t.name);
      expect(names.first, UpdatePlanTool.toolName, reason: "today's built-in tools stay first");
      expect(names, containsAll(['memory__save_note', 'memory__search_notes', 'device__current_time']));
      // A trusted read-only, closed-world built-in runs without asking.
      expect(rt.policy.evaluate(router.lookup('memory__search_notes')!, 's'), isA<AutoApprove>());
      expect(rt.policy.evaluate(router.lookup('memory__delete_note')!, 's'), isA<NeedsConfirmation>());
      final r = await router.execute(
        const ToolCall(id: 'c1', name: 'memory__save_note', arguments: {'text': 'Buy milk'}),
        toolCtx('s'),
      );
      expect(r.isError, isFalse);
    });

    test('overrides wire the tool router and one approval policy', () async {
      rt = await fakeRuntime();
      final container = ProviderContainer(overrides: [
        sessionStoreProvider.overrideWithValue(InMemorySessionStore()),
        ...mcpRuntimeOverrides(rt),
      ]);
      addTearDown(container.dispose);
      expect(container.read(approvalPolicyProvider), same(rt.policy));
      expect(container.read(mcpRuntimeProvider), same(rt));
      unawaited(rt.start());
      await container.read(toolsReadyProvider)();
      final router = container.read(toolRouterProvider);
      expect(router.lookup('memory__save_note'), isNotNull, reason: 'listed before ready completes');
      expect(router.lookup(UpdatePlanTool.toolName), isNotNull);
      await router.toolsForTurn(sessionId: 's');
      rt.router.resetSegment('s');
      container.read(toolsUserTurnHookProvider)('s');
      expect(rt.router.segmentOf('s'), 1);

      // Without MCP wiring the seams are harmless no-ops.
      final bare = ProviderContainer();
      addTearDown(bare.dispose);
      await bare.read(toolsReadyProvider)();
      bare.read(toolsUserTurnHookProvider)('s');
    });

    test('the secret cache only keeps hot auth keys and stays coherent', () async {
      final inner = InMemorySecretStore();
      final cache = CachingSecretStore(inner);
      await inner.write('oauth/servers/abc', 'b1');
      expect(await cache.read('oauth/servers/abc'), 'b1');
      await inner.write('oauth/servers/abc', 'b2');
      expect(await cache.read('oauth/servers/abc'), 'b1', reason: 'cached');
      await cache.delete('oauth/servers/abc');
      expect(await cache.read('oauth/servers/abc'), isNull);
      await inner.write('oauth/issuer/client', 'c1');
      expect(await cache.read('oauth/issuer/client'), 'c1');
      await inner.write('oauth/issuer/client', 'c2');
      expect(await cache.read('oauth/issuer/client'), 'c2', reason: 'registrations are read through');
    });

    test("an added untrusted server's tools wait for review; approving offers them with a bound hash", () async {
      final remote = remoteWith();
      rt = await fakeRuntime(remote: remote);
      final config = await rt.addServer(url: Uri.parse(remoteUrl), name: 'Example tools');
      expect(config.id, 'example_tools');
      expect(config.trusted, isFalse);
      await rt.refresh();
      final tools = rt.toolsOf(config.id);
      expect(tools.map((e) => e.modelName), ['example_tools__lookup', 'example_tools__send']);
      expect(tools.every((e) => e.quarantined), isTrue);
      expect(rt.pendingReviews, hasLength(2));
      final before = await rt.router.toolsForTurn(sessionId: 's');
      expect(before.map((t) => t.name), isNot(contains('example_tools__lookup')));

      expect(await rt.approveTool(const McpToolKey('example_tools', 'lookup')), isTrue);
      rt.router.resetSegment('s');
      final def = rt.router.lookup('example_tools__lookup')!;
      expect(def.definitionHash, isNotNull);
      expect(def.annotations.isReadOnly, isFalse, reason: 'an untrusted server: its readOnlyHint is not used');
      expect(rt.policy.evaluate(def, 's'), isA<NeedsConfirmation>());
      expect((await rt.router.toolsForTurn(sessionId: 's')).map((t) => t.name), contains('example_tools__lookup'));
    });

    test('trusting a server feeds the policy and persists; its new tools are pinned at first sight', () async {
      final remote = remoteWith();
      rt = await fakeRuntime(remote: remote);
      final c = await rt.addServer(url: Uri.parse(remoteUrl), name: 'Example tools');
      rt.setTrusted(c.id, true);
      await rt.refresh();
      expect(rt.toolsOf(c.id).where((e) => e.quarantined), isEmpty);
      final lookup = rt.router.lookup('example_tools__lookup')!;
      expect(rt.policy.evaluate(lookup, 's'), isA<AutoApprove>(), reason: 'trusted read-only, closed-world');
      rt.setTrusted(c.id, false);
      expect(rt.policy.isTrusted(lookup), isFalse);
    });

    test('a duplicate URL is found; ids never take a reserved name', () async {
      rt = await fakeRuntime(remote: remoteWith());
      await rt.addServer(url: Uri.parse(remoteUrl), name: 'Memory');
      expect(rt.serverForUrl(Uri.parse('$remoteUrl/'))?.id, 'memory_2');
      final c2 = await rt.addServer(url: Uri.parse('https://other.example.com/mcp'), name: '');
      expect(c2.id, 'other');
      expect(c2.name, 'other.example.com');
    });

    test('onUserTurn starts a new tool segment only when the old one went stale', () async {
      final remote = remoteWith();
      rt = await fakeRuntime(remote: remote);
      await rt.start();
      final first = await rt.router.toolsForTurn(sessionId: 's');
      rt.onUserTurn('s');
      expect(rt.router.segmentOf('s'), 1);
      expect(await rt.router.toolsForTurn(sessionId: 's'), hasLength(first.length));
      final c = await rt.addServer(url: Uri.parse(remoteUrl), name: 'Example tools');
      rt.setTrusted(c.id, true);
      await rt.refresh();
      expect(rt.router.isSegmentStale('s'), isTrue);
      rt.onUserTurn('s');
      final next = await rt.router.toolsForTurn(sessionId: 's');
      expect(next.map((t) => t.name), contains('example_tools__send'));
    });

    test('the default input handler declines elicitation, sampling and roots', () async {
      final declined = <McpDeclinedInput>[];
      final h = DecliningInputHandler(onDeclined: declined.add);
      final ctx = McpInputContext(serverId: 'x', serverName: 'X', era: McpEra.modern, cancel: CancellationToken(), originName: 'tool');
      final form = McpElicitRequest.fromJson({
        'mode': 'form',
        'message': 'Your name?',
        'requestedSchema': {'type': 'object', 'properties': <String, Object?>{}},
      });
      expect((await h.elicit(form, ctx)).action, McpElicitAction.decline);
      await expectLater(
        h.listRoots(ctx),
        throwsA(isA<InputRequestDeclined>().having((e) => e.reason, 'reason', DecliningInputHandler.rootsReason)),
      );
      expect(declined.map((d) => d.kind), ['form', 'roots']);
      expect(declined.first.originName, 'tool');
    });
  });

  group('persistence across restarts', () {
    test('servers, pins, switches, grants and trust survive; removing a server cleans up', () async {
      final records = InMemoryMcpRecords();
      final secrets = InMemorySecretStore();
      final clock = FakeClock(DateTime.utc(2026, 10, 19, 12));
      final remote = remoteWith();
      var rt = await fakeRuntime(records: records, secrets: secrets, remote: remote, clock: clock);
      final c = await rt.addServer(url: Uri.parse(remoteUrl), name: 'Example tools');
      await rt.refresh();
      await rt.approveTool(const McpToolKey('example_tools', 'send'));
      await rt.setToolEnabled('example_tools__lookup', false);
      await rt.setSessionServer('chat-1', 'memory', false);
      await rt.setEnabled(McpRuntime.deviceServerId, false);
      final send = rt.router.lookup('example_tools__send')!;
      rt.policy.recordFor(send, 'chat-1', const ApprovalResponse(UserDecision.approve, scope: ApprovalScope.session));
      expect(rt.policy.grants, hasLength(1));
      await pumpEventQueue();
      await rt.dispose();

      rt = await fakeRuntime(records: records, secrets: secrets, remote: remote, clock: clock);
      expect(rt.server(c.id)?.url.toString(), remoteUrl);
      expect(rt.metaOf(c.id)?.source, McpServerSource.url);
      expect(rt.server(McpRuntime.deviceServerId)?.enabled, isFalse, reason: 'built-in on/off persists');
      expect(rt.isToolEnabled('example_tools__lookup'), isFalse);
      expect(rt.enablement.isServerEnabled('chat-1', 'memory'), isFalse);
      await rt.refresh();
      expect(rt.router.entryFor('example_tools__send')!.quarantined, isFalse, reason: 'the pin was persisted');
      expect(rt.router.entryFor('example_tools__lookup')!.quarantined, isTrue);
      final restored = rt.policy.grants.single;
      expect(restored.toolName, 'example_tools__send');
      expect(restored.definitionHash, rt.router.lookup('example_tools__send')!.definitionHash);
      expect(rt.policy.evaluate(rt.router.lookup('example_tools__send')!, 'chat-1'), isA<AutoApprove>());

      await rt.removeServer(c.id);
      await pumpEventQueue();
      expect(rt.server(c.id), isNull);
      expect(rt.policy.grants, isEmpty);
      expect(records.ids(DocumentCollections.mcpServers), isNot(contains(c.id)));
      expect(records.ids(DocumentCollections.mcpToolPins).where((k) => k.startsWith('example_tools/')), isEmpty);
      expect(rt.isToolEnabled('example_tools__lookup'), isTrue, reason: 'its switches are forgotten');
      await rt.dispose();
    });
  });
  group('delete all data', () {
    test('eraseAll removes user servers, their sign-in, notes, pins, switches, approvals and input data', () async {
      final records = InMemoryMcpRecords();
      final secrets = InMemorySecretStore();
      final world = FakeAuthWorld();
      final remote = remoteWith()
        ..requireBearer[remoteUrl] = world.issued.contains
        ..resourceMetadata[remoteUrl] = world.prmUrl;
      final rt = await fakeRuntime(
        records: records,
        secrets: secrets,
        remote: remote,
        client: world.client(),
        browser: FakeBrowser(world.approve),
        notes: DocumentNoteStorage(records),
      );
      addTearDown(rt.dispose);
      await rt.start();

      // A signed-in user server with a reviewed tool, switches and a grant.
      final c = await rt.addServer(url: Uri.parse(remoteUrl), name: 'Example tools');
      await rt.refresh();
      expect(await rt.oauth.authorize(c.id, (await rt.oauth.prepareConsent(c.id))!), isA<McpSignedIn>());
      await rt.refresh();
      expect(await rt.oauth.hasCredentials(c.id), isTrue);
      expect(await rt.approveTool(const McpToolKey('example_tools', 'send')), isTrue);
      await rt.setToolEnabled('example_tools__lookup', false);
      await rt.setToolEnabled('memory__delete_note', false);
      await rt.setSessionServer('chat-1', McpRuntime.memoryServerId, false);
      await rt.enablement.setPinned('device__current_time', true);
      final send = rt.router.lookup('example_tools__send')!;
      rt.policy.recordFor(send, 'chat-1', const ApprovalResponse(UserDecision.approve, scope: ApprovalScope.always));
      rt.policy.recordFor(rt.router.lookup('memory__delete_note')!, 'chat-1',
          const ApprovalResponse(UserDecision.approve, scope: ApprovalScope.always));
      // Built-in changes: a server turned off, a note, host settings.
      await rt.setEnabled(McpRuntime.deviceServerId, false);
      final saved = await rt.router.execute(
        const ToolCall(id: 'n1', name: 'memory__save_note', arguments: {'text': 'My locker code is 4417'}),
        toolCtx('chat-2'),
      );
      expect(saved.isError, isFalse);
      await rt.updateHostSettings(c.id, const McpServerHostSettings(sampling: McpSamplingMode.ask, appsEnabled: false));
      await pumpEventQueue();
      for (final collection in [
        DocumentCollections.mcpServers,
        DocumentCollections.mcpToolPins,
        DocumentCollections.mcpToolSettings,
        DocumentCollections.approvalGrants,
        DocumentCollections.memoryNotes,
      ]) {
        expect(records.ids(collection), isNotEmpty, reason: '$collection before');
      }
      expect(rt.policy.grants, hasLength(2));
      expect((await secrets.keys(prefix: 'oauth/')).where((k) => k.contains('/tokens/')), isNotEmpty);

      await rt.eraseAll();
      await pumpEventQueue();

      expect(rt.servers.map((s) => s.id), [McpRuntime.memoryServerId, McpRuntime.deviceServerId],
          reason: 'only the built-in servers stay');
      expect(rt.servers.every((s) => s.enabled && s.trusted), isTrue, reason: 'with their defaults');
      expect(await rt.oauth.hasCredentials(c.id), isFalse);
      expect((await secrets.keys(prefix: 'oauth/')).where((k) => k.contains('/tokens/')), isEmpty);
      expect(rt.oauth.stateOf(c.id).needsConsent, isFalse);
      expect(records.ids(DocumentCollections.mcpServers), isNot(contains(c.id)));
      expect(records.ids(DocumentCollections.memoryNotes), isEmpty);
      expect(await rt.notes.keys(), isEmpty);
      expect(records.ids(DocumentCollections.mcpToolPins).where((k) => k.startsWith('example_tools/')), isEmpty);
      expect(records.ids(DocumentCollections.mcpToolSettings), isEmpty);
      expect(records.ids(DocumentCollections.approvalGrants), isEmpty);
      expect(rt.policy.grants, isEmpty);
      expect(rt.isToolEnabled('memory__delete_note'), isTrue);
      expect(rt.isToolEnabled('example_tools__lookup'), isTrue);
      expect(rt.enablement.isServerEnabled('chat-1', McpRuntime.memoryServerId), isTrue);
      expect(rt.enablement.isPinned('chat-1', 'device__current_time'), isFalse);
      expect(rt.hostSettingsOf(c.id).sampling, McpSamplingMode.off);
      expect(rt.pendingReviews, isEmpty);
      expect(rt.policy.evaluate(rt.router.lookup('memory__delete_note')!, 'chat-1'), isA<NeedsConfirmation>(),
          reason: 'no remembered approval');
      // The built-in tools are listed again (and re-pinned without review).
      expect(rt.router.lookup('device__current_time'), isNotNull);
      expect(rt.router.entryFor('memory__save_note')!.quarantined, isFalse);
      final notes = await rt.router.execute(
        const ToolCall(id: 'n2', name: 'memory__search_notes', arguments: {'query': 'locker'}),
        toolCtx('chat-2'),
      );
      expect([for (final p in notes.content) if (p is TextPart) p.text].join(), isNot(contains('4417')));
      expect(jsonEncode(notes.structured), isNot(contains('4417')));

      // Nothing comes back after a restart either.
      final again = await fakeRuntime(records: records, secrets: secrets, remote: remote, notes: DocumentNoteStorage(records));
      addTearDown(again.dispose);
      expect(again.servers.map((s) => s.id), [McpRuntime.memoryServerId, McpRuntime.deviceServerId]);
      expect(again.server(McpRuntime.deviceServerId)!.enabled, isTrue);
      expect(again.policy.grants, isEmpty);
      expect(again.isToolEnabled('memory__delete_note'), isTrue);
    });

    test('the "Delete all data" hook, registered as bootstrap does, erases MCP data', () async {
      final rt = await fakeRuntime(remote: remoteWith());
      addTearDown(rt.dispose);
      final c = await rt.addServer(url: Uri.parse(remoteUrl), name: 'Example tools');
      final container = ProviderContainer(overrides: [
        sessionStoreProvider.overrideWithValue(InMemorySessionStore()),
        ...mcpRuntimeOverrides(rt),
        dataEraseHooksProvider.overrideWith((ref) => [() => _eraseMcp(ref)]),
      ]);
      addTearDown(container.dispose);
      for (final hook in container.read(dataEraseHooksProvider)) {
        await hook();
      }
      expect(rt.server(c.id), isNull);
    });

    test('eraseAll on a fresh runtime is harmless', () async {
      final records = InMemoryMcpRecords();
      final rt = await fakeRuntime(records: records, notes: DocumentNoteStorage(records));
      addTearDown(rt.dispose);
      await rt.eraseAll();
      expect(rt.servers.map((s) => s.id), [McpRuntime.memoryServerId, McpRuntime.deviceServerId]);
      expect(rt.router.lookup('memory__save_note'), isNotNull);
    });
  });
}

extension on McpRuntime {
  Future<void> setSessionServer(String sessionId, String serverId, bool on) =>
      enablement.setServerEnabled(serverId, on, sessionId: sessionId);
}

/// The bootstrap's hook (lib/bootstrap.dart registers the same function).
Future<void> _eraseMcp(Ref ref) => ref.read(mcpRuntimeProvider).eraseAll();
