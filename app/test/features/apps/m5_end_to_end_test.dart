/// M5 end to end, through a real in-process MCP server (`DartMcpServer`,
/// 2026-07-28 era, so input arrives as MRTR `inputRequests`), the real
/// runtime (per-server capabilities, router, approval policy), the input
/// queue and its sheets, the user's model through the provider registry,
/// and the MCP App view host on sherpa_webview's fake platform.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa/features/apps/mcp_app_message_view.dart';
import 'package:sherpa/features/apps/state/apps_providers.dart';
import 'package:sherpa/features/mcp/input/input_host.dart';
import 'package:sherpa/services/mcp/input/host_settings.dart';
import 'package:sherpa/services/mcp/input/input_history.dart';
import 'package:sherpa/services/mcp/input/input_queue.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_mcp/sherpa_mcp.dart';
import 'package:sherpa_webview/sherpa_webview.dart';
import 'package:sherpa_webview/testing.dart';

import '../mcp/support/input_rig.dart';

const _url = 'https://travel.example.com/mcp';

JsonMap? _map(Object? v) => v is Map ? v.cast<String, Object?>() : null;

/// `plan_trip`: asks where to (form elicitation), then asks the client's
/// model for an itinerary (sampling), then returns text plus a UI view.
DartMcpServer _travelServer(List<JsonMap> declared) => DartMcpServer(
      info: const McpImplementation(name: 'travel', version: '1'),
      tools: [
        DartMcpTool(
          name: 'plan_trip',
          description: 'Plans a trip.',
          inputSchema: const {'type': 'object', 'properties': <String, Object?>{}},
          meta: const {
            'ui': {'resourceUri': 'ui://travel/itinerary'},
          },
          handler: (args, ctx) async {
            declared.add(ctx.clientCapabilities);
            final r = ctx.inputResponses ?? const <String, Object?>{};
            // MRTR keeps no session: what the server learnt so far travels in
            // requestState, echoed back byte-exact by the client.
            if (ctx.requestState == null) {
              return const DartToolResult.inputRequired({
                'where': {
                  'method': 'elicitation/create',
                  'params': {
                    'mode': 'form',
                    'message': 'Where do you want to go?',
                    'requestedSchema': {
                      'type': 'object',
                      'properties': {
                        'city': {'type': 'string', 'title': 'City'},
                        'nights': {'type': 'integer', 'title': 'Nights', 'minimum': 1, 'default': 2},
                      },
                      'required': ['city'],
                    },
                  },
                },
              }, requestState: 'step-1');
            }
            if (ctx.requestState == 'step-1') {
              final where = _map(r['where']);
              if (where?['action'] != 'accept') return DartToolResult.text('No trip, then.');
              final content = _map(where!['content'])!;
              return DartToolResult.inputRequired({
                'plan': {
                  'method': 'sampling/createMessage',
                  'params': {
                    'messages': [
                      {
                        'role': 'user',
                        'content': {'type': 'text', 'text': 'Suggest ${content['nights']} nights in ${content['city']}.'},
                      },
                    ],
                    'maxTokens': 200,
                  },
                },
              }, requestState: jsonEncode(content));
            }
            final content = _map(jsonDecode(ctx.requestState!))!;
            final itinerary = (_map(_map(r['plan'])?['content'])?['text'] as String?) ?? '';
            return DartToolResult.json({'city': content['city'], 'itinerary': itinerary},
                text: 'Trip to ${content['city']}: $itinerary');
          },
        ),
      ],
      resources: [
        DartMcpResource(
          uri: 'ui://travel/itinerary',
          name: 'itinerary',
          mimeType: mcpAppMimeType,
          read: () async => const [
            McpTextResourceContents(uri: 'ui://travel/itinerary', mimeType: mcpAppMimeType, text: '<!DOCTYPE html><p>trip</p>'),
          ],
        ),
      ],
    );

void main() {
  testWidgets('a tool that elicits, samples and returns a UI resource, answered through the real UI', (tester) async {
    McpAppController.resetProfileCountsForTest();
    final declared = <JsonMap>[];
    final remote = FakeRemoteServers();
    remote.servers[_url] = _travelServer(declared);
    final rig = await InputRig.create(tester, remote: remote);
    rig.model.reply = 'Day 1: Alfama. Day 2: Belém.';
    final platform = FakeMcpAppPlatform();
    rig.extra = [mcpAppPlatformProvider.overrideWithValue(platform)];
    late String serverId;
    await tester.runAsync(() async {
      final c = await rig.runtime.addServer(url: Uri.parse(_url), name: 'Travel');
      serverId = c.id;
      await rig.runtime.updateHostSettings(serverId, const McpServerHostSettings(sampling: McpSamplingMode.ask));
      await rig.runtime.refresh();
      await rig.runtime.approveAll(serverId);
    });
    await rig.pumpApp(tester, home: const Scaffold(body: McpPendingInputsInline(sessionId: 'chat-1')));

    // The model calls the tool.
    ToolResult? result;
    await tester.runAsync(() async {
      final router = rig.runtime.router;
      final call = ToolCall(id: 'call-1', name: '${serverId}__plan_trip', arguments: const {});
      final def = router.lookup(call.name)!;
      expect(rig.runtime.policy.evaluate(def, 'chat-1'), isA<NeedsConfirmation>(), reason: 'the agent loop would ask first');
      unawaited(router
          .execute(call, ToolExecutionContext(sessionId: 'chat-1', cancel: CancellationToken(), timeout: const Duration(seconds: 30)))
          .then((r) => result = r));
    });
    await rig.settle(tester);

    // 1. The form, from the chat's inline card.
    expect(find.byType(McpPendingInputCard), findsOneWidget);
    expect(find.text('Travel asks you to fill in a form'), findsNWidgets(2), reason: 'the card and the app-wide banner');
    await tester.tap(find.descendant(of: find.byType(McpPendingInputCard), matching: find.text('Review')));
    await tester.pumpAndSettle();
    expect(find.text('Where do you want to go?'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('elicit-city')), 'Lisbon');
    await tester.tap(find.text('Send to Travel'));
    await rig.settle(tester);

    // 2. Sampling: approval, the model runs, the answer is reviewed.
    expect(find.text('Travel asks to use your model'), findsNWidgets(2));
    await tester.tap(find.descendant(of: find.byType(McpPendingInputCard), matching: find.text('Review')));
    await tester.pumpAndSettle();
    expect(find.text('Suggest 2 nights in Lisbon.'), findsOneWidget, reason: 'the default was pre-filled and sent');
    await tester.tap(find.text('Allow once'));
    await rig.settle(tester);
    expect(find.text('Send this answer?'), findsOneWidget);
    await tester.tap(find.text('Send answer'));
    await rig.settle(tester);
    for (var i = 0; i < 20 && result == null; i++) {
      await rig.settle(tester, rounds: 2);
    }

    final r = result!;
    expect(r.isError, isFalse);
    expect(r.content.whereType<TextPart>().single.text, 'Trip to Lisbon: Day 1: Alfama. Day 2: Belém.');
    expect(r.uiResourceUri, 'ui://travel/itinerary');
    expect(rig.model.requests.single.tools, isEmpty);
    expect(rig.model.requests.single.params.maxOutputTokens, 200);
    expect(declared.first['sampling'], isNotNull, reason: 'declared because the user allowed it for this server');
    expect((declared.first['extensions']! as Map).containsKey(McpExtensionIds.ui), isTrue);
    expect([for (final x in rig.runtime.inputRecords(serverId)) (x.kind, x.outcome)], [
      (McpInputKind.form, McpInputOutcome.accepted),
      (McpInputKind.sampling, McpInputOutcome.accepted),
    ]);
    expect(rig.runtime.inputRecords(serverId).first.summary, isNot(contains('Lisbon')), reason: 'answers are not logged');

    // 3. The result renders as an MCP App with its tool data.
    final part = ToolResultPart(
      callId: 'call-1',
      toolName: '${serverId}__plan_trip',
      content: r.content,
      structured: r.structured,
      uiResourceUri: r.uiResourceUri,
      meta: {...r.meta, ToolResultPart.metaServerId: serverId},
    );
    await rig.pumpApp(tester, home: Scaffold(body: ListView(children: [McpAppMessageView(sessionId: 'chat-1', result: part)])));
    await rig.settle(tester, andSettle: false);
    final view = platform.last.fake
      ..shellReady()
      ..handshake();
    await rig.settle(tester, andSettle: false);
    expect(find.text('Content from Travel'), findsOneWidget);
    expect(view.commands('load').single['html'], '<!DOCTYPE html><p>trip</p>');
    final delivered = view.notifications('ui/notifications/tool-result').single['params']! as Map;
    expect((delivered['structuredContent']! as Map)['itinerary'], 'Day 1: Alfama. Day 2: Belém.');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });
}
