import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../state/chat_controller.dart';
import '../state/chat_view_state.dart';

/// What the turn-status node says for [s]: phase transitions only, never
/// the streaming text.
String turnStatusLabel(ChatViewState s) {
  switch (s.status) {
    case ChatRunStatus.streaming:
      return 'Assistant is responding';
    case ChatRunStatus.runningTools:
      final tool = s.runningToolName;
      return tool == null ? 'Assistant is working' : 'Running $tool';
    case ChatRunStatus.awaitingApproval:
      return 'Waiting for your approval';
    case ChatRunStatus.cancelled:
      return 'Response stopped';
    case ChatRunStatus.error:
      return s.error == null ? 'Response failed' : 'Response failed: ${s.error!.title}';
    case ChatRunStatus.idle:
      return switch (s.lastOutcome) {
        RunOutcome.completed => 'Response complete',
        RunOutcome.maxSteps => 'Paused, waiting for you',
        _ => '',
      };
  }
}

/// The single live region of a chat (docs/research/12 §1.8).
///
/// Screen readers re-announce a live region's whole label on every change,
/// so this node carries only the turn *phase*, debounced to one change per
/// [debounce]: the first change is announced immediately, later ones within
/// the window collapse into the newest. It is a 1×1 node rather than
/// zero-sized because zero-area semantics nodes are dropped from the tree.
class TurnStatusAnnouncer extends ConsumerStatefulWidget {
  const TurnStatusAnnouncer({
    super.key,
    required this.sessionId,
    this.debounce = const Duration(milliseconds: 1500),
  });

  final String sessionId;
  final Duration debounce;

  @override
  ConsumerState<TurnStatusAnnouncer> createState() => _TurnStatusAnnouncerState();
}

class _TurnStatusAnnouncerState extends ConsumerState<TurnStatusAnnouncer> {
  String _announced = '';
  String? _pending;

  /// Running while the last change is younger than the debounce window.
  /// Timers only (no wall clock) so it behaves the same under fake time.
  Timer? _cooldown;

  @override
  void dispose() {
    _cooldown?.cancel();
    super.dispose();
  }

  void _offer(String label) {
    if (_cooldown != null) {
      _pending = label;
      return;
    }
    if (label != _announced) _apply(label);
  }

  void _apply(String label) {
    setState(() => _announced = label);
    _cooldown = Timer(widget.debounce, () {
      _cooldown = null;
      final next = _pending;
      _pending = null;
      if (mounted && next != null && next != _announced) _apply(next);
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<String>(
      chatControllerProvider(widget.sessionId).select(turnStatusLabel),
      (_, next) => _offer(next),
    );
    return Semantics(
      container: true,
      liveRegion: true,
      label: _announced,
      child: const SizedBox(width: 1, height: 1),
    );
  }
}
