import 'dart:async';

import 'package:flutter/widgets.dart';

/// Whether the app's UI is visible (the foreground-only rule of Gemini
/// Nano, and when LiteRT-LM may reload after a memory release).
///
/// Same contract as sherpa_platform's `ForegroundSource`; it is not reused
/// directly because depending on sherpa_platform would make Flutter wire its
/// Android module (compileSdk 37) under this plugin (compileSdk 36). Adapt
/// an existing source with [AppForeground.from].
abstract interface class AppForeground {
  /// Adapts any lifecycle source, e.g. sherpa_platform's
  /// `ForegroundSource`: `AppForeground.from(() => fs.isForeground, fs.changes)`.
  factory AppForeground.from(bool Function() isForeground, Stream<bool> changes) = _FunctionForeground;

  bool get isForeground;

  /// Emits on every foreground ↔ background transition.
  Stream<bool> get changes;
}

final class _FunctionForeground implements AppForeground {
  _FunctionForeground(this._isForeground, this.changes);

  final bool Function() _isForeground;

  @override
  final Stream<bool> changes;

  @override
  bool get isForeground => _isForeground();
}

/// Flutter's app lifecycle: `resumed` and `inactive` (still visible, e.g. a
/// system sheet) count as foreground; `hidden`, `paused` and `detached` do
/// not.
final class WidgetsAppForeground implements AppForeground {
  WidgetsAppForeground();

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
