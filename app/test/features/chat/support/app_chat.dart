/// A chat over a real MCP runtime with one "Weather" server whose tool
/// result carries an MCP App view, rendered on sherpa_webview's fake
/// platform (shared by the MCP Apps chat tests and the accessibility audit).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa/features/apps/app_view_pool.dart';
import 'package:sherpa/features/apps/state/apps_providers.dart';
import 'package:sherpa/features/chat/state/chat_mcp_apps.dart';
import 'package:sherpa/features/mcp/state/input_providers.dart';
import 'package:sherpa/features/mcp/state/mcp_providers.dart';
import 'package:sherpa/services/mcp/input/interactive_handler.dart';
import 'package:sherpa/services/mcp/mcp_runtime.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_core/testing.dart';
import 'package:sherpa_mcp/sherpa_mcp.dart';
import 'package:sherpa_webview/sherpa_webview.dart';
import 'package:sherpa_webview/testing.dart';

import '../../../services/mcp/support/input_fakes.dart' show RecordingUrlOpener;
import '../../../services/mcp/support/mcp_fakes.dart';
import 'harness.dart';

const _url = 'https://weather.example.com/mcp';

DartMcpTool _tool(String name, {JsonMap? meta}) => DartMcpTool(
  name: name,
  description: 'Does $name things.',
  inputSchema: const {'type': 'object', 'properties': <String, Object?>{}},
  meta: meta,
  handler: (args, ctx) async => DartToolResult.json({'tool': name, 'args': args}),
);

FakeRemoteServers _weather() => FakeRemoteServers()
  ..add(
    _url,
    name: 'Weather',
    tools: [
      _tool(
        'get_weather',
        meta: const {
          'ui': {'resourceUri': 'ui://weather/view'},
        },
      ),
      _tool(
        'refresh',
        meta: const {
          'ui': {
            'visibility': ['app'],
          },
        },
      ),
    ],
    resources: [
      DartMcpResource(
        uri: 'ui://weather/view',
        name: 'view',
        mimeType: mcpAppMimeType,
        read: () async => const [
          McpTextResourceContents(
            uri: 'ui://weather/view',
            mimeType: mcpAppMimeType,
            text: '<!DOCTYPE html><p>weather</p>',
          ),
        ],
      ),
    ],
  );

/// A chat (real controller, scripted model) over a real MCP runtime with
/// the Weather server, the fake WebView platform and the chat's app
/// overrides exactly as bootstrap installs them.
final class AppChat {
  AppChat._(this.runtime, this.serverId, this.h);

  static Future<AppChat> create(WidgetTester tester, {List<ScriptedTurn> turns = const []}) async {
    McpAppController.resetProfileCountsForTest();
    late McpRuntime rt;
    late String id;
    await tester.runAsync(() async {
      rt = await fakeRuntime(remote: _weather());
      final c = await rt.addServer(url: Uri.parse(_url), name: 'Weather');
      id = c.id;
      await rt.refresh();
      await rt.approveAll(id);
    });
    addTearDown(() => tester.runAsync(rt.dispose));
    final platform = FakeMcpAppPlatform();
    final opener = RecordingUrlOpener();
    final h = ChatHarness(
      turns: turns,
      overrides: [
        mcpRuntimeProvider.overrideWithValue(rt),
        mcpInputQueueProvider.overrideWithValue(rt.inputQueue),
        mcpUrlOpenerProvider.overrideWithValue(opener),
        mcpAppPlatformProvider.overrideWithValue(platform),
        mcpAppViewPoolProvider.overrideWith((ref) {
          final p = McpAppViewPool(ref, hiddenGrace: const Duration(seconds: 1));
          ref.onDispose(p.dispose);
          return p;
        }),
        ...chatMcpAppOverrides(),
      ],
    );
    addTearDown(h.dispose);
    return AppChat._(rt, id, h)..platform = platform;
  }

  final McpRuntime runtime;
  final String serverId;
  final ChatHarness h;
  late final FakeMcpAppPlatform platform;

  String get toolName => '${serverId}__get_weather';

  InteractiveInputHandler get inputs => runtime.manager.options.inputHandler! as InteractiveInputHandler;

  /// user → assistant(tool call) → tool(result with a view) → assistant.
  Future<void> seedWeather({List<ContentPart> replyExtra = const []}) async {
    await h.createSession();
    final s = await h.store.getSession(kSession);
    Message msg(String id, String? parent, Role role, List<ContentPart> content) =>
        Message(id: id, parentId: parent, role: role, content: content, createdAt: h.clock.now(), modelId: kModelId);
    final messages = [
      msg('u1', s!.activeLeafId, Role.user, const [TextPart('Weather in Lisbon?')]),
      msg('a1', 'u1', Role.assistant, [
        ToolCallPart(ToolCall(id: 'c1', name: toolName, arguments: const {'city': 'Lisbon'})),
      ]),
      msg('t1', 'a1', Role.tool, [
        ToolResultPart(
          callId: 'c1',
          toolName: toolName,
          content: const [TextPart('Lisbon: 21°C, clear')],
          structured: const {'tempC': 21},
          uiResourceUri: 'ui://weather/view',
          meta: {ToolResultPart.metaServerId: serverId},
        ),
      ]),
      msg('a2', 't1', Role.assistant, [const TextPart('Sunny in Lisbon.'), ...replyExtra]),
    ];
    for (final m in messages) {
      await h.store.putMessage(kSession, m);
    }
    await h.store.putSession(s.copyWith(activeLeafId: 'a2', title: 'Weather'));
  }

  Future<void> settle(WidgetTester tester, {int rounds = 10}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump(const Duration(milliseconds: 16));
    }
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// Every view after its shell and the App handshake; returns the first
  /// (the tool result's).
  Future<FakeMcpAppChannel> handshake(WidgetTester tester, {String name = 'Weather Dashboard'}) async {
    for (final v in platform.views) {
      v.fake
        ..shellReady()
        ..handshake(name: name);
    }
    await settle(tester);
    return platform.views.first.fake;
  }

  Future<Map<String, Object?>?> response(WidgetTester tester, FakeMcpAppChannel ch, Object id) async {
    for (var i = 0; i < 40 && ch.responseTo(id) == null; i++) {
      await settle(tester, rounds: 2);
    }
    return ch.responseTo(id);
  }

  /// Unmounts everything and lets teardown timers run out.
  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  }
}
