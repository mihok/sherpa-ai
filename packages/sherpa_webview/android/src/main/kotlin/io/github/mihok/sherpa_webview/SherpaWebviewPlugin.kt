package io.github.mihok.sherpa_webview

import android.annotation.SuppressLint
import android.content.Context
import android.util.Log
import androidx.webkit.ProfileStore
import androidx.webkit.WebStorageCompat
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/**
 * Entry point: the Pigeon host API, and the platform view factory for
 * `io.github.mihok.sherpa_webview/mcp_app`. All calls arrive on the main
 * thread (WebView is a main-thread API).
 */
class SherpaWebviewPlugin : FlutterPlugin, McpAppHostApi {
  private lateinit var context: Context
  private lateinit var assets: FlutterPlugin.FlutterAssets
  private var flutterApi: McpAppFlutterApi? = null
  private var shellTemplate: String? = null
  private val configs = HashMap<Long, NativeViewConfig>()
  private val views = HashMap<Long, McpAppPlatformView>()

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    context = binding.applicationContext
    assets = binding.flutterAssets
    McpAppHostApi.setUp(binding.binaryMessenger, this)
    flutterApi = McpAppFlutterApi(binding.binaryMessenger)
    binding.platformViewRegistry.registerViewFactory(VIEW_TYPE, Factory())
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    McpAppHostApi.setUp(binding.binaryMessenger, null)
    for (v in views.values) v.dispose()
    views.clear()
    configs.clear()
    flutterApi = null
  }

  override fun support(): NativeSupport {
    if (WebViewCompat.getCurrentWebViewPackage(context) == null) {
      return NativeSupport(false, "No WebView is installed or enabled.")
    }
    if (!WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)) {
      return NativeSupport(false, "The installed WebView is too old for interactive content.")
    }
    return NativeSupport(true, null)
  }

  override fun createView(config: NativeViewConfig) {
    configs[config.viewId] = config
  }

  override fun postToShell(viewId: Long, message: String) {
    views[viewId]?.postToShell(message)
  }

  override fun disposeView(viewId: Long) {
    configs.remove(viewId)
    views.remove(viewId)?.dispose()
  }

  /**
   * Wipes the server's WebView profile: cookies, storage and HTTP cache,
   * then deletes the profile (fails while a WebView still uses it; the
   * wipe has happened by then).
   */
  // RequiresFeature: MULTI_PROFILE is checked at the top; lint does not
  // follow it into the completion lambda.
  @SuppressLint("RequiresFeature")
  override fun clearProfile(profileKey: String, callback: (Result<Boolean>) -> Unit) {
    if (!WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE)) {
      callback(Result.success(false))
      return
    }
    val name = ShellPolicy.profileName(profileKey)
    if (name == null) {
      callback(Result.success(false))
      return
    }
    try {
      val store = ProfileStore.getInstance()
      val profile = store.getProfile(name)
      if (profile == null) {
        callback(Result.success(true))
        return
      }
      profile.cookieManager.removeAllCookies(null)
      profile.webStorage.deleteAllData()
      val finish = {
        val deleted = try {
          store.deleteProfile(name)
        } catch (_: IllegalStateException) {
          false // still in use by a live WebView
        }
        callback(Result.success(deleted))
      }
      if (WebViewFeature.isFeatureSupported(WebViewFeature.DELETE_BROWSING_DATA)) {
        WebStorageCompat.deleteBrowsingData(profile.webStorage) { finish() }
      } else {
        finish()
      }
    } catch (e: RuntimeException) {
      Log.w(TAG, "profile wipe failed", e)
      callback(Result.success(false))
    }
  }

  private fun shell(): String? {
    shellTemplate?.let { return it }
    return try {
      val path = assets.getAssetFilePathByName(SHELL_ASSET, PACKAGE)
      context.assets.open(path).bufferedReader(Charsets.UTF_8).use { it.readText() }.also { shellTemplate = it }
    } catch (e: Exception) {
      Log.e(TAG, "shell asset missing", e)
      null
    }
  }

  private fun emit(viewId: Long, kind: NativeViewEventKind, detail: String?) {
    flutterApi?.onViewEvent(viewId, NativeViewEvent(kind, detail)) {}
  }

  private inner class Factory : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context?, id: Int, args: Any?): PlatformView {
      val viewId = ((args as? Map<*, *>)?.get("viewId") as? Number)?.toLong() ?: -1L
      val config = configs[viewId] ?: NativeViewConfig(viewId, ShellPolicy.DEFAULT_CSP, emptyList(), "", false, 0)
      val view = McpAppPlatformView(
        context = context ?: this@SherpaWebviewPlugin.context,
        viewId = viewId,
        config = config,
        // An unknown id gets no shell at all (fail closed).
        shellTemplate = if (configs.containsKey(viewId)) shell() else null,
        onShellMessage = { m -> flutterApi?.onShellMessage(viewId, m) {} },
        onEvent = { kind, detail -> emit(viewId, kind, detail) },
      )
      views.put(viewId, view)?.dispose()
      return view
    }
  }

  private companion object {
    const val TAG = "SherpaMcpApp"
    const val VIEW_TYPE = "io.github.mihok.sherpa_webview/mcp_app"
    const val PACKAGE = "sherpa_webview"
    const val SHELL_ASSET = "assets/mcp_app_shell.html"
  }
}
