import 'package:meta/meta.dart';

/// An RFC 8628 device authorization in progress: the user visits
/// [verificationUri] on any device and enters [userCode] while the app
/// polls. Used for Hugging Face as a fallback when no browser redirect is
/// possible (R08 §8.3).
///
/// [deviceCode] is a secret (it is redeemed for tokens) and never appears
/// in [toString]; [userCode] is meant to be shown.
@immutable
final class DeviceAuthorization {
  const DeviceAuthorization({
    required this.issuer,
    required this.resource,
    required this.clientId,
    required this.tokenEndpoint,
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    required this.expiresAt,
    required this.interval,
    this.verificationUriComplete,
    this.scopes = const [],
    this.sendResource = false,
    this.revocationEndpoint,
  });

  final String issuer;
  final String resource;
  final String clientId;
  final Uri tokenEndpoint;
  final String deviceCode;
  final String userCode;

  /// Validated https URL to show (and optionally open).
  final Uri verificationUri;

  /// Includes the user code; suitable for a QR code.
  final Uri? verificationUriComplete;
  final DateTime expiresAt;

  /// Minimum polling interval (RFC 8628 §3.2, default 5 s).
  final Duration interval;
  final List<String> scopes;
  final bool sendResource;
  final Uri? revocationEndpoint;

  @override
  String toString() => 'DeviceAuthorization($issuer, user_code: $userCode, verify at $verificationUri, '
      'expires: ${expiresAt.toIso8601String()})';
}
