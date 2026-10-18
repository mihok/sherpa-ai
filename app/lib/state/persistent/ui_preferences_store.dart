import 'dart:async';

import 'package:sherpa_data/sherpa_data.dart';

import '../ui_preferences.dart';

/// [UiPreferencesStore] persisted as one document in the encrypted database.
final class DocumentUiPreferencesStore implements UiPreferencesStore {
  DocumentUiPreferencesStore(this._docs);

  final JsonDocumentStore _docs;
  final StreamController<UiSettings> _changes = StreamController.broadcast();
  UiSettings _settings = const UiSettings();

  static const _collection = DocumentCollections.preferences;
  static const _id = 'ui';

  Future<void> load() async {
    final doc = await _docs.get(_collection, _id);
    if (doc != null) _settings = UiSettings.fromJson(doc);
  }

  @override
  UiSettings get settings => _settings;

  @override
  Future<void> save(UiSettings settings) async {
    if (settings == _settings) return;
    await _docs.put(_collection, _id, settings.toJson());
    _settings = settings;
    _changes.add(settings);
  }

  @override
  Stream<UiSettings> get changes => _changes.stream;
}
