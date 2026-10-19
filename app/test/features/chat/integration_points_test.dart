import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa/features/chat/state/chat_dependencies.dart';
import 'package:sherpa/features/chat/state/chat_errors.dart';
import 'package:sherpa/features/chat/state/chat_view_state.dart';
import 'package:sherpa/features/chat/state/model_selection.dart';
import 'package:sherpa/features/chat/state/notice_copy.dart';
import 'package:sherpa/features/chat/state/transcript_model.dart';
import 'package:sherpa/features/mcp/state/mcp_providers.dart';
import 'package:sherpa/services/inference/local_model_provider.dart';
import 'package:sherpa/services/mcp/composer_sources.dart';
import 'package:sherpa/state/services.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_core/testing.dart';
import 'package:sherpa_mcp/sherpa_mcp.dart' show McpPromptArgument;

import 'support/harness.dart';
import 'support/mcp.dart';

UserItem lastUser(ChatViewState s) => s.items.whereType<UserItem>().last;

AssistantTurnItem lastTurn(ChatViewState s) => s.items.whereType<AssistantTurnItem>().last;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ChatHarness h;
  tearDown(() => h.dispose());

  group('MCP prompts', () {
    test('an expanded prompt is stored with its metadata; its last message runs', () async {
      h = ChatHarness(turns: [ScriptedTurn.text('Looks good.')]);
      await h.createSession();
      final c = await h.open();
      final cmd = promptCommand();
      await c.sendPrompt(expandedPrompt(cmd, [
        (Role.user, 'House style: short sentences.'),
        (Role.assistant, 'Understood.'),
        (Role.user, 'Review: the tide follows the moon'),
      ]));

      final path = await h.activePath();
      expect(path.map((m) => m.role), [Role.user, Role.assistant, Role.user, Role.assistant]);
      for (final m in path.take(3)) {
        expect(m.metadata[UntrustedData.messageMetadataKey], isTrue, reason: 'untrusted server text stays flagged');
        final p = m.metadata[kMcpPromptKey]! as Map;
        expect(p['serverId'], 'srv');
        expect(p['serverName'], 'Example tools');
        expect(p['command'], 'srv:review');
      }
      final sent = h.scripted.requests.single.messages;
      expect(sent.map((m) => m.text), ['House style: short sentences.', 'Understood.', 'Review: the tide follows the moon']);

      final user = lastUser(h.state);
      expect(user.promptSource!.label, 'From Example tools · /srv:review · untrusted');
      expect(lastTurn(h.state).copyText, 'Looks good.');
    });

    test("a trusted server's prompt is labelled with its source but not flagged", () async {
      h = ChatHarness(turns: [ScriptedTurn.text('Done.')]);
      await h.createSession();
      final c = await h.open();
      await c.sendPrompt(expandedPrompt(promptCommand(trusted: true), [(Role.user, 'Summarize the week')]));
      final user = (await h.activePath()).first;
      expect(user.metadata[UntrustedData.messageMetadataKey], isNull);
      expect(lastUser(h.state).promptSource!.label, 'From Example tools · /srv:review');
      expect(lastUser(h.state).promptSource!.untrusted, isFalse);
    });

    test('a prompt that ends with an assistant message is added without a run', () async {
      h = ChatHarness();
      await h.createSession();
      final c = await h.open();
      await c.sendPrompt(expandedPrompt(promptCommand(), [(Role.user, 'Q'), (Role.assistant, 'An example answer')]));
      final path = await h.activePath();
      expect(path.map((m) => m.text), ['Q', 'An example answer']);
      expect(h.scripted.requests, isEmpty);
      expect(lastTurn(h.state).promptSource?.serverName, 'Example tools');
    });

    test('missing required arguments are reported by the composer sources', () async {
      final cmd = promptCommand(arguments: const [McpPromptArgument(name: 'topic', required: true)]);
      final sources = FakeMcpSources();
      await expectLater(sources.expand(cmd, const {}), throwsA(isA<McpPromptArgumentsException>()));
      expect(cmd.parseArguments('tides'), {'topic': 'tides'});
    });
  });

  group('@ mentions', () {
    test('a mention attaches the resolved resource part, with its server for the transcript', () async {
      final sources = FakeMcpSources(parts: {
        'today': const EmbeddedResourcePart(uri: 'notes://today.md', mimeType: 'text/markdown', text: 'Buy milk'),
      });
      h = ChatHarness(
        turns: [ScriptedTurn.text('Noted.')],
        overrides: [chatMcpSourcesProvider.overrideWithValue(sources)],
      );
      await h.createSession();
      final c = await h.open();
      await c.send('What is on my list?', mentions: [resource('today')]);

      expect(sources.resolved, ['srv:today']);
      final user = (await h.activePath()).first;
      expect(user.text, 'What is on my list?');
      expect(user.content.whereType<EmbeddedResourcePart>().single.text, 'Buy milk');
      expect(user.metadata[kMcpResourcesKey], [
        {'uri': 'notes://today.md', 'serverId': 'srv', 'serverName': 'Example tools', 'mention': 'srv:today', 'name': 'today'},
      ]);
      final sent = h.scripted.requests.single.messages.first;
      expect(sent.content.whereType<EmbeddedResourcePart>(), hasLength(1));
      final item = lastUser(h.state);
      expect(item.resources.single.label, 'today');
      expect(item.resources.single.serverName, 'Example tools');
    });

    test('a mention alone (no text) is a message too; a link when it is not embedded', () async {
      h = ChatHarness(
        turns: [ScriptedTurn.text('Opened.')],
        overrides: [chatMcpSourcesProvider.overrideWithValue(FakeMcpSources())],
      );
      await h.createSession();
      final c = await h.open();
      await c.send('', mentions: [resource('report', uri: 'docs://q3/report.pdf')]);
      final user = (await h.activePath()).first;
      expect(user.content.single, isA<ResourceLinkPart>());
      expect(lastUser(h.state).resources.single.embedded, isFalse);
    });
  });

  group('tool segments and resume', () {
    test('the user-turn hook runs before send, edit and regenerate, not before continue', () async {
      final turns = <String>[];
      h = ChatHarness(
        turns: [ScriptedTurn.text('One.'), ScriptedTurn.text('Two.'), ScriptedTurn.text('Three.')],
        overrides: [toolsUserTurnHookProvider.overrideWithValue(turns.add)],
      );
      await h.createSession();
      final c = await h.open();
      await c.send('Hi');
      expect(turns, [kSession]);
      await c.retry(lastTurn(h.state).firstMessageId!);
      expect(turns, hasLength(2));
      await c.edit(lastUser(h.state).message.id, 'Hello');
      expect(turns, hasLength(3));
    });

    test('resume waits until the tools are listed', () async {
      final ready = Completer<void>();
      var asked = 0;
      h = ChatHarness(
        turns: [ScriptedTurn.text('Picking up.')],
        overrides: [
          toolsReadyProvider.overrideWithValue(() {
            asked++;
            return ready.future;
          }),
        ],
      );
      await h.createSession();
      final user = Message(id: 'u1', role: Role.user, content: const [TextPart('Go on')], createdAt: h.clock.now());
      await h.store.putMessage(kSession, user);
      final s = await h.store.getSession(kSession);
      await h.store.putSession(s!.copyWith(activeLeafId: 'u1'));
      await h.store.putCheckpoint(RunCheckpoint(
        sessionId: kSession,
        runId: 'run_old',
        phase: RunPhase.preparingContext,
        step: 1,
        updatedAt: h.clock.now(),
        leafMessageId: 'u1',
      ));
      final c = await h.open();
      final resumed = c.resumeIfInterrupted();
      await h.settle();
      expect(asked, 1);
      expect(h.scripted.requests, isEmpty, reason: 'nothing runs before the tool listing finished');
      ready.complete();
      await resumed;
      expect(h.scripted.requests, hasLength(1));
      expect(lastTurn(h.state).copyText, 'Picking up.');
    });
  });

  group('on-device models', () {
    test('a local chat whose provider cannot be built still says it runs on this phone', () async {
      h = ChatHarness();
      await h.store.putSession(SessionRecord(
        id: kSession,
        title: 'Local',
        createdAt: h.clock.now(),
        updatedAt: h.clock.now(),
        providerId: localProviderId,
        modelId: 'lib-qwen3',
      ));
      await h.open();
      expect(h.state.availability, ProviderAvailability.providerMissing);
      expect(h.state.model!.location, ExecutionLocation.onDevice);
      expect(h.state.model!.providerName, kLocalProviderName);
    });

    test('no provider but models on this phone: the chat offers them and uses one', () async {
      final local = ScriptedProvider([ScriptedTurn.text('Hi from the phone.')], info: kLocalInfo);
      h = ChatHarness(configured: false, providers: {localProviderId: local});
      await h.createSession(withModel: false);
      final c = await h.open();
      expect(h.state.availability, ProviderAvailability.needsModel, reason: 'not "add a provider"');
      expect(h.state.onDeviceModels, 1);

      await c.changeModel(const ModelChoice(providerId: localProviderId, modelId: 'scripted-model'));
      expect(h.state.availability, ProviderAvailability.ready);
      expect(h.state.model!.modelName, 'Scripted model', reason: 'the display name, not the library id');
      expect(h.state.model!.location, ExecutionLocation.onDevice);
      await c.send('Hello');
      expect(lastTurn(h.state).copyText, 'Hi from the phone.');
    });

    test('nothing at all: still "add a provider"', () async {
      h = ChatHarness(configured: false);
      await h.createSession(withModel: false);
      await h.open();
      expect(h.state.availability, ProviderAvailability.noProviders);
      expect(h.state.onDeviceModels, 0);
    });

    test('a local reply keeps its speed; the turn shows it', () async {
      final local = ScriptedProvider([
        ScriptedTurn([
          const TextDelta('Tides follow the moon.'),
          const PerfSample(timeToFirstTokenMs: 420, decodeTokensPerSec: 42.3, prefillTokensPerSec: 310, draftAcceptRate: 0.63),
          const Finish(FinishReason.stop),
        ]),
      ], info: kLocalInfo);
      h = ChatHarness(provider: local, configs: const [], providers: {localProviderId: local});
      await h.store.putSession(SessionRecord(
        id: kSession,
        title: defaultSessionTitle,
        createdAt: h.clock.now(),
        updatedAt: h.clock.now(),
        providerId: localProviderId,
        modelId: 'scripted-model',
      ));
      final c = await h.open();
      await c.send('Why tides?');
      await h.settle();
      final perf = lastTurn(h.state).perf!;
      expect(perf.label, '42 tok/s · TTFT 0.4 s');
      expect(perf.semanticLabel, contains('Generated at 42 tokens per second'));
      expect(perf.semanticLabel, contains('63% of drafted tokens accepted'));
      final reply = (await h.activePath()).last;
      expect(reply.metadata[kReplyPerfKey], isNotNull, reason: 'kept for when the chat is reopened');
    });

    test('a reply without timing has no speed line', () async {
      h = ChatHarness(turns: [ScriptedTurn.text('Hello.')]);
      await h.createSession();
      final c = await h.open();
      await c.send('Hi');
      expect(lastTurn(h.state).perf, isNull);
    });

    test('the engine crash report becomes a plain warning', () async {
      const report = 'The app was stopped (possibly by the system for using too much memory) while generating a reply '
          'with Qwen3 0.6B (8192-token context).';
      final n = providerNoticeFor(const ProviderNotice(kEngineCrashNoticeCode, report))!;
      expect(n.kind, ChatNoticeKind.warning);
      expect(n.dismissible, isTrue);
      expect(n.message, startsWith('The on-device model stopped unexpectedly last time. '));
      expect(n.message, contains('Qwen3 0.6B'));
      expect(n.message, endsWith('try a smaller model or close other apps.'));

      h = ChatHarness(turns: [
        ScriptedTurn([const ProviderNotice(kEngineCrashNoticeCode, report), const TextDelta('Hi.'), const Finish(FinishReason.stop)]),
      ]);
      await h.createSession();
      final c = await h.open();
      await c.send('Hi');
      expect(h.state.notices.where((n) => n.code == kEngineCrashNoticeCode).single.kind, ChatNoticeKind.warning);
    });

    test('an unavailable engine reads "On-device models are unavailable", with the library to fix it', () {
      const model = ModelSelection(
        providerId: localProviderId,
        modelId: 'lib-qwen3',
        providerName: kLocalProviderName,
        modelName: 'Qwen3 0.6B',
        location: ExecutionLocation.onDevice,
      );
      final e = chatErrorFrom(
        const ProviderException(
          ProviderErrorKind.unsupported,
          'On-device inference is unavailable: this build has no engine library',
          providerId: localProviderId,
        ),
        outcome: RunOutcome.failed,
        model: model,
      );
      expect(e.title, 'On-device models are unavailable: this build has no engine library');
      expect(e.title, isNot(contains('On this device rejected')));
      expect(e.actions, [ChatErrorAction.openModels, ChatErrorAction.changeModel]);
      // Other local errors never start with "On this device".
      final other = chatErrorFrom(const ProviderException(ProviderErrorKind.invalidRequest, 'bad'), model: model);
      expect(other.title, 'The on-device model rejected the request');
      // Remote providers keep their names.
      final remote = chatErrorFrom(const ProviderException(ProviderErrorKind.unsupported, 'no tools'));
      expect(remote.title, 'The provider rejected the request');
    });
  });
}
