import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' show ThemeMode;
import 'package:sherpa/state/persistent/ui_preferences_store.dart';
import 'package:sherpa/state/ui_preferences.dart';
import 'package:sherpa_data/sherpa_data.dart';

/// Finding 17: quickly reverting a UI setting must leave the last choice,
/// both on screen and on disk.
void main() {
  late SherpaDatabase db;
  late JsonDocumentStore docs;

  setUp(() {
    db = SherpaDatabase.inMemory();
    docs = JsonDocumentStore(db);
  });
  tearDown(() => db.close());

  Future<UiSettings> persisted() async {
    final fresh = DocumentUiPreferencesStore(docs);
    await fresh.load();
    return fresh.settings;
  }

  test('a second tap before the first write lands wins on screen and on disk', () async {
    final store = DocumentUiPreferencesStore(docs);
    await store.load();
    final container = ProviderContainer(overrides: [uiPreferencesStoreProvider.overrideWithValue(store)]);
    addTearDown(container.dispose);
    expect(container.read(uiSettingsProvider).hapticsEnabled, isTrue);
    final n = container.read(uiSettingsProvider.notifier);

    // Two taps on the haptics switch, the second before the first write lands.
    final a = n.update((u) => u.copyWith(hapticsEnabled: false));
    final b = n.update((u) => u.copyWith(hapticsEnabled: true));
    expect(container.read(uiSettingsProvider).hapticsEnabled, isTrue);
    await Future.wait([a, b]);
    await pumpEventQueue();

    expect(container.read(uiSettingsProvider).hapticsEnabled, isTrue, reason: 'the switch must not flip back');
    expect(store.settings.hapticsEnabled, isTrue);
    expect((await persisted()).hapticsEnabled, isTrue, reason: 'the next launch loads the last choice');
  });

  test('many overlapping saves end with the last one, and changes arrive in call order', () async {
    final store = DocumentUiPreferencesStore(docs);
    await store.load();
    final seen = <ThemeMode>[];
    final sub = store.changes.listen((s) => seen.add(s.themeMode));
    addTearDown(sub.cancel);

    final modes = [ThemeMode.dark, ThemeMode.system, ThemeMode.light, ThemeMode.dark, ThemeMode.system];
    final saves = [for (final m in modes) store.save(store.settings.copyWith(themeMode: m))];
    expect(store.settings.themeMode, ThemeMode.system);
    await Future.wait(saves);
    await pumpEventQueue();

    expect(seen, modes);
    expect(store.settings.themeMode, ThemeMode.system);
    expect((await persisted()).themeMode, ThemeMode.system);
  });

  test('saving the current settings writes nothing; a later change still persists', () async {
    final store = DocumentUiPreferencesStore(docs);
    await store.load();
    await store.save(store.settings);
    expect(await docs.get(DocumentCollections.preferences, 'ui'), isNull);
    await store.save(store.settings.copyWith(hapticsEnabled: false));
    expect((await persisted()).hapticsEnabled, isFalse);
  });
}
