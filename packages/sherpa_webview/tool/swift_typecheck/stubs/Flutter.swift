// Minimal stand-ins for the Flutter iOS embedder API (Linux type-check
// only). Shapes follow the Objective-C headers as imported into Swift.
@_exported import Foundation
import UIKit

public protocol FlutterBinaryMessenger: NSObjectProtocol {}
public protocol FlutterTaskQueue: NSObjectProtocol {}
public protocol FlutterMessageCodec: NSObjectProtocol {}
public typealias FlutterReply = (Any?) -> Void
public typealias FlutterMessageHandler = (Any?, @escaping FlutterReply) -> Void

open class FlutterStandardReader: NSObject {
  public init(data: Data) {}
  open func readValue(ofType type: UInt8) -> Any? { return nil }
  open func readValue() -> Any? { return nil }
}
open class FlutterStandardWriter: NSObject {
  public init(data: NSMutableData) {}
  open func writeValue(_ value: Any) {}
  open func writeByte(_ value: UInt8) {}
}
open class FlutterStandardReaderWriter: NSObject {
  public override init() {}
  open func reader(with data: Data) -> FlutterStandardReader { return FlutterStandardReader(data: data) }
  open func writer(with data: NSMutableData) -> FlutterStandardWriter { return FlutterStandardWriter(data: data) }
}
open class FlutterStandardMessageCodec: NSObject, FlutterMessageCodec {
  public init(readerWriter: FlutterStandardReaderWriter) {}
  open class func sharedInstance() -> Self { fatalError("stub") }
}
open class FlutterError: NSObject {
  public let code: String
  public let message: String?
  public let details: Any?
  public init(code: String, message: String?, details: Any?) { self.code = code; self.message = message; self.details = details }
}
open class FlutterBasicMessageChannel: NSObject {
  public init(name: String, binaryMessenger: FlutterBinaryMessenger, codec: FlutterMessageCodec) {}
  public init(name: String, binaryMessenger: FlutterBinaryMessenger, codec: FlutterMessageCodec, taskQueue: FlutterTaskQueue?) {}
  open func setMessageHandler(_ handler: FlutterMessageHandler?) {}
  open func sendMessage(_ message: Any?, reply callback: FlutterReply? = nil) {}
}
public protocol FlutterPlatformView: NSObjectProtocol {
  func view() -> UIView
}
public protocol FlutterPlatformViewFactory: NSObjectProtocol {
  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView
  // @optional in Objective-C.
  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol
}
public protocol FlutterPluginRegistrar: NSObjectProtocol {
  func messenger() -> FlutterBinaryMessenger
  func register(_ factory: FlutterPlatformViewFactory, withId factoryId: String)
  func lookupKey(forAsset asset: String, fromPackage package: String) -> String
}
public protocol FlutterPlugin: NSObjectProtocol {
  static func register(with registrar: FlutterPluginRegistrar)
}
