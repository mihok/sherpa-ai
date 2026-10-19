import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';

/// URL-safe base64 of [bytes] CSPRNG bytes, without padding.
String randomUrlSafe(Random random, {int bytes = 32}) {
  final b = List<int>.generate(bytes, (_) => random.nextInt(256));
  return base64Url.encode(b).replaceAll('=', '');
}

/// A PKCE verifier/challenge pair (RFC 7636). Only `S256` is ever used
/// (SC26 L53); `plain` is not implemented.
@immutable
final class Pkce {
  const Pkce._(this.verifier, this.challenge);

  /// Verifier from 32 random bytes → 43 characters of `[A-Za-z0-9-_]`,
  /// the minimum length RFC 7636 §4.1 allows (and that HF enforces, R08
  /// §8.2). [random] must be `Random.secure()` in production.
  factory Pkce.generate(Random random) => Pkce.fromVerifier(randomUrlSafe(random));

  /// Throws [ArgumentError] unless [verifier] is 43–128 unreserved chars.
  factory Pkce.fromVerifier(String verifier) {
    if (!isValidVerifier(verifier)) {
      throw ArgumentError.value('«redacted»', 'verifier', 'must be 43-128 characters of [A-Za-z0-9-._~]');
    }
    return Pkce._(verifier, challengeFor(verifier));
  }

  static const String method = 'S256';

  final String verifier;
  final String challenge;

  static final RegExp _verifier = RegExp(r'^[A-Za-z0-9\-._~]{43,128}$');

  static bool isValidVerifier(String v) => _verifier.hasMatch(v);

  /// `BASE64URL(SHA256(ASCII(code_verifier)))` without padding (RFC 7636 §4.2).
  static String challengeFor(String verifier) =>
      base64Url.encode(sha256.convert(ascii.encode(verifier)).bytes).replaceAll('=', '');

  @override
  String toString() => 'Pkce(S256)';
}
