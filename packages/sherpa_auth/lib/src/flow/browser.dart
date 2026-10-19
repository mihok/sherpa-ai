/// The one platform piece of the flow: the system authentication session.
///
/// The app implements it with `flutter_web_auth_2` (iOS
/// `ASWebAuthenticationSession`, Android Auth Tab / Custom Tabs). Never an
/// embedded WebView (RFC 8252 §8.12) and never a shell (SBP26).
///
/// Contract:
/// - [authorize] opens [url] and completes with the **full** callback URL
///   (query included) once the browser hits [callbackScheme] (for a
///   claimed-https redirect, `https` plus the host and path of
///   [redirectUri]).
/// - The user closing the session throws `AuthCancelledException`; no
///   usable browser throws `BrowserUnavailableException`.
/// - [ephemeral] asks for a non-persistent session (no shared cookies).
///
/// The URL has already passed the network policy (https only, no
/// `javascript:`/`data:`), and the pending flow has been persisted.
abstract interface class BrowserLauncher {
  Future<Uri> authorize(Uri url, {required String callbackScheme, bool ephemeral = false, Uri? redirectUri});
}

/// Whether the app is in the foreground and the call stems from a user
/// gesture. Interactive authorization is refused otherwise (R02 Q4).
typedef InteractionGate = bool Function();
