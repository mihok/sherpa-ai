/// On-device inference for Sherpa (Flutter FFI plugin).
///
/// Layers, bottom up:
/// * `ffi/` — hand-written bindings to `native/engine/include/sherpa_engine.h`
///   and the platform library loader.
/// * [EngineHost] — the engine boundary (contract in its doc comment);
///   [FfiEngineHost] runs the engine in-process on background isolates;
///   [ProcessEngineHost] runs it in Android's private `:inference` process
///   (bound service, Binder, JNI). [createDefaultEngineHost] picks one.
/// * [LlamaCppProvider] — the core `ModelProvider` over a host, with
///   [EngineTokenCounter] (+ [WarmingContextManager]) for exact counts.
/// * [ModelLifecycleManager] — admission control, one warm model, memory
///   pressure, background policy, crash forensics, prefix-cache binding.
/// * [InferenceScheduler] — priorities and preemption.
/// * [Autotuner] — first-use `se_bench` sweeps, persisted per environment.
/// * [PrefixCacheStore] — persisted KV prefixes with an LRU budget.
library;

// The Flutter-free core (FFI host, provider, lifecycle, types).
export 'engine.dart';
// The Android process host and the default host picker (need Flutter).
export 'src/engine/default_engine_host.dart';
export 'src/engine/process_engine_host.dart';
export 'src/engine/process_exit.dart';
export 'src/engine/process_messages.pigeon.dart' show BindPolicy;
