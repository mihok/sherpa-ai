import Foundation
import UIKit
import os

/// Raw readings (R06 §5, §7). Thread-safe except where noted; the UIKit
/// reads hop to the main thread because UIDevice is a main-actor type.
enum DeviceReaders {
  static func nowMs() -> Int64 {
    return Int64((Date().timeIntervalSince1970 * 1000).rounded())
  }

  /// Cheap enough for the 2 s foreground poll: os_proc_available_memory is
  /// "much more efficient" than task_info, and we make one TASK_VM_INFO call.
  static func memorySample() -> MemorySample {
    let info = ProcessInfo.processInfo
    return MemorySample(
      platform: "ios",
      timestampMs: nowMs(),
      // "limit minus footprint", 0 when over the limit; never cached.
      procAvailableBytes: Int64(os_proc_available_memory()),
      physFootprintBytes: physFootprint(),
      physicalMemoryBytes: Int64(clamping: info.physicalMemory),
      thermalStatus: Int64(info.thermalState.rawValue),
      lowPowerMode: info.isLowPowerModeEnabled
    )
  }

  /// `task_vm_info.phys_footprint`: the figure jetsam compares to the limit.
  static func physFootprint() -> Int64? {
    var vmInfo = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &vmInfo) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), raw, &count)
      }
    }
    guard result == KERN_SUCCESS else { return nil }
    return Int64(clamping: vmInfo.phys_footprint)
  }

  /// What deviceInfo needs from UIDevice, a main-actor type.
  private struct UIKitFacts {
    var systemVersion: String
    var model: String
    var battery: Double?
    var charging: Bool?
  }

  @MainActor
  private static func readUIKit() -> UIKitFacts {
    let device = UIDevice.current
    // Battery values are -1 / .unknown unless monitoring is on; restore the
    // app's own setting afterwards.
    let wasMonitoring = device.isBatteryMonitoringEnabled
    device.isBatteryMonitoringEnabled = true
    let level = device.batteryLevel
    let charging: Bool?
    switch device.batteryState {
    case .charging, .full:
      charging = true
    case .unplugged:
      charging = false
    default:
      charging = nil
    }
    device.isBatteryMonitoringEnabled = wasMonitoring
    return UIKitFacts(
      systemVersion: device.systemVersion,
      model: device.model,
      battery: level >= 0 ? Double(level) : nil,
      charging: charging
    )
  }

  /// Runs on Pigeon's background task queue; only the UIDevice reads hop to
  /// the main thread.
  static func deviceInfo() -> DeviceInfo {
    let facts: UIKitFacts
    if Thread.isMainThread {
      facts = MainActor.assumeIsolated { readUIKit() }
    } else {
      facts = DispatchQueue.main.sync { MainActor.assumeIsolated { readUIKit() } }
    }

    var freeStorage: Int64?
    var totalStorage: Int64?
    let home = URL(fileURLWithPath: NSHomeDirectory())
    if let values = try? home.resourceValues(forKeys: [
      .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey,
    ]) {
      // "Important usage": what the system will free up for a download the
      // user asked for, which is the question device-fit asks.
      freeStorage = values.volumeAvailableCapacityForImportantUsage
      if let total = values.volumeTotalCapacity {
        totalStorage = Int64(total)
      }
    }

    let performanceCores = sysctlInt("hw.perflevel0.physicalcpu")
    return DeviceInfo(
      platform: "ios",
      osVersion: facts.systemVersion,
      manufacturer: "Apple",
      model: facts.model,
      hardware: sysctlString("hw.model"),
      machine: sysctlString("hw.machine"),
      memory: memorySample(),
      freeStorageBytes: freeStorage,
      totalStorageBytes: totalStorage,
      cpuCores: Int64(ProcessInfo.processInfo.processorCount),
      cpuMaxFreqKHz: [],
      cpuCapacity: [],
      bigCoreIndices: [],
      performanceCores: performanceCores,
      cpuFeatures: cpuFeatures(),
      isLowRamDevice: false,
      batteryLevel: facts.battery,
      charging: facts.charging
    )
  }

  /// ARM features via `hw.optional.arm.FEAT_*` (1 = present). A missing key
  /// means absent (older OS or core). Names match the Android parser.
  static func cpuFeatures() -> [String] {
    let keys: [(String, String)] = [
      ("hw.optional.arm.FEAT_BF16", "bf16"),
      ("hw.optional.arm.FEAT_DotProd", "dotprod"),
      ("hw.optional.arm.FEAT_FP16", "fp16"),
      ("hw.optional.arm.FEAT_I8MM", "i8mm"),
      ("hw.optional.arm.FEAT_SME", "sme"),
      ("hw.optional.arm.FEAT_SME2", "sme2"),
    ]
    return keys.compactMap { key, name in sysctlInt(key) == 1 ? name : nil }
  }

  /// Integer sysctl; these keys are 32-bit, some hw.* keys are 64-bit.
  static func sysctlInt(_ name: String) -> Int64? {
    var value: Int64 = 0
    var size = MemoryLayout<Int64>.size
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
    switch size {
    case MemoryLayout<Int32>.size:
      return Int64(Int32(truncatingIfNeeded: value))
    case MemoryLayout<Int64>.size:
      return value
    default:
      return nil
    }
  }

  static func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
    return buffer.withUnsafeBufferPointer { pointer -> String? in
      guard let base = pointer.baseAddress else { return nil }
      return String(cString: base)
    }
  }
}
