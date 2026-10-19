import 'dart:async';

import 'package:sherpa/state/services.dart';

/// A [PreferencesStore] that remembers nothing (screens that only read it).
final class NoPrefs implements PreferencesStore {
  @override
  ModelChoice? get defaultModel => null;

  @override
  Future<void> setDefaultModel(ModelChoice? choice) async {}

  @override
  bool get onboardingComplete => true;

  @override
  Future<void> setOnboardingComplete(bool value) async {}

  @override
  Stream<void> get changes => const Stream.empty();
}
