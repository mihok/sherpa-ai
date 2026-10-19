import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../design/tokens.dart';
import '../../design/widgets/privacy_badge.dart';
import 'model_picker_sheet.dart';
import 'state/chat_controller.dart';
import 'state/chat_dependencies.dart';
import 'state/chat_errors.dart';
import 'state/chat_view_state.dart';
import 'state/model_selection.dart';
import 'state/transcript_model.dart';
import 'widgets/approval_card.dart';
import 'widgets/assistant_turn.dart';
import 'widgets/chat_notices.dart';
import 'widgets/chat_style.dart';
import 'widgets/composer.dart';
import 'widgets/context_ring.dart';
import 'widgets/model_chip.dart';
import 'widgets/transcript.dart';
import 'widgets/turn_status.dart';
import 'widgets/user_message.dart';

/// Below this width the approval opens as a modal sheet (focus + route
/// semantics); at or above it the card docks above the composer.
const double kCompactApprovalBreakpoint = 600;

/// One conversation: transcript, approvals, composer.
///
/// The screen is thin: all behaviour lives in [ChatController]; this widget
/// maps user intent to controller calls and navigation. Leaving the screen
/// never stops a run (the controller keeps itself alive until it ends).
class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key, required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final TextEditingController _text = TextEditingController();
  final FocusNode _composerFocus = FocusNode(debugLabel: 'composer');
  final GlobalKey<ChatTranscriptState> _transcript = GlobalKey();
  String? _editingId;
  String? _sheetFor;

  // Created once so cached transcript tiles keep valid callbacks.
  late final UserMessageCallbacks _userCallbacks = UserMessageCallbacks(
    onEdit: _startEdit,
    onCopy: (item) => _copy(item.message.id),
    onSwitch: (item, forward) => _controller.switchBranch(
      item.message.id,
      forward ? BranchDirection.next : BranchDirection.previous,
    ),
  );

  late final AssistantTurnCallbacks _turnCallbacks = AssistantTurnCallbacks(
    onCopy: (item) => _copy(item.steps.isEmpty ? '' : item.steps.last.id),
    onShare: (item) => item.steps.isEmpty ? null : _controller.share(item.steps.last.id),
    onRetry: (item) => item.firstMessageId == null ? null : _controller.retry(item.firstMessageId!),
    onSwitch: (item, forward) => item.firstMessageId == null
        ? null
        : _controller.switchBranch(item.firstMessageId!, forward ? BranchDirection.next : BranchDirection.previous),
    onLinkTap: _openLink,
    onCopyCode: (_) => _toast('Code copied'),
  );

  ChatController get _controller => ref.read(chatControllerProvider(widget.sessionId).notifier);

  ChatRoutes get _routes => ref.read(chatRoutesProvider);

  @override
  void dispose() {
    _text.dispose();
    _composerFocus.dispose();
    super.dispose();
  }

  bool get _compact => MediaQuery.sizeOf(context).width < kCompactApprovalBreakpoint;

  // ---------------------------------------------------------------------------
  // Intents

  void _send(String text) {
    final editing = _editingId;
    if (editing != null) {
      unawaited(_controller.edit(editing, text));
      setState(() => _editingId = null);
    } else {
      unawaited(_controller.send(text));
    }
    _text.clear();
  }

  void _startEdit(UserItem item) {
    if (_controller.isRunning) return;
    setState(() => _editingId = item.message.id);
    _text.value = TextEditingValue(
      text: item.text,
      selection: TextSelection.collapsed(offset: item.text.length),
    );
    _composerFocus.requestFocus();
  }

  void _cancelEdit() {
    setState(() => _editingId = null);
    _text.clear();
  }

  void _editLast() {
    final items = ref.read(chatControllerProvider(widget.sessionId)).items;
    final last = items.whereType<UserItem>().lastOrNull;
    if (last != null) _startEdit(last);
  }

  Future<void> _copy(String messageId) async {
    if (await _controller.copy(messageId)) _toast('Copied');
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 2)));
  }

  Future<void> _pickModel() async {
    final current = ref.read(chatControllerProvider(widget.sessionId)).model?.choice;
    final choice = await ModelPickerSheet.show(context, current: current);
    if (choice != null && mounted) await _controller.changeModel(choice);
  }

  Future<void> _newChat() async {
    final id = await _controller.startNewChat();
    if (id == null || !mounted) return;
    unawaited(GoRouter.maybeOf(context)?.pushReplacement(_routes.chat(id)));
  }

  void _push(String location) => unawaited(GoRouter.maybeOf(context)?.push(location));

  void _onErrorAction(ChatErrorAction action) {
    final s = ref.read(chatControllerProvider(widget.sessionId));
    switch (action) {
      case ChatErrorAction.fixProvider:
        final id = s.error?.providerId ?? s.model?.providerId;
        _push(id == null ? _routes.newProvider : _routes.editProvider(id));
      case ChatErrorAction.addProvider:
        _push(_routes.newProvider);
      case ChatErrorAction.retry:
        // Repeats what failed (the run, or the share/switch/send that threw).
        unawaited(_controller.retryError());
      case ChatErrorAction.changeModel:
        unawaited(_pickModel());
      case ChatErrorAction.newChat:
        unawaited(_newChat());
    }
  }

  void _onOverflow(_ChatMenu item) => switch (item) {
        _ChatMenu.context => _push(_routes.context(widget.sessionId)),
        _ChatMenu.compact => unawaited(_compactNow()),
        _ChatMenu.handoff => _push(_routes.handoff(widget.sessionId)),
      };

  /// "Compact now": summarizes older turns right away and says what it did,
  /// with an Undo (the transcript is untouched; undo deletes the overlay).
  Future<void> _compactNow() async {
    try {
      final outcome = await _controller.compactNow();
      if (!mounted || outcome == null) return;
      final overlay = outcome.overlay;
      if (overlay == null) {
        _toast('Nothing to summarize yet: ${outcome.skippedReason ?? 'the chat is short'}.');
        return;
      }
      ScaffoldMessenger.maybeOf(context)
        ?..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text('Summarized earlier messages, freed ${formatTokenCount(overlay.tokensSaved)} tokens.'),
          persist: false,
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () => unawaited(_controller.undoContextChange(overlay.id).catchError((Object _) => null)),
          ),
        ));
    } on StateError catch (e) {
      _toast("Couldn't summarize: ${e.message}.");
    } on Object {
      _toast("Couldn't summarize the conversation. Try again.");
    }
  }

  void _onNoticeAction(ChatNoticeAction action) => switch (action) {
        ChatNoticeAction.continueRun => unawaited(_controller.continueRun()),
        ChatNoticeAction.handOff => _push(_routes.handoff(widget.sessionId)),
      };

  void _onCommand(SlashCommand c) {
    switch (c.name) {
      case 'new':
        unawaited(_newChat());
      case 'retry':
        unawaited(_controller.retryLast());
      case 'model':
        unawaited(_pickModel());
    }
  }

  /// Links are never opened silently: the full URL is shown first
  /// (docs/research/11 §9.7, exfiltration via links).
  Future<void> _openLink(Uri uri) async {
    final tokens = SherpaTokens.of(context);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      builder: (sheet) => Padding(
        padding: EdgeInsets.fromLTRB(tokens.space.xl, 0, tokens.space.xl, tokens.space.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Link in the reply', style: Theme.of(sheet).textTheme.titleMedium),
            SizedBox(height: tokens.space.sm),
            SelectableText(uri.toString(), style: chatMonoStyle(sheet)),
            SizedBox(height: tokens.space.md),
            Text(
              'Check the address before opening it. Links in replies can come from web pages or tools.',
              style: Theme.of(sheet).textTheme.bodySmall,
            ),
            SizedBox(height: tokens.space.md),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: FilledButton.tonalIcon(
                onPressed: () {
                  unawaited(ref.read(chatPlatformProvider).copyText(uri.toString()));
                  Navigator.of(sheet).pop();
                  _toast('Link copied');
                },
                icon: const Icon(Icons.copy_rounded),
                label: const Text('Copy link'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _maybeShowApprovalSheet(PendingApproval? pending) {
    if (pending == null || !_compact || _sheetFor != null) return;
    setState(() => _sheetFor = pending.call.id);
    unawaited(ApprovalSheet.show(context, widget.sessionId).whenComplete(() {
      if (mounted) setState(() => _sheetFor = null);
    }));
  }

  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final provider = chatControllerProvider(widget.sessionId);
    final (title, model, availability, running, loading) =
        ref.watch(provider.select((s) => (s.title, s.model, s.availability, s.isRunActive, s.loading)));
    final (budget, level, estimate) = ref.watch(provider.select((s) => (s.budget, s.contextLevel, s.budgetIsEstimate)));
    final (pending, interrupted, hasItems) =
        ref.watch(provider.select((s) => (s.pendingApproval, s.interrupted, s.items.isNotEmpty)));
    ref.listen(provider.select((s) => s.pendingApproval), (prev, next) {
      if (next != null && next.call.id != prev?.call.id) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _maybeShowApprovalSheet(ref.read(provider).pendingApproval);
        });
      }
    });

    final tokens = SherpaTokens.of(context);
    final width = MediaQuery.sizeOf(context).width;
    final ready = availability == ProviderAvailability.ready || availability == ProviderAvailability.loading;

    final commands = [
      const SlashCommand(name: 'new', description: 'Start a new chat', icon: Icons.edit_square),
      SlashCommand(
        name: 'retry',
        description: 'Regenerate the last reply',
        icon: Icons.refresh_rounded,
        enabled: !running && hasItems,
      ),
      const SlashCommand(name: 'model', description: 'Switch model', icon: Icons.swap_horiz_rounded),
    ];

    final dock = <Widget>[
      if (interrupted != null && !running)
        InterruptedBanner(
          run: interrupted,
          onResume: () => unawaited(_controller.resumeIfInterrupted()),
          onDiscard: () => unawaited(_controller.discardInterrupted()),
        ),
      if (pending != null)
        _compact
            ? (_sheetFor == null
                ? ApprovalReminderBar(approval: pending, onReview: () => _maybeShowApprovalSheet(pending))
                : const SizedBox.shrink())
            : DockedApprovalCard(sessionId: widget.sessionId, approval: pending),
      if (ready)
        ChatComposer(
          controller: _text,
          focusNode: _composerFocus,
          running: running,
          canSend: !loading && availability == ProviderAvailability.ready,
          onSend: _send,
          onStop: _controller.stop,
          commands: commands,
          onCommand: _onCommand,
          hintText: model == null ? 'Message' : 'Message ${model.modelName}',
          editing: _editingId == null ? null : ComposerEditing(onCancel: _cancelEdit),
          onEditLast: _editLast,
        )
      else
        SetupPanel(
          availability: availability,
          providerName: model?.providerName,
          onAddProvider: () => _push(_routes.newProvider),
          onChooseModel: () => unawaited(_pickModel()),
        ),
    ];

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, control: true): () {
          if (_text.text.trim().isNotEmpty && !running) _send(_text.text);
        },
        const SingleActivator(LogicalKeyboardKey.enter, meta: true): () {
          if (_text.text.trim().isNotEmpty && !running) _send(_text.text);
        },
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (running) _controller.stop();
        },
        const SingleActivator(LogicalKeyboardKey.slash, control: true): () => unawaited(_pickModel()),
        const SingleActivator(LogicalKeyboardKey.slash, meta: true): () => unawaited(_pickModel()),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          appBar: PreferredSize(
            preferredSize: const Size.fromHeight(kToolbarHeight),
            child: MediaQuery.withClampedTextScaling(
              maxScaleFactor: kChromeMaxTextScale,
              child: AppBar(
                title: Semantics(
                  headingLevel: 1,
                  child: Text(title.isEmpty ? 'New chat' : title, maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
                actions: [
                  ModelChip(selection: model, onTap: () => unawaited(_pickModel()), maxWidth: width * 0.45),
                  ContextRing(
                    budget: budget,
                    level: level,
                    estimate: estimate,
                    onTap: () => unawaited(ContextBudgetSheet.show(
                      context,
                      budget: budget,
                      level: level,
                      estimate: estimate,
                      modelName: model?.modelName,
                      lastChange: _controller.lastContextChange(),
                      onInspect: () => _push(_routes.context(widget.sessionId)),
                    )),
                  ),
                  _ChatOverflowMenu(
                    canCompact: !running && availability == ProviderAvailability.ready && hasItems,
                    canHandOff: hasItems,
                    onSelected: _onOverflow,
                  ),
                ],
              ),
            ),
          ),
          body: SafeArea(
            top: false,
            child: Column(
              children: [
                Expanded(
                  child: ChatTranscript(
                    key: _transcript,
                    sessionId: widget.sessionId,
                    userCallbacks: _userCallbacks,
                    turnCallbacks: _turnCallbacks,
                    onNoticeAction: _onNoticeAction,
                    onErrorAction: _onErrorAction,
                    emptyState: _EmptyChat(model: model, ready: availability == ProviderAvailability.ready),
                  ),
                ),
                TurnStatusAnnouncer(sessionId: widget.sessionId),
                ReadableWidth(
                  horizontalPadding: tokens.space.md,
                  child: Padding(
                    padding: EdgeInsets.only(bottom: tokens.space.sm),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final w in dock) Padding(padding: EdgeInsets.only(top: tokens.space.sm), child: w),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A new chat: a calm greeting plus where messages will go.
class _EmptyChat extends StatelessWidget {
  const _EmptyChat({required this.model, required this.ready});

  final ModelSelection? model;
  final bool ready;

  @override
  Widget build(BuildContext context) {
    final tokens = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final m = model;
    return Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.all(tokens.space.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.terrain_rounded, size: tokens.space.xxxl, color: theme.colorScheme.primary),
            SizedBox(height: tokens.space.lg),
            Semantics(
              headingLevel: 2,
              child: Text('What are we working on?', style: theme.textTheme.headlineSmall, textAlign: TextAlign.center),
            ),
            if (ready && m != null) ...[
              SizedBox(height: tokens.space.md),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(child: PrivacyBadge(location: m.location, host: m.host)),
                ],
              ),
              SizedBox(height: tokens.space.xs),
              Text(
                m.privacy.description,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

enum _ChatMenu { context, compact, handoff }

/// The app bar's overflow: context tools that are useful but not frequent
/// enough for their own buttons.
class _ChatOverflowMenu extends StatelessWidget {
  const _ChatOverflowMenu({required this.canCompact, required this.canHandOff, required this.onSelected});

  /// False while a reply is running (a rewrite would race it) or before
  /// there is a model and something to summarize.
  final bool canCompact;
  final bool canHandOff;
  final void Function(_ChatMenu item) onSelected;

  @override
  Widget build(BuildContext context) => PopupMenuButton<_ChatMenu>(
        tooltip: 'More',
        icon: const Icon(Icons.more_vert_rounded),
        onSelected: onSelected,
        itemBuilder: (_) => [
          const PopupMenuItem(
            value: _ChatMenu.context,
            child: ListTile(leading: Icon(Icons.manage_search_rounded), title: Text('Context details')),
          ),
          PopupMenuItem(
            value: _ChatMenu.compact,
            enabled: canCompact,
            child: const ListTile(leading: Icon(Icons.compress_rounded), title: Text('Compact now')),
          ),
          PopupMenuItem(
            value: _ChatMenu.handoff,
            enabled: canHandOff,
            child: const ListTile(leading: Icon(Icons.move_up_rounded), title: Text('Hand off…')),
          ),
        ],
      );
}
