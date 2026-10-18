import 'dart:math';

/// Wrapper for untrusted text that Sherpa itself places in the context
/// (summary items tagged `[tool:*]`, handoff turns), in the style of
/// `PromptBoundary.wrapUntrusted`.
///
/// Why a nonce: a fixed `</untrusted_data>` tag can be forged by the very
/// content it wraps (the spotlighting paper's point about delimiters, R11
/// §9.7). The closing tag carries a per-session random id that was chosen
/// after the wrapped content was produced, and any tag-shaped text inside is
/// escaped as well, so tool output can neither close the block early nor open
/// a fake one.
abstract final class UntrustedData {
  static final RegExp _tag = RegExp(r'<(/?)(untrusted_data)', caseSensitive: false);
  static final RegExp _sourceUnsafe = RegExp(r'[^A-Za-z0-9_.:/-]');
  static final RegExp _nonceShape = RegExp(r'^[A-Za-z0-9]{8,64}$');

  /// 16 hex chars (64 bits) from a CSPRNG unless [random] is injected.
  static String newNonce([Random? random]) {
    final r = random ?? Random.secure();
    final b = StringBuffer();
    for (var i = 0; i < 16; i++) {
      b.write(r.nextInt(16).toRadixString(16));
    }
    return b.toString();
  }

  static bool isValidNonce(String nonce) => _nonceShape.hasMatch(nonce);

  /// Neutralises anything inside [text] that looks like a wrapper tag.
  static String escape(String text) => text.replaceAllMapped(_tag, (m) => '&lt;${m[1]}${m[2]}');

  /// `<untrusted_data source=… id=NONCE>…</untrusted_data id=NONCE>`.
  /// Without a (valid) [nonce] the id attribute is omitted.
  static String wrap(String text, {required String source, String? nonce}) {
    final safeSource = source.replaceAll(_sourceUnsafe, '_');
    final id = nonce != null && isValidNonce(nonce) ? ' id="$nonce"' : '';
    return '<untrusted_data source="$safeSource"$id>\n${escape(text)}\n</untrusted_data$id>';
  }
}
