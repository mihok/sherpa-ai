import 'dart:io' show InternetAddress;

import 'package:sherpa_net/sherpa_net.dart';

/// Pure validation for the provider form, shared by onboarding and settings
/// (and unit-tested without widgets).

/// The [UrlPolicy] a user-entered base URL is checked against.
///
/// Public HTTPS only, unless the user ticked "This is a server on my own
/// network": then http, private (RFC 1918 / ULA / .local) and loopback
/// addresses are allowed too. Link-local (incl. 169.254.169.254 cloud
/// metadata) is refused either way by the policy itself.
UrlPolicy baseUrlPolicy({required bool allowLocalNetwork}) => UrlPolicy(
      scope: allowLocalNetwork ? NetworkScope.loopback : NetworkScope.publicOnly,
      allowHttp: allowLocalNetwork,
    );

/// Outcome of checking the base URL field.
sealed class BaseUrlCheck {
  const BaseUrlCheck();
}

final class BaseUrlOk extends BaseUrlCheck {
  const BaseUrlOk(this.uri);
  final Uri uri;
}

final class BaseUrlError extends BaseUrlCheck {
  const BaseUrlError(this.message, {this.needsLocalNetworkOptIn = false});
  final String message;

  /// The URL would be fine with the "my own network" box ticked.
  final bool needsLocalNetworkOptIn;
}

/// Syntactic check (no DNS) with copy a person can act on.
BaseUrlCheck checkBaseUrl(String raw, {required bool allowLocalNetwork}) {
  final text = raw.trim();
  if (text.isEmpty) return const BaseUrlError('Enter the server address.');
  if (RegExp(r'\s').hasMatch(text)) return const BaseUrlError("Addresses can't contain spaces.");
  final withScheme = text.contains('://') ? text : 'https://$text';
  final Uri uri;
  try {
    uri = baseUrlPolicy(allowLocalNetwork: allowLocalNetwork).checkSyntax(withScheme);
  } on UrlPolicyViolation catch (v) {
    return _explain(v, withScheme, allowLocalNetwork: allowLocalNetwork);
  }
  final host = uri.host.toLowerCase();
  final isIp = InternetAddress.tryParse(host.replaceAll('[', '').replaceAll(']', '')) != null;
  if (!isIp && host != 'localhost' && !RegExp(r'^[^.]+(\.[^.]+)+$').hasMatch(host)) {
    return const BaseUrlError('Enter a full address, like https://api.example.com/v1.');
  }
  if (uri.hasQuery || uri.hasFragment) {
    return const BaseUrlError('Leave out ?query and #fragment parts; use the base address only.');
  }
  // The opt-in is for the user's own network. Plain http to a public IP
  // would send prompts unencrypted across the internet.
  final literal = InternetAddress.tryParse(uri.host.replaceAll('[', '').replaceAll(']', ''));
  if (uri.scheme == 'http' && literal != null && classify(literal) == AddressKind.public) {
    return const BaseUrlError(
      'This is a public internet address. Use https:// so your messages are encrypted on the way.',
    );
  }
  return BaseUrlOk(normalizeBaseUrl(uri));
}

/// Drops a trailing slash so `…/v1/` and `…/v1` are the same provider.
Uri normalizeBaseUrl(Uri uri) {
  var path = uri.path;
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  return uri.replace(path: path);
}

BaseUrlError _explain(UrlPolicyViolation v, String url, {required bool allowLocalNetwork}) {
  final r = v.reason;
  // Would the same URL pass with the opt-in? Then say so, instead of
  // making the user guess which rule they hit.
  if (!allowLocalNetwork) {
    try {
      baseUrlPolicy(allowLocalNetwork: true).checkSyntax(url);
      final why = r.contains('http')
          ? 'Plain http:// is only allowed for a server on your own network.'
          : 'This is a local address.';
      return BaseUrlError(
        '$why Tick "This is a server on my own network" to allow it, or use a public https:// address.',
        needsLocalNetworkOptIn: true,
      );
    } on UrlPolicyViolation {
      // Fails either way; explain the original reason below.
    }
  }
  if (r.contains('credentials')) {
    return const BaseUrlError('Remove the user name or password from the address. Put keys in the key field.');
  }
  if (r.contains('absolute')) return const BaseUrlError('Enter a full address, like https://api.example.com/v1.');
  if (r.contains('only https')) return const BaseUrlError('Use an https:// (or, on your own network, http://) address.');
  if (r.contains('linkLocal') || r.contains('reserved') || r.contains('multicast') || r.contains('unspecified')) {
    return const BaseUrlError("Sherpa won't connect to link-local or reserved addresses.");
  }
  return BaseUrlError('This address is not allowed: $r.');
}

/// Header names that carry credentials. Secrets belong in the API key field,
/// which goes to the Keychain/Keystore; extra headers are stored in plain
/// app data and show up in exports and logs.
const _credentialHeaderNames = {
  'authorization',
  'proxy-authorization',
  'cookie',
  'set-cookie',
  'x-api-key',
  'api-key',
  'apikey',
  'x-goog-api-key',
  'ocp-apim-subscription-key',
  'x-amz-security-token',
};

const _credentialFragments = [
  'token',
  'secret',
  'password',
  'passwd',
  'api-key',
  'apikey',
  'auth',
  'credential',
  'session',
  'cookie',
  'signature',
  'bearer',
  'private-key',
];

/// Headers Sherpa sets itself; overriding them breaks requests.
const _reservedHeaderNames = {
  'host',
  'content-length',
  'content-type',
  'transfer-encoding',
  'connection',
  'keep-alive',
  'upgrade',
  'te',
  'accept',
  'accept-encoding',
};

bool looksLikeCredentialHeader(String name) {
  final n = name.trim().toLowerCase().replaceAll('_', '-');
  return _credentialHeaderNames.contains(n) || _credentialFragments.any(n.contains);
}

/// Values that look like API keys even under an innocent header name.
bool looksLikeSecretValue(String value) {
  final v = value.trim();
  final lower = v.toLowerCase();
  return lower.startsWith('bearer ') ||
      lower.startsWith('basic ') ||
      RegExp(r'^(sk|rk|pk)-[A-Za-z0-9_\-]{8,}').hasMatch(v) ||
      RegExp(r'^hf_[A-Za-z0-9]{8,}').hasMatch(v) ||
      RegExp(r'^(ghp|gho|github_pat)_[A-Za-z0-9_]{8,}').hasMatch(v);
}

final _tchar = RegExp(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$");

/// Error for a header name, or null when acceptable.
String? validateHeaderName(String name, {required String keyFieldLabel}) {
  final n = name.trim();
  if (n.isEmpty) return 'Enter a header name.';
  if (!_tchar.hasMatch(n)) return 'Header names can only use letters, digits and - _ . ! # \$ % & \' * + ^ ` | ~.';
  if (looksLikeCredentialHeader(n)) {
    return 'This looks like a credential. Put it in the $keyFieldLabel field instead, '
        'so it is stored in the secure Keychain/Keystore.';
  }
  if (_reservedHeaderNames.contains(n.toLowerCase())) return 'Sherpa sets $n itself.';
  return null;
}

/// Error for a header value, or null when acceptable.
String? validateHeaderValue(String value, {required String keyFieldLabel}) {
  if (value.contains('\r') || value.contains('\n') || value.contains('\u0000')) {
    return 'Header values must be on one line.';
  }
  if (value.trim().isEmpty) return 'Enter a value.';
  if (looksLikeSecretValue(value)) {
    return 'This looks like a key. Put it in the $keyFieldLabel field instead, '
        'so it is stored in the secure Keychain/Keystore.';
  }
  return null;
}

/// One editable header row.
typedef HeaderRow = ({String name, String value});

/// Per-row errors (name, value); null entries are valid. Also flags
/// case-insensitive duplicates.
List<({String? name, String? value})> validateHeaders(List<HeaderRow> rows, {required String keyFieldLabel}) {
  final seen = <String>{};
  return [
    for (final r in rows)
      (
        name: validateHeaderName(r.name, keyFieldLabel: keyFieldLabel) ??
            (seen.add(r.name.trim().toLowerCase()) ? null : 'This header is already listed.'),
        value: validateHeaderValue(r.value, keyFieldLabel: keyFieldLabel),
      ),
  ];
}

/// Rows with both cells blank are ignored (a fresh "Add header" row).
List<HeaderRow> meaningfulRows(List<HeaderRow> rows) =>
    [for (final r in rows) if (r.name.trim().isNotEmpty || r.value.trim().isNotEmpty) r];
