import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show KeepAliveLink;
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_providers/sherpa_providers.dart';

import '../../../state/providers.dart';
import '../../../state/services.dart';
import 'chat_dependencies.dart';
import 'chat_errors.dart';
import 'chat_view_state.dart';
import 'draft_builder.dart';
import 'frame_scheduler.dart';
import 'model_selection.dart';
import 'transcript_model.dart';
import 'ui_approval_handler.dart';

/// One [ChatController] per open chat, keyed by session id.
///
/// Why a `Notifier` family rather than a plain class behind a `Provider`:
/// the chat's state is one immutable value that many widgets watch in
/// slices (`select`), and Notifier gives that plus lifecycle for free.
/// `autoDispose` frees a chat nobody is looking at, but a running turn holds
/// a keep-alive link: leaving the screen (or a back gesture) must never
/// cancel the agent (docs/research/12 §1.5). The link is released when the
/// run ends.
final chatControllerProvider = NotifierProvider.autoDispose.family<ChatController, ChatViewState, String>(
  ChatController.new,
  name: 'chatControllerProvider',
);

/// Direction for the branch switcher.
enum BranchDirection { previous, next }

/// Owns the [AgentRunner] of one session and turns its event stream into
/// [ChatViewState].
///
/// Design notes:
/// * Streamed deltas go into a mutable [DraftBuilder]; state is published
///   at most once per frame through [FrameScheduler]. Every other event
///   (tool started, approval, completion) publishes immediately: they are
///   rare and the user should see them without delay.
/// * The persisted transcript is the source of truth. Completed messages
///   are applied incrementally from events (so nothing flickers between
///   "draft" and "finished"), and the path is re-read from the store at the
///   start and end of every run to reconcile.
/// * No action throws: failures become [ChatViewState.error] with copy and
///   actions the user can act on.
class ChatController extends Notifier<ChatViewState> {
  ChatController(this.sessionId);

  final String sessionId;

  late SessionStore _store;
  late ProviderRegistry _registry;
  PreferencesStore? _prefs;
  late Clock _clock;
  late ToolRouter _router;
  late FrameScheduler _frames;
  late ChatPlatformActions _platform;
  late UiApprovalHandler _approvals;
  late AgentConfig _config;

  AgentRunner? _runner;
  ModelChoice? _runnerChoice;
  bool _runnerStale = false;

  StreamSubscription<AgentEvent>? _runSub;
  StreamSubscription<List<ProviderConfig>>? _registrySub;
  StreamSubscription<void>? _prefsSub;
  Completer<void>? _runDone;
  KeepAliveLink? _keepAlive;
  bool _runActive = false;
  bool _finishing = false;
  bool _stopping = false;

  List<Message> _path = const [];
  final Map<String?, List<Message>> _siblings = {};
  final Set<String?> _touchedParents = {};
  Map<String, ToolExecutionView> _pathTools = const {};
  final Map<String, ToolExecutionView> _liveTools = {};
  Map<String, ToolExecutionView>? _toolsCache;
  DraftBuilder? _draft;
  String? _pendingUser;
  String? _pendingUserId;
  bool _reloadOnCheckpoint = false;
  int _reloadSeq = 0;
  int _scrollNonce = 0;

  bool _flushScheduled = false;
  bool _dirty = false;
  bool _disposed = false;
  late Future<void> _loaded;

  /// Completes once the session, transcript and model are loaded.
  Future<void> get loaded => _loaded;

  /// True while an [AgentRunner] run is in flight (including its final
  /// reconciliation).
  bool get isRunning => _runActive;

  @override
  ChatViewState build() {
    // Services are app-lifetime singletons. They are read, not watched, so a
    // provider refresh can never rebuild (and reset) a chat in the middle of
    // a run.
    _store = ref.read(sessionStoreProvider);
    _registry = ref.read(providerRegistryProvider);
    _clock = ref.read(clockProvider);
    _router = ref.read(toolRouterProvider);
    _frames = ref.read(chatFrameSchedulerProvider);
    _platform = ref.read(chatPlatformProvider);
    _config = ref.read(chatAgentConfigProvider);
    try {
      _prefs = ref.read(preferencesProvider);
    } on Object {
      _prefs = null; // Optional: chats work without a default model.
    }
    _approvals = UiApprovalHandler(onChanged: _onApprovalChanged, clock: _clock);
    ref.onDispose(_dispose);
    _registrySub = _registry.changes.listen((_) => unawaited(_guarded(_refreshModel)));
    _prefsSub = _prefs?.changes.listen((_) => unawaited(_guarded(_refreshModel)));
    _loaded = _load();
    return ChatViewState(sessionId: sessionId);
  }

  @override
  bool updateShouldNotify(ChatViewState previous, ChatViewState next) => !identical(previous, next);

  // ---------------------------------------------------------------------------
  // Public actions. None of them throw.

  /// Sends [text] as a new user message and runs the agent. Completes when
  /// the run has finished (the UI doesn't await it; tests do).
  ///
  /// The message appears synchronously, before anything is persisted, so
  /// tapping send never feels like it waited on storage.
  Future<void> send(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || _runActive) return;
    unawaited(_platform.haptic(ChatHaptic.send));
    await _launch(
      anchorAt: state.items.length,
      pendingUser: trimmed,
      open: (runner) => runner.send(sessionId, [TextPart(trimmed)]),
    );
  }

  /// Stops everything: streaming, tools, and any open approval (denied).
  void stop() {
    if (!_runActive) return;
    _stopping = true;
    _runner?.cancel('stopped by user');
    _approvals.denyAll();
  }

  /// Answers the approval card currently shown.
  void respondToApproval(ApprovalResponse response) {
    final pending = state.pendingApproval;
    if (pending == null) return;
    _approvals.respond(pending.call.id, response);
  }

  /// Regenerates the reply [assistantMessageId] belongs to from its parent,
  /// keeping the old reply as a sibling branch ("‹ 2/2 ›").
  Future<void> retry(String assistantMessageId) async {
    if (_runActive) return;
    final message = await _message(assistantMessageId);
    final parentId = message?.parentId;
    if (message == null || parentId == null) {
      _showError(chatErrorFrom(StateError('cannot retry $assistantMessageId'), model: state.model));
      return;
    }
    await _launch(
      anchorAt: _itemIndexOf(assistantMessageId),
      keepThrough: parentId,
      open: (runner) => runner.regenerate(sessionId, fromMessageId: parentId),
    );
  }

  /// Retries whatever ended last: a failed or stopped partial reply is
  /// regenerated from its parent (keeping earlier tool work); a finished
  /// turn is regenerated as a whole; a turn that never produced output is
  /// re-run from its user or tool message.
  Future<void> retryLast() async {
    if (_runActive) return;
    final leaf = _path.isEmpty ? null : _path.last;
    if (leaf == null) return;
    if (leaf.role == Role.assistant) {
      final partial = leaf.finishReason == FinishReason.error.name || leaf.metadata['error'] != null;
      if (partial) return retry(leaf.id);
      final turn = _turnContaining(leaf.id);
      return retry(turn?.firstMessageId ?? leaf.id);
    }
    await _launch(
      anchorAt: state.items.length,
      open: (runner) => runner.regenerate(sessionId, fromMessageId: leaf.id),
    );
  }

  /// Continues a run that stopped at the step limit, from its last tool
  /// results, without inventing a user message.
  Future<void> continueRun() async {
    if (_runActive || _path.isEmpty) return;
    final leaf = _path.last;
    if (leaf.role != Role.tool && leaf.role != Role.user) return retryLast();
    _dismissNotice('max_steps');
    await _launch(
      anchorAt: _itemIndexOf(leaf.id),
      open: (runner) => runner.regenerate(sessionId, fromMessageId: leaf.id),
    );
  }

  /// Edit-and-resubmit: a new user message as a sibling of
  /// [userMessageId]; the original exchange stays as another branch.
  Future<void> edit(String userMessageId, String newText) async {
    final trimmed = newText.trim();
    if (trimmed.isEmpty || _runActive) return;
    final message = await _message(userMessageId);
    if (message == null || message.role != Role.user) {
      _showError(chatErrorFrom(StateError('cannot edit $userMessageId'), model: state.model));
      return;
    }
    await _launch(
      anchorAt: _itemIndexOf(userMessageId),
      keepBefore: userMessageId,
      pendingUser: trimmed,
      open: (runner) => runner.edit(sessionId, userMessageId, [TextPart(trimmed)]),
    );
  }

  /// Starts a run with an optimistic UI: the transcript is truncated to
  /// where the new branch starts ([keepThrough] / [keepBefore]), the pending
  /// user text and the live "thinking" turn appear immediately, and all of
  /// it is rolled back if the run can't start (no provider, store error).
  Future<void> _launch({
    required int anchorAt,
    required Stream<AgentEvent> Function(AgentRunner runner) open,
    String? pendingUser,
    String? keepThrough,
    String? keepBefore,
  }) async {
    if (_runActive) return;
    final previousPath = _path;
    void applyOptimistic() {
      if (keepThrough != null) _truncateAfter(keepThrough);
      if (keepBefore != null) _truncateBefore(keepBefore);
      _pendingUser = pendingUser;
    }

    void rollback(ChatError? error) {
      _runActive = false;
      _stopping = false;
      _pendingUser = null;
      _setPath(previousPath);
      final restored = _buildItems();
      _flush(base: state.copyWith(
        status: ChatRunStatus.idle,
        items: restored,
        historyCount: math.min(state.historyCount, restored.length),
        error: error,
      ));
    }

    _runActive = true;
    _stopping = false;
    applyOptimistic();
    final items = _buildItems();
    _flush(base: state.copyWith(
      status: ChatRunStatus.streaming,
      error: null,
      notices: const [],
      items: items,
      historyCount: math.min(state.historyCount, math.min(anchorAt, items.length)),
    ));
    AgentRunner runner;
    try {
      runner = await _ensureRunner();
      if (state.interrupted != null) {
        _runActive = false; // the settle run must not look like ours
        await _settleInterrupted(runner);
        _runActive = true;
        applyOptimistic();
      }
    } on Object catch (e, st) {
      debugPrint('chat[$sessionId]: $e\n$st');
      if (_disposed) return;
      rollback(chatErrorFrom(e, model: state.model));
      return;
    }
    if (_disposed) return;
    if (_stopping) {
      // Stop was tapped before the run even started.
      rollback(null);
      return;
    }
    await _run(open(runner), anchorAt: anchorAt);
  }

  /// Shows the previous/next sibling of [messageId]: the session's active
  /// leaf moves to the deepest message along the first-child chain of the
  /// chosen sibling.
  Future<void> switchBranch(String messageId, BranchDirection direction) async {
    if (_runActive) return;
    await _guarded(() async {
      final message = await _message(messageId);
      if (message == null) return;
      final siblings = _ordered(await _store.children(sessionId, message.parentId))
          .where((m) => m.role == message.role)
          .toList();
      final index = siblings.indexWhere((m) => m.id == messageId);
      final target = index + (direction == BranchDirection.next ? 1 : -1);
      if (index < 0 || target < 0 || target >= siblings.length) return;
      var leaf = siblings[target];
      for (var guard = 0; guard < 100000; guard++) {
        final kids = _ordered(await _store.children(sessionId, leaf.id));
        if (kids.isEmpty) break;
        leaf = kids.first;
      }
      final session = await _requireSession();
      await _store.putSession(session.copyWith(activeLeafId: leaf.id, updatedAt: _clock.now()));
      _siblings[message.parentId] = siblings;
      unawaited(_platform.haptic(ChatHaptic.selection));
      await _reloadPath(force: true, historyCount: _itemIndexOf(messageId), scroll: ChatScrollKind.revealLive);
    });
  }

  /// Copies what the user sees as one message: a user message's text, or
  /// every text block of the assistant turn [messageId] belongs to.
  Future<bool> copy(String messageId) async {
    final text = _visibleTextOf(messageId);
    if (text.isEmpty) return false;
    try {
      await _platform.copyText(text);
      return true;
    } on Object catch (e) {
      _showError(chatErrorFrom(e));
      return false;
    }
  }

  /// Opens the system share sheet with the same text [copy] would copy.
  Future<void> share(String messageId) async {
    final text = _visibleTextOf(messageId);
    if (text.isEmpty) return;
    await _guarded(() => _platform.shareText(text, subject: state.title.isEmpty ? null : state.title));
  }

  /// Switches the chat to another provider/model. Future turns use it; a
  /// running turn finishes on the model it started with.
  Future<void> changeModel(ModelChoice choice) async {
    await _guarded(() async {
      final session = await _requireSession();
      await _store.putSession(session.copyWith(
        providerId: choice.providerId,
        modelId: choice.modelId,
        updatedAt: _clock.now(),
      ));
      if (_runActive) {
        _runnerStale = true;
      } else {
        _runner = null;
        _runnerChoice = null;
      }
      if (_isSetupError(state.error)) _commit(state.copyWith(error: null));
      await _refreshModel();
      unawaited(_quiet(_estimateBudget));
    });
  }

  /// Continues a run that was interrupted (app killed mid-reply) from its
  /// last checkpoint. Approvals that were pending are asked again.
  Future<void> resumeIfInterrupted() async {
    if (_runActive) return;
    await _guarded(() async {
      await _loaded;
      final cp = await _store.getCheckpoint(sessionId);
      if (cp == null || cp.isTerminal || cp.leafMessageId == null) {
        _commit(state.copyWith(interrupted: null));
        return;
      }
      final runner = await _ensureRunner();
      final last = state.items.isEmpty ? null : state.items.last;
      final anchor = last is AssistantTurnItem ? state.items.length - 1 : state.items.length;
      await _run(runner.resume(sessionId), anchorAt: anchor);
    });
  }

  /// Abandons an interrupted run. The runner closes it properly (every
  /// dangling tool call gets a "cancelled" result) so the branch stays
  /// valid to continue.
  Future<void> discardInterrupted() async {
    if (_runActive) return;
    await _guarded(() async {
      AgentRunner? runner;
      try {
        runner = await _ensureRunner();
      } on ChatSetupException {
        runner = null; // Closed properly on the next send instead.
      }
      if (runner != null) await _settleInterrupted(runner, force: true);
      _commit(state.copyWith(interrupted: null));
    });
  }

  /// Creates an empty chat on the same model; returns its id for navigation.
  Future<String?> startNewChat() async {
    try {
      final now = _clock.now();
      final id = ref.read(idGeneratorProvider).next('ses');
      final choice = state.model?.choice;
      await _store.putSession(SessionRecord(
        id: id,
        title: defaultSessionTitle,
        createdAt: now,
        updatedAt: now,
        providerId: choice?.providerId,
        modelId: choice?.modelId,
      ));
      return id;
    } on Object catch (e) {
      _showError(chatErrorFrom(e));
      return null;
    }
  }

  void dismissError() => _commit(state.copyWith(error: null));

  void dismissNotice(String code) => _dismissNotice(code);

  // ---------------------------------------------------------------------------
  // Loading and model resolution

  Future<void> _load() async {
    try {
      final session = await _store.getSession(sessionId);
      if (_disposed) return;
      if (session == null) {
        _commit(state.copyWith(
          loading: false,
          availability: ProviderAvailability.providerMissing,
          error: chatErrorFrom(StateError('unknown session $sessionId')),
        ));
        return;
      }
      final leaf = session.activeLeafId;
      final path = leaf == null ? <Message>[] : await _store.path(sessionId, leaf);
      await _prefetchSiblings(path);
      final cp = await _store.getCheckpoint(sessionId);
      if (_disposed) return;
      _setPath(path);
      final items = _buildItems();
      _commit(state.copyWith(
        loading: false,
        title: session.title,
        items: items,
        historyCount: items.length,
        tools: _toolsSnapshot(),
        interrupted: cp != null && !cp.isTerminal && cp.leafMessageId != null
            ? InterruptedRun(phase: cp.phase, updatedAt: cp.updatedAt)
            : null,
      ));
      await _refreshModel(session: session);
      unawaited(_quiet(_estimateBudget));
    } on Object catch (e) {
      if (_disposed) return;
      _commit(state.copyWith(loading: false, error: chatErrorFrom(e)));
    }
  }

  /// Works out which model this chat uses and what the privacy badge says.
  /// Order: the chat's own choice → the user's default → the first provider
  /// with a default model.
  Future<void> _refreshModel({SessionRecord? session}) async {
    final s = session ?? await _store.getSession(sessionId);
    if (s == null || _disposed) return;
    final configs = _registry.configs;
    ModelChoice? choice;
    if (s.providerId != null && s.modelId != null) {
      choice = ModelChoice(providerId: s.providerId!, modelId: s.modelId!);
    }
    choice ??= _prefs?.defaultModel;
    if (choice == null) {
      for (final c in configs) {
        if (c.defaultModelId != null) {
          choice = ModelChoice(providerId: c.id, modelId: c.defaultModelId!);
          break;
        }
      }
    }
    if (choice == null) {
      _commit(state.copyWith(
        availability: configs.isEmpty ? ProviderAvailability.noProviders : ProviderAvailability.needsModel,
        model: null,
      ));
      return;
    }

    final config = configs.where((c) => c.id == choice!.providerId).firstOrNull;
    final previousName = state.model?.modelId == choice.modelId ? state.model?.modelName : null;
    ModelSelection selection;
    var availability = ProviderAvailability.ready;
    try {
      final provider = await _registry.resolve(choice.providerId);
      final privacy = privacyForProvider(provider.info);
      selection = ModelSelection(
        providerId: choice.providerId,
        modelId: choice.modelId,
        providerName: config?.displayName ?? provider.info.displayName,
        modelName: previousName ?? choice.modelId,
        location: privacy.location,
        host: privacy.host,
      );
    } on Object {
      availability = ProviderAvailability.providerMissing;
      final privacy = config == null ? null : privacyForConfig(config);
      selection = ModelSelection(
        providerId: choice.providerId,
        modelId: choice.modelId,
        providerName: config?.displayName ?? choice.providerId,
        modelName: previousName ?? choice.modelId,
        location: privacy?.location ?? ExecutionLocation.remote,
        host: privacy?.host,
      );
    }
    if (_disposed) return;
    _commit(state.copyWith(availability: availability, model: selection));

    if (availability != ProviderAvailability.ready) return;
    try {
      final models = await _registry.models(choice.providerId);
      final d = models.where((m) => m.id == choice!.modelId).firstOrNull;
      final current = state.model;
      if (d != null && !_disposed && current != null && current.modelId == d.id) {
        _commit(state.copyWith(model: current.copyWith(modelName: d.displayName)));
      }
    } on Object {
      // Listing can fail offline; the raw model id is a fine label.
    }
  }

  /// A budget estimate before the first run, so the context ring is
  /// meaningful as soon as a long chat opens. The runner's own numbers
  /// replace it at the next model call.
  Future<void> _estimateBudget() async {
    final model = state.model;
    if (model == null || state.availability != ProviderAvailability.ready || _runActive) return;
    final provider = await _registry.resolve(model.providerId);
    final caps = await provider.capabilities(model.modelId);
    final session = await _store.getSession(sessionId);
    final overlays = await _store.overlays(sessionId);
    final tools = caps.canCallTools
        ? (await _router.toolsForTurn(sessionId: sessionId)).where((t) => t.modelVisible).toList()
        : const <ToolDefinition>[];
    final config = _config;
    if (_disposed) return;
    final system = PromptBoundary.compose(session?.systemPrompt ?? config.defaultSystemPrompt);
    final request = ContextRequest(
      sessionId: sessionId,
      path: _path,
      overlays: overlays,
      tools: tools,
      capabilities: caps,
      counter: HeuristicTokenCounter(),
      systemPrompt: system,
      settings: config.contextSettings,
    );
    final budget = PassthroughContextManager.measure(
      request,
      system,
      PassthroughContextManager.applyOverlays(_path, overlays),
    );
    if (_disposed || _runActive || (state.budget != null && !state.budgetIsEstimate)) return;
    _commit(state.copyWith(
      budget: budget,
      contextLevel: budget.levelFor(config.contextSettings.thresholds),
      budgetIsEstimate: true,
    ));
  }

  Future<AgentRunner> _ensureRunner() async {
    await _loaded;
    final choice = await _choiceForRun();
    final existing = _runner;
    if (existing != null && _runnerChoice == choice && !_runnerStale) return existing;
    final provider = await _registry.resolve(choice.providerId);
    final runner = AgentRunner(
      store: _store,
      provider: provider,
      modelId: choice.modelId,
      tools: _router,
      approvals: ref.read(approvalPolicyProvider),
      approvalHandler: _approvals,
      contextManager: ref.read(chatContextManagerProvider),
      clock: _clock,
      ids: ref.read(idGeneratorProvider),
      config: _config,
      sleep: ref.read(chatRetrySleepProvider),
    );
    _runner = runner;
    _runnerChoice = choice;
    _runnerStale = false;
    return runner;
  }

  Future<ModelChoice> _choiceForRun() async {
    final session = await _requireSession();
    switch (state.availability) {
      case ProviderAvailability.noProviders:
        throw const ChatSetupException(
          ChatErrorKind.noProvider,
          'Sherpa needs a model to talk to. Add an API provider such as Anthropic, OpenAI, or a '
          'compatible server like llama.cpp or Ollama.',
        );
      case ProviderAvailability.providerMissing:
        throw ChatSetupException(
          ChatErrorKind.providerMissing,
          '${state.model?.providerName ?? 'The provider'} was removed or could not be set up. '
          'Choose another model to continue this chat.',
        );
      case ProviderAvailability.needsModel || ProviderAvailability.loading:
        if (state.model == null) {
          throw const ChatSetupException(ChatErrorKind.needsModel, 'Pick which model this chat should use.');
        }
      case ProviderAvailability.ready:
        break;
    }
    final selection = state.model!;
    if (session.providerId != selection.providerId || session.modelId != selection.modelId) {
      // Persist the effective default so reopening the chat agrees with
      // what it actually used.
      await _store.putSession(session.copyWith(providerId: selection.providerId, modelId: selection.modelId));
    }
    return selection.choice;
  }

  /// Closes an interrupted run before starting a new one, so the transcript
  /// never carries unanswered tool calls into the next request.
  Future<void> _settleInterrupted(AgentRunner runner, {bool force = false}) async {
    if (!force && state.interrupted == null) return;
    final cp = await _store.getCheckpoint(sessionId);
    if (cp != null && !cp.isTerminal && cp.leafMessageId != null) {
      final events = runner.resume(sessionId);
      runner.cancel('discarded interrupted run');
      await events.drain<void>();
      await _reloadPath(force: true);
    }
    if (!_disposed) _commit(state.copyWith(interrupted: null));
  }

  // ---------------------------------------------------------------------------
  // Running

  Future<void> _run(Stream<AgentEvent> events, {required int anchorAt}) {
    final done = Completer<void>();
    _runDone = done;
    _runActive = true;
    _finishing = false;
    _keepAlive ??= ref.keepAlive();
    _draft = null;
    _pendingUserId = null;
    _liveTools.clear();
    _touchedParents.clear();
    _reloadOnCheckpoint = true;
    _invalidateTools();
    final items = _buildItems();
    _flush(base: state.copyWith(
      status: ChatRunStatus.streaming,
      error: null,
      notices: const [],
      interrupted: null,
      pendingApproval: null,
      pendingUserText: _pendingUser,
      items: items,
      historyCount: math.min(state.historyCount, math.min(anchorAt, items.length)),
      scrollRequest: ChatScrollRequest(++_scrollNonce, ChatScrollKind.bottom),
    ));
    _runSub = events.listen(
      _onEvent,
      onError: (Object e, StackTrace _) => unawaited(_finishRun(RunFinished(
        outcome: RunOutcome.failed,
        usage: Usage.zero,
        error: e,
      ))),
      onDone: () {
        if (!_finishing) {
          unawaited(_finishRun(const RunFinished(outcome: RunOutcome.completed, usage: Usage.zero)));
        }
      },
    );
    return done.future;
  }

  void _onEvent(AgentEvent e) {
    if (_disposed) return;
    switch (e) {
      case RunStarted():
        break;
      case StepStarted(:final step):
        _setStatus(ChatRunStatus.streaming);
        // Results of a step whose calls were all denied are persisted without
        // a ToolCallFinished event; pick them up before the next reply lands.
        if (step > 1) unawaited(_guarded(_reloadPath));
      case Checkpointed(:final checkpoint):
        if (_reloadOnCheckpoint && checkpoint.leafMessageId != null) {
          // The first checkpoint names the run's starting leaf: for send and
          // edit that is the user message the runner just persisted.
          _reloadOnCheckpoint = false;
          if (_pendingUser != null) _pendingUserId = checkpoint.leafMessageId;
          unawaited(_guarded(_reloadPath));
        }
      case ContextPrepared(:final budget, :final level):
        _flush(base: state.copyWith(budget: budget, contextLevel: level, budgetIsEstimate: false));
      case ModelStreamed(:final messageId, :final event):
        final draft = _draft?.messageId == messageId ? _draft! : (_draft = DraftBuilder(messageId));
        draft.apply(event, _clock.now());
        if (state.notices.any((n) => n.code == 'retrying')) {
          _flush(base: state.copyWith(notices: state.notices.where((n) => n.code != 'retrying').toList()));
        } else {
          _markDirty();
        }
      case AssistantMessageCompleted(:final message):
        _onAssistantCompleted(message);
      case ToolApprovalRequested(:final call):
        _liveTools[call.id] = _toolView(call, ToolRunStatus.awaitingApproval);
        _invalidateTools();
        _flush(base: state.copyWith(status: ChatRunStatus.awaitingApproval));
      case ToolApprovalResolved(:final callId, :final approved):
        final view = _liveTools[callId];
        if (view != null) {
          _liveTools[callId] = view.copyWith(status: approved ? ToolRunStatus.pending : ToolRunStatus.denied);
        }
        _invalidateTools();
        _flush(base: state.copyWith(
          status: state.pendingApproval != null ? ChatRunStatus.awaitingApproval : ChatRunStatus.runningTools,
        ));
      case ToolCallStarted(:final call):
        _liveTools[call.id] = (_liveTools[call.id] ?? _toolView(call, ToolRunStatus.running))
            .copyWith(status: ToolRunStatus.running, startedAt: _clock.now());
        _invalidateTools();
        _flush(base: state.copyWith(status: ChatRunStatus.runningTools));
      case ToolCallProgressed(:final callId, :final progress):
        final view = _liveTools[callId];
        if (view == null) return;
        _liveTools[callId] = view.copyWith(progress: progress.fraction, progressMessage: progress.message);
        _invalidateTools();
        _markDirty();
      case ToolCallFinished(:final call, :final result, :final message):
        _liveTools.remove(call.id);
        _applyMessage(message);
        if (result.isError) unawaited(_platform.haptic(ChatHaptic.toolFailed));
        _flush(base: state.copyWith(items: _buildItems()));
      case PlanUpdated():
        break; // The plan is visible through the update_plan tool result.
      case RunNotice(:final code, :final message):
        final notice = ChatNotice(
          code: code,
          message: _noticeCopy(code, message),
          kind: code == 'retrying' ? ChatNoticeKind.progress : ChatNoticeKind.info,
        );
        _flush(base: state.copyWith(notices: [...state.notices.where((n) => n.code != code), notice]));
      case RunFinished():
        unawaited(_finishRun(e));
    }
  }

  void _onAssistantCompleted(Message message) {
    final draft = _draft?.messageId == message.id ? _draft : null;
    var m = message;
    if (draft != null) {
      draft.finish(_clock.now());
      final thought = draft.reasoningDuration;
      if (thought != null && m.content.any((p) => p is ReasoningPart)) {
        // "Thought for Ns" survives reopening the chat: persisted as a
        // client-only hint (providers never see message metadata). The
        // runner never rewrites a message after completing it.
        m = m.copyWith(metadata: {...m.metadata, 'reasoningMs': thought.inMilliseconds});
        final hinted = m;
        unawaited(_guarded(() => _store.putMessage(sessionId, hinted)));
      }
    }
    if (_applyMessage(m) && draft != null) _draft = null;
    _flush(base: state.copyWith(items: _buildItems()));
  }

  Future<void> _finishRun(RunFinished e) async {
    if (_finishing) return;
    _finishing = true;
    _draft?.finish(_clock.now());
    _approvals.denyAll();
    for (final p in _touchedParents) {
      _siblings.remove(p);
    }
    try {
      await _reloadPath(force: true, finishing: true);
    } on Object {
      // Keep what we have; the next open re-reads the store.
    }
    if (_disposed) {
      _completeRun();
      return;
    }
    _runActive = false;
    _draft = null;
    _pendingUser = null;
    _pendingUserId = null;
    _liveTools.clear();
    _invalidateTools();

    var status = ChatRunStatus.idle;
    ChatError? error;
    final notices = [...state.notices.where((n) => n.code != 'retrying')];
    switch (e.outcome) {
      case RunOutcome.completed:
        if (e.detail == 'reply truncated at max output tokens') {
          notices.add(const ChatNotice(
            code: 'truncated',
            message: 'The reply hit the maximum length and was cut off.',
            kind: ChatNoticeKind.warning,
          ));
        }
        unawaited(_platform.haptic(ChatHaptic.runComplete));
      case RunOutcome.cancelled:
        status = ChatRunStatus.cancelled;
        if (!(e.detail ?? '').startsWith('discarded')) {
          notices.add(const ChatNotice(code: 'stopped', message: 'You stopped this response.'));
        }
      case RunOutcome.maxSteps:
        notices.add(ChatNotice(
          code: 'max_steps',
          message: 'Paused after ${_config.maxSteps} steps so you can check in.',
          kind: ChatNoticeKind.warning,
          action: ChatNoticeAction.continueRun,
        ));
      case RunOutcome.needsUserAction || RunOutcome.failed:
        status = ChatRunStatus.error;
        error = chatErrorFrom(e.error, outcome: e.outcome, detail: e.detail, model: state.model);
    }
    final items = _buildItems();
    _flush(base: state.copyWith(
      status: status,
      lastOutcome: e.outcome,
      error: error,
      notices: notices,
      pendingApproval: null,
      pendingUserText: null,
      draft: null,
      items: items,
      historyCount: math.min(state.historyCount, items.length),
    ));
    if (_runnerStale) {
      _runner = null;
      _runnerChoice = null;
      _runnerStale = false;
    }
    _completeRun();
  }

  void _completeRun() {
    _runActive = false;
    final sub = _runSub;
    _runSub = null;
    unawaited(sub?.cancel());
    final link = _keepAlive;
    _keepAlive = null;
    link?.close();
    final done = _runDone;
    _runDone = null;
    if (done != null && !done.isCompleted) done.complete();
  }

  void _onApprovalChanged(PendingApproval? pending) {
    if (_disposed) return;
    if (pending != null) {
      _liveTools[pending.call.id] = _toolView(pending.call, ToolRunStatus.awaitingApproval);
      _invalidateTools();
      unawaited(_platform.haptic(ChatHaptic.approvalRequested));
    }
    _flush(base: state.copyWith(
      pendingApproval: pending,
      status: pending != null
          ? ChatRunStatus.awaitingApproval
          : (_runActive && !_finishing && !_stopping ? ChatRunStatus.runningTools : state.status),
    ));
  }

  // ---------------------------------------------------------------------------
  // Transcript bookkeeping

  void _setPath(List<Message> path) {
    _path = List.unmodifiable(path);
    _pathTools = toolViewsFromPath(_path, lookup: _router.lookup, sourceLabel: sourceLabelOf, previous: _pathTools);
    _invalidateTools();
  }

  /// Applies a persisted message without a store round trip. Returns false
  /// (and schedules a reload) when it doesn't extend the known path.
  bool _applyMessage(Message m) {
    final index = _path.indexWhere((x) => x.id == m.id);
    if (index >= 0) {
      _setPath([..._path]..[index] = m);
      return true;
    }
    final parentMatches = _path.isEmpty ? m.parentId == null : m.parentId == _path.last.id;
    if (!parentMatches) {
      unawaited(_guarded(_reloadPath));
      return false;
    }
    _setPath([..._path, m]);
    _touchedParents.add(m.parentId);
    final sibs = _siblings[m.parentId];
    _siblings[m.parentId] = [...?sibs?.where((s) => s.id != m.id), m];
    return true;
  }

  /// Re-reads the active path from the store. Concurrent reloads collapse
  /// to the newest; unless [force], a snapshot older than what events have
  /// already applied is ignored so nothing that was shown disappears.
  Future<void> _reloadPath({
    bool force = false,
    bool finishing = false,
    int? historyCount,
    ChatScrollKind? scroll,
  }) async {
    final seq = ++_reloadSeq;
    final session = await _store.getSession(sessionId);
    if (session == null) return;
    final leaf = session.activeLeafId;
    final fresh = leaf == null ? <Message>[] : await _store.path(sessionId, leaf);
    // A message we haven't seen means its parent gained a child (send,
    // edit, retry): refresh that parent's sibling list.
    final known = {for (final m in _path) m.id};
    for (final m in fresh) {
      if (!known.contains(m.id)) {
        _siblings.remove(m.parentId);
        _touchedParents.add(m.parentId);
      }
    }
    await _prefetchSiblings(fresh);
    if (_disposed || seq != _reloadSeq) return;

    var next = fresh;
    if (!force && _isPrefix(fresh, _path)) next = _path; // events got further than this read
    _setPath(next);
    final ids = {for (final m in next) m.id};
    if (_pendingUserId != null && ids.contains(_pendingUserId)) {
      _pendingUser = null;
      _pendingUserId = null;
    }
    if (_draft != null && ids.contains(_draft!.messageId)) _draft = null;
    if (finishing) return; // _finishRun publishes the final state itself.
    final items = _buildItems();
    _flush(base: state.copyWith(
      title: session.title,
      items: items,
      pendingUserText: _pendingUser,
      historyCount: math.min(historyCount ?? state.historyCount, items.length),
      scrollRequest: scroll == null ? state.scrollRequest : ChatScrollRequest(++_scrollNonce, scroll),
    ));
  }

  /// Fetches sibling lists for the parents whose branch counts are shown:
  /// user messages and the first step of each assistant turn.
  Future<void> _prefetchSiblings(List<Message> path) async {
    final needed = <String?>{};
    for (var i = 0; i < path.length; i++) {
      final m = path[i];
      final turnStart = m.role == Role.assistant && (i == 0 || path[i - 1].role == Role.user);
      if (m.role == Role.user || turnStart) needed.add(m.parentId);
    }
    for (final parent in needed) {
      if (_siblings.containsKey(parent)) continue;
      _siblings[parent] = _ordered(await _store.children(sessionId, parent));
    }
  }

  List<ChatItem> _buildItems() => buildTranscriptItems(
        path: _path,
        siblings: _siblings,
        runActive: _runActive && !_finishing,
        previous: state.items,
        pendingUserText: _pendingUser,
      );

  void _truncateAfter(String messageId) {
    final i = _path.indexWhere((m) => m.id == messageId);
    if (i >= 0) _setPath(_path.sublist(0, i + 1));
  }

  void _truncateBefore(String messageId) {
    final i = _path.indexWhere((m) => m.id == messageId);
    if (i >= 0) _setPath(_path.sublist(0, i));
  }

  int _itemIndexOf(String messageId) {
    for (final (i, item) in state.items.indexed) {
      switch (item) {
        case UserItem(:final message) when message.id == messageId:
          return i;
        case AssistantTurnItem(:final steps) when steps.any((s) => s.id == messageId):
          return i;
        default:
          break;
      }
    }
    // A tool message belongs to the turn of the assistant message before it.
    final at = _path.indexWhere((m) => m.id == messageId);
    if (at > 0) return _itemIndexOf(_path[at - 1].id);
    return state.items.length;
  }

  AssistantTurnItem? _turnContaining(String messageId) {
    for (final item in state.items) {
      if (item is AssistantTurnItem && item.steps.any((s) => s.id == messageId)) return item;
    }
    return null;
  }

  String _visibleTextOf(String messageId) {
    for (final item in state.items) {
      switch (item) {
        case UserItem(:final message) when message.id == messageId:
          return message.text;
        case AssistantTurnItem(:final steps) when steps.any((s) => s.id == messageId):
          return item.copyText;
        default:
          break;
      }
    }
    return '';
  }

  Future<Message?> _message(String id) async {
    for (final m in _path) {
      if (m.id == id) return m;
    }
    return _store.getMessage(sessionId, id);
  }

  Future<SessionRecord> _requireSession() async =>
      await _store.getSession(sessionId) ?? (throw StateError('unknown session $sessionId'));

  /// Non-draft children, oldest first (stable for equal timestamps).
  static List<Message> _ordered(List<Message> children) {
    final list = [
      for (final (i, m) in children.indexed)
        if (m.metadata['draft'] != true) (i, m),
    ]..sort((a, b) {
        final c = a.$2.createdAt.compareTo(b.$2.createdAt);
        return c != 0 ? c : a.$1.compareTo(b.$1);
      });
    return [for (final e in list) e.$2];
  }

  static bool _isPrefix(List<Message> shorter, List<Message> longer) {
    if (shorter.length > longer.length) return false;
    for (var i = 0; i < shorter.length; i++) {
      if (shorter[i].id != longer[i].id) return false;
    }
    return true;
  }

  // ---------------------------------------------------------------------------
  // Tool views

  ToolExecutionView _toolView(ToolCall call, ToolRunStatus status) {
    final def = _router.lookup(call.name);
    return ToolExecutionView(
      callId: call.id,
      toolName: call.name,
      displayName: def?.displayName ?? call.name,
      sourceLabel: sourceLabelOf(def?.source),
      status: status,
    );
  }

  void _invalidateTools() => _toolsCache = null;

  /// Path-derived results win over live state once a result is persisted.
  Map<String, ToolExecutionView> _toolsSnapshot() => _toolsCache ??= _liveTools.isEmpty
      ? _pathTools
      : Map.unmodifiable({
          ..._pathTools,
          for (final e in _liveTools.entries)
            if (!_pathTools.containsKey(e.key)) e.key: e.value,
        });

  // ---------------------------------------------------------------------------
  // Publishing

  /// Publishes coalesced changes on the next frame (at most once per frame).
  void _markDirty() {
    _dirty = true;
    if (_flushScheduled) return;
    _flushScheduled = true;
    _frames.scheduleFrameCallback(() {
      _flushScheduled = false;
      if (_dirty && !_disposed) _flush();
    });
  }

  /// Publishes now, folding in the latest draft and tool snapshot.
  void _flush({ChatViewState? base}) {
    if (_disposed) return;
    _dirty = false;
    final b = base ?? state;
    state = b.copyWith(
      draft: _draft?.snapshot(),
      tools: _toolsSnapshot(),
      pendingUserText: _pendingUser,
    );
  }

  void _commit(ChatViewState next) {
    if (_disposed) return;
    state = next;
  }

  void _setStatus(ChatRunStatus status) {
    if (state.status == status) return;
    _flush(base: state.copyWith(status: status));
  }

  void _showError(ChatError error) => _commit(state.copyWith(error: error));

  void _dismissNotice(String code) {
    if (!state.notices.any((n) => n.code == code)) return;
    _commit(state.copyWith(notices: state.notices.where((n) => n.code != code).toList()));
  }

  static bool _isSetupError(ChatError? e) =>
      e != null &&
      const {
        ChatErrorKind.noProvider,
        ChatErrorKind.needsModel,
        ChatErrorKind.providerMissing,
        ChatErrorKind.modelNotFound,
        ChatErrorKind.auth,
        ChatErrorKind.quotaExceeded,
        ChatErrorKind.contextOverflow,
      }.contains(e.kind);

  /// The runner's notice text is technical (`rateLimited: retrying in
  /// 800 ms`); the transcript shows a calm sentence instead.
  static String _noticeCopy(String code, String message) {
    if (code != 'retrying') return message;
    if (message.startsWith('${ProviderErrorKind.rateLimited.name}:')) return 'Rate limited — retrying shortly…';
    if (message.startsWith('${ProviderErrorKind.overloaded.name}:')) return 'The server is busy — retrying…';
    return 'Connection problem — retrying…';
  }

  /// Best-effort work whose failure must not surface as an error.
  Future<void> _quiet(Future<void> Function() body) async {
    try {
      await body();
    } on Object catch (e) {
      if (!_disposed) debugPrint('chat[$sessionId] (ignored): $e');
    }
  }

  /// Runs [body]; any failure becomes a visible, actionable error.
  Future<void> _guarded(Future<void> Function() body) async {
    try {
      await body();
    } on Object catch (e, st) {
      if (_disposed) return;
      debugPrint('chat[$sessionId]: $e\n$st');
      _showError(chatErrorFrom(e, model: state.model));
    }
  }

  void _dispose() {
    _disposed = true;
    _approvals.denyAll();
    _runner?.cancel('chat closed');
    unawaited(_runSub?.cancel());
    unawaited(_registrySub?.cancel());
    unawaited(_prefsSub?.cancel());
    final done = _runDone;
    if (done != null && !done.isCompleted) done.complete();
  }
}
