import 'dart:async';

import 'package:flutter/foundation.dart' show immutable;
import 'package:http/http.dart' as http;
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_data/sherpa_data.dart' show DocumentCollections;
import 'package:sherpa_hub/sherpa_hub.dart';

import '../../../services/downloads/record_store.dart';

/// The signed-in Hugging Face user, as `whoami-v2` described them. A
/// display profile only — the token itself lives in the [SecretStore].
@immutable
final class HubProfile {
  const HubProfile({required this.name, this.fullName, this.orgs = const [], this.tokenRole, this.isPro});

  factory HubProfile.fromWhoAmI(HubWhoAmI w) =>
      HubProfile(name: w.name, fullName: w.fullName, orgs: w.orgs, tokenRole: w.tokenRole, isPro: w.isPro);

  factory HubProfile.fromJson(JsonMap j) => HubProfile(
        name: j.req<String>('name'),
        fullName: j.opt<String>('fullName'),
        orgs: [for (final o in j.opt<List<Object?>>('orgs') ?? const <Object?>[]) '$o'],
        tokenRole: j.opt<String>('tokenRole'),
        isPro: j.opt<bool>('isPro'),
      );

  final String name;
  final String? fullName;
  final List<String> orgs;

  /// `read`, `write` or `fineGrained`.
  final String? tokenRole;
  final bool? isPro;

  String get tokenRoleLabel => switch (tokenRole) {
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
      });
}

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
final class HubAccount {
  HubAccount({required SecretStore secrets, required ModelRecordStore store, required http.Client client, Uri? baseUri})
      : _secrets = secrets,
        _store = store,
        _client = client,
        _baseUri = baseUri;

  static const String tokenKey = 'hub/hf/token';

  final SecretStore _secrets;
  final ModelRecordStore _store;
  final http.Client _client;
  final Uri? _baseUri;
  final StreamController<HubProfile?> _changes = StreamController.broadcast();
  String? _token;
  bool _tokenLoaded = false;
  HubProfile? _profile;
  bool _profileLoaded = false;

  Stream<HubProfile?> get changes => _changes.stream;

  /// For [HfHubClient.tokenProvider]: read once from the secure store, then
  /// kept in memory (the client asks on every request).
  Future<String?> token() async {
    if (_tokenLoaded) return _token;
    final t = await _secrets.read(tokenKey);
    _token = t;
    _tokenLoaded = true;
    return t;
  }

  Future<HubProfile?> profile() async {
    if (_profileLoaded) return _profile;
    final doc = await _store.get(DocumentCollections.preferences, ModelPreferenceIds.hubAccount);
    final t = await token();
    _profile = t == null || doc == null ? null : HubProfile.fromJson(doc);
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

  Future<void> signOut() async {
    await _secrets.delete(tokenKey);
    await _store.delete(DocumentCollections.preferences, ModelPreferenceIds.hubAccount);
    _token = null;
    _tokenLoaded = true;
    _profile = null;
    _profileLoaded = true;
    _changes.add(null);
  }

  Future<void> dispose() => _changes.close();
}
