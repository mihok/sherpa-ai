/// URL policy for `ui/open-link` (R03 §11.6 item 5).
library;

import 'package:meta/meta.dart';

/// Why a link was refused before the user was asked.
enum LinkRefusal { malformed, tooLong, scheme, credentials, host }

/// Result of [LinkPolicy.check]: either a normalized [uri] to confirm with
/// the user, or a [refusal].
@immutable
final class LinkCheck {
  const LinkCheck.allowed(Uri this.uri) : refusal = null;
  const LinkCheck.refused(LinkRefusal this.refusal) : uri = null;

  final Uri? uri;
  final LinkRefusal? refusal;

  bool get isAllowed => uri != null;
}

/// Decides which URLs a View may ask the host to open.
///
/// Only `https:` by default; `mailto:` / `tel:` are opt-in. `javascript:`,
/// `data:`, `file:`, `content:`, `intent:`, `http:` and app deep links are
/// always refused. Every allowed link still needs the user's confirmation
/// (the bridge calls `confirmOpenLink` before `launchLink`).
@immutable
final class LinkPolicy {
  const LinkPolicy({this.allowMailto = false, this.allowTel = false, this.maxLength = 2048});

  final bool allowMailto;
  final bool allowTel;
  final int maxLength;

  LinkCheck check(Object? raw) {
    if (raw is! String || raw.isEmpty) return const LinkCheck.refused(LinkRefusal.malformed);
    if (raw.length > maxLength) return const LinkCheck.refused(LinkRefusal.tooLong);
    // Control characters and whitespace can hide the real target in a
    // confirmation sheet; refuse instead of trimming.
    if (RegExp(r'[\u0000-\u0020\u007f-\u009f\u200b-\u200f\u2028-\u202e\u2066-\u2069]').hasMatch(raw)) {
      return const LinkCheck.refused(LinkRefusal.malformed);
    }
    final Uri uri;
    try {
      uri = Uri.parse(raw);
    } on FormatException {
      return const LinkCheck.refused(LinkRefusal.malformed);
    }
    switch (uri.scheme.toLowerCase()) {
      case 'https':
        if (uri.host.isEmpty) return const LinkCheck.refused(LinkRefusal.host);
        if (uri.userInfo.isNotEmpty) return const LinkCheck.refused(LinkRefusal.credentials);
        return LinkCheck.allowed(uri);
      case 'mailto' when allowMailto:
        return LinkCheck.allowed(uri);
      case 'tel' when allowTel:
        return LinkCheck.allowed(uri);
      default:
        return const LinkCheck.refused(LinkRefusal.scheme);
    }
  }
}
