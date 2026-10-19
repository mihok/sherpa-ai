// STAND-IN for Flutter.framework (iOS), for type-checking on Linux only.
// Mirrors the Objective-C declarations Pigeon's generated Swift and the
// plugin use (FlutterChannels.h, FlutterCodecs.h, FlutterPlugin.h), as Swift
// imports them. Not a functional implementation.
@_exported import Foundation  // the Flutter umbrella header imports Foundation

public typealias FlutterEventSink = (Any?) -> Void
public typealias FlutterReply = (Any?) -> Void
public typealias FlutterMessageHandler = (Any?, @escaping FlutterReply) -> Void

public let FlutterEndOfEventStream: NSObject = NSObject()

public protocol FlutterBinaryMessenger: NSObjectProtocol {}

public protocol FlutterMessageCodec: NSObjectProtocol {}
public protocol FlutterMethodCodec: NSObjectProtocol {}

open class FlutterStandardReader: NSObject {
  public init(data: Data) {}
  open func readByte() -> UInt8 { 0 }
  open func readValue() -> Any? { nil }
  open func readValue(ofType type: UInt8) -> Any? { nil }
}

open class FlutterStandardWriter: NSObject {
  public init(data: NSMutableData) {}
  open func writeByte(_ value: UInt8) {}
  open func writeValue(_ value: Any) {}
}

open class FlutterStandardReaderWriter: NSObject {
  public override init() {}
  open func reader(with data: Data) -> FlutterStandardReader { FlutterStandardReader(data: data) }
  open func writer(with data: NSMutableData) -> FlutterStandardWriter { FlutterStandardWriter(data: data) }
}

open class FlutterStandardMessageCodec: NSObject, FlutterMessageCodec {
  public init(readerWriter: FlutterStandardReaderWriter) {}
}

open class FlutterStandardMethodCodec: NSObject, FlutterMethodCodec {
  public init(readerWriter: FlutterStandardReaderWriter) {}
}

open class FlutterBasicMessageChannel: NSObject {
  public init(name: String, binaryMessenger messenger: FlutterBinaryMessenger, codec: FlutterMessageCodec) {}
  open func setMessageHandler(_ handler: FlutterMessageHandler?) {}
}

public protocol FlutterStreamHandler: NSObjectProtocol {
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError?
  func onCancel(withArguments arguments: Any?) -> FlutterError?
}

open class FlutterEventChannel: NSObject {
  public init(name: String, binaryMessenger messenger: FlutterBinaryMessenger, codec: FlutterMethodCodec) {}
  open func setStreamHandler(_ handler: FlutterStreamHandler?) {}
}

// The real class is an NSObject; on Darwin `error as? FlutterError` goes
// through NSError bridging. Conforming to Error lets the same cast compile
// on Linux.
open class FlutterError: NSObject, Error {
  public let code: String
  public let message: String?
  public let details: Any?

  public init(code: String, message: String?, details: Any?) {
    self.code = code
    self.message = message
    self.details = details
  }
}

open class FlutterStandardTypedData: NSObject {
  public let data: Data = Data()
}

public protocol FlutterPluginRegistrar: NSObjectProtocol {
  func messenger() -> FlutterBinaryMessenger
}

public protocol FlutterPlugin: NSObjectProtocol {
  static func register(with registrar: FlutterPluginRegistrar)
}
