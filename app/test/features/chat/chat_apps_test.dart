/// MCP Apps and MCP input inside the chat: the view of a tool result in
/// the transcript (sherpa_webview's fake platform), `ui/message` sent as an
/// attributed user message, app tool calls on the chat's approval card,
/// app model context at the next user turn, and pending input requests
/// inline above the composer.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa/features/apps/state/apps_providers.dart';
import 'package:sherpa/features/chat/state/chat_view_state.dart';
import 'package:sherpa/features/chat/state/transcript_model.dart';
import 'package:sherpa/features/chat/widgets/approval_card.dart';
import 'package:sherpa/features/mcp/input/input_host.dart';
import 'package:sherpa/services/mcp/input/input_queue.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_core/testing.dart';
import 'package:sherpa_webview/sherpa_webview.dart';

import '../../services/mcp/support/input_fakes.dart';
import 'support/app_chat.dart';
import 'support/fakes.dart';
import 'support/harness.dart';
import 'support/pump.dart';

void main() {
  testWidgets('a tool result with a view renders the app in the transcript, with its server named', (tester) async {
    final a = await AppChat.create(tester);
    await a.seedWeather(
      replyExtra: [UiResourcePart(resourceUri: 'ui://weather/view', serverId: a.serverId, callId: 'c9')],
    );
    await pumpChatScreen(tester, a.h, size: const Size(420, 1400));
    await a.settle(tester);

    expect(find.byKey(const ValueKey('mcp-app-c1')), findsOneWidget, reason: 'under the tool card');
    expect(find.byKey(const ValueKey('mcp-ui-c9')), findsOneWidget, reason: 'a stored UI resource part');
    expect(a.platform.views, hasLength(2));
    final ch = await a.handshake(tester);
    expect(find.text('Content from Weather'), findsWidgets, reason: 'host chrome outside the WebView');
    final first = a.platform.views
        .map((v) => v.fake)
        .firstWhere((f) => f.notifications('ui/notifications/tool-result').isNotEmpty);
    expect(first.notifications('ui/notifications/tool-input').single['params'], {
      'arguments': {'city': 'Lisbon'},
    }, reason: "the matching call's arguments");
    expect((first.notifications('ui/notifications/tool-result').single['params']! as Map)['structuredContent'], {
      'tempC': 21,
    });
    expect(ch, isNotNull);

    final semantics = tester.ensureSemantics();
    expect(find.bySemanticsLabel('Interactive content from Weather'), findsWidgets);
    semantics.dispose();
    await a.close(tester);
  });

  testWidgets('without a WebView the tool text is shown instead, still attributed', (tester) async {
    final a = await AppChat.create(tester);
    a.platform.supported = false;
    a.platform.reason = 'No WebView here';
    await a.seedWeather();
    await pumpChatScreen(tester, a.h, size: const Size(420, 1200));
    await a.settle(tester);
    expect(find.byKey(const ValueKey('mcp-app-c1')), findsOneWidget);
    expect(find.text('Lisbon: 21°C, clear'), findsOneWidget, reason: 'the fallback is the result text');
    await a.close(tester);
  });

  testWidgets('ui/message: confirmed in the view, sent in the chat as "Sent by" the app', (tester) async {
    final a = await AppChat.create(tester, turns: [ScriptedTurn.text('Porto is 19°C.')]);
    await a.seedWeather();
    await pumpChatScreen(tester, a.h, size: const Size(420, 1400));
    await a.settle(tester);
    final ch = await a.handshake(tester);

    ch.viewRequest(1, 'ui/message', {
      'role': 'user',
      'content': [
        {'type': 'text', 'text': 'Show me Porto too'},
      ],
    });
    await a.settle(tester);
    expect(find.text('Send this message?'), findsOneWidget);
    await tester.tap(find.text('Send'));
    await a.response(tester, ch, 1);
    for (var i = 0; i < 60 && find.text('Porto is 19°C.').evaluate().isEmpty; i++) {
      await a.settle(tester, rounds: 2);
    }

    expect(find.text('Sent by Weather Dashboard (from Weather)'), findsOneWidget);
    expect(find.text('Show me Porto too'), findsOneWidget);
    expect(find.text('Porto is 19°C.'), findsOneWidget, reason: 'the agent answered it');
    final user = (await a.h.activePath()).where((m) => m.role == Role.user).last;
    expect(user.text, 'Show me Porto too');
    expect((user.metadata[kMcpAppMessageKey]! as Map)['label'], 'Weather Dashboard (from Weather)');
    expect(user.metadata[UntrustedData.messageMetadataKey], isTrue);
    await a.close(tester);
  });

  testWidgets("app tool calls are approved on the chat's card, labelled as the app's", (tester) async {
    final a = await AppChat.create(tester);
    await a.seedWeather();
    await pumpChatScreen(tester, a.h, size: const Size(420, 1400));
    await a.settle(tester);
    final ch = await a.handshake(tester);

    ch.viewRequest(1, 'tools/call', {'name': 'refresh', 'arguments': <String, Object?>{}});
    await a.settle(tester);
    final pending = a.h.state.pendingApproval;
    expect(pending, isNotNull, reason: "the chat's approval handler got it");
    expect(pending!.isFromApp, isTrue);
    expect(pending.call.id, startsWith('app-'));
    expect(a.h.state.status, isNot(ChatRunStatus.awaitingApproval), reason: 'no run is paused by it');
    expect(find.text('Allow “refresh”?'), findsNothing, reason: 'an app request never pops up by itself');
    expect(find.textContaining('An app asks to use'), findsOneWidget);
    expect(find.byTooltip('Send'), findsOneWidget, reason: 'the composer stays usable');

    await tester.tap(find.text('Review'));
    await a.settle(tester);
    expect(find.byType(ApprovalCard), findsOneWidget);
    expect(find.text('Requested by an app, not by the model'), findsOneWidget);
    expect(find.text('Stop'), findsNothing, reason: 'Stop is about the run');
    await tester.tap(find.text('Allow once'));
    final r = await a.response(tester, ch, 1);
    expect((r!['result']! as Map)['isError'], isNot(true));
    expect(((r['result']! as Map)['structuredContent']! as Map)['tool'], 'refresh');
    expect(a.h.state.pendingApproval, isNull);
    await a.close(tester);
  });

  testWidgets('a pending MCP input request of this chat shows inline above the composer', (tester) async {
    final a = await AppChat.create(tester);
    await a.seedWeather();
    await pumpChatScreen(tester, a.h, size: const Size(420, 1200));
    await a.settle(tester);
    unawaited(
      a.inputs.elicit(
        formRequest({
          'city': {'type': 'string', 'title': 'City'},
        }, message: 'Which city?'),
        inputContext(sessionId: kSession),
      ),
    );
    unawaited(
      a.inputs.elicit(
        formRequest({
          'x': {'type': 'string'},
        }, message: 'Another chat'),
        inputContext(sessionId: 'other-chat'),
      ),
    );
    await a.settle(tester);
    expect(find.byType(McpPendingInputsInline), findsOneWidget);
    expect(find.byType(McpPendingInputCard), findsOneWidget, reason: "only this chat's request");
    expect(find.text('Example tools asks you to fill in a form'), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(McpPendingInputCard), matching: find.text('Review')));
    await a.settle(tester);
    expect(find.text('A tool server needs your input'), findsOneWidget);
    expect(find.text('Which city?'), findsOneWidget);
    for (final p in [...a.runtime.inputQueue.pending]) {
      if (p is PendingFormElicitation) p.cancel();
    }
    await a.close(tester);
  });

  test('app model context goes with the next user turn as untrusted data, once', () async {
    final h = ChatHarness(turns: [ScriptedTurn.text('ok'), ScriptedTurn.text('ok again')]);
    addTearDown(h.dispose);
    await h.createSession();
    final c = await h.open();
    const identity = McpAppIdentity(serverId: 'weather', serverName: 'Weather', appName: 'Weather Dashboard');
    h.container
        .read(mcpAppModelContextsProvider)
        .set(
          kSession,
          'view-1',
          const McpAppModelContext(
            identity: identity,
            content: [
              {'type': 'text', 'text': 'The user selected Porto.'},
            ],
          ),
        );
    await c.send('What about this one?');
    await h.settle();

    final sent = h.scripted.requests.first.messages.lastWhere((m) => m.role == Role.user);
    expect(sent.text, 'What about this one?', reason: 'the bubble shows only what the user typed');
    final ctx = sent.content.whereType<EmbeddedResourcePart>().single;
    expect(ctx.text, contains('<untrusted_app_context source="Weather Dashboard (from Weather)">'));
    expect(ctx.text, contains('The user selected Porto.'));
    final item = h.state.items.whereType<UserItem>().last;
    expect(item.resources.single.label, 'Context from Weather Dashboard');
    expect(item.resources.single.serverName, 'Weather');
    expect(h.container.read(mcpAppModelContextsProvider).latest(kSession), isEmpty, reason: 'taken');

    await c.send('And tomorrow?');
    await h.settle();
    final next = h.scripted.requests.last.messages.lastWhere((m) => m.role == Role.user);
    expect(next.content.whereType<EmbeddedResourcePart>(), isEmpty, reason: 'sent once');
  });

  test('sendAppMessage attributes the message and waits for a running reply', () async {
    final h = ChatHarness(
      turns: [ScriptedTurn.text('first'), ScriptedTurn.text('second')],
      eventDelay: const Duration(milliseconds: 5),
    );
    addTearDown(h.dispose);
    await h.createSession();
    final c = await h.open();
    final running = c.send('Hello');
    await Future<void>.delayed(const Duration(milliseconds: 1));
    expect(c.isRunning, isTrue);
    final app = c.sendAppMessage('Book it', from: 'Trips (from Travel)');
    await running;
    await app;
    await h.settle();
    final users = (await h.activePath()).where((m) => m.role == Role.user).toList();
    expect(users.map((m) => m.text), ['Hello', 'Book it'], reason: 'queued behind the running reply, not dropped');
    expect(AppMessageSource.of(users.last)!.text, 'Sent by Trips (from Travel)');
    expect(h.state.items.whereType<UserItem>().last.appSource?.label, 'Trips (from Travel)');
    expect(AppMessageSource.of(users.first), isNull);
  });

  test("Stop and the end of a run deny the run's approvals, never an app's", () async {
    final h = ChatHarness(
      tools: [writeTool('save_note', title: 'Save note')],
      turns: [
        ScriptedTurn.toolCalls([
          ToolCall(id: 'c1', name: 'save_note', arguments: const {'text': 'x'}),
        ]),
        ScriptedTurn.text('unused'),
      ],
    );
    addTearDown(h.dispose);
    await h.createSession();
    final c = await h.open();
    final run = c.send('Save it');
    await h.settle();
    expect(h.state.pendingApproval?.call.id, 'c1');

    final appDecision = c.approvalHandler.requestApproval(
      sessionId: kSession,
      call: const ToolCall(id: 'app-c9-1', name: 'weather__refresh', arguments: {}),
      tool: null,
      requirement: const NeedsConfirmation(RiskLevel.moderate, 'An app view asked for this.'),
      cancel: CancellationToken(),
    );
    c.stop();
    await run;
    await h.settle();
    final after = h.state.pendingApproval;
    expect(after?.call.id, 'app-c9-1', reason: "the app's request still waits");
    expect(after!.isFromApp, isTrue);
    expect(after.requesterLabel, 'Requested by an app');
    expect(h.state.status, isNot(ChatRunStatus.awaitingApproval));
    expect(h.state.tools.containsKey('app-c9-1'), isFalse, reason: 'no tool card for an app call');

    c.respondToApproval(const ApprovalResponse(UserDecision.approve));
    expect((await appDecision).decision, UserDecision.approve);
    expect(h.state.pendingApproval, isNull);
  });
}
