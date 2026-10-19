import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding;
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:sherpa_auth/sherpa_auth.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../../../app_info.dart';

/// Sherpa's identity as an OAuth client, shared by MCP servers and
/// "Sign in with Hugging Face".
///
/// Redirect (PLAN §7 Q10): the reverse-DNS private-use scheme of the app id,
/// single slash (RFC 8252 §7.1). It must match what an authorization
/// server has on file exactly, so it never changes casually. Claimed https
/// and a Client ID Metadata Document wait for a Sherpa domain.
///
/// The deep-link scheme for "add this server" links ([McpAddLink]) is a
/// different scheme on purpose: on Android flutter_web_auth_2's callback
/// activity claims every URI of the OAuth scheme.
abstract final class SherpaOAuth {
  static const String callbackScheme = 'io.github.mihok.sherpa';
  static const String redirectUri = '$callbackScheme:/oauth/callback';

  static const OAuthClientIdentity identity = OAuthClientIdentity(
    clientName: 'Sherpa',
    redirectUri: redirectUri,
    clientUri: 'https://github.com/mihok/sherpa-ai',
    softwareId: 'io.github.mihok.sherpa',
    softwareVersion: AppInfo.version,
  );

  /// The public OAuth app registered at huggingface.co/settings/applications
  /// with [redirectUri] as its redirect. Builds pass it with
  /// `--dart-define=SHERPA_HF_OAUTH_CLIENT_ID=…`; without it the "Sign in
  /// with Hugging Face" button is hidden (pasting a token still works).
  static const String huggingFaceClientId = String.fromEnvironment('SHERPA_HF_OAUTH_CLIENT_ID');

  /// Interactive authorization only while the app is in the foreground
  /// (R02 Q4); the UI only calls it from a tap.
  static bool canInteract() {
    final s = WidgetsBinding.instance.lifecycleState;
    return s == null || s == AppLifecycleState.resumed;
  }
}

/// [BrowserLauncher] over flutter_web_auth_2 5.x: `ASWebAuthenticationSession`
/// on iOS, Chrome Auth Tab (Custom Tabs fallback plus the manifest's
/// `CallbackActivity`) on Android. Never an embedded WebView (RFC 8252 §8.12).
final class FlutterWebAuthBrowserLauncher implements BrowserLauncher {
  const FlutterWebAuthBrowserLauncher();

  @override
  Future<Uri> authorize(Uri url, {required String callbackScheme, bool ephemeral = false, Uri? redirectUri}) async {
    final https = callbackScheme == 'https';
    final String result;
    try {
      result = await FlutterWebAuth2.authenticate(
        url: url.toString(),
        callbackUrlScheme: callbackScheme,
        options: FlutterWebAuth2Options(
          preferEphemeral: ephemeral,
          httpsHost: https ? redirectUri?.host : null,
          httpsPath: https ? redirectUri?.path : null,
        ),
      );
    } on PlatformException catch (e) {
      if (e.code == 'CANCELED') throw AuthCancelledException();
      throw BrowserUnavailableException('the sign-in window could not be opened (${e.code})');
    } on ArgumentError {
      throw BrowserUnavailableException('the callback scheme is not valid');
    }
    final uri = Uri.tryParse(result);
    if (uri == null) throw BrowserUnavailableException('the sign-in window returned an unreadable address');
    return uri;
  }
}

/// A [SecretStore] that remembers what it read (and that a key is absent),
/// so per-request token lookups do not hit the Keychain / Keystore every
/// time. Writes and deletes go straight through and update the copy.
///
/// Only keys [shouldCache] accepts are cached (default: sherpa_auth's
/// server bindings and token sets, which only this store's owner writes);
/// anything another writer may change, such as an issuer's client
/// registration, is always read through.
final class CachingSecretStore implements SecretStore {
  CachingSecretStore(this._inner, {bool Function(String key)? shouldCache}) : _shouldCache = shouldCache ?? _authHotKeys;

  final SecretStore _inner;
  final bool Function(String key) _shouldCache;
  final Map<String, String?> _cache = {};

  static bool _authHotKeys(String key) => key.startsWith('oauth/servers/') || key.contains('/tokens/');

  @override
  Future<String?> read(String key) async {
    if (!_shouldCache(key)) return _inner.read(key);
    if (_cache.containsKey(key)) return _cache[key];
    final v = await _inner.read(key);
    _cache[key] = v;
    return v;
  }

  @override
  Future<void> write(String key, String value) async {
    await _inner.write(key, value);
    if (_shouldCache(key)) _cache[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    await _inner.delete(key);
    if (_shouldCache(key)) _cache[key] = null;
  }

  @override
  Future<List<String>> keys({String prefix = ''}) => _inner.keys(prefix: prefix);
}
