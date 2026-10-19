// STAND-IN for Metal, for type-checking on Linux only.
import Foundation

public protocol MTLDevice: NSObjectProtocol {
  var recommendedMaxWorkingSetSize: UInt64 { get }
}

public func MTLCreateSystemDefaultDevice() -> (any MTLDevice)? { nil }
