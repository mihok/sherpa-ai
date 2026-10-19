import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_webview/sherpa_webview.dart';
import 'package:sherpa_webview/testing.dart';

const _html = '<!DOCTYPE html><html><body>app</body></html>';

McpAppResource resource({Map<String, Object?>? csp}) => McpAppResource.fromContents(
      uri: 'ui://maps/view',
      mimeType: mcpAppMimeType,
      text: _html,
      contentMeta: csp == null ? null : {'ui': {'csp': csp}},
    );

Future<void> settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// A scripted host around one bridge.
final class Host {
  Host({
    McpAppLimits limits = const McpAppLimits(),
    bool links = true,
    bool messages = true,
    bool modelContext = true,
    bool resources = false,
    McpAppCsp? csp,
    Clock clock = const SystemClock(),
  }) {
    bridge = McpAppsBridge(
      channel: ch,
      session: McpAppSession(
        serverId: 'maps',
        serverName: 'Maps',
        resource: resource(),
        tool: const {'name': 'show_map', 'inputSchema': {'type': 'object'}},
        toolCallRequestId: 102,
        callId: 'c1',
      ),
      csp: csp ?? McpAppCsp.build(),
      limits: limits,
      clock: clock,
      hostContext: const McpAppHostContext(theme: McpAppTheme.dark, locale: 'en-US'),
      callbacks: McpAppHostCallbacks(
        lookupTool: (name) {
          lookups.add(name);
          if (lookupThrows) throw StateError('boom');
          return tools[name];
        },
        approveToolCall: (r) async {
          approvals.add(r);
          if (approveThrows) throw StateError('sheet crashed');
          return approve;
        },
        callTool: (c) async {
          calls.add(c);
          return execute(c);
        },
        confirmMessage: messages
            ? (r) async {
                proposed.add(r);
                return confirm;
              }
            : null,
        insertMessage: messages ? inserted.add : null,
        confirmOpenLink: links
            ? (r) async {
                linkPrompts.add(r);
                if (linkGate != null) await linkGate!.future;
                return confirm;
              }
            : null,
        launchLink: links
            ? (u) async {
                launched.add(u);
                return true;
              }
            : null,
        updateModelContext: modelContext ? contexts.add : null,
        readResource: resources ? (uri) async => {'contents': <Object?>[], 'uri': uri} : null,
        onLog: logs.add,
      ),
    );
    bridge.events.listen(events.add);
  }

  final FakeMcpAppChannel ch = FakeMcpAppChannel();
  late final McpAppsBridge bridge;
  final List<McpAppEvent> events = [];
  final List<String> lookups = [];
  final List<McpAppToolCallRequest> approvals = [];
  final List<McpAppToolCall> calls = [];
  final List<McpAppMessageRequest> proposed = [];
  final List<McpAppMessageRequest> inserted = [];
  final List<McpAppLinkRequest> linkPrompts = [];
  final List<Uri> launched = [];
  final List<McpAppModelContext> contexts = [];
  final List<McpAppLogEntry> logs = [];
  bool approve = true;
  bool approveThrows = false;
  bool lookupThrows = false;
  bool confirm = true;
  Completer<void>? linkGate;
  Future<ToolResult> Function(McpAppToolCall c) execute =
      (c) async => ToolResult(content: [TextPart('ran ${c.tool.name} ${jsonEncode(c.arguments)}')], structured: const {'ok': true});

  final Map<String, McpAppTool> tools = {
    'pan': const McpAppTool(name: 'pan', visibility: ['app']),
    'show_map': const McpAppTool(name: 'show_map'),
    'model_only': const McpAppTool(name: 'model_only', visibility: ['model']),
    'hidden': const McpAppTool(name: 'hidden', visibility: []),
    'alias': const McpAppTool(name: 'something_else'),
  };

  Future<void> start({bool handshake = true}) async {
    ch.shellReady();
    if (handshake) ch.handshake();
    await settle();
  }

  Future<Map<String, Object?>> request(Object id, String method, [Map<String, Object?>? params]) async {
    ch.viewRequest(id, method, params);
    await settle();
    return ch.responseTo(id)!;
  }
}

Map<String, Object?> resultOf(Map<String, Object?> response) => (response['result']! as Map).cast<String, Object?>();
int codeOf(Map<String, Object?> response) => (response['error']! as Map)['code']! as int;

void main() {
  group('shell bootstrap', () {
    test('ready → load with the HTML, limits and theme', () async {
      final h = Host();
      h.ch.shellReady();
      await settle();
      final load = h.ch.commands('load').single;
      expect(load['html'], _html);
      expect(load['theme'], 'dark');
      expect(load['title'], 'Content from Maps');
      expect((load['limits']! as Map)['maxChars'], 1024 * 1024);
      expect(h.bridge.state, McpAppBridgeState.loading);
      h.ch.shellReady();
      await settle();
      expect(h.ch.commands('load'), hasLength(1), reason: 'a second ready is ignored');
    });

    test('a shell without a valid CSP fails closed', () async {
      final h = Host();
      h.ch.shellReady(cspOk: false);
      await settle();
      expect(h.ch.commands('load'), isEmpty);
      expect(h.bridge.state, McpAppBridgeState.failed);
      expect(h.events.whereType<McpAppFailed>(), isNotEmpty);
      h.ch.handshake();
      await settle();
      expect(h.ch.toView, isEmpty, reason: 'nothing is answered after failure');
    });

    test('unknown shell protocol version fails', () async {
      final h = Host();
      h.ch.shellReady(version: 2);
      await settle();
      expect(h.bridge.state, McpAppBridgeState.failed);
    });

    test('View messages before the shell is ready are ignored', () async {
      final h = Host();
      h.ch.viewRequest(1, 'ping');
      await settle();
      expect(h.ch.sent, isEmpty);
    });

    test('malformed and oversized shell strings are dropped', () async {
      final h = Host(limits: const McpAppLimits(maxMessageBytes: 2048));
      await h.start();
      h.ch.shellRaw('not json');
      h.ch.shellRaw(jsonEncode({'kind': 'view', 'message': 'x' * 5000}));
      h.ch.viewRequest(9, 'ping', {'pad': 'x' * 4000});
      await settle();
      expect(h.ch.responseTo(9), isNull);
      expect(h.events.whereType<McpAppDropped>().map((e) => e.reason), containsAll(['malformed shell envelope', 'oversized']));
    });

    test('shell drop statistics surface as events', () async {
      final h = Host();
      await h.start();
      h.ch.shellRaw(jsonEncode({'kind': 'stats', 'forged': 2, 'malformed': 0, 'oversized': 1, 'rateLimited': 5}));
      await settle();
      expect(h.events.whereType<McpAppDropped>().single.count, 8);
    });
  });

  group('handshake', () {
    test('ui/initialize result: version, host info, capabilities, context', () async {
      final h = Host(csp: McpAppCsp.build(DeclaredDomains.fromCsp({
        'connectDomains': ['https://api.example.com'],
      })));
      h.ch.shellReady();
      await settle();
      final res = resultOf(await h.request('v1', 'ui/initialize', {
        'protocolVersion': '2026-01-26',
        'appInfo': {'name': 'Weather\u202E Dashboard', 'version': '1.2.0'},
        'appCapabilities': {
          'availableDisplayModes': ['inline', 'fullscreen', 'bogus'],
        },
      }));
      expect(res['protocolVersion'], '2026-01-26');
      expect(res['hostInfo'], {'name': 'sherpa', 'version': '0.1.0'});
      final caps = (res['hostCapabilities']! as Map).cast<String, Object?>();
      expect(caps.keys, containsAll(['openLinks', 'serverTools', 'logging', 'message', 'updateModelContext', 'sandbox']));
      expect(caps.containsKey('serverResources'), isFalse);
      expect(caps.containsKey('downloadFile'), isFalse);
      expect(caps.containsKey('sampling'), isFalse);
      expect(caps['sandbox'], {
        'permissions': <String, Object?>{},
        'csp': {
          'connectDomains': ['https://api.example.com'],
          'resourceDomains': <String>[],
        },
      });
      final ctx = (res['hostContext']! as Map).cast<String, Object?>();
      expect(ctx['theme'], 'dark');
      expect(ctx['platform'], 'mobile');
      expect(ctx['toolInfo'], {
        'id': 102,
        'tool': {'name': 'show_map', 'inputSchema': {'type': 'object'}},
      });
      expect(h.bridge.identity.appName, 'Weather Dashboard', reason: 'bidi controls stripped');
      expect(h.bridge.appDisplayModes, [McpAppDisplayMode.inline, McpAppDisplayMode.fullscreen]);
    });

    test('unsupported protocol version gets the latest', () async {
      final h = Host();
      h.ch.shellReady();
      await settle();
      final res = resultOf(await h.request(1, 'ui/initialize', {'protocolVersion': '2099-01-01'}));
      expect(res['protocolVersion'], latestProtocolVersion);
    });

    test('capabilities follow the callbacks the app provided', () async {
      final h = Host(links: false, messages: false, modelContext: false, resources: true);
      h.ch.shellReady();
      await settle();
      final caps = (resultOf(await h.request(1, 'ui/initialize'))['hostCapabilities']! as Map);
      expect(caps.containsKey('openLinks'), isFalse);
      expect(caps.containsKey('message'), isFalse);
      expect(caps.containsKey('updateModelContext'), isFalse);
      expect(caps.containsKey('serverResources'), isTrue);
    });

    test('requests before ui/initialize are refused (ping is fine)', () async {
      final h = Host();
      h.ch.shellReady();
      await settle();
      expect(resultOf(await h.request('p', 'ping')), isEmpty);
      expect(codeOf(await h.request('t', 'tools/call', {'name': 'pan'})), RpcCode.invalidRequest);
      expect(h.lookups, isEmpty);
    });
  });

  group('tool data ordering', () {
    test('nothing reaches the View before initialized; then input → result, once', () async {
      final h = Host();
      h.bridge.sendToolInputPartial({'q': 'Lis'});
      h.bridge.sendToolResult(const ToolResult(content: [TextPart('21°C')], structured: {'t': 21}));
      h.ch.shellReady();
      h.ch.viewRequest('v1', 'ui/initialize', {'protocolVersion': '2026-01-26'});
      await settle();
      expect(h.ch.toView, hasLength(1), reason: 'only the initialize response');
      h.ch.viewNotify('ui/notifications/initialized');
      await settle();
      expect(h.ch.toView, hasLength(2), reason: 'a partial; the result waits for tool-input');
      expect(h.ch.notifications('ui/notifications/tool-input-partial').single['params'], {
        'arguments': {'q': 'Lis'},
      });
      h.bridge.sendToolInputPartial({'q': 'Lisb'});
      h.bridge.sendToolInput({'q': 'Lisbon'});
      h.bridge.sendToolInput({'q': 'again'});
      h.bridge.sendToolInputPartial({'q': 'late'});
      h.bridge.sendToolResult(const ToolResult(content: [TextPart('again')]));
      await settle();
      final methods = [for (final m in h.ch.toView.skip(1)) m['method']];
      expect(methods, [
        'ui/notifications/tool-input-partial',
        'ui/notifications/tool-input-partial',
        'ui/notifications/tool-input',
        'ui/notifications/tool-result',
      ]);
      expect(h.ch.notifications('ui/notifications/tool-input').single['params'], {
        'arguments': {'q': 'Lisbon'},
      });
      expect(h.ch.notifications('ui/notifications/tool-result').single['params'], {
        'content': [
          {'type': 'text', 'text': '21°C'},
        ],
        'structuredContent': {'t': 21},
      });
    });

    test('cancelled instead of a result', () async {
      final h = Host();
      await h.start();
      h.bridge.sendToolInput(const {});
      h.bridge.sendToolCancelled('');
      h.bridge.sendToolResult(const ToolResult(content: []));
      await settle();
      expect(h.ch.notifications('ui/notifications/tool-cancelled').single['params'], {'reason': 'cancelled'});
      expect(h.ch.notifications('ui/notifications/tool-result'), isEmpty);
    });

    test('a reloaded View (second ui/initialize) gets the data again', () async {
      final h = Host();
      await h.start();
      h.bridge.sendToolInput({'a': 1});
      h.bridge.sendToolResultPart(const ToolResultPart(callId: 'c1', toolName: 't', content: [TextPart('r')]));
      await settle();
      h.ch.handshake(id: 'again');
      await settle();
      expect(h.ch.notifications('ui/notifications/tool-input'), hasLength(2));
      expect(h.ch.notifications('ui/notifications/tool-result'), hasLength(2));
    });

    test('host-context-changed carries only changed keys, after initialized', () async {
      final h = Host();
      h.ch.shellReady();
      await settle();
      h.bridge.updateHostContext(const McpAppHostContext(theme: McpAppTheme.light));
      expect(h.ch.notifications('ui/notifications/host-context-changed'), isEmpty);
      h.ch.handshake();
      await settle();
      h.bridge.updateHostContext(const McpAppHostContext(theme: McpAppTheme.light));
      h.bridge.updateHostContext(const McpAppHostContext(theme: McpAppTheme.dark, locale: 'de-DE'));
      await settle();
      final changes = h.ch.notifications('ui/notifications/host-context-changed');
      expect(changes.single['params'], {'theme': 'dark', 'locale': 'de-DE'});
      expect(h.ch.commands('context').map((c) => c['theme']), ['light', 'dark'], reason: 'shell colour scheme follows');
    });
  });

  group('tools/call: visibility and approval are enforced by the bridge', () {
    test('an app-only tool runs after approval; progress uses the View token; View _meta is not forwarded', () async {
      final h = Host();
      h.execute = (c) async {
        c.onProgress!(const ToolProgress(progress: 1, total: 2, message: 'half'));
        return const ToolResult(content: [TextPart('panned')], meta: {'ai.sherpa/serverId': 'maps', 'x': 1});
      };
      await h.start();
      final res = await h.request('v2', 'tools/call', {
        'name': 'pan',
        'arguments': {'dx': 3},
        '_meta': {'progressToken': 'v-pt-1', 'io.modelcontextprotocol/clientCapabilities': {'evil': true}},
      });
      expect(resultOf(res), {
        'content': [
          {'type': 'text', 'text': 'panned'},
        ],
        '_meta': {'x': 1},
      });
      expect(h.approvals.single.tool.name, 'pan');
      expect(h.approvals.single.identity.label, 'Test App (from Maps)');
      expect(h.approvals.single.arguments, {'dx': 3});
      final call = h.calls.single;
      expect(call.serverId, 'maps');
      expect(call.arguments, {'dx': 3});
      expect(h.ch.notifications('notifications/progress').single['params'],
          {'progressToken': 'v-pt-1', 'progress': 1.0, 'total': 2.0, 'message': 'half'});
    });

    test('default visibility (["model","app"]) is app-callable', () async {
      final h = Host();
      await h.start();
      expect(resultOf(await h.request(1, 'tools/call', {'name': 'show_map'}))['content'], isNotEmpty);
    });

    test('model-only, [] visibility, unknown, mismatched and failing lookups are refused without asking', () async {
      final h = Host();
      await h.start();
      for (final name in ['model_only', 'hidden', 'nope', 'alias']) {
        final r = await h.request('x-$name', 'tools/call', {'name': name});
        expect(codeOf(r), RpcCode.invalidParams, reason: name);
        expect((r['error']! as Map)['message'], 'Tool not callable from this app');
      }
      h.lookupThrows = true;
      expect(codeOf(await h.request('boom', 'tools/call', {'name': 'pan'})), RpcCode.invalidParams);
      expect(h.approvals, isEmpty);
      expect(h.calls, isEmpty);
    });

    test('a denied (or crashing) approval never executes', () async {
      final h = Host()..approve = false;
      await h.start();
      final r = resultOf(await h.request(1, 'tools/call', {'name': 'pan'}));
      expect(r['isError'], isTrue);
      h
        ..approve = true
        ..approveThrows = true;
      expect(resultOf(await h.request(2, 'tools/call', {'name': 'pan'}))['isError'], isTrue);
      expect(h.calls, isEmpty);
    });

    test('bad params, executor failure and timeout', () async {
      final h = Host(limits: const McpAppLimits(toolCallTimeout: Duration(milliseconds: 50)));
      await h.start();
      expect(codeOf(await h.request(1, 'tools/call', {'name': 7})), RpcCode.invalidParams);
      expect(codeOf(await h.request(2, 'tools/call', {'name': 'pan', 'arguments': 'x'})), RpcCode.invalidParams);
      h.execute = (c) async => throw StateError('server exploded with secret details');
      final failed = await h.request(3, 'tools/call', {'name': 'pan'});
      expect(codeOf(failed), RpcCode.internalError);
      expect(jsonEncode(failed), isNot(contains('secret')));
      late McpAppToolCall slow;
      h.execute = (c) {
        slow = c;
        return Completer<ToolResult>().future;
      };
      h.ch.viewRequest(4, 'tools/call', {'name': 'pan'});
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await settle();
      expect(codeOf(h.ch.responseTo(4)!), RpcCode.hostError);
      expect(slow.cancel.isCancelled, isTrue);
    });

    test('notifications/cancelled cancels the call and suppresses the response', () async {
      final h = Host();
      final gate = Completer<ToolResult>();
      h.execute = (c) {
        c.cancel.whenCancelled.then((_) => gate.completeError(const CancelledException()));
        return gate.future;
      };
      await h.start();
      h.ch.viewRequest(7, 'tools/call', {'name': 'pan'});
      await settle();
      h.ch.viewNotify('notifications/cancelled', {'requestId': 7});
      await settle();
      expect(h.calls.single.cancel.isCancelled, isTrue);
      expect(h.ch.responseTo(7), isNull);
    });

    test('concurrency cap', () async {
      final h = Host(limits: const McpAppLimits(maxConcurrentToolCalls: 2));
      h.execute = (c) => Completer<ToolResult>().future;
      await h.start();
      for (final id in [1, 2, 3]) {
        h.ch.viewRequest(id, 'tools/call', {'name': 'pan'});
      }
      await settle();
      expect(h.ch.responseTo(1), isNull);
      expect(h.ch.responseTo(2), isNull);
      expect(codeOf(h.ch.responseTo(3)!), RpcCode.hostError);
    });
  });

  group('links', () {
    test('https link: confirmed, then launched; never navigated in place', () async {
      final h = Host();
      await h.start();
      expect(resultOf(await h.request(1, 'ui/open-link', {'url': 'https://example.com/a'})), isEmpty);
      expect(h.linkPrompts.single.uri.toString(), 'https://example.com/a');
      expect(h.linkPrompts.single.fromAnchor, isFalse);
      expect(h.launched.single.toString(), 'https://example.com/a');
    });

    test('declined → isError, no launch', () async {
      final h = Host()..confirm = false;
      await h.start();
      expect(resultOf(await h.request(1, 'ui/open-link', {'url': 'https://example.com/a'})), {'isError': true});
      expect(h.launched, isEmpty);
    });

    test('disallowed schemes are refused before the user is asked', () async {
      final h = Host();
      await h.start();
      for (final (i, url) in ['javascript:alert(1)', 'intent://x', 'file:///etc/hosts', 'http://example.com', 42].indexed) {
        expect(resultOf(await h.request('l$i', 'ui/open-link', {'url': url})), {'isError': true});
      }
      expect(h.linkPrompts, isEmpty);
    });

    test('anchor activations from the shell prelude take the same path (no response)', () async {
      final h = Host();
      await h.start();
      h.ch.viewNotify(McpAppMethods.linkActivated, {'url': 'https://example.com/b'});
      h.ch.viewNotify(McpAppMethods.linkActivated, {'url': 'javascript:void(0)'});
      await settle();
      expect(h.linkPrompts.single.fromAnchor, isTrue);
      expect(h.launched.single.toString(), 'https://example.com/b');
    });

    test('one prompt at a time; unsupported when the app has no link callbacks', () async {
      final h = Host()..linkGate = Completer<void>();
      await h.start();
      h.ch.viewRequest(1, 'ui/open-link', {'url': 'https://example.com/1'});
      await settle();
      expect(resultOf(await h.request(2, 'ui/open-link', {'url': 'https://example.com/2'})), {'isError': true});
      h.linkGate!.complete();
      await settle();
      expect(resultOf(h.ch.responseTo(1)!), isEmpty);
      final n = Host(links: false);
      await n.start();
      expect(resultOf(await n.request(1, 'ui/open-link', {'url': 'https://example.com'})), {'isError': true});
    });
  });

  group('ui/message', () {
    test('inserted only after the user confirms', () async {
      final h = Host();
      await h.start();
      final r = await h.request(1, 'ui/message', {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': 'Book it'},
          {'type': 'text', 'text': 'for two'},
        ],
      });
      expect(resultOf(r), isEmpty);
      expect(h.proposed.single.text, 'Book it\n\nfor two');
      expect(h.inserted.single.content, hasLength(2));
      h.confirm = false;
      expect(resultOf(await h.request(2, 'ui/message', {
        'role': 'user',
        'content': {'type': 'text', 'text': 'spec-prose single block'},
      })), {'isError': true});
      expect(h.proposed, hasLength(2));
      expect(h.inserted, hasLength(1));
    });

    test('validation: role, text only, size, empty, unsupported', () async {
      final h = Host(limits: const McpAppLimits(maxMessageTextChars: 10));
      await h.start();
      Future<int> code(Map<String, Object?> p) async => codeOf(await h.request('m${p.hashCode}', 'ui/message', p));
      expect(await code({'role': 'assistant', 'content': [{'type': 'text', 'text': 'x'}]}), RpcCode.invalidParams);
      expect(await code({'role': 'user', 'content': [{'type': 'image', 'data': 'x', 'mimeType': 'image/png'}]}),
          RpcCode.invalidParams);
      expect(await code({'role': 'user', 'content': [{'type': 'text', 'text': 'x' * 11}]}), RpcCode.invalidParams);
      expect(await code({'role': 'user', 'content': [{'type': 'text', 'text': '  '}]}), RpcCode.invalidParams);
      expect(h.proposed, isEmpty);
      final n = Host(messages: false);
      await n.start();
      expect(codeOf(await n.request(1, 'ui/message', {'role': 'user', 'content': <Object?>[]})), RpcCode.methodNotFound);
    });
  });

  group('other requests', () {
    test('update-model-context: stored, size-capped', () async {
      final h = Host(limits: const McpAppLimits(maxModelContextBytes: 200));
      await h.start();
      expect(resultOf(await h.request(1, 'ui/update-model-context', {
        'content': [
          {'type': 'text', 'text': 'selected: Lisbon'},
          {'type': 'image', 'data': 'x'},
        ],
        'structuredContent': {'city': 'Lisbon'},
      })), isEmpty);
      expect(h.contexts.single.content, [
        {'type': 'text', 'text': 'selected: Lisbon'},
      ]);
      expect(h.contexts.single.structuredContent, {'city': 'Lisbon'});
      expect(codeOf(await h.request(2, 'ui/update-model-context', {'structuredContent': {'x': 'y' * 300}})),
          RpcCode.invalidParams);
      final n = Host(modelContext: false);
      await n.start();
      expect(codeOf(await n.request(1, 'ui/update-model-context', const {})), RpcCode.methodNotFound);
    });

    test('request-display-mode: only declared and offered modes', () async {
      final h = Host();
      final asked = <McpAppDisplayMode>[];
      h.bridge.onRequestDisplayMode = (m) async {
        asked.add(m);
        return m;
      };
      h.ch.shellReady();
      h.ch.handshake(displayModes: const ['inline', 'fullscreen']);
      await settle();
      expect(resultOf(await h.request(1, 'ui/request-display-mode', {'mode': 'pip'})), {'mode': 'inline'});
      expect(resultOf(await h.request(2, 'ui/request-display-mode', {'mode': 'fullscreen'})), {'mode': 'fullscreen'});
      expect(asked, [McpAppDisplayMode.fullscreen]);
      expect(h.ch.notifications('ui/notifications/host-context-changed').last['params'], {'displayMode': 'fullscreen'});
      expect(codeOf(await h.request(3, 'ui/request-display-mode', {'mode': 'huge'})), RpcCode.invalidParams);

      final undeclared = Host();
      undeclared.bridge.onRequestDisplayMode = (m) async => m;
      undeclared.ch.shellReady();
      undeclared.ch.handshake(displayModes: const []);
      await settle();
      expect(resultOf(await undeclared.request(1, 'ui/request-display-mode', {'mode': 'fullscreen'})),
          {'mode': 'inline'});
    });

    test('unsupported methods get -32601', () async {
      final h = Host();
      await h.start();
      for (final m in ['ui/download-file', 'sampling/createMessage', 'resources/list', 'prompts/list', 'resources/read', 'x']) {
        expect(codeOf(await h.request(m, m)), RpcCode.methodNotFound, reason: m);
      }
    });

    test('resources/read only when the app allows it', () async {
      final h = Host(resources: true);
      await h.start();
      expect(resultOf(await h.request(1, 'resources/read', {'uri': 'ui://maps/other'}))['uri'], 'ui://maps/other');
      expect(codeOf(await h.request(2, 'resources/read', {'uri': 3})), RpcCode.invalidParams);
    });

    test('requests are rate-limited', () async {
      final h = Host(limits: const McpAppLimits(requestBurst: 5, requestsPerSecond: 0.001));
      await h.start();
      for (var i = 0; i < 10; i++) {
        h.ch.viewRequest('r$i', 'ping');
      }
      await settle();
      final codes = [
        for (var i = 0; i < 10; i++) h.ch.responseTo('r$i')!.containsKey('error') ? codeOf(h.ch.responseTo('r$i')!) : 0,
      ];
      // The handshake used one token.
      expect(codes.where((c) => c == 0), hasLength(4));
      expect(codes.where((c) => c == RpcCode.hostError), hasLength(6));
    });
  });

  group('notifications', () {
    test('size-changed is validated and coalesced', () async {
      final h = Host();
      await h.start();
      for (final p in <Map<String, Object?>>[
        {'width': 360, 'height': 412},
        {'width': 360, 'height': 412},
        {'height': 412},
        {'height': -1},
        {'height': 1e9},
        {'height': 'tall'},
        {'height': 500},
      ]) {
        h.ch.viewNotify('ui/notifications/size-changed', p);
      }
      await settle();
      final sizes = h.events.whereType<McpAppSizeChanged>().map((e) => e.height).toList();
      expect(sizes, [412, 500]);
    });

    test('logs are truncated and capped per minute', () async {
      final clock = FakeClock();
      final h = Host(limits: const McpAppLimits(maxLogsPerMinute: 3, maxLogChars: 10), clock: clock);
      await h.start();
      for (var i = 0; i < 5; i++) {
        h.ch.viewNotify('notifications/message', {'level': 'info', 'data': 'line $i ${'x' * 20}'});
      }
      await settle();
      expect(h.logs, hasLength(3));
      expect(h.logs.first.data, 'line 0 xxx…');
      clock.advance(const Duration(minutes: 1));
      h.ch.viewNotify('notifications/message', {'level': 'warning', 'data': {'k': 1}});
      await settle();
      expect(h.logs.last.data, '{"k":1}');
    });

    test('request-teardown surfaces as an event', () async {
      final h = Host();
      await h.start();
      h.ch.viewNotify('ui/notifications/request-teardown');
      await settle();
      expect(h.events.whereType<McpAppTeardownRequested>(), hasLength(1));
    });
  });

  group('teardown', () {
    test('sends ui/resource-teardown, awaits the answer, then removes the frame', () async {
      final h = Host();
      await h.start();
      final done = h.bridge.teardown();
      await settle();
      final req = h.ch.toView.last;
      expect(req['method'], 'ui/resource-teardown');
      expect(req['params'], <String, Object?>{});
      expect(h.ch.commands('teardown'), isEmpty, reason: 'waits for the View');
      h.ch.fromView({'jsonrpc': '2.0', 'id': req['id'], 'result': <String, Object?>{}});
      await done;
      expect(h.ch.commands('teardown'), hasLength(1));
      expect(h.bridge.state, McpAppBridgeState.tornDown);
      h.ch.viewRequest('late', 'ping');
      await settle();
      expect(h.ch.responseTo('late'), isNull, reason: 'nothing is served after teardown');
    });

    test('times out, and cancels in-flight calls', () async {
      final h = Host(limits: const McpAppLimits(teardownTimeout: Duration(milliseconds: 30)));
      h.execute = (c) => Completer<ToolResult>().future;
      await h.start();
      h.ch.viewRequest(1, 'tools/call', {'name': 'pan'});
      await settle();
      await h.bridge.dispose();
      expect(h.ch.commands('teardown'), hasLength(1));
      expect(h.calls.single.cancel.isCancelled, isTrue);
      expect(h.ch.closed, isTrue);
    });

    test('before initialization there is no teardown request', () async {
      final h = Host();
      h.ch.shellReady();
      await settle();
      await h.bridge.teardown();
      expect(h.ch.toView, isEmpty);
      expect(h.ch.commands('teardown'), hasLength(1));
    });
  });
}
