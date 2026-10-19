import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../design/tokens.dart';
import '../../../design/widgets/a11y.dart';
import '../state/chat_controller.dart';
import '../state/chat_errors.dart';
import '../state/chat_view_state.dart';
import '../state/transcript_model.dart';
import 'assistant_turn.dart';
import 'chat_notices.dart';
import 'chat_style.dart';
import 'user_message.dart';

/// Pinned/Detached follow state for the transcript.
///
/// Pinned: new content keeps the newest line in view. Any user drag, fling
/// or wheel detaches; ending a scroll within [repinDistance] of the bottom
/// (or tapping "jump to latest") pins again.
class FollowController extends ChangeNotifier {
  FollowController({this.repinDistance = 48});

  final double repinDistance;
  bool _pinned = true;
  bool _unread = false;
  double _extentAfter = 0;

  bool get pinned => _pinned;

  /// New content arrived below while detached.
  bool get unread => _unread;
  bool get showJump => !_pinned && _extentAfter > repinDistance;

  void detach() {
    if (!_pinned) return;
    _pinned = false;
    notifyListeners();
  }

  void pin() {
    if (_pinned && !_unread) return;
    _pinned = true;
    _unread = false;
    notifyListeners();
  }

  void markUnread() {
    if (_pinned || _unread) return;
    _unread = true;
    notifyListeners();
  }

  void updateExtentAfter(double v) {
    final before = showJump;
    _extentAfter = v;
    if (before != showJump) notifyListeners();
  }
}

/// Keeps the scroll offset glued to the end while [FollowController.pinned]
/// and nobody is scrolling.
///
/// It works inside layout (via [adjustPositionForNewDimensions]), so a
/// growing reply never shows one frame of lag or a jump; when detached the
/// default behaviour applies, and since live content grows below the
/// center key, what the reader is looking at doesn't move.
class FollowScrollPhysics extends ScrollPhysics {
  const FollowScrollPhysics({required this.follow, super.parent});

  final FollowController follow;

  @override
  FollowScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      FollowScrollPhysics(follow: follow, parent: buildParent(ancestor));

  @override
  double adjustPositionForNewDimensions({
    required ScrollMetrics oldPosition,
    required ScrollMetrics newPosition,
    required bool isScrolling,
    required double velocity,
  }) {
    final adjusted = super.adjustPositionForNewDimensions(
      oldPosition: oldPosition,
      newPosition: newPosition,
      isScrolling: isScrolling,
      velocity: velocity,
    );
    if (follow.pinned && !isScrolling) return newPosition.maxScrollExtent;
    return adjusted;
  }
}

/// Run state for tiles that are cached across rebuilds: they read it here
/// (and rebuild only when it flips) instead of taking it as a parameter.
class ChatRunScope extends InheritedWidget {
  const ChatRunScope({super.key, required this.running, required super.child});

  final bool running;

  static bool runningOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ChatRunScope>()?.running ?? false;

  @override
  bool updateShouldNotify(ChatRunScope oldWidget) => oldWidget.running != running;
}

/// One turn of the conversation for screen readers: who speaks it ("You",
/// "Sherpa") as a level-2 heading, so heading navigation steps from turn to
/// turn, carrying the turn's own actions (copy, edit, retry).
///
/// The message, its chips and its buttons stay separate nodes under the
/// heading (`explicitChildNodes`), read after the speaker, never merged
/// into it.
class TurnHeading extends StatelessWidget {
  const TurnHeading({super.key, required this.speaker, this.actions, required this.child});

  final String speaker;
  final Map<CustomSemanticsAction, VoidCallback>? actions;
  final Widget child;

  @override
  Widget build(BuildContext context) => Heading(
        child: Semantics(label: speaker, explicitChildNodes: true, customSemanticsActions: actions, child: child),
      );
}

/// The conversation.
///
/// A `CustomScrollView` with a center key and `anchor: 1`: history renders
/// above the center and grows upward, the live part renders below it and
/// grows downward. Streaming therefore never shifts what a reader scrolled
/// up to, and following the bottom is a layout-time correction rather than
/// a per-frame `jumpTo` (docs/research/12 §1.10, design B).
///
/// Finished tiles are cached by item identity: the controller reuses item
/// instances while a message is unchanged, so a streaming frame rebuilds
/// only the live draft, never a finished message.
class ChatTranscript extends ConsumerStatefulWidget {
  const ChatTranscript({
    super.key,
    required this.sessionId,
    required this.userCallbacks,
    required this.turnCallbacks,
    required this.onNoticeAction,
    required this.onErrorAction,
    required this.emptyState,
  });

  final String sessionId;
  final UserMessageCallbacks userCallbacks;
  final AssistantTurnCallbacks turnCallbacks;
  final void Function(ChatNoticeAction action) onNoticeAction;
  final void Function(ChatErrorAction action) onErrorAction;
  final Widget emptyState;

  @override
  ConsumerState<ChatTranscript> createState() => ChatTranscriptState();
}

class ChatTranscriptState extends ConsumerState<ChatTranscript> {
  static const Key _centerKey = ValueKey('chat-live-center');

  final ScrollController _scroll = ScrollController();
  final FollowController _follow = FollowController();
  Map<ChatItem, Widget> _cache = HashMap.identity();

  /// Exposed for tests and the screen's keyboard shortcuts.
  FollowController get follow => _follow;
  ScrollController get scrollController => _scroll;

  @override
  void initState() {
    super.initState();
    // The very first layout of a scroll position never goes through
    // adjustPositionForNewDimensions; if the chat is opened mid-run (live
    // items below the center), pin to the end once laid out.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _follow.pinned && _scroll.hasClients) {
        _scroll.position.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    _follow.dispose();
    super.dispose();
  }

  Widget _tile(ChatItem item) {
    final cached = _cache[item];
    if (cached != null) return cached;
    return _cache[item] = switch (item) {
      UserItem() => UserMessageTile(
          key: ValueKey(item.key),
          item: item,
          callbacks: widget.userCallbacks,
        ),
      PendingUserItem() => PendingUserTile(key: ValueKey(item.key), text: item.text),
      AssistantTurnItem() => AssistantTurnTile(
          key: ValueKey(item.key),
          sessionId: widget.sessionId,
          item: item,
          callbacks: widget.turnCallbacks,
        ),
    };
  }

  bool _onScroll(ScrollNotification n) {
    if (n.depth != 0 || n.metrics.axis != Axis.vertical) return false;
    if (n is UserScrollNotification && n.direction != ScrollDirection.idle) {
      _follow.detach();
    } else if (n is ScrollEndNotification && n.metrics.extentAfter <= _follow.repinDistance) {
      _follow.pin();
    }
    _follow.updateExtentAfter(n.metrics.extentAfter);
    return false;
  }

  bool _onMetrics(ScrollMetricsNotification n) {
    if (n.depth == 0) _follow.updateExtentAfter(n.metrics.extentAfter);
    return false;
  }

  /// Animates to the newest content and pins there.
  Future<void> jumpToLatest() async {
    if (!_scroll.hasClients) return;
    final p = _scroll.position;
    _follow.pin();
    final motion = chatMotionOf(context);
    if (motion.reduced) {
      p.jumpTo(p.maxScrollExtent);
    } else {
      await p.animateTo(p.maxScrollExtent, duration: motion.slow, curve: motion.emphasized);
      // Content may have grown during the animation.
      if (mounted && _follow.pinned && _scroll.hasClients) p.jumpTo(p.maxScrollExtent);
    }
  }

  void _handleScrollRequest(ChatScrollKind kind) {
    if (!mounted || !_scroll.hasClients) return;
    final p = _scroll.position;
    switch (kind) {
      case ChatScrollKind.bottom:
        _follow.pin();
        p.jumpTo(p.maxScrollExtent);
      case ChatScrollKind.revealLive:
        // With anchor 1 the center sits at the viewport's bottom edge when
        // pixels == 0, so pixels == viewport height puts the start of the
        // live region (the branch the user picked) at the top.
        final target = math.max(p.minScrollExtent, math.min(p.maxScrollExtent, p.viewportDimension));
        p.jumpTo(target);
        if (target >= p.maxScrollExtent - 0.5) {
          _follow.pin();
        } else {
          _follow.detach();
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = chatControllerProvider(widget.sessionId);
    final (items, historyCount, notices, error, loading, running) = ref.watch(
      provider.select((s) => (s.items, s.historyCount, s.notices, s.error, s.loading, s.isRunActive)),
    );
    ref.listen(provider.select((s) => s.scrollRequest), (prev, next) {
      if (next == null || next.id == prev?.id) return;
      WidgetsBinding.instance.addPostFrameCallback((_) => _handleScrollRequest(next.kind));
    });
    ref.listen(provider.select((s) => (s.items, s.draft?.contentLength ?? 0)), (_, _) => _follow.markUnread());

    final tokens = SherpaTokens.of(context);
    // The scroll view always exists (the empty state is an overlay): a
    // position that already has dimensions pins to the first message in
    // the same layout pass instead of starting below it.
    final empty = !loading && items.isEmpty && notices.isEmpty && error == null;

    // Rebuild the identity cache from the current items so it never grows.
    final previous = _cache;
    _cache = HashMap.identity();
    for (final item in items) {
      final w = previous[item];
      if (w != null) _cache[item] = w;
    }

    final split = historyCount.clamp(0, items.length);
    final history = items.sublist(0, split);
    final liveItems = items.sublist(split);
    final live = <Widget>[
      for (final item in liveItems) _tile(item),
      for (final n in notices)
        NoticeTile(
          key: ValueKey('notice:${n.code}'),
          notice: n,
          onAction: widget.onNoticeAction,
          onDismiss: n.dismissible ? () => ref.read(provider.notifier).dismissNotice(n.code) : null,
        ),
      if (error != null)
        ChatErrorCard(
          key: const ValueKey('error'),
          error: error,
          onAction: widget.onErrorAction,
          onDismiss: () => ref.read(provider.notifier).dismissError(),
        ),
    ];
    final historyIndex = {for (final (i, item) in history.indexed) item.key: history.length - 1 - i};
    final liveIndex = {for (final (i, w) in live.indexed) (w.key! as ValueKey<String>).value: i};

    return ChatRunScope(
      running: running,
      child: NotificationListener<ScrollMetricsNotification>(
        onNotification: _onMetrics,
        child: NotificationListener<ScrollNotification>(
          onNotification: _onScroll,
          child: Stack(
            children: [
              // Its own group, unlabelled: each turn is named by its heading
              // ("You", "Sherpa"), and a label here would be read before
              // the first of them (and again on every way back in).
              Semantics(
                container: true,
                explicitChildNodes: true,
                child: CustomScrollView(
                  controller: _scroll,
                  center: _centerKey,
                  anchor: 1,
                  physics: FollowScrollPhysics(follow: _follow),
                  scrollCacheExtent: const ScrollCacheExtent.viewport(1),
                  keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                  slivers: [
                    SliverToBoxAdapter(child: SizedBox(height: tokens.space.lg)),
                    SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (context, i) => _tile(history[history.length - 1 - i]),
                        childCount: history.length,
                        addRepaintBoundaries: false,
                        findChildIndexCallback: (key) => key is ValueKey<String> ? historyIndex[key.value] : null,
                      ),
                    ),
                    SliverList(
                      key: _centerKey,
                      delegate: SliverChildBuilderDelegate(
                        (context, i) => live[i],
                        childCount: live.length,
                        addRepaintBoundaries: false,
                        findChildIndexCallback: (key) => key is ValueKey<String> ? liveIndex[key.value] : null,
                      ),
                    ),
                    SliverToBoxAdapter(child: SizedBox(height: tokens.space.lg)),
                  ],
                ),
              ),
              if (empty) Positioned.fill(child: widget.emptyState),
              PositionedDirectional(
                end: tokens.space.lg,
                bottom: tokens.space.md,
                child: JumpToLatestButton(follow: _follow, onPressed: jumpToLatest),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Floating "jump to latest" with a dot when new content arrived.
class JumpToLatestButton extends StatelessWidget {
  const JumpToLatestButton({super.key, required this.follow, required this.onPressed});

  final FollowController follow;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final motion = chatMotionOf(context);
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: follow,
      builder: (context, _) {
        final visible = follow.showJump;
        return IgnorePointer(
          ignoring: !visible,
          child: ExcludeSemantics(
            excluding: !visible,
            child: AnimatedScale(
              scale: visible ? 1 : 0.6,
              duration: motion.fast,
              curve: motion.standard,
              child: AnimatedOpacity(
                opacity: visible ? 1 : 0,
                duration: motion.fast,
                child: Semantics(
                  container: true,
                  button: true,
                  label: follow.unread ? 'Jump to latest, new messages below' : 'Jump to latest',
                  // While hidden the whole button is out of the semantics
                  // tree (ExcludeSemantics above), so the action can stay.
                  onTap: onPressed,
                  excludeSemantics: true,
                  child: Badge(
                    isLabelVisible: follow.unread,
                    smallSize: SherpaTokens.of(context).space.sm,
                    backgroundColor: theme.colorScheme.primary,
                    child: IconButton.filledTonal(
                      key: const ValueKey('jump-to-latest'),
                      tooltip: 'Jump to latest',
                      onPressed: onPressed,
                      icon: const Icon(Icons.arrow_downward_rounded),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
