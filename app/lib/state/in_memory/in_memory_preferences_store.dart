import 'dart:async';

import '../services.dart';

/// Volatile [PreferencesStore] so the app runs before the persisted store is
/// wired, and for widget tests.
final class InMemoryPreferencesStore implements PreferencesStore {
  InMemoryPreferencesStore({ModelChoice? defaultModel, bool onboardingComplete = false})
      : _defaultModel = defaultModel,
        _onboardingComplete = onboardingComplete;

  ModelChoice? _defaultModel;
  bool _onboardingComplete;
  final StreamController<void> _changes = StreamController<void>.broadcast();

  @override
  ModelChoice? get defaultModel => _defaultModel;

  @override
  Future<void> setDefaultModel(ModelChoice? choice) async {
    if (choice == _defaultModel) return;
    _defaultModel = choice;
    _changes.add(null);
  }

  @override
  bool get onboardingComplete => _onboardingComplete;

  @override
  Future<void> setOnboardingComplete(bool value) async {
    if (value == _onboardingComplete) return;
    _onboardingComplete = value;
    _changes.add(null);
  }

  @override
  Stream<void> get changes => _changes.stream;
}
