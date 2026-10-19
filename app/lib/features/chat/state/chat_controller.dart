import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show KeepAliveLink;
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_providers/sherpa_providers.dart';
import 'package:sherpa_webview/sherpa_webview.dart' show McpAppModelContext;

import '../../../services/background/background_copy.dart' show expectedChatTitle;
import '../../../services/background/background_providers.dart';
import '../../../services/background/run_activity.dart';
import '../../../services/inference/on_device_ids.dart' show isOnDeviceProviderId, onDeviceProviderIds, onDeviceProviderName;
import '../../../services/mcp/composer_sources.dart';
import '../../../state/providers.dart';
import '../../../state/services.dart';
import '../../../state/ui_preferences.dart';
import '../../apps/state/apps_providers.dart';
import '../../context/state/context_actions.dart';
import '../../diagnostics/app_error_ring.dart';
import '../../mcp/state/mcp_providers.dart';
import '../attachments/attachment_policy.dart';
import '../attachments/attachment_store.dart';
import '../attachments/composer_attachments.dart';
import '../attachments/inlining_provider.dart';
import 'chat_dependencies.dart';
import 'chat_errors.dart';
import 'chat_view_state.dart';
import 'draft_builder.dart';
import 'frame_scheduler.dart';
import 'model_selection.dart';
import 'notice_copy.dart';
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
///   actions the user can act on. Each is also recorded, by type and code
///   only, in the diagnostics error ring ([AppErrorRing], source `chat`).
/// * Every run is registered with [RunActivity], which keeps it alive when
///   the user leaves the app (a foreground service / background task),
///   says what it does in the notification, and asks the chat to stop it
///   with a checkpoint when the OS ends the background time first: the
///   chat then says so and offers Continue ([kBackgroundPausedNotice]).
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
  late RunActivity _activity;
  late AppErrorRing _errors;

  /// The current run's registration with [_activity].
  BackgroundRun? _background;

  /// The current run was stopped because the background time ended.
  bool _pausedForBackground = false;

  AgentRunner? _runner;
  ModelChoice? _runnerChoice;

  /// The provider instance [_runner] talks to. The registry builds a new
  /// instance whenever a provider is edited (base URL, key, headers), so an
  /// unchanged [ModelChoice] alone doesn't mean the runner is current.
  ModelProvider? _runnerProvider;
  bool _runnerStale = false;

  /// What "Try again" on the current error card repeats (see [retryError]).
  ({ChatError error, Future<void> Function() again})? _retry;

  /// Notices the user dismissed that the runner repeats on every run of a
  /// chat ([_repeatingNotices]): once is enough.
  final Set<String> _dismissedNotices = {};

  /// Said again by every run once true (the chat stays tainted); other
  /// notices report a new event each time and are shown again.
  static const _repeatingNotices = {'untrusted_content'};

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

  /// The chat's approval UI as an [ApprovalHandler]: the agent loop asks
  /// through it, and so do MCP App views of this chat for the tool calls
  /// they make themselves (their call ids start with
  /// [PendingApproval.appCallPrefix]; the card says "Requested by an
  /// app"). Ending or stopping a run never answers an app's request.
  UiApprovalHandler get approvalHandler => _approvals;

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
    _activity = ref.read(runActivityProvider);
    _errors = ref.read(appErrorRingProvider);
    try {
      _prefs = ref.read(preferencesProvider);
    } on Object {
      _prefs = null; // Optional: chats work without a default model.
    }
    _approvals = UiApprovalHandler(onChanged: _onApprovalChanged, clock: _clock);
    ref.onDispose(_dispose);
    _registrySub = _registry.changes.listen((_) => _onRegistryChanged());
    _prefsSub = _prefs?.changes.listen((_) => unawaited(_guarded(_refreshModel, failed: "update this chat's model")));
    // Who writes summaries is part of the runner's context manager.
    ref.listen(uiSettingsProvider.select((s) => s.modelSummaries), (_, _) => _invalidateRunner());
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
  ///
  /// [mentions] (MCP resources picked with `@`) are resolved after that and
  /// attached to the message: the text of a small one is embedded, others
  /// are linked. The agent loop counts either as untrusted content.
  ///
  /// [attachments] from the composer go first (photos are stored as files
  /// and sent as images; text files and PDFs as resources). Context that
  /// MCP App views set for the model since the last user turn rides along
  /// as untrusted app data ([McpAppModelContexts]).
  Future<void> send(
    String text, {
    List<McpResourceSuggestion> mentions = const [],
    List<ComposerAttachment> attachments = const [],
  }) async {
    final trimmed = text.trim();
    if ((trimmed.isEmpty && mentions.isEmpty && attachments.isEmpty) || _runActive) return;
    unawaited(_platform.haptic(ChatHaptic.send));
    await _launch(
      anchorAt: state.items.length,
      pendingUser: trimmed.isNotEmpty
          ? trimmed
          : [for (final a in attachments) a.name, for (final m in mentions) '@${m.mention}'].join(' '),
      userTurn: true,
      open: (runner) async {
        final files = await attachmentParts(
          attachments,
          sessionId: sessionId,
          store: ref.read(chatAttachmentStoreProvider),
        );
        final attached = await _resolveMentions(mentions);
        final app = _takeAppContexts();
        return runner.send(
          sessionId,
          [...files.parts, if (trimmed.isNotEmpty) TextPart(trimmed), ...attached.parts, ...app.parts],
          metadata: _mergeMetadata(attached.metadata, app.listed, files.listed),
        );
      },
      again: () => send(trimmed, mentions: mentions, attachments: attachments),
    );
  }

  /// Sends a message an MCP App view proposed and the user confirmed
  /// (`ui/message`), then runs the agent as for [send]. The message is
  /// stored as the user's but attributed: "Sent by [from]" in the bubble
  /// ([kMcpAppMessageKey]), and flagged untrusted for the agent loop (an
  /// untrusted server's view wrote it). While a run is active it waits for
  /// the run to end rather than being dropped.
  Future<void> sendAppMessage(String text, {required String from}) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    await _loaded;
    // Another queued message may start first when a run ends: wait again.
    do {
      await _whenIdle();
      if (_disposed) return;
    } while (_runActive);
    unawaited(_platform.haptic(ChatHaptic.send));
    await _launch(
      anchorAt: state.items.length,
      pendingUser: trimmed,
      userTurn: true,
      open: (runner) async {
        final app = _takeAppContexts();
        return runner.send(
          sessionId,
          [TextPart(trimmed), ...app.parts],
          metadata: {
            kMcpAppMessageKey: {'label': from},
            UntrustedData.messageMetadataKey: true,
            ..._mergeMetadata(const {}, app.listed, const []),
          },
        );
      },
      again: () => sendAppMessage(trimmed, from: from),
    );
  }

  /// Completes once no run (or context rewrite) is active.
  Future<void> _whenIdle() async {
    while (_runActive && !_disposed) {
      final done = _runDone;
      if (done != null && !done.isCompleted) {
        await done.future;
      } else {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  }

  /// The model context MCP App views of this chat set since the last user
  /// turn (taken, so each is sent once), as untrusted resources the agent
  /// loop counts as tainted content, plus their [kMcpResourcesKey] entries.
  ({List<ContentPart> parts, List<JsonMap> listed}) _takeAppContexts() {
    List<McpAppModelContext> contexts;
    try {
      contexts = ref.read(mcpAppModelContextsProvider).take(sessionId);
    } on Object catch (e) {
      debugPrint('chat[$sessionId] (app context): $e');
      return (parts: const [], listed: const []);
    }
    final parts = <ContentPart>[];
    final listed = <JsonMap>[];
    for (final (i, c) in contexts.indexed) {
      final hasText = c.content.any((b) => b['type'] == 'text' && b['text'] is String && (b['text']! as String).trim().isNotEmpty);
      if (!hasText) continue;
      final id = c.identity;
      final uri = Uri(scheme: 'mcp-app-context', path: '${id.serverId}/$i/${id.label}').toString();
      parts.add(EmbeddedResourcePart(uri: uri, mimeType: 'text/plain', text: McpAppModelContexts.render(c)));
      listed.add({
        'uri': uri,
        'serverId': id.serverId,
        'serverName': id.serverName,
        'name': 'Context from ${id.appName == null || id.appName!.isEmpty ? 'an app' : id.appName}',
      });
    }
    return (parts: parts, listed: listed);
  }

  /// [base] (mention metadata) with app contexts added to its resource list
  /// and the [kMessageAttachmentsKey] list.
  static JsonMap _mergeMetadata(JsonMap base, List<JsonMap> appContexts, List<JsonMap> attachments) {
    if (appContexts.isEmpty && attachments.isEmpty) return base;
    final resources = base[kMcpResourcesKey];
    return {
      ...base,
      if (appContexts.isNotEmpty || resources != null)
        kMcpResourcesKey: [if (resources is List) ...resources, ...appContexts],
      if (attachments.isNotEmpty) kMessageAttachmentsKey: attachments,
    };
  }

  /// Sends what an MCP prompt (a slash command) expanded to. Every message
  /// before the last is stored as the prompt wrote it; the last one, a user
  /// message, is sent through the runner. Each keeps the prompt's metadata,
  /// so a message from a server the user doesn't trust stays flagged as
  /// untrusted for the agent loop, and the transcript says where it came
  /// from. [mentions] attach to the last message as in [send].
  ///
  /// A prompt that ends with an assistant message leaves nothing to answer:
  /// its messages are added and the user continues from there.
  Future<void> sendPrompt(McpExpandedPrompt prompt, {List<McpResourceSuggestion> mentions = const []}) async {
    if (_runActive || prompt.messages.isEmpty) return;
    final messages = prompt.messages;
    final last = messages.last;
    if (last.role != Role.user) {
      await _guarded(failed: 'add the prompt', () async {
        await _appendPromptMessages(prompt, messages);
        await _reloadPath(force: true, scroll: ChatScrollKind.bottom);
      });
      return;
    }
    final text = [for (final p in last.content) if (p is TextPart) p.text].join('\n').trim();
    unawaited(_platform.haptic(ChatHaptic.send));
    await _launch(
      anchorAt: state.items.length,
      pendingUser: text.isEmpty ? '/${prompt.command.command}' : text,
      userTurn: true,
      open: (runner) async {
        await _appendPromptMessages(prompt, messages.sublist(0, messages.length - 1));
        final attached = await _resolveMentions(mentions);
        final app = _takeAppContexts();
        return runner.send(
          sessionId,
          [...last.content, ...attached.parts, ...app.parts],
          metadata: _mergeMetadata({..._promptMetadata(prompt, last), ...attached.metadata}, app.listed, const []),
        );
      },
      again: () => sendPrompt(prompt, mentions: mentions),
    );
  }

  /// [m]'s metadata plus the server's name and the command, for the label.
  static JsonMap _promptMetadata(McpExpandedPrompt prompt, McpExpandedMessage m) {
    final p = m.metadata[kMcpPromptKey];
    return {
      ...m.metadata,
      kMcpPromptKey: {
        if (p is Map) ...p.cast<String, Object?>(),
        'serverName': prompt.command.serverName,
        'command': prompt.command.command,
      },
    };
  }

  /// Stores [messages] as a chain under the active leaf and moves the leaf
  /// to the last one.
  Future<void> _appendPromptMessages(McpExpandedPrompt prompt, List<McpExpandedMessage> messages) async {
    if (messages.isEmpty) return;
    final session = await _requireSession();
    final ids = ref.read(idGeneratorProvider);
    var parent = session.activeLeafId;
    for (final m in messages) {
      final message = Message(
        id: ids.next('msg'),
        parentId: parent,
        role: m.role,
        content: m.content,
        createdAt: _clock.now(),
        metadata: _promptMetadata(prompt, m),
      );
      await _store.putMessage(sessionId, message);
      parent = message.id;
    }
    await _store.putSession(session.copyWith(activeLeafId: parent, updatedAt: _clock.now()));
  }

  /// Resolves `@` mentions to message parts, plus the metadata that names
  /// each one's server for the transcript.
  Future<({List<ContentPart> parts, JsonMap metadata})> _resolveMentions(List<McpResourceSuggestion> mentions) async {
    if (mentions.isEmpty) return (parts: const <ContentPart>[], metadata: const <String, Object?>{});
    final sources = ref.read(chatMcpSourcesProvider);
    final parts = <ContentPart>[];
    final listed = <JsonMap>[];
    for (final m in mentions) {
      final part = await sources.resolveMention(m);
      final uri = switch (part) {
        EmbeddedResourcePart(:final uri) || ResourceLinkPart(:final uri) => uri,
        _ => m.resource.uri,
      };
      parts.add(part);
      listed.add({'uri': uri, 'serverId': m.serverId, 'serverName': m.serverName, 'mention': m.mention, 'name': m.label});
    }
    return (parts: parts, metadata: {kMcpResourcesKey: listed});
  }

  /// Stops everything: streaming, tools, and any open approval (denied).
  void stop() {
    if (!_runActive) return;
    _stopping = true;
    _runner?.cancel('stopped by user');
    _denyRunApprovals();
  }

  /// Denies the run's pending approvals; requests from MCP App views keep
  /// waiting for the user (they are not part of the run).
  void _denyRunApprovals() => _approvals.denyWhere((r) => !r.isFromApp);

  /// Answers the approval card currently shown.
  void respondToApproval(ApprovalResponse response) {
    final pending = state.pendingApproval;
    if (pending == null) return;
    _approvals.respond(pending.call.id, response);
  }

  /// Regenerates the reply [assistantMessageId] belongs to from its parent,
  /// keeping the old reply as a sibling branch ("‹ 2/2 ›").
  Future<void> retry(String assistantMessageId, {bool long = false}) async {
    if (_runActive) return;
    final message = await _message(assistantMessageId);
    final parentId = message?.parentId;
    if (message == null || parentId == null) {
      _showError(actionErrorFrom(StateError('cannot retry $assistantMessageId'), failed: 'regenerate this reply'));
      return;
    }
    await _launch(
      anchorAt: _itemIndexOf(assistantMessageId),
      keepThrough: parentId,
      userTurn: true,
      long: long,
      open: (runner) => runner.regenerate(sessionId, fromMessageId: parentId),
      again: () => retry(assistantMessageId, long: long),
    );
  }

  /// Retries whatever ended last: a failed or stopped partial reply is
  /// regenerated from its parent (keeping earlier tool work); a finished
  /// turn is regenerated as a whole; a turn that never produced output is
  /// re-run from its user or tool message.
  ///
  /// "Stopped" counts as partial: after Stop during the text that follows a
  /// tool step, only that step is regenerated, so the tools that already
  /// ran are kept and never executed a second time. [long]: the user is
  /// continuing an agent run (see [continueRun]).
  Future<void> retryLast({bool long = false}) async {
    if (_runActive) return;
    final leaf = _path.isEmpty ? null : _path.last;
    if (leaf == null) return;
    if (leaf.role == Role.assistant) {
      final partial = leaf.finishReason == FinishReason.error.name ||
          leaf.finishReason == FinishReason.cancelled.name ||
          leaf.metadata['error'] != null;
      if (partial) return retry(leaf.id, long: long);
      final turn = _turnContaining(leaf.id);
      return retry(turn?.firstMessageId ?? leaf.id, long: long);
    }
    await _launch(
      anchorAt: state.items.length,
      userTurn: true,
      long: long,
      open: (runner) => runner.regenerate(sessionId, fromMessageId: leaf.id),
      again: () => retryLast(long: long),
    );
  }

  /// Continues a run that stopped at the step limit, or one stopped because
  /// Sherpa's background time ended ([kBackgroundPausedNotice]), from its
  /// last tool results (a cut-off reply is regenerated from where it
  /// started, keeping earlier tool work), without inventing a user
  /// message. The user asked for more of an agent run, so it may keep a
  /// long background lease from the start.
  Future<void> continueRun() async {
    if (_runActive || _path.isEmpty) return;
    final leaf = _path.last;
    _dismissNotice(kBackgroundPausedNotice);
    _activity.clearPaused(sessionId);
    if (leaf.role != Role.tool && leaf.role != Role.user) return retryLast(long: true);
    _dismissNotice('max_steps');
    await _launch(
      anchorAt: _itemIndexOf(leaf.id),
      long: true,
      open: (runner) => runner.regenerate(sessionId, fromMessageId: leaf.id),
      again: continueRun,
    );
  }

  /// Edit-and-resubmit: a new user message as a sibling of
  /// [userMessageId]; the original exchange stays as another branch.
  Future<void> edit(String userMessageId, String newText) async {
    final trimmed = newText.trim();
    if (trimmed.isEmpty || _runActive) return;
    final message = await _message(userMessageId);
    if (message == null || message.role != Role.user) {
      _showError(actionErrorFrom(StateError('cannot edit $userMessageId'), failed: 'edit this message'));
      return;
    }
    await _launch(
      anchorAt: _itemIndexOf(userMessageId),
      keepBefore: userMessageId,
      pendingUser: trimmed,
      userTurn: true,
      open: (runner) => runner.edit(sessionId, userMessageId, [TextPart(trimmed), ..._takeAppContexts().parts]),
      again: () => edit(userMessageId, trimmed),
    );
  }

  /// Starts a run with an optimistic UI: the transcript is truncated to
  /// where the new branch starts ([keepThrough] / [keepBefore]), the pending
  /// user text and the live "thinking" turn appear immediately, and all of
  /// it is rolled back if the run can't start (no provider, store error).
  /// [again] is the public call that launched it: "Try again" on a failure
  /// to start repeats it (resends the message) rather than regenerating an
  /// earlier reply. [userTurn] marks a new user turn (send, edit,
  /// regenerate; not "continue"): tool changes made since the chat's tool
  /// list was frozen take effect from it ([toolsUserTurnHookProvider]).
  Future<void> _launch({
    required int anchorAt,
    required FutureOr<Stream<AgentEvent>> Function(AgentRunner runner) open,
    required Future<void> Function() again,
    String? pendingUser,
    String? keepThrough,
    String? keepBefore,
    bool userTurn = false,
    bool long = false,
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
        error: error == null ? null : _bindRetry(error, again),
      ));
    }

    _runActive = true;
    _stopping = false;
    _retry = null;
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
      _recordError(e);
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
    if (userTurn) _userTurnBoundary();
    Stream<AgentEvent> events;
    try {
      events = await open(runner);
    } on Object catch (e, st) {
      debugPrint('chat[$sessionId]: $e\n$st');
      _recordError(e);
      if (_disposed) return;
      rollback(chatErrorFrom(e, model: state.model));
      return;
    }
    if (_disposed) return;
    if (_stopping) {
      rollback(null);
      return;
    }
    await _run(events, anchorAt: anchorAt, long: long);
  }

  /// A new user turn: lets MCP start a new tool segment when servers,
  /// switches or approvals changed since this chat's tool list was frozen.
  void _userTurnBoundary() {
    try {
      ref.read(toolsUserTurnHookProvider)(sessionId);
    } on Object catch (e) {
      debugPrint('chat[$sessionId] (tool segment): $e');
    }
  }

  /// Waits until MCP has listed every server's tools (start-up), so a
  /// resumed run finds the tools of its interrupted calls. Never blocks
  /// for good: a failure only means some tool may read as unknown.
  Future<void> _toolsReady() async {
    try {
      await ref.read(toolsReadyProvider)();
    } on Object catch (e) {
      debugPrint('chat[$sessionId] (tools ready): $e');
    }
  }

  /// Shows the previous/next sibling of [messageId]: the session's active
  /// leaf moves to the deepest message along the first-child chain of the
  /// chosen sibling.
  Future<void> switchBranch(String messageId, BranchDirection direction) async {
    if (_runActive) return;
    await _guarded(failed: 'switch to that version', () async {
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
      _recordError(e);
      _showError(actionErrorFrom(e, failed: 'copy the text'), again: () => copy(messageId));
      return false;
    }
  }

  /// Opens the system share sheet with the same text [copy] would copy.
  Future<void> share(String messageId) async {
    final text = _visibleTextOf(messageId);
    if (text.isEmpty) return;
    await _guarded(
      failed: 'share this reply',
      () => _platform.shareText(text, subject: state.title.isEmpty ? null : state.title),
    );
  }

  /// Switches the chat to another provider/model. Future turns use it; a
  /// running turn finishes on the model it started with.
  Future<void> changeModel(ModelChoice choice) async {
    await _guarded(failed: 'switch the model', () async {
      final session = await _requireSession();
      await _store.putSession(session.copyWith(
        providerId: choice.providerId,
        modelId: choice.modelId,
        updatedAt: _clock.now(),
      ));
      _invalidateRunner();
      if (_isSetupError(state.error)) _commit(state.copyWith(error: null));
      await _refreshModel();
      unawaited(_quiet(_estimateBudget));
    });
  }

  /// Continues a run that was interrupted (app killed mid-reply) from its
  /// last checkpoint. Approvals that were pending are asked again.
  Future<void> resumeIfInterrupted() async {
    if (_runActive) return;
    await _guarded(failed: 'resume the interrupted reply', () async {
      await _loaded;
      final cp = await _store.getCheckpoint(sessionId);
      if (cp == null || cp.isTerminal || cp.leafMessageId == null) {
        _commit(state.copyWith(interrupted: null));
        return;
      }
      final runner = await _ensureRunner();
      await _toolsReady();
      if (_disposed || _runActive) return;
      final last = state.items.isEmpty ? null : state.items.last;
      final anchor = last is AssistantTurnItem ? state.items.length - 1 : state.items.length;
      // Resuming an agent run the user asked to continue.
      final agent = cp.step > 1 || cp.phase == RunPhase.awaitingApproval || cp.phase == RunPhase.executingTools;
      await _run(runner.resume(sessionId), anchorAt: anchor, long: agent);
    });
  }

  /// Abandons an interrupted run. The runner closes it properly (every
  /// dangling tool call gets a "cancelled" result) so the branch stays
  /// valid to continue.
  Future<void> discardInterrupted() async {
    if (_runActive) return;
    await _guarded(failed: 'discard the interrupted reply', () async {
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
      _recordError(e);
      // Retrying from the card wouldn't navigate; "New chat" goes through
      // the screen, which does.
      _showError(actionErrorFrom(e, failed: 'start a new chat', actions: const [ChatErrorAction.newChat]));
      return null;
    }
  }

  /// "Try again" on the error card: repeats exactly what failed. A failed
  /// run is retried from where it stopped ([retryLast]); a failed action
  /// (share, copy, branch switch, model change, a send that could not
  /// start) is repeated as that action, so a failed share never
  /// regenerates a reply.
  Future<void> retryError() async {
    final pending = _retry;
    _retry = null;
    if (pending == null || !identical(pending.error, state.error)) return;
    _commit(state.copyWith(error: null));
    await pending.again();
  }

  void dismissError() {
    _retry = null;
    _commit(state.copyWith(error: null));
  }

  void dismissNotice(String code) {
    if (_repeatingNotices.contains(code)) _dismissedNotices.add(code);
    if (code == kBackgroundPausedNotice) _activity.clearPaused(sessionId);
    _dismissNotice(code);
  }

  // ---------------------------------------------------------------------------
  // Context (M3). The inspector, "Compact now" and undo go through the
  // controller so a context rewrite can never race a run (for append-only
  // models a rewrite inside a tool loop would invalidate that turn's
  // reasoning) and the context ring reflects the change at once. Unlike the
  // chat actions above these throw: the inspector reports failures in place.

  ContextActions get _contextActions => ContextActions(
        store: _store,
        registry: _registry,
        router: _router,
        config: _config,
        manager: ref.read(chatContextManagerProvider),
        extras: ref.read(chatContextExtrasProvider),
        memory: ref.read(memoryMonitorProvider),
        clock: _clock,
        ids: ref.read(idGeneratorProvider),
      );

  /// What the next request would send, for the context inspector; null
  /// while the chat has no usable model (the window size is unknown then).
  Future<ContextSnapshot?> inspectContext() async {
    await _loaded;
    final model = state.model;
    if (model == null || state.availability != ProviderAvailability.ready) return null;
    return _contextActions.snapshot(sessionId, model.choice);
  }

  /// Summarizes older turns now, persisted like a ladder-made overlay.
  /// Null when a run is active or there is no model.
  Future<CompactionOutcome?> compactNow() =>
      _contextChange((choice) => _contextActions.compactNow(sessionId, choice));

  /// Undoes [overlayId] together with the overlays built on it; returns the
  /// ids removed (null when a run is active or there is no model).
  Future<List<String>?> undoContextChange(String overlayId) =>
      _contextChange((choice) => _contextActions.undo(sessionId, choice, overlayId));

  /// The newest recorded context change (the context ring's "last change").
  Future<ContextOverlay?> lastContextChange() => _contextActions.latestOverlay(sessionId);

  Future<T?> _contextChange<T>(Future<T> Function(ModelChoice choice) body) async {
    await _loaded;
    final model = state.model;
    if (_runActive || model == null || state.availability != ProviderAvailability.ready) return null;
    _runActive = true; // a send waits for the overlay to be persisted
    try {
      final result = await body(model.choice);
      final after = await _contextActions.snapshot(sessionId, model.choice);
      _commit(state.copyWith(
        budget: after.budget,
        contextLevel: after.inspection.level,
        budgetIsEstimate: true,
      ));
      return result;
    } finally {
      _runActive = false;
    }
  }

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
        // Stopped while the chat was closed (its controller was freed).
        notices: _activity.wasPausedInBackground(sessionId) ? [backgroundPausedNotice()] : state.notices,
      ));
      await _refreshModel(session: session);
      unawaited(_quiet(_estimateBudget));
    } on Object catch (e) {
      _recordError(e);
      if (_disposed) return;
      _commit(state.copyWith(
        loading: false,
        error: _bindRetry(chatErrorFrom(e), () async {
          _loaded = _load();
          await _loaded;
        }),
      ));
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
      // Models on this phone make the chat usable without any provider.
      final onDevice = await _onDeviceModelCount();
      if (_disposed) return;
      _commit(state.copyWith(
        availability: configs.isEmpty && onDevice == 0 ? ProviderAvailability.noProviders : ProviderAvailability.needsModel,
        model: null,
        onDeviceModels: onDevice,
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
      final onDevice = isOnDeviceProviderId(choice.providerId);
      selection = ModelSelection(
        providerId: choice.providerId,
        modelId: choice.modelId,
        providerName: config?.displayName ?? onDeviceProviderName(choice.providerId) ?? choice.providerId,
        modelName: previousName ?? choice.modelId,
        // The on-device providers have no config, but never leave the phone.
        location: privacy?.location ?? (onDevice ? ExecutionLocation.onDevice : ExecutionLocation.remote),
        host: privacy?.host,
      );
    }
    if (_disposed) return;
    _commit(state.copyWith(availability: availability, model: selection));

    if (availability != ProviderAvailability.ready) {
      _commit(state.copyWith(attachmentPolicy: AttachmentPolicy.textOnly));
      return;
    }
    unawaited(_quiet(() => _refreshAttachmentPolicy(choice!)));
    try {
      final models = await _registry.models(choice.providerId);
      final d = models.where((m) => m.id == choice!.modelId).firstOrNull;
      final current = state.model;
      if (d != null && !_disposed && current != null && current.modelId == d.id) {
        _commit(state.copyWith(model: current.copyWith(modelName: d.displayName)));
        if (d.displayName != selection.modelName) unawaited(_quiet(() => _refreshAttachmentPolicy(choice!)));
      }
    } on Object {
      // Listing can fail offline; the raw model id is a fine label.
    }
  }

  /// What the model accepts as attachments: vision from its capabilities,
  /// documents and image size from its provider.
  Future<void> _refreshAttachmentPolicy(ModelChoice choice) async {
    final provider = await _registry.resolve(choice.providerId);
    final caps = await provider.capabilities(choice.modelId);
    final model = state.model;
    if (_disposed || model == null || model.choice != choice) return;
    final policy = AttachmentPolicy.forModel(modelName: model.modelName, provider: provider.info, capabilities: caps);
    if (policy != state.attachmentPolicy) _commit(state.copyWith(attachmentPolicy: policy));
  }

  /// How many models the on-device providers offer together: llama.cpp's
  /// library, MLX, LiteRT-LM and the system models (Apple Intelligence,
  /// Gemini Nano). A provider that isn't wired or isn't on this platform
  /// counts 0.
  Future<int> _onDeviceModelCount() async {
    var n = 0;
    for (final id in onDeviceProviderIds) {
      try {
        n += (await _registry.models(id)).length;
      } on Object {
        // Not wired, or not on this platform.
      }
    }
    return n;
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

  /// The runner for the next run, rebuilt when the model choice changed, the
  /// registry changed ([_onRegistryChanged]) or the provider now resolves
  /// to another instance (an edit the change event didn't reach us for).
  Future<AgentRunner> _ensureRunner() async {
    await _loaded;
    final choice = await _choiceForRun();
    final provider = await _registry.resolve(choice.providerId);
    final existing = _runner;
    if (existing != null && _runnerChoice == choice && !_runnerStale && identical(_runnerProvider, provider)) {
      return existing;
    }
    final base = ref.read(chatContextManagerProvider);
    final extras = ref.read(chatContextExtrasProvider)(provider, choice, base);
    final runner = AgentRunner(
      store: _store,
      // Attached photos and PDFs are stored as files; this reads them into
      // each request (providers do no file IO).
      provider: AttachmentInliningProvider(provider, ref.read(chatAttachmentStoreProvider)),
      modelId: choice.modelId,
      tools: _router,
      approvals: ref.read(approvalPolicyProvider),
      approvalHandler: _approvals,
      contextManager: extras.contextManager ?? base,
      counter: extras.counter,
      memory: ref.read(memoryMonitorProvider),
      clock: _clock,
      ids: ref.read(idGeneratorProvider),
      config: _config,
      sleep: ref.read(chatRetrySleepProvider),
    );
    _runner = runner;
    _runnerChoice = choice;
    _runnerProvider = provider;
    _runnerStale = false;
    return runner;
  }

  /// A registry change can rebuild the active provider: an edited base URL,
  /// key or header must never keep going to the old endpoint while the
  /// privacy badge already shows the new one. The change event doesn't say
  /// which provider changed (and a key edit leaves every config as it was),
  /// so the runner is always invalidated; building one is cheap.
  void _onRegistryChanged() {
    _invalidateRunner();
    unawaited(_guarded(_refreshModel, failed: "update this chat's model"));
  }

  /// Drops the runner now when idle; while a run uses it, marks it stale so
  /// the run finishes on what it started with and the next run rebuilds.
  void _invalidateRunner() {
    if (_runActive) {
      _runnerStale = true;
      return;
    }
    _runner = null;
    _runnerChoice = null;
    _runnerProvider = null;
    _runnerStale = false;
  }

  Future<ModelChoice> _choiceForRun() async {
    final session = await _requireSession();
    switch (state.availability) {
      case ProviderAvailability.noProviders:
        throw const ChatSetupException(
          ChatErrorKind.noProvider,
          'Sherpa needs a model to talk to. Download one to run on this phone, or add an API provider such '
          'as Anthropic, OpenAI, or a compatible server like llama.cpp or Ollama.',
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
      await _toolsReady();
      final events = runner.resume(sessionId);
      runner.cancel('discarded interrupted run');
      await events.drain<void>();
      await _reloadPath(force: true);
    }
    if (!_disposed) _commit(state.copyWith(interrupted: null));
  }

  // ---------------------------------------------------------------------------
  // Running

  Future<void> _run(Stream<AgentEvent> events, {required int anchorAt, bool long = false}) {
    final done = Completer<void>();
    _runDone = done;
    _runActive = true;
    _finishing = false;
    // A Stop (or a background pause) of an earlier run is over; _launch
    // has already honoured one that came before this run started.
    _stopping = false;
    _keepAlive ??= ref.keepAlive();
    _registerBackground(long: long);
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
      // An MCP App's request may already be waiting; the run's come later.
      pendingApproval: _approvals.current,
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
        _background?.update(step: step, phase: RunActivityPhase.working);
        if (step > 1) _background?.markLong();
        _setStatus(ChatRunStatus.streaming);
        // Results of a step whose calls were all denied are persisted without
        // a ToolCallFinished event; pick them up before the next reply lands.
        if (step > 1) unawaited(_guarded(_reloadPath, failed: 'refresh the conversation'));
      case Checkpointed(:final checkpoint):
        if (_reloadOnCheckpoint && checkpoint.leafMessageId != null) {
          // The first checkpoint names the run's starting leaf: for send and
          // edit that is the user message the runner just persisted.
          _reloadOnCheckpoint = false;
          if (_pendingUser != null) _pendingUserId = checkpoint.leafMessageId;
          unawaited(_guarded(_reloadPath, failed: 'refresh the conversation'));
        }
      case ContextPrepared(:final budget, :final level):
        _flush(base: state.copyWith(budget: budget, contextLevel: level, budgetIsEstimate: false));
      case ModelStreamed(:final messageId, :final event):
        _background?.update(
          phase: event is ProviderNotice && event.code == kWaitingForForegroundNotice
              ? RunActivityPhase.waitingForApp
              : RunActivityPhase.working,
        );
        final draft = _draft?.messageId == messageId ? _draft! : (_draft = DraftBuilder(messageId));
        draft.apply(event, _clock.now());
        var notices = state.notices;
        // Progress lines end when the reply moves on: a retry succeeded, or
        // the on-device model continues now that Sherpa is back on screen.
        if (notices.any(_isProgressNotice)) notices = notices.where((n) => !_isProgressNotice(n)).toList();
        final notice = event is ProviderNotice ? providerNoticeFor(event) : null;
        if (notice != null) notices = _withNotice(notices, notice);
        if (!identical(notices, state.notices)) {
          _flush(base: state.copyWith(notices: notices));
        } else {
          _markDirty();
        }
      case AssistantMessageCompleted(:final message):
        _onAssistantCompleted(message);
      case ToolApprovalRequested(:final call, :final tool):
        _background
          ?..update(phase: RunActivityPhase.awaitingApproval)
          ..markLong();
        // For a proxy such as `call_tool`, [call] and [tool] are the target.
        _liveTools[call.id] = _toolView(call, ToolRunStatus.awaitingApproval, def: tool);
        _invalidateTools();
        _flush(base: state.copyWith(status: ChatRunStatus.awaitingApproval));
      case ToolApprovalResolved(:final callId, :final approved):
        _background?.update(phase: approved ? RunActivityPhase.usingTool : RunActivityPhase.working);
        final view = _liveTools[callId];
        if (view != null) {
          _liveTools[callId] = view.copyWith(status: approved ? ToolRunStatus.pending : ToolRunStatus.denied);
        }
        _invalidateTools();
        _flush(base: state.copyWith(
          status: state.pendingApproval != null ? ChatRunStatus.awaitingApproval : ChatRunStatus.runningTools,
        ));
      case ToolCallStarted(:final call):
        _background
          ?..update(phase: RunActivityPhase.usingTool)
          ..markLong();
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
        final notices = _withNotice(state.notices, runNoticeFor(code, message));
        if (!identical(notices, state.notices)) _flush(base: state.copyWith(notices: notices));
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
      final sample = draft.perf;
      final perf = sample == null ? null : ReplyPerf.fromSample(sample);
      final hints = <String, Object?>{
        // "Thought for Ns" survives reopening the chat.
        if (thought != null && m.content.any((p) => p is ReasoningPart)) 'reasoningMs': thought.inMilliseconds,
        // "42 tok/s · TTFT 0.4 s" under a local reply.
        if (perf != null && !perf.isEmpty) kReplyPerfKey: perf.toJson(),
      };
      if (hints.isNotEmpty) {
        // Client-only hints (providers never see message metadata). The
        // runner never rewrites a message after completing it.
        m = m.copyWith(metadata: {...m.metadata, ...hints});
        final hinted = m;
        // A display hint: losing it is not worth an error card.
        unawaited(_quiet(() => _store.putMessage(sessionId, hinted)));
      }
    }
    if (_applyMessage(m) && draft != null) _draft = null;
    _flush(base: state.copyWith(items: _buildItems()));
  }

  Future<void> _finishRun(RunFinished e) async {
    if (_finishing) return;
    _finishing = true;
    _draft?.finish(_clock.now());
    _denyRunApprovals();
    for (final p in _touchedParents) {
      _siblings.remove(p);
    }
    try {
      await _reloadPath(force: true, finishing: true);
    } on Object {
      // Keep what we have; the next open re-reads the store.
    }
    if (_disposed) {
      _endBackground(e.outcome);
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
    final notices = [...state.notices.where((n) => !_isProgressNotice(n))];
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
        if (_pausedForBackground || e.detail == kBackgroundPauseReason) {
          // Checkpointed by the runner; Continue picks it up again.
          notices.add(backgroundPausedNotice());
        } else if (!(e.detail ?? '').startsWith('discarded')) {
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
        _recordError(e.error);
        // A failed run left a reply (or a request) to retry from.
        error = _bindRetry(chatErrorFrom(e.error, outcome: e.outcome, detail: e.detail, model: state.model), retryLast);
    }
    final items = _buildItems();
    _flush(base: state.copyWith(
      status: status,
      lastOutcome: e.outcome,
      error: error,
      notices: notices,
      // The run's own requests were denied; an app's may still wait.
      pendingApproval: _approvals.current,
      pendingUserText: null,
      draft: null,
      items: items,
      historyCount: math.min(state.historyCount, items.length),
    ));
    if (_runnerStale) {
      _runner = null;
      _runnerChoice = null;
      _runnerProvider = null;
      _runnerStale = false;
    }
    _endBackground(e.outcome);
    _completeRun();
  }

  // ---------------------------------------------------------------------------
  // Background execution

  /// Registers the run that starts now with [RunActivity] (the app is
  /// visible: the user just acted), under the title the chat will have.
  void _registerBackground({required bool long}) {
    _background?.end(RunOutcome.cancelled); // a stale one, never expected
    _pausedForBackground = false;
    try {
      _background = _activity.start(
        sessionId: sessionId,
        title: expectedChatTitle(state.title, _pendingUser),
        providerId: _runnerChoice?.providerId ?? state.model?.providerId ?? '',
        long: long,
        onExpired: _onBackgroundTimeEnded,
      );
    } on Object catch (e) {
      // Background execution is best effort; the run goes on regardless.
      debugPrint('chat[$sessionId] (background): ${e.runtimeType}');
      _background = null;
    }
  }

  /// The OS ended Sherpa's background time before the run did: stop it the
  /// way Stop does (the runner checkpoints the cancelled run and keeps the
  /// partial reply), but say why and offer Continue.
  void _onBackgroundTimeEnded(String why) {
    if (_disposed || !_runActive || _finishing) return;
    debugPrint('chat[$sessionId]: background time ended ($why); pausing the run');
    _pausedForBackground = true;
    _stopping = true;
    _runner?.cancel(kBackgroundPauseReason);
    _denyRunApprovals();
  }

  void _endBackground(RunOutcome outcome) {
    final run = _background;
    _background = null;
    run?.end(outcome);
  }

  /// Keeps the error's type and code (never its message) for diagnostics.
  void _recordError(Object? error) {
    if (error == null || error is CancelledException || error is ChatSetupException) return;
    _errors.record(error, source: 'chat');
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
      // An app's own call is not in the transcript: no tool card to update.
      if (!pending.isFromApp) {
        _liveTools[pending.call.id] = _toolView(pending.call, ToolRunStatus.awaitingApproval, def: pending.tool);
        _invalidateTools();
      }
      unawaited(_platform.haptic(ChatHaptic.approvalRequested));
    }
    final running = _runActive && !_finishing && !_stopping;
    // An app's request neither starts nor pauses a run: the composer stays
    // usable while it waits.
    final status = pending != null && !pending.isFromApp
        ? ChatRunStatus.awaitingApproval
        : (running && state.status == ChatRunStatus.awaitingApproval ? ChatRunStatus.runningTools : state.status);
    _flush(base: state.copyWith(pendingApproval: pending, status: status));
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
      unawaited(_guarded(_reloadPath, failed: 'refresh the conversation'));
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
    _background?.title = session.title;
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

  ToolExecutionView _toolView(ToolCall call, ToolRunStatus status, {ToolDefinition? def}) {
    def ??= _router.lookup(call.name);
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

  /// Shows [error]. Its "Try again" repeats [again], the operation that
  /// failed; without one the card offers no retry.
  void _showError(ChatError error, {Future<void> Function()? again}) =>
      _commit(state.copyWith(error: _bindRetry(error, again)));

  /// Binds [error]'s retry action to [again] (see [retryError]); drops the
  /// action when nothing can be retried, so "Try again" never means
  /// "regenerate the last reply" for something that wasn't a run.
  ChatError _bindRetry(ChatError error, Future<void> Function()? again) {
    final offers = error.actions.contains(ChatErrorAction.retry);
    final bound = offers && again == null
        ? error.withActions([for (final a in error.actions) if (a != ChatErrorAction.retry) a])
        : error;
    _retry = offers && again != null ? (error: bound, again: again) : null;
    return bound;
  }

  /// Adds [notice] (replacing one with the same code). Notices the user
  /// dismissed stay dismissed when the runner repeats them, and one tool
  /// call cut off by the length limit is reported once, not by both the
  /// provider and the runner.
  List<ChatNotice> _withNotice(List<ChatNotice> notices, ChatNotice notice) {
    if (_dismissedNotices.contains(notice.code)) return notices;
    if (notice.code == 'tool_args_truncated' && notices.any((n) => n.code == 'tool_call_truncated')) return notices;
    return [
      ...notices.where((n) =>
          n.code != notice.code && !(notice.code == 'tool_call_truncated' && n.code == 'tool_args_truncated')),
      notice,
    ];
  }

  static bool _isProgressNotice(ChatNotice n) => n.code == 'retrying' || n.code == kWaitingForForegroundNotice;

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

  /// Best-effort work whose failure must not surface as an error.
  Future<void> _quiet(Future<void> Function() body) async {
    try {
      await body();
    } on Object catch (e) {
      if (!_disposed) debugPrint('chat[$sessionId] (ignored): $e');
    }
  }

  /// Runs [body], an action that is not a run; a failure becomes a visible
  /// error ("Couldn't [failed]") whose "Try again" runs [body] again.
  Future<void> _guarded(Future<void> Function() body, {required String failed}) async {
    try {
      await body();
    } on Object catch (e, st) {
      _recordError(e);
      if (_disposed) return;
      debugPrint('chat[$sessionId]: $e\n$st');
      _showError(
        actionErrorFrom(e, failed: failed, model: state.model),
        again: () => _guarded(body, failed: failed),
      );
    }
  }

  void _dispose() {
    _disposed = true;
    _approvals.denyAll();
    _runner?.cancel('chat closed');
    _endBackground(RunOutcome.cancelled);
    unawaited(_runSub?.cancel());
    unawaited(_registrySub?.cancel());
    unawaited(_prefsSub?.cancel());
    final done = _runDone;
    if (done != null && !done.isCompleted) done.complete();
  }
}
