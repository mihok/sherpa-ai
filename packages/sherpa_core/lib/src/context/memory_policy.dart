import 'package:meta/meta.dart';

import '../memory/memory_monitor.dart';
import '../provider/capabilities.dart';

/// Maps device memory and thermal state to how much of the model window the
/// context manager may fill, for on-device providers only.
///
/// This is also the hook the local engine uses to shrink `n_ctx`: before a
/// (re)load it calls [effectiveContextLength] with the current
/// [MemoryState], so the KV cache it allocates and the budget the context
/// manager plans against are the same number. A smaller window then flows
/// through the ordinary ladder (prune → compact → handoff) instead of an OOM
/// kill (PLAN findings 11–12: Android 17's anonymous-memory limiter, iOS
/// jetsam).
@immutable
final class MemoryContextPolicy {
  const MemoryContextPolicy({
    this.normalFraction = 1.0,
    this.moderateFraction = 0.75,
    this.criticalFraction = 0.5,
    this.thermalPruneShift = 0.10,
    this.minimumTokens = 1024,
  });

  /// A policy that never reduces anything (remote-only setups, tests).
  static const none = MemoryContextPolicy(moderateFraction: 1.0, criticalFraction: 1.0, thermalPruneShift: 0);

  final double normalFraction;
  final double moderateFraction;
  final double criticalFraction;

  /// At thermal `serious`/`critical`, prune this much earlier: every token
  /// not prefilled is heat not generated.
  final double thermalPruneShift;

  /// Never plan below this many tokens of window.
  final int minimumTokens;

  /// Memory pressure only shrinks windows whose KV cache lives on this
  /// device; a remote model's window costs the phone nothing.
  bool appliesTo(ExecutionLocation? location) => location == ExecutionLocation.onDevice;

  double limitFraction(MemoryState state) => switch (state.pressure) {
        MemoryPressure.normal => normalFraction,
        MemoryPressure.moderate => moderateFraction,
        MemoryPressure.critical => criticalFraction,
      };

  /// The window to plan (and allocate) for [contextLength] under [state].
  int effectiveContextLength(int contextLength, MemoryState state) {
    final reduced = (contextLength * limitFraction(state)).floor();
    final floor = contextLength < minimumTokens ? contextLength : minimumTokens;
    return reduced < floor ? floor : reduced;
  }

  /// How much earlier pruning starts (subtracted from the prune threshold).
  double pruneShift(MemoryState state) =>
      state.thermal == ThermalLevel.serious || state.thermal == ThermalLevel.critical ? thermalPruneShift : 0;
}
