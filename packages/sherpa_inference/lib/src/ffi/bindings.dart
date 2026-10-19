// Hand-written dart:ffi bindings for native/engine/include/sherpa_engine.h
// (C ABI version 1, 39 se_* functions).
//
// Why hand-written instead of ffigen: the header is small and stable, the
// struct layouts are part of the ABI contract (struct_size versioning, see
// below), and a generated file would hide the few places where Dart must not
// do the obvious thing (the *_init helpers, the event stride). Every struct
// here mirrors the header field for field and in order; `dart:ffi` applies
// the platform C ABI's alignment and padding, so `sizeOf<T>()` equals the C
// `sizeof` of the version we were written against.
//
// struct_size rules (header, "Versioned"; native/engine/src/se_internal.h
// read_params/write_out):
// * Input params: the engine starts from its own defaults and overlays the
//   first `struct_size` bytes the caller declared. We must NOT call
//   se_*_params_init() on a struct we allocated with our own sizeof: the
//   helper memsets the *engine's* sizeof, which is larger than ours as soon
//   as a newer engine appends fields. [EngineStructs] therefore lets the
//   helper fill an oversized scratch buffer (engine structs are < 64 KiB,
//   read_params rejects anything larger) and then declares
//   min(engine size, our size).
// * Output structs (memory estimate, bench result): we declare our sizeof;
//   the engine writes min(declared, its own) bytes.
// * Events live in an engine-owned array whose stride is the ENGINE's
//   sizeof(se_event) (each event's struct_size); see [eventAt].
// ignore_for_file: non_constant_identifier_names, camel_case_types
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// `SE_ABI_VERSION` these bindings were written against.
const int kSeAbiVersion = 1;

/// Status codes (`se_status`, header "Status codes").
abstract final class SeStatus {
  static const ok = 0;
  static const invalidArg = -1;
  static const oom = -2;
  static const io = -3;
  static const modelLoad = -4;
  static const contextCreate = -5;
  static const contextFull = -6;
  static const cancelled = -7;
  static const decode = -8;
  static const template = -9;
  static const grammar = -10;
  static const parse = -11;
  static const stateMismatch = -12;
  static const busy = -13;
  static const unsupported = -14;
  static const bufferTooSmall = -15;
  static const timeout = -16;
  static const abi = -17;
  static const internal = -99;

  static String name(int code) => switch (code) {
        ok => 'SE_OK',
        invalidArg => 'SE_ERR_INVALID_ARG',
        oom => 'SE_ERR_OOM',
        io => 'SE_ERR_IO',
        modelLoad => 'SE_ERR_MODEL_LOAD',
        contextCreate => 'SE_ERR_CONTEXT_CREATE',
        contextFull => 'SE_ERR_CONTEXT_FULL',
        cancelled => 'SE_ERR_CANCELLED',
        decode => 'SE_ERR_DECODE',
        template => 'SE_ERR_TEMPLATE',
        grammar => 'SE_ERR_GRAMMAR',
        parse => 'SE_ERR_PARSE',
        stateMismatch => 'SE_ERR_STATE_MISMATCH',
        busy => 'SE_ERR_BUSY',
        unsupported => 'SE_ERR_UNSUPPORTED',
        bufferTooSmall => 'SE_ERR_BUFFER_TOO_SMALL',
        timeout => 'SE_ERR_TIMEOUT',
        abi => 'SE_ERR_ABI',
        internal => 'SE_ERR_INTERNAL',
        _ => 'SE_ERR_UNKNOWN($code)',
      };
}

/// `se_event_type`.
abstract final class SeEventType {
  static const textDelta = 1;
  static const reasoningDelta = 2;
  static const toolCallStart = 3;
  static const toolCallArgsDelta = 4;
  static const toolCallDone = 5;
  static const usage = 6;
  static const perf = 7;
  static const finish = 8;
  static const error = 9;
  static const promptProgress = 10;
}

/// `se_finish_reason`.
abstract final class SeFinish {
  static const stop = 1;
  static const length = 2;
  static const toolCalls = 3;
  static const cancelled = 4;
  static const error = 5;
}

/// `SE_SEED_RANDOM`.
const int kSeSeedRandom = 0xFFFFFFFF;

// ---------------------------------------------------------------------------
// Structs

final class SeInitParams extends Struct {
  @Uint32()
  external int struct_size;
  @Int32()
  external int log_level;
  external Pointer<Void> log_cb;
  external Pointer<Void> log_user;
  external Pointer<Utf8> backend_dir;
  external Pointer<Utf8> crash_breadcrumb_path;
}

final class SeModelParams extends Struct {
  @Uint32()
  external int struct_size;
  @Int32()
  external int n_gpu_layers;
  @Int32()
  external int load_mode;
  @Int32()
  external int use_extra_bufts;
  @Int32()
  external int check_tensors;
  @Int32()
  external int load_mtp;
  @Int32()
  external int vocab_only;
  @Int32()
  external int mmproj_use_gpu;
  @Int32()
  external int draft_n_gpu_layers;
  external Pointer<Utf8> chat_template_override;
  external Pointer<Utf8> model_id;
  external Pointer<Utf8> mmproj_path;
  external Pointer<Utf8> draft_model_path;
  external Pointer<NativeFunction<SeProgressCbNative>> progress_cb;
  external Pointer<Void> progress_user;
  external Pointer<Void> cancel;
}

final class SeSessionParams extends Struct {
  @Uint32()
  external int struct_size;
  @Uint32()
  external int n_ctx;
  @Uint32()
  external int n_batch;
  @Uint32()
  external int n_ubatch;
  @Int32()
  external int n_threads;
  @Int32()
  external int n_threads_batch;
  @Int32()
  external int type_k;
  @Int32()
  external int type_v;
  @Int32()
  external int flash_attn;
  @Uint32()
  external int n_outputs_max;
  @Int32()
  external int swa_full;
  @Uint32()
  external int seed;
  @Int32()
  external int spec_type;
  @Int32()
  external int spec_n_max;
  @Int32()
  external int spec_n_min;
  @Int32()
  external int spec_ngram_n_match;
  @Float()
  external double spec_min_accept;
  @Int32()
  external int spec_min_drafted;
  @Uint32()
  external int event_capacity;
}

final class SeEvent extends Struct {
  @Uint32()
  external int struct_size;
  @Int32()
  external int type;
  @Uint32()
  external int generation_id;
  @Int32()
  external int index;
  @Int32()
  external int code;
  @Uint32()
  external int text_len;
  external Pointer<Utf8> text;
  external Pointer<Utf8> id;
  external Pointer<Utf8> name;
  @Int32()
  external int prompt_tokens;
  @Int32()
  external int cached_tokens;
  @Int32()
  external int completion_tokens;
  @Int32()
  external int n_drafted;
  @Int32()
  external int n_accepted;
  @Int32()
  external int progress_done;
  @Int32()
  external int progress_total;
  @Int32()
  external int reserved0;
  @Double()
  external double ttft_ms;
  @Double()
  external double prefill_tps;
  @Double()
  external double decode_tps;
  @Double()
  external double draft_accept_rate;
  @Double()
  external double prefill_ms;
  @Double()
  external double decode_ms;
}

final class SeMemoryEstimate extends Struct {
  @Uint32()
  external int struct_size;
  @Uint32()
  external int n_ctx;
  @Uint32()
  external int n_ctx_seq;
  @Int32()
  external int flash_attn;
  @Uint64()
  external int model_bytes;
  @Uint64()
  external int model_mapped_bytes;
  @Uint64()
  external int kv_bytes;
  @Uint64()
  external int compute_bytes;
  @Uint64()
  external int output_bytes;
  @Uint64()
  external int total_bytes;
  @Uint64()
  external int kv_bytes_per_token;
  @Uint64()
  external int file_bytes;
}

final class SeBenchParams extends Struct {
  @Uint32()
  external int struct_size;
  @Int32()
  external int n_threads;
  @Int32()
  external int n_threads_batch;
  @Uint32()
  external int n_batch;
  @Uint32()
  external int n_ubatch;
  @Uint32()
  external int n_ctx;
  @Int32()
  external int n_prompt;
  @Int32()
  external int n_gen;
  @Int32()
  external int n_reps;
  @Int32()
  external int type_k;
  @Int32()
  external int type_v;
  @Int32()
  external int flash_attn;
  external Pointer<Void> cancel;
}

final class SeBenchResult extends Struct {
  @Uint32()
  external int struct_size;
  @Int32()
  external int n_prompt;
  @Int32()
  external int n_gen;
  @Int32()
  external int n_threads;
  @Double()
  external double pp_tps;
  @Double()
  external double tg_tps;
  @Double()
  external double pp_ms;
  @Double()
  external double tg_ms;
}

// ---------------------------------------------------------------------------
// Native signatures

typedef SeProgressCbNative = Int32 Function(Float progress, Pointer<Void> user);

typedef _VoidPtrN = Pointer<Void> Function();
typedef _VoidPtrD = Pointer<Void> Function();
typedef _PtrVoidN = Void Function(Pointer<Void>);
typedef _PtrVoidD = void Function(Pointer<Void>);
typedef _PtrStatusN = Int32 Function(Pointer<Void>);
typedef _PtrStatusD = int Function(Pointer<Void>);
typedef _JsonN = Int32 Function(Pointer<Void>, Pointer<Utf8>, Int32);
typedef _JsonD = int Function(Pointer<Void>, Pointer<Utf8>, int);

/// Every `se_*` entry point, resolved once per isolate. The library handle
/// is per isolate (`DynamicLibrary.open` refcounts the same `dlopen`), the
/// native state behind it is per process, so pointers created in one isolate
/// stay valid in another.
final class SherpaEngineBindings {
  SherpaEngineBindings(DynamicLibrary lib)
      : se_last_error = lib.lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>('se_last_error'),
        se_last_error_code = lib.lookupFunction<Int32 Function(), int Function()>('se_last_error_code'),
        se_status_name =
            lib.lookupFunction<Pointer<Utf8> Function(Int32), Pointer<Utf8> Function(int)>('se_status_name'),
        se_abi_version = lib.lookupFunction<Uint32 Function(), int Function()>('se_abi_version'),
        se_version_string =
            lib.lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>('se_version_string'),
        se_init_params_init = lib.lookupFunction<_PtrVoidN, _PtrVoidD>('se_init_params_init'),
        se_backend_init = lib.lookupFunction<_PtrStatusN, _PtrStatusD>('se_backend_init'),
        se_system_info_json = lib.lookupFunction<Int32 Function(Pointer<Utf8>, Int32), int Function(Pointer<Utf8>, int)>(
            'se_system_info_json'),
        se_canceller_create = lib.lookupFunction<_VoidPtrN, _VoidPtrD>('se_canceller_create'),
        se_canceller_cancel = lib.lookupFunction<_PtrVoidN, _PtrVoidD>('se_canceller_cancel'),
        se_canceller_reset = lib.lookupFunction<_PtrVoidN, _PtrVoidD>('se_canceller_reset'),
        se_canceller_free = lib.lookupFunction<_PtrVoidN, _PtrVoidD>('se_canceller_free'),
        se_model_params_init = lib.lookupFunction<_PtrVoidN, _PtrVoidD>('se_model_params_init'),
        se_model_load = lib.lookupFunction<Int32 Function(Pointer<Utf8>, Pointer<Void>, Pointer<Pointer<Void>>),
            int Function(Pointer<Utf8>, Pointer<Void>, Pointer<Pointer<Void>>)>('se_model_load'),
        se_model_free = lib.lookupFunction<_PtrVoidN, _PtrVoidD>('se_model_free'),
        se_model_info_json = lib.lookupFunction<_JsonN, _JsonD>('se_model_info_json'),
        se_tokenize = lib.lookupFunction<
            Int32 Function(Pointer<Void>, Pointer<Utf8>, Int32, Int32, Int32, Pointer<Int32>, Int32),
            int Function(Pointer<Void>, Pointer<Utf8>, int, int, int, Pointer<Int32>, int)>('se_tokenize'),
        se_detokenize = lib.lookupFunction<
            Int32 Function(Pointer<Void>, Pointer<Int32>, Int32, Int32, Pointer<Utf8>, Int32),
            int Function(Pointer<Void>, Pointer<Int32>, int, int, Pointer<Utf8>, int)>('se_detokenize'),
        se_count_chat_tokens = lib.lookupFunction<Int32 Function(Pointer<Void>, Pointer<Utf8>),
            int Function(Pointer<Void>, Pointer<Utf8>)>('se_count_chat_tokens'),
        se_session_params_init = lib.lookupFunction<_PtrVoidN, _PtrVoidD>('se_session_params_init'),
        se_session_create = lib.lookupFunction<Int32 Function(Pointer<Void>, Pointer<Void>, Pointer<Pointer<Void>>),
            int Function(Pointer<Void>, Pointer<Void>, Pointer<Pointer<Void>>)>('se_session_create'),
        se_session_free = lib.lookupFunction<_PtrVoidN, _PtrVoidD>('se_session_free'),
        se_session_reset = lib.lookupFunction<_PtrStatusN, _PtrStatusD>('se_session_reset'),
        se_session_set_threads = lib.lookupFunction<Int32 Function(Pointer<Void>, Int32, Int32),
            int Function(Pointer<Void>, int, int)>('se_session_set_threads'),
        se_session_info_json = lib.lookupFunction<_JsonN, _JsonD>('se_session_info_json'),
        se_generate_start = lib.lookupFunction<Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Uint32>),
            int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Uint32>)>('se_generate_start'),
        se_poll_events = lib.lookupFunction<
            Int32 Function(Pointer<Void>, Int32, Int32, Pointer<Pointer<SeEvent>>, Pointer<Int32>),
            int Function(Pointer<Void>, int, int, Pointer<Pointer<SeEvent>>, Pointer<Int32>)>('se_poll_events'),
        se_set_event_callback = lib.lookupFunction<Int32 Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, Int32),
            int Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, int)>('se_set_event_callback'),
        se_cancel = lib.lookupFunction<_PtrStatusN, _PtrStatusD>('se_cancel'),
        se_wait = lib.lookupFunction<Int32 Function(Pointer<Void>, Int32), int Function(Pointer<Void>, int)>('se_wait'),
        se_state_save = lib.lookupFunction<Int32 Function(Pointer<Void>, Pointer<Utf8>),
            int Function(Pointer<Void>, Pointer<Utf8>)>('se_state_save'),
        se_state_load = lib.lookupFunction<Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Int32>),
            int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Int32>)>('se_state_load'),
        se_lora_load = lib.lookupFunction<Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Pointer<Void>>),
            int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Pointer<Void>>)>('se_lora_load'),
        se_lora_free = lib.lookupFunction<_PtrVoidN, _PtrVoidD>('se_lora_free'),
        se_session_set_loras = lib.lookupFunction<
            Int32 Function(Pointer<Void>, Pointer<Pointer<Void>>, Pointer<Float>, Int32),
            int Function(Pointer<Void>, Pointer<Pointer<Void>>, Pointer<Float>, int)>('se_session_set_loras'),
        se_estimate_memory = lib.lookupFunction<
            Int32 Function(Pointer<Utf8>, Pointer<Void>, Pointer<Void>, Pointer<SeMemoryEstimate>),
            int Function(Pointer<Utf8>, Pointer<Void>, Pointer<Void>, Pointer<SeMemoryEstimate>)>('se_estimate_memory'),
        se_session_memory = lib.lookupFunction<Int32 Function(Pointer<Void>, Pointer<SeMemoryEstimate>),
            int Function(Pointer<Void>, Pointer<SeMemoryEstimate>)>('se_session_memory'),
        se_bench_params_init = lib.lookupFunction<_PtrVoidN, _PtrVoidD>('se_bench_params_init'),
        se_bench = lib.lookupFunction<Int32 Function(Pointer<Void>, Pointer<Void>, Pointer<SeBenchResult>),
            int Function(Pointer<Void>, Pointer<Void>, Pointer<SeBenchResult>)>('se_bench');

  final Pointer<Utf8> Function() se_last_error;
  final int Function() se_last_error_code;
  final Pointer<Utf8> Function(int) se_status_name;
  final int Function() se_abi_version;
  final Pointer<Utf8> Function() se_version_string;
  final void Function(Pointer<Void>) se_init_params_init;
  final int Function(Pointer<Void>) se_backend_init;
  final int Function(Pointer<Utf8>, int) se_system_info_json;
  final Pointer<Void> Function() se_canceller_create;
  final void Function(Pointer<Void>) se_canceller_cancel;
  final void Function(Pointer<Void>) se_canceller_reset;
  final void Function(Pointer<Void>) se_canceller_free;
  final void Function(Pointer<Void>) se_model_params_init;
  final int Function(Pointer<Utf8>, Pointer<Void>, Pointer<Pointer<Void>>) se_model_load;
  final void Function(Pointer<Void>) se_model_free;
  final int Function(Pointer<Void>, Pointer<Utf8>, int) se_model_info_json;
  final int Function(Pointer<Void>, Pointer<Utf8>, int, int, int, Pointer<Int32>, int) se_tokenize;
  final int Function(Pointer<Void>, Pointer<Int32>, int, int, Pointer<Utf8>, int) se_detokenize;
  final int Function(Pointer<Void>, Pointer<Utf8>) se_count_chat_tokens;
  final void Function(Pointer<Void>) se_session_params_init;
  final int Function(Pointer<Void>, Pointer<Void>, Pointer<Pointer<Void>>) se_session_create;
  final void Function(Pointer<Void>) se_session_free;
  final int Function(Pointer<Void>) se_session_reset;
  final int Function(Pointer<Void>, int, int) se_session_set_threads;
  final int Function(Pointer<Void>, Pointer<Utf8>, int) se_session_info_json;
  final int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Uint32>) se_generate_start;
  final int Function(Pointer<Void>, int, int, Pointer<Pointer<SeEvent>>, Pointer<Int32>) se_poll_events;

  /// Bound for completeness of the ABI. Never call it with a Dart callback:
  /// the event is valid only during the synchronous call on the engine's
  /// worker thread, which a `NativeCallable.listener` cannot honour (header
  /// comment on se_set_event_callback). Dart polls.
  final int Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, int) se_set_event_callback;
  final int Function(Pointer<Void>) se_cancel;
  final int Function(Pointer<Void>, int) se_wait;
  final int Function(Pointer<Void>, Pointer<Utf8>) se_state_save;
  final int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Int32>) se_state_load;
  final int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Pointer<Void>>) se_lora_load;
  final void Function(Pointer<Void>) se_lora_free;
  final int Function(Pointer<Void>, Pointer<Pointer<Void>>, Pointer<Float>, int) se_session_set_loras;
  final int Function(Pointer<Utf8>, Pointer<Void>, Pointer<Void>, Pointer<SeMemoryEstimate>) se_estimate_memory;
  final int Function(Pointer<Void>, Pointer<SeMemoryEstimate>) se_session_memory;
  final void Function(Pointer<Void>) se_bench_params_init;
  final int Function(Pointer<Void>, Pointer<Void>, Pointer<SeBenchResult>) se_bench;

  /// Number of `se_*` functions bound above (header: 39).
  static const int functionCount = 39;

  /// Thread-local message of the last failed call on this thread. Call it
  /// right after the failing call, on the same isolate (same thread).
  String lastError() => se_last_error().toDartString();

  String versionString() => se_version_string().toDartString();

  /// Calls a `*_json(buf, cap)` function with the size-then-fill protocol
  /// (header "Return conventions"): the first call learns the length, the
  /// second writes it.
  String readJson(int Function(Pointer<Utf8> buf, int cap) fn) {
    var cap = 4096;
    for (var attempt = 0; attempt < 3; attempt++) {
      final buf = calloc<Uint8>(cap);
      try {
        final n = fn(buf.cast(), cap);
        if (n < 0) throw SeCallException(n, lastError());
        if (n < cap) return buf.cast<Utf8>().toDartString(length: n);
        cap = n + 1;
      } finally {
        calloc.free(buf);
      }
    }
    throw const SeCallException(SeStatus.bufferTooSmall, 'JSON kept growing between calls');
  }
}

/// A failed `se_*` call: the status code plus `se_last_error()`.
final class SeCallException implements Exception {
  const SeCallException(this.code, this.message);

  final int code;
  final String message;

  String get codeName => SeStatus.name(code);

  @override
  String toString() => 'SeCallException($codeName): $message';
}

/// Allocation of versioned params structs with the engine's own defaults
/// (see the library comment for why the *_init helper writes into scratch).
abstract final class EngineStructs {
  /// Upper bound the engine accepts for `struct_size` (se_internal.h:77).
  static const int _maxStructBytes = 1 << 16;

  /// Allocates a `T` pre-filled with the engine defaults from [init] and
  /// with `struct_size` = min(engine sizeof, our sizeof). Free it with
  /// `calloc.free`.
  static Pointer<T> params<T extends Struct>(
    void Function(Pointer<Void>) init,
    int ourSize,
  ) {
    final scratch = calloc<Uint8>(_maxStructBytes);
    try {
      init(scratch.cast());
      final engineSize = scratch.cast<Uint32>().value;
      final declared = engineSize < ourSize ? engineSize : ourSize;
      final out = calloc<Uint8>(ourSize);
      for (var i = 0; i < declared; i++) {
        out[i] = scratch[i];
      }
      out.cast<Uint32>().value = declared;
      return out.cast<T>();
    } finally {
      calloc.free(scratch);
    }
  }

  /// An output struct of our size with `struct_size` set.
  static Pointer<T> output<T extends Struct>(int ourSize) {
    final p = calloc<Uint8>(ourSize);
    p.cast<Uint32>().value = ourSize;
    return p.cast<T>();
  }
}

/// The [i]-th event of a batch returned by `se_poll_events`. The stride is
/// the engine's `sizeof(se_event)` (each event's `struct_size`), not ours,
/// so a newer engine that appended fields is still read correctly; fields it
/// appended are ignored.
SeEvent eventAt(Pointer<SeEvent> base, int i) {
  final stride = base.ref.struct_size;
  return Pointer<SeEvent>.fromAddress(base.address + i * stride).ref;
}
