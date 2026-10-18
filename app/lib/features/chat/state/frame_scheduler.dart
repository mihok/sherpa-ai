import 'package:flutter/scheduler.dart';

/// Runs a callback once, just before the next frame is built.
///
/// The chat controller coalesces streamed deltas behind this so the UI is
/// updated at most once per vsync no matter how fast tokens arrive. It is
/// an interface so tests can drive "frames" by hand and count emissions.
abstract interface class FrameScheduler {
  void scheduleFrameCallback(void Function() callback);
}

/// Production scheduler: a transient frame callback. Setting provider state
/// from it lands in the same frame's build phase, so a delta never waits an
/// extra frame. Frames don't run while the app is backgrounded; deltas
/// accumulate and the controller flushes them on the next frame or at the
/// end of the run, whichever comes first.
final class SchedulerFrameScheduler implements FrameScheduler {
  const SchedulerFrameScheduler();

  @override
  void scheduleFrameCallback(void Function() callback) {
    SchedulerBinding.instance.scheduleFrameCallback((_) => callback());
  }
}
