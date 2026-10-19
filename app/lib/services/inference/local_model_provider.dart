import 'dart:async';

import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_inference/sherpa_inference.dart';

import '../../state/services.dart' show localProviderId;
import 'local_inference.dart';
import 'on_device_ids.dart' show kOnDeviceName;

/// What the picker, chat header and session list call the built-in local
/// provider.
const String kLocalProviderName = kOnDeviceName;

/// `ProviderNotice.code` of the one-time "the engine crashed last time"
/// notice on the first local reply after a crash report.
const String kEngineCrashNoticeCode = 'engine_crash_report';

/// The built-in `local` provider: [LlamaCppProvider] behind a facade that
/// exists before the engine starts and survives it being unavailable.
///
/// Why a facade instead of handing out the [LlamaCppProvider] itself:
/// * it can be resolved (and its privacy badge shown: on device) before the
///   engine has started, and starts it on first use;
/// * an unavailable engine becomes a clear `ProviderException(unsupported)`
///   per request instead of a registry that can't resolve `local`;
/// * it sees each reply end, which is what schedules first-use autotune
///   ([AutotuneScheduler.onReplySucceeded]) and stops a running sweep when
///   the user asks for a reply;
/// * it delivers the crash report to the next local reply, once.
///
/// [engine] is the real [LlamaCppProvider]; [tokenCounter] and
/// [withPriority] pass through to it (the runner extras use both).
final class LocalModelProvider implements ModelProvider {
  LocalModelProvider(this._local);

  final LocalInference _local;

  /// The llama.cpp provider once the engine is ready; null before and when
  /// it is unavailable.
  LlamaCppProvider? get engine => _local.engine;

  @override
  ProviderInfo get info => const ProviderInfo(
        id: localProviderId,
        kind: ProviderKind.localLlamaCpp,
        displayName: kLocalProviderName,
        location: ExecutionLocation.onDevice,
      );

  /// The library's runnable models; never needs the engine.
  @override
  Future<List<ModelDescriptor>> listModels() => _local.listModels();

  /// Loads the model (like [LlamaCppProvider.capabilities]): the context
  /// length is the admitted one.
  @override
  Future<ModelCapabilities> capabilities(String modelId) async => (await _ready()).capabilities(modelId);

  @override
  Stream<ModelEvent> stream(ModelRequest request, {CancellationToken? cancel}) => _stream(request, cancel, null);

  /// The exact counter for [modelId] (null until the engine is ready).
  EngineTokenCounter? tokenCounter(String modelId) => engine?.tokenCounter(modelId);

  /// Requests at [priority], e.g. the compaction summarizer at
  /// [InferencePriority.background]. They neither count as a reply nor
  /// stop autotune.
  ModelProvider withPriority(InferencePriority priority) => _PriorityView(this, priority);

  Future<LlamaCppProvider> _ready() async {
    final status = await _local.start();
    final e = _local.engine;
    if (e != null) {
      try {
        await _local.beforeRequest?.call();
      } on Object {
        // Freeing another engine is best effort.
      }
      return e;
    }
    throw ProviderException(
      ProviderErrorKind.unsupported,
      'On-device inference is unavailable: ${status.reason ?? 'the engine did not start'}',
      providerId: localProviderId,
    );
  }

  Stream<ModelEvent> _stream(ModelRequest request, CancellationToken? cancel, InferencePriority? priority) async* {
    final engine = await _ready();
    final reply = priority == null;
    if (reply) {
      // The scheduler would preempt it too, but only once this request is
      // queued; the context manager's counting runs before that.
      _local.autotune?.cancel('a reply was requested');
      final crash = _local.takeCrashNotice();
      if (crash != null) yield ProviderNotice(kEngineCrashNoticeCode, crash);
    }
    final source = priority == null
        ? engine.stream(request, cancel: cancel)
        : engine.withPriority(priority).stream(request, cancel: cancel);
    var succeeded = false;
    Usage? usage;
    await for (final e in source) {
      if (e is UsageUpdate) usage = e.usage;
      if (e is PerfSample) _local.recordGeneration(request.modelId, e, usage: usage, background: !reply);
      if (e is Finish) {
        succeeded = e.reason == FinishReason.stop || e.reason == FinishReason.toolCalls || e.reason == FinishReason.length;
      }
      yield e;
    }
    if (reply && succeeded) _local.autotune?.onReplySucceeded(request.modelId);
  }
}

final class _PriorityView implements ModelProvider {
  _PriorityView(this._p, this._priority);

  final LocalModelProvider _p;
  final InferencePriority _priority;

  @override
  ProviderInfo get info => _p.info;

  @override
  Future<ModelCapabilities> capabilities(String modelId) => _p.capabilities(modelId);

  @override
  Future<List<ModelDescriptor>> listModels() => _p.listModels();

  @override
  Stream<ModelEvent> stream(ModelRequest request, {CancellationToken? cancel}) => _p._stream(request, cancel, _priority);
}
