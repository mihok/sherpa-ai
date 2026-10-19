import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa/design/theme.dart';
import 'package:sherpa/features/chat/attachments/attachment_store.dart';
import 'package:sherpa/features/chat/attachments/composer_attachments.dart';
import 'package:sherpa/features/chat/attachments/image_prep.dart';
import 'package:sherpa/features/chat/links/reply_links.dart';
import 'package:sherpa/features/chat/model_picker_sheet.dart';
import 'package:sherpa/features/chat/prompt_arguments_sheet.dart';
import 'package:sherpa/features/chat/state/chat_controller.dart';
import 'package:sherpa/features/chat/state/chat_dependencies.dart';
import 'package:sherpa/features/chat/widgets/approval_card.dart';
import 'package:sherpa/features/chat/widgets/attachment_views.dart';
import 'package:sherpa/features/chat/widgets/composer.dart';
import 'package:sherpa/features/chat/widgets/context_ring.dart';
import 'package:sherpa/features/mcp/state/mcp_providers.dart';
import 'package:sherpa/features/models/state/local_inference_providers.dart';
import 'package:sherpa/features/models/state/local_model_fit.dart';
import 'package:sherpa/features/models/state/models_providers.dart';
import 'package:sherpa/services/device/device_profile_source.dart';
import 'package:sherpa/services/inference/local_provider_registry.dart';
import 'package:sherpa/state/providers.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_core/testing.dart';
import 'package:sherpa_mcp/sherpa_mcp.dart' show McpPromptArgument;

import '../features/chat/support/app_chat.dart';
import '../features/chat/support/fakes.dart';
import '../features/chat/support/harness.dart';
import '../features/chat/support/mcp.dart';
import '../services/inference/support/local_rig.dart';
import '../support/a11y_audit.dart';
import 'support/chat_rig.dart';

/// M6 audit of the chat: a new chat, a reply streaming, tool cards, an
/// approval (a sheet on phones, docked on tablets), an MCP App view,
/// attachments, the composer's command and mention menus, notices and
/// errors, and every sheet the chat opens (see [auditScreen]).
// Where textContrastGuideline is skipped (the exact check still runs; see
// auditScreen), and what it misread there.
const _small = '12 px text at 1×: an anti-aliasing shade is the most frequent "dark" pixel';
const _tinted = '12 px text in a tinted box at 1×: the tint and its border outnumber the glyphs';
const _digits = '14 px digits at 1× ("111 tokens"): thin glyphs, so anti-aliasing shades outnumber the text colour';
const _oneX = {AuditView.phone1x, AuditView.tablet1x};

void main() {
  /// The tools the seeded conversations call, with their display names.
  List<LocalTool> tools() => [
        FakeTool('weather', title: 'Weather'),
        FakeTool('calendar', title: 'Calendar'),
        FakeTool('notes', title: 'Notes'),
        FakeTool('maps', title: 'Maps'),
        writeTool('save_note', title: 'Save note'),
      ];

  ChatHarness harness({List<ScriptedTurn> turns = const [], ModelProvider? provider, List<Override> overrides = const []}) {
    final h = ChatHarness(turns: turns, provider: provider, tools: tools(), overrides: overrides);
    addTearDown(h.dispose);
    return h;
  }

  Future<void> settle(WidgetTester tester) async {
    await streamFrames(tester, frames: 20);
    await tester.pumpAndSettle();
  }

  auditScreen('chat: new', (tester, view) async {
    final h = harness();
    await h.createSession();
    await pumpChatFor(tester, h, view);
    await settle(tester);
  });

  auditScreen('chat: no model set up', (tester, view) async {
    final h = ChatHarness(configured: false);
    addTearDown(h.dispose);
    await h.createSession(withModel: false);
    await pumpChatFor(tester, h, view);
    await settle(tester);
  });

  auditScreen('chat: a reply streaming', (tester, view) async {
    final p = ManualProvider(info: kCloudInfo);
    final h = harness(provider: p);
    await h.createSession();
    await h.seedExchange('Hi! Can you help me plan a trip?', 'Of course. Where are you headed?');
    await pumpChatFor(tester, h, view);
    await settle(tester);
    await typeAndSend(tester, 'Three days in Lisbon in May');
    p.emit(const TextDelta('Lisbon in May is lovely: warm days, few crowds. '));
    p.emit(const TextDelta('Here is a plan:\n\n1. **Day one**: Alfama and the castle'));
    // Mid-reply (the provider sends nothing more), once Send has turned
    // into Stop.
    await streamFrames(tester, frames: 20);
    expect(find.byTooltip('Stop (Esc)'), findsOneWidget);
  }, cleanup: (tester) async {
    final p = ProviderScope.containerOf(tester.element(find.byType(Scaffold).first)).read(chatControllerProvider(kSession).notifier);
    p.stop();
    await streamFrames(tester, frames: 10);
  });

  auditScreen('chat: tool cards', (tester, view) async {
    final h = harness();
    await h.createSession();
    await seedToolConversation(h);
    await pumpChatFor(tester, h, view);
    await settle(tester);
    // One card and the group of three, opened.
    await tester.tap(find.text('Weather'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ran 3 tools'));
    await tester.pumpAndSettle();
    // From the top: the audit scrolls down through all of it.
    final list = tester.state<ScrollableState>(find.byType(Scrollable).first);
    list.position.jumpTo(list.position.minScrollExtent);
    await tester.pumpAndSettle();
  });

  auditScreen('chat: an approval', (tester, view) async {
    final h = harness(turns: [
      ScriptedTurn.toolCalls([
        const ToolCall(
          id: 'n1',
          name: 'save_note',
          arguments: {'title': 'Lisbon', 'text': 'Light rain after 3 pm. Take a jacket.'},
        ),
      ]),
    ]);
    await h.createSession();
    await pumpChatFor(tester, h, view);
    await settle(tester);
    await typeAndSend(tester, 'Save that to my notes');
    await settle(tester);
    expect(find.text('Allow “Save note”?'), findsOneWidget);
  }, pixelContrastSkip: _oneX, contrastNote: _tinted, cleanup: (tester) async {
    final c = ProviderScope.containerOf(tester.element(find.byType(Scaffold).first));
    c.read(chatControllerProvider(kSession).notifier).stop();
    await settle(tester);
  });

  // On a phone, after the sheet was swiped away: the reminder above the
  // composer (tablets keep the card docked instead).
  auditScreen('chat: an approval waiting', (tester, view) async {
    final h = harness(turns: [
      ScriptedTurn.toolCalls([const ToolCall(id: 'n1', name: 'save_note', arguments: {'title': 'Lisbon'})]),
    ]);
    await h.createSession();
    await pumpChatFor(tester, h, view);
    await settle(tester);
    await typeAndSend(tester, 'Save that to my notes');
    await settle(tester);
    Navigator.of(tester.element(find.byType(ApprovalSheet))).pop();
    await tester.pumpAndSettle();
    expect(find.text('Approval needed: Save note'), findsOneWidget);
  }, views: const [AuditView.phone1x, AuditView.phone2x, AuditView.phoneDark], cleanup: (tester) async {
    final c = ProviderScope.containerOf(tester.element(find.byType(Scaffold).first));
    c.read(chatControllerProvider(kSession).notifier).stop();
    await settle(tester);
  });

  auditScreen('chat: an MCP App view', (tester, view) async {
    final a = await AppChat.create(tester);
    await a.seedWeather();
    await pumpChatFor(tester, a.h, view);
    await a.settle(tester);
    await a.handshake(tester);
  }, cleanup: (tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });

  // ---- attachments ------------------------------------------------------

  auditScreen('chat: attachments', (tester, view) async {
    final dir = Directory.systemTemp.createTempSync('sherpa_a11y_attachments_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final picker = _Picker();
    final h = harness(
      provider: ScriptedProvider(
        [ScriptedTurn.text('Got it: a beach, and your plan.')],
        info: kCloudInfo,
        capabilitiesValue: const ModelCapabilities(contextLength: 32768, vision: true),
      ),
      overrides: [
        chatAttachmentStoreProvider.overrideWithValue(ChatAttachmentStore(root: () async => dir)),
        chatAttachmentPickerProvider.overrideWithValue(picker),
        chatImagePreparerProvider.overrideWithValue(_prepare),
      ],
    );
    await h.createSession();
    await pumpChatFor(tester, h, view);
    await _io(tester);
    Future<void> attach(AttachSource from) async {
      await tester.tap(find.byKey(const ValueKey('composer-attach')));
      await tester.pumpAndSettle();
      final option = find.byKey(ValueKey('attach-${from.name}'));
      await tester.ensureVisible(option);
      await tester.pumpAndSettle();
      await tester.tap(option);
      await _io(tester);
    }

    // Sent: a thumbnail and a file chip under the bubble.
    picker.photo = PickedAttachment(name: 'beach.jpg', size: _photo.length, bytes: _photo);
    await attach(AttachSource.photos);
    picker.file = PickedAttachment(name: 'plan.md', size: _plan.length, bytes: _plan);
    await attach(AttachSource.files);
    await tester.enterText(find.byType(TextField), 'What do you see?');
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    await _io(tester, rounds: 20);
    // Waiting in the composer: a photo and a file.
    await attach(AttachSource.photos);
    await attach(AttachSource.files);
    expect(find.byTooltip('Remove beach.jpg'), findsOneWidget);
  });

  auditScreen('attach sheet', (tester, view) async {
    final h = harness(
      provider: ScriptedProvider(const [], info: kCloudInfo, capabilitiesValue: const ModelCapabilities(contextLength: 32768)),
    );
    await h.createSession();
    await pumpChatFor(tester, h, view);
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('composer-attach')));
    await tester.pumpAndSettle();
    expect(find.byType(AttachSheet), findsOneWidget);
  }, pixelContrastSkip: _oneX, contrastNote: _small);

  // ---- the composer's menus --------------------------------------------

  final review = promptCommand(arguments: const [McpPromptArgument(name: 'topic', required: true, description: 'What to review')]);

  auditScreen('composer: the command menu', (tester, view) async {
    final h = harness(overrides: [mcpPromptCommandsProvider.overrideWith((ref, sessionId) async => [review])]);
    await h.createSession();
    await pumpChatFor(tester, h, view);
    await settle(tester);
    await tester.enterText(find.byType(TextField), '/');
    await tester.pumpAndSettle();
    expect(find.text('/srv:review'), findsOneWidget);
  });

  auditScreen('composer: mention suggestions', (tester, view) async {
    final h = harness(overrides: [
      chatMcpSourcesProvider.overrideWithValue(FakeMcpSources()),
      mcpResourceSuggestionsProvider.overrideWith((ref, q) async => [resource('today'), resource('ideas', uri: 'notes://ideas.md')]),
    ]);
    await h.createSession();
    await pumpChatFor(tester, h, view);
    await settle(tester);
    await tester.enterText(find.byType(TextField), 'What is on @');
    await tester.pumpAndSettle();
    await tester.tap(find.text('@srv:today'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'What is on @i');
    await tester.pumpAndSettle();
    expect(find.text('@srv:ideas'), findsOneWidget);
  });

  auditScreen('composer: a prompt with an argument', (tester, view) async {
    final h = harness(overrides: [mcpPromptCommandsProvider.overrideWith((ref, sessionId) async => [review])]);
    await h.createSession();
    await pumpChatFor(tester, h, view);
    await settle(tester);
    await tester.enterText(find.byType(TextField), '/srv:review ');
    await tester.pumpAndSettle();
    expect(find.textContaining('takes topic (required)'), findsOneWidget);
  });

  auditScreen('prompt arguments sheet', (tester, view) async {
    final h = harness(overrides: [
      chatMcpSourcesProvider.overrideWithValue(FakeMcpSources()),
      mcpPromptCommandsProvider.overrideWith((ref, sessionId) async => [review]),
    ]);
    await h.createSession();
    await pumpChatFor(tester, h, view);
    await settle(tester);
    await tester.enterText(find.byType(TextField), '/srv:review');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();
    expect(find.byType(PromptArgumentsSheet), findsOneWidget);
  });

  // ---- notices and errors ------------------------------------------------

  auditScreen('chat: notices', (tester, view) async {
    final h = harness(turns: [
      ScriptedTurn([
        const ToolCallStart(index: 0, id: 'c1', name: 'save_note'),
        ToolCallComplete(
          index: 0,
          call: const ToolCall(id: 'c1', name: 'save_note', arguments: {}, argumentsError: 'truncated'),
        ),
        const Finish(FinishReason.length),
      ]),
    ]);
    await h.createSession();
    await pumpChatFor(tester, h, view);
    await settle(tester);
    await typeAndSend(tester, 'Save a long note');
    await settle(tester);
    expect(find.textContaining("didn't run that call"), findsOneWidget);
  });

  auditScreen('chat: stopped', (tester, view) async {
    final p = ManualProvider(info: kCloudInfo);
    final h = harness(provider: p);
    await h.createSession();
    await pumpChatFor(tester, h, view);
    await settle(tester);
    await typeAndSend(tester, 'Tell me a long story');
    p.emit(const TextDelta('Once upon a time, '));
    await streamFrames(tester, frames: 5);
    await tester.tap(find.byTooltip('Stop (Esc)'));
    await settle(tester);
  }, pixelContrastSkip: _oneX, contrastNote: _small);

  auditScreen('chat: an error', (tester, view) async {
    final h = harness(turns: [
      ScriptedTurn.error(const ProviderException(ProviderErrorKind.auth, 'invalid x-api-key', statusCode: 401)),
    ]);
    await h.createSession();
    await pumpChatFor(tester, h, view);
    await settle(tester);
    await typeAndSend(tester, 'Hello');
    await settle(tester);
    await tester.tap(find.text('Details'));
    await tester.pumpAndSettle();
  });

  auditScreen('chat: interrupted', (tester, view) async {
    final h = harness(turns: [ScriptedTurn.text('Resumed reply.')]);
    await h.createSession();
    final (user, _) = await h.seedExchange('What changed this week?', 'Three things.');
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
    await pumpChatFor(tester, h, view);
    await settle(tester);
    expect(find.text('Resume'), findsOneWidget);
  });

  // ---- sheets --------------------------------------------------------------

  auditScreen('model picker', (tester, view) async {
    final h = harness();
    await h.createSession();
    await pumpChatFor(tester, h, view);
    await settle(tester);
    await tester.tap(find.bySemanticsLabel(RegExp('^Model: ')));
    await tester.pumpAndSettle();
    expect(find.byType(ModelPickerSheet), findsOneWidget);
  });

  auditScreen('model picker, with models on this device', (tester, view) async {
    late LocalRig rig;
    await tester.runAsync(() async {
      rig = await LocalRig.create();
      await rig.add(libraryModel('small', name: 'Small model', sizeBytes: 807694464, installedAt: DateTime.utc(2026, 10, 2)));
      await rig.add(libraryModel('huge', name: 'Huge model', sizeBytes: 9 * gib));
      await rig.local.start();
    });
    addTearDown(() => tester.runAsync(rig.dispose));
    final inner = FakeProviderRegistry(configs: [kCloudConfig], providers: {kProviderId: StubRemoteProvider(kCloudConfig)});
    setAuditWindow(tester, view);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        providerRegistryProvider.overrideWithValue(LocalProviderRegistry(inner, rig.local)),
        localInferenceProvider.overrideWithValue(rig.local),
        modelLibraryProvider.overrideWithValue(rig.library),
        modelStorageLayoutProvider.overrideWithValue(rig.layout),
        deviceProfileSourceProvider.overrideWithValue(FixedDeviceProfileSource(phone12gb)),
        localModelShapeProvider.overrideWith((ref, path) async => llama1bLikeShape),
      ],
      child: MaterialApp(
        theme: SherpaTheme.light(),
        darkTheme: SherpaTheme.dark(),
        themeMode: view.themeMode,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => unawaited(ModelPickerSheet.show(context)),
                child: const Text('Pick'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Pick'));
    await tester.pumpAndSettle();
    expect(find.text('On this device'), findsOneWidget);
  });

  auditScreen('context ring sheet', (tester, view) async {
    final h = harness();
    await h.createSession();
    await h.seedExchange('Hi', 'Hello! What can I do for you today?');
    await pumpChatFor(tester, h, view);
    await settle(tester);
    await tester.tap(find.bySemanticsLabel(RegExp('^Context ')));
    await tester.pumpAndSettle();
    expect(find.byType(ContextBudgetSheet), findsOneWidget);
  }, pixelContrastSkip: _oneX, contrastNote: _digits);

  auditScreen('link confirm sheet', (tester, view) async {
    final h = harness();
    await h.createSession();
    await h.seedExchange('Where can I read about it?', 'See [the guide](https://xn--exmple-cua.com/lisbon?utm=1).');
    await pumpChatFor(tester, h, view);
    await settle(tester);
    unawaited(ReplyLinkSheet.show(
      tester.element(find.byType(ChatComposer)),
      uri: Uri.parse('https://xn--exmple-cua.com/lisbon?utm=1'),
      kind: ReplyLinkKind.web,
    ));
    await tester.pumpAndSettle();
    expect(find.byType(ReplyLinkSheet), findsOneWidget);
  }, pixelContrastSkip: {AuditView.tablet1x}, contrastNote: _small);
}

/// A photo with EXIF (300×400 after orientation), from the chat tests.
final Uint8List _photo = File('test/features/chat/fixtures/gps_rotated.jpg').readAsBytesSync();
final Uint8List _plan = Uint8List.fromList(utf8.encode('# Plan\n\n- Alfama\n- Belém'));

Future<PreparedImage> _prepare(Uint8List input, {required int maxLongEdge}) async =>
    prepareImage(input, maxLongEdge: maxLongEdge);

final class _Picker implements ChatAttachmentPicker {
  PickedAttachment? photo;
  PickedAttachment? file;

  @override
  Future<PickedAttachment?> pickPhoto() async => photo;

  @override
  Future<PickedAttachment?> takePhoto() async => photo;

  @override
  Future<PickedAttachment?> pickFile({required int maxBytes}) async => file;
}

/// Real time for the attachment store's file IO, fake time for the UI: at
/// least [rounds] rounds, then until no photo is being prepared (its chip
/// spins) and no reply is running. A busy CPU makes the IO slow.
Future<void> _io(WidgetTester tester, {int rounds = 12}) async {
  final c = ProviderScope.containerOf(tester.element(find.byType(Scaffold).first));
  for (var i = 0; i < 400; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump(const Duration(milliseconds: 16));
    final busy = find.byType(CircularProgressIndicator).evaluate().isNotEmpty ||
        c.read(chatControllerProvider(kSession)).isRunActive;
    if (i >= rounds && !busy) break;
  }
  await tester.pumpAndSettle();
}
