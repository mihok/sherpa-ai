import 'dart:async';

import 'package:sherpa_data/sherpa_data.dart';

import '../ui_preferences.dart';

/// [UiPreferencesStore] persisted as one document in the encrypted database.
///
/// The last [save] always wins, on screen and on disk. [settings] and
/// [changes] follow each request immediately, in call order; writes are
/// serialized and each one writes the newest settings, so a slow write can
/// never land after (or hide) a newer choice. The settings screen fires
/// saves without awaiting them, so two quick taps can overlap.
final class DocumentUiPreferencesStore implements UiPreferencesStore {
  DocumentUiPreferencesStore(this._docs);

  final JsonDocumentStore _docs;
  final StreamController<UiSettings> _changes = StreamController.broadcast();

  /// The newest requested settings.
  UiSettings _settings = const UiSettings();

  /// What the database holds (as far as this store knows).
  UiSettings _persisted = const UiSettings();

  /// The write loop, while one runs.
  Future<void>? _writing;

  static const _collection = DocumentCollections.preferences;
  static const _id = 'ui';

  Future<void> load() async {
    final doc = await _docs.get(_collection, _id);
    if (doc != null) _settings = _persisted = UiSettings.fromJson(doc);
  }

  @override
  UiSettings get settings => _settings;

  /// Completes once [settings] (or something newer) is on disk.
  @override
  Future<void> save(UiSettings settings) {
    if (settings != _settings) {
      _settings = settings;
      _changes.add(settings);
    }
    final running = _writing;
    if (running != null) return running;
    if (_settings == _persisted) return Future.value();
    return _writing = _writeLatest();
  }

  Future<void> _writeLatest() async {
    try {
      while (_persisted != _settings) {
        final next = _settings;
        await _docs.put(_collection, _id, next.toJson());
        _persisted = next;
      }
    } finally {
      _writing = null;
    }
  }

  @override
  Stream<UiSettings> get changes => _changes.stream;
}
