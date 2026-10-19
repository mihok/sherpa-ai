// Stand-ins mirroring the iOS SDK declarations the plugin uses, including
// their @MainActor isolation (Linux type-check only).
@_exported import Foundation

@MainActor open class UIColor: NSObject {
  public static let clear = UIColor()
}

@MainActor open class UIView: NSObject {
  public struct AutoresizingMask: OptionSet, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let flexibleWidth = AutoresizingMask(rawValue: 2)
    public static let flexibleHeight = AutoresizingMask(rawValue: 16)
  }
  public init(frame: CGRect) { self.bounds = CGRect(origin: .zero, size: frame.size) }
  open var bounds: CGRect
  open var backgroundColor: UIColor?
  open var isOpaque: Bool = true
  open var autoresizingMask: AutoresizingMask = []
  open func addSubview(_ view: UIView) {}
  open func removeFromSuperview() {}
}

@MainActor open class UIScrollView: UIView {
  public enum ContentInsetAdjustmentBehavior: Int, Sendable { case automatic, scrollableAxes, never, always }
  open var bounces: Bool = true
  open var contentInsetAdjustmentBehavior: ContentInsetAdjustmentBehavior = .automatic
}
