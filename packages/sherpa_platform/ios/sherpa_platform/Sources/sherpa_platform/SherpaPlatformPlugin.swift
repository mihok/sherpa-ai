import Flutter
import UIKit

/// Entry point. sampleMemory / deviceInfo / setProcessStateSummary /
/// excludeFromBackup run on Pigeon's background task queue (see
/// pigeons/platform_api.dart); the lease calls arrive on the main thread,
/// which is where UIApplication and BGTaskScheduler bookkeeping happens.
///
/// UNVERIFIED against the real iOS SDK: written from Apple's documentation
/// and type-checked only on Linux against stand-in modules that mirror the
/// SDK declarations (Swift 5 mode: clean). The first real compile is CI on
/// macOS.
public final class SherpaPlatformPlugin: NSObject, FlutterPlugin, SherpaPlatformHostApi {
  private let hub: SignalHub
  private let leases: BackgroundLeases

  /// Created by `register(with:)`, which Flutter calls on the main thread.
  override init() {
    let hub = SignalHub()
    self.hub = hub
    self.leases = MainActor.assumeIsolated {
      BackgroundLeases { [weak hub] id, detail in
        hub?.emit(kind: .leaseExpired, level: 0, leaseId: id, detail: detail)
      }
    }
    super.init()
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = SherpaPlatformPlugin()
    // setUp's handlers retain `instance` for the engine's lifetime.
    SherpaPlatformHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: instance)
    SignalsStreamHandler.register(with: registrar.messenger(), streamHandler: instance.hub)
  }

  func sampleMemory() throws -> MemorySample {
    return DeviceReaders.memorySample()
  }

  func deviceInfo() throws -> DeviceInfo {
    return DeviceReaders.deviceInfo()
  }

  /// No iOS equivalent of Android's ApplicationExitInfo summary.
  func setProcessStateSummary(summary: FlutterStandardTypedData) throws -> Bool {
    return false
  }

  /// `isExcludedFromBackup` is a per-file attribute, so each existing SQLite
  /// sidecar is flagged too. Apple notes some file operations reset it; the
  /// Dart side re-applies it after each database open.
  func excludeFromBackup(path: String, includeSqliteSidecars: Bool) throws -> [String] {
    var candidates = [path]
    if includeSqliteSidecars {
      candidates += ["-wal", "-shm", "-journal"].map { path + $0 }
    }
    var flagged: [String] = []
    for candidate in candidates where FileManager.default.fileExists(atPath: candidate) {
      var url = URL(fileURLWithPath: candidate)
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try url.setResourceValues(values)
      flagged.append(candidate)
    }
    return flagged
  }

  /// Background tasks need no notification permission on iOS.
  func notificationsPermitted() throws -> Bool {
    return true
  }

  // Lease calls have no TaskQueue, so Flutter delivers them on the main
  // thread; assumeIsolated states that (and traps if it ever changes).
  func beginLease(request: LeaseRequest, completion: @escaping (Result<LeaseResult, Error>) -> Void) {
    let result = MainActor.assumeIsolated { leases.begin(request) }
    completion(.success(result))
  }

  func updateLease(id: String, progress: Double?, text: String?) throws {
    MainActor.assumeIsolated { leases.update(id, progress: progress, text: text) }
  }

  func endLease(id: String) throws {
    MainActor.assumeIsolated { leases.end(id) }
  }
}
