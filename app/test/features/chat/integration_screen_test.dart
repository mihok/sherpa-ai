import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa/features/chat/prompt_arguments_sheet.dart';
import 'package:sherpa/features/chat/state/chat_dependencies.dart';
import 'package:sherpa/features/chat/widgets/source_chips.dart';
import 'package:sherpa/features/chat/widgets/user_message.dart';
import 'package:sherpa/features/mcp/session_tools_sheet.dart';
import 'package:sherpa/features/mcp/state/mcp_providers.dart';
import 'package:sherpa/services/inference/local_model_provider.dart';
import 'package:sherpa/services/mcp/mcp_runtime.dart';
import 'package:sherpa/state/services.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_core/testing.dart';
import 'package:sherpa_mcp/sherpa_mcp.dart' show McpPromptArgument;

import '../../services/mcp/support/mcp_fakes.dart' show fakeRuntime;
import 'support/harness.dart';
import 'support/mcp.dart';
import 'support/pump.dart';

Future<void> stream(WidgetTester tester, {int frames = 30}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<void> localSession(ChatHarness h) => h.store.putSession(SessionRecord(
      id: kSession,
      title: defaultSessionTitle,
      createdAt: h.clock.now(),
      updatedAt: h.clock.now(),
      providerId: localProviderId,
      modelId: 'scripted-model',
    ));

void main() {
  late ChatHarness h;
  tearDown(() => h.dispose());

  group('tools', () {
    late McpRuntime rt;

    Future<void> withRuntime(WidgetTester tester) async {
      await tester.runAsync(() async => rt = await fakeRuntime());
      addTearDown(() => tester.runAsync(rt.dispose));
    }

    testWidgets('the overflow menu opens the tools sheet; Manage servers goes to Tools & servers', (tester) async {
      await withRuntime(tester);
      h = ChatHarness(overrides: [mcpRuntimeProvider.overrideWithValue(rt)]);
      await h.createSession();
      final router = await pumpChatScreen(tester, h);
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tools'));
      await tester.pumpAndSettle();
      expect(find.byType(SessionToolsSheet), findsOneWidget);
      expect(find.text('Tools in this chat'), findsOneWidget);
      await tester.tap(find.text('Manage servers'));
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/settings/tools');
    });

    testWidgets('/tools in the composer opens the same sheet', (tester) async {
      await withRuntime(tester);
      h = ChatHarness(overrides: [
        mcpRuntimeProvider.overrideWithValue(rt),
        // The servers' prompts are not under test (listing them is real I/O).
        mcpPromptCommandsProvider.overrideWith((ref, sessionId) async => const []),
      ]);
      await h.createSession();
      await pumpChatScreen(tester, h);
      await tester.enterText(find.byType(TextField), '/to');
      await tester.pump();
      await tester.tap(find.text('/tools'));
      await tester.pumpAndSettle();
      expect(find.byType(SessionToolsSheet), findsOneWidget);
    });
  });

  group('slash commands from MCP prompts', () {
    final cmd = promptCommand(arguments: const [McpPromptArgument(name: 'topic', required: true)]);

    ChatHarness withPrompt(FakeMcpSources sources) => ChatHarness(
          turns: [ScriptedTurn.text('Here is the review.')],
          overrides: [
            chatMcpSourcesProvider.overrideWithValue(sources),
            mcpPromptCommandsProvider.overrideWith((ref, sessionId) async => [cmd]),
          ],
        );

    FakeMcpSources sources() => FakeMcpSources(prompts: {
          'srv:review': (args) => expandedPrompt(cmd, [(Role.user, 'Review this: ${args['topic']}')]),
        });

    testWidgets('the menu names the server; sending runs the prompt and labels its message', (tester) async {
      final s = sources();
      h = withPrompt(s);
      await h.createSession();
      await pumpChatScreen(tester, h);
      await tester.enterText(find.byType(TextField), '/');
      await tester.pumpAndSettle();
      expect(find.text('/srv:review'), findsOneWidget);
      expect(find.text('Reviews a text'), findsOneWidget);
      expect(find.text('from Example tools'), findsOneWidget, reason: 'server text is labelled as such');

      await tester.tap(find.text('/srv:review'));
      await tester.pump();
      expect(find.textContaining('takes topic (required)'), findsOneWidget, reason: 'the inline argument hint');
      await tester.enterText(find.byType(TextField), '/srv:review the tides');
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Send'));
      await stream(tester);
      await tester.pumpAndSettle();

      expect(s.expanded.single.$1, 'srv:review');
      expect(s.expanded.single.$2, {'topic': 'the tides'});
      expect(find.descendant(of: find.byType(UserBubble), matching: find.text('Review this: the tides')), findsOneWidget);
      expect(find.text('From Example tools · /srv:review · untrusted'), findsOneWidget);
      expect(find.text('Here is the review.'), findsOneWidget);
      final path = await h.activePath();
      expect(path.first.metadata[UntrustedData.messageMetadataKey], isTrue);
    });

    testWidgets('a missing required argument opens the argument form instead of failing', (tester) async {
      final s = sources();
      h = withPrompt(s);
      await h.createSession();
      await pumpChatScreen(tester, h);
      await tester.enterText(find.byType(TextField), '/srv:review');
      await tester.pumpAndSettle(); // the server's prompts are listed
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();
      expect(find.byType(PromptArgumentsSheet), findsOneWidget);
      expect(find.text('A prompt from Example tools. Its text is treated as untrusted content.'), findsOneWidget);
      expect(s.expanded, isEmpty);

      await tester.tap(find.widgetWithText(FilledButton, 'Send'));
      await tester.pump();
      expect(find.text('Required'), findsOneWidget);
      await tester.enterText(find.descendant(of: find.byType(PromptArgumentsSheet), matching: find.byType(TextField)), 'moons');
      await tester.tap(find.widgetWithText(FilledButton, 'Send'));
      await stream(tester);
      await tester.pumpAndSettle();
      expect(s.expanded.single.$2, {'topic': 'moons'});
      expect(find.descendant(of: find.byType(UserBubble), matching: find.text('Review this: moons')), findsOneWidget);
    });

    testWidgets('dismissing the form puts the command back', (tester) async {
      h = withPrompt(sources());
      await h.createSession();
      await pumpChatScreen(tester, h);
      await tester.enterText(find.byType(TextField), '/srv:review');
      await tester.pumpAndSettle(); // the server's prompts are listed
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(200, 40)); // the scrim
      await tester.pumpAndSettle();
      expect(find.byType(PromptArgumentsSheet), findsNothing);
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, startsWith('/srv:review'));
    });
  });

  group('@ mentions', () {
    testWidgets('typing @ suggests resources; a pick becomes a chip and is sent with the message', (tester) async {
      final s = FakeMcpSources(parts: {
        'today': const EmbeddedResourcePart(uri: 'notes://today.md', mimeType: 'text/markdown', text: 'Buy milk'),
      });
      final queries = <String>[];
      h = ChatHarness(
        turns: [ScriptedTurn.text('Milk, then.')],
        overrides: [
          chatMcpSourcesProvider.overrideWithValue(s),
          mcpResourceSuggestionsProvider.overrideWith((ref, q) async {
            queries.add(q.query);
            return [resource('today')];
          }),
        ],
      );
      await h.createSession();
      await pumpChatScreen(tester, h);
      await tester.enterText(find.byType(TextField), 'What is on @to');
      await tester.pumpAndSettle();
      expect(queries, contains('to'));
      expect(find.text('@srv:today'), findsOneWidget);
      expect(find.text('from Example tools'), findsOneWidget);
      await tester.tap(find.text('@srv:today'));
      await tester.pumpAndSettle();
      expect(find.byType(ResourceChip), findsOneWidget, reason: 'the pick is a chip');
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'What is on ');

      await tester.enterText(find.byType(TextField), 'What is on my list?');
      await tester.pump();
      await tester.tap(find.byTooltip('Send'));
      await stream(tester);
      await tester.pumpAndSettle();
      expect(s.resolved, ['srv:today']);
      expect(find.text('Milk, then.'), findsOneWidget);
      // In the transcript: a compact chip naming the server.
      final chip = tester.widget<ResourceChip>(find.byType(ResourceChip));
      expect(chip.label, 'today');
      expect(chip.serverName, 'Example tools');
      expect(find.bySemanticsLabel('Resource today, from Example tools'), findsOneWidget);
      final user = (await h.activePath()).first;
      expect(user.content.whereType<EmbeddedResourcePart>(), hasLength(1));
    });
  });

  group('on-device models in the chat', () {
    testWidgets('a local reply shows its speed quietly, with a spoken label', (tester) async {
      final handle = tester.ensureSemantics();
      final local = ScriptedProvider([
        ScriptedTurn([
          const TextDelta('Tides follow the moon.'),
          const PerfSample(timeToFirstTokenMs: 420, decodeTokensPerSec: 42.3, prefillTokensPerSec: 310),
          const Finish(FinishReason.stop),
        ]),
      ], info: kLocalInfo);
      h = ChatHarness(provider: local, configs: const [], providers: {localProviderId: local});
      await localSession(h);
      await pumpChatScreen(tester, h);
      await tester.enterText(find.byType(TextField), 'Why tides?');
      await tester.pump();
      await tester.tap(find.byTooltip('Send'));
      await stream(tester);
      await tester.pumpAndSettle();
      expect(find.text('42 tok/s · TTFT 0.4 s'), findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp('Generated at 42 tokens per second, first token after 0.4 seconds')),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('a remote reply without timing has no speed line', (tester) async {
      h = ChatHarness(turns: [ScriptedTurn.text('Hello.')]);
      await h.createSession();
      await pumpChatScreen(tester, h);
      await tester.enterText(find.byType(TextField), 'Hi');
      await tester.pump();
      await tester.tap(find.byTooltip('Send'));
      await stream(tester);
      await tester.pumpAndSettle();
      expect(find.byType(ReplyPerfFooter), findsNothing);
    });

    testWidgets('an unavailable engine says so and opens the model library', (tester) async {
      final local = ScriptedProvider([
        ScriptedTurn.error(const ProviderException(
          ProviderErrorKind.unsupported,
          'On-device inference is unavailable: this build has no engine library',
          providerId: localProviderId,
        )),
      ], info: kLocalInfo);
      h = ChatHarness(provider: local, configs: const [], providers: {localProviderId: local});
      await localSession(h);
      final router = await pumpChatScreen(tester, h);
      await tester.enterText(find.byType(TextField), 'Hi');
      await tester.pump();
      await tester.tap(find.byTooltip('Send'));
      await stream(tester);
      await tester.pumpAndSettle();
      expect(find.text('On-device models are unavailable: this build has no engine library'), findsOneWidget);
      expect(find.textContaining('On this device rejected'), findsNothing);
      await tester.tap(find.text('Open model library'));
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/settings/models');
    });

    testWidgets('no provider but a model on this phone: the chat offers it', (tester) async {
      final local = ScriptedProvider(const [], info: kLocalInfo);
      h = ChatHarness(configured: false, providers: {localProviderId: local});
      await h.createSession(withModel: false);
      await pumpChatScreen(tester, h);
      await tester.pumpAndSettle();
      expect(find.text('Choose a model'), findsOneWidget);
      expect(find.textContaining('A model on this phone is ready to use'), findsOneWidget);
      expect(find.text('Add a model to start chatting'), findsNothing);
      expect(find.widgetWithText(TextButton, 'Add provider'), findsOneWidget);
    });

    testWidgets('the engine crash report shows as a warning on the next local reply', (tester) async {
      final local = ScriptedProvider([
        ScriptedTurn([
          const ProviderNotice(kEngineCrashNoticeCode, 'The on-device engine crashed while generating a reply with Qwen3.'),
          const TextDelta('Back again.'),
          const Finish(FinishReason.stop),
        ]),
      ], info: kLocalInfo);
      h = ChatHarness(provider: local, configs: const [], providers: {localProviderId: local});
      await localSession(h);
      await pumpChatScreen(tester, h);
      await tester.enterText(find.byType(TextField), 'Hi');
      await tester.pump();
      await tester.tap(find.byTooltip('Send'));
      await stream(tester);
      await tester.pumpAndSettle();
      expect(find.textContaining('The on-device model stopped unexpectedly last time.'), findsOneWidget);
      expect(find.text('Back again.'), findsOneWidget);
    });
  });
}
