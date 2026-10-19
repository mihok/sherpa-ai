import Flutter
import UIKit
import WebKit

/// One sandboxed WKWebView hosting the trusted shell page.
///
/// - `WKWebsiteDataStore.nonPersistent()` per view: nothing reaches disk and
///   nothing is shared between views or servers.
/// - The shell is `loadHTMLString` under the virtual https origin
///   `ShellPolicy.shellOrigin` (no request; `.invalid` never resolves). No
///   file URLs are ever loaded, so file-URL access settings never apply.
/// - The message handler exists ONLY in a private `WKContentWorld`, fed by a
///   user script injected into the MAIN frame only; page-world scripts (the
///   shell and every View frame) cannot see it. Every message is re-checked
///   for main frame, bridge world, shell origin and size.
/// - A `WKContentRuleList` blocks every load except local schemes, the
///   shell document and the consented origins (all loads when none).
/// - Navigation: only the initial shell load and the View's `about:srcdoc`
///   subframe; no new windows, downloads, media capture, motion sensors or
///   JS dialogs.
///
/// Main-actor isolated (WebKit is), and therefore Sendable; Flutter's
/// nonisolated entry points hop with `MainActor.assumeIsolated` (they are
/// always called on the main thread).
///
/// UNVERIFIED against the real iOS SDK and on a device: written from
/// Apple's documentation, type-checked on Linux against stand-in modules.
@MainActor
final class McpAppPlatformView: NSObject, FlutterPlatformView, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
  private let container: UIView
  private let config: NativeViewConfig
  private let onShellMessage: (String) -> Void
  private let onEvent: (NativeViewEventKind, String?) -> Void
  private let bridgeWorld = WKContentWorld.world(name: ShellPolicy.bridgeWorldName)
  private var webView: WKWebView?
  private var expectingShellLoad = false
  private var shellReady = false
  private var pending: [String] = []
  private var disposed = false

  init(
    frame: CGRect,
    config: NativeViewConfig,
    shellTemplate: String?,
    onShellMessage: @escaping (String) -> Void,
    onEvent: @escaping (NativeViewEventKind, String?) -> Void
  ) {
    container = UIView(frame: frame)
    container.backgroundColor = .clear
    self.config = config
    self.onShellMessage = onShellMessage
    self.onEvent = onEvent
    super.init()
    guard let template = shellTemplate, let html = ShellPolicy.renderShell(template, csp: config.csp) else {
      onEvent(.loadFailed, "shell page missing")
      return
    }
    let rules = ShellPolicy.contentRules(allowedOrigins: config.allowedOrigins)
    WKContentRuleListStore.default().compileContentRuleList(
      forIdentifier: ShellPolicy.ruleListIdentifier(rules),
      encodedContentRuleList: rules
    ) { [weak self] list, error in
      let failure = error.map { ShellPolicy.clip("content rules: \($0)") }
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          guard let self = self, !self.disposed else { return }
          // Fail closed: without the rule list the view is never created.
          guard let list = list, failure == nil else {
            self.onEvent(.loadFailed, failure ?? "content rules failed to compile")
            return
          }
          self.create(html: html, rules: list)
        }
      }
    }
  }

  nonisolated func view() -> UIView { container }

  private func create(html: String, rules: WKContentRuleList) {
    let cfg = WKWebViewConfiguration()
    cfg.websiteDataStore = .nonPersistent()
    cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
    // Safe Browsing equivalent: the only document is our static shell and
    // every navigation is cancelled; no lookups about View subresources.
    cfg.preferences.isFraudulentWebsiteWarningEnabled = false
    if #available(iOS 15.4, *) {
      cfg.preferences.isElementFullscreenEnabled = false
    }
    cfg.defaultWebpagePreferences.allowsContentJavaScript = true
    cfg.mediaTypesRequiringUserActionForPlayback = .all
    cfg.allowsAirPlayForMediaPlayback = false
    cfg.allowsPictureInPictureMediaPlayback = false
    cfg.dataDetectorTypes = []
    cfg.limitsNavigationsToAppBoundDomains = false

    let ucc = cfg.userContentController
    ucc.add(rules)
    ucc.add(WeakScriptMessageHandler(self), contentWorld: bridgeWorld, name: ShellPolicy.handlerName)
    ucc.addUserScript(WKUserScript(
      source: ShellPolicy.bridgeRelayScript, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: bridgeWorld))
    ucc.addUserScript(WKUserScript(
      source: ShellPolicy.neuterWebRTC, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))

    let wv = WKWebView(frame: container.bounds, configuration: cfg)
    wv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    wv.navigationDelegate = self
    wv.uiDelegate = self
    wv.isOpaque = false
    wv.backgroundColor = .clear
    wv.scrollView.backgroundColor = .clear
    wv.scrollView.bounces = false
    wv.scrollView.contentInsetAdjustmentBehavior = .never
    wv.allowsLinkPreview = false
    wv.allowsBackForwardNavigationGestures = false
    if #available(iOS 16.4, *) {
      wv.isInspectable = config.debuggable
    }
    container.addSubview(wv)
    webView = wv
    expectingShellLoad = true
    wv.loadHTMLString(html, baseURL: URL(string: ShellPolicy.shellBaseURL))
  }

  // MARK: Bridge

  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    let origin = message.frameInfo.securityOrigin
    guard message.world.name == bridgeWorld.name,
      let body = message.body as? String,
      ShellPolicy.acceptBridgeMessage(
        isMainFrame: message.frameInfo.isMainFrame, scheme: origin.protocol, host: origin.host,
        port: origin.port, length: body.utf16.count, maxChars: config.maxMessageChars)
    else {
      onEvent(.bridgeRejected, ShellPolicy.clip("\(message.frameInfo.securityOrigin.host) main=\(message.frameInfo.isMainFrame)"))
      return
    }
    if !shellReady {
      shellReady = true
      let queued = pending
      pending.removeAll()
      queued.forEach(deliver)
    }
    onShellMessage(body)
  }

  /// Native → shell; queued until the shell's first message.
  func postToShell(_ message: String) {
    guard webView != nil else { return }
    if shellReady {
      deliver(message)
    } else if pending.count < 16 {
      pending.append(message)
    }
  }

  private func deliver(_ message: String) {
    // The payload is an argument, never spliced into source.
    webView?.callAsyncJavaScript(
      "if (window.__sherpaShell) { window.__sherpaShell.receive(m); }",
      arguments: ["m": message], in: nil, in: .page, completionHandler: nil)
  }

  func dispose() {
    guard !disposed else { return }
    disposed = true
    pending.removeAll()
    guard let wv = webView else { return }
    webView = nil
    wv.configuration.userContentController.removeScriptMessageHandler(forName: ShellPolicy.handlerName, contentWorld: bridgeWorld)
    wv.configuration.userContentController.removeAllUserScripts()
    wv.stopLoading()
    wv.navigationDelegate = nil
    wv.uiDelegate = nil
    wv.removeFromSuperview()
  }

  // MARK: Navigation
  //
  // Handler types match the iOS 26 SDK exactly (`@MainActor @Sendable`). In
  // Swift 5 mode the compiler would also accept the unannotated form as a
  // preconcurrency witness, but in Swift 6 mode that form stops matching and
  // WebKit silently stops calling these methods (only a near-miss warning),
  // which would drop the navigation lockdown and the permission denials.

  func webView(
    _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
  ) {
    let url = navigationAction.request.url?.absoluteString ?? ""
    guard let target = navigationAction.targetFrame else {
      // window.open / target=_blank: never a new web view.
      decisionHandler(.cancel)
      onEvent(.navigationBlocked, ShellPolicy.clip(url))
      return
    }
    if target.isMainFrame {
      if expectingShellLoad && url == ShellPolicy.shellBaseURL {
        expectingShellLoad = false
        decisionHandler(.allow)
        return
      }
    } else if ShellPolicy.isAllowedSubframeURL(url) {
      decisionHandler(.allow)
      return
    }
    decisionHandler(.cancel)
    onEvent(.navigationBlocked, ShellPolicy.clip(url))
  }

  func webView(
    _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
    decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
  ) {
    // Anything WebKit would download instead of display is refused.
    decisionHandler(navigationResponse.canShowMIMEType ? .allow : .cancel)
  }

  func webView(
    _ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
      completionHandler(.performDefaultHandling, nil)
    } else {
      // No HTTP auth or client certificates for Views.
      completionHandler(.cancelAuthenticationChallenge, nil)
    }
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    onEvent(.loadFailed, ShellPolicy.clip(error.localizedDescription))
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    guard webView === self.webView else { return }
    dispose()
    onEvent(.renderProcessGone, "WebContent process terminated")
  }

  // MARK: UI

  func webView(
    _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    onEvent(.navigationBlocked, ShellPolicy.clip(navigationAction.request.url?.absoluteString ?? "window"))
    return nil
  }

  @available(iOS 15.0, *)
  func webView(
    _ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
    type: WKMediaCaptureType, decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
  ) {
    // No permission is granted to Views in this version.
    decisionHandler(.deny)
    onEvent(.permissionDenied, "media capture")
  }

  @available(iOS 15.0, *)
  func webView(
    _ webView: WKWebView, requestDeviceOrientationAndMotionPermissionFor origin: WKSecurityOrigin,
    initiatedByFrame frame: WKFrameInfo, decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
  ) {
    decisionHandler(.deny)
    onEvent(.permissionDenied, "motion")
  }

  func webView(
    _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
    completionHandler: @escaping @MainActor @Sendable () -> Void
  ) {
    completionHandler()
  }

  func webView(
    _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
    completionHandler: @escaping @MainActor @Sendable (Bool) -> Void
  ) {
    completionHandler(false)
  }

  func webView(
    _ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
    initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (String?) -> Void
  ) {
    completionHandler(nil)
  }
}

/// WKUserContentController retains its handlers strongly.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
  private weak var target: WKScriptMessageHandler?

  init(_ target: WKScriptMessageHandler) {
    self.target = target
    super.init()
  }

  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    target?.userContentController(userContentController, didReceive: message)
  }
}
