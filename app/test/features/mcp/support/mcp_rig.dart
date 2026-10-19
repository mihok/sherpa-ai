import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sherpa/app.dart';
import 'package:sherpa/bootstrap.dart' show noRetry;
import 'package:sherpa/features/mcp/add_server_screen.dart';
import 'package:sherpa/features/mcp/mcp_bootstrap.dart';
import 'package:sherpa/features/mcp/state/mcp_providers.dart';
import 'package:sherpa/services/mcp/mcp_records.dart';
import 'package:sherpa/services/mcp/mcp_runtime.dart';
import 'package:sherpa/services/mcp/registry_client.dart';
import 'package:sherpa/services/mcp/server_probe.dart';
import 'package:sherpa_core/sherpa_core.dart' show ToolAnnotations;
import 'package:sherpa_mcp/sherpa_mcp.dart';

import '../../../services/mcp/support/mcp_fakes.dart';
import '../../../support/harness.dart';

export '../../../services/mcp/support/mcp_fakes.dart';

const String toolsUrl = 'https://tools.example.com/mcp';

/// A prober that answers from a map instead of connecting.
final class FakeProber implements McpServerProber {
  FakeProber([this.reports = const {}]);

  final Map<String, McpProbeReport> reports;
  final List<String> probed = [];

  @override
  Future<McpProbeReport> probe(McpServerConfig config) async {
    probed.add(config.url.toString());
    return reports[config.url.toString()] ?? const McpProbeReport(error: "Couldn't reach the server.");
  }
}

/// The real app with MCP wired to an in-memory runtime and fake servers.
final class McpRig {
  McpRig._(this.app, this.runtime, this.remote, this.records, this.prober, this.registryHttp, this.browser);

  static Future<McpRig> create(
    WidgetTester tester, {
    FakeRemoteServers? remote,
    FakeProber? prober,
    http.Client? registryHttp,
    http.Client? httpClient,
    FakeBrowser? browser,
  }) async {
    final app = Harness();
    final servers = remote ?? FakeRemoteServers();
    final records = InMemoryMcpRecords();
    final b = browser ?? FakeBrowser();
    late McpRuntime rt;
    await tester.runAsync(() async {
      rt = await fakeRuntime(records: records, remote: servers, clock: app.clock, client: httpClient, browser: b);
      await rt.refresh();
    });
    final rig = McpRig._(
      app,
      rt,
      servers,
      records,
      prober ?? FakeProber(),
      registryHttp ?? MockClient((r) async => http.Response('{"servers":[],"metadata":{"count":0}}', 200)),
      b,
    );
    addTearDown(() => tester.runAsync(rt.dispose));
    return rig;
  }

  final Harness app;
  final McpRuntime runtime;
  final FakeRemoteServers remote;
  final InMemoryMcpRecords records;
  final FakeProber prober;
  final http.Client registryHttp;
  final FakeBrowser browser;

  /// What the QR scanner "sees".
  String? scanned;

  List<Override> extra = const [];

  List<Override> get overrides => [
        ...app.overrides,
        ...mcpRuntimeOverrides(runtime),
        mcpUrlValidatorProvider.overrideWithValue(McpUrlValidator(resolver: fakeResolver)),
        mcpProberProvider.overrideWithValue(prober),
        mcpRegistryClientProvider.overrideWithValue(McpRegistryClient(client: registryHttp)),
        mcpCodeScannerProvider.overrideWithValue((context) async => scanned),
        mcpCanScanProvider.overrideWithValue(true),
        ...extra,
      ];

  Future<void> pump(WidgetTester tester, {String? location, double textScale = 1}) async {
    setWindow(tester, phone, textScale: textScale);
    await tester.pumpWidget(ProviderScope(overrides: overrides, retry: noRetry, child: const SherpaApp()));
    await tester.pumpAndSettle();
    if (location != null) await goTo(tester, location);
  }

  /// Adds a remote server through the runtime (outside the UI).
  Future<McpServerConfig> addRemote(WidgetTester tester, {String url = toolsUrl, String name = 'Example tools', bool trusted = false}) async {
    late McpServerConfig c;
    await tester.runAsync(() async {
      c = await runtime.addServer(url: Uri.parse(url), name: name);
      if (trusted) runtime.setTrusted(c.id, true);
      await runtime.refresh();
    });
    await tester.pumpAndSettle();
    return c;
  }

  /// Lets work that hops between the test's fake clock and real time
  /// (in-process servers run on real timers, widgets on fake ones) finish.
  Future<void> settle(WidgetTester tester, {int rounds = 12}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pumpAndSettle();
  }

  /// Runs [action] (a tap, typing) in real time, then [settle]s.
  Future<void> act(WidgetTester tester, Future<void> Function() action) async {
    await tester.runAsync(action);
    await settle(tester);
  }

  Future<void> tap(WidgetTester tester, Finder f) => act(tester, () => tester.tap(f));
}

/// A registry page with one usable server and one that needs a key.
http.Client registryMock(List<Uri> seen) => MockClient((r) async {
      seen.add(r.url);
      return http.Response(
        jsonEncode({
          'servers': [
            {
              'server': {
                'name': 'io.example/weather',
                'title': 'Weather',
                'description': 'Forecasts and alerts',
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
                    'url': 'https://server.smithery.ai/github/mcp',
                    'headers': [
                      {'name': 'Authorization', 'isRequired': true, 'isSecret': true},
                    ],
                  },
                ],
              },
              '_meta': {
                'io.modelcontextprotocol.registry/official': {'status': 'active', 'isLatest': true},
              },
            },
          ],
          'metadata': {'count': 2},
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

FakeRemoteServers exampleServers() => FakeRemoteServers()
  ..add(toolsUrl, name: 'Example tools', tools: [
    fakeTool('lookup', description: 'Looks things up.', annotations: readOnlyHints),
    fakeTool('send', description: 'Sends a message.', annotations: const ToolAnnotations(destructiveHint: false)),
  ]);
