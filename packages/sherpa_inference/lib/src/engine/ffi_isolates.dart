// The two long-lived background isolates behind FfiEngineHost.
//
// Why two:
// * The WORKER runs every blocking engine call (model load, memory dry run,
//   session creation, state save/load, bench, tokenization). While it sits
//   inside a multi-second `se_model_load` it cannot process messages, so it
//   can neither cancel that load nor keep streaming another session's
//   tokens.
// * The PUMP owns everything that must stay responsive: `se_generate_start`
//   (returns immediately), `se_poll_events` (the single consumer of every
//   session's event ring, header "Threading"), `se_cancel`, and the
//   `se_canceller` tokens that abort the worker's blocking calls. Its loop
//   blocks in native code for at most [kPumpPollTimeoutMs] at a time and
//   yields to its message queue in between, so a cancel is acted on within
//   a few milliseconds.
//
// No FFI call ever runs on the UI isolate: the main-isolate side
// (FfiEngineHost) only sends and receives messages.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import '../ffi/bindings.dart';
import '../ffi/library_loader.dart';
import 'engine_types.dart';

/// Longest time the pump blocks inside `se_poll_events` before it looks at
/// its message queue again (cancel latency bound).
const int kPumpPollTimeoutMs = 4;

/// Delivery cadence: text deltas are coalesced for about one frame (~16 ms)
/// so the UI isolate handles ~60 messages per second instead of one per
/// token. The first delta of a generation is sent immediately (TTFT).
const Duration kCoalesceWindow = Duration(milliseconds: 16);

/// Upper bound of events held in one coalescing buffer.
const int kMaxPendingEvents = 256;

/// Batches a stream may have in flight / buffered on the main isolate
/// before the pump stops polling that session (the bounded queue that turns
/// a paused subscription into engine backpressure).
const int kStreamCredits = 4;

// ---------------------------------------------------------------------------
// Messages: main <-> worker

final class WorkerRequest {
  const WorkerRequest(this.id, this.op, this.args);
  final int id;
  final String op;
  final List<Object?> args;
}

final class WorkerReply {
  const WorkerReply(this.id, {this.result, this.errorCode, this.errorMessage});
  final int id;
  final Object? result;
  final int? errorCode;
  final String? errorMessage;
}

final class WorkerProgress {
  const WorkerProgress(this.id, this.progress);
  final int id;
  final double progress;
}

// ---------------------------------------------------------------------------
// Messages: main <-> pump

sealed class PumpCommand {
  const PumpCommand();
}

final class PumpStart extends PumpCommand {
  const PumpStart(this.streamId, this.session, this.requestJson);
  final int streamId;
  final int session;
  final String requestJson;
}

final class PumpCredit extends PumpCommand {
  const PumpCredit(this.streamId, this.n);
  final int streamId;
  final int n;
}

/// The consumer went away: cancel, then drain and discard until FINISH.
final class PumpCancelStream extends PumpCommand {
  const PumpCancelStream(this.streamId);
  final int streamId;
}

/// Cancel whatever runs on a session; the stream (if any) gets FINISH.
final class PumpCancelSession extends PumpCommand {
  const PumpCancelSession(this.session);
  final int session;
}

/// Stop touching [session] (it is about to be freed). Streams on it are
/// dropped; the reply is [PumpAck].
final class PumpRelease extends PumpCommand {
  const PumpRelease(this.requestId, this.session);
  final int requestId;
  final int session;
}

/// After a pump restart: cancel and drain sessions that may still have a
/// generation running from the previous pump.
final class PumpRecover extends PumpCommand {
  const PumpRecover(this.sessions);
  final List<int> sessions;
}

final class PumpCreateCanceller extends PumpCommand {
  const PumpCreateCanceller(this.requestId);
  final int requestId;
}

final class PumpCancelCanceller extends PumpCommand {
  const PumpCancelCanceller(this.addr);
  final int addr;
}

final class PumpFreeCanceller extends PumpCommand {
  const PumpFreeCanceller(this.addr);
  final int addr;
}

final class PumpShutdown extends PumpCommand {
  const PumpShutdown(this.requestId);
  final int requestId;
}

sealed class PumpMessage {
  const PumpMessage();
}

final class PumpReady extends PumpMessage {
  const PumpReady(this.port);
  final SendPort port;
}

final class PumpStarted extends PumpMessage {
  const PumpStarted(this.streamId, this.generationId);
  final int streamId;
  final int generationId;
}

final class PumpStartFailed extends PumpMessage {
  const PumpStartFailed(this.streamId, this.code, this.message);
  final int streamId;
  final int code;
  final String message;
}

final class PumpBatch extends PumpMessage {
  const PumpBatch(this.streamId, this.events, {required this.last});
  final int streamId;
  final List<EngineEvent> events;

  /// Contains the FINISH event; the stream is complete.
  final bool last;
}

/// A session became idle from the pump's point of view (its last generation
/// reached FINISH, delivered or discarded).
final class PumpSessionIdle extends PumpMessage {
  const PumpSessionIdle(this.session);
  final int session;
}

final class PumpAck extends PumpMessage {
  const PumpAck(this.requestId, [this.value = 0]);
  final int requestId;
  final int value;
}

String _describe(EngineUnavailableException e) => e.cause == null ? e.message : '${e.message}: ${e.cause}';

// ---------------------------------------------------------------------------
// Worker isolate

/// Entry point: `[SendPort replyTo, String? libraryPath]`.
void engineWorkerMain(List<Object?> args) {
  final replyTo = args[0]! as SendPort;
  final path = args[1] as String?;
  final port = ReceivePort();
  final EngineLibrary lib;
  try {
    lib = EngineLibrary.open(path: path);
  } on EngineUnavailableException catch (e) {
    replyTo.send(WorkerReply(-1, errorCode: SeStatus.unsupported, errorMessage: _describe(e)));
    port.close();
    return;
  }
  final worker = _Worker(lib.bindings, replyTo);
  replyTo.send(port.sendPort);
  port.listen((Object? msg) {
    if (msg is WorkerRequest) {
      if (msg.op == 'shutdown') {
        replyTo.send(WorkerReply(msg.id));
        port.close();
        return;
      }
      replyTo.send(worker.handle(msg));
    }
  });
}

final class _Worker {
  _Worker(this.b, this.replyTo);

  final SherpaEngineBindings b;
  final SendPort replyTo;

  WorkerReply handle(WorkerRequest r) {
    try {
      return WorkerReply(r.id, result: _dispatch(r));
    } on SeCallException catch (e) {
      return WorkerReply(r.id, errorCode: e.code, errorMessage: e.message);
    } on Object catch (e) {
      return WorkerReply(r.id, errorCode: SeStatus.internal, errorMessage: 'worker: $e');
    }
  }

  Object? _dispatch(WorkerRequest r) {
    final a = r.args;
    switch (r.op) {
      case 'init':
        return _init(a[0] as String?, a[1] as String?);
      case 'systemInfo':
        return b.readJson(b.se_system_info_json);
      case 'loadModel':
        return _loadModel(r.id, a[0]! as ModelLoadOptions, a[1]! as int, a[2]! as bool);
      case 'freeModel':
        b.se_model_free(_ptr(a[0]));
        return null;
      case 'estimate':
        return _estimate(a[0]! as ModelLoadOptions, a[1]! as SessionConfig);
      case 'createSession':
        return _createSession(_ptr(a[0]), a[1]! as SessionConfig);
      case 'freeSession':
        b.se_session_free(_ptr(a[0]));
        return null;
      case 'resetSession':
        _idle(a[0]);
        _check(b.se_session_reset(_ptr(a[0])));
        return null;
      case 'setThreads':
        _idle(a[0]);
        _check(b.se_session_set_threads(_ptr(a[0]), a[1]! as int, a[2]! as int));
        return null;
      case 'sessionInfo':
        final s = _ptr(a[0]);
        return b.readJson((buf, cap) => b.se_session_info_json(s, buf, cap));
      case 'sessionMemory':
        return _sessionMemory(_ptr(a[0]));
      case 'modelInfo':
        final m = _ptr(a[0]);
        return b.readJson((buf, cap) => b.se_model_info_json(m, buf, cap));
      case 'tokenize':
        return _tokenize(_ptr(a[0]), a[1]! as String, a[2]! as bool, a[3]! as bool);
      case 'detokenize':
        return _detokenize(_ptr(a[0]), (a[1]! as List<Object?>).cast<int>(), a[2]! as bool);
      case 'countChat':
        return _countChat(_ptr(a[0]), a[1]! as String);
      case 'countBatch':
        return _countBatch(_ptr(a[0]), (a[1]! as List<Object?>).cast<String>(), (a[2]! as List<Object?>).cast<String>());
      case 'stateSave':
        _idle(a[0]);
        return using((arena) {
          _check(b.se_state_save(_ptr(a[0]), (a[1]! as String).toNativeUtf8(allocator: arena)));
          return null;
        });
      case 'stateLoad':
        _idle(a[0]);
        return using((arena) {
          final n = arena<Int32>();
          _check(b.se_state_load(_ptr(a[0]), (a[1]! as String).toNativeUtf8(allocator: arena), n));
          return n.value;
        });
      case 'loraLoad':
        return using((arena) {
          final out = arena<Pointer<Void>>();
          _check(b.se_lora_load(_ptr(a[0]), (a[1]! as String).toNativeUtf8(allocator: arena), out));
          return out.value.address;
        });
      case 'loraFree':
        b.se_lora_free(_ptr(a[0]));
        return null;
      case 'setLoras':
        _idle(a[0]);
        return _setLoras(_ptr(a[0]), (a[1]! as List<Object?>).cast<int>(), (a[2]! as List<Object?>).cast<double>());
      case 'bench':
        return _bench(_ptr(a[0]), a[1]! as BenchConfig, a[2]! as int);
      default:
        throw SeCallException(SeStatus.invalidArg, 'unknown worker op ${r.op}');
    }
  }

  static Pointer<Void> _ptr(Object? addr) => Pointer<Void>.fromAddress(addr! as int);

  void _check(int status) {
    if (status < 0) throw SeCallException(status, b.lastError());
  }

  /// A session op right after FINISH can race the engine worker clearing
  /// its busy flag (it is cleared after the FINISH event is queued,
  /// se_session.cpp worker_main). A short se_wait closes that window; a
  /// generation that is really running still yields SE_ERR_BUSY.
  void _idle(Object? session) => b.se_wait(_ptr(session), 200);

  List<Object?> _init(String? breadcrumbPath, String? backendDir) {
    using((arena) {
      final p = EngineStructs.params<SeInitParams>(b.se_init_params_init, sizeOf<SeInitParams>());
      try {
        // log_cb stays NULL: the engine calls it from any thread with a
        // message valid only during the call, which no Dart callback type
        // can honour (a listener runs later, isolate-local callbacks abort
        // on foreign threads). NULL = stderr / logcat "sherpa_engine".
        if (breadcrumbPath != null) p.ref.crash_breadcrumb_path = breadcrumbPath.toNativeUtf8(allocator: arena);
        if (backendDir != null) p.ref.backend_dir = backendDir.toNativeUtf8(allocator: arena);
        _check(b.se_backend_init(p.cast()));
      } finally {
        calloc.free(p);
      }
    });
    return [b.se_abi_version(), b.versionString(), b.readJson(b.se_system_info_json)];
  }

  Pointer<SeModelParams> _modelParams(ModelLoadOptions o, Arena arena) {
    final p = EngineStructs.params<SeModelParams>(b.se_model_params_init, sizeOf<SeModelParams>());
    arena.onReleaseAll(() => calloc.free(p));
    final r = p.ref
      ..n_gpu_layers = o.nGpuLayers
      ..load_mode = o.loadMode.code
      ..use_extra_bufts = o.useExtraBuffers ? 1 : 0
      ..vocab_only = o.vocabOnly ? 1 : 0
      ..load_mtp = o.loadMtp ? 1 : 0;
    if (o.chatTemplateOverride != null) r.chat_template_override = o.chatTemplateOverride!.toNativeUtf8(allocator: arena);
    if (o.modelId != null) r.model_id = o.modelId!.toNativeUtf8(allocator: arena);
    if (o.mmprojPath != null) r.mmproj_path = o.mmprojPath!.toNativeUtf8(allocator: arena);
    if (o.draftModelPath != null) r.draft_model_path = o.draftModelPath!.toNativeUtf8(allocator: arena);
    return p;
  }

  Pointer<SeSessionParams> _sessionParams(SessionConfig c, Arena arena) {
    final p = EngineStructs.params<SeSessionParams>(b.se_session_params_init, sizeOf<SeSessionParams>());
    arena.onReleaseAll(() => calloc.free(p));
    p.ref
      ..n_ctx = c.nCtx
      ..n_batch = c.nBatch
      ..n_ubatch = c.nUbatch
      ..n_threads = c.nThreads
      ..n_threads_batch = c.nThreadsBatch
      ..type_k = c.typeK.code
      ..type_v = c.typeV.code
      ..flash_attn = c.flashAttention.code
      ..n_outputs_max = c.nOutputsMax
      ..swa_full = c.swaFull
      ..seed = c.seed
      ..spec_type = c.speculative.code
      ..spec_n_max = c.specMaxDraft
      ..event_capacity = c.eventCapacity;
    return p;
  }

  List<Object?> _loadModel(int requestId, ModelLoadOptions o, int canceller, bool wantProgress) {
    return using((arena) {
      final p = _modelParams(o, arena);
      if (canceller != 0) p.ref.cancel = Pointer<Void>.fromAddress(canceller);
      NativeCallable<SeProgressCbNative>? cb;
      if (wantProgress) {
        var last = -1.0;
        // Invoked synchronously on this isolate's thread: llama.cpp reports
        // progress from the loading loop of the thread that called
        // se_model_load (llama-model-loader.cpp load_all_data).
        cb = NativeCallable<SeProgressCbNative>.isolateLocal((double progress, Pointer<Void> _) {
          if (progress - last >= 0.01 || progress >= 1.0) {
            last = progress;
            replyTo.send(WorkerProgress(requestId, progress));
          }
          return 1;
        }, exceptionalReturn: 1);
        p.ref.progress_cb = cb.nativeFunction;
      }
      try {
        final out = arena<Pointer<Void>>();
        _check(b.se_model_load(o.path.toNativeUtf8(allocator: arena), p.cast(), out));
        final m = out.value;
        final info = b.readJson((buf, cap) => b.se_model_info_json(m, buf, cap));
        return [m.address, info];
      } finally {
        cb?.close();
      }
    });
  }

  MemoryEstimate _estimate(ModelLoadOptions o, SessionConfig c) => using((arena) {
        final mp = _modelParams(o, arena);
        final sp = _sessionParams(c, arena);
        final out = EngineStructs.output<SeMemoryEstimate>(sizeOf<SeMemoryEstimate>());
        arena.onReleaseAll(() => calloc.free(out));
        _check(b.se_estimate_memory(o.path.toNativeUtf8(allocator: arena), mp.cast(), sp.cast(), out));
        return _readEstimate(out.ref);
      });

  MemoryEstimate _sessionMemory(Pointer<Void> s) => using((arena) {
        final out = EngineStructs.output<SeMemoryEstimate>(sizeOf<SeMemoryEstimate>());
        arena.onReleaseAll(() => calloc.free(out));
        _check(b.se_session_memory(s, out));
        return _readEstimate(out.ref);
      });

  static MemoryEstimate _readEstimate(SeMemoryEstimate e) => MemoryEstimate(
        nCtx: e.n_ctx,
        nCtxSeq: e.n_ctx_seq,
        flashAttention: e.flash_attn == 1,
        modelBytes: e.model_bytes,
        modelMappedBytes: e.model_mapped_bytes,
        kvBytes: e.kv_bytes,
        computeBytes: e.compute_bytes,
        outputBytes: e.output_bytes,
        totalBytes: e.total_bytes,
        kvBytesPerToken: e.kv_bytes_per_token,
        fileBytes: e.file_bytes,
      );

  List<Object?> _createSession(Pointer<Void> model, SessionConfig c) => using((arena) {
        final sp = _sessionParams(c, arena);
        final out = arena<Pointer<Void>>();
        _check(b.se_session_create(model, sp.cast(), out));
        final s = out.value;
        return [s.address, b.readJson((buf, cap) => b.se_session_info_json(s, buf, cap))];
      });

  List<int> _tokenize(Pointer<Void> m, String text, bool addSpecial, bool parseSpecial) => using((arena) {
        final units = text.toNativeUtf8(allocator: arena);
        final len = units.length;
        final n = b.se_tokenize(m, units, len, addSpecial ? 1 : 0, parseSpecial ? 1 : 0, nullptr, 0);
        if (n < 0) throw SeCallException(n, b.lastError());
        final toks = arena<Int32>(n == 0 ? 1 : n);
        final n2 = b.se_tokenize(m, units, len, addSpecial ? 1 : 0, parseSpecial ? 1 : 0, toks, n);
        if (n2 < 0) throw SeCallException(n2, b.lastError());
        return List<int>.generate(n2, (i) => toks[i]);
      });

  String _detokenize(Pointer<Void> m, List<int> tokens, bool renderSpecial) => using((arena) {
        final toks = arena<Int32>(tokens.isEmpty ? 1 : tokens.length);
        for (var i = 0; i < tokens.length; i++) {
          toks[i] = tokens[i];
        }
        final n = b.se_detokenize(m, toks, tokens.length, renderSpecial ? 1 : 0, nullptr, 0);
        if (n < 0) throw SeCallException(n, b.lastError());
        final buf = arena<Uint8>(n + 1);
        final n2 = b.se_detokenize(m, toks, tokens.length, renderSpecial ? 1 : 0, buf.cast(), n + 1);
        if (n2 < 0) throw SeCallException(n2, b.lastError());
        return buf.cast<Utf8>().toDartString(length: n2);
      });

  int _countChat(Pointer<Void> m, String json) => using((arena) {
        final n = b.se_count_chat_tokens(m, json.toNativeUtf8(allocator: arena));
        if (n < 0) throw SeCallException(n, b.lastError());
        return n;
      });

  List<int> _countBatch(Pointer<Void> m, List<String> texts, List<String> chats) => using((arena) {
        final out = <int>[];
        for (final t in texts) {
          final u = t.toNativeUtf8(allocator: arena);
          out.add(b.se_tokenize(m, u, u.length, 0, 0, nullptr, 0));
        }
        for (final c in chats) {
          out.add(b.se_count_chat_tokens(m, c.toNativeUtf8(allocator: arena)));
        }
        return out;
      });

  Object? _setLoras(Pointer<Void> s, List<int> loras, List<double> scales) => using((arena) {
        final n = loras.length;
        final lp = arena<Pointer<Void>>(n == 0 ? 1 : n);
        final sc = arena<Float>(n == 0 ? 1 : n);
        for (var i = 0; i < n; i++) {
          lp[i] = Pointer<Void>.fromAddress(loras[i]);
          sc[i] = scales[i];
        }
        _check(b.se_session_set_loras(s, lp, sc, n));
        return null;
      });

  BenchResult _bench(Pointer<Void> m, BenchConfig c, int canceller) => using((arena) {
        final p = EngineStructs.params<SeBenchParams>(b.se_bench_params_init, sizeOf<SeBenchParams>());
        arena.onReleaseAll(() => calloc.free(p));
        p.ref
          ..n_threads = c.nThreads
          ..n_threads_batch = c.nThreadsBatch
          ..n_batch = c.nBatch
          ..n_ubatch = c.nUbatch
          ..n_ctx = c.nCtx
          ..n_prompt = c.nPrompt
          ..n_gen = c.nGen
          ..n_reps = c.nReps
          ..type_k = c.typeK.code
          ..type_v = c.typeV.code
          ..flash_attn = c.flashAttention.code
          ..cancel = Pointer<Void>.fromAddress(canceller);
        final out = EngineStructs.output<SeBenchResult>(sizeOf<SeBenchResult>());
        arena.onReleaseAll(() => calloc.free(out));
        _check(b.se_bench(m, p.cast(), out));
        final r = out.ref;
        return BenchResult(
          nPrompt: r.n_prompt,
          nGen: r.n_gen,
          nThreads: r.n_threads,
          promptTokensPerSec: r.pp_tps,
          genTokensPerSec: r.tg_tps,
          promptMs: r.pp_ms,
          genMs: r.tg_ms,
        );
      });
}

// ---------------------------------------------------------------------------
// Pump isolate

/// Entry point: `[SendPort replyTo, String? libraryPath]`.
void enginePumpMain(List<Object?> args) {
  final replyTo = args[0]! as SendPort;
  final path = args[1] as String?;
  final EngineLibrary lib;
  try {
    lib = EngineLibrary.open(path: path);
  } on EngineUnavailableException catch (e) {
    replyTo.send(PumpStartFailed(-1, SeStatus.unsupported, _describe(e)));
    return;
  }
  final pump = _Pump(lib.bindings, replyTo);
  replyTo.send(PumpReady(pump.port.sendPort));
  unawaited(pump.run());
}

final class _Gen {
  _Gen(this.streamId, this.session);

  final int streamId;
  final int session;
  int generationId = -1;
  int credits = kStreamCredits;

  /// Consumer gone: drain and discard until FINISH.
  bool discard = false;
  bool finished = false;
  bool sentAny = false;
  final List<EngineEvent> pending = [];
  int pendingSince = 0;

  /// Recovery drain after a pump restart: accept FINISH of any generation.
  bool anyGeneration = false;

  bool get canPoll => !finished && (discard || (credits > 0 && pending.length < kMaxPendingEvents));
}

final class _Pump {
  _Pump(this.b, this.replyTo) {
    port.listen(_onMessage);
  }

  final SherpaEngineBindings b;
  final SendPort replyTo;
  final ReceivePort port = ReceivePort();
  final Stopwatch _clock = Stopwatch()..start();

  /// Active generations by stream id; at most one per session.
  final Map<int, _Gen> _gens = {};

  /// Starts queued behind a session's running/draining generation.
  final Map<int, List<PumpStart>> _waiting = {};
  final Pointer<Pointer<SeEvent>> _evOut = calloc<Pointer<SeEvent>>();
  final Pointer<Int32> _nOut = calloc<Int32>();
  Completer<void>? _wake;
  bool _shutdown = false;

  void _signal() {
    final w = _wake;
    _wake = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  _Gen? _genForSession(int session) {
    for (final g in _gens.values) {
      if (g.session == session) return g;
    }
    return null;
  }

  void _onMessage(Object? msg) {
    switch (msg) {
      case PumpStart():
        if (_genForSession(msg.session) != null) {
          (_waiting[msg.session] ??= []).add(msg);
        } else {
          _start(msg);
        }
      case PumpCredit(:final streamId, :final n):
        final g = _gens[streamId];
        if (g != null) g.credits += n;
      case PumpCancelStream(:final streamId):
        final g = _gens[streamId];
        if (g != null) {
          g.discard = true;
          g.pending.clear();
          b.se_cancel(Pointer<Void>.fromAddress(g.session));
        } else {
          for (final q in _waiting.values) {
            q.removeWhere((s) => s.streamId == streamId);
          }
        }
      case PumpCancelSession(:final session):
        b.se_cancel(Pointer<Void>.fromAddress(session));
      case PumpRelease(:final requestId, :final session):
        _gens.removeWhere((_, g) => g.session == session);
        final queued = _waiting.remove(session) ?? const [];
        for (final s in queued) {
          replyTo.send(PumpStartFailed(s.streamId, SeStatus.invalidArg, 'session was freed'));
        }
        replyTo.send(PumpAck(requestId));
      case PumpRecover(:final sessions):
        for (final s in sessions) {
          b.se_cancel(Pointer<Void>.fromAddress(s));
          _gens[-s] = _Gen(-s, s)
            ..discard = true
            ..anyGeneration = true;
        }
      case PumpCreateCanceller(:final requestId):
        replyTo.send(PumpAck(requestId, b.se_canceller_create().address));
      case PumpCancelCanceller(:final addr):
        b.se_canceller_cancel(Pointer<Void>.fromAddress(addr));
      case PumpFreeCanceller(:final addr):
        b.se_canceller_free(Pointer<Void>.fromAddress(addr));
      case PumpShutdown(:final requestId):
        _shutdown = true;
        for (final g in _gens.values) {
          b.se_cancel(Pointer<Void>.fromAddress(g.session));
        }
        replyTo.send(PumpAck(requestId));
    }
    _signal();
  }

  void _start(PumpStart s) {
    final status = using((arena) {
      final id = arena<Uint32>();
      final rc = b.se_generate_start(Pointer<Void>.fromAddress(s.session), s.requestJson.toNativeUtf8(allocator: arena), id);
      return (rc, id.value, rc < 0 ? b.lastError() : '');
    });
    if (status.$1 < 0) {
      replyTo.send(PumpStartFailed(s.streamId, status.$1, status.$3));
      _startNext(s.session);
      return;
    }
    _gens[s.streamId] = _Gen(s.streamId, s.session)..generationId = status.$2;
    replyTo.send(PumpStarted(s.streamId, status.$2));
  }

  void _startNext(int session) {
    final q = _waiting[session];
    if (q == null || q.isEmpty) {
      _waiting.remove(session);
      replyTo.send(PumpSessionIdle(session));
      return;
    }
    _start(q.removeAt(0));
  }

  Future<void> run() async {
    while (!_shutdown) {
      if (_gens.isEmpty) {
        await (_wake = Completer<void>()).future;
        continue;
      }
      var drained = 0;
      for (final g in _gens.values.toList()) {
        if (g.canPoll) drained += _drain(g, 0);
      }
      _flush();
      if (drained == 0) {
        _Gen? blocker;
        for (final g in _gens.values) {
          if (g.canPoll) {
            blocker = g;
            break;
          }
        }
        if (blocker != null) {
          _drain(blocker, kPumpPollTimeoutMs);
          _flush();
        } else {
          // Every stream is paused (no credit) or waiting to flush: sleep
          // until a credit arrives, re-checking the coalescing timers.
          final w = _wake = Completer<void>();
          await Future.any([w.future, Future<void>.delayed(const Duration(milliseconds: 4))]);
          _flush();
        }
      }
      // Yield so cancel/credit/start messages are handled between polls.
      await Future<void>.delayed(Duration.zero);
    }
    calloc
      ..free(_evOut)
      ..free(_nOut);
    port.close();
  }

  int _drain(_Gen g, int timeoutMs) {
    final rc = b.se_poll_events(Pointer<Void>.fromAddress(g.session), timeoutMs, kMaxPendingEvents, _evOut, _nOut);
    if (rc < 0) return 0;
    final n = _nOut.value;
    if (n == 0) {
      // A recovery drain ends once the session is idle and its ring empty.
      if (g.anyGeneration && b.se_wait(Pointer<Void>.fromAddress(g.session), 0) == SeStatus.ok) g.finished = true;
      return 0;
    }
    final base = _evOut.value;
    for (var i = 0; i < n; i++) {
      final e = eventAt(base, i);
      final type = EngineEventType.of(e.type);
      final mine = g.anyGeneration || e.generation_id == g.generationId;
      if (!mine) continue; // left over from a generation whose consumer is gone
      if (type == EngineEventType.finish) g.finished = true;
      if (g.discard || type == EngineEventType.unknown) continue;
      if (g.pending.isEmpty) g.pendingSince = _clock.elapsedMicroseconds;
      EventCoalescer.append(g.pending, _copy(e, type));
    }
    return n;
  }

  /// Copies one engine event out of the engine-owned batch (valid only until
  /// the next poll on this session).
  static EngineEvent _copy(SeEvent e, EngineEventType type) => EngineEvent(
        type: type,
        generationId: e.generation_id,
        index: e.index,
        code: e.code,
        text: e.text_len == 0 ? '' : e.text.toDartString(length: e.text_len),
        id: e.id.toDartString(),
        name: e.name.toDartString(),
        promptTokens: e.prompt_tokens,
        cachedTokens: e.cached_tokens,
        completionTokens: e.completion_tokens,
        nDrafted: e.n_drafted,
        nAccepted: e.n_accepted,
        progressDone: e.progress_done,
        progressTotal: e.progress_total,
        ttftMs: e.ttft_ms,
        prefillTps: e.prefill_tps,
        decodeTps: e.decode_tps,
        draftAcceptRate: e.draft_accept_rate,
        prefillMs: e.prefill_ms,
        decodeMs: e.decode_ms,
      );

  void _flush() {
    final now = _clock.elapsedMicroseconds;
    for (final g in _gens.values.toList()) {
      if (g.discard) {
        g.pending.clear();
        if (g.finished) _retire(g);
        continue;
      }
      if (g.pending.isEmpty) {
        if (g.finished) _retire(g);
        continue;
      }
      final due = g.finished ||
          !g.sentAny ||
          g.pending.length >= kMaxPendingEvents ||
          now - g.pendingSince >= kCoalesceWindow.inMicroseconds;
      if (!due || g.credits <= 0) continue;
      g.credits--;
      g.sentAny = true;
      replyTo.send(PumpBatch(g.streamId, List.of(g.pending), last: g.finished));
      g.pending.clear();
      if (g.finished) _retire(g);
    }
  }

  void _retire(_Gen g) {
    _gens.remove(g.streamId);
    _startNext(g.session);
  }
}
