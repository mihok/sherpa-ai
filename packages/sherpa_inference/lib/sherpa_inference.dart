/// On-device inference for Sherpa (Flutter FFI plugin).
///
/// Layers, bottom up:
/// * `ffi/` — hand-written bindings to `native/engine/include/sherpa_engine.h`
///   and the platform library loader.
/// * [EngineHost] — the engine boundary (contract in its doc comment);
///   [FfiEngineHost] runs the engine in-process on background isolates. The
///   Android `:inference` process host implements the same interface.
/// * [LlamaCppProvider] — the core `ModelProvider` over a host, with
///   [EngineTokenCounter] (+ [WarmingContextManager]) for exact counts.
/// * [ModelLifecycleManager] — admission control, one warm model, memory
///   pressure, background policy, crash forensics, prefix-cache binding.
/// * [InferenceScheduler] — priorities and preemption.
/// * [Autotuner] — first-use `se_bench` sweeps, persisted per environment.
/// * [PrefixCacheStore] — persisted KV prefixes with an LRU budget.
library;

export 'src/autotune/autotune.dart';
export 'src/cache/prefix_cache_store.dart';
export 'src/common/key_value_store.dart';
export 'src/engine/engine_host.dart';
export 'src/engine/engine_types.dart';
export 'src/engine/ffi_engine_host.dart';
export 'src/ffi/library_loader.dart' show EngineLibrary, EngineUnavailableException, kEngineLibraryEnv;
export 'src/lifecycle/admission.dart';
export 'src/lifecycle/forensics.dart';
export 'src/lifecycle/lifecycle_manager.dart';
export 'src/provider/event_mapper.dart';
export 'src/provider/llama_cpp_provider.dart';
export 'src/provider/model_info.dart';
export 'src/provider/request_mapper.dart';
export 'src/provider/token_counter.dart';
export 'src/scheduler/inference_scheduler.dart';
