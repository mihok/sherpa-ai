// Stand-ins mirroring the iOS 17 SDK WebKit declarations the plugin uses,
// with their @MainActor isolation (Linux type-check only). The optional
// Objective-C delegate methods the plugin implements are declared here as
// REQUIREMENTS with the SDK's Swift signatures, so a mistyped witness is an
// error instead of a silently-never-called method.
@_exported import Foundation
@_exported import FoundationNetworking
import UIKit

@MainActor open class WKContentWorld: NSObject {
  public class var page: WKContentWorld { WKContentWorld() }
  public class func world(name: String) -> WKContentWorld { WKContentWorld() }
  open var name: String? { nil }
}

open class WKContentRuleList: NSObject {}

@MainActor open class WKContentRuleListStore: NSObject {
  open class func `default`() -> WKContentRuleListStore! { WKContentRuleListStore() }
  open func compileContentRuleList(
    forIdentifier identifier: String!, encodedContentRuleList: String!,
    completionHandler: ((WKContentRuleList?, (any Error)?) -> Void)!
  ) {}
}

public enum WKUserScriptInjectionTime: Int, Sendable { case atDocumentStart, atDocumentEnd }

@MainActor open class WKUserScript: NSObject {
  public init(source: String, injectionTime: WKUserScriptInjectionTime, forMainFrameOnly: Bool, in contentWorld: WKContentWorld) {}
}

@MainActor open class WKSecurityOrigin: NSObject {
  open var `protocol`: String { "" }
  open var host: String { "" }
  open var port: Int { 0 }
}

@MainActor open class WKFrameInfo: NSObject {
  open var isMainFrame: Bool { false }
  open var securityOrigin: WKSecurityOrigin { WKSecurityOrigin() }
  open var request: URLRequest { URLRequest(url: URL(string: "about:blank")!) }
}

@MainActor open class WKScriptMessage: NSObject {
  open var body: Any { "" }
  open var frameInfo: WKFrameInfo { WKFrameInfo() }
  open var name: String { "" }
  open var world: WKContentWorld { WKContentWorld() }
}

@MainActor public protocol WKScriptMessageHandler: NSObjectProtocol {
  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage)
}

@MainActor open class WKUserContentController: NSObject {
  open func add(_ contentRuleList: WKContentRuleList) {}
  open func add(_ scriptMessageHandler: WKScriptMessageHandler, contentWorld world: WKContentWorld, name: String) {}
  open func addUserScript(_ userScript: WKUserScript) {}
  open func removeScriptMessageHandler(forName name: String, contentWorld: WKContentWorld) {}
  open func removeAllUserScripts() {}
}

@MainActor open class WKPreferences: NSObject {
  open var javaScriptCanOpenWindowsAutomatically: Bool = false
  open var isFraudulentWebsiteWarningEnabled: Bool = true
  @available(iOS 15.4, *)
  open var isElementFullscreenEnabled: Bool { get { false } set {} }
}

@MainActor open class WKWebpagePreferences: NSObject {
  open var allowsContentJavaScript: Bool = true
}

public struct WKAudiovisualMediaTypes: OptionSet, Sendable {
  public let rawValue: UInt
  public init(rawValue: UInt) { self.rawValue = rawValue }
  public static let audio = WKAudiovisualMediaTypes(rawValue: 1)
  public static let video = WKAudiovisualMediaTypes(rawValue: 2)
  public static let all = WKAudiovisualMediaTypes(rawValue: ~0)
}

public struct WKDataDetectorTypes: OptionSet, Sendable {
  public let rawValue: UInt
  public init(rawValue: UInt) { self.rawValue = rawValue }
  public static let phoneNumber = WKDataDetectorTypes(rawValue: 1)
}

@MainActor open class WKWebsiteDataStore: NSObject {
  open class func nonPersistent() -> WKWebsiteDataStore { WKWebsiteDataStore() }
}

@MainActor open class WKWebViewConfiguration: NSObject {
  public override init() {}
  open var websiteDataStore: WKWebsiteDataStore = .nonPersistent()
  open var preferences: WKPreferences = WKPreferences()
  open var defaultWebpagePreferences: WKWebpagePreferences! = WKWebpagePreferences()
  open var userContentController: WKUserContentController = WKUserContentController()
  open var mediaTypesRequiringUserActionForPlayback: WKAudiovisualMediaTypes = []
  open var allowsAirPlayForMediaPlayback: Bool = true
  open var allowsPictureInPictureMediaPlayback: Bool = true
  open var dataDetectorTypes: WKDataDetectorTypes = []
  open var limitsNavigationsToAppBoundDomains: Bool = false
}

@MainActor open class WKNavigation: NSObject {}
@MainActor open class WKWindowFeatures: NSObject {}

public enum WKNavigationActionPolicy: Int, Sendable { case cancel, allow, download }
public enum WKNavigationResponsePolicy: Int, Sendable { case cancel, allow, download }
public enum WKPermissionDecision: Int, Sendable { case prompt, grant, deny }
public enum WKMediaCaptureType: Int, Sendable { case camera, microphone, cameraAndMicrophone }

@MainActor open class WKNavigationAction: NSObject {
  open var request: URLRequest { URLRequest(url: URL(string: "about:blank")!) }
  open var targetFrame: WKFrameInfo? { nil }
  open var sourceFrame: WKFrameInfo { WKFrameInfo() }
}

@MainActor open class WKNavigationResponse: NSObject {
  open var canShowMIMEType: Bool { true }
  open var isForMainFrame: Bool { true }
}

@MainActor public protocol WKNavigationDelegate: NSObjectProtocol {
  func webView(
    _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void)
  func webView(
    _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
    decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void)
  func webView(
    _ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void)
  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error)
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView)
}

@MainActor public protocol WKUIDelegate: NSObjectProtocol {
  func webView(
    _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView?
  @available(iOS 15.0, *)
  func webView(
    _ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
    type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void)
  @available(iOS 15.0, *)
  func webView(
    _ webView: WKWebView, requestDeviceOrientationAndMotionPermissionFor origin: WKSecurityOrigin,
    initiatedByFrame frame: WKFrameInfo, decisionHandler: @escaping (WKPermissionDecision) -> Void)
  func webView(
    _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
    completionHandler: @escaping () -> Void)
  func webView(
    _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
    completionHandler: @escaping (Bool) -> Void)
  func webView(
    _ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
    initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void)
}

@MainActor open class WKWebView: UIView {
  public init(frame: CGRect, configuration: WKWebViewConfiguration) {
    self.configuration = configuration
    super.init(frame: frame)
  }
  open private(set) var configuration: WKWebViewConfiguration
  weak open var navigationDelegate: (any WKNavigationDelegate)?
  weak open var uiDelegate: (any WKUIDelegate)?
  open var scrollView: UIScrollView { UIScrollView(frame: .zero) }
  open var allowsLinkPreview: Bool = true
  open var allowsBackForwardNavigationGestures: Bool = false
  @available(iOS 16.4, *)
  open var isInspectable: Bool { get { false } set {} }
  @discardableResult
  open func loadHTMLString(_ string: String, baseURL: URL?) -> WKNavigation? { nil }
  open func stopLoading() {}
  open func callAsyncJavaScript(
    _ functionBody: String, arguments: [String: Any] = [:], in frame: WKFrameInfo? = nil, in contentWorld: WKContentWorld,
    completionHandler: ((Result<Any, any Error>) -> Void)? = nil
  ) {}
}

// Darwin's Foundation constant (unavailable in swift-corelibs on Linux); the
// type-check substitutes this name in its copy of the sources.
public let LinuxShim_NSURLAuthenticationMethodServerTrust = "NSURLAuthenticationMethodServerTrust"
