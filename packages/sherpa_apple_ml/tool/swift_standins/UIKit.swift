// STAND-IN for UIKit (and the Darwin-only Foundation members the plugin
// uses), for type-checking on Linux only. Isolation mirrors the iOS 26 SDK:
// UIApplication and UIDevice are @MainActor; notification names are
// nonisolated constants; the background-task expiration handler is
// `@MainActor @Sendable`.
@_exported import Foundation  // UIKit re-exports Foundation

@MainActor
open class UIApplication: NSObject {
  public enum State: Int, Sendable {
    case active, inactive, background
  }

  public static var shared: UIApplication { fatalError("stand-in") }
  public var applicationState: UIApplication.State { .active }

  public func beginBackgroundTask(
    withName taskName: String?, expirationHandler handler: (@MainActor @Sendable () -> Void)? = nil
  ) -> UIBackgroundTaskIdentifier { .invalid }

  public func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier) {}

  nonisolated public static let willResignActiveNotification = Notification.Name("UIApplicationWillResignActiveNotification")
  nonisolated public static let didBecomeActiveNotification = Notification.Name("UIApplicationDidBecomeActiveNotification")
  nonisolated public static let didEnterBackgroundNotification = Notification.Name("UIApplicationDidEnterBackgroundNotification")
  nonisolated public static let didReceiveMemoryWarningNotification = Notification.Name(
    "UIApplicationDidReceiveMemoryWarningNotification")
}

public struct UIBackgroundTaskIdentifier: RawRepresentable, Hashable, Sendable {
  public let rawValue: Int
  public init(rawValue: Int) { self.rawValue = rawValue }
  public static let invalid = UIBackgroundTaskIdentifier(rawValue: 0)
}

@MainActor
open class UIDevice: NSObject {
  public static var current: UIDevice { fatalError("stand-in") }
  public var systemVersion: String { "26.0" }
}

// Darwin Foundation members missing from swift-corelibs-foundation.
extension ProcessInfo {
  public enum ThermalState: Int, Sendable {
    case nominal, fair, serious, critical
  }

  public var thermalState: ProcessInfo.ThermalState { .nominal }
  public var isLowPowerModeEnabled: Bool { false }
}
