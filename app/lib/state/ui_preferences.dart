import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart' show ThemeMode, immutable;

import '../design/haptics.dart';

/// Device-local preferences: look and feel, how long chats are summarized
/// ([modelSummaries]) and whether runs continue in the background
/// ([backgroundRuns]).
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
    this.backgroundRuns = true,
    this.backgroundNotificationsAsked = false,
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

  /// "Keep working in the background": a reply or agent run that is in
  /// flight when the user leaves Sherpa keeps going (Android foreground
  /// service, iOS background task / continued processing). On by default
  /// (PLAN §7 decision 2: Android yes; iOS continues remote models, and
  /// on-device models on iPhone pause until Sherpa is back either way).
  final bool backgroundRuns;

  /// The chat already asked whether Sherpa may post notifications for
  /// background runs (Android 13+), so it doesn't ask again.
  final bool backgroundNotificationsAsked;

  UiSettings copyWith({
    bool? hapticsEnabled,
    bool? dynamicColor,
    ThemeMode? themeMode,
    bool? modelSummaries,
    bool? backgroundRuns,
    bool? backgroundNotificationsAsked,
  }) =>
      UiSettings(
        hapticsEnabled: hapticsEnabled ?? this.hapticsEnabled,
        dynamicColor: dynamicColor ?? this.dynamicColor,
        themeMode: themeMode ?? this.themeMode,
        modelSummaries: modelSummaries ?? this.modelSummaries,
        backgroundRuns: backgroundRuns ?? this.backgroundRuns,
        backgroundNotificationsAsked: backgroundNotificationsAsked ?? this.backgroundNotificationsAsked,
      );

  Map<String, Object?> toJson() => {
        'hapticsEnabled': hapticsEnabled,
        'dynamicColor': dynamicColor,
        'themeMode': themeMode.name,
        'modelSummaries': modelSummaries,
        'backgroundRuns': backgroundRuns,
        'backgroundNotificationsAsked': backgroundNotificationsAsked,
      };

  static UiSettings fromJson(Map<String, Object?> j) => UiSettings(
        hapticsEnabled: j['hapticsEnabled'] as bool? ?? true,
        dynamicColor: j['dynamicColor'] as bool? ?? true,
        themeMode: ThemeMode.values.asNameMap()[j['themeMode']] ?? ThemeMode.system,
        modelSummaries: j['modelSummaries'] as bool? ?? false,
        backgroundRuns: j['backgroundRuns'] as bool? ?? true,
        backgroundNotificationsAsked: j['backgroundNotificationsAsked'] as bool? ?? false,
      );

  @override
  bool operator ==(Object other) =>
      other is UiSettings &&
      other.hapticsEnabled == hapticsEnabled &&
      other.dynamicColor == dynamicColor &&
      other.themeMode == themeMode &&
      other.modelSummaries == modelSummaries &&
      other.backgroundRuns == backgroundRuns &&
      other.backgroundNotificationsAsked == backgroundNotificationsAsked;

  @override
  int get hashCode =>
      Object.hash(hapticsEnabled, dynamicColor, themeMode, modelSummaries, backgroundRuns, backgroundNotificationsAsked);
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
