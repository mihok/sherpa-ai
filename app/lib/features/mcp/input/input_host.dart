import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../design/tokens.dart';
import '../../../services/mcp/input/input_queue.dart';
import '../state/input_providers.dart';
import 'input_sheets.dart';

/// Surfaces MCP input requests app-wide: a slim banner above every screen
/// while any request waits ("`Server` asks you to fill in a form ·
/// Review"), snackbars for requests Sherpa refused on the user's behalf,
/// and the sampling driver (approved requests run even with their sheet
/// closed).
///
/// Sheets never pop up on their own: a request opens only when the user
/// taps Review (here, or on a chat's inline card), so a server cannot slip
/// a dialog under a tap meant for something else. Requests that arrive
/// while the app is in the background simply wait (and time out with a
/// polite decline if nobody answers).
///
/// Place it in `MaterialApp.builder` (like the offline banner) and pass
/// the router's root [navigatorKey] so the sheets have a Navigator; without
/// one it looks for the first Navigator below it.
class McpInputHost extends ConsumerStatefulWidget {
  const McpInputHost({super.key, required this.child, this.navigatorKey});

  final Widget child;
  final GlobalKey<NavigatorState>? navigatorKey;

  @override
  ConsumerState<McpInputHost> createState() => _McpInputHostState();
}

class _McpInputHostState extends ConsumerState<McpInputHost> {
  StreamSubscription<McpInputNotice>? _notices;
  McpInputQueue? _queue;

  @override
  void initState() {
    super.initState();
    ref.listenManual(mcpInputQueueProvider, (_, q) => _listenNotices(q), fireImmediately: true);
  }

  @override
  void dispose() {
    unawaited(_notices?.cancel());
    super.dispose();
  }

  void _listenNotices(McpInputQueue? q) {
    if (identical(q, _queue)) return;
    _queue = q;
    unawaited(_notices?.cancel());
    _notices = q?.notices.listen((n) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(_navigatorContext() ?? context)?.showSnackBar(
        SnackBar(content: Text(n.message), duration: const Duration(seconds: 8)),
      );
    });
  }

  BuildContext? _navigatorContext() {
    final keyed = widget.navigatorKey?.currentContext;
    if (keyed != null) return keyed;
    if (Navigator.maybeOf(context) != null) return context;
    NavigatorState? found;
    void visit(Element e) {
      if (found != null) return;
      if (e is StatefulElement && e.state is NavigatorState) {
        found = e.state as NavigatorState;
        return;
      }
      e.visitChildElements(visit);
    }

    context.visitChildElements(visit);
    return found?.context;
  }

  /// The request whose sheet is open (Review never stacks a second one).
  String? _open;

  Future<void> _review(McpPendingInput p) async {
    final ctx = _navigatorContext();
    if (ctx == null || _open != null) return;
    _open = p.id;
    try {
      await showMcpInputSheet(ctx, p);
    } finally {
      _open = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(mcpSamplingDriverProvider);
    final pending = ref.watch(mcpPendingInputsProvider).value ?? const <McpPendingInput>[];
    final motion = SherpaTokens.maybeOf(context)?.motion;
    final show = pending.isNotEmpty;
    return Column(
      children: [
        AnimatedSize(
          duration: motion?.medium ?? const Duration(milliseconds: 250),
          curve: motion?.standard ?? Curves.easeOut,
          alignment: Alignment.topCenter,
          child: show
              ? McpInputBanner(pending: pending, onReview: () => unawaited(_review(pending.first)))
              : const SizedBox(width: double.infinity),
        ),
        Expanded(child: MediaQuery.removePadding(context: context, removeTop: show, child: widget.child)),
      ],
    );
  }
}

/// The banner: the oldest request and how many more wait.
class McpInputBanner extends StatelessWidget {
  const McpInputBanner({super.key, required this.pending, required this.onReview});

  final List<McpPendingInput> pending;
  final VoidCallback onReview;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.maybeOf(context);
    final scheme = Theme.of(context).colorScheme;
    final first = pending.first;
    final more = pending.length - 1;
    final text = '${first.serverName} ${_ready(first) ?? first.summary}${more > 0 ? ' · $more more' : ''}';
    final style = Theme.of(context).textTheme.labelLarge?.copyWith(color: scheme.onPrimaryContainer);
    return Material(
      color: scheme.primaryContainer,
      child: SafeArea(
        bottom: false,
        child: Semantics(
          liveRegion: true,
          container: true,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: t?.space.lg ?? 16, vertical: t?.space.xxs ?? 2),
            child: Row(
              children: [
                Icon(Icons.pending_actions_rounded, size: 18, color: scheme.onPrimaryContainer),
                SizedBox(width: t?.space.sm ?? 8),
                Expanded(child: Text(text, style: style, maxLines: 2, overflow: TextOverflow.ellipsis)),
                TextButton(onPressed: onReview, child: const Text('Review')),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String? _ready(McpPendingInput p) =>
      p is PendingSampling && p.stage == SamplingStage.review ? 'has an answer ready for your review' : null;
}

/// Inline cards for one chat's pending requests (the chat shows them in
/// its transcript or above the composer). Each opens its sheet.
class McpPendingInputsInline extends ConsumerWidget {
  const McpPendingInputsInline({super.key, required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = ref.watch(mcpPendingInputsForSessionProvider(sessionId));
    if (pending.isEmpty) return const SizedBox.shrink();
    final t = SherpaTokens.maybeOf(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final p in pending)
          Padding(
            padding: EdgeInsets.only(bottom: t?.space.sm ?? 8),
            child: McpPendingInputCard(input: p),
          ),
      ],
    );
  }
}

/// One pending request: who asks, for what, and Review.
class McpPendingInputCard extends StatelessWidget {
  const McpPendingInputCard({super.key, required this.input});

  final McpPendingInput input;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.maybeOf(context);
    final theme = Theme.of(context);
    final icon = switch (input) {
      PendingFormElicitation() => Icons.edit_note_rounded,
      PendingUrlElicitation() => Icons.open_in_browser_rounded,
      PendingSampling() => Icons.psychology_alt_outlined,
    };
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: EdgeInsets.all(t?.space.md ?? 12),
        child: Row(
          children: [
            Icon(icon, color: theme.colorScheme.primary),
            SizedBox(width: t?.space.md ?? 12),
            Expanded(
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(text: input.serverName, style: const TextStyle(fontWeight: FontWeight.w700)),
                  TextSpan(text: ' ${McpInputBanner._ready(input) ?? input.summary}'),
                ]),
                style: theme.textTheme.bodyMedium,
              ),
            ),
            FilledButton.tonal(onPressed: () => unawaited(showMcpInputSheet(context, input)), child: const Text('Review')),
          ],
        ),
      ),
    );
  }
}
