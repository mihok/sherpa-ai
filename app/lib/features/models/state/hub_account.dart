import 'dart:async';

import 'package:flutter/foundation.dart' show immutable;
import 'package:http/http.dart' as http;
import 'package:sherpa_auth/sherpa_auth.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_data/sherpa_data.dart' show DocumentCollections;
import 'package:sherpa_hub/sherpa_hub.dart';

import '../../../services/downloads/record_store.dart';
import '../../../services/mcp/auth/oauth_platform.dart';

/// The signed-in Hugging Face user, as `whoami-v2` described them. A
/// display profile only — the token itself lives in the [SecretStore].
@immutable
final class HubProfile {
  const HubProfile({
    required this.name,
    this.fullName,
    this.orgs = const [],
    this.tokenRole,
    this.isPro,
    this.method = HubSignInMethod.token,
    this.scopes = const [],
  });

  factory HubProfile.fromWhoAmI(HubWhoAmI w, {HubSignInMethod method = HubSignInMethod.token, List<String> scopes = const []}) =>
      HubProfile(
        name: w.name,
        fullName: w.fullName,
        orgs: w.orgs,
        tokenRole: w.tokenRole,
        isPro: w.isPro,
        method: method,
        scopes: scopes,
      );

  factory HubProfile.fromJson(JsonMap j) => HubProfile(
        name: j.req<String>('name'),
        fullName: j.opt<String>('fullName'),
        orgs: [for (final o in j.opt<List<Object?>>('orgs') ?? const <Object?>[]) '$o'],
        tokenRole: j.opt<String>('tokenRole'),
        isPro: j.opt<bool>('isPro'),
        method: HubSignInMethod.values.where((m) => m.name == j['method']).firstOrNull ?? HubSignInMethod.token,
        scopes: [for (final s in j.opt<List<Object?>>('scopes') ?? const <Object?>[]) '$s'],
      );

  final String name;
  final String? fullName;
  final List<String> orgs;

  /// `read`, `write` or `fineGrained`.
  final String? tokenRole;
  final bool? isPro;

  /// A pasted access token, or "Sign in with Hugging Face" (OAuth).
  final HubSignInMethod method;

  /// What the OAuth sign-in granted (empty for a pasted token).
  final List<String> scopes;

  String get tokenRoleLabel => method == HubSignInMethod.oauth ? 'Signed in with Hugging Face' : switch (tokenRole) {
        'read' => 'Read token',
        'write' => 'Write token',
        'fineGrained' => 'Fine-grained token',
        final r? => '$r token',
        null => 'Access token',
      };

  JsonMap toJson() => compact({
        'name': name,
        'fullName': fullName,
        'orgs': orgs,
        'tokenRole': tokenRole,
        'isPro': isPro,
        'method': method == HubSignInMethod.token ? null : method.name,
        'scopes': scopes.isEmpty ? null : scopes,
      });
}

enum HubSignInMethod { token, oauth }

/// Why sign-in failed, in words for the form.
final class HubSignInException implements Exception {
  const HubSignInException(this.message);

  final String message;

  @override
  String toString() => 'HubSignInException: $message';
}

/// The user's Hugging Face token.
///
/// - Stored only in the [SecretStore] (Keychain / Android Keystore) under
///   [tokenKey]; never in the database, logs or download records.
/// - Validated with `GET /api/whoami-v2` before it is saved: the Hub
///   silently ignores an invalid token on public reads, so without the
///   check a typo would look like "signed in" until the first gated
///   download fails (R08 §1, §7.1).
/// - Sent only to huggingface.co, and only from this process: [HfHubClient]
///   attaches it per request on the Hub's own origin and never to the CDN
///   (R08 §5.5 step 2); Hub-origin file bytes go through
///   `InProcessTransferBackend`, never background_downloader, whose task
///   records (headers included) the plugin persists outside the Keychain.
///
/// Signing in doubles the anonymous rate limits and unlocks gated repos
/// whose terms the user accepted (R08 §6, §7.3).
///
/// "Sign in with Hugging Face" ([signInWithBrowser], R08 §8) is offered
/// when the build has an OAuth client id ([SherpaOAuth.huggingFaceClientId])
/// or a [HuggingFaceOAuth] is injected. Its tokens live in the
/// [SecretStore] through sherpa_auth (refreshed when HF issues refresh
/// tokens); a pasted token, when there is one, wins.
final class HubAccount {
  HubAccount({
    required SecretStore secrets,
    required ModelRecordStore store,
    required http.Client client,
    Uri? baseUri,
    HuggingFaceOAuth? oauth,
    String? oauthClientId,
    BrowserLauncher? browser,
    Clock clock = const SystemClock(),
  })  : _secrets = secrets,
        _store = store,
        _client = client,
        _baseUri = baseUri,
        _clock = clock,
        _oauth = oauth,
        _oauthClientId = oauthClientId ?? SherpaOAuth.huggingFaceClientId,
        _browser = browser;

  static const String tokenKey = 'hub/hf/token';

  final SecretStore _secrets;
  final ModelRecordStore _store;
  final http.Client _client;
  final Uri? _baseUri;
  final Clock _clock;
  HuggingFaceOAuth? _oauth;
  final String _oauthClientId;
  final BrowserLauncher? _browser;
  final StreamController<HubProfile?> _changes = StreamController.broadcast();
  String? _token;
  bool _tokenLoaded = false;
  HubProfile? _profile;
  bool _profileLoaded = false;
  (String, DateTime?)? _oauthToken;

  Stream<HubProfile?> get changes => _changes.stream;

  /// Why "Sign in with Hugging Face" is not offered, for the screen.
  static const String browserSignInUnavailable =
      "Sign in with Hugging Face isn't set up in this build: it needs Sherpa's Hugging Face OAuth app id "
      '(SHERPA_HF_OAUTH_CLIENT_ID). Paste an access token instead.';

  /// The OAuth flow, when this build can offer it.
  HuggingFaceOAuth? get oauth {
    final o = _oauth;
    if (o != null) return o;
    if (_oauthClientId.isEmpty) return null;
    return _oauth = HuggingFaceOAuth(
      oauth: OAuthClient(
        store: SecretAuthStateStore(_secrets),
        browser: _browser ?? const FlutterWebAuthBrowserLauncher(),
        identity: SherpaOAuth.identity,
        httpClient: _client,
        clock: _clock,
        canInteract: SherpaOAuth.canInteract,
      ),
      clientId: _oauthClientId,
      hubUri: _baseUri,
    );
  }

  bool get canSignInWithBrowser => oauth != null;

  /// For [HfHubClient.tokenProvider]: the pasted token (read once from the
  /// secure store, then kept in memory: the client asks on every request),
  /// else the OAuth access token, refreshed shortly before it expires.
  Future<String?> token() async {
    if (!_tokenLoaded) {
      _token = await _secrets.read(tokenKey);
      _tokenLoaded = true;
    }
    final pasted = _token;
    if (pasted != null) return pasted;
    final o = oauth;
    if (o == null) return null;
    final cached = _oauthToken;
    final now = _clock.now();
    if (cached != null && (cached.$2 == null || now.isBefore(cached.$2!.subtract(const Duration(seconds: 90))))) {
      return cached.$1;
    }
    try {
      final t = await o.accessToken();
      if (t == null) {
        _oauthToken = null;
        return null;
      }
      final set = await o.tokens();
      _oauthToken = (t, set?.expiresAt);
      return t;
    } on AuthException {
      return null; // Offline refresh: public files still download.
    }
  }

  Future<HubProfile?> profile() async {
    if (_profileLoaded) return _profile;
    final doc = await _store.get(DocumentCollections.preferences, ModelPreferenceIds.hubAccount);
    final p = doc == null ? null : HubProfile.fromJson(doc);
    // An OAuth sign-in counts while its grant is stored, even when the
    // access token needs a refresh that cannot happen offline right now.
    final signedIn = p == null
        ? false
        : p.method == HubSignInMethod.oauth
            ? (_token != null || await oauth?.tokens() != null || await token() != null)
            : await token() != null;
    _profile = signedIn ? p : null;
    _profileLoaded = true;
    return _profile;
  }

  /// Validates [rawToken] with whoami and stores it. Throws
  /// [HubSignInException] with a user-facing reason.
  Future<HubProfile> signIn(String rawToken) async {
    final t = rawToken.trim();
    if (t.isEmpty) throw const HubSignInException('Paste a token first.');
    if (t.contains(RegExp(r'\s'))) throw const HubSignInException('A token has no spaces. Copy it again.');
    final probe = HfHubClient(
      httpClient: _client,
      tokenProvider: () async => t,
      baseUri: _baseUri,
      retryPolicy: const HubRetryPolicy(maxRetries: 1),
    );
    final HubWhoAmI who;
    try {
      who = await probe.whoami();
    } on HubUnauthorizedException {
      throw const HubSignInException('Hugging Face rejected this token. Check that you copied all of it.');
    } on HubRepoNotFoundException {
      throw const HubSignInException('Hugging Face rejected this token. Check that you copied all of it.');
    } on HubRateLimitedException {
      throw const HubSignInException('Hugging Face is rate limiting requests. Try again in a minute.');
    } on HubNetworkException {
      throw const HubSignInException("Couldn't reach huggingface.co. Check your connection.");
    } on HubException catch (e) {
      throw HubSignInException('Hugging Face answered: ${e.message}');
    }
    final profile = HubProfile.fromWhoAmI(who);
    await _secrets.write(tokenKey, t);
    await _store.put(DocumentCollections.preferences, ModelPreferenceIds.hubAccount, profile.toJson());
    _token = t;
    _tokenLoaded = true;
    _profile = profile;
    _profileLoaded = true;
    _changes.add(profile);
    return profile;
  }

  /// "Sign in with Hugging Face": the system browser (never a WebView),
  /// PKCE, then whoami with the new token. Call only from a tap, after the
  /// consent sheet. Throws [HubSignInException] with a user-facing reason.
  Future<HubProfile> signInWithBrowser() async {
    final o = oauth;
    if (o == null) throw const HubSignInException(browserSignInUnavailable);
    final TokenSet tokens;
    try {
      tokens = await o.signIn();
    } on AuthCancelledException {
      throw const HubSignInException('Sign-in was cancelled.');
    } on BrowserUnavailableException {
      throw const HubSignInException('No browser is available to sign in. Paste an access token instead.');
    } on AuthorizationDeniedException {
      throw const HubSignInException('Access was not granted on the Hugging Face page.');
    } on AuthNetworkException {
      throw const HubSignInException("Couldn't reach huggingface.co. Check your connection.");
    } on InteractiveAuthNotAllowedException {
      throw const HubSignInException('Sign-in can only start while Sherpa is open.');
    } on AuthException catch (e) {
      throw HubSignInException('Hugging Face sign-in failed: ${e.message}');
    }
    final probe = HfHubClient(
      httpClient: _client,
      tokenProvider: () async => tokens.accessToken,
      baseUri: _baseUri,
      retryPolicy: const HubRetryPolicy(maxRetries: 1),
    );
    final HubWhoAmI who;
    try {
      who = await probe.whoami();
    } on HubException catch (e) {
      await o.signOut();
      throw HubSignInException(e is HubNetworkException
          ? "Couldn't reach huggingface.co. Check your connection."
          : 'Hugging Face did not accept the sign-in. Try again.');
    }
    final profile = HubProfile.fromWhoAmI(who, method: HubSignInMethod.oauth, scopes: tokens.effectiveScopes);
    // One account at a time: the browser sign-in replaces a pasted token.
    await _secrets.delete(tokenKey);
    await _store.put(DocumentCollections.preferences, ModelPreferenceIds.hubAccount, profile.toJson());
    _token = null;
    _tokenLoaded = true;
    _oauthToken = (tokens.accessToken, tokens.expiresAt);
    _profile = profile;
    _profileLoaded = true;
    _changes.add(profile);
    return profile;
  }

  Future<void> signOut() async {
    await _secrets.delete(tokenKey);
    final o = oauth;
    if (o != null) {
      try {
        await o.signOut();
      } on Object {
        // Nothing stored for OAuth, or the store is unavailable.
      }
    }
    await _store.delete(DocumentCollections.preferences, ModelPreferenceIds.hubAccount);
    _token = null;
    _tokenLoaded = true;
    _oauthToken = null;
    _profile = null;
    _profileLoaded = true;
    _changes.add(null);
  }

  Future<void> dispose() => _changes.close();
}
