import BackgroundTasks
import Foundation
import UIKit

/// Background time for an agent reply or run (R06 §6). Main actor: UIKit
/// and the lease bookkeeping live there, and Pigeon delivers these calls on
/// the main thread.
///
/// - Default: `beginBackgroundTask` — finishing work, seconds rather than
///   minutes; the expiration handler runs on the main thread and must end
///   the task, or the app is killed.
/// - `long` + an identifier on iOS 26+: `BGContinuedProcessingTask`, which
///   starts in the foreground from a user action and shows a system Live
///   Activity with a cancel button. Strategy `.fail`: if it cannot start now
///   we fall back to `beginBackgroundTask` instead of queueing a run the user
///   believes is already running. `.gpu` only when requested *and* in
///   `BGTaskScheduler.supportedResources` (Apple DTS: M3+ iPads, no iPhone);
///   without it Metal rejects background command buffers, so local GPU
///   inference must still pause.
@MainActor
final class BackgroundLeases {
  /// (leaseId, reason) when the OS ends a lease before Dart does.
  private let onExpired: (String, String) -> Void

  private var tasks: [String: UIBackgroundTaskIdentifier] = [:]

  /// BGContinuedProcessingTask (iOS 26+). Typed as AnyObject because stored
  /// properties cannot be `@available`-gated; cast back under `#available`.
  private var continued: [String: AnyObject] = [:]

  /// Submitted, launch handler not yet run.
  private var continuedPending: Set<String> = []

  /// "Register each task identifier only once. The system kills the app on
  /// the second registration of the same task identifier."
  private static var registered: Set<String> = []

  init(onExpired: @escaping (String, String) -> Void) {
    self.onExpired = onExpired
  }

  func begin(_ request: LeaseRequest) -> LeaseResult {
    var note: String?
    if request.long, let identifier = request.iosContinuedTaskIdentifier {
      if #available(iOS 26.0, *) {
        if let failure = submitContinued(request, identifier: identifier) {
          note = failure
        } else {
          return LeaseResult(id: request.id, mode: .iosContinuedProcessing, granted: true, notificationsVisible: true)
        }
      } else {
        note = "BGContinuedProcessingTask needs iOS 26"
      }
    }
    let leaseId = request.id
    let taskId = UIApplication.shared.beginBackgroundTask(withName: "sherpa.\(leaseId)") { [weak self] in
      // Main thread, shortly before background time runs out (or at once if
      // the assertion could not be granted).
      self?.expire(leaseId, detail: "background time expired")
    }
    guard taskId != .invalid else {
      return LeaseResult(
        id: leaseId, mode: .none, granted: false,
        error: note ?? "background execution is not possible", notificationsVisible: true)
    }
    tasks[leaseId] = taskId
    return LeaseResult(id: leaseId, mode: .iosBackgroundTask, granted: true, error: note, notificationsVisible: true)
  }

  func update(_ id: String, progress: Double?, text: String?) {
    guard #available(iOS 26.0, *), let task = continued[id] as? BGContinuedProcessingTask else { return }
    if let progress = progress {
      // The system terminates tasks that report little progress first.
      task.progress.completedUnitCount = Int64((min(max(progress, 0), 1) * 100).rounded())
    }
    if let text = text {
      task.updateTitle(task.title, subtitle: text)
    }
  }

  func end(_ id: String) {
    if let taskId = tasks.removeValue(forKey: id) {
      UIApplication.shared.endBackgroundTask(taskId)
    }
    continuedPending.remove(id)
    if #available(iOS 26.0, *), let task = continued.removeValue(forKey: id) as? BGContinuedProcessingTask {
      task.progress.completedUnitCount = task.progress.totalUnitCount
      task.setTaskCompleted(success: true)
    }
  }

  private func expire(_ id: String, detail: String) {
    var known = false
    if let taskId = tasks.removeValue(forKey: id) {
      UIApplication.shared.endBackgroundTask(taskId)
      known = true
    }
    if #available(iOS 26.0, *), let task = continued.removeValue(forKey: id) as? BGContinuedProcessingTask {
      task.setTaskCompleted(success: false)
      known = true
    }
    if known {
      onExpired(id, detail)
    }
  }

  /// Returns nil when submitted, else why not.
  @available(iOS 26.0, *)
  private func submitContinued(_ request: LeaseRequest, identifier: String) -> String? {
    guard Self.permitted(identifier) else {
      return "\(identifier) is not covered by BGTaskSchedulerPermittedIdentifiers"
    }
    let scheduler = BGTaskScheduler.shared
    let leaseId = request.id
    if !Self.registered.contains(identifier) {
      // Handler queue: main, so assumeIsolated holds.
      let ok = scheduler.register(forTaskWithIdentifier: identifier, using: DispatchQueue.main) { [weak self] task in
        MainActor.assumeIsolated {
          self?.continuedStarted(task, leaseId: leaseId)
        }
      }
      guard ok else { return "BGTaskScheduler did not register \(identifier)" }
      Self.registered.insert(identifier)
    }
    let taskRequest = BGContinuedProcessingTaskRequest(identifier: identifier, title: request.title, subtitle: request.reason)
    taskRequest.strategy = .fail
    if request.iosRequestGpu && BGTaskScheduler.supportedResources.contains(.gpu) {
      // Also needs the com.apple.developer.background-tasks.continued-processing.gpu entitlement.
      taskRequest.requiredResources = .gpu
    }
    continuedPending.insert(leaseId)
    do {
      try scheduler.submit(taskRequest)
    } catch {
      continuedPending.remove(leaseId)
      return "BGContinuedProcessingTask submit failed: \(error.localizedDescription)"
    }
    return nil
  }

  @available(iOS 26.0, *)
  private func continuedStarted(_ task: BGTask, leaseId: String) {
    guard let task = task as? BGContinuedProcessingTask, continuedPending.remove(leaseId) != nil else {
      // Ended by Dart before the system started it (or an unexpected type).
      task.setTaskCompleted(success: true)
      return
    }
    task.progress.totalUnitCount = 100
    task.expirationHandler = { [weak self] in
      // Cancelled from the Live Activity or by the system; the queue is
      // unspecified, so hop to main where the bookkeeping lives.
      guard let leases = self else { return }
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          leases.expire(leaseId, detail: "continued processing task expired")
        }
      }
    }
    continued[leaseId] = task
  }

  /// Exact entry or a `<prefix>.*` wildcard in the app's Info.plist.
  /// Checked first because registering an unlisted identifier is refused.
  static func permitted(_ identifier: String) -> Bool {
    let entries = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
    return entries.contains { entry in
      entry == identifier || (entry.hasSuffix(".*") && identifier.hasPrefix(String(entry.dropLast())))
    }
  }
}
