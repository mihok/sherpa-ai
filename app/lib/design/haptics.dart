import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The kinds of feedback Sherpa uses. Deliberately few: haptics mark
/// *moments* (a choice, a send, a result), never streaming tokens.
enum HapticKind { selection, light, success, warning, error }

/// Platform hook so tests can record calls without a device.
abstract interface class HapticsDriver {
  Future<void> perform(HapticKind kind);
}

/// Calls the platform vibration APIs.
///
/// Notes on platform behaviour (docs/research/12 §1.9):
/// - success/warning/error map to iOS `UINotificationFeedbackGenerator` and
///   Android `CONFIRM`/`REJECT` constants, which are no-ops below API 30;
/// - iOS already silences everything when "System Haptics" is off.
final class PlatformHapticsDriver implements HapticsDriver {
  const PlatformHapticsDriver();

  @override
  Future<void> perform(HapticKind kind) => switch (kind) {
        HapticKind.selection => HapticFeedback.selectionClick(),
        HapticKind.light => HapticFeedback.lightImpact(),
        HapticKind.success => HapticFeedback.successNotification(),
        HapticKind.warning => HapticFeedback.warningNotification(),
        HapticKind.error => HapticFeedback.errorNotification(),
      };
}

/// App-wide haptics. Read it via `hapticsProvider`; it is a no-op when the
/// user turned haptics off in Settings, on platforms without a vibrator,
/// and on web/desktop.
///
/// Suggested mapping: chip/radio pick → [selection]; send → [light];
/// approval needed → [warning]; tool error → [error]; run finished while
/// the app is in the foreground → [success].
final class Haptics {
  const Haptics({required this.enabled, this.driver = const PlatformHapticsDriver()});

  /// Disabled haptics; handy default for previews and tests.
  static const off = Haptics(enabled: false);

  final bool enabled;
  final HapticsDriver driver;

  static bool get _platformSupports =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

  void selection() => _fire(HapticKind.selection);
  void light() => _fire(HapticKind.light);
  void success() => _fire(HapticKind.success);
  void warning() => _fire(HapticKind.warning);
  void error() => _fire(HapticKind.error);

  void _fire(HapticKind kind) {
    if (!enabled || !_platformSupports) return;
    // Fire-and-forget: feedback must never block or fail a user action.
    unawaited(driver.perform(kind).catchError((Object _) {}));
  }
}
