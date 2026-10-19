import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/mcp/input/host_settings.dart';
import '../../../services/mcp/input/input_queue.dart';
import '../../../services/mcp/input/sampling.dart';
import '../../../services/mcp/input/url_opener.dart';
import '../../../state/app_providers.dart';
import '../../../state/providers.dart';
import '../../../state/services.dart';
import 'mcp_providers.dart';

// ---------------------------------------------------------------------------
// MCP input (M5): elicitation, URL consent, sampling.
// ---------------------------------------------------------------------------

/// The requests waiting for the user. Null when MCP is not wired (tests,
/// previews): every input surface then shows nothing.
final mcpInputQueueProvider = Provider<McpInputQueue?>((ref) => null);

/// Every pending request, oldest first, live.
final mcpPendingInputsProvider = StreamProvider<List<McpPendingInput>>((ref) async* {
  final q = ref.watch(mcpInputQueueProvider);
  if (q == null) {
    yield const [];
    return;
  }
  yield q.pending;
  await for (final _ in q.changes) {
    yield q.pending;
  }
});

/// The pending requests of one chat (for inline cards in the chat).
final mcpPendingInputsForSessionProvider = Provider.family<List<McpPendingInput>, String>((ref, sessionId) {
  final all = ref.watch(mcpPendingInputsProvider).value ?? const <McpPendingInput>[];
  return [for (final p in all) if (p.sessionId == sessionId) p];
});

/// Opens URLs the user confirmed (URL elicitation, links from app views).
final mcpUrlOpenerProvider = Provider<McpUrlOpener>((ref) => const UrlLauncherOpener());

/// Runs approved sampling requests on the user's model.
final mcpSamplingServiceProvider = Provider<McpSamplingService>((ref) {
  final prefs = ref.watch(preferencesProvider);
  return McpSamplingService(
    registry: ref.watch(providerRegistryProvider),
    defaultModel: () => prefs.defaultModel,
    clock: ref.watch(clockProvider),
    ids: ref.watch(idGeneratorProvider),
  );
});

/// The model a chat currently uses (sampling requests made during that
/// chat run on it unless the server has its own choice). The default reads
/// the session record's provider and model; the chat may override it with
/// its live selection.
final mcpChatModelProvider = Provider<Future<ModelChoice?> Function(String sessionId)>((ref) {
  final store = ref.watch(sessionStoreProvider);
  return (sessionId) async {
    try {
      final s = await store.getSession(sessionId);
      final p = s?.providerId, m = s?.modelId;
      return p == null || m == null ? null : ModelChoice(providerId: p, modelId: m);
    } on Object {
      return null;
    }
  };
});

/// The model a sampling request would run on, and why that one.
typedef SamplingModelPick = ({ModelChoice? model, String source, String? label});

/// Drives approved sampling requests: when one reaches
/// [SamplingStage.running] (approved, or allowed for its chat), runs it on
/// the resolved model and hands the draft over for review. Kept alive by
/// the input host, so a request runs even while its sheet is closed.
final mcpSamplingDriverProvider = Provider<McpSamplingDriver?>((ref) {
  final q = ref.watch(mcpInputQueueProvider);
  if (q == null) return null;
  final d = McpSamplingDriver(ref, q);
  ref.onDispose(d.dispose);
  return d;
});

final class McpSamplingDriver {
  McpSamplingDriver(this._ref, this._queue) {
    _sub = _queue.changes.listen((_) => _scan());
    _scan();
  }

  final Ref _ref;
  final McpInputQueue _queue;
  late final StreamSubscription<void> _sub;
  final Set<String> _started = {};
  bool _disposed = false;

  void _scan() {
    for (final p in _queue.pending) {
      if (p is PendingSampling && p.stage == SamplingStage.running && _started.add(p.id)) unawaited(_run(p));
    }
  }

  /// The model [p] runs on: the server's chosen model, else the chat's
  /// current model, else the app default.
  Future<SamplingModelPick> modelFor(PendingSampling p) async {
    final settings = _ref.read(mcpRuntimeProvider).hostSettingsOf(p.serverId);
    final chosen = settings.samplingModel;
    if (chosen != null) return (model: chosen, source: 'Chosen for this server', label: label(chosen));
    final session = p.sessionId;
    if (session != null) {
      final chat = await _ref.read(mcpChatModelProvider)(session);
      if (chat != null) return (model: chat, source: "This chat's model", label: label(chat));
    }
    final d = _ref.read(preferencesProvider).defaultModel;
    return (model: d, source: d == null ? 'No model set up' : 'Your default model', label: d == null ? null : label(d));
  }

  Future<void> _run(PendingSampling p) async {
    try {
      final pick = await modelFor(p);
      final model = pick.model;
      if (model == null) {
        p.setFailed('No model is set up. Choose a default model in Settings first.');
        return;
      }
      final service = _ref.read(mcpSamplingServiceProvider);
      final c = await service.run(
        request: p.request,
        model: model,
        maxTokens: p.limits.maxTokens,
        editedPrompt: p.approvedPrompt,
        cancel: p.runCancel,
      );
      if (_disposed || p.isDone) return;
      p.setDraft(SamplingDraft(
        text: c.text,
        model: model.modelId,
        modelLabel: label(model),
        stopReason: c.stopReason,
        outputTokens: c.outputTokens,
      ));
    } on SamplingException catch (e) {
      p.setFailed(e.message);
    } on Object catch (e) {
      if (!p.runCancel.isCancelled) p.setFailed('The model failed ($e).');
    }
  }

  /// "model · provider" for the sheets.
  String label(ModelChoice m) {
    try {
      final model = _ref.read(modelDisplayNameProvider(m));
      final provider = _ref.read(providerDisplayNameProvider(m.providerId));
      return provider == null ? model : '$model · $provider';
    } on Object {
      return m.modelId;
    }
  }

  void dispose() {
    _disposed = true;
    unawaited(_sub.cancel());
  }
}

/// One server's host settings, live.
final mcpHostSettingsProvider = Provider.family<McpServerHostSettings, String>((ref, serverId) {
  ref.watch(mcpRevisionProvider);
  return ref.watch(mcpRuntimeProvider).hostSettingsOf(serverId);
});
