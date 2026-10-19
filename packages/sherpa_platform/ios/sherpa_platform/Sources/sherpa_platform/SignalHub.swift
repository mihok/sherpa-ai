import Foundation
import UIKit

/// Pushes OS events to Dart while the event channel is listened, and only
/// then (R06 §5, §7):
/// - `didReceiveMemoryWarningNotification` (edge-triggered, no all-clear);
/// - a DispatchSource memory-pressure source (level-triggered: normal,
///   warning, critical);
/// - `thermalStateDidChangeNotification` and `NSProcessInfoPowerStateDidChange`.
/// Everything is delivered on the main queue, where Flutter event sinks must
/// be called.
final class SignalHub: SignalsStreamHandler {
  private var sink: PigeonEventSink<PlatformSignal>?
  private var observers: [NSObjectProtocol] = []
  private var pressureSource: DispatchSourceMemoryPressure?

  override func onListen(withArguments arguments: Any?, sink: PigeonEventSink<PlatformSignal>) {
    stop()
    self.sink = sink
    // "You must access the thermalState prior to registering for the
    // notification."
    _ = ProcessInfo.processInfo.thermalState
    let center = NotificationCenter.default
    observers.append(center.addObserver(
      forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
    ) { [weak self] _ in
      self?.emit(kind: .memoryWarning, level: 0)
    })
    observers.append(center.addObserver(
      forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      self?.emit(kind: .thermal, level: Int64(ProcessInfo.processInfo.thermalState.rawValue))
    })
    observers.append(center.addObserver(
      forName: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: .main
    ) { [weak self] _ in
      self?.emit(kind: .powerMode, level: ProcessInfo.processInfo.isLowPowerModeEnabled ? 1 : 0)
    })

    // Starts inactive; must be activated. The handler reads the source via
    // self (weak) so the source does not retain itself through the closure.
    let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
    source.setEventHandler { [weak self] in
      guard let self = self, let event = self.pressureSource?.data else { return }
      let level: Int64 = event.contains(.critical) ? 2 : (event.contains(.warning) ? 1 : 0)
      self.emit(kind: .memoryPressure, level: level)
    }
    pressureSource = source
    source.activate()
  }

  override func onCancel(withArguments arguments: Any?) {
    stop()
  }

  private func stop() {
    for observer in observers {
      NotificationCenter.default.removeObserver(observer)
    }
    observers.removeAll()
    pressureSource?.cancel()
    pressureSource = nil
    sink = nil
  }

  func emit(kind: SignalKind, level: Int64, leaseId: String? = nil, detail: String? = nil) {
    let signal = PlatformSignal(
      kind: kind, level: level, leaseId: leaseId, detail: detail, timestampMs: DeviceReaders.nowMs())
    if Thread.isMainThread {
      sink?.success(signal)
    } else {
      DispatchQueue.main.async { [weak self] in
        self?.sink?.success(signal)
      }
    }
  }
}
