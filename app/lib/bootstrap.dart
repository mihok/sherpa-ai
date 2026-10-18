import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_providers/sherpa_providers.dart';

import 'routing/chat_route.dart';
import 'routing/chat_screen_binding.dart';
import 'state/in_memory/in_memory_preferences_store.dart';
import 'state/in_memory/in_memory_provider_registry.dart';
import 'state/observable_session_store.dart';
import 'state/providers.dart';
import 'state/ui_preferences.dart';

/// Riverpod's automatic retry is off app-wide: failed network calls belong to
/// the agent loop's own retry policy (which knows not to retry a spend-cap
/// 429), not to a silent UI-layer retry. Pass as `ProviderScope(retry:)`.
Duration? noRetry(int retryCount, Object error) => null;

/// Wires the app's services and returns them as `ProviderScope` overrides.
///
/// INTEGRATOR: this is the one place to swap implementations. Replace each
/// in-memory store with its persisted counterpart, keeping the
/// [ObservableSessionStore] wrapper (it is what keeps the sessions list
/// live):
///
/// | Root provider                | now                         | target                                  |
/// |------------------------------|-----------------------------|-----------------------------------------|
/// | `secretStoreProvider`        | `InMemorySecretStore`       | `SecureSecretStore()` (this app)        |
/// | `sessionStoreProvider`       | `InMemorySessionStore`      | sherpa_data Drift store                 |
/// | `providerRegistryProvider`   | `InMemoryProviderRegistry`  | Drift-backed registry (same factory)    |
/// | `preferencesProvider`        | `InMemoryPreferencesStore`  | Drift/settings-backed store             |
/// | `uiPreferencesStoreProvider` | `InMemoryUiPreferencesStore`| Drift/settings-backed store             |
///
/// and pass the real adapters as [providerFactory].
Future<List<Override>> bootstrap({ModelProviderFactory? providerFactory}) async {
  WidgetsFlutterBinding.ensureInitialized();
  _installErrorHandlers();

  final secrets = InMemorySecretStore();
  final sessions = ObservableSessionStore(InMemorySessionStore());
  final registry = InMemoryProviderRegistry(secrets: secrets, factory: providerFactory ?? unwiredProviderFactory);
  final prefs = InMemoryPreferencesStore();
  final ui = InMemoryUiPreferencesStore();

  return [
    secretStoreProvider.overrideWithValue(secrets),
    sessionStoreProvider.overrideWithValue(sessions),
    providerRegistryProvider.overrideWithValue(registry),
    preferencesProvider.overrideWithValue(prefs),
    uiPreferencesStoreProvider.overrideWithValue(ui),
    chatScreenBuilderProvider.overrideWithValue(buildChatScreen),
  ];
}

/// Errors are reported without their arguments: a provider exception can
/// echo request details, and nothing here may ever print a secret.
void _installErrorHandlers() {
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    if (kDebugMode) {
      previous?.call(details);
    } else {
      debugPrint('FlutterError: ${details.exception.runtimeType}');
    }
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('Uncaught ${error.runtimeType}');
    return true;
  };
}

/// Stand-in until the sherpa_providers adapters are wired in: every call
/// fails with a clear, non-retryable error, so the UI shows a real error
/// state instead of pretending to connect.
FutureOr<ModelProvider> unwiredProviderFactory(ProviderConfig config, String? apiKey) =>
    _UnwiredProvider(config);

final class _UnwiredProvider implements ModelProvider {
  _UnwiredProvider(this._config);

  final ProviderConfig _config;

  ProviderException get _error => ProviderException(
        ProviderErrorKind.unsupported,
        'Remote model adapters are not wired into this build yet.',
        providerId: _config.id,
      );

  @override
  ProviderInfo get info => ProviderInfo(
        id: _config.id,
        kind: _config.flavor == ApiFlavor.anthropic ? ProviderKind.anthropic : ProviderKind.openAiCompatible,
        displayName: _config.displayName,
        location: ExecutionLocation.remote,
        baseUrl: _config.baseUrl,
      );

  @override
  Future<List<ModelDescriptor>> listModels() async => throw _error;

  @override
  Future<ModelCapabilities> capabilities(String modelId) async => throw _error;

  @override
  Stream<ModelEvent> stream(ModelRequest request, {CancellationToken? cancel}) => Stream.error(_error);
}
