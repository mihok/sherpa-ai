/// Test doubles: a scriptable shell channel and a fake platform whose
/// "WebView" is a plain widget.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import 'src/channel.dart';
import 'src/platform/messages.pigeon.dart' show NativeViewEventKind;
import 'src/platform/platform.dart';
import 'src/protocol/shell_envelope.dart';

/// A [McpAppChannel] that plays the shell: tests push shell envelopes and
/// View messages, and read what the bridge sent.
final class FakeMcpAppChannel implements McpAppChannel {
  final StreamController<String> _fromShell = StreamController<String>();

  /// Every envelope the bridge sent, decoded.
  final List<Map<String, Object?>> sent = [];
  bool closed = false;

  @override
  Stream<String> get fromShell => _fromShell.stream;

  @override
  void toShell(String envelope) {
    if (closed) return;
    sent.add((jsonDecode(envelope) as Map).cast<String, Object?>());
  }

  @override
  Future<void> close() {
    if (!closed) {
      closed = true;
      unawaited(_fromShell.close());
    }
    return Future<void>.value();
  }

  /// Raw shell string (as native would deliver it).
  void shellRaw(String raw) {
    if (!closed) _fromShell.add(raw);
  }

  void shellReady({bool cspOk = true, int version = shellProtocolVersion}) =>
      shellRaw(jsonEncode({'kind': 'ready', 'v': version, 'cspOk': cspOk}));

  void frameLoaded() => shellRaw(jsonEncode({'kind': 'frame-loaded'}));

  /// A JSON-RPC message from the View, wrapped as the shell wraps it.
  void fromView(Map<String, Object?> message) => shellRaw(jsonEncode({'kind': 'view', 'message': message}));

  void viewRequest(Object id, String method, [Map<String, Object?>? params]) =>
      fromView({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': ?params});

  void viewNotify(String method, [Map<String, Object?>? params]) =>
      fromView({'jsonrpc': '2.0', 'method': method, 'params': ?params});

  /// Runs the SDK handshake (`ui/initialize` + `initialized`).
  void handshake({Object id = 'init', List<String> displayModes = const ['inline', 'fullscreen'], String name = 'Test App'}) {
    viewRequest(id, 'ui/initialize', {
      'protocolVersion': '2026-01-26',
      'appInfo': {'name': name, 'version': '1.0.0'},
      'appCapabilities': {'availableDisplayModes': displayModes},
    });
    viewNotify('ui/notifications/initialized');
  }

  /// JSON-RPC messages the bridge posted to the View, in order.
  List<Map<String, Object?>> get toView => [
        for (final e in sent)
          if (e['kind'] == 'post') (e['message']! as Map).cast<String, Object?>(),
      ];

  /// The response to the View request [id], if sent.
  Map<String, Object?>? responseTo(Object id) {
    for (final m in toView) {
      if (m['id'] == id && (m.containsKey('result') || m.containsKey('error'))) return m;
    }
    return null;
  }

  /// Notifications posted to the View with [method].
  List<Map<String, Object?>> notifications(String method) => [
        for (final m in toView)
          if (m['method'] == method && !m.containsKey('id')) m,
      ];

  /// Shell commands of [kind] (`load`, `context`, `teardown`).
  List<Map<String, Object?>> commands(String kind) => [
        for (final e in sent)
          if (e['kind'] == kind) e,
      ];
}

/// A [McpAppPlatform] whose views render [FakeMcpAppNativeView.placeholderKey]
/// widgets and expose a [FakeMcpAppChannel].
final class FakeMcpAppPlatform implements McpAppPlatform {
  FakeMcpAppPlatform({this.supported = true, this.reason});

  bool supported;
  String? reason;
  final List<McpAppNativeViewConfig> configs = [];
  final List<FakeMcpAppNativeView> views = [];
  final List<String> clearedProfiles = [];
  int _ids = 0;

  FakeMcpAppNativeView get last => views.last;

  @override
  Future<McpAppPlatformSupport> support() async => McpAppPlatformSupport(supported: supported, reason: reason);

  @override
  Future<McpAppNativeView> createView(McpAppNativeViewConfig config) async {
    configs.add(config);
    final v = FakeMcpAppNativeView(++_ids, config);
    views.add(v);
    return v;
  }

  @override
  Future<void> clearServerData(String profileKey) async => clearedProfiles.add(profileKey);
}

final class FakeMcpAppNativeView implements McpAppNativeView {
  FakeMcpAppNativeView(this.viewId, this.config);

  @override
  final int viewId;
  final McpAppNativeViewConfig config;
  final FakeMcpAppChannel fake = FakeMcpAppChannel();
  final StreamController<McpAppNativeEvent> _events = StreamController<McpAppNativeEvent>.broadcast();
  bool disposed = false;

  /// How many times a platform view widget for this view was mounted
  /// (moving it between inline and fullscreen must not remount it).
  int mounts = 0;
  Set<Factory<OneSequenceGestureRecognizer>> lastGestures = const {};

  static Key placeholderKey(int viewId) => ValueKey('fake-mcp-app-view-$viewId');

  @override
  McpAppChannel get channel => fake;

  @override
  Stream<McpAppNativeEvent> get events => _events.stream;

  void emit(NativeViewEventKind kind, [String? detail]) => _events.add(McpAppNativeEvent(kind, detail));

  @override
  Widget build(BuildContext context, {Set<Factory<OneSequenceGestureRecognizer>> gestureRecognizers = const {}}) {
    lastGestures = gestureRecognizers;
    return _FakeNativeWidget(key: placeholderKey(viewId), view: this);
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await fake.close();
    await _events.close();
  }
}

class _FakeNativeWidget extends StatefulWidget {
  const _FakeNativeWidget({super.key, required this.view});
  final FakeMcpAppNativeView view;

  @override
  State<_FakeNativeWidget> createState() => _FakeNativeWidgetState();
}

class _FakeNativeWidgetState extends State<_FakeNativeWidget> {
  @override
  void initState() {
    super.initState();
    widget.view.mounts++;
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}
