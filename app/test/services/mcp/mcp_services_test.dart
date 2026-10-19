import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sherpa/routing/routes.dart';
import 'package:sherpa/services/mcp/composer_sources.dart';
import 'package:sherpa/services/mcp/deep_link.dart';
import 'package:sherpa/services/mcp/mcp_records.dart';
import 'package:sherpa/services/mcp/mcp_runtime.dart';
import 'package:sherpa/services/mcp/registry_client.dart';
import 'package:sherpa/services/mcp/server_probe.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_data/sherpa_data.dart' show DocumentCollections;
import 'package:sherpa_mcp/sherpa_mcp.dart';

import 'support/mcp_fakes.dart';

/// A trimmed `GET /v0.1/servers` answer, shaped like the live registry's
/// (2026-10-19): one usable remote, one needing an API key header, one
/// package-only, one SSE-only, one deleted entry.
final JsonMap registryFixture = {
  'servers': [
    {
      'server': {
        r'$schema': 'https://static.modelcontextprotocol.io/schemas/2025-12-11/server.schema.json',
        'name': 'io.example/weather',
        'title': 'Weather',
        'description': 'Forecasts \u202Eand alerts',
        'version': '1.2.0',
        'remotes': [
          {'type': 'streamable-http', 'url': 'https://weather.example.com/mcp'},
        ],
      },
      '_meta': {
        'io.modelcontextprotocol.registry/official': {'status': 'active', 'isLatest': true},
      },
    },
    {
      'server': {
        'name': 'ai.smithery/github',
        'description': 'GitHub via Smithery',
        'version': '1.0.0',
        'remotes': [
          {
            'type': 'streamable-http',
            'url': 'https://server.smithery.ai/@smithery-ai/github/mcp',
            'headers': [
              {'name': 'Authorization', 'isRequired': true, 'isSecret': true, 'value': 'Bearer {smithery_api_key}'},
            ],
          },
        ],
      },
      '_meta': {
        'io.modelcontextprotocol.registry/official': {'status': 'active', 'isLatest': true},
      },
    },
    {
      'server': {
        'name': 'io.github.someone/filesystem',
        'description': 'Local files',
        'version': '0.3.0',
        'packages': [
          {'registryType': 'npm', 'identifier': '@someone/fs'},
        ],
      },
      '_meta': {
        'io.modelcontextprotocol.registry/official': {'status': 'active', 'isLatest': true},
      },
    },
    {
      'server': {
        'name': 'com.example/old-sse',
        'description': 'Older server',
        'version': '0.1.0',
        'remotes': [
          {'type': 'sse', 'url': 'https://old.example.com/sse'},
        ],
      },
      '_meta': {
        'io.modelcontextprotocol.registry/official': {'status': 'active', 'isLatest': true},
      },
    },
    {
      'server': {
        'name': 'com.example/gone',
        'description': 'Removed',
        'version': '1.0.0',
        'remotes': [
          {'type': 'streamable-http', 'url': 'https://gone.example.com/mcp'},
        ],
      },
      '_meta': {
        'io.modelcontextprotocol.registry/official': {'status': 'deleted', 'isLatest': true},
      },
    },
  ],
  'metadata': {'count': 5, 'nextCursor': 'com.example/gone:1.0.0'},
};

void main() {
  group('records', () {
    test('server configs and their meta round-trip; corrupt documents are skipped', () async {
      final records = InMemoryMcpRecords();
      final store = McpServerConfigStore(records);
      final c = McpServerConfig(id: 'docs', name: 'Docs', url: Uri.parse('https://docs.example.com/mcp'), trusted: true);
      await store.save(c, meta: McpServerMeta(source: McpServerSource.registry, registryName: 'io.example/docs', addedAt: DateTime.utc(2026)));
      await records.put(DocumentCollections.mcpServers, 'broken', {'id': 'broken'});
      final loaded = await McpServerConfigStore(records).load();
      expect(loaded, hasLength(1));
      expect(loaded.single.$1.toJson(), c.toJson());
      expect(loaded.single.$2.registryName, 'io.example/docs');
      expect(loaded.single.$2.source, McpServerSource.registry);
    });

    test('tool pins persist one document per tool and are removed per server', () async {
      final records = InMemoryMcpRecords();
      final pins = DocumentToolPinStore(records);
      final pin = ToolPin(
        key: const McpToolKey('docs', 'a/b'),
        hash: 'abc',
        definition: const {'name': 'a/b'},
        approvedAt: DateTime.utc(2026),
        origin: PinOrigin.user,
      );
      await pins.put(pin);
      await pins.put(ToolPin(key: const McpToolKey('other', 'x'), hash: 'h', definition: const {}, approvedAt: DateTime.utc(2026), origin: PinOrigin.user));
      expect(records.ids(DocumentCollections.mcpToolPins), ['docs/a%2Fb', 'other/x']);
      final fresh = DocumentToolPinStore(records);
      expect((await fresh.get(const McpToolKey('docs', 'a/b')))?.hash, 'abc');
      await fresh.removeServer('docs');
      expect(records.ids(DocumentCollections.mcpToolPins), ['other/x']);
    });

    test('tool switches persist; forgetting a server clears its switches in every scope', () async {
      final records = InMemoryMcpRecords();
      final e = await PersistentToolEnablement.load(records);
      var changes = 0;
      e.changes.listen((_) => changes++);
      await e.setToolEnabled('docs__read', false);
      await e.setToolEnabled('docs__read', true, sessionId: 's1');
      await e.setServerEnabled('docs', false, sessionId: 's2');
      await e.setPinned('memory__save_note', true);
      final again = await PersistentToolEnablement.load(records);
      expect(again.isToolEnabledGlobally('docs__read'), isFalse);
      expect(again.isToolEnabled('s1', 'docs__read'), isTrue);
      expect(again.isServerEnabled('s2', 'docs'), isFalse);
      expect(again.isPinned('any', 'memory__save_note'), isTrue);
      await again.forgetServer('docs', ['docs__read']);
      final cleared = await PersistentToolEnablement.load(records);
      expect(cleared.isToolEnabledGlobally('docs__read'), isTrue);
      expect(cleared.isToolEnabled('s1', 'docs__read'), isTrue);
      expect(cleared.isServerEnabled('s2', 'docs'), isTrue);
      expect(cleared.isPinned('any', 'memory__save_note'), isTrue);
      expect(changes, 4);
    });

    test('grants round-trip; expired ones are dropped on load', () async {
      final records = InMemoryMcpRecords();
      final clock = FakeClock(DateTime.utc(2026, 10, 19, 12));
      final store = ApprovalGrantStore(records, clock: clock);
      await store.save([
        ApprovalGrant(toolName: 'a__b', scope: ApprovalScope.always, grantedAt: clock.now(), definitionHash: 'h'),
        ApprovalGrant(
          toolName: 'a__c',
          scope: ApprovalScope.session,
          sessionId: 's',
          grantedAt: clock.now(),
          expiresAt: clock.now().add(const Duration(minutes: 5)),
        ),
      ]);
      expect((await store.load()).map((g) => g.toolName), ['a__b', 'a__c']);
      clock.advance(const Duration(minutes: 10));
      final loaded = await store.load();
      expect(loaded.single.definitionHash, 'h');
    });

    test('memory notes live in the document store', () async {
      final records = InMemoryMcpRecords();
      final notes = MemoryNotes(store: DocumentNoteStorage(records));
      final (note, created) = await notes.save(text: 'Ada likes tea', tags: const ['pref']);
      expect(created, isTrue);
      final again = MemoryNotes(store: DocumentNoteStorage(records));
      expect((await again.all()).single.id, note.id);
      expect(records.ids(DocumentCollections.memoryNotes), hasLength(1));
    });
  });

  group('MCP Registry', () {
    test('only active remote servers are offered; others say why', () {
      final page = McpRegistryClient.parsePage(registryFixture);
      expect(page.nextCursor, 'com.example/gone:1.0.0');
      expect(page.entries.map((e) => e.name), ['io.example/weather', 'ai.smithery/github', 'io.github.someone/filesystem', 'com.example/old-sse']);
      final weather = page.entries[0];
      expect(weather.displayName, 'Weather');
      expect(weather.description, isNot(contains('\u202E')), reason: 'bidi overrides are stripped');
      expect(weather.preferredRemote?.url, 'https://weather.example.com/mcp');
      expect(page.entries[1].preferredRemote, isNull);
      expect(page.entries[1].unsupportedReason, contains('API key'));
      expect(page.entries[2].unsupportedReason, contains('computer'));
      expect(page.entries[3].preferredRemote?.type, 'sse');
    });

    test('search asks /v0.1/servers for the latest versions', () async {
      final seen = <Uri>[];
      final client = McpRegistryClient(client: MockClient((r) async {
        seen.add(r.url);
        return http.Response(jsonEncode(registryFixture), 200, headers: {'content-type': 'application/json'});
      }));
      final page = await client.search('weather', cursor: 'abc');
      expect(page.entries, isNotEmpty);
      expect(seen.single.path, '/v0.1/servers');
      expect(seen.single.queryParameters, {'search': 'weather', 'version': 'latest', 'limit': '30', 'cursor': 'abc'});
    });

    test('offline, server errors and junk become plain-language errors', () async {
      Future<McpRegistryFailure> failureOf(MockClient c) async {
        try {
          await McpRegistryClient(client: c).search('');
          fail('no error');
        } on McpRegistryException catch (e) {
          expect(e.message, isNot(contains('Exception')));
          return e.failure;
        }
      }

      expect(await failureOf(MockClient((r) async => throw http.ClientException('no route'))), McpRegistryFailure.offline);
      expect(await failureOf(MockClient((r) async => http.Response('oops', 502))), McpRegistryFailure.unavailable);
      expect(await failureOf(MockClient((r) async => http.Response('<html>', 200))), McpRegistryFailure.invalidResponse);
    });
  });

  group('add links', () {
    test('build and parse round-trip; bare https codes work too', () {
      final link = McpAddLink.build('https://tools.example.com/mcp?x=1', name: 'Tools');
      expect(link.toString(), startsWith('sherpa://mcp/add?url='));
      final parsed = McpAddLink.parse(link.toString())!;
      expect(parsed.url, 'https://tools.example.com/mcp?x=1');
      expect(parsed.name, 'Tools');
      expect(McpAddLink.parse('https://a.example.com/mcp', source: McpServerSource.qr)?.source, McpServerSource.qr);
      expect(McpAddLink.parse('sherpa://mcp/add'), isNull);
      expect(McpAddLink.parse('io.github.mihok.sherpa:/oauth/callback?code=x'), isNull);
      expect(McpAddLink.parse('javascript:alert(1)'), isNull);
    });

    test('the router redirect sends a link to the add screen, marked as a link', () {
      final to = McpAddLink.redirectFor(Uri.parse('sherpa://mcp/add?url=https%3A%2F%2Ft.example.com%2Fmcp&name=T'), addRoute: Routes.addServer)!;
      final u = Uri.parse(to);
      expect(u.path, Routes.addServer);
      expect(u.queryParameters, {'url': 'https://t.example.com/mcp', 'name': 'T', 'source': 'link'});
      expect(McpAddLink.redirectFor(Uri.parse('/settings'), addRoute: Routes.addServer), isNull);
    });
  });

  group('URL policy', () {
    final v = McpUrlValidator(resolver: (h) => fakeResolver(h, local: {'nas.example.com': '192.168.1.10'}));

    test('https on the internet is fine; a scheme-less address gets https', () async {
      final r = await v.check('tools.example.com/mcp');
      expect(r.url.toString(), 'https://tools.example.com/mcp');
      expect(r.local, isFalse);
    });

    test('plain http only to a local address, never across the internet', () async {
      final lan = await v.check('http://192.168.1.20:8080/mcp');
      expect(lan.isValid, isTrue);
      expect(lan.local, isTrue);
      final public = await v.check('http://tools.example.com/mcp');
      expect(public.isValid, isFalse);
      expect(public.error, contains('own network'));
      final named = await v.check('http://nas.example.com/mcp');
      expect(named.isValid, isTrue, reason: 'resolves to a private address');
    });

    test('a private address needs "on my network"; metadata addresses never pass', () async {
      final hidden = await v.check('https://nas.example.com/mcp', local: false);
      expect(hidden.error, contains('local network'));
      expect((await v.check('https://nas.example.com/mcp', local: true)).isValid, isTrue);
      expect((await v.check('http://169.254.169.254/latest', local: true)).isValid, isFalse);
      expect((await v.check('https://user:pw@tools.example.com/mcp')).error, contains('password'));
      expect((await v.check('ftp://tools.example.com')).isValid, isFalse);
      expect((await v.check('https://nowhere.invalid/mcp')).error, contains("Couldn't find"));
    });
  });

  group('probe', () {
    test('reports the era, server name and tool count; auth and failures are reported, not thrown', () async {
      final remote = FakeRemoteServers()..add('https://t.example.com/mcp', name: 'Tooly', tools: [fakeTool('a'), fakeTool('b')]);
      final prober = ConnectingMcpProber(client: MockClient((r) async => http.Response('', 404)), connector: remote.connect);
      final ok = await prober.probe(McpServerConfig(id: 'p', name: 'p', url: Uri.parse('https://t.example.com/mcp')));
      expect(ok.reachable, isTrue);
      expect(ok.era, McpEra.modern);
      expect(ok.serverName, 'Tooly');
      expect(ok.toolCount, 2);
      expect(ok.eraLabel, contains(ok.protocolVersion));
      remote.down.add('https://t.example.com/mcp');
      final down = await prober.probe(McpServerConfig(id: 'p', name: 'p', url: Uri.parse('https://t.example.com/mcp')));
      expect(down.error, contains("Couldn't reach"));
      final authProber = ConnectingMcpProber(
        client: MockClient((r) async => http.Response('', 404)),
        connector: (c, o, t) async => throw McpAuthRequiredException(statusCode: 401, needsUserConsent: true),
      );
      expect((await authProber.probe(McpServerConfig(id: 'p', name: 'p', url: Uri.parse('https://t.example.com/mcp')))).needsAuth, isTrue);
    });

    test('eras and last errors read as plain language', () {
      expect(describeEra(McpEra.legacy, '2025-11-25', McpTransportKind.legacyStreamableHttp), contains('sessions'));
      expect(describeEra(McpEra.legacy, '2024-11-05', McpTransportKind.legacySse), contains('deprecated'));
      expect(describeLastError('McpTransportException: SocketException: Connection refused'), "Couldn't reach the server.");
      expect(describeLastError('McpAuthRequiredException: authorization required (HTTP 401)'), contains('sign in'));
    });
  });

  group('composer sources', () {
    late McpRuntime rt;
    tearDown(() => rt.dispose());

    Future<McpRuntime> withPromptsAndResources({bool trusted = false}) async {
      final remote = FakeRemoteServers()
        ..add(
          'https://docs.example.com/mcp',
          name: 'Docs',
          prompts: [
            DartMcpPrompt(
              name: 'summarize',
              title: 'Summarize a page',
              arguments: const [McpPromptArgument(name: 'page', required: true), McpPromptArgument(name: 'style')],
              get: (args) async => [
                McpPromptMessage(role: 'user', content: McpTextContent('Summarize ${args['page']} (${args['style'] ?? 'brief'})')),
                const McpPromptMessage(role: 'assistant', content: McpTextContent('Sure.')),
              ],
            ),
          ],
          resources: [
            DartMcpResource(
              uri: 'docs://guide',
              name: 'guide',
              title: 'User guide',
              mimeType: 'text/markdown',
              read: () async => [const McpTextResourceContents(uri: 'docs://guide', text: '# Guide', mimeType: 'text/markdown')],
            ),
            DartMcpResource(
              uri: 'docs://logo.png',
              name: 'logo',
              mimeType: 'image/png',
              read: () async => [const McpBlobResourceContents(uri: 'docs://logo.png', blob: 'AAAA', mimeType: 'image/png')],
            ),
          ],
        );
      rt = await fakeRuntime(remote: remote);
      final c = await rt.addServer(url: Uri.parse('https://docs.example.com/mcp'), name: 'Docs');
      if (trusted) rt.setTrusted(c.id, true);
      return rt;
    }

    test('prompts become slash commands; expansion yields messages flagged untrusted', () async {
      await withPromptsAndResources();
      final sources = McpComposerSources(rt);
      final commands = await sources.promptCommands(sessionId: 's');
      final cmd = commands.single;
      expect(cmd.command, 'docs:summarize');
      expect(cmd.label, 'Summarize a page');
      expect(cmd.parseArguments('page=intro style="very short"'), {'page': 'intro', 'style': 'very short'});
      expect(cmd.parseArguments('intro short and sweet'), {'page': 'intro', 'style': 'short and sweet'});
      await expectLater(sources.expand(cmd, const {}), throwsA(isA<McpPromptArgumentsException>()));
      final x = await sources.expand(cmd, const {'page': 'intro'});
      expect(x.messages.map((m) => m.role), [Role.user, Role.assistant]);
      expect(x.userText, 'Summarize intro (brief)');
      expect(x.messages.first.metadata[UntrustedData.messageMetadataKey], isTrue);
      final msg = x.messages.first.toMessage(id: 'm1', createdAt: DateTime.utc(2026));
      expect(msg.text, 'Summarize intro (brief)');

      await rt.enablement.setServerEnabled('docs', false, sessionId: 's');
      expect(await sources.promptCommands(sessionId: 's'), isEmpty, reason: 'switched off for this chat');
    });

    test("a trusted server's prompt text is not flagged", () async {
      await withPromptsAndResources(trusted: true);
      final sources = McpComposerSources(rt);
      final cmd = (await sources.promptCommands()).single;
      final x = await sources.expand(cmd, const {'page': 'p'});
      expect(x.messages.first.metadata.containsKey(UntrustedData.messageMetadataKey), isFalse);
    });

    test('@ mentions: small text is embedded, binary is linked', () async {
      await withPromptsAndResources();
      final sources = McpComposerSources(rt);
      final all = await sources.resourceSuggestions('');
      expect(all.map((s) => s.mention), ['docs:guide', 'docs:logo']);
      final guide = (await sources.resourceSuggestions('guide')).single;
      expect(guide.label, 'User guide');
      final embedded = await sources.resolveMention(guide);
      expect(embedded, isA<EmbeddedResourcePart>().having((p) => p.text, 'text', '# Guide'));
      final logo = (await sources.resourceSuggestions('logo')).single;
      expect(await sources.resolveMention(logo), isA<ResourceLinkPart>().having((p) => p.uri, 'uri', 'docs://logo.png'));
      expect(await sources.resolveMention(guide, embed: false), isA<ResourceLinkPart>());
    });
  });
}
