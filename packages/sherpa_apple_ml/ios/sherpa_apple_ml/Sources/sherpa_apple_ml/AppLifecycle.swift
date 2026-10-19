import Foundation
import UIKit

/// Whether GPU work may be submitted now.
///
/// Metal rejects command buffers committed after the app has moved to the
/// background (`MTLCommandBufferError.notPermitted`) and MLX's default error
/// handler would then exit the process (R06 §2.10, §6.1), so MLX work only
/// runs while the gate is open: it closes on `willResignActive` (before the
/// background transition, while the GPU is still usable, so a generation can
/// stop at a token boundary) and opens on `didBecomeActive`. Generations
/// that start while it is closed wait (cancellably) instead of failing.
final class GpuGate: @unchecked Sendable {
  private let lock = NSLock()
  private var isOpenValue: Bool
  private var reasonValue = "app_inactive"
  private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

  init(open: Bool) {
    isOpenValue = open
  }

  var isOpen: Bool { lock.withLock { isOpenValue } }
  var reason: String { lock.withLock { reasonValue } }

  func close(reason: String) {
    lock.withLock {
      isOpenValue = false
      reasonValue = reason
    }
  }

  func open() {
    let resumed: [CheckedContinuation<Void, Error>] = lock.withLock {
      isOpenValue = true
      let all = Array(waiters.values)
      waiters.removeAll()
      return all
    }
    for c in resumed { c.resume() }
  }

  /// Returns at once when open; otherwise waits for [open]. Throws
  /// `CancellationError` when the calling task is cancelled meanwhile,
  /// including before the waiter is registered.
  func waitUntilOpen() async throws {
    if isOpen { return }
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
        // In an already-cancelled task `onCancel` runs BEFORE this body and
        // finds no waiter ("the cancellation handler will be executed
        // immediately before the operation closure", Swift docs for
        // withTaskCancellationHandler), so check the flag here too. The
        // runtime sets it before running handlers and `onCancel` takes the
        // same lock: either this check sees it, or `onCancel` finds the
        // registered waiter.
        let outcome: Result<Void, Error>? = lock.withLock {
          if isOpenValue { return .success(()) }
          if Task.isCancelled { return .failure(CancellationError()) }
          waiters[id] = c
          return nil
        }
        if let outcome { c.resume(with: outcome) }
      }
    } onCancel: {
      let c: CheckedContinuation<Void, Error>? = lock.withLock { waiters.removeValue(forKey: id) }
      c?.resume(throwing: CancellationError())
    }
  }
}

/// Observes the app lifecycle and memory warnings (main thread).
///
/// * `willResignActive`: closes the [GpuGate] and asks the MLX engine to
///   pause every generation at a token boundary, inside a
///   `beginBackgroundTask` assertion so the wind-down can finish if the app
///   is backgrounded right after. Dart receives `paused` and ends the reply
///   with `Finish(pause)`.
/// * `didBecomeActive`: opens the gate; waiting generations start.
/// * memory warning: the MLX engine clears its buffer cache and drops idle
///   sessions (KV caches); Dart gets a global `memoryWarning` event.
///
/// Foundation Models is not paused: the system model runs out of process
/// and is usable (rate-limited) in the background (R06 §3.8).
@MainActor
final class LifecycleMonitor {
  private let gate: GpuGate
  private let hub: EventHub
  private let onResign: @Sendable (String) async -> Void
  private let onMemoryWarning: @Sendable () async -> Void
  private var observers: [NSObjectProtocol] = []

  init(
    gate: GpuGate,
    hub: EventHub,
    onResign: @escaping @Sendable (String) async -> Void,
    onMemoryWarning: @escaping @Sendable () async -> Void
  ) {
    self.gate = gate
    self.hub = hub
    self.onResign = onResign
    self.onMemoryWarning = onMemoryWarning
  }

  func start() {
    let center = NotificationCenter.default
    observers.append(
      center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) {
        [weak self] _ in
        MainActor.assumeIsolated { self?.resignActive() }
      })
    observers.append(
      center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) {
        [weak self] _ in
        MainActor.assumeIsolated { self?.becameActive() }
      })
    observers.append(
      center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) {
        [weak self] _ in
        MainActor.assumeIsolated { self?.lifecycle("background") }
      })
    observers.append(
      center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) {
        [weak self] _ in
        MainActor.assumeIsolated { self?.memoryWarning() }
      })
  }

  private func resignActive() {
    gate.close(reason: "app_inactive")
    lifecycle("inactive")
    let assertion = BackgroundAssertion(name: "sherpa.mlx.pause")
    let onResign = self.onResign
    Task { @MainActor in
      await onResign("app_inactive")
      assertion.end()
    }
  }

  private func becameActive() {
    gate.open()
    lifecycle("active")
  }

  private func memoryWarning() {
    let onMemoryWarning = self.onMemoryWarning
    Task.detached { await onMemoryWarning() }
  }

  private func lifecycle(_ state: String) {
    var e = AmEvent(kind: .lifecycle)
    e.code = state
    hub.emitGlobal(e)
  }

  deinit {
    for o in observers { NotificationCenter.default.removeObserver(o) }
  }
}

/// A `beginBackgroundTask` assertion that ends once, on main.
@MainActor
final class BackgroundAssertion {
  private var id: UIBackgroundTaskIdentifier = .invalid

  init(name: String) {
    id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
      // Expired: every generation has been asked to stop already.
      MainActor.assumeIsolated { self?.end() }
    }
  }

  func end() {
    guard id != .invalid else { return }
    UIApplication.shared.endBackgroundTask(id)
    id = .invalid
  }
}
