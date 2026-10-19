import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_inference/sherpa_inference.dart';

import '../../state/services.dart' show ModelChoice;
import 'local_model_provider.dart';

/// What the local provider adds to an `AgentRunner`; mirrors the chat's
/// `RunnerExtras` (both null = the runner's defaults).
typedef LocalRunnerExtras = ({TokenCounter? counter, ContextManager? contextManager});

const LocalRunnerExtras noRunnerExtras = (counter: null, contextManager: null);

/// The runner extras for [provider]:
///
/// * the local provider (engine ready): the model's exact
///   [EngineTokenCounter] and a [WarmingContextManager] around [base], so
///   the ladder's synchronous counts hit a cache filled off the UI isolate
///   in one engine round trip per request;
/// * anything else (remote providers, an unavailable engine): nothing.
///
/// A model-written compaction summarizer that targets the local provider
/// ([ModelContextStrategy] in a [LadderContextManager]) is rebuilt over
/// `withPriority(InferencePriority.background)`, so summarizing never
/// competes with the user's reply. The app's ladder currently summarizes
/// extractively, which passes through unchanged.
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
  return (counter: counter, contextManager: WarmingContextManager(withBackgroundSummarizer(base, local)));
}

/// [base] with a model summarizer on [local] moved to background priority;
/// everything else unchanged.
ContextManager withBackgroundSummarizer(ContextManager base, ModelProvider local) {
  if (base is! LadderContextManager) return base;
  final s = base.strategy;
  if (s is! ModelContextStrategy || s.provider.info.id != local.info.id) return base;
  final background = switch (local) {
    LocalModelProvider() => local.withPriority(InferencePriority.background),
    LlamaCppProvider() => local.withPriority(InferencePriority.background),
    _ => local,
  };
  return LadderContextManager(
    strategy: ModelContextStrategy(provider: background, modelId: s.modelId, params: s.params, maxAttempts: s.maxAttempts),
    fallbackStrategy: base.fallbackStrategy,
    memoryPolicy: base.memoryPolicy,
    location: base.location,
    toolLookup: base.toolLookup,
  );
}
