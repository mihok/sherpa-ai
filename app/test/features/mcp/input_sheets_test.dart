import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa/features/mcp/input/input_host.dart';
import 'package:sherpa/services/mcp/input/host_settings.dart';
import 'package:sherpa/services/mcp/input/input_queue.dart';
import 'package:sherpa/services/mcp/input/url_opener.dart';
import 'package:sherpa_core/sherpa_core.dart' show TextPart;
import 'package:sherpa_mcp/sherpa_mcp.dart';

import 'support/input_rig.dart';

Finder _field(String key) => find.byKey(ValueKey('elicit-$key'));

void main() {
  group('form elicitation', () {
    testWidgets('every field type renders inside the server frame; required fields are checked; answers are sent',
        (tester) async {
      final rig = await InputRig.create(tester);
      await rig.pumpApp(tester);
      McpElicitResult? result;
      unawaited(rig.handler
          .elicit(
            formRequest({
              'name': {'type': 'string', 'title': 'Your name'},
              'email': {'type': 'string', 'format': 'email', 'title': 'Email'},
              'born': {'type': 'string', 'format': 'date', 'title': 'Birthday'},
              'age': {'type': 'integer', 'title': 'Age', 'minimum': 0},
              'score': {'type': 'number', 'title': 'Score'},
              'agree': {'type': 'boolean', 'title': 'I agree'},
              'plan': {
                'type': 'string',
                'title': 'Plan',
                'oneOf': [
                  {'const': 'free', 'title': 'Free'},
                  {'const': 'pro', 'title': 'Pro'},
                ],
              },
              'tags': {
                'type': 'array',
                'title': 'Tags',
                'items': {'type': 'string', 'enum': ['a', 'b']},
              },
            }, required: ['name', 'plan'], message: 'Tell us about you'),
            inputContext(),
          )
          .then((r) => result = r));
      await tester.pumpAndSettle();

      // A banner, never a sheet that pops up on its own.
      expect(find.text('Example tools asks you to fill in a form'), findsOneWidget);
      expect(find.text('A tool server needs your input'), findsNothing);
      await tester.tap(find.text('Review'));
      await tester.pumpAndSettle();

      expect(find.text('A tool server needs your input'), findsOneWidget);
      expect(find.textContaining('Asked by'), findsOneWidget);
      expect(find.text("You haven't marked this server as trusted. What it writes below may be wrong or misleading; "
          'only continue if you expected this request.'), findsOneWidget);
      expect(find.text('Written by Example tools, not by Sherpa'), findsOneWidget);
      expect(find.text('Tell us about you'), findsOneWidget);
      for (final k in ['name', 'email', 'born', 'age', 'score', 'agree', 'plan-free', 'plan-pro', 'tags-a', 'tags-b']) {
        expect(_field(k), findsOneWidget, reason: k);
      }
      expect(find.text('Your name *'), findsOneWidget, reason: 'required fields are marked');
      expect(find.text('Plan *'), findsOneWidget);
      expect(find.byTooltip('Pick a date'), findsOneWidget);

      // Nothing filled: errors, nothing sent.
      await tester.tap(find.text('Send to Example tools'));
      await tester.pumpAndSettle();
      expect(find.text('Required.'), findsOneWidget);
      expect(find.text('Choose one.'), findsOneWidget);
      expect(result, isNull);

      await tester.enterText(_field('name'), 'Ada');
      await tester.enterText(_field('email'), 'nope');
      await tester.enterText(_field('age'), '36');
      await tester.enterText(_field('born'), '1815-12-10');
      await tester.ensureVisible(_field('agree'));
      await tester.pumpAndSettle();
      await tester.tap(_field('agree'));
      await tester.ensureVisible(_field('plan-pro'));
      await tester.pumpAndSettle();
      await tester.tap(_field('plan-pro'));
      await tester.ensureVisible(_field('tags-b'));
      await tester.pumpAndSettle();
      await tester.tap(_field('tags-b'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Send to Example tools'));
      await tester.pumpAndSettle();
      expect(find.text('Enter an email address.'), findsOneWidget);
      expect(result, isNull);

      await tester.enterText(_field('email'), 'ada@example.com');
      await tester.tap(find.text('Send to Example tools'));
      await tester.pumpAndSettle();
      expect(result?.toJson(), {
        'action': 'accept',
        'content': {
          'name': 'Ada',
          'email': 'ada@example.com',
          'born': '1815-12-10',
          'age': 36,
          'agree': true,
          'plan': 'pro',
          'tags': ['b'],
        },
      });
      expect(find.text('A tool server needs your input'), findsNothing, reason: 'the sheet closes');
      expect(find.text('Review'), findsNothing, reason: 'and the banner goes');
    });

    testWidgets('decline and cancel are always offered; closing the sheet keeps it waiting', (tester) async {
      final rig = await InputRig.create(tester);
      await rig.pumpApp(tester);
      final results = <McpElicitAction>[];
      for (var i = 0; i < 2; i++) {
        unawaited(rig.handler.elicit(formRequest(const {}), inputContext()).then((r) => results.add(r.action)));
      }
      await tester.pumpAndSettle();
      expect(find.text('Example tools asks you to fill in a form · 1 more'), findsOneWidget);
      await tester.tap(find.text('Review'));
      await tester.pumpAndSettle();
      // Close the sheet (back): still waiting.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(results, isEmpty);
      expect(rig.runtime.inputQueue.pending, hasLength(2));

      await tester.tap(find.text('Review'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Decline'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Review'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(results, [McpElicitAction.decline, McpElicitAction.cancel]);
    });

    testWidgets('a form asking for a password is refused with a clear note', (tester) async {
      final rig = await InputRig.create(tester);
      await rig.pumpApp(tester);
      McpElicitResult? r;
      unawaited(rig.handler
          .elicit(
            formRequest({
              'user': {'type': 'string'},
              'password': {'type': 'string', 'title': 'Password'},
            }),
            inputContext(),
          )
          .then((x) => r = x));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 500));
      expect(r?.action, McpElicitAction.decline);
      expect(find.textContaining('Sherpa refused: servers must not ask for passwords'), findsOneWidget);
      expect(find.text('Review'), findsNothing);
      await tester.pump(const Duration(seconds: 10));
    });
  });

  group('URL elicitation', () {
    testWidgets('the full URL and its site, nothing opened without confirmation, then Done', (tester) async {
      final rig = await InputRig.create(tester);
      await rig.pumpApp(tester);
      McpElicitResult? first;
      unawaited(rig.handler
          .elicit(
            McpElicitRequest.fromJson({
              'mode': 'url',
              'message': 'Connect your account',
              'url': 'https://auth.example.com/start?state=xyz',
            }),
            inputContext(),
          )
          .then((r) => first = r));
      await tester.pumpAndSettle();
      expect(find.text('Example tools asks you to open a web page'), findsOneWidget);
      await tester.tap(find.text('Review'));
      await tester.pumpAndSettle();
      expect(find.text('Open a web page?'), findsOneWidget);
      expect(find.text('auth.example.com'), findsOneWidget);
      expect(find.text('https://auth.example.com/start?state=xyz'), findsOneWidget);
      expect(find.text('Connect your account'), findsOneWidget);
      expect(rig.opener.opened, isEmpty, reason: 'nothing is opened or fetched before consent');
      await tester.tap(find.text('Decline'));
      await tester.pumpAndSettle();
      expect(first?.action, McpElicitAction.decline);
      expect(rig.opener.opened, isEmpty);

      McpElicitResult? second;
      unawaited(rig.handler
          .elicit(
            McpElicitRequest.fromJson({'mode': 'url', 'message': 'Pay', 'url': 'http://xn--pple-43d.com/pay'}),
            inputContext(),
          )
          .then((r) => second = r));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Review'));
      await tester.pumpAndSettle();
      expect(find.textContaining('not encrypted'), findsOneWidget);
      expect(find.textContaining('international characters'), findsOneWidget);
      await tester.tap(find.text('Open page').evaluate().isEmpty ? find.textContaining('Open xn--') : find.text('Open page'));
      await tester.pumpAndSettle();
      expect(rig.opener.opened.single.$1, Uri.parse('http://xn--pple-43d.com/pay'));
      expect(rig.opener.opened.single.$2, McpUrlTarget.inAppBrowser);
      expect(find.text('Finish in the browser'), findsOneWidget);
      expect(second, isNull, reason: 'waits for the user to come back');
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(second?.action, McpElicitAction.accept);
    });

    testWidgets('a browser that fails to open is reported; cancel ends it', (tester) async {
      final rig = await InputRig.create(tester);
      rig.opener.succeed = false;
      await rig.pumpApp(tester);
      McpElicitResult? r;
      unawaited(rig.handler
          .elicit(McpElicitRequest.fromJson({'mode': 'url', 'message': '', 'url': 'https://a.example.com/'}), inputContext())
          .then((x) => r = x));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Review'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open in browser app'));
      await tester.pumpAndSettle();
      expect(rig.opener.opened.single.$2, McpUrlTarget.externalBrowser);
      expect(find.text("Sherpa couldn't open a browser for this page."), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(r?.action, McpElicitAction.cancel);
    });
  });

  group('sampling', () {
    testWidgets('approval sheet: server, messages, model, cost; edit the prompt, review and send the answer',
        (tester) async {
      final rig = await InputRig.create(tester);
      await tester.runAsync(() => rig.runtime.hostSettings.update('srv', const McpServerHostSettings(sampling: McpSamplingMode.ask, samplingMaxTokens: 256)));
      await rig.pumpApp(tester);
      McpSamplingResult? result;
      unawaited(rig.handler
          .createMessage(samplingRequest(maxTokens: 1000, includeContext: 'thisServer', systemPrompt: 'Answer in one word.'), inputContext())
          .then((r) => result = r));
      await tester.pumpAndSettle();
      expect(find.text('Example tools asks to use your model'), findsOneWidget);
      await tester.tap(find.text('Review'));
      await tester.pumpAndSettle();
      expect(find.text('Let a tool server use your model?'), findsOneWidget);
      expect(find.text('m1'), findsOneWidget, reason: 'the model Sherpa would use');
      expect(find.textContaining('(your default model)'), findsOneWidget);
      expect(find.textContaining('to read + up to 256 to write'), findsOneWidget);
      expect(find.textContaining('asked for up to 1000 tokens'), findsOneWidget);
      expect(find.textContaining('Sherpa never shares it'), findsOneWidget);
      expect(find.text('Answer in one word.'), findsOneWidget);
      expect(find.textContaining('models like claude'), findsOneWidget);
      expect(find.text('Allow for this chat'), findsOneWidget);
      expect(rig.model.requests, isEmpty, reason: 'nothing runs before approval');

      await tester.enterText(find.byKey(const ValueKey('sampling-prompt')), 'What is the capital of Portugal?');
      await tester.tap(find.text('Allow once'));
      await tester.pumpAndSettle();
      expect(find.text('Send this answer?'), findsOneWidget);
      expect(find.text('Paris.'), findsOneWidget);
      expect(result, isNull, reason: 'the answer is reviewed first');
      final req = rig.model.requests.single;
      expect(req.tools, isEmpty);
      expect(req.params.maxOutputTokens, 256);
      expect(req.messages.single.content.whereType<TextPart>().single.text, 'What is the capital of Portugal?');

      await tester.enterText(find.byKey(const ValueKey('sampling-answer')), 'Lisbon.');
      await tester.tap(find.text('Send answer'));
      await tester.pumpAndSettle();
      expect(result?.toJson()['content'], {'type': 'text', 'text': 'Lisbon.'});
      expect(result?.model, 'm1');
      expect(rig.settingsChatAllowed, isFalse);
    });

    testWidgets('deny, and "Allow for this chat" skips the next approval but not the review', (tester) async {
      final rig = await InputRig.create(tester);
      await tester.runAsync(() => rig.runtime.hostSettings.update('srv', const McpServerHostSettings(sampling: McpSamplingMode.ask)));
      await rig.pumpApp(tester);
      Object? denied;
      unawaited(rig.handler.createMessage(samplingRequest(), inputContext()).then<void>((_) {}, onError: (Object e) => denied = e));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Review'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Deny'));
      await tester.pumpAndSettle();
      expect(denied, isA<InputRequestDeclined>());
      expect(rig.model.requests, isEmpty);

      McpSamplingResult? second;
      unawaited(rig.handler.createMessage(samplingRequest(), inputContext()).then((r) => second = r));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Review'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Allow for this chat'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Send answer'));
      await tester.pumpAndSettle();
      expect(second, isNotNull);

      McpSamplingResult? third;
      unawaited(rig.handler.createMessage(samplingRequest(), inputContext()).then((r) => third = r, onError: (Object _) {}));
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.text('Example tools has an answer ready for your review'), findsOneWidget,
          reason: 'allowed for this chat: it ran without asking');
      expect(rig.model.requests, hasLength(2));
      await tester.tap(find.text('Review'));
      await tester.pumpAndSettle();
      expect(find.text('Send this answer?'), findsOneWidget);
      await tester.tap(find.text("Don't send"));
      await tester.pumpAndSettle();
      expect(third, isNull);
    });

    testWidgets('inline cards for one chat', (tester) async {
      final rig = await InputRig.create(tester);
      await rig.pumpApp(tester, home: const Scaffold(body: McpPendingInputsInline(sessionId: 'chat-1')));
      unawaited(rig.handler.elicit(formRequest(const {}), inputContext()));
      unawaited(rig.handler.elicit(formRequest(const {}), inputContext(sessionId: 'chat-2')));
      await tester.pumpAndSettle();
      expect(find.byType(McpPendingInputCard), findsOneWidget);
      await tester.tap(find.descendant(of: find.byType(McpPendingInputCard), matching: find.text('Review')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Decline'));
      await tester.pumpAndSettle();
      expect(find.byType(McpPendingInputCard), findsNothing);
      for (final p in rig.runtime.inputQueue.pending) {
        (p as PendingFormElicitation).cancel();
      }
      await tester.pumpAndSettle();
    });
  });
}

extension on InputRig {
  bool get settingsChatAllowed => runtime.hostSettings.chatAllowed('srv', 'chat-1');
}
