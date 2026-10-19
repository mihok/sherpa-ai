import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa/features/mcp/mcp_bootstrap.dart';
import 'package:sherpa/features/mcp/state/mcp_providers.dart';
import 'package:sherpa/services/mcp/auth/oauth_platform.dart';
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
}

extension on McpRuntime {
  Future<void> setSessionServer(String sessionId, String serverId, bool on) =>
      enablement.setServerEnabled(serverId, on, sessionId: sessionId);
}
