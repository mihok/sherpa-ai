import 'dart:async';

import 'package:flutter/widgets.dart';

/// Whether the app's UI is visible. Injected into [PlatformMemoryMonitor] so
/// tests can drive lifecycle without a widget binding.
abstract interface class ForegroundSource {
  bool get isForeground;

  /// Emits on every foreground ↔ background transition.
  Stream<bool> get changes;
}

/// Flutter's app lifecycle: `resumed` and `inactive` (still visible, e.g.
/// an iOS system sheet) count as foreground; `hidden`, `paused` and
/// `detached` do not.
final class WidgetsForegroundSource implements ForegroundSource {
  WidgetsForegroundSource();

  AppLifecycleListener? _listener;
  bool? _last;
  late final StreamController<bool> _controller = StreamController.broadcast(
    onListen: () {
      _last = isForeground;
      _listener = AppLifecycleListener(onStateChange: (s) {
        final fg = _isForeground(s);
        if (fg == _last) return;
        _last = fg;
        _controller.add(fg);
      });
    },
    onCancel: () {
      _listener?.dispose();
      _listener = null;
    },
  );

  static bool _isForeground(AppLifecycleState? s) =>
      s == null || s == AppLifecycleState.resumed || s == AppLifecycleState.inactive;

  @override
  bool get isForeground => _isForeground(WidgetsBinding.instance.lifecycleState);

  @override
  Stream<bool> get changes => _controller.stream;
}
