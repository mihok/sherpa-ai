import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa/design/theme.dart';
import 'package:sherpa/features/apps/app_prompts.dart';
import 'package:sherpa/features/mcp/consent_sheet.dart';
import 'package:sherpa/features/mcp/session_tools_sheet.dart';
import 'package:sherpa/routing/routes.dart';
import 'package:sherpa/services/mcp/input/host_settings.dart';
import 'package:sherpa/services/mcp/server_probe.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_mcp/sherpa_mcp.dart';
import 'package:sherpa_webview/sherpa_webview.dart';

import '../features/mcp/support/input_rig.dart' show InputRig, formRequest, inputContext, samplingRequest;
import '../features/mcp/support/mcp_rig.dart';
import '../support/a11y_audit.dart';

// Where textContrastGuideline is skipped (the exact check still runs; see
// auditScreen), and what it misread there.
const _small = '12–13 px text at 1×: anti-aliasing shades, or the neighbouring surface, win the pixel sample';
const _underFab = 'a heading under the floating "Add a server" button at the first scroll position';
const _oneX = {AuditView.phone1x, AuditView.tablet1x};

/// M6 audit of Tools & servers (MCP): the server list, adding one, the
/// registry, a server, its console, tool review, approvals, sign-in
/// consent, the chat's tools sheet, the input sheets (forms, web pages,
/// sampling) and MCP Apps' prompts (see [auditScreen]).
void main() {
  Future<McpRig> rigAt(WidgetTester tester, AuditView view, {String? location, bool server = true, McpRig? rig}) async {
    final r = rig ?? await McpRig.create(tester, remote: exampleServers(), mode: view.themeMode);
    if (server) await r.addRemote(tester);
    await r.pump(tester, size: view.size, textScale: view.textScale, location: location);
    return r;
  }

  auditScreen('tools & servers', (tester, view) async => rigAt(tester, view, location: Routes.tools),
      pixelContrastSkip: {AuditView.phone2x}, contrastNote: _underFab);
  auditScreen('tools & servers, built-ins only', (tester, view) async => rigAt(tester, view, location: Routes.tools, server: false));
  auditScreen('add a server', (tester, view) async => rigAt(tester, view, location: Routes.addServer, server: false),
      pixelContrastSkip: {AuditView.tablet1x}, contrastNote: _small);
  auditScreen('add a server: checked', (tester, view) async {
    final rig = await McpRig.create(
      tester,
      remote: exampleServers(),
      mode: view.themeMode,
      prober: FakeProber({toolsUrl: const McpProbeReport(era: McpEra.modern, serverName: 'Example tools', toolCount: 2)}),
    );
    await rigAt(tester, view, location: Routes.addServerWith(url: toolsUrl, source: 'link'), server: false, rig: rig);
    final check = find.text('Check server');
    await tester.ensureVisible(check);
    await rig.tap(tester, check);
  }, pixelContrastSkip: {AuditView.tablet1x}, contrastNote: _small);
  auditScreen('MCP Registry', (tester, view) async {
    final rig = await McpRig.create(tester, registryHttp: registryMock([]), mode: view.themeMode);
    await rigAt(tester, view, location: Routes.toolRegistry, server: false, rig: rig);
    await rig.settle(tester);
  }, pixelContrastSkip: {AuditView.tablet1x}, contrastNote: _small);
  auditScreen('MCP Registry, unreachable', (tester, view) async {
    final rig = await McpRig.create(tester, mode: view.themeMode, registryHttp: _failingRegistry());
    await rigAt(tester, view, location: Routes.toolRegistry, server: false, rig: rig);
    await rig.settle(tester);
  }, pixelContrastSkip: {AuditView.tablet1x}, contrastNote: _small);
  auditScreen('server detail', (tester, view) async => rigAt(tester, view, location: Routes.toolServer('example_tools')));
  auditScreen('server detail, built in', (tester, view) async => rigAt(tester, view, location: Routes.toolServer('memory')));
  auditScreen('server not found', (tester, view) async => rigAt(tester, view, location: Routes.toolServer('gone'), server: false));
  auditScreen('server console', (tester, view) async => rigAt(tester, view, location: Routes.toolServerConsole('example_tools')));
  auditScreen('review a new tool', (tester, view) async {
    await rigAt(tester, view, location: Routes.toolReview('example_tools', 'lookup'));
  });
  auditScreen('remove server dialog', (tester, view) async {
    final rig = await rigAt(tester, view, location: Routes.toolServer('example_tools'));
    await tester.scrollUntilVisible(find.text('Remove server'), 200, scrollable: find.byType(Scrollable).first);
    await rig.tap(tester, find.text('Remove server'));
  });
  auditScreen('remembered approvals', (tester, view) async {
    final rig = await McpRig.create(tester, remote: exampleServers(), mode: view.themeMode);
    await rig.addRemote(tester, trusted: true);
    final send = rig.runtime.router.lookup('example_tools__send')!;
    rig.runtime.policy.recordFor(
      send,
      's1',
      const ApprovalResponse(UserDecision.approve, scope: ApprovalScope.session, expiresIn: Duration(hours: 2)),
    );
    rig.runtime.policy.recordFor(
      rig.runtime.router.lookup('memory__save_note')!,
      's1',
      const ApprovalResponse(UserDecision.approve, scope: ApprovalScope.always),
    );
    await rigAt(tester, view, location: Routes.toolApprovals, server: false, rig: rig);
  });
  auditScreen('remembered approvals, none', (tester, view) async {
    await rigAt(tester, view, location: Routes.toolApprovals, server: false);
  });

  auditScreen('sign-in consent sheet', (tester, view) async {
    final rig = await rigAt(tester, view, location: Routes.tools, server: false);
    unawaited(showOAuthConsentSheet(
      tester.element(find.byType(Scaffold).last),
      const OAuthConsentDetails(
        title: 'Sign in to Docs',
        intro: 'This tool server needs you to sign in before Sherpa can use it.',
        serverLabel: 'Docs',
        serverHost: 'docs.example.com',
        authorizationOrigin: 'https://login.example.net',
        scopes: ['openid', 'docs.read'],
        selfDescribedName: 'Docs (official)',
        warnings: ['You will sign in at login.example.net, a different site from the server (docs.example.com).'],
        steps: ['Sherpa opens login.example.net in a secure browser window.', 'You can sign out any time.'],
      ),
    ));
    await rig.settle(tester);
  });

  auditScreen("a chat's tools sheet", (tester, view) async {
    final rig = await McpRig.create(tester, remote: exampleServers(), mode: view.themeMode);
    await rig.addRemote(tester, trusted: true);
    setAuditWindow(tester, view);
    await tester.pumpWidget(ProviderScope(
      overrides: rig.overrides,
      child: MaterialApp(
        theme: SherpaTheme.light(),
        darkTheme: SherpaTheme.dark(),
        themeMode: view.themeMode,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => SessionToolsSheet.show(context, sessionId: 'chat-1', onManage: () {}),
                child: const Text('Tools'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Tools'));
    await tester.pumpAndSettle();
  }, pixelContrastSkip: _oneX, contrastNote: _small);

  // ---- input requests from servers -----------------------------------

  Future<InputRig> inputRig(WidgetTester tester, AuditView view) async {
    final rig = await InputRig.create(tester);
    await rig.pumpApp(tester, size: view.size, textScale: view.textScale, themeMode: view.themeMode);
    return rig;
  }

  // Requests wait 5 minutes for an answer; let them time out politely.
  Future<void> expire(WidgetTester tester) async {
    await tester.pump(const Duration(minutes: 6));
    await tester.pumpAndSettle();
  }

  Future<void> review(WidgetTester tester) async {
    await tester.pumpAndSettle();
    await tester.tap(find.text('Review'));
    await tester.pumpAndSettle();
  }

  auditScreen('input request banner', (tester, view) async {
    final rig = await inputRig(tester, view);
    unawaited(rig.handler.elicit(formRequest({'name': {'type': 'string', 'title': 'Your name'}}), inputContext()));
    await tester.pumpAndSettle();
  }, requireHeading: false, cleanup: expire);

  auditScreen('form request sheet', (tester, view) async {
    final rig = await inputRig(tester, view);
    unawaited(rig.handler.elicit(
      formRequest({
        'name': {'type': 'string', 'title': 'Your name', 'description': 'As it appears on your account'},
        'born': {'type': 'string', 'format': 'date', 'title': 'Birthday'},
        'age': {'type': 'integer', 'title': 'Age'},
        'agree': {'type': 'boolean', 'title': 'I agree to the terms'},
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
          'items': {'type': 'string', 'enum': ['work', 'home']},
        },
      }, required: ['name', 'plan'], message: 'Tell us about you'),
      inputContext(),
    ));
    await review(tester);
  }, cleanup: expire, pixelContrastSkip: {..._oneX, AuditView.phoneDark}, contrastNote: _small);

  auditScreen('web page request sheet', (tester, view) async {
    final rig = await inputRig(tester, view);
    unawaited(rig.handler.elicit(
      McpElicitRequest.fromJson({'mode': 'url', 'message': 'Connect your account', 'url': 'http://xn--pple-43d.com/pay'}),
      inputContext(),
    ));
    await review(tester);
  }, cleanup: expire, pixelContrastSkip: {AuditView.phone1x}, contrastNote: _small);

  auditScreen('sampling request sheet', (tester, view) async {
    final rig = await inputRig(tester, view);
    await tester.runAsync(() => rig.runtime.hostSettings.update('srv', const McpServerHostSettings(sampling: McpSamplingMode.ask)));
    unawaited(rig.handler.createMessage(samplingRequest(systemPrompt: 'Answer briefly.'), inputContext()).then<void>((_) {}, onError: (Object _) {}));
    await review(tester);
  }, cleanup: expire);

  // ---- MCP Apps' prompts ---------------------------------------------

  const identity = McpAppIdentity(serverId: 'srv', serverName: 'Example tools', appName: 'Planner');
  Future<BuildContext> appHost(WidgetTester tester, AuditView view) async {
    setAuditWindow(tester, view);
    await tester.pumpWidget(MaterialApp(
      theme: SherpaTheme.light(),
      darkTheme: SherpaTheme.dark(),
      themeMode: view.themeMode,
      home: const Scaffold(body: SizedBox.expand()),
    ));
    return tester.element(find.byType(SizedBox).last);
  }

  auditScreen('app: send a message', (tester, view) async {
    final c = await appHost(tester, view);
    unawaited(showAppMessageSheet(c, const McpAppMessageRequest(identity: identity, text: 'Book the 9:40 train.', content: [])));
    await tester.pumpAndSettle();
  }, pixelContrastSkip: _oneX, contrastNote: _small);
  auditScreen('app: open a link', (tester, view) async {
    final c = await appHost(tester, view);
    unawaited(showAppLinkSheet(c, McpAppLinkRequest(identity: identity, uri: Uri.parse('http://198.51.100.7/pay?x=1'))));
    await tester.pumpAndSettle();
  }, pixelContrastSkip: _oneX, contrastNote: _small);
  auditScreen('app: use the internet', (tester, view) async {
    final c = await appHost(tester, view);
    unawaited(showAppNetworkSheet(
      c,
      McpAppNetworkRequest(
        serverId: 'srv',
        serverName: 'Example tools',
        resourceUri: 'ui://planner/view',
        resourceSha256: 'abc',
        declared: DeclaredDomains.fromCsp({
          'connectDomains': ['https://api.example.com'],
          'resourceDomains': ['https://cdn.example.com', 'javascript:alert(1)'],
        }),
      ),
    ));
    await tester.pumpAndSettle();
  }, pixelContrastSkip: {AuditView.tablet1x}, contrastNote: _small);
  auditScreen('app: run a tool', (tester, view) async {
    final c = await appHost(tester, view);
    unawaited(showAppToolApprovalSheet(
      c,
      request: const McpAppToolCallRequest(identity: identity, tool: McpAppTool(name: 'book', title: 'Book a train'), arguments: {'train': '9:40'}),
      tool: const ToolDefinition(name: 'srv__book', description: 'Books a train.', inputSchema: {'type': 'object'}),
      requirement: const NeedsConfirmation(RiskLevel.destructive, 'Booking spends money.'),
    ));
    await tester.pumpAndSettle();
  });
}

/// A registry that can't be reached.
http.Client _failingRegistry() => MockClient((r) async => throw http.ClientException('offline'));
