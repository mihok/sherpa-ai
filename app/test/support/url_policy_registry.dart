import 'package:sherpa/state/services.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_net/sherpa_net.dart';
import 'package:sherpa_providers/sherpa_providers.dart';

/// A registry that refuses every save with the [UrlPolicyViolation] the
/// persistent registry raises when its own check fails (its DNS answer can
/// differ from the form's a moment earlier).
final class RefusingRegistry implements ProviderRegistry {
  RefusingRegistry(this.inner, this.violation);

  final ProviderRegistry inner;
  final UrlPolicyViolation violation;

  @override
  List<ProviderConfig> get configs => inner.configs;

  @override
  Stream<List<ProviderConfig>> get changes => inner.changes;

  @override
  Future<ProviderConfig> add(ProviderConfig config, {String? apiKey}) async => throw violation;

  @override
  Future<ProviderConfig> update(ProviderConfig config, {String? apiKey, bool clearApiKey = false}) async =>
      throw violation;

  @override
  Future<void> remove(String providerId) => inner.remove(providerId);

  @override
  Future<bool> hasApiKey(String providerId) => inner.hasApiKey(providerId);

  @override
  Future<ModelProvider> resolve(String providerId) => inner.resolve(providerId);

  @override
  Future<List<ModelDescriptor>> models(String providerId, {bool refresh = false}) =>
      inner.models(providerId, refresh: refresh);

  @override
  Future<EndpointStatus> probe(String providerId) => inner.probe(providerId);
}
