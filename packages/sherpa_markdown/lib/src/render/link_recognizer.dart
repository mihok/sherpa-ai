import 'dart:async';

import 'package:flutter/foundation.dart' show VoidCallback;
import 'package:flutter/gestures.dart';

/// One recognizer for a link span: a tap calls [onTap], a press held for
/// [longPressTimeout] calls [onLongPress] instead.
///
/// A `TextSpan` takes a single recognizer, and the text engine only maps
/// a [TapGestureRecognizer] to the semantics tap action ("link"), so this
/// extends it rather than pairing it with a long-press recognizer.
///
/// When the press is held long enough the recognizer claims the gesture
/// (the ancestor `SelectionArea` does not start a selection on the link)
/// and the tap that would follow the release is suppressed. Without an
/// [onLongPress] it behaves like a plain [TapGestureRecognizer], so a long
/// press still selects text.
class LinkGestureRecognizer extends TapGestureRecognizer {
  LinkGestureRecognizer({
    super.debugOwner,
    this.longPressTimeout = kLongPressTimeout,
  });

  /// Called when the press is held for [longPressTimeout].
  VoidCallback? onLongPress;

  final Duration longPressTimeout;

  Timer? _timer;
  bool _longPressed = false;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    final fresh = state == GestureRecognizerState.ready;
    super.addAllowedPointer(event);
    if (!fresh) return; // a second finger: the first press decides
    _timer?.cancel();
    _longPressed = false;
    if (onLongPress != null) _timer = Timer(longPressTimeout, _onTimer);
  }

  void _onTimer() {
    _timer = null;
    final handler = onLongPress;
    if (handler == null || state != GestureRecognizerState.possible) return;
    _longPressed = true;
    // Wins the arena now, so the selection gesture of an ancestor
    // SelectionArea is rejected for this pointer.
    resolve(GestureDisposition.accepted);
    handler();
  }

  @override
  void handleTapUp({
    required PointerDownEvent down,
    required PointerUpEvent up,
  }) {
    _timer?.cancel();
    _timer = null;
    if (_longPressed) {
      _longPressed = false;
      return;
    }
    super.handleTapUp(down: down, up: up);
  }

  @override
  void handleTapCancel({
    required PointerDownEvent down,
    PointerCancelEvent? cancel,
    required String reason,
  }) {
    _timer?.cancel();
    _timer = null;
    _longPressed = false;
    super.handleTapCancel(down: down, cancel: cancel, reason: reason);
  }

  @override
  void rejectGesture(int pointer) {
    _timer?.cancel();
    _timer = null;
    super.rejectGesture(pointer);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }

  @override
  String get debugDescription => 'link tap';
}
