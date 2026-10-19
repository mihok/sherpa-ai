/// Opens a URL the user confirmed OUTSIDE the app's own views: Custom Tabs
/// (Android) or SFSafariViewController (iOS), which the app and the model
/// cannot inspect (client/elicitation.md), or the external browser.
library;

import 'package:url_launcher/url_launcher.dart' as launcher;

/// Where a confirmed URL opens.
enum McpUrlTarget {
  /// Custom Tabs / SFSafariViewController.
  inAppBrowser,

  /// The default browser app.
  externalBrowser,
}

abstract interface class McpUrlOpener {
  /// Opens [url]; false when nothing could open it.
  Future<bool> open(Uri url, {McpUrlTarget target = McpUrlTarget.inAppBrowser});
}

/// [McpUrlOpener] over `url_launcher`. Only `https`/`http` URLs are
/// opened; anything else (app schemes, `javascript:`, `file:`…) is refused
/// here as well as by the callers.
///
/// On Android, `inAppBrowserView` falls back to an in-app WebView when no
/// Custom Tabs provider is visible, and a WebView is exactly what the spec
/// rules out (the app could inspect it). So the in-app browser is used only
/// when the platform reports Custom Tabs support (Android 11+ needs a
/// `<queries>` entry for `android.support.customtabs.action.CustomTabsService`
/// in the manifest); otherwise the URL opens in the browser app.
final class UrlLauncherOpener implements McpUrlOpener {
  const UrlLauncherOpener();

  @override
  Future<bool> open(Uri url, {McpUrlTarget target = McpUrlTarget.inAppBrowser}) async {
    final scheme = url.scheme.toLowerCase();
    if ((scheme != 'https' && scheme != 'http') || !url.hasAuthority) return false;
    try {
      var mode = switch (target) {
        McpUrlTarget.inAppBrowser => launcher.LaunchMode.inAppBrowserView,
        McpUrlTarget.externalBrowser => launcher.LaunchMode.externalApplication,
      };
      if (mode == launcher.LaunchMode.inAppBrowserView && !await launcher.supportsLaunchMode(mode)) {
        mode = launcher.LaunchMode.externalApplication;
      }
      return await launcher.launchUrl(url, mode: mode);
    } on Object {
      return false;
    }
  }
}
