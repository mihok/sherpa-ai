import 'dart:async';

import 'package:sherpa_core/sherpa_core.dart';

import '../cache/prefix_cache_store.dart';
import '../engine/engine_types.dart';
import '../ffi/library_loader.dart';
import '../lifecycle/lifecycle_manager.dart';
import '../scheduler/inference_scheduler.dart';
import 'event_mapper.dart';
import 'request_mapper.dart';
import 'token_counter.dart';

/// [ModelProvider] for GGUF models on the device, through sherpa_engine
/// (llama.cpp).
///
/// A request flows: [InferenceScheduler] (priority queue, preemption) →
/// [ModelLifecycleManager.acquire] (admission control, one warm model) →
/// [ModelLease.beginGeneration] (prefix cache bind/restore, forensics
/// phase) → [EngineRequestMapper] → `EngineHost.generate` →
/// [EngineEventMapper] → the returned stream.
///
/// Stream contract (core `ModelProvider`): cold and single-subscription;
/// cancelling the subscription or [stream]'s token stops the engine at the
/// next token (`se_cancel`) and ends with `Finish(cancelled)`; pausing the
/// subscription pauses decoding (bounded buffering, then the engine's event
/// ring blocks its worker); exactly one [Finish] on success; failures are
/// [ProviderException]s (`outOfMemory`, `contextOverflow`, `engineCrashed`,
/// ...). A generation the lifecycle manager stopped for the app going to
/// the background or for critical memory pressure ends with
/// `Finish(FinishReason.pause)`: the agent loop then continues the reply
/// (the request ends with the partial assistant message, which the mapper
/// sends as `continue_final_message`) once the app is back.
final class LlamaCppProvider implements ModelProvider {
  LlamaCppProvider({
    required this.lifecycle,
    InferenceScheduler? scheduler,
    this.id = 'llama_cpp',
    this.displayName = 'On-device (llama.cpp)',
    this.cancelGrace = const Duration(seconds: 2),
    this.useSyncTokenizer = false,
  }) : scheduler = scheduler ?? InferenceScheduler();

  final ModelLifecycleManager lifecycle;
  final InferenceScheduler scheduler;
  final String id;
  final String displayName;

  /// After a cancel, how long to wait for the engine's FINISH before ending
  /// the stream anyway (the engine keeps draining in the background).
  final Duration cancelGrace;

  /// Let token counters fall back to direct FFI on the calling isolate (only
  /// when the agent runner does not live on the UI isolate).
  final bool useSyncTokenizer;

  final Map<String, EngineTokenCounter> _counters = {};

  @override
  ProviderInfo get info =>
      ProviderInfo(id: id, kind: ProviderKind.localLlamaCpp, displayName: displayName, location: ExecutionLocation.onDevice);

  @override
  Future<List<ModelDescriptor>> listModels() async => [
        for (final s in lifecycle.models)
          ModelDescriptor(
            id: s.id,
            providerId: id,
            displayName: s.label,
            capabilities: lifecycle.loaded?.spec.id == s.id
                ? lifecycle.loaded!.capabilities
                : ModelCapabilities(
                    contextLength: s.preferredContext,
                    toolCallFormat: s.toolCalling ? ToolCallFormat.jsonGrammar : ToolCallFormat.none,
                    parallelToolCalls: false,
                    supportsPromptCache: true,
                    historyPolicy: HistoryPolicy.appendOnly,
                  ),
          ),
      ];

  /// Loads the model if needed: `contextLength` is the session's real
  /// (admitted, padded) n_ctx, the tool-call format comes from the
  /// template classification. A load or model switch is queued as
  /// foreground work, so it preempts background generations instead of
  /// waiting for them to finish.
  @override
  Future<ModelCapabilities> capabilities(String modelId) async {
    final loaded = lifecycle.loaded;
    if (loaded != null && loaded.spec.id == modelId) return loaded.capabilities;
    return scheduler.run(InferencePriority.foreground, label: 'load $modelId', (_) async {
      final lease = await _acquire(modelId);
      try {
        return lease.capabilities;
      } finally {
        lease.release();
      }
    });
  }

  /// The exact counter for [modelId] (stable across reloads). Pair it with
  /// [WarmingContextManager] so counts are computed off the UI isolate.
  EngineTokenCounter tokenCounter(String modelId) => _counters[modelId] ??= EngineTokenCounter(
        host: lifecycle.host,
        providerId: id,
        useSyncTokenizer: useSyncTokenizer,
        tokenizerFamily: lifecycle.loaded?.spec.id == modelId ? lifecycle.loaded!.info.tokenizerFamily : null,
        resolveModel: () async {
          final lease = await _acquire(modelId);
          lease.release();
          return lease.model;
        },
      );

  /// A view of this provider whose requests run at [priority] (e.g. the
  /// compaction summarizer at [InferencePriority.background]).
  ModelProvider withPriority(InferencePriority priority) => _PriorityView(this, priority);

  /// Exact prompt tokens of [request] as the engine renders it.
  Future<int> countPromptTokens(ModelRequest request) async {
    final lease = await _acquire(request.modelId);
    try {
      final mapped = EngineRequestMapper(providerId: id, model: lease.info).map(request);
      return await lease.host.countChatTokens(lease.model, mapped.encode());
    } finally {
      lease.release();
    }
  }

  Future<ModelLease> _acquire(String modelId, {CancellationToken? cancel}) async {
    try {
      return await lifecycle.acquire(modelId, cancel: cancel);
    } on CancelledException {
      rethrow;
    } on Object catch (e) {
      throw _error(e);
    }
  }

  ProviderException _error(Object e) => switch (e) {
        AdmissionRefusedException(:final message) =>
          ProviderException(ProviderErrorKind.outOfMemory, message, providerId: id, cause: e),
        EngineUnavailableException(:final message) => ProviderException(
            ProviderErrorKind.unsupported, 'On-device inference is unavailable: $message',
            providerId: id, cause: e),
        ArgumentError() => ProviderException(ProviderErrorKind.modelNotFound, '${e.message}: ${e.invalidValue}',
            providerId: id, cause: e),
        _ => providerErrorFor(e, providerId: id),
      };

  /// Requests that answer tool results continue an agent run; anything else
  /// is a reply the user waits for.
  static InferencePriority inferPriority(ModelRequest request) =>
      request.messages.isNotEmpty && request.messages.last.role == Role.tool
          ? InferencePriority.toolFollowUp
          : InferencePriority.foreground;

  @override
  Stream<ModelEvent> stream(ModelRequest request, {CancellationToken? cancel}) =>
      _stream(request, cancel, inferPriority(request));

  Stream<ModelEvent> _stream(ModelRequest request, CancellationToken? cancel, InferencePriority priority) {
    return _Generation(this, request, cancel, priority).controller.stream;
  }
}

final class _PriorityView implements ModelProvider {
  _PriorityView(this._p, this._priority);

  final LlamaCppProvider _p;
  final InferencePriority _priority;

  @override
  ProviderInfo get info => _p.info;

  @override
  Future<ModelCapabilities> capabilities(String modelId) => _p.capabilities(modelId);

  @override
  Future<List<ModelDescriptor>> listModels() => _p.listModels();

  @override
  Stream<ModelEvent> stream(ModelRequest request, {CancellationToken? cancel}) =>
      _p._stream(request, cancel, _priority);
}

/// One `stream()` call.
final class _Generation {
  _Generation(this.p, this.request, this.cancel, this.priority) {
    controller = StreamController<ModelEvent>(
      onListen: () => unawaited(_run()),
      onPause: () => _engineSub?.pause(),
      onResume: () => _engineSub?.resume(),
      onCancel: _onCancel,
    );
  }

  final LlamaCppProvider p;
  final ModelRequest request;
  final CancellationToken? cancel;
  final InferencePriority priority;
  late final StreamController<ModelEvent> controller;

  StreamSubscription<EngineEvent>? _engineSub;
  Completer<void>? _done;
  bool _listenerGone = false;
  bool _finishSent = false;

  void _emit(ModelEvent e) {
    if (_listenerGone || controller.isClosed) return;
    if (e is Finish) _finishSent = true;
    controller.add(e);
  }

  Future<void> _onCancel() async {
    _listenerGone = true;
    final sub = _engineSub;
    _engineSub = null;
    // Cancelling the engine subscription cancels the generation; the host
    // drains it to FINISH in the background, so this returns at once.
    await sub?.cancel();
    final d = _done;
    if (d != null && !d.isCompleted) d.complete();
  }

  Future<void> _run() async {
    final label = request.cache.sessionId == null ? 'chat' : 'chat ${request.cache.sessionId}';
    try {
      await p.scheduler.run(priority, _job, label: '${priority.name}: $label', cancel: cancel);
    } on PreemptedException catch (e) {
      _fail(ProviderException(ProviderErrorKind.overloaded, 'Paused for more urgent on-device work (${e.by}).',
          providerId: p.id, cause: e));
    } on CancelledException {
      if (!_finishSent) _emit(const Finish(FinishReason.cancelled));
    } on ProviderException catch (e) {
      _fail(e);
    } on Object catch (e) {
      _fail(p._error(e));
    } finally {
      if (!controller.isClosed) await controller.close();
    }
  }

  void _fail(ProviderException e) {
    if (_listenerGone || controller.isClosed) return;
    if ((cancel?.isCancelled ?? false) && !_finishSent) {
      _emit(const Finish(FinishReason.cancelled));
      return;
    }
    controller.addError(e);
  }

  Future<void> _job(InferenceJobContext ctx) async {
    cancel?.throwIfCancelled();
    final lease = await p._acquire(request.modelId, cancel: cancel);
    try {
      cancel?.throwIfCancelled();
      final mapper = EngineRequestMapper(providerId: p.id, model: lease.info);
      final mapped = mapper.map(request);
      for (final n in mapped.notices) {
        _emit(n);
      }
      final fingerprint = PrefixFingerprint.of(messages: mapped.messages, tools: (mapped.body['tools'] as List?) ?? const []);
      final restored = await lease.beginGeneration(conversation: request.cache.sessionId, fingerprint: fingerprint);
      if (restored != null && restored.restored) {
        _emit(ProviderNotice('prefix_restored', 'Restored ${restored.tokens} cached tokens of this conversation.',
            data: {'tokens': restored.tokens}));
      }
      if (_listenerGone) return;
      final events = EngineEventMapper(providerId: p.id);
      final done = _done = Completer<void>();
      var cancelRequested = false;
      Timer? grace;

      void requestCancel() {
        if (cancelRequested || done.isCompleted) return;
        cancelRequested = true;
        unawaited(lease.host.cancelGeneration(lease.session).catchError((Object _) {}));
        grace = Timer(p.cancelGrace, () {
          // FINISH did not arrive in time (e.g. a paused consumer): end the
          // stream; the host drains the engine in the background.
          final sub = _engineSub;
          _engineSub = null;
          unawaited(sub?.cancel());
          if (!done.isCompleted) done.complete();
        });
      }

      _engineSub = lease.host.generate(lease.session, mapped.encode()).listen(
        (e) {
          final List<ModelEvent> out;
          try {
            out = events.map(e);
          } on ProviderException catch (err) {
            if (!done.isCompleted) done.completeError(err);
            return;
          }
          for (final m in out) {
            if (m is Finish && m.reason == FinishReason.cancelled) {
              if (ctx.preempt.isCancelled && !(cancel?.isCancelled ?? false) && lease.interruptReason == null) {
                continue; // reported as preemption below
              }
              final interrupted = lease.interruptReason;
              _emit(interrupted != null && !(cancel?.isCancelled ?? false)
                  ? Finish(FinishReason.pause, rawReason: interrupted)
                  : m);
              continue;
            }
            if (m is TextDelta || m is ReasoningDelta || m is ToolCallStart) ctx.markOutput();
            _emit(m);
          }
        },
        onError: (Object err) {
          if (!done.isCompleted) done.completeError(err);
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
      );
      if (controller.isPaused) _engineSub?.pause();
      // Both tokens only ever complete (never error); nothing awaits them.
      if (cancel != null) unawaited(cancel!.whenCancelled.then((_) => requestCancel()));
      unawaited(ctx.preempt.whenCancelled.then((_) => requestCancel()));
      try {
        await done.future;
      } finally {
        grace?.cancel();
      }
      final usage = events.usage;
      await lease.endGeneration(
        fingerprint: fingerprint,
        promptTokens: (usage?.inputTokens ?? 0) + (usage?.cacheReadTokens ?? 0),
        completionTokens: usage?.outputTokens ?? 0,
      );
      if (ctx.preempt.isCancelled && !(cancel?.isCancelled ?? false) && lease.interruptReason == null && !_finishSent) {
        throw PreemptedException(ctx.preempt.reason ?? 'a more urgent job');
      }
      if (!_finishSent && !_listenerGone) {
        // The engine stream ended without FINISH (only on a cancel grace
        // timeout): the reply was stopped.
        _emit(Finish(lease.interruptReason != null ? FinishReason.pause : FinishReason.cancelled,
            rawReason: lease.interruptReason));
      }
    } on Object catch (e) {
      if (e is PreemptedException || e is CancelledException || e is ProviderException) rethrow;
      throw p._error(e);
    } finally {
      lease.release();
    }
  }
}
