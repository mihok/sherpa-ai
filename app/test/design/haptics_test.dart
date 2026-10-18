import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa/design/haptics.dart';
import 'package:sherpa/state/ui_preferences.dart';

import '../support/harness.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('enabled haptics reach the driver on phones', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final driver = RecordingHaptics();
    Haptics(enabled: true, driver: driver)
      ..selection()
      ..light()
      ..success()
      ..warning()
      ..error();
    expect(driver.calls, [HapticKind.selection, HapticKind.light, HapticKind.success, HapticKind.warning, HapticKind.error]);
  });

  test('disabled haptics are a no-op', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final driver = RecordingHaptics();
    Haptics(enabled: false, driver: driver).success();
    expect(driver.calls, isEmpty);
  });

  test('unsupported platforms are a no-op', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final driver = RecordingHaptics();
    Haptics(enabled: true, driver: driver).success();
    expect(driver.calls, isEmpty);
  });

  test('a failing platform call never throws', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(() => Haptics(enabled: true, driver: _Throwing()).light(), returnsNormally);
  });

  test('hapticsProvider follows the user setting', () async {
    final driver = RecordingHaptics();
    final container = ProviderContainer.test(overrides: [hapticsDriverProvider.overrideWithValue(driver)]);
    expect(container.read(hapticsProvider).enabled, isTrue);
    await container.read(uiSettingsProvider.notifier).update((s) => s.copyWith(hapticsEnabled: false));
    expect(container.read(hapticsProvider).enabled, isFalse);
  });
}

final class _Throwing implements HapticsDriver {
  @override
  Future<void> perform(HapticKind kind) => Future.error(StateError('no vibrator'));
}
