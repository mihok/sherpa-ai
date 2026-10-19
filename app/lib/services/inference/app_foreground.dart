import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:sherpa_litert/sherpa_litert.dart' show AppForeground;

/// Whether Sherpa is on screen, from Flutter's [AppLifecycleListener]: one
/// listener for the app, adapted for every on-device provider that needs it
/// (sherpa_litert's [AppForeground]: Gemini Nano's foreground-only rule,
/// LiteRT-LM's "reload only in the foreground" after a memory release).
///
/// `resumed` and `inactive` (still visible, e.g. a system sheet) count as
/// foreground; `hidden`, `paused` and `detached` do not — the same rule as
/// sherpa_platform's `WidgetsForegroundSource`.
final class AppLifecycleForeground {
  AppLifecycleForeground() {
    try {
      _last = _isForeground(WidgetsBinding.instance.lifecycleState);
      _listener = AppLifecycleListener(onStateChange: _onState);
    } on Object {
      // No widgets binding (plain Dart tests): always foreground.
    }
  }

  AppLifecycleListener? _listener;
  bool _last = true;
  final StreamController<bool> _changes = StreamController<bool>.broadcast(sync: true);

  static bool _isForeground(AppLifecycleState? s) =>
      s == null || s == AppLifecycleState.resumed || s == AppLifecycleState.inactive;

  void _onState(AppLifecycleState s) {
    final fg = _isForeground(s);
    if (fg == _last) return;
    _last = fg;
    if (!_changes.isClosed) _changes.add(fg);
  }

  bool get isForeground => _last;

  /// Every foreground ↔ background transition.
  Stream<bool> get changes => _changes.stream;

  /// For sherpa_litert's providers.
  late final AppForeground asLiteRt = AppForeground.from(() => isForeground, changes);

  void dispose() {
    _listener?.dispose();
    _listener = null;
    unawaited(_changes.close());
  }
}
