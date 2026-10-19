import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_providers/sherpa_providers.dart';

/// A provider + model the user can chat with.
final class ModelChoice {
  const ModelChoice({required this.providerId, required this.modelId});

  final String providerId;
  final String modelId;

  @override
  bool operator ==(Object other) =>
      other is ModelChoice && other.providerId == providerId && other.modelId == modelId;

  @override
  int get hashCode => Object.hash(providerId, modelId);
}

/// Health of one configured endpoint, from the last probe.
enum EndpointStatus { unknown, ok, unauthorized, unreachable, error }

/// Provider id of the built-in on-device provider (llama.cpp over the model
/// library). It has no [ProviderConfig]: a registry wired for local
/// inference (`LocalProviderRegistry`) resolves it itself, so it never
/// appears in [ProviderRegistry.configs] and can't be added, edited or
/// removed. A library model is chosen as
/// `ModelChoice(providerId: localProviderId, modelId: LibraryModel.id)`.
const String localProviderId = 'local';

/// App-level registry of configured model providers. Persists
/// [ProviderConfig]s, keeps API keys in the [SecretStore], and builds
/// [ModelProvider] instances on demand.
///
/// [resolve], [models] and [probe] also answer [localProviderId] when the
/// registry is wired for on-device inference; [configs] never lists it.
abstract interface class ProviderRegistry {
  List<ProviderConfig> get configs;

  /// Emits the full list after every change.
  Stream<List<ProviderConfig>> get changes;

  Future<ProviderConfig> add(ProviderConfig config, {String? apiKey});

  Future<ProviderConfig> update(ProviderConfig config, {String? apiKey, bool clearApiKey = false});

  Future<void> remove(String providerId);

  Future<bool> hasApiKey(String providerId);

  /// A ready-to-use provider. Throws [StateError] for unknown ids.
  Future<ModelProvider> resolve(String providerId);

  /// Lists models (cached; [refresh] re-probes the server).
  Future<List<ModelDescriptor>> models(String providerId, {bool refresh = false});

  /// Cheap connectivity/auth probe for the settings screen.
  Future<EndpointStatus> probe(String providerId);
}

/// What the user picked as the default for new chats.
abstract interface class PreferencesStore {
  ModelChoice? get defaultModel;

  Future<void> setDefaultModel(ModelChoice? choice);

  bool get onboardingComplete;

  Future<void> setOnboardingComplete(bool value);

  /// Emits whenever any preference changes.
  Stream<void> get changes;
}
