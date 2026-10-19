import Flutter
import UIKit

/// Entry point: the Pigeon host API and the platform view factory for
/// `io.github.mihok.sherpa_webview/mcp_app`. Everything runs on the main
/// thread (Pigeon's default; WKWebView is main-thread only).
///
/// UNVERIFIED against the real iOS SDK: written from Apple's and Flutter's
/// documentation and type-checked only on Linux against stand-in modules
/// (see README). The first real compile is CI on macOS.
public final class SherpaWebviewPlugin: NSObject, FlutterPlugin, McpAppHostApi {
  private let registrar: FlutterPluginRegistrar
  private let flutterApi: McpAppFlutterApi
  private var configs: [Int64: NativeViewConfig] = [:]
  private var views: [Int64: McpAppPlatformView] = [:]
  private var shellTemplate: String?

  init(registrar: FlutterPluginRegistrar) {
    self.registrar = registrar
    self.flutterApi = McpAppFlutterApi(binaryMessenger: registrar.messenger())
    super.init()
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = SherpaWebviewPlugin(registrar: registrar)
    McpAppHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: instance)
    registrar.register(Factory(plugin: instance), withId: "io.github.mihok.sherpa_webview/mcp_app")
  }

  func support() throws -> NativeSupport {
    // WKWebView, content worlds (iOS 14) and content rules are always
    // present on the iOS 17 floor.
    return NativeSupport(supported: true, reason: nil)
  }

  func createView(config: NativeViewConfig) throws {
    configs[config.viewId] = config
  }

  func postToShell(viewId: Int64, message: String) throws {
    let view = views[viewId]
    MainActor.assumeIsolated { view?.postToShell(message) }
  }

  func disposeView(viewId: Int64) throws {
    configs.removeValue(forKey: viewId)
    let view = views.removeValue(forKey: viewId)
    MainActor.assumeIsolated { view?.dispose() }
  }

  /// Data stores are non-persistent and per view: nothing to wipe.
  func clearProfile(profileKey: String, completion: @escaping (Result<Bool, Error>) -> Void) {
    completion(.success(true))
  }

  fileprivate func shell() -> String? {
    if let cached = shellTemplate { return cached }
    let key = registrar.lookupKey(forAsset: "assets/mcp_app_shell.html", fromPackage: "sherpa_webview")
    guard let path = Bundle.main.path(forResource: key, ofType: nil),
      let html = try? String(contentsOfFile: path, encoding: .utf8)
    else { return nil }
    shellTemplate = html
    return html
  }

  /// Called on the main thread by the factory.
  fileprivate func makeView(frame: CGRect, viewIdentifier: Int64, arguments: Any?) -> McpAppPlatformView {
    let args = arguments as? [String: Any]
    let viewId = (args?["viewId"] as? NSNumber)?.int64Value ?? -1
    let known = configs[viewId]
    let config = known ?? NativeViewConfig(
      viewId: viewId, csp: ShellPolicy.defaultCSP, allowedOrigins: [], profileKey: "", debuggable: false,
      maxMessageChars: 0)
    let api = flutterApi
    // An unknown id gets no shell at all (fail closed).
    let template = known == nil ? nil : shell()
    let previous = views[viewId]
    let view = MainActor.assumeIsolated { () -> McpAppPlatformView in
      previous?.dispose()
      return McpAppPlatformView(
        frame: frame,
        config: config,
        shellTemplate: template,
        onShellMessage: { message in api.onShellMessage(viewId: viewId, message: message) { _ in } },
        onEvent: { kind, detail in
          api.onViewEvent(viewId: viewId, event: NativeViewEvent(kind: kind, detail: detail)) { _ in }
        }
      )
    }
    views[viewId] = view
    return view
  }
}

private final class Factory: NSObject, FlutterPlatformViewFactory {
  private weak var plugin: SherpaWebviewPlugin?

  init(plugin: SherpaWebviewPlugin) {
    self.plugin = plugin
    super.init()
  }

  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    guard let plugin = plugin else {
      return MainActor.assumeIsolated {
        McpAppPlatformView(
          frame: frame,
          config: NativeViewConfig(
            viewId: -1, csp: ShellPolicy.defaultCSP, allowedOrigins: [], profileKey: "", debuggable: false,
            maxMessageChars: 0),
          shellTemplate: nil, onShellMessage: { _ in }, onEvent: { _, _ in })
      }
    }
    return plugin.makeView(frame: frame, viewIdentifier: viewId, arguments: args)
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    return FlutterStandardMessageCodec.sharedInstance()
  }
}
