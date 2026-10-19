import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart' show ThemeMode, immutable;

import '../design/haptics.dart';

/// Device-local preferences: look and feel, plus how long chats are
/// summarized ([modelSummaries]).
///
/// Kept apart from `PreferencesStore` on purpose: that interface is a shared
/// contract with other implementations (Drift, test fakes), and adding
/// members to it would break every implementer.
@immutable
final class UiSettings {
  const UiSettings({
    this.hapticsEnabled = true,
    this.dynamicColor = true,
    this.themeMode = ThemeMode.system,
    this.modelSummaries = false,
  });

  final bool hapticsEnabled;

  /// Use the wallpaper palette on Android 12+ instead of the brand colors.
  final bool dynamicColor;
  final ThemeMode themeMode;

  /// "Let the chat's model write summaries": when a chat on a model that
  /// isn't built into Sherpa gets long, its older messages are sent to that
  /// provider once more to be summarized. Off (the default): summaries are
  /// extractive, made on this phone. On-device chats always summarize with
  /// their own model, whatever this says (PLAN §7 decision 9: no remote
  /// compaction without opt-in).
  final bool modelSummaries;

  UiSettings copyWith({bool? hapticsEnabled, bool? dynamicColor, ThemeMode? themeMode, bool? modelSummaries}) =>
      UiSettings(
        hapticsEnabled: hapticsEnabled ?? this.hapticsEnabled,
        dynamicColor: dynamicColor ?? this.dynamicColor,
        themeMode: themeMode ?? this.themeMode,
        modelSummaries: modelSummaries ?? this.modelSummaries,
      );

  Map<String, Object?> toJson() => {
        'hapticsEnabled': hapticsEnabled,
        'dynamicColor': dynamicColor,
        'themeMode': themeMode.name,
        'modelSummaries': modelSummaries,
      };

  static UiSettings fromJson(Map<String, Object?> j) => UiSettings(
        hapticsEnabled: j['hapticsEnabled'] as bool? ?? true,
        dynamicColor: j['dynamicColor'] as bool? ?? true,
        themeMode: ThemeMode.values.asNameMap()[j['themeMode']] ?? ThemeMode.system,
        modelSummaries: j['modelSummaries'] as bool? ?? false,
      );

  @override
  bool operator ==(Object other) =>
      other is UiSettings &&
      other.hapticsEnabled == hapticsEnabled &&
      other.dynamicColor == dynamicColor &&
      other.themeMode == themeMode &&
      other.modelSummaries == modelSummaries;

  @override
  int get hashCode => Object.hash(hapticsEnabled, dynamicColor, themeMode, modelSummaries);
}

/// Persistence for [UiSettings]. `toJson`/`fromJson` make a key-value or
/// single-row Drift implementation trivial.
abstract interface class UiPreferencesStore {
  UiSettings get settings;

  Future<void> save(UiSettings settings);

  Stream<UiSettings> get changes;
}

final class InMemoryUiPreferencesStore implements UiPreferencesStore {
  InMemoryUiPreferencesStore([this._settings = const UiSettings()]);

  UiSettings _settings;
  final StreamController<UiSettings> _changes = StreamController<UiSettings>.broadcast();

  @override
  UiSettings get settings => _settings;

  @override
  Future<void> save(UiSettings settings) async {
    if (settings == _settings) return;
    _settings = settings;
    _changes.add(settings);
  }

  @override
  Stream<UiSettings> get changes => _changes.stream;
}

/// Defaults to an in-memory store so widgets and tests work unwired; the
/// integrator overrides it with a persisted implementation in bootstrap.
final uiPreferencesStoreProvider = Provider<UiPreferencesStore>((ref) => InMemoryUiPreferencesStore());

final uiSettingsProvider = NotifierProvider<UiSettingsNotifier, UiSettings>(UiSettingsNotifier.new);

class UiSettingsNotifier extends Notifier<UiSettings> {
  @override
  UiSettings build() {
    final store = ref.watch(uiPreferencesStoreProvider);
    final sub = store.changes.listen((s) => state = s);
    ref.onDispose(sub.cancel);
    return store.settings;
  }

  Future<void> update(UiSettings Function(UiSettings current) change) async {
    final next = change(state);
    state = next;
    await ref.read(uiPreferencesStoreProvider).save(next);
  }
}

/// Override in tests to record haptic calls.
final hapticsDriverProvider = Provider<HapticsDriver>((ref) => const PlatformHapticsDriver());

/// App-wide haptics honoring the user's setting. Usage:
/// `ref.read(hapticsProvider).selection()`.
final hapticsProvider = Provider<Haptics>(
  (ref) => Haptics(
    enabled: ref.watch(uiSettingsProvider.select((s) => s.hapticsEnabled)),
    driver: ref.watch(hapticsDriverProvider),
  ),
);
