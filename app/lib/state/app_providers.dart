import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_providers/sherpa_providers.dart';

import 'provider_location.dart';
import 'providers.dart';
import 'services.dart';

// Derived, UI-facing views over the root services in providers.dart. They
// add no state of their own; overriding the roots is enough for tests.

/// Configured providers, live.
final providerConfigsProvider = StreamProvider<List<ProviderConfig>>((ref) async* {
  final registry = ref.watch(providerRegistryProvider);
  yield registry.configs;
  yield* registry.changes;
});

/// One config by id, or null once it was removed.
final providerConfigProvider = Provider.family<ProviderConfig?, String>((ref, id) {
  final configs = ref.watch(providerConfigsProvider).value ?? ref.read(providerRegistryProvider).configs;
  for (final c in configs) {
    if (c.id == id) return c;
  }
  return null;
});

/// Last probe result for a provider. Invalidate to re-probe.
final providerStatusProvider = FutureProvider.autoDispose.family<EndpointStatus, String>(
  (ref, id) => ref.watch(providerRegistryProvider).probe(id),
);

/// Models a provider serves (cached by the registry).
final providerModelsProvider = FutureProvider.autoDispose.family<List<ModelDescriptor>, String>(
  (ref, id) => ref.watch(providerRegistryProvider).models(id),
);

/// Whether an API key is stored for a provider (never the key itself).
final hasApiKeyProvider = FutureProvider.autoDispose.family<bool, String>(
  (ref, id) => ref.watch(providerRegistryProvider).hasApiKey(id),
);

/// The model new chats start with, live.
final defaultModelProvider = StreamProvider<ModelChoice?>((ref) async* {
  final prefs = ref.watch(preferencesProvider);
  yield prefs.defaultModel;
  await for (final _ in prefs.changes) {
    yield prefs.defaultModel;
  }
});

/// Privacy facts about a provider, ready for a badge.
typedef ProviderPrivacy = ({ExecutionLocation location, String host});

final providerPrivacyProvider = Provider.family<ProviderPrivacy?, String>((ref, id) {
  final config = ref.watch(providerConfigProvider(id));
  if (config == null) return null;
  ref.watch(localHostVerdictsProvider);
  ensureLocalHostVerified(config, ref.read(hostResolverProvider));
  return (location: locationOf(config), host: privacyHostLabel(config));
});
