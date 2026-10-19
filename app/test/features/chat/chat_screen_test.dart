import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa/features/chat/model_picker_sheet.dart';
import 'package:sherpa/features/chat/state/chat_dependencies.dart';
import 'package:sherpa/features/chat/state/chat_view_state.dart';
import 'package:sherpa/features/chat/widgets/assistant_turn.dart';
import 'package:sherpa/features/chat/widgets/transcript.dart';
import 'package:sherpa/features/chat/widgets/user_message.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_core/testing.dart';
import 'package:sherpa_providers/sherpa_providers.dart';

import 'support/fakes.dart';
import 'support/harness.dart';
import 'support/pump.dart';

ToolCall call(String id, String name, [Map<String, Object?> args = const {}]) =>
    ToolCall(id: id, name: name, arguments: args);

/// Advances fake time in small steps so scripted events stream through.
Future<void> stream(WidgetTester tester, {int frames = 30, Duration step = const Duration(milliseconds: 16)}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(step);
  }
}

Future<void> typeAndSend(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.pump();
  await tester.tap(find.byTooltip('Send'));
  await tester.pump();
}

void main() {
  late ChatHarness h;
  tearDown(() => h.dispose());

  testWidgets('send → the streamed reply appears; Stop is visible during the run', (tester) async {
    final p = ManualProvider();
    h = ChatHarness(provider: p);
    await h.createSession();
    await pumpChatScreen(tester, h);
    expect(find.text('What are we working on?'), findsOneWidget);

    await typeAndSend(tester, 'Why are there tides?');
    expect(find.descendant(of: find.byType(UserBubble), matching: find.text('Why are there tides?')), findsOneWidget,
        reason: 'shown immediately');
    await tester.pump(const Duration(milliseconds: 300)); // past the send→stop transition
    expect(find.byTooltip('Stop (Esc)'), findsOneWidget);
    expect(find.byTooltip('Send'), findsNothing);
    expect(find.text('Thinking…'), findsOneWidget, reason: 'before the first token');

    p.emit(const TextDelta('The tide '));
    await stream(tester, frames: 2);
    expect(find.textContaining('The tide'), findsOneWidget, reason: 'partial text while streaming');
    expect(find.byTooltip('Stop (Esc)'), findsOneWidget);

    p.emit(const TextDelta('follows the moon.'));
    await p.finish();
    await stream(tester, frames: 5);
    await tester.pumpAndSettle();
    expect(find.text('The tide follows the moon.'), findsOneWidget);
    expect(find.byTooltip('Stop (Esc)'), findsNothing);
    expect(find.byTooltip('Copy reply'), findsOneWidget);
    expect(find.byTooltip('Retry'), findsOneWidget);
  });

  testWidgets('Stop ends the run and says so inline', (tester) async {
    final p = ManualProvider();
    h = ChatHarness(provider: p);
    await h.createSession();
    await pumpChatScreen(tester, h);
    await typeAndSend(tester, 'Write an essay');
    p.emit(const TextDelta('Once upon'));
    await stream(tester, frames: 3);
    expect(find.textContaining('Once upon'), findsOneWidget);
    await tester.tap(find.byTooltip('Stop (Esc)'));
    await stream(tester, frames: 5);
    await tester.pumpAndSettle();
    expect(find.text('You stopped this response.'), findsOneWidget);
    expect(find.byTooltip('Send'), findsOneWidget);
    expect(h.state.status, ChatRunStatus.cancelled);
  });

  testWidgets('Enter sends from a hardware keyboard, Shift+Enter does not', (tester) async {
    h = ChatHarness(turns: [ScriptedTurn.text('Hi!')]);
    await h.createSession();
    await pumpChatScreen(tester, h);
    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), 'line one');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(h.state.items, isEmpty, reason: 'Shift+Enter is a newline');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await stream(tester, frames: 10);
    await tester.pumpAndSettle();
    expect(find.text('Hi!'), findsOneWidget);
  });

  testWidgets('approval card: docked on wide screens, Allow once runs the tool', (tester) async {
    final tool = writeTool('save_note', title: 'Save note');
    h = ChatHarness(
      tools: [tool],
      turns: [
        ScriptedTurn.toolCalls([call('c1', 'save_note', {'text': 'Buy milk'})]),
        ScriptedTurn.text('Saved your note.'),
      ],
    );
    await h.createSession();
    await pumpChatScreen(tester, h, size: const Size(900, 900));
    await typeAndSend(tester, 'Remember to buy milk');
    await stream(tester, frames: 10);

    expect(find.text('Allow “Save note”?'), findsOneWidget);
    expect(find.text('Can make changes'), findsOneWidget);
    expect(find.textContaining('"text": "Buy milk"'), findsOneWidget, reason: 'exact arguments');
    expect(find.text('Always allow'), findsOneWidget);
    expect(find.byTooltip('Stop (Esc)'), findsOneWidget, reason: 'Stop stays visible during approval');
    expect(h.platform.haptics, contains(ChatHaptic.approvalRequested));

    await tester.tap(find.text('Allow once'));
    await stream(tester, frames: 10);
    await tester.pumpAndSettle();
    expect(find.text('Allow “Save note”?'), findsNothing);
    expect(tool.calls.single, {'text': 'Buy milk'});
    expect(find.text('Saved your note.'), findsOneWidget);
  });

  testWidgets('approval sheet on compact screens; Deny records a denied call', (tester) async {
    final tool = destructiveTool('delete_file', title: 'Delete file');
    h = ChatHarness(
      tools: [tool],
      turns: [
        ScriptedTurn.toolCalls([call('c1', 'delete_file', {'path': '/notes/todo.md'})]),
        ScriptedTurn.text('Left it alone.'),
      ],
    );
    await h.createSession();
    await pumpChatScreen(tester, h, size: const Size(360, 740));
    await typeAndSend(tester, 'Delete my todo file');
    await stream(tester, frames: 10);
    await tester.pumpAndSettle();

    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.text('Can modify or delete data'), findsOneWidget);
    expect(find.text('Always allow'), findsNothing, reason: 'never for destructive tools');
    expect(find.text('Actions that can delete data always ask first.'), findsOneWidget);

    await tester.tap(find.text('Deny'));
    await stream(tester, frames: 10);
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    expect(tool.calls, isEmpty);
    expect(find.text('Denied'), findsOneWidget);
    expect(find.text('Left it alone.'), findsOneWidget);
  });

  testWidgets('tool card expands to show arguments and result', (tester) async {
    final tool = FakeTool('lookup', title: 'Look up', onRun: (args, ctx) async => ToolResult.text('42 is the answer'));
    h = ChatHarness(
      tools: [tool],
      turns: [
        ScriptedTurn.toolCalls([call('c1', 'lookup', {'q': 'meaning of life'})]),
        ScriptedTurn.text('It is 42.'),
      ],
    );
    await h.createSession();
    await pumpChatScreen(tester, h);
    await typeAndSend(tester, 'Look it up');
    await stream(tester, frames: 20);
    await tester.pumpAndSettle();

    expect(find.text('Look up'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);
    expect(find.text('42 is the answer'), findsNothing, reason: 'collapsed by default');
    await tester.tap(find.text('Look up'));
    await tester.pumpAndSettle();
    expect(find.textContaining('"q": "meaning of life"'), findsOneWidget);
    expect(find.text('42 is the answer'), findsOneWidget);
  });

  testWidgets('consecutive tool calls group as "Ran 2 tools"', (tester) async {
    h = ChatHarness(
      tools: [FakeTool('a'), FakeTool('b')],
      turns: [
        ScriptedTurn.toolCalls([call('c1', 'a'), call('c2', 'b')]),
        ScriptedTurn.text('Both done.'),
      ],
    );
    await h.createSession();
    await pumpChatScreen(tester, h);
    await typeAndSend(tester, 'Do both');
    await stream(tester, frames: 20);
    await tester.pumpAndSettle();
    expect(find.text('Ran 2 tools'), findsOneWidget);
    expect(find.text('a'), findsNothing, reason: 'collapsed once finished');
    await tester.tap(find.text('Ran 2 tools'));
    await tester.pumpAndSettle();
    expect(find.text('a'), findsOneWidget);
    expect(find.text('b'), findsOneWidget);
  });

  testWidgets('retry creates a branch and the switcher moves between them', (tester) async {
    h = ChatHarness(turns: [ScriptedTurn.text('First take.'), ScriptedTurn.text('Second take.')]);
    await h.createSession();
    await pumpChatScreen(tester, h);
    await typeAndSend(tester, 'Tell me a joke');
    await stream(tester, frames: 10);
    await tester.pumpAndSettle();
    h.clock.advance(const Duration(seconds: 3));

    await tester.tap(find.byTooltip('Retry'));
    await stream(tester, frames: 10);
    await tester.pumpAndSettle();
    expect(find.text('Second take.'), findsOneWidget);
    expect(find.text('2/2'), findsOneWidget);

    await tester.tap(find.byTooltip('Previous reply'));
    await stream(tester, frames: 5);
    await tester.pumpAndSettle();
    expect(find.text('First take.'), findsOneWidget);
    expect(find.text('1/2'), findsOneWidget);
  });

  testWidgets('long-press → Edit puts the text in the composer and sends a new version', (tester) async {
    h = ChatHarness(turns: [ScriptedTurn.text('Paris.'), ScriptedTurn.text('Rome.')]);
    await h.createSession();
    await pumpChatScreen(tester, h);
    await typeAndSend(tester, 'Capital of France?');
    await stream(tester, frames: 10);
    await tester.pumpAndSettle();
    h.clock.advance(const Duration(seconds: 3));

    await tester.longPress(find.descendant(of: find.byType(UserBubble), matching: find.text('Capital of France?')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit message'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Editing your message'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Capital of Italy?');
    await tester.tap(find.byTooltip('Send'));
    await stream(tester, frames: 10);
    await tester.pumpAndSettle();
    expect(find.text('Rome.'), findsOneWidget);
    expect(find.text('Edited'), findsOneWidget);
    expect(find.text('2/2'), findsOneWidget);
  });

  testWidgets('jump-to-latest appears when scrolled up and returns to the bottom', (tester) async {
    h = ChatHarness();
    await h.createSession();
    for (var i = 0; i < 12; i++) {
      await h.seedExchange('Question $i', List.filled(8, 'A long answer line $i.').join('\n\n'));
    }
    await pumpChatScreen(tester, h);
    await tester.pumpAndSettle();
    final jump = find.byKey(const ValueKey('jump-to-latest'));
    expect(tester.widget<IgnorePointer>(find.ancestor(of: jump, matching: find.byType(IgnorePointer)).first).ignoring, isTrue);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, 600));
    await tester.pumpAndSettle();
    final transcript = tester.state<ChatTranscriptState>(find.byType(ChatTranscript));
    expect(transcript.follow.pinned, isFalse);
    expect(transcript.follow.showJump, isTrue);
    expect(tester.widget<IgnorePointer>(find.ancestor(of: jump, matching: find.byType(IgnorePointer)).first).ignoring, isFalse);

    await tester.tap(jump);
    await tester.pumpAndSettle();
    expect(transcript.follow.pinned, isTrue);
    expect(transcript.scrollController.position.extentAfter, lessThan(1));
  });

  testWidgets('streaming while scrolled up does not move what the reader sees', (tester) async {
    final p = ManualProvider();
    h = ChatHarness(provider: p);
    await h.createSession();
    for (var i = 0; i < 8; i++) {
      await h.seedExchange('Question $i', List.filled(6, 'Answer line $i.').join('\n\n'));
    }
    await pumpChatScreen(tester, h);
    await tester.pumpAndSettle();
    await typeAndSend(tester, 'One more');
    p.emit(const TextDelta('Starting… '));
    await stream(tester, frames: 3);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, 500));
    await tester.pumpAndSettle();
    final anchor = find.text('Question 5');
    final before = tester.getTopLeft(anchor).dy;
    for (var i = 0; i < 200; i++) {
      p.emit(TextDelta('token$i '));
      if (i % 20 == 0) p.emit(const TextDelta('\n\n'));
    }
    await stream(tester, frames: 10);
    expect(tester.getTopLeft(anchor).dy, before, reason: 'zero drift while detached');
    final transcript = tester.state<ChatTranscriptState>(find.byType(ChatTranscript));
    expect(transcript.follow.unread, isTrue);
    await p.finish();
    await stream(tester, frames: 5);
  });

  testWidgets('finished messages are not rebuilt while a reply streams', (tester) async {
    final p = ManualProvider();
    h = ChatHarness(provider: p);
    await h.createSession();
    await h.seedExchange('Earlier question', 'Earlier answer.');
    final userBuilds = <String, int>{};
    final turnBuilds = <String, int>{};
    UserMessageTile.debugOnBuild = (id) => userBuilds[id] = (userBuilds[id] ?? 0) + 1;
    AssistantTurnTile.debugOnBuild = (key) => turnBuilds[key] = (turnBuilds[key] ?? 0) + 1;
    addTearDown(() {
      UserMessageTile.debugOnBuild = null;
      AssistantTurnTile.debugOnBuild = null;
    });
    await pumpChatScreen(tester, h);
    await tester.pumpAndSettle();
    await typeAndSend(tester, 'New question');
    p.emit(const TextDelta('First words '));
    await stream(tester, frames: 3);

    final earlierUser = Map.of(userBuilds);
    final earlierTurns = Map.of(turnBuilds);
    for (var i = 0; i < 60; i++) {
      p.emit(TextDelta('w$i '));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(find.textContaining('w59'), findsOneWidget);
    expect(userBuilds, earlierUser, reason: 'no user bubble rebuilt during streaming');
    expect(turnBuilds, earlierTurns, reason: 'no assistant turn rebuilt during streaming');
    await p.finish();
    await stream(tester, frames: 5);
  });

  testWidgets('no provider: composer replaced by setup CTA that opens provider setup', (tester) async {
    h = ChatHarness(configured: false);
    await h.createSession(withModel: false);
    final router = await pumpChatScreen(tester, h);
    await tester.pumpAndSettle();
    expect(find.text('Add a model to start chatting'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.text('Add provider'));
    await tester.pumpAndSettle();
    expect(find.text('route:/settings/providers/new'), findsOneWidget);
    expect(router.state.uri.path, '/settings/providers/new');
  });

  testWidgets('errors render as an actionable card', (tester) async {
    h = ChatHarness(turns: [
      ScriptedTurn.error(const ProviderException(ProviderErrorKind.auth, 'invalid x-api-key', statusCode: 401)),
    ]);
    await h.createSession();
    final router = await pumpChatScreen(tester, h);
    await typeAndSend(tester, 'Hi');
    await stream(tester, frames: 10);
    await tester.pumpAndSettle();
    expect(find.text("Test Cloud didn't accept the API key"), findsOneWidget);
    await tester.tap(find.text('Details'));
    await tester.pump();
    expect(find.textContaining('HTTP 401'), findsOneWidget);
    await tester.tap(find.text('Fix provider'));
    await tester.pumpAndSettle();
    expect(router.state.uri.path, '/settings/providers/cloud');
  });

  testWidgets('slash menu lists built-in commands', (tester) async {
    h = ChatHarness();
    await h.createSession();
    await pumpChatScreen(tester, h);
    await tester.enterText(find.byType(TextField), '/');
    await tester.pump();
    expect(find.text('/new'), findsOneWidget);
    expect(find.text('/retry'), findsOneWidget);
    expect(find.text('/model'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '/mo');
    await tester.pump();
    expect(find.text('/new'), findsNothing);
    await tester.tap(find.text('/model'));
    await tester.pumpAndSettle();
    expect(find.text('Choose a model'), findsOneWidget, reason: '/model opens the picker');
    expect(find.text('Scripted model'), findsWidgets);
  });

  testWidgets('model picker lists models with privacy badges and switches', (tester) async {
    final local = ScriptedProvider(const [], info: const ProviderInfo(
      id: 'phone',
      kind: ProviderKind.fake,
      displayName: 'On this phone',
      location: ExecutionLocation.onDevice,
    ));
    h = ChatHarness(
      configs: [
        kCloudConfig,
        ProviderConfig(
          id: 'phone',
          flavor: ApiFlavor.openAiChat,
          displayName: 'Phone server',
          baseUrl: Uri.parse('http://127.0.0.1:8080/v1'),
        ),
      ],
    );
    h.registry.setProvider(kProviderId, h.provider);
    h.registry.setProvider('phone', local);
    await h.createSession();
    await pumpChatScreen(tester, h);
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel(RegExp('^Model: ')));
    await tester.pumpAndSettle();
    final sheet = find.byType(ModelPickerSheet);
    expect(find.descendant(of: sheet, matching: find.text('Test Cloud')), findsOneWidget);
    expect(find.descendant(of: sheet, matching: find.text('api.example.com')), findsOneWidget);
    expect(find.descendant(of: sheet, matching: find.text('On device')), findsOneWidget);
    // Both providers offer "Scripted model"; the phone server is listed second.
    final localRow = find.descendant(of: sheet, matching: find.text('Scripted model', skipOffstage: false)).last;
    await tester.ensureVisible(localRow);
    await tester.pumpAndSettle();
    await tester.tap(localRow);
    await tester.pumpAndSettle();
    final s = await h.store.getSession(kSession);
    expect(s!.providerId, 'phone');
  });

  testWidgets('context ring opens the budget breakdown', (tester) async {
    h = ChatHarness();
    await h.createSession();
    await h.seedExchange('Hi', 'Hello!');
    await pumpChatScreen(tester, h);
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel(RegExp('^Context about')));
    await tester.pumpAndSettle();
    expect(find.text('Context window'), findsOneWidget);
    expect(find.text('Conversation'), findsOneWidget);
    expect(find.text('Reserved for the reply'), findsOneWidget);
  });

  testWidgets('interrupted run offers Resume', (tester) async {
    h = ChatHarness(turns: [ScriptedTurn.text('Resumed reply.')]);
    await h.createSession();
    final (user, _) = await h.seedExchange('Q', 'A');
    await h.store.putCheckpoint(RunCheckpoint(
      sessionId: kSession,
      runId: 'r0',
      phase: RunPhase.preparingContext,
      step: 1,
      updatedAt: h.clock.now(),
      leafMessageId: user.id,
    ));
    final s = await h.store.getSession(kSession);
    await h.store.putSession(s!.copyWith(activeLeafId: user.id));
    await pumpChatScreen(tester, h);
    await tester.pumpAndSettle();
    expect(find.text('The last reply was interrupted when the app closed.'), findsOneWidget);
    await tester.tap(find.text('Resume'));
    await stream(tester, frames: 10);
    await tester.pumpAndSettle();
    expect(find.text('Resumed reply.'), findsOneWidget);
    expect(find.text('Resume'), findsNothing);
  });

  testWidgets('a failed share offers "Try again", which shares again instead of regenerating', (tester) async {
    h = ChatHarness(turns: [ScriptedTurn.text('An answer.')]);
    await h.createSession();
    await pumpChatScreen(tester, h);
    await typeAndSend(tester, 'Question');
    await stream(tester, frames: 10);
    await tester.pumpAndSettle();
    h.platform.failShares = 1;
    await tester.tap(find.byTooltip('Share reply'));
    await tester.pumpAndSettle();
    expect(find.text("Couldn't share this reply"), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.text("Couldn't share this reply"), findsNothing);
    expect(h.platform.shared, ['An answer.']);
    expect(h.scripted.requests, hasLength(1), reason: 'no new model call');
    expect(find.byTooltip('Previous version'), findsNothing, reason: 'no new branch');
  });

  testWidgets('a repaired call: only Deny and Allow once, with the reason', (tester) async {
    final tool = writeTool('save_note', title: 'Save note');
    h = ChatHarness(
      tools: [tool],
      turns: [
        ScriptedTurn.toolCalls(const [ToolCall(id: 'c1', name: 'save_note', arguments: {'text': 'milk'}, repaired: true)]),
        ScriptedTurn.text('Saved.'),
      ],
    );
    await h.createSession();
    await pumpChatScreen(tester, h, size: const Size(900, 900));
    await typeAndSend(tester, 'Save');
    await stream(tester, frames: 10);

    expect(find.text("The model's request had to be repaired"), findsOneWidget);
    expect(find.textContaining('Sherpa repaired them'), findsOneWidget, reason: "the policy's reason");
    expect(find.text('Deny'), findsOneWidget);
    expect(find.text('Allow once'), findsOneWidget);
    expect(find.text('Allow for this chat'), findsNothing);
    expect(find.text('Always allow'), findsNothing);
    expect(find.text('A corrected request can only be allowed once.'), findsOneWidget);
    await tester.tap(find.text('Allow once'));
    await stream(tester, frames: 10);
    await tester.pumpAndSettle();
    expect(tool.calls.single, {'text': 'milk'});
  });

  testWidgets('a proxied call shows the target tool, its server and arguments; no "Always"', (tester) async {
    h = ChatHarness(
      router: ProxyToolRouter(),
      turns: [
        ScriptedTurn.toolCalls([
          call('c1', ProxyToolRouter.proxyName, {
            'name': 'github__create_issue',
            'arguments': {'title': 'Crash on launch'},
          }),
        ]),
        ScriptedTurn.text('Filed.'),
      ],
    );
    await h.createSession();
    await pumpChatScreen(tester, h, size: const Size(900, 900));
    await typeAndSend(tester, 'File it');
    await stream(tester, frames: 10);

    expect(find.text('Allow “Create issue”?'), findsOneWidget);
    expect(find.text('github__create_issue · GitHub'), findsOneWidget);
    expect(find.textContaining('"title": "Crash on launch"'), findsOneWidget);
    expect(find.textContaining('call_tool'), findsNothing);
    expect(find.text('Allow for this chat'), findsOneWidget);
    expect(find.text('Always allow'), findsNothing);
    expect(find.text("Tools from a server you haven't trusted can't be allowed permanently."), findsOneWidget);
    await tester.tap(find.text('Deny'));
    await stream(tester, frames: 10);
    await tester.pumpAndSettle();
  });

  testWidgets('dismissible notices close', (tester) async {
    final tool = writeTool('save_note');
    h = ChatHarness(tools: [tool], turns: [
      ScriptedTurn([
        const ToolCallStart(index: 0, id: 'c1', name: 'save_note'),
        ToolCallComplete(
          index: 0,
          call: const ToolCall(id: 'c1', name: 'save_note', arguments: {}, argumentsError: 'truncated'),
        ),
        const Finish(FinishReason.length),
      ]),
      ScriptedTurn.text('Shorter this time.'),
    ]);
    await h.createSession();
    await pumpChatScreen(tester, h);
    await typeAndSend(tester, 'Save a long note');
    await stream(tester, frames: 20);
    await tester.pumpAndSettle();
    expect(find.textContaining("didn't run that call"), findsOneWidget);
    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pumpAndSettle();
    expect(find.textContaining("didn't run that call"), findsNothing);
  });

  group('accessibility', () {
    testWidgets('one live region announces phases, never the streaming text', (tester) async {
      final handle = tester.ensureSemantics();
      final p = ManualProvider();
      h = ChatHarness(provider: p);
      await h.createSession();
      await pumpChatScreen(tester, h);
      await typeAndSend(tester, 'Hello');
      p.emit(const TextDelta('Streaming words here'));
      await stream(tester, frames: 3);

      final live = find.byWidgetPredicate((w) => w is Semantics && (w.properties.liveRegion ?? false));
      expect(live, findsOneWidget);
      final label = tester.widget<Semantics>(live).properties.label;
      expect(label, 'Assistant is responding');

      await p.finish();
      await stream(tester, frames: 5);
      await tester.pump(const Duration(seconds: 2));
      expect(tester.widget<Semantics>(live).properties.label, 'Response complete');
      handle.dispose();
    });

    testWidgets('meets tap-target and label guidelines', (tester) async {
      final handle = tester.ensureSemantics();
      h = ChatHarness(turns: [ScriptedTurn.text('An answer.')]);
      await h.createSession();
      await pumpChatScreen(tester, h);
      await typeAndSend(tester, 'Question');
      await stream(tester, frames: 10);
      await tester.pumpAndSettle();
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      handle.dispose();
    });

    testWidgets('Stop, Send, the model chip and the context ring are operable buttons for screen readers',
        (tester) async {
      final handle = tester.ensureSemantics();
      final p = ManualProvider(info: kCloudInfo);
      h = ChatHarness(provider: p);
      await h.createSession();
      await pumpChatScreen(tester, h);
      await tester.pumpAndSettle();

      SemanticsNode node(String label) => tester.getSemantics(find.bySemanticsLabel(RegExp(label)).first);
      for (final label in ['^Model: ', '^Context ']) {
        final n = node(label);
        expect(n.getSemanticsData().hasAction(SemanticsAction.tap), isTrue, reason: '$label has a tap action');
        expect(n.getSemanticsData().flagsCollection.isButton, isTrue);
        expect(n.rect.width, lessThan(400), reason: '$label is its own node, not the whole screen');
      }

      await tester.enterText(find.byType(TextField), 'Hello');
      await tester.pump();
      final send = node('^Send message');
      expect(send.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      tester.semantics.tap(find.semantics.byLabel('Send message'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(h.state.isRunActive, isTrue, reason: 'the semantics tap sent the message');

      p.emit(const TextDelta('Streaming'));
      await stream(tester, frames: 3);
      final stop = node('^Stop response');
      expect(stop.rect.width, lessThan(100), reason: 'Stop is not merged into a screen-wide node');
      tester.semantics.tap(find.semantics.byLabel('Stop response'));
      await stream(tester, frames: 5);
      await tester.pumpAndSettle();
      expect(h.state.status, ChatRunStatus.cancelled, reason: 'TalkBack / VoiceOver can stop the reply');

      tester.semantics.tap(find.semantics.byLabel(RegExp('^Context ')));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget, reason: 'the ring opens its details');
      handle.dispose();
    });

    testWidgets('text scale 2.0 on a 360-wide screen does not overflow', (tester) async {
      final tool = writeTool('save_note', title: 'Save a very important note');
      h = ChatHarness(
        tools: [tool],
        turns: [
          ScriptedTurn([
            const ReasoningDelta('Let me think about where to save this.'),
            const TextDelta('I will save it.'),
            const ToolCallStart(index: 0, id: 'c1', name: 'save_note'),
            ToolCallComplete(index: 0, call: call('c1', 'save_note', {'text': 'x' * 400})),
            const Finish(FinishReason.toolCalls),
          ]),
          ScriptedTurn.text('Saved.'),
        ],
      );
      await h.createSession();
      await h.seedExchange('An earlier question that is fairly long', 'An earlier answer.');
      await pumpChatScreen(tester, h, size: const Size(360, 740), textScale: 2);
      await tester.pumpAndSettle();
      await typeAndSend(tester, 'Save a note for me please');
      await stream(tester, frames: 10);
      await tester.pumpAndSettle();
      // Sheet open on compact: decide, then check the finished transcript.
      expect(find.text('Allow “Save a very important note”?'), findsOneWidget);
      await tester.tap(find.text('Allow once'));
      await stream(tester, frames: 10);
      await tester.pumpAndSettle();
      expect(find.text('Saved.'), findsOneWidget);
      // Overflow errors would have failed the test through FlutterError.
      expect(tester.takeException(), isNull);
    });

    testWidgets('reduced motion: no animation controllers left running when idle', (tester) async {
      h = ChatHarness(turns: [ScriptedTurn.text('Calm.')]);
      await h.createSession();
      await pumpChatScreen(tester, h, reducedMotion: true);
      await typeAndSend(tester, 'Hi');
      await stream(tester, frames: 10);
      await tester.pumpAndSettle(const Duration(milliseconds: 16), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 2));
      expect(find.text('Calm.'), findsOneWidget);
    });
  });
}
