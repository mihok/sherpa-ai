import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sherpa_core/sherpa_core.dart';

import 'services.dart';

// Root dependencies. Every one is overridden in bootstrap (lib/bootstrap.dart)
// with the real implementation and in tests with fakes, so widgets never
// construct services themselves.

final clockProvider = Provider<Clock>((ref) => const SystemClock());

final idGeneratorProvider = Provider<IdGenerator>((ref) => RandomIdGenerator());

final sessionStoreProvider = Provider<SessionStore>(
  (ref) => throw UnimplementedError('sessionStoreProvider must be overridden'),
);

final secretStoreProvider = Provider<SecretStore>(
  (ref) => throw UnimplementedError('secretStoreProvider must be overridden'),
);

final providerRegistryProvider = Provider<ProviderRegistry>(
  (ref) => throw UnimplementedError('providerRegistryProvider must be overridden'),
);

final preferencesProvider = Provider<PreferencesStore>(
  (ref) => throw UnimplementedError('preferencesProvider must be overridden'),
);

/// Device memory/thermal signals. Overridden in bootstrap with the platform
/// plugin's monitor; the default never reports pressure (tests, previews).
final memoryMonitorProvider = Provider<MemoryMonitor>((ref) => FakeMemoryMonitor());

/// One policy for the whole app so "always allow" grants are shared.
final approvalPolicyProvider = Provider<ApprovalPolicy>(
  (ref) => ApprovalPolicy(clock: ref.watch(clockProvider)),
);

/// Built-in and (later) MCP tools offered to every session.
final toolRouterProvider = Provider<ToolRouter>((ref) {
  final store = ref.watch(sessionStoreProvider);
  final clock = ref.watch(clockProvider);
  return CompositeToolRouter([
    LocalToolRouter([UpdatePlanTool(store: store, clock: clock)]),
  ]);
});
