/// The Flutter-free part of `sherpa_inference`, for pure-Dart hosts (`dart
/// run`, `dart test`, CLI tools such as `sherpa_evals`): everything but the
/// Android process host, whose Binder transport needs `package:flutter`.
///
/// * [FfiEngineHost] runs the engine in-process on background isolates
///   (desktop hosts, iOS); [EngineHost] is the boundary it implements;
/// * [LlamaCppProvider] (+ [EngineEventMapper], [EngineTokenCounter]) is
///   the core `ModelProvider` over a host;
/// * [ModelLifecycleManager] with admission control and crash forensics,
///   [InferenceScheduler], [Autotuner] and [PrefixCacheStore];
/// * the engine's types and status codes ([EngineEvent], [SeStatus],
///   [SeFinish]).
///
/// `package:sherpa_inference/sherpa_inference.dart` exports all of this plus
/// [ProcessEngineHost] and `createDefaultEngineHost`. This library must not
/// import `package:flutter` (test/unit/engine_library_test.dart checks the
/// import graph).
library;

export 'src/autotune/autotune.dart';
export 'src/cache/prefix_cache_store.dart';
export 'src/common/key_value_store.dart';
export 'src/engine/engine_host.dart';
export 'src/engine/engine_types.dart';
export 'src/engine/ffi_engine_host.dart';
export 'src/ffi/bindings.dart' show SeFinish, SeStatus;
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
