import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa/routing/routes.dart';
import 'package:sherpa/services/mcp/input/elicitation_form.dart';
import 'package:sherpa/services/mcp/input/host_settings.dart';
import 'package:sherpa/services/mcp/input/input_history.dart';
import 'package:sherpa/services/mcp/input/input_queue.dart';
import 'package:sherpa_mcp/sherpa_mcp.dart';

import 'support/mcp_rig.dart';

void main() {
  testWidgets("the server's console lists its input requests, redacted", (tester) async {
    final rig = await McpRig.create(tester, remote: exampleServers());
    final c = await rig.addRemote(tester);
    final at = DateTime.utc(2026, 10, 19, 12, 30);
    rig.runtime.inputHistory
      ..add(McpInputRecord(
        at: at,
        serverId: c.id,
        kind: McpInputKind.form,
        outcome: McpInputOutcome.accepted,
        summary: McpInputHistory.formSummary(
          McpElicitRequest.fromJson({
            'message': 'Who are you? token=sk-abcdefghijklmnopqrstuvwxyz123456',
            'requestedSchema': {
              'type': 'object',
              'properties': {
                'name': {'type': 'string'},
              },
            },
          }),
          // Field names only: the answer is never part of a record.
          const ElicitationFormStub().form,
        ),
        toolName: 'example_tools__lookup',
      ))
      ..add(McpInputRecord(
        at: at,
        serverId: c.id,
        kind: McpInputKind.url,
        outcome: McpInputOutcome.declined,
        summary: McpInputHistory.urlSummary(
          McpElicitRequest.fromJson({'mode': 'url', 'message': 'x', 'url': 'https://auth.example.com/cb?code=SECRET'}),
        ),
      ))
      ..add(McpInputRecord(
        at: at,
        serverId: c.id,
        kind: McpInputKind.sampling,
        outcome: McpInputOutcome.refused,
        summary: '1 message, up to 100 tokens',
        reason: 'Using the model is turned off for this server in Sherpa.',
      ));
    await rig.pump(tester, location: Routes.toolServerConsole(c.id));
    expect(find.text('Requests for your input'), findsOneWidget);
    final text = find.textContaining('web page declined').evaluate().map((e) => e.widget.toString()).join();
    expect(text, contains('Open https://auth.example.com/cb (query removed)'));
    expect(text, isNot(contains('SECRET')));
    expect(text, isNot(contains('sk-abcdefghijklmnopqrstuvwxyz123456')), reason: 'server text is redacted');
    expect(text, contains('model use refused by Sherpa'));
    expect(text, contains('form answered (example_tools__lookup): Fields: name'));
  });

  testWidgets('server detail shows the MCP Apps and model-use sections for remote servers only', (tester) async {
    final rig = await McpRig.create(tester, remote: exampleServers());
    final c = await rig.addRemote(tester);
    await rig.pump(tester, location: Routes.toolServer(c.id));
    await scrollTo(tester, find.text('MCP Apps'));
    expect(find.text('It offers no interactive content.'), findsOneWidget);
    await scrollTo(tester, find.text('Use of your model'));
    expect(find.text('Off'), findsOneWidget);
    expect(rig.runtime.hostSettingsOf(c.id).sampling, McpSamplingMode.off);

    await rig.pump(tester, location: Routes.toolServer('memory'));
    expect(find.text('MCP Apps'), findsNothing);
    expect(find.text('Use of your model'), findsNothing);
  });

  testWidgets('"Delete all data" can wipe the M5 settings', (tester) async {
    final rig = await McpRig.create(tester, remote: exampleServers());
    final c = await rig.addRemote(tester);
    await tester.runAsync(() async {
      await rig.runtime.updateHostSettings(c.id, const McpServerHostSettings(sampling: McpSamplingMode.ask));
      await rig.runtime.hostSettings.setGrantedOrigins(c.id, 'h', {'https://a.example.com'});
      await rig.runtime.eraseInputData();
    });
    expect(rig.runtime.hostSettingsOf(c.id).sampling, McpSamplingMode.off);
    expect(rig.runtime.hostSettings.consentsOf(c.id), isEmpty);
    expect(rig.runtime.inputQueue.pending, isEmpty);
  });
}

/// A one-field form for [McpInputHistory.formSummary].
final class ElicitationFormStub {
  const ElicitationFormStub();

  ElicitationForm get form => ElicitationForm.parse(const {
        'type': 'object',
        'properties': {
          'name': {'type': 'string'},
        },
      });
}

Future<void> scrollTo(WidgetTester tester, Finder f) async {
  await tester.scrollUntilVisible(f, 300, scrollable: find.byType(Scrollable).first);
  await tester.pumpAndSettle();
}
