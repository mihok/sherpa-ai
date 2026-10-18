import 'dart:async';

import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_data/sherpa_data.dart';

import '../services.dart';

/// [PreferencesStore] persisted as one document in the encrypted database.
/// Values are cached so the UI reads them synchronously.
final class DocumentPreferencesStore implements PreferencesStore {
  DocumentPreferencesStore(this._docs);

  final JsonDocumentStore _docs;
  final StreamController<void> _changes = StreamController.broadcast();
  JsonMap _values = const {};

  static const _collection = DocumentCollections.preferences;
  static const _id = 'app';

  Future<void> load() async => _values = await _docs.get(_collection, _id) ?? const {};

  @override
  ModelChoice? get defaultModel {
    final m = _values.optObj('defaultModel');
    if (m == null) return null;
    final p = m.opt<String>('providerId');
    final id = m.opt<String>('modelId');
    return p == null || id == null ? null : ModelChoice(providerId: p, modelId: id);
  }

  @override
  Future<void> setDefaultModel(ModelChoice? choice) => _set(
        'defaultModel',
        choice == null ? null : {'providerId': choice.providerId, 'modelId': choice.modelId},
      );

  @override
  bool get onboardingComplete => _values.opt<bool>('onboardingComplete') ?? false;

  @override
  Future<void> setOnboardingComplete(bool value) => _set('onboardingComplete', value);

  @override
  Stream<void> get changes => _changes.stream;

  Future<void> _set(String key, Object? value) async {
    final next = {..._values}..remove(key);
    if (value != null) next[key] = value;
    await _docs.put(_collection, _id, next);
    _values = next;
    _changes.add(null);
  }

  Future<void> dispose() => _changes.close();
}
