package io.github.mihok.sherpa_webview

import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.ApplicationInfo
import android.graphics.Color
import android.net.Uri
import android.net.http.SslError
import android.os.Message
import android.util.Log
import android.view.View
import android.webkit.ClientCertRequest
import android.webkit.ConsoleMessage
import android.webkit.CookieManager
import android.webkit.GeolocationPermissions
import android.webkit.HttpAuthHandler
import android.webkit.JsPromptResult
import android.webkit.JsResult
import android.webkit.PermissionRequest
import android.webkit.RenderProcessGoneDetail
import android.webkit.SslErrorHandler
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import androidx.webkit.JavaScriptReplyProxy
import androidx.webkit.ProfileStore
import androidx.webkit.ScriptHandler
import androidx.webkit.WebMessageCompat
import androidx.webkit.WebSettingsCompat
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import io.flutter.plugin.platform.PlatformView
import java.io.ByteArrayInputStream

/**
 * One sandboxed WebView hosting the trusted shell page.
 *
 * - The shell is loaded with `loadDataWithBaseURL` under the virtual https
 *   origin [ShellPolicy.SHELL_ORIGIN]: a real, secure origin for the bridge's
 *   origin rule WITHOUT any request (nothing depends on interception, and no
 *   `WebViewAssetLoader` path handler exists that a View could fetch from).
 * - The bridge is `WebViewCompat.addWebMessageListener` restricted to that
 *   origin, so the object is injected only into frames of the shell origin
 *   (the View's opaque-origin iframe matches no rule); every message is
 *   re-checked for main frame + origin + size.
 * - No file/content access, geolocation, multiple windows, zoom, autofill,
 *   downloads, permission grants, JS dialogs, file choosers or third-party
 *   cookies; Safe Browsing and attribution reporting off; a per-server
 *   WebView profile; `blockNetworkLoads` unless the user consented to domains,
 *   and `shouldInterceptRequest` answers 403 for every non-consented origin.
 * - Every navigation is cancelled except the View's `about:srcdoc` subframe.
 */
// RequiresFeature: a WebView (and so a reply proxy or listener) only exists
// after init checked WEB_MESSAGE_LISTENER; lint cannot follow that.
@SuppressLint("SetJavaScriptEnabled", "RequiresFeature")
internal class McpAppPlatformView(
  context: Context,
  private val viewId: Long,
  private val config: NativeViewConfig,
  shellTemplate: String?,
  private val onShellMessage: (String) -> Unit,
  private val onEvent: (NativeViewEventKind, String?) -> Unit,
) : PlatformView {
  private val container = FrameLayout(context)
  private var webView: WebView? = null
  private var reply: JavaScriptReplyProxy? = null
  private val pending = ArrayDeque<String>()
  private var startScript: ScriptHandler? = null
  private val allowlist = ShellPolicy.OriginAllowlist(config.allowedOrigins)

  init {
    container.setBackgroundColor(Color.TRANSPARENT)
    val html = shellTemplate?.let { ShellPolicy.renderShell(it, config.csp) }
    when {
      !WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER) ->
        onEvent(NativeViewEventKind.LOAD_FAILED, "WebView too old (no WEB_MESSAGE_LISTENER)")
      html == null -> onEvent(NativeViewEventKind.LOAD_FAILED, "shell page missing")
      else -> try {
        create(context, html)
      } catch (e: RuntimeException) {
        // No WebView provider installed / disabled, profile errors, …
        Log.w(TAG, "WebView creation failed", e)
        onEvent(NativeViewEventKind.LOAD_FAILED, ShellPolicy.clip(e.javaClass.simpleName))
      }
    }
  }

  override fun getView(): View = container

  private fun create(context: Context, html: String) {
    val wv = WebView(context)
    // The profile must be set before anything else touches the WebView.
    val profileName = ShellPolicy.profileName(config.profileKey)
    var profileCookies: CookieManager? = null
    if (profileName != null && WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE)) {
      val profile = ProfileStore.getInstance().getOrCreateProfile(profileName)
      WebViewCompat.setProfile(wv, profileName)
      profileCookies = profile.cookieManager
    }
    harden(wv, context)
    // Opaque-origin frames cannot use cookies at all; this also stops
    // Set-Cookie from consented connect domains (third-party context).
    (profileCookies ?: CookieManager.getInstance()).setAcceptThirdPartyCookies(wv, false)
    profileCookies?.setAcceptCookie(false)

    WebViewCompat.addWebMessageListener(wv, ShellPolicy.BRIDGE_OBJECT, setOf(ShellPolicy.SHELL_ORIGIN)) {
        _, message, sourceOrigin, isMainFrame, replyProxy ->
      onBridgeMessage(message, sourceOrigin, isMainFrame, replyProxy)
    }
    if (WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
      // Best effort in every frame (WebRTC is not covered by CSP). Exposes
      // nothing; a View can still reach a fresh realm, see the README.
      startScript = WebViewCompat.addDocumentStartJavaScript(wv, NEUTER_WEBRTC, setOf("*"))
    }
    wv.webViewClient = Client()
    wv.webChromeClient = Chrome()
    wv.setDownloadListener { url, _, _, _, _ -> onEvent(NativeViewEventKind.NAVIGATION_BLOCKED, "download " + ShellPolicy.clip(url)) }
    container.addView(wv, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
    webView = wv
    wv.loadDataWithBaseURL(ShellPolicy.SHELL_BASE_URL, html, "text/html", "utf-8", null)
  }

  private fun harden(wv: WebView, context: Context) {
    with(wv.settings) {
      javaScriptEnabled = true
      domStorageEnabled = false
      allowFileAccess = false
      allowContentAccess = false
      @Suppress("DEPRECATION")
      allowFileAccessFromFileURLs = false
      @Suppress("DEPRECATION")
      allowUniversalAccessFromFileURLs = false
      setGeolocationEnabled(false)
      setSupportMultipleWindows(false)
      javaScriptCanOpenWindowsAutomatically = false
      mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
      mediaPlaybackRequiresUserGesture = true
      // No network at all unless the user consented to declared domains.
      blockNetworkLoads = allowlist.isEmpty
      cacheMode = WebSettings.LOAD_NO_CACHE
      setSupportZoom(false)
      builtInZoomControls = false
      displayZoomControls = false
      @Suppress("DEPRECATION")
      saveFormData = false
    }
    val s = wv.settings
    if (WebViewFeature.isFeatureSupported(WebViewFeature.SAFE_BROWSING_ENABLE)) {
      // The only document is our own static shell and every navigation is
      // cancelled, so Safe Browsing has nothing to protect; off avoids
      // lookups/reports about the virtual origin and View subresources.
      WebSettingsCompat.setSafeBrowsingEnabled(s, false)
    }
    if (WebViewFeature.isFeatureSupported(WebViewFeature.ATTRIBUTION_REGISTRATION_BEHAVIOR)) {
      WebSettingsCompat.setAttributionRegistrationBehavior(s, WebSettingsCompat.ATTRIBUTION_BEHAVIOR_DISABLED)
    }
    if (WebViewFeature.isFeatureSupported(WebViewFeature.WEB_AUTHENTICATION)) {
      WebSettingsCompat.setWebAuthenticationSupport(s, WebSettingsCompat.WEB_AUTHENTICATION_SUPPORT_NONE)
    }
    if (WebViewFeature.isFeatureSupported(WebViewFeature.PAYMENT_REQUEST)) {
      WebSettingsCompat.setPaymentRequestEnabled(s, false)
    }
    // Password managers / autofill never see or fill View content.
    wv.importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS
    wv.isSaveEnabled = false
    wv.isHapticFeedbackEnabled = false
    wv.overScrollMode = View.OVER_SCROLL_NEVER
    wv.setBackgroundColor(Color.TRANSPARENT)
    // A View's renderer is the first to go under memory pressure.
    wv.setRendererPriorityPolicy(WebView.RENDERER_PRIORITY_BOUND, true)
    if (config.debuggable && (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0) {
      // Process-wide; only ever in debuggable builds.
      WebView.setWebContentsDebuggingEnabled(true)
    }
  }

  private fun onBridgeMessage(message: WebMessageCompat, origin: Uri, isMainFrame: Boolean, proxy: JavaScriptReplyProxy) {
    val data = if (message.type == WebMessageCompat.TYPE_STRING) message.data else null
    if (data == null ||
      !ShellPolicy.acceptBridgeMessage(isMainFrame, origin.scheme, origin.host, origin.port, data.length, config.maxMessageChars)
    ) {
      onEvent(NativeViewEventKind.BRIDGE_REJECTED, ShellPolicy.clip("$origin main=$isMainFrame"))
      return
    }
    if (reply !== proxy) {
      reply = proxy
      while (pending.isNotEmpty()) proxy.postMessage(pending.removeFirst())
    }
    onShellMessage(data)
  }

  /** Native → shell. Before the shell's first message there is no proxy. */
  fun postToShell(message: String) {
    if (webView == null) return
    val proxy = reply
    if (proxy != null) {
      proxy.postMessage(message)
    } else if (pending.size < MAX_PENDING) {
      pending.addLast(message)
    }
  }

  override fun dispose() {
    val wv = webView ?: return
    webView = null
    reply = null
    pending.clear()
    startScript?.remove()
    startScript = null
    try {
      WebViewCompat.removeWebMessageListener(wv, ShellPolicy.BRIDGE_OBJECT)
    } catch (_: RuntimeException) {
    }
    wv.stopLoading()
    wv.webChromeClient = null
    container.removeView(wv)
    wv.destroy()
  }

  // onRenderProcessGone IS implemented below (returns true); the androidx
  // lint check does not see it on a Kotlin inner class.
  @SuppressLint("MissingOnRenderProcessGone")
  private inner class Client : WebViewClient() {
    override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
      val url = request.url.toString()
      if (!request.isForMainFrame && ShellPolicy.isAllowedSubframeUrl(url)) return false
      onEvent(NativeViewEventKind.NAVIGATION_BLOCKED, ShellPolicy.clip(url))
      return true
    }

    override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
      if (allowlist.allows(request.url.toString())) return null
      return WebResourceResponse(
        "text/plain", "utf-8", 403, "Forbidden", mapOf("Cache-Control" to "no-store"), ByteArrayInputStream(ByteArray(0)),
      )
    }

    override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
      if (request.isForMainFrame) onEvent(NativeViewEventKind.LOAD_FAILED, ShellPolicy.clip(error.description.toString()))
    }

    override fun onReceivedHttpAuthRequest(view: WebView, handler: HttpAuthHandler, host: String?, realm: String?) =
      handler.cancel()

    override fun onReceivedClientCertRequest(view: WebView, request: ClientCertRequest) = request.cancel()

    @SuppressLint("WebViewClientOnReceivedSslError")
    override fun onReceivedSslError(view: WebView, handler: SslErrorHandler, error: SslError) = handler.cancel()

    override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
      // MUST return true, or the app process is killed with the renderer.
      if (view === webView) {
        webView = null
        reply = null
        container.removeView(view)
        view.destroy()
        onEvent(NativeViewEventKind.RENDER_PROCESS_GONE, if (detail.didCrash()) "crashed" else "killed")
      }
      return true
    }
  }

  private inner class Chrome : WebChromeClient() {
    override fun onPermissionRequest(request: PermissionRequest) {
      // No permission is granted to Views in this version.
      request.deny()
      onEvent(NativeViewEventKind.PERMISSION_DENIED, request.resources.joinToString(","))
    }

    override fun onGeolocationPermissionsShowPrompt(origin: String?, callback: GeolocationPermissions.Callback) {
      callback.invoke(origin, false, false)
      onEvent(NativeViewEventKind.PERMISSION_DENIED, "geolocation")
    }

    override fun onCreateWindow(view: WebView, isDialog: Boolean, isUserGesture: Boolean, resultMsg: Message?): Boolean = false

    override fun onJsAlert(view: WebView, url: String?, message: String?, result: JsResult): Boolean {
      result.cancel()
      return true
    }

    override fun onJsConfirm(view: WebView, url: String?, message: String?, result: JsResult): Boolean {
      result.cancel()
      return true
    }

    override fun onJsPrompt(view: WebView, url: String?, message: String?, defaultValue: String?, result: JsPromptResult): Boolean {
      result.cancel()
      return true
    }

    override fun onJsBeforeUnload(view: WebView, url: String?, message: String?, result: JsResult): Boolean {
      result.confirm()
      return true
    }

    override fun onShowFileChooser(
      webView: WebView,
      filePathCallback: ValueCallback<Array<Uri>>,
      fileChooserParams: FileChooserParams,
    ): Boolean {
      filePathCallback.onReceiveValue(null)
      return true
    }

    /** Untrusted content stays out of logcat unless debugging. */
    override fun onConsoleMessage(consoleMessage: ConsoleMessage): Boolean = !config.debuggable
  }

  companion object {
    private const val TAG = "SherpaMcpApp"
    private const val MAX_PENDING = 16

    private const val NEUTER_WEBRTC =
      "(function(){try{['RTCPeerConnection','webkitRTCPeerConnection','RTCDataChannel','RTCIceTransport'," +
        "'RTCSctpTransport','RTCRtpSender','RTCRtpReceiver','RTCRtpTransceiver'].forEach(function(k){" +
        "try{Object.defineProperty(window,k,{value:undefined,writable:false,configurable:false});}catch(e){}});}catch(e){}})();"
  }
}
