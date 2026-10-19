/// What to check about a web address before anyone opens it, in plain
/// words. Shared by links in replies (`replyLinkWarnings`) and every sheet
/// that asks before opening a page a server or app supplied (URL
/// elicitation, MCP App links: `urlWarnings`), so they never disagree.
library;

/// The host as people read it: international names decoded (Dart keeps
/// them percent-encoded), lower case.
String displayHost(Uri uri) {
  try {
    return Uri.decodeComponent(uri.host).toLowerCase();
  } on FormatException {
    return uri.host.toLowerCase();
  }
}

/// Punycode labels, or non-ASCII characters (which `Uri` percent-encodes).
bool looksInternationalHost(String host) =>
    host.split('.').any((l) => l.startsWith('xn--')) || host.contains('%') || host.runes.any((r) => r > 0x7f);

/// IPv6, or IPv4 in any form a browser accepts: dotted, a single decimal
/// or hex number (`2130706433`, `0x7f000001`), octal parts.
bool looksIpHost(String host) =>
    host.contains(':') || RegExp(r'^((0x[0-9a-f]*|\d+)\.?){1,4}$').hasMatch(host.toLowerCase());

/// Warnings for a web page address (empty when nothing stands out). The
/// text of a link can name one site while the address goes to another, so
/// these are about the address itself.
List<String> webAddressWarnings(Uri uri) {
  final host = uri.host.toLowerCase();
  return [
    if (uri.scheme.toLowerCase() != 'https') 'This page is not encrypted (http). Anyone on the network could see or change it.',
    if (looksInternationalHost(host))
      'The address uses international characters (${displayHost(uri)}). Look closely: it may imitate a site you know.',
    if (uri.userInfo.isNotEmpty)
      'The address has a user name before the site (“${uri.userInfo.split(':').first}@”). '
          'That is a common trick to make a link look like another site.',
    if (looksIpHost(host)) 'The address is a bare IP address, not a site name.',
  ];
}
