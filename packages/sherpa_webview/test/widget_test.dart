import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_webview/sherpa_webview.dart';
import 'package:sherpa_webview/testing.dart';

McpAppResource _resource({Map<String, Object?>? csp, bool? prefersBorder}) => McpAppResource.fromContents(
      uri: 'ui://maps/view',
      mimeType: mcpAppMimeType,
      text: '<p>map</p>',
      contentMeta: {
        'ui': {'csp': ?csp, 'prefersBorder': ?prefersBorder},
      },
    );

McpAppHostCallbacks _callbacks({Future<Set<String>> Function(McpAppNetworkRequest r)? network}) => McpAppHostCallbacks(
      lookupTool: (name) => McpAppTool(name: name, visibility: const ['app']),
      approveToolCall: (_) async => true,
      callTool: (_) async => ToolResult.text('ok'),
      requestNetworkAccess: network,
    );

Widget _host(Widget child, {Brightness brightness = Brightness.light}) => MaterialApp(
      theme: ThemeData(brightness: brightness),
      home: Scaffold(body: ListView(children: [child])),
    );

void main() {
  setUp(McpAppController.resetProfileCountsForTest);

  Future<void> flush(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
  }

  // close() may wait for the teardown timeout, a timer: advance fake time.
  Future<void> closeAll(WidgetTester tester, McpAppController c) async {
    final done = c.close();
    await tester.pump(const Duration(seconds: 2));
    await done;
  }

  testWidgets('loading → ready, with the host label and the requested height', (tester) async {
    final platform = FakeMcpAppPlatform();
    final c = McpAppController(
      session: McpAppSession(serverId: 'maps', serverName: 'Maps', resource: _resource()),
      callbacks: _callbacks(),
      platform: platform,
    );
    await tester.pumpWidget(_host(McpAppView(controller: c, maxHeight: 400)));
    expect(find.text('Content from Maps'), findsOneWidget);
    await flush(tester);
    expect(c.status, McpAppViewStatus.loading);
    final view = platform.last;
    expect(find.byKey(FakeMcpAppNativeView.placeholderKey(view.viewId)), findsOneWidget);
    expect(find.text('Loading interactive content…'), findsOneWidget);
    expect(view.config.csp, McpAppCsp.build().policy);
    expect(view.config.allowedOrigins, isEmpty);
    expect(view.config.profileKey, McpAppNativeViewConfig.profileKeyFor('maps'));

    view.fake
      ..shellReady()
      ..frameLoaded();
    await flush(tester);
    expect(c.status, McpAppViewStatus.ready);
    expect(find.text('Loading interactive content…'), findsNothing);
    expect(view.fake.commands('load').single['html'], '<p>map</p>');

    view.fake
      ..handshake()
      ..viewNotify('ui/notifications/size-changed', {'height': 300});
    await flush(tester);
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.getSize(find.byKey(FakeMcpAppNativeView.placeholderKey(view.viewId))).height, 300);
    view.fake.viewNotify('ui/notifications/size-changed', {'height': 5000});
    await flush(tester);
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.getSize(find.byKey(FakeMcpAppNativeView.placeholderKey(view.viewId))).height, 400, reason: 'clamped');

    // Inline: only taps, long presses and horizontal drags reach the WebView.
    expect(view.lastGestures.length, 3);

    // The handshake reported the inline container.
    final init = view.fake.responseTo('init')!;
    final ctx = ((init['result']! as Map)['hostContext']! as Map);
    expect(ctx['displayMode'], 'inline');
    expect(ctx['theme'], 'light');
    expect(ctx['locale'], 'en-US');
    await closeAll(tester, c);
  });

  testWidgets('dark theme reaches the View', (tester) async {
    final platform = FakeMcpAppPlatform();
    final c = McpAppController(
      session: McpAppSession(serverId: 'maps', serverName: 'Maps', resource: _resource()),
      callbacks: _callbacks(),
      platform: platform,
    );
    await tester.pumpWidget(_host(McpAppView(controller: c), brightness: Brightness.dark));
    await flush(tester);
    platform.last.fake
      ..shellReady()
      ..handshake();
    await flush(tester);
    expect(platform.last.fake.commands('load').single['theme'], 'dark');
    final ctx = (platform.last.fake.responseTo('init')!['result']! as Map)['hostContext']! as Map;
    expect(ctx['theme'], 'dark');
    await closeAll(tester, c);
  });

  testWidgets('error state with fallback, retry replays the tool data into a new view', (tester) async {
    final platform = FakeMcpAppPlatform();
    final c = McpAppController(
      session: McpAppSession(serverId: 'maps', serverName: 'Maps', resource: _resource()),
      callbacks: _callbacks(),
      platform: platform,
    )
      ..setToolInput({'city': 'Lisbon'})
      ..setToolResult(ToolResult.text('21°C'));
    await tester.pumpWidget(_host(McpAppView(controller: c, fallback: const Text('Lisbon: 21°C, clear'))));
    await flush(tester);
    final first = platform.last;
    first.fake.shellReady();
    first.emit(NativeViewEventKind.renderProcessGone);
    await flush(tester);
    expect(c.status, McpAppViewStatus.error);
    expect(find.text('The interactive view stopped.'), findsOneWidget);
    expect(find.text('Lisbon: 21°C, clear'), findsOneWidget);
    expect(first.disposed, isTrue);

    await tester.tap(find.text('Retry'));
    await flush(tester);
    expect(platform.views, hasLength(2));
    final second = platform.last;
    second.fake
      ..shellReady()
      ..handshake();
    await flush(tester);
    expect(second.fake.notifications('ui/notifications/tool-input').single['params'], {
      'arguments': {'city': 'Lisbon'},
    });
    expect(second.fake.notifications('ui/notifications/tool-result'), hasLength(1));
    await closeAll(tester, c);
  });

  testWidgets('unsupported platform shows an error, no view is created', (tester) async {
    final platform = FakeMcpAppPlatform(supported: false, reason: 'No WebView on this device.');
    final c = McpAppController(
      session: McpAppSession(serverId: 'maps', serverName: 'Maps', resource: _resource()),
      callbacks: _callbacks(),
      platform: platform,
    );
    await tester.pumpWidget(_host(McpAppView(controller: c)));
    await flush(tester);
    expect(c.status, McpAppViewStatus.error);
    expect(find.text('No WebView on this device.'), findsOneWidget);
    expect(platform.views, isEmpty);
    await closeAll(tester, c);
  });

  testWidgets('a View that never loads times out into the error state', (tester) async {
    final platform = FakeMcpAppPlatform();
    final c = McpAppController(
      session: McpAppSession(serverId: 'maps', serverName: 'Maps', resource: _resource()),
      callbacks: _callbacks(),
      platform: platform,
      loadTimeout: const Duration(seconds: 3),
    );
    await tester.pumpWidget(_host(McpAppView(controller: c)));
    await flush(tester);
    await tester.pump(const Duration(seconds: 4));
    expect(c.status, McpAppViewStatus.error);
    expect(find.text('The interactive view did not load.'), findsOneWidget);
    await closeAll(tester, c);
  });

  testWidgets('network consent: asked first, only granted declared origins reach native', (tester) async {
    final platform = FakeMcpAppPlatform();
    final asked = Completer<Set<String>>();
    McpAppNetworkRequest? request;
    final c = McpAppController(
      session: McpAppSession(
        serverId: 'weather',
        serverName: 'Weather',
        resource: _resource(csp: {
          'connectDomains': ['https://api.example.com', 'https://evil.example.com', 'http://x.example.com'],
        }),
      ),
      callbacks: _callbacks(network: (r) {
        request = r;
        return asked.future;
      }),
      platform: platform,
    );
    await tester.pumpWidget(_host(McpAppView(controller: c)));
    await flush(tester);
    expect(c.status, McpAppViewStatus.consent);
    expect(find.text('Waiting for your network decision…'), findsOneWidget);
    expect([for (final o in request!.declared.connect) o.source], ['https://api.example.com', 'https://evil.example.com']);
    expect(request!.declared.rejected, ['http://x.example.com']);
    expect(request!.resourceSha256, hasLength(64));
    asked.complete({'https://api.example.com', 'https://not-declared.example.com'});
    await flush(tester);
    final config = platform.last.config;
    expect(config.allowedOrigins, ['https://api.example.com']);
    expect(config.csp, contains('connect-src https://api.example.com;'));
    expect(c.grantedOrigins, {'https://api.example.com', 'https://not-declared.example.com'});
    await closeAll(tester, c);
  });

  testWidgets('fullscreen moves the same platform view into a route and back', (tester) async {
    final platform = FakeMcpAppPlatform();
    final c = McpAppController(
      session: McpAppSession(serverId: 'maps', serverName: 'Maps', resource: _resource()),
      callbacks: _callbacks(),
      platform: platform,
    );
    await tester.pumpWidget(_host(McpAppView(controller: c)));
    await flush(tester);
    final view = platform.last;
    view.fake
      ..shellReady()
      ..frameLoaded()
      ..handshake();
    await flush(tester);
    expect(view.mounts, 1);

    await tester.tap(find.byTooltip('Open full screen'));
    await tester.pumpAndSettle();
    expect(c.displayMode, McpAppDisplayMode.fullscreen);
    expect(find.byType(McpAppFullscreenPage), findsOneWidget);
    expect(find.byKey(FakeMcpAppNativeView.placeholderKey(view.viewId)), findsOneWidget);
    expect(view.mounts, 1, reason: 'reparented, not recreated');
    expect(view.lastGestures.single.constructor(), isA<EagerGestureRecognizer>(), reason: 'fullscreen: all gestures');
    final changes = view.fake.notifications('ui/notifications/host-context-changed');
    expect(changes.map((m) => (m['params']! as Map)['displayMode']), contains('fullscreen'));
    final dims = changes.lastWhere((m) => (m['params']! as Map).containsKey('containerDimensions'));
    expect(((dims['params']! as Map)['containerDimensions']! as Map).containsKey('height'), isTrue,
        reason: 'fullscreen: fixed height');

    await tester.tap(find.byType(CloseButton));
    await tester.pumpAndSettle();
    expect(c.displayMode, McpAppDisplayMode.inline);
    expect(find.byType(McpAppFullscreenPage), findsNothing);
    expect(find.byKey(FakeMcpAppNativeView.placeholderKey(view.viewId)), findsOneWidget);
    expect(view.mounts, 1);
    expect(view.disposed, isFalse);

    // The View asks for fullscreen itself.
    view.fake.viewRequest('dm', 'ui/request-display-mode', {'mode': 'fullscreen'});
    await tester.pumpAndSettle();
    expect((view.fake.responseTo('dm')!['result']! as Map)['mode'], 'fullscreen');
    expect(find.byType(McpAppFullscreenPage), findsOneWidget);
    view.fake.viewRequest('dm2', 'ui/request-display-mode', {'mode': 'inline'});
    await tester.pumpAndSettle();
    expect(find.byType(McpAppFullscreenPage), findsNothing);
    expect(view.mounts, 1);
    await closeAll(tester, c);
  });

  testWidgets('removing the widget releases the WebView; showing it again re-renders', (tester) async {
    final platform = FakeMcpAppPlatform();
    final c = McpAppController(
      session: McpAppSession(serverId: 'maps', serverName: 'Maps', resource: _resource()),
      callbacks: _callbacks(),
      platform: platform,
    )..setToolInput(const {'a': 1});
    await tester.pumpWidget(_host(McpAppView(controller: c)));
    await flush(tester);
    platform.last.fake
      ..shellReady()
      ..frameLoaded();
    await flush(tester);
    await tester.pumpWidget(_host(const SizedBox()));
    await flush(tester);
    expect(c.status, McpAppViewStatus.suspended);
    expect(platform.last.disposed, isTrue);
    expect(platform.clearedProfiles, [c.profileKey], reason: 'last view of the server: profile wiped');

    await tester.pumpWidget(_host(McpAppView(controller: c)));
    await flush(tester);
    expect(platform.views, hasLength(2));
    platform.last.fake
      ..shellReady()
      ..handshake();
    await flush(tester);
    expect(platform.last.fake.notifications('ui/notifications/tool-input'), hasLength(1));
    await closeAll(tester, c);
  });

  testWidgets('close() sends ui/resource-teardown while the View is alive', (tester) async {
    final platform = FakeMcpAppPlatform();
    final c = McpAppController(
      session: McpAppSession(serverId: 'maps', serverName: 'Maps', resource: _resource()),
      callbacks: _callbacks(),
      platform: platform,
    );
    await tester.pumpWidget(_host(McpAppView(controller: c)));
    await flush(tester);
    final view = platform.last;
    view.fake
      ..shellReady()
      ..handshake();
    await flush(tester);
    final closing = c.close();
    await tester.pump();
    final req = view.fake.toView.last;
    expect(req['method'], 'ui/resource-teardown');
    view.fake.fromView({'jsonrpc': '2.0', 'id': req['id'], 'result': <String, Object?>{}});
    await tester.pump();
    await closing;
    expect(view.disposed, isTrue);
    expect(c.status, McpAppViewStatus.closed);
  });

  test('style variables cover every colour key with light-dark()', () {
    final v = mcpAppStyleVariables(
      light: ColorScheme.fromSeed(seedColor: Colors.teal),
      dark: ColorScheme.fromSeed(seedColor: Colors.teal, brightness: Brightness.dark),
    );
    final colours = v.keys.where((k) => k.startsWith('--color-')).toList();
    expect(colours, hasLength(37));
    for (final k in colours) {
      expect(v[k], anyOf(startsWith('light-dark('), 'transparent'), reason: k);
    }
    expect(v.keys.where((k) => k.startsWith('--font-text-') || k.startsWith('--font-heading-')), hasLength(22));
    expect(v['--color-text-primary'], matches(RegExp(r'^light-dark\(#[0-9a-f]{6}, #[0-9a-f]{6}\)$')));
  });
}
