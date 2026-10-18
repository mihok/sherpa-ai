/// Internal text helpers shared by the context manager and handoff code.
/// Not exported: callers outside `src/` have no reason to depend on them.
library;

/// Cuts [s] to at most [max] UTF-16 units, ending in `…` when cut, without
/// splitting a surrogate pair.
String clipText(String s, int max) {
  if (s.length <= max) return s;
  if (max <= 0) return '';
  var end = max - 1;
  if (end > 0 && _isHighSurrogate(s.codeUnitAt(end - 1))) end--;
  return '${s.substring(0, end)}…';
}

bool _isHighSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;

/// Collapses runs of whitespace to single spaces and trims.
String squash(String s) => s.replaceAll(_ws, ' ').trim();
final RegExp _ws = RegExp(r'\s+');

/// The first non-empty line of [s], squashed.
String firstLine(String s) {
  for (final line in s.split('\n')) {
    final t = squash(line);
    if (t.isNotEmpty) return t;
  }
  return '';
}

/// Splits prose into sentences (and lines), dropping empties.
List<String> sentences(String s) => [
      for (final part in s.split(_sentenceBreak))
        if (squash(part).isNotEmpty) squash(part),
    ];
final RegExp _sentenceBreak = RegExp(r'(?<=[.!?])\s+|\n+');

/// Dedupe key for list items: provenance tag and case/whitespace ignored.
String itemKey(String item) => squash(item.replaceFirst(_tag, '')).toLowerCase();
final RegExp _tag = RegExp(r'^\s*\[(?:user|model|tool:[^\]]*)\]\s*', caseSensitive: false);

/// Formats 4812 as `4,812` for user-facing reasons and stubs.
String groupDigits(int n) {
  final s = n.abs().toString();
  final b = StringBuffer(n < 0 ? '-' : '');
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}
