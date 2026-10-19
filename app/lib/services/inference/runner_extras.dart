import 'dart:async';

import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_inference/sherpa_inference.dart';

import '../../state/services.dart' show ModelChoice;
import 'local_model_provider.dart';

/// What the local provider adds to an `AgentRunner`; mirrors the chat's
/// `RunnerExtras` (both null = the runner's defaults).
typedef LocalRunnerExtras = ({TokenCounter? counter, ContextManager? contextManager});

const LocalRunnerExtras noRunnerExtras = (counter: null, contextManager: null);

/// How long an on-device summary may take before the ladder falls back to
/// the extractive one. A phone decodes a ~1K-token summary at 10–30 tok/s;
/// the prefix is reused from the KV cache, so prefill is small.
const Duration localSummaryTimeout = Duration(seconds: 120);

/// The same for a remote provider (the user opted in).
const Duration remoteSummaryTimeout = Duration(seconds: 60);

/// Smaller models rarely follow the summary schema (R11: sub-2B models
/// collapse on structured multi-turn work), so they get the extractive
/// summary straight away instead of two wasted attempts.
const int minSummarizerParameters = 1500000000;

/// The runner extras for [provider]:
///
/// * the local provider (engine ready): the model's exact
///   [EngineTokenCounter] and a [WarmingContextManager] around [base] whose
///   ladder summarizes with that same model at background priority
///   ([withLocalSummarizer]), so the ladder's synchronous counts hit a
///   cache filled off the UI isolate and summarizing never competes with
///   the user's reply;
/// * anything else (remote providers, an unavailable engine): nothing. The
///   chat decides about remote summaries itself (they need the user's
///   opt-in).
LocalRunnerExtras localRunnerExtras(ModelProvider provider, ModelChoice choice, ContextManager base) {
  final ModelProvider local;
  final EngineTokenCounter counter;
  switch (provider) {
    case LocalModelProvider(:final engine?):
      local = provider;
      counter = engine.tokenCounter(choice.modelId);
    case LlamaCppProvider():
      local = provider;
      counter = provider.tokenCounter(choice.modelId);
    default:
      return noRunnerExtras;
  }
  return (counter: counter, contextManager: WarmingContextManager(withLocalSummarizer(base, local, choice.modelId)));
}

/// [base] (a ladder) summarizing with [modelId] on [local] at background
/// priority, falling back to the ladder's deterministic summary when the
/// engine is unavailable, the model is too small to follow the schema, or
/// the attempt fails or times out ([ModelSummarizer]). Any other summarizer
/// on [base] is replaced: a local chat never sends its history to a remote
/// model for compaction (PLAN §7 decision 9). Not a ladder: unchanged.
ContextManager withLocalSummarizer(ContextManager base, ModelProvider local, String modelId) {
  if (base is! LadderContextManager) return base;
  // Keep the sampling and retry settings of a summarizer already on this
  // provider (e.g. configured in bootstrap).
  final existing = _modelStrategyOf(base.strategy);
  final mine = existing != null && existing.provider.info.id == local.info.id ? existing : null;
  return withSummarizer(
    base,
    ModelSummarizer(
      provider: backgroundView(local),
      modelId: modelId,
      params: mine?.params ?? const GenerationParams(),
      maxAttempts: mine?.maxAttempts ?? 2,
      priority: InferencePriority.background,
      timeout: localSummaryTimeout,
      minParameters: minSummarizerParameters,
    ),
  );
}

ModelContextStrategy? _modelStrategyOf(ContextStrategy s) => switch (s) {
      ModelSummarizer(:final inner) => inner,
      ModelContextStrategy() => s,
      _ => null,
    };

/// [local] with its requests at [InferencePriority.background] (the
/// summarizer); other providers are returned as they are.
ModelProvider backgroundView(ModelProvider local) => switch (local) {
      LocalModelProvider() => local.withPriority(InferencePriority.background),
      LlamaCppProvider() => local.withPriority(InferencePriority.background),
      _ => local,
    };

/// [base] (a ladder) with [strategy] as its summarizer; the deterministic
/// fallback, memory policy, location and tool lookups are kept. Anything
/// else is returned unchanged.
ContextManager withSummarizer(ContextManager base, ContextStrategy strategy, {Clock clock = const SystemClock()}) {
  if (base is! LadderContextManager) return base;
  return LadderContextManager(
    strategy: strategy,
    fallbackStrategy: base.fallbackStrategy,
    memoryPolicy: base.memoryPolicy,
    location: base.location,
    toolLookup: base.toolLookup,
    annotationsFor: base.annotationsFor,
    clock: clock,
  );
}

/// The summarizer a ladder's strategy is, when it writes with a model.
ModelSummarizer? modelSummarizerOf(ContextManager manager) {
  final m = switch (manager) {
    WarmingContextManager(:final inner) => inner,
    _ => manager,
  };
  if (m is! LadderContextManager) return null;
  final s = m.strategy;
  return s is ModelSummarizer ? s : null;
}

/// A [ModelContextStrategy] that never holds compaction up: it gives up
/// (throws [CompactionRejected], so the ladder uses its deterministic
/// fallback) when
/// * the provider can't answer (the on-device engine is unavailable),
/// * the model is smaller than [minParameters] (when its size is known),
/// * the attempt takes longer than [timeout] (the request is cancelled), or
/// * the model's summary fails validation ([ModelContextStrategy] checks
///   the schema, retries once, and rejects one that is not smaller).
///
/// The user stopping the run still cancels it (never reported as a
/// failure).
final class ModelSummarizer implements ContextStrategy {
  ModelSummarizer({
    required ModelProvider provider,
    required String modelId,
    GenerationParams params = const GenerationParams(),
    int maxAttempts = 2,
    this.timeout,
    this.minParameters,
    this.priority,
  }) : inner = ModelContextStrategy(provider: provider, modelId: modelId, params: params, maxAttempts: maxAttempts);

  final ModelContextStrategy inner;

  /// Null: no limit.
  final Duration? timeout;

  /// Null: no size check (remote models).
  final int? minParameters;

  /// The scheduling priority [provider] runs at, for diagnostics and tests
  /// (the provider itself enforces it).
  final InferencePriority? priority;

  ModelProvider get provider => inner.provider;

  String get modelId => inner.modelId;

  @override
  String get id => inner.id;

  @override
  Future<CompactionSummary> summarize(CompactionInput input, {CancellationToken? cancel}) async {
    final min = minParameters;
    if (min != null) {
      final ModelCapabilities caps;
      try {
        caps = await provider.capabilities(modelId);
      } on CancelledException {
        rethrow;
      } on Object catch (e) {
        throw CompactionRejected('the summarizer model is unavailable: $e');
      }
      final n = caps.parameterCount;
      if (n != null && n < min) {
        throw CompactionRejected(
          'the model (${(n / 1e9).toStringAsFixed(1)}B parameters) is too small to write a structured summary',
        );
      }
    }
    final limit = timeout;
    if (limit == null) return inner.summarize(input, cancel: cancel);
    final token = cancel?.child() ?? CancellationToken();
    var timedOut = false;
    try {
      return await inner.summarize(input, cancel: token).timeout(limit, onTimeout: () {
        timedOut = true;
        token.cancel('the summary took longer than ${limit.inSeconds} s');
        throw CompactionRejected('the summary took longer than ${limit.inSeconds} s');
      });
    } on CancelledException {
      if (timedOut || !(cancel?.isCancelled ?? false)) {
        throw CompactionRejected('the summary took longer than ${limit.inSeconds} s');
      }
      rethrow;
    } finally {
      token.detach();
    }
  }
}
