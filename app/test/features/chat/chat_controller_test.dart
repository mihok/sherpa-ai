import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa/features/chat/state/chat_controller.dart';
import 'package:sherpa/features/chat/state/chat_dependencies.dart';
import 'package:sherpa/features/chat/state/chat_errors.dart';
import 'package:sherpa/features/chat/state/chat_view_state.dart';
import 'package:sherpa/features/chat/state/model_selection.dart';
import 'package:sherpa/features/chat/state/transcript_model.dart';
import 'package:sherpa/state/services.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_core/testing.dart';
import 'package:sherpa_providers/sherpa_providers.dart';

import 'support/fakes.dart';
import 'support/harness.dart';

AssistantTurnItem lastTurn(ChatViewState s) => s.items.whereType<AssistantTurnItem>().last;

UserItem lastUser(ChatViewState s) => s.items.whereType<UserItem>().last;

String turnText(ChatViewState s) => lastTurn(s).copyText;

ToolCall call(String id, String name, [Map<String, Object?> args = const {}]) =>
    ToolCall(id: id, name: name, arguments: args);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ChatHarness h;
  tearDown(() => h.dispose());

  group('loading', () {
    test('resolves the model and its privacy badge', () async {
      h = ChatHarness();
      await h.createSession();
      await h.open();
      final s = h.state;
      expect(s.loading, isFalse);
      expect(s.availability, ProviderAvailability.ready);
      expect(s.model!.modelName, 'Scripted model');
      expect(s.model!.leavesDevice, isTrue);
      expect(s.model!.privacy.shortLabel, '→ api.example.com');
      expect(s.budget, isNotNull, reason: 'estimated before the first run');
      expect(s.budgetIsEstimate, isTrue);
    });

    test('no provider configured is a setup state, not a crash', () async {
      h = ChatHarness(configured: false);
      await h.createSession(withModel: false);
      final c = await h.open();
      expect(h.state.availability, ProviderAvailability.noProviders);
      await c.send('hello');
      expect(h.state.error!.kind, ChatErrorKind.noProvider);
      expect(h.state.error!.actions, contains(ChatErrorAction.addProvider));
      expect(h.state.items, isEmpty);
    });

    test('falls back to the default model and persists it on first send', () async {
      h = ChatHarness(turns: [ScriptedTurn.text('Hi!')]);
      await h.createSession(withModel: false);
      h.prefs.defaultModel = const ModelChoice(providerId: kProviderId, modelId: kModelId);
      final c = await h.open();
      expect(h.state.availability, ProviderAvailability.ready);
      await c.send('hello');
      final session = await h.store.getSession(kSession);
      expect(session!.providerId, kProviderId);
      expect(session.modelId, kModelId);
    });

    test('a missing session maps to an actionable error', () async {
      h = ChatHarness();
      await h.open('nope');
      final s = h.container.read(chatControllerProvider('nope'));
      expect(s.error!.kind, ChatErrorKind.sessionMissing);
      expect(s.error!.actions, [ChatErrorAction.newChat]);
    });
  });

  group('streaming', () {
    test('send streams a reply and ends idle', () async {
      h = ChatHarness(turns: [ScriptedTurn.text('Hello there, traveller.')]);
      await h.createSession();
      final c = await h.open();
      await c.send('  Hi  ');
      final s = h.state;
      expect(s.status, ChatRunStatus.idle);
      expect(s.lastOutcome, RunOutcome.completed);
      expect(s.draft, isNull);
      expect(s.pendingUserText, isNull);
      expect(lastUser(s).text, 'Hi');
      expect(turnText(s), 'Hello there, traveller.');
      expect(s.title, 'Hi', reason: 'the runner titles new chats from the first message');
      expect(s.budgetIsEstimate, isFalse);
      expect(h.platform.haptics, containsAllInOrder([ChatHaptic.send, ChatHaptic.runComplete]));
    });

    test('shows the user message immediately and the live draft while streaming', () async {
      final p = ManualProvider();
      h = ChatHarness(provider: p);
      await h.createSession();
      final c = await h.open();
      final done = c.send('Explain tides');
      expect(h.state.pendingUserText, 'Explain tides', reason: 'optimistic, before persistence');
      expect(h.state.status, ChatRunStatus.streaming);
      expect(h.state.items.last, isA<AssistantTurnItem>().having((t) => t.live, 'live', isTrue));
      await p.started;
      p.emitAll(const [TextDelta('The moon '), TextDelta('pulls.')]);
      await h.settle();
      expect(h.state.draft!.text, 'The moon pulls.');
      expect(h.state.pendingUserText, isNull, reason: 'replaced by the persisted message');
      expect(lastUser(h.state).text, 'Explain tides');
      await p.finish();
      await done;
      expect(turnText(h.state), 'The moon pulls.');
      expect(h.state.draft, isNull);
    });

    test('coalesces deltas: at most one state emission per frame', () async {
      final frames = ManualFrameScheduler();
      final p = ManualProvider();
      h = ChatHarness(provider: p, frames: frames);
      await h.createSession();
      final c = await h.open();
      final done = c.send('Count');
      await p.started;
      await h.settle();
      final before = h.emissions.length;
      for (var i = 0; i < 100; i++) {
        p.emit(TextDelta('$i '));
      }
      await h.settle();
      expect(h.emissions.length, before, reason: 'no frame yet, so nothing published');
      expect(frames.pendingCount, 1, reason: 'one frame callback for 100 deltas');
      frames.tick();
      expect(h.emissions.length, before + 1);
      expect(h.state.draft!.text, startsWith('0 1 2 '));
      expect(h.state.draft!.text, endsWith('99 '));
      frames.tick();
      expect(h.emissions.length, before + 1, reason: 'nothing new, no emission');
      await p.finish();
      await done;
    });

    test('records how long the model thought', () async {
      final p = ManualProvider();
      h = ChatHarness(provider: p);
      await h.createSession();
      final c = await h.open();
      final done = c.send('Think');
      await p.started;
      p.emit(const ReasoningDelta('Considering…'));
      await h.settle();
      expect(h.state.draft!.isThinking, isTrue);
      h.clock.advance(const Duration(seconds: 12));
      p.emit(const TextDelta('Done.'));
      await h.settle();
      expect(h.state.draft!.reasoningDuration, const Duration(seconds: 12));
      await p.finish();
      await done;
      final reasoning = lastTurn(h.state).blocks.whereType<ReasoningBlock>().single;
      expect(reasoning.duration, const Duration(seconds: 12));
      await h.settle();
      final persisted = (await h.activePath()).last;
      expect(persisted.metadata['reasoningMs'], 12000, reason: 'survives reopening the chat');
    });
  });

  group('tools and approvals', () {
    test('a tool needing approval waits for the user, then runs', () async {
      final tool = writeTool('save_note', title: 'Save note');
      h = ChatHarness(
        tools: [tool],
        turns: [
          ScriptedTurn.toolCalls([call('c1', 'save_note', {'text': 'milk'})]),
          ScriptedTurn.text('Saved.'),
        ],
      );
      await h.createSession();
      final c = await h.open();
      final done = c.send('Remember milk');
      await h.until(() => h.state.pendingApproval != null);
      final p = h.state.pendingApproval!;
      expect(h.state.status, ChatRunStatus.awaitingApproval);
      expect(p.toolDisplayName, 'Save note');
      expect(p.risk, RiskLevel.moderate);
      expect(p.allowsAlways, isTrue);
      expect(h.state.tools['c1']!.status, ToolRunStatus.awaitingApproval);
      expect(h.platform.haptics, contains(ChatHaptic.approvalRequested));
      expect(tool.calls, isEmpty);

      c.respondToApproval(const ApprovalResponse(UserDecision.approve));
      expect(h.state.pendingApproval, isNull);
      await done;
      expect(tool.calls.single, {'text': 'milk'});
      expect(h.state.tools['c1']!.status, ToolRunStatus.succeeded);
      expect(h.state.tools['c1']!.resultText, 'save_note ok');
      expect(turnText(h.state), 'Saved.');
      final group = lastTurn(h.state).blocks.whereType<ToolGroupBlock>().single;
      expect(group.calls.single.id, 'c1');
    });

    test('deny keeps the tool from running and records it as denied', () async {
      final tool = writeTool('save_note');
      h = ChatHarness(
        tools: [tool],
        turns: [
          ScriptedTurn.toolCalls([call('c1', 'save_note')]),
          ScriptedTurn.text('OK, not saving.'),
        ],
      );
      await h.createSession();
      final c = await h.open();
      final done = c.send('Remember milk');
      await h.until(() => h.state.pendingApproval != null);
      c.respondToApproval(const ApprovalResponse(UserDecision.deny));
      await done;
      expect(tool.calls, isEmpty);
      expect(h.state.tools['c1']!.status, ToolRunStatus.denied);
      expect(turnText(h.state), 'OK, not saving.');
    });

    test('"allow for this chat" is remembered for the next call', () async {
      final tool = writeTool('save_note');
      h = ChatHarness(
        tools: [tool],
        turns: [
          ScriptedTurn.toolCalls([call('c1', 'save_note')]),
          ScriptedTurn.toolCalls([call('c2', 'save_note')]),
          ScriptedTurn.text('Both saved.'),
        ],
      );
      await h.createSession();
      final c = await h.open();
      final done = c.send('Save twice');
      await h.until(() => h.state.pendingApproval != null);
      c.respondToApproval(const ApprovalResponse(UserDecision.approve, scope: ApprovalScope.session));
      await done;
      expect(tool.calls, hasLength(2));
      final group = lastTurn(h.state).blocks.whereType<ToolGroupBlock>().single;
      expect(group.calls.map((c) => c.id), ['c1', 'c2'], reason: 'consecutive calls group across steps');
    });

    test('destructive tools never offer "always allow"', () async {
      h = ChatHarness(
        tools: [destructiveTool('delete_file')],
        turns: [ScriptedTurn.toolCalls([call('c1', 'delete_file', {'path': '/a'})])],
      );
      await h.createSession();
      final c = await h.open();
      final done = c.send('Delete it');
      await h.until(() => h.state.pendingApproval != null);
      expect(h.state.pendingApproval!.risk, RiskLevel.destructive);
      expect(h.state.pendingApproval!.allowsAlways, isFalse);
      c.stop();
      await done;
    });

    test('stop while an approval is open denies it and cancels the run', () async {
      final tool = writeTool('save_note');
      h = ChatHarness(tools: [tool], turns: [ScriptedTurn.toolCalls([call('c1', 'save_note')])]);
      await h.createSession();
      final c = await h.open();
      final done = c.send('Save');
      await h.until(() => h.state.pendingApproval != null);
      c.stop();
      await done;
      expect(tool.calls, isEmpty);
      expect(h.state.pendingApproval, isNull);
      expect(h.state.status, ChatRunStatus.cancelled);
      expect(h.state.notices.map((n) => n.code), contains('stopped'));
      // Pairing invariant: the call was answered.
      final path = await h.activePath();
      expect(path.last.role, Role.tool);
      expect(h.state.tools['c1']!.status, isNot(ToolRunStatus.succeeded));
    });

    test('tool progress updates the live execution view', () async {
      final gate = Completer<void>();
      final tool = FakeTool('index', onRun: (args, ctx) async {
        ctx.onProgress?.call(const ToolProgress(progress: 1, total: 4, message: 'Indexing'));
        await gate.future;
        return ToolResult.text('indexed');
      });
      h = ChatHarness(
        tools: [tool],
        turns: [ScriptedTurn.toolCalls([call('c1', 'index')]), ScriptedTurn.text('Done')],
      );
      await h.createSession();
      final c = await h.open();
      final done = c.send('Index');
      await h.until(() => h.state.tools['c1']?.progress != null);
      expect(h.state.status, ChatRunStatus.runningTools);
      expect(h.state.tools['c1']!.status, ToolRunStatus.running);
      expect(h.state.tools['c1']!.progress, 0.25);
      expect(h.state.runningToolName, 'index');
      gate.complete();
      await done;
      expect(h.state.tools['c1']!.status, ToolRunStatus.succeeded);
    });
  });

  group('stop', () {
    test('stop mid-stream keeps the partial reply and says so', () async {
      final p = ManualProvider();
      h = ChatHarness(provider: p);
      await h.createSession();
      final c = await h.open();
      final done = c.send('Write a poem');
      await p.started;
      p.emit(const TextDelta('Roses are'));
      await h.settle();
      expect(h.state.isRunActive, isTrue);
      c.stop();
      await done;
      expect(h.state.status, ChatRunStatus.cancelled);
      expect(h.state.isRunActive, isFalse);
      expect(turnText(h.state), 'Roses are');
      expect(h.state.notices.single.code, 'stopped');
      expect(p.cancelled, isTrue);
    });
  });

  group('stop before start', () {
    test('Stop right after Send cancels before the run starts', () async {
      h = ChatHarness(turns: [ScriptedTurn.text('never')]);
      await h.createSession();
      final c = await h.open();
      final done = c.send('Oops');
      expect(h.state.isRunActive, isTrue, reason: 'optimistic run state is immediate');
      c.stop();
      await done;
      expect(h.state.isRunActive, isFalse);
      expect(h.state.items, isEmpty);
      expect(h.state.pendingUserText, isNull);
      expect(h.scripted.requests, isEmpty, reason: 'nothing was sent to the model');
      expect(await h.activePath(), isEmpty);
    });
  });

  group('branches', () {
    test('retry creates a sibling and the switcher shows 2/2', () async {
      h = ChatHarness(turns: [ScriptedTurn.text('First answer'), ScriptedTurn.text('Second answer')]);
      await h.createSession();
      final c = await h.open();
      await c.send('Question');
      final firstId = lastTurn(h.state).firstMessageId!;
      h.clock.advance(const Duration(seconds: 5));
      await c.retry(firstId);
      final turn = lastTurn(h.state);
      expect(turn.copyText, 'Second answer');
      expect(turn.branch!.index, 1);
      expect(turn.branch!.count, 2);
      expect(h.state.items.whereType<UserItem>(), hasLength(1));
    });

    test('switchBranch moves between retries and back', () async {
      h = ChatHarness(turns: [ScriptedTurn.text('First answer'), ScriptedTurn.text('Second answer')]);
      await h.createSession();
      final c = await h.open();
      await c.send('Question');
      h.clock.advance(const Duration(seconds: 5));
      await c.retry(lastTurn(h.state).firstMessageId!);
      await c.switchBranch(lastTurn(h.state).firstMessageId!, BranchDirection.previous);
      expect(turnText(h.state), 'First answer');
      expect(lastTurn(h.state).branch!.index, 0);
      expect(h.state.scrollRequest!.kind, ChatScrollKind.revealLive);
      await c.switchBranch(lastTurn(h.state).firstMessageId!, BranchDirection.next);
      expect(turnText(h.state), 'Second answer');
      final session = await h.store.getSession(kSession);
      expect(session!.activeLeafId, lastTurn(h.state).steps.last.id);
    });

    test('switchBranch follows the first-child chain to the deepest leaf', () async {
      h = ChatHarness(turns: [ScriptedTurn.text('A1'), ScriptedTurn.text('A2'), ScriptedTurn.text('B1')]);
      await h.createSession();
      final c = await h.open();
      await c.send('Q1');
      h.clock.advance(const Duration(seconds: 1));
      await c.send('Q2');
      final q1 = h.state.items.whereType<UserItem>().first;
      h.clock.advance(const Duration(seconds: 1));
      await c.edit(q1.message.id, 'Q1 edited');
      expect(h.state.items.whereType<UserItem>().single.text, 'Q1 edited');
      expect(lastUser(h.state).branch.count, 2);
      expect(lastUser(h.state).branch.index, 1);
      await c.switchBranch(lastUser(h.state).message.id, BranchDirection.previous);
      // Back on the original branch, all the way down to Q2's answer.
      expect(h.state.items.whereType<UserItem>().map((u) => u.text), ['Q1', 'Q2']);
      expect(turnText(h.state), 'A2');
    });

    test('edit creates a branch and keeps the original', () async {
      h = ChatHarness(turns: [ScriptedTurn.text('Paris'), ScriptedTurn.text('Rome')]);
      await h.createSession();
      final c = await h.open();
      await c.send('Capital of France?');
      final original = lastUser(h.state).message.id;
      h.clock.advance(const Duration(seconds: 5));
      await c.edit(original, 'Capital of Italy?');
      final s = h.state;
      expect(s.items.whereType<UserItem>().single.text, 'Capital of Italy?');
      expect(lastUser(s).isEdit, isTrue);
      expect(lastUser(s).branch.count, 2);
      expect(turnText(s), 'Rome');
      expect(await h.store.getMessage(kSession, original), isNotNull, reason: 'append-only');
    });
  });

  group('errors', () {
    test('quotaExceeded explains billing and does not offer retry', () async {
      h = ChatHarness(turns: [
        ScriptedTurn.error(const ProviderException(ProviderErrorKind.quotaExceeded, 'insufficient_quota', statusCode: 429)),
      ]);
      await h.createSession();
      final c = await h.open();
      await c.send('Hi');
      final e = h.state.error!;
      expect(h.state.status, ChatRunStatus.error);
      expect(e.kind, ChatErrorKind.quotaExceeded);
      expect(e.message, contains('billing'));
      expect(e.actions, isNot(contains(ChatErrorAction.retry)));
      expect(e.actions, contains(ChatErrorAction.changeModel));
      expect(e.detail, contains('429'));
    });

    test('auth errors offer "Fix provider"', () async {
      h = ChatHarness(turns: [ScriptedTurn.error(const ProviderException(ProviderErrorKind.auth, 'bad key', statusCode: 401))]);
      await h.createSession();
      final c = await h.open();
      await c.send('Hi');
      expect(h.state.error!.kind, ChatErrorKind.auth);
      expect(h.state.error!.actions.first, ChatErrorAction.fixProvider);
      expect(h.state.error!.providerId, kProviderId);
    });

    test('rate limits are retried automatically, then offer retry', () async {
      const limited = ProviderException(ProviderErrorKind.rateLimited, 'slow down');
      h = ChatHarness(
        turns: [ScriptedTurn.error(limited), ScriptedTurn.error(limited), ScriptedTurn.error(limited)],
      );
      await h.createSession();
      final c = await h.open();
      await c.send('Hi');
      expect(h.state.error!.kind, ChatErrorKind.rateLimited);
      expect(h.state.error!.actions.first, ChatErrorAction.retry);
      expect(h.state.notices.where((n) => n.code == 'retrying'), isEmpty, reason: 'cleared at the end');
    });

    test('retryLast after a failure runs again from the same message', () async {
      h = ChatHarness(turns: [
        ScriptedTurn.error(const ProviderException(ProviderErrorKind.network, 'down')),
        ScriptedTurn.error(const ProviderException(ProviderErrorKind.network, 'down')),
        ScriptedTurn.error(const ProviderException(ProviderErrorKind.network, 'down')),
        ScriptedTurn.text('Back online.'),
      ]);
      await h.createSession();
      final c = await h.open();
      await c.send('Hi');
      expect(h.state.error!.kind, ChatErrorKind.offline);
      await c.retryLast();
      expect(h.state.error, isNull);
      expect(turnText(h.state), 'Back online.');
      expect(h.state.items.whereType<UserItem>(), hasLength(1));
    });

    test('context overflow explains and offers a new chat', () async {
      h = ChatHarness(
        caps: const ModelCapabilities(contextLength: 3000),
        turns: [ScriptedTurn.text('never')],
      );
      await h.createSession();
      final c = await h.open();
      await c.send('x' * 20000);
      expect(h.state.error!.kind, ChatErrorKind.contextOverflow);
      expect(h.state.error!.actions, contains(ChatErrorAction.newChat));
    });
  });

  group('resume', () {
    test('an interrupted streaming checkpoint is offered and resumes', () async {
      h = ChatHarness(turns: [ScriptedTurn.text('Picking up where I left off.')]);
      await h.createSession();
      final user = Message(
        id: 'u1',
        role: Role.user,
        content: const [TextPart('Long question')],
        createdAt: h.clock.now(),
      );
      await h.store.putMessage(kSession, user);
      final s = await h.store.getSession(kSession);
      await h.store.putSession(s!.copyWith(activeLeafId: 'u1'));
      // Process death mid-stream: a partial draft and a non-terminal checkpoint.
      await h.store.putMessage(
        kSession,
        Message(
          id: 'd1',
          parentId: 'u1',
          role: Role.assistant,
          content: const [TextPart('Picking up')],
          createdAt: h.clock.now(),
          metadata: const {'draft': true},
        ),
      );
      await h.store.putCheckpoint(RunCheckpoint(
        sessionId: kSession,
        runId: 'run_old',
        phase: RunPhase.streamingModel,
        step: 1,
        updatedAt: h.clock.now(),
        leafMessageId: 'u1',
        draftMessageId: 'd1',
      ));
      final c = await h.open();
      expect(h.state.interrupted!.phase, RunPhase.streamingModel);
      await c.resumeIfInterrupted();
      expect(h.state.interrupted, isNull);
      expect(turnText(h.state), 'Picking up where I left off.');
      expect(lastTurn(h.state).branch!.count, 1, reason: 'the orphan draft is not a branch');
      final cp = await h.store.getCheckpoint(kSession);
      expect(cp!.isTerminal, isTrue);
    });

    test('sending while interrupted closes the old run first', () async {
      final tool = writeTool('save_note');
      h = ChatHarness(tools: [tool], turns: [ScriptedTurn.text('Fresh start.')]);
      await h.createSession();
      final user = Message(id: 'u1', role: Role.user, content: const [TextPart('Save')], createdAt: h.clock.now());
      final asst = Message(
        id: 'a1',
        parentId: 'u1',
        role: Role.assistant,
        content: [ToolCallPart(call('c1', 'save_note'))],
        createdAt: h.clock.now(),
        finishReason: 'toolCalls',
      );
      await h.store.putMessage(kSession, user);
      await h.store.putMessage(kSession, asst);
      final s = await h.store.getSession(kSession);
      await h.store.putSession(s!.copyWith(activeLeafId: 'a1'));
      await h.store.putCheckpoint(RunCheckpoint(
        sessionId: kSession,
        runId: 'run_old',
        phase: RunPhase.awaitingApproval,
        step: 1,
        updatedAt: h.clock.now(),
        leafMessageId: 'a1',
        draftMessageId: 't1',
        pendingCalls: const [PendingCall(callId: 'c1', toolName: 'save_note', status: PendingCallStatus.pending)],
      ));
      final c = await h.open();
      expect(h.state.interrupted!.wasAwaitingApproval, isTrue);
      await c.send('Never mind');
      expect(tool.calls, isEmpty, reason: 'approvals are never auto-granted on resume');
      final path = await h.activePath();
      expect(path.map((m) => m.role), [Role.user, Role.assistant, Role.tool, Role.user, Role.assistant]);
      expect(turnText(h.state), 'Fresh start.');
    });
  });

  group('actions', () {
    test('copy and share use the visible text of the whole turn', () async {
      final tool = FakeTool('lookup');
      h = ChatHarness(tools: [tool], turns: [
        ScriptedTurn.toolCalls([call('c1', 'lookup')], preamble: 'Let me check.'),
        ScriptedTurn.text('It is 42.'),
      ]);
      await h.createSession();
      final c = await h.open();
      await c.send('Answer?');
      final turn = lastTurn(h.state);
      expect(await c.copy(turn.steps.last.id), isTrue);
      expect(h.platform.copied.single, 'Let me check.\n\nIt is 42.');
      await c.share(lastUser(h.state).message.id);
      expect(h.platform.shared.single, 'Answer?');
    });

    test('changeModel updates the session and the badge', () async {
      final local = ScriptedProvider(const [], info: const ProviderInfo(
        id: 'phone',
        kind: ProviderKind.fake,
        displayName: 'On phone',
        location: ExecutionLocation.onDevice,
      ));
      h = ChatHarness();
      h.registry.setProvider('phone', local);
      await h.createSession();
      final c = await h.open();
      await c.changeModel(const ModelChoice(providerId: 'phone', modelId: 'scripted-model'));
      final s = await h.store.getSession(kSession);
      expect(s!.providerId, 'phone');
      expect(h.state.model!.leavesDevice, isFalse);
      expect(h.state.model!.privacy.shortLabel, 'On device');
    });

    test('startNewChat creates a session on the same model', () async {
      h = ChatHarness();
      await h.createSession();
      final c = await h.open();
      final id = await c.startNewChat();
      final s = await h.store.getSession(id!);
      expect(s!.providerId, kProviderId);
      expect(s.title, defaultSessionTitle);
    });
  });

  group('helpers', () {
    test('privacy classification follows the app-wide rules', () {
      PrivacyBadgeData of(String url) => privacyForConfig(ProviderConfig(
            id: 'x',
            flavor: ApiFlavor.openAiChat,
            displayName: 'X',
            baseUrl: Uri.parse(url),
          ));
      expect(of('http://localhost:8080').location, ExecutionLocation.onDevice);
      expect(of('http://192.168.1.20:11434').location, ExecutionLocation.localNetwork);
      expect(of('http://192.168.1.20:11434').host, '192.168.1.20:11434', reason: 'port tells LAN servers apart');
      expect(of('http://mac-mini.local:1234').location, ExecutionLocation.localNetwork);
      expect(of('https://api.anthropic.com').location, ExecutionLocation.remote);
      expect(of('https://api.anthropic.com').shortLabel, '→ api.anthropic.com');
    });

    test('token counts', () {
      expect(formatTokenCount(8192), '8K');
      expect(formatTokenCount(131072), '128K');
      expect(formatTokenCount(200000), '200K');
      expect(formatTokenCount(1530), '1.5K');
      expect(formatTokenCount(1048576), '1M');
      expect(formatTokenCount(512), '512');
    });
  });
}
