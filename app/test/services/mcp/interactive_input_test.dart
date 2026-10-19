import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa/services/mcp/input/host_settings.dart';
import 'package:sherpa/services/mcp/input/input_history.dart';
import 'package:sherpa/services/mcp/input/input_queue.dart';
import 'package:sherpa/services/mcp/input/interactive_handler.dart';
import 'package:sherpa/services/mcp/input/url_opener.dart';
import 'package:sherpa/services/mcp/mcp_records.dart';
import 'package:sherpa/services/mcp/mcp_runtime.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_mcp/sherpa_mcp.dart';

import 'support/input_fakes.dart';
import 'support/mcp_fakes.dart';

final class _Rig {
  _Rig._(this.records, this.settings, this.queue, this.history, this.handler, this.clock);

  static Future<_Rig> create({Duration timeout = const Duration(minutes: 5)}) async {
    final records = InMemoryMcpRecords();
    final clock = FakeClock(DateTime.utc(2026, 10, 19, 12));
    final settings = await McpHostSettingsStore.load(records, clock: clock);
    final queue = McpInputQueue(clock: clock, timeout: timeout);
    final history = McpInputHistory();
    final handler = InteractiveInputHandler(queue: queue, settings: settings, history: history, clock: clock);
    return _Rig._(records, settings, queue, history, handler, clock);
  }

  final InMemoryMcpRecords records;
  final McpHostSettingsStore settings;
  final McpInputQueue queue;
  final McpInputHistory history;
  final InteractiveInputHandler handler;
  final FakeClock clock;
}

void main() {
  group('queue', () {
    test('form: queued with its context, answered once, recorded without the answer', () async {
      final rig = await _Rig.create();
      final future = rig.handler.elicit(
        formRequest({
          'name': {'type': 'string'},
        }, required: ['name']),
        inputContext(),
      );
      await pump();
      final p = rig.queue.pending.single as PendingFormElicitation;
      expect(p.serverName, 'Example tools');
      expect(p.sessionId, 'chat-1');
      expect(rig.queue.forSession('chat-1'), [p]);
      expect(rig.queue.forSession('other'), isEmpty);
      expect(p.accept({'name': ''}), isFalse, reason: 'invalid answers are not sent');
      expect(p.accept({'name': 'Ada'}), isTrue);
      expect(p.accept({'name': 'Again'}), isFalse);
      final r = await future;
      expect(r.toJson(), {
        'action': 'accept',
        'content': {'name': 'Ada'},
      });
      expect(rig.queue.pending, isEmpty);
      final rec = rig.history.of('srv').single;
      expect(rec.outcome, McpInputOutcome.accepted);
      expect(rec.summary, contains('name'));
      expect(rec.summary, isNot(contains('Ada')), reason: 'answers are never recorded');
      expect(rec.toolName, 'srv__ask');
    });

    test('decline and cancel', () async {
      final rig = await _Rig.create();
      final a = rig.handler.elicit(formRequest(const {}), inputContext());
      final b = rig.handler.elicit(formRequest(const {}), inputContext());
      await pump();
      final [pa, pb] = rig.queue.pending;
      (pa as PendingFormElicitation).decline();
      (pb as PendingFormElicitation).cancel();
      expect((await a).action, McpElicitAction.decline);
      expect((await b).action, McpElicitAction.cancel);
      expect([for (final r in rig.history.of('srv')) r.outcome], [McpInputOutcome.declined, McpInputOutcome.cancelled]);
    });

    test('an unanswered request times out with a polite decline', () async {
      final rig = await _Rig.create(timeout: const Duration(milliseconds: 30));
      final r = await rig.handler.elicit(formRequest(const {}), inputContext());
      expect(r.action, McpElicitAction.decline);
      expect(rig.history.of('srv').single.outcome, McpInputOutcome.timedOut);
      await expectLater(
        () async {
          await rig.settings.update('srv', const McpServerHostSettings(sampling: McpSamplingMode.ask));
          return rig.handler.createMessage(samplingRequest(), inputContext());
        }(),
        throwsA(isA<InputRequestDeclined>().having((e) => e.reason, 'reason', contains('in time'))),
      );
      expect(rig.queue.pending, isEmpty);
    });

    test('a cancelled call closes its request', () async {
      final rig = await _Rig.create();
      final cancel = CancellationToken();
      final f = rig.handler.elicit(formRequest(const {}), inputContext(cancel: cancel));
      await pump();
      expect(rig.queue.pending, hasLength(1));
      cancel.cancel('stopped');
      expect((await f).action, McpElicitAction.cancel);
      expect(rig.queue.pending, isEmpty);
    });

    test('changes stream and dropServer', () async {
      final rig = await _Rig.create();
      var changes = 0;
      final sub = rig.queue.changes.listen((_) => changes++);
      addTearDown(sub.cancel);
      final f = rig.handler.elicit(formRequest(const {}), inputContext());
      await pump();
      expect(changes, greaterThan(0));
      rig.queue.dropServer('srv');
      expect((await f).action, McpElicitAction.decline);
    });
  });

  group('form secrets', () {
    test('a password field is refused at once, with a notice, and never queued', () async {
      final rig = await _Rig.create();
      final notices = <McpInputNotice>[];
      final sub = rig.queue.notices.listen(notices.add);
      addTearDown(sub.cancel);
      final r = await rig.handler.elicit(
        formRequest({
          'user': {'type': 'string'},
          'password': {'type': 'string'},
        }),
        inputContext(),
      );
      await pump();
      expect(r.action, McpElicitAction.decline);
      expect(rig.queue.pending, isEmpty);
      expect(notices.single.message, contains('Sherpa refused'));
      expect(rig.history.of('srv').single.outcome, McpInputOutcome.refused);
      expect(rig.history.of('srv').single.reason, contains('password'));
    });
  });

  group('URL elicitation', () {
    test('accept only after the page was opened; a legacy completion notice finishes it', () async {
      final rig0 = await _Rig.create();
      final completions = StreamController<McpElicitationCompleted>.broadcast();
      addTearDown(completions.close);
      final handler = InteractiveInputHandler(
        queue: rig0.queue,
        settings: rig0.settings,
        history: rig0.history,
        completions: (_) => completions.stream,
      );
      final f = handler.elicit(
        McpElicitRequest.fromJson({
          'mode': 'url',
          'message': 'Sign in to Example',
          'url': 'https://auth.example.com/start?code=SECRET',
          'elicitationId': 'el-1',
        }),
        inputContext(),
      );
      await pump();
      final p = rig0.queue.pending.single as PendingUrlElicitation;
      expect(p.stage, UrlElicitationStage.consent);
      p.complete();
      expect(p.isDone, isFalse, reason: 'nothing is accepted before the page was opened');
      completions.add(const McpElicitationCompleted('el-1'));
      await pump();
      expect(p.isDone, isFalse);
      p.markOpened();
      completions.add(const McpElicitationCompleted('other'));
      await pump();
      expect(p.isDone, isFalse);
      completions.add(const McpElicitationCompleted('el-1'));
      expect((await f).action, McpElicitAction.accept);
      final rec = rig0.history.of('srv').single;
      expect(rec.summary, 'Open https://auth.example.com/start (query removed)');
    });
  });

  test('the URL opener refuses anything but http(s) before touching the platform', () async {
    const opener = UrlLauncherOpener();
    for (final u in ['javascript:alert(1)', 'file:///etc/passwd', 'intent://x#Intent;end', 'sherpa://x', 'https:no-host']) {
      expect(await opener.open(Uri.parse(u)), isFalse, reason: u);
    }
  });

  group('sampling policy', () {
    test('off by default: refused without asking', () async {
      final rig = await _Rig.create();
      await expectLater(rig.handler.createMessage(samplingRequest(), inputContext()), throwsA(isA<InputRequestDeclined>()));
      expect(rig.queue.pending, isEmpty);
      expect(rig.history.of('srv').single.outcome, McpInputOutcome.refused);
    });

    test('ask: the approval stage, capped maxTokens, refused context, then review and send', () async {
      final rig = await _Rig.create();
      await rig.settings.update('srv', const McpServerHostSettings(sampling: McpSamplingMode.ask, samplingMaxTokens: 256));
      final f = rig.handler.createMessage(samplingRequest(maxTokens: 4000, includeContext: 'allServers'), inputContext());
      await pump();
      final p = rig.queue.pending.single as PendingSampling;
      expect(p.stage, SamplingStage.approval);
      expect(p.preApproved, isFalse);
      expect(p.limits.maxTokens, 256);
      expect(p.limits.capped, isTrue);
      expect(p.limits.contextRefused, isTrue);
      p.approve(prompt: 'Capital of Portugal?', forChat: true);
      expect(p.stage, SamplingStage.running);
      expect(p.approvedPrompt, 'Capital of Portugal?');
      expect(rig.settings.chatAllowed('srv', 'chat-1'), isTrue, reason: 'granted when chosen');
      expect(p.send(), isFalse, reason: 'nothing to send before the answer is reviewed');
      p.setDraft(const SamplingDraft(text: 'Lisbon.', model: 'm1', modelLabel: 'Model One'));
      expect(p.send(text: 'Lisbon!'), isTrue);
      final r = await f;
      expect(r.toJson(), {
        'role': 'assistant',
        'content': {'type': 'text', 'text': 'Lisbon!'},
        'model': 'm1',
        'stopReason': 'endTurn',
      });

      // Allowed for this chat: the next request in it skips the approval.
      final g = rig.handler.createMessage(samplingRequest(), inputContext());
      await pump();
      final q = rig.queue.pending.single as PendingSampling;
      expect(q.preApproved, isTrue);
      expect(q.stage, SamplingStage.running);
      q.deny();
      await expectLater(g, throwsA(isA<InputRequestDeclined>()));

      // Another chat still asks.
      final h = rig.handler.createMessage(samplingRequest(), inputContext(sessionId: 'chat-2'));
      await pump();
      expect((rig.queue.pending.single as PendingSampling).stage, SamplingStage.approval);
      (rig.queue.pending.single as PendingSampling).deny();
      await expectLater(h, throwsA(isA<InputRequestDeclined>()));
    });

    test('allowInChats skips the approval in a chat only; requests per minute are limited', () async {
      final rig = await _Rig.create();
      await rig.settings.update(
        'srv',
        const McpServerHostSettings(sampling: McpSamplingMode.allowInChats, samplingPerMinute: 2),
      );
      final a = rig.handler.createMessage(samplingRequest(), inputContext());
      final b = rig.handler.createMessage(samplingRequest(), inputContext(sessionId: null, toolName: null));
      await pump();
      final [pa, pb] = [for (final p in rig.queue.pending) p as PendingSampling];
      expect(pa.preApproved, isTrue);
      expect(pb.preApproved, isFalse, reason: 'outside a chat it asks');
      await expectLater(
        rig.handler.createMessage(samplingRequest(), inputContext()),
        throwsA(isA<InputRequestDeclined>().having((e) => e.reason, 'reason', contains('too often'))),
      );
      rig.clock.advance(const Duration(minutes: 1));
      final c = rig.handler.createMessage(samplingRequest(), inputContext());
      await pump();
      expect(rig.queue.pending, hasLength(3));
      for (final p in rig.queue.pending) {
        (p as PendingSampling).deny();
      }
      for (final f in [a, b, c]) {
        await expectLater(f, throwsA(isA<InputRequestDeclined>()));
      }
    });

    test('tools in sampling are refused', () async {
      final rig = await _Rig.create();
      await rig.settings.update('srv', const McpServerHostSettings(sampling: McpSamplingMode.ask));
      await expectLater(
        rig.handler.createMessage(
          samplingRequest(tools: [
            {
              'name': 'x',
              'inputSchema': {'type': 'object'},
            },
          ]),
          inputContext(),
        ),
        throwsA(isA<InputRequestDeclined>()),
      );
      expect(rig.queue.pending, isEmpty);
    });

    test('roots are refused', () async {
      final rig = await _Rig.create();
      await expectLater(rig.handler.listRoots(inputContext()), throwsA(isA<InputRequestDeclined>()));
    });
  });

  group('settings persistence', () {
    test('sampling and apps settings, consents and revocation survive a reload', () async {
      final rig = await _Rig.create();
      await rig.settings.update(
        'srv',
        const McpServerHostSettings(sampling: McpSamplingMode.allowInChats, samplingMaxTokens: 4096, appsEnabled: false, samplingModel: defaultChoice),
      );
      await rig.settings.setGrantedOrigins('srv', 'abc', {'https://api.example.com'}, resourceUri: 'ui://srv/view');
      await rig.settings.setGrantedOrigins('srv', 'def', const {}, resourceUri: 'ui://srv/other');
      final again = await McpHostSettingsStore.load(rig.records);
      final s = again.of('srv');
      expect(s.sampling, McpSamplingMode.allowInChats);
      expect(s.samplingMaxTokens, 4096);
      expect(s.appsEnabled, isFalse);
      expect(s.samplingModel, defaultChoice);
      expect(again.of('other').sampling, McpSamplingMode.off, reason: 'off by default');
      expect(again.of('other').appsEnabled, isTrue);
      expect(again.grantedOrigins('srv', 'abc'), {'https://api.example.com'});
      expect(again.grantedOrigins('srv', 'def'), isEmpty, reason: '"keep offline" is remembered too');
      expect(again.grantedOrigins('srv', 'changed-hash'), isNull, reason: 'a changed view asks again');
      await again.revokeConsent('srv', 'abc');
      expect((await McpHostSettingsStore.load(rig.records)).grantedOrigins('srv', 'abc'), isNull);
      await again.forgetServer('srv');
      final gone = await McpHostSettingsStore.load(rig.records);
      expect(gone.of('srv').sampling, McpSamplingMode.off);
      expect(gone.consentsOf('srv'), isEmpty);
    });
  });

  group('runtime', () {
    const url = 'https://tools.example.com/mcp';

    test('capabilities are declared per server: no sampling by default, MCP Apps unless turned off', () async {
      final seen = <JsonMap>[];
      final remote = FakeRemoteServers()
        ..add(url, name: 'Example tools', tools: [
          DartMcpTool(
            name: 'caps',
            description: 'Reports what the client declared.',
            inputSchema: const {'type': 'object'},
            handler: (args, ctx) async {
              seen.add(ctx.clientCapabilities);
              return DartToolResult.text('ok');
            },
          ),
        ]);
      final rt = await fakeRuntime(remote: remote);
      addTearDown(rt.dispose);
      final c = await rt.addServer(url: Uri.parse(url), name: 'Example tools');
      rt.setTrusted(c.id, true);
      await rt.refresh();
      Future<void> call() async {
        final r = await rt.router.execute(const ToolCall(id: 'c', name: 'example_tools__caps', arguments: {}), toolCtx('s'));
        expect(r.isError, isFalse);
      }

      await call();
      expect(seen.last['elicitation'], {'form': <String, Object?>{}, 'url': <String, Object?>{}});
      expect(seen.last.containsKey('sampling'), isFalse, reason: 'sampling is off by default');
      expect((seen.last['extensions']! as Map).containsKey(McpExtensionIds.ui), isTrue);

      await rt.updateHostSettings(c.id, rt.hostSettingsOf(c.id).copyWith(sampling: McpSamplingMode.ask));
      await call();
      expect(seen.last['sampling'], <String, Object?>{}, reason: 'declared without tools');

      await rt.updateHostSettings(c.id, rt.hostSettingsOf(c.id).copyWith(appsEnabled: false));
      await call();
      expect(seen.last.containsKey('extensions'), isFalse);

      // Removing the server forgets its settings and history.
      rt.inputHistory.add(McpInputRecord(at: DateTime.utc(2026), serverId: c.id, kind: McpInputKind.form, outcome: McpInputOutcome.declined, summary: 'x'));
      await rt.removeServer(c.id);
      expect(rt.inputRecords(c.id), isEmpty);
      expect(rt.hostSettingsOf(c.id).sampling, McpSamplingMode.off);
    });

    test('the default input handler is interactive: an elicitation waits in the queue', () async {
      final remote = FakeRemoteServers()
        ..add(url, name: 'Example tools', tools: [
          DartMcpTool(
            name: 'ask',
            description: 'Asks for a name.',
            inputSchema: const {'type': 'object'},
            handler: (args, ctx) async {
              final answer = ctx.inputResponses?['who'];
              if (answer is! Map) {
                return const DartToolResult.inputRequired({
                  'who': {
                    'method': 'elicitation/create',
                    'params': {
                      'message': 'Who are you?',
                      'requestedSchema': {
                        'type': 'object',
                        'properties': {
                          'name': {'type': 'string'},
                        },
                      },
                    },
                  },
                });
              }
              return DartToolResult.text('hi ${(answer['content'] as Map?)?['name']}');
            },
          ),
        ]);
      final rt = await fakeRuntime(remote: remote);
      addTearDown(rt.dispose);
      final c = await rt.addServer(url: Uri.parse(url), name: 'Example tools');
      rt.setTrusted(c.id, true);
      await rt.refresh();
      final run = rt.router.execute(const ToolCall(id: 'c', name: 'example_tools__ask', arguments: {}), toolCtx('chat-9'));
      await eventually(() => rt.inputQueue.pending.isNotEmpty);
      final p = rt.inputQueue.pending.single as PendingFormElicitation;
      expect(p.sessionId, 'chat-9', reason: 'attributed to the chat that called the tool');
      expect(p.toolName, 'example_tools__ask');
      expect(p.serverTrusted, isTrue);
      p.accept({'name': 'Grace'});
      final r = await run;
      expect(r.content.whereType<TextPart>().single.text, 'hi Grace');
      expect(rt.inputRecords(c.id).single.outcome, McpInputOutcome.accepted);
      expect(McpRuntime.reservedIds, isNotEmpty);
    });
  });
}
