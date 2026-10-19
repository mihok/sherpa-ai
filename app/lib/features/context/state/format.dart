/// Number and size formatting for the context screens. English-only until
/// the app is localized (strings live here so the l10n pass finds them).
library;

/// `4812` → `4,812`: exact counts read better grouped than abbreviated
/// when the user is comparing "before" and "after".
String groupDigits(int n) {
  final s = n.abs().toString();
  final b = StringBuffer(n < 0 ? '-' : '');
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

/// `0.734` → `73%`; `∞` when the window is unknown.
String formatPercent(double ratio) => ratio.isFinite ? '${(ratio * 100).round()}%' : '∞';

/// `812 bytes`, `3.4 KB`, `1.2 MB` (decimal units, as file managers show).
String formatBytes(int bytes) {
  if (bytes < 1000) return '$bytes bytes';
  if (bytes < 1000 * 1000) {
    final kb = bytes / 1000;
    return '${kb >= 10 ? kb.round() : kb.toStringAsFixed(1)} KB';
  }
  final mb = bytes / (1000 * 1000);
  return '${mb >= 10 ? mb.round() : mb.toStringAsFixed(1)} MB';
}

/// "1 message" / "3 messages".
String plural(int n, String one, [String? many]) => '${groupDigits(n)} ${n == 1 ? one : (many ?? '${one}s')}';

/// The first non-empty line of [s], whitespace collapsed and clipped to
/// [max] characters (list previews).
String previewLine(String s, {int max = 160}) {
  for (final line in s.split('\n')) {
    final t = line.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.isNotEmpty) return t.length <= max ? t : '${t.substring(0, max - 1)}…';
  }
  return '';
}
