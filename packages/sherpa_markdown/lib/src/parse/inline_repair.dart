/// Repairs the trailing, still-streaming end of an inline run so it renders
/// as what it is most likely to become.
///
/// Without this, `**bol` renders as literal asterisks and then snaps to
/// bold when `d**` arrives; `[link](htt` shows raw brackets and a partial
/// URL. Here the open construct is closed provisionally, so the text is
/// bold (or link-styled) from the first character and never changes
/// interpretation — only gains characters. The repair runs only on the open
/// tail of a streaming message; frozen and complete text is parsed exactly.
///
/// Rules, in order:
/// 1. An odd trailing backslash is hidden (it is half of `\(`, `\[` or an
///    escape).
/// 2. An unclosed code span is closed (and everything after its opener is
///    code); an opener with no content yet is hidden.
/// 3. A trailing incomplete link becomes a *pending* link: `[text](part`
///    keeps its text with a sentinel destination the AST converter turns
///    into `href: null` (styled, not tappable). `[text` and `[text]` show
///    just `text`; incomplete images are hidden until their destination
///    starts arriving.
/// 4. Unclosed `*`, `_`, `**`, `__`, `~~` are closed in reverse order; a
///    trailing delimiter run that closes nothing (`Hello **`) is hidden.
/// 5. A bare URL at the very end is flagged so its link is not tappable
///    until whitespace proves the URL complete.
library;

import 'inline_math.dart';
import 'source_lines.dart';

/// Destination used for links and images whose URL is still streaming.
const kPendingHref = 'sherpa-pending:';

/// Result of [repairTrailingInline].
typedef InlineRepair = ({String text, bool trailingUrlPending});

final _bareUrl = RegExp(r'(?:https?://|www\.)[^\s<]*', caseSensitive: false);

/// Repairs the end of [input]; see the library doc for the rules.
InlineRepair repairTrailingInline(String input) {
  var text = input.trimRight();
  // 1. Odd trailing backslash.
  var slashes = 0;
  while (slashes < text.length &&
      text.codeUnitAt(text.length - 1 - slashes) == 0x5C) {
    slashes++;
  }
  if (slashes.isOdd) text = text.substring(0, text.length - 1).trimRight();

  // 2. Code spans.
  final code = _scanCodeSpans(text);
  var head = text;
  var codeTail = '';
  if (code.openAt >= 0) {
    head = text.substring(0, code.openAt);
    final content = text.substring(code.openAt + code.runLength);
    if (content.trim().isNotEmpty) {
      codeTail = '${text.substring(code.openAt)}${'`' * code.runLength}';
    }
  }

  // 3. Trailing incomplete link / image (only when the end is not code).
  if (code.openAt < 0) head = _repairTrailingLink(head, code.lastSpanEnd);

  // 4. Emphasis.
  final skips = <(int, int)>[...code.spans];
  final emphasis = _closeEmphasis(head, skips, atEnd: codeTail.isEmpty);

  // 5. Bare URL at the end.
  var pendingUrl = false;
  if (codeTail.isEmpty) {
    for (final m in _bareUrl.allMatches(emphasis.head)) {
      if (m.end == emphasis.head.length) pendingUrl = true;
    }
  }
  return (
    text: '${emphasis.head}$codeTail${emphasis.closers}',
    trailingUrlPending: pendingUrl,
  );
}

/// Finds code spans; returns the start of an unclosed opener (or -1).
({int openAt, int runLength, List<(int, int)> spans, int lastSpanEnd})
_scanCodeSpans(String s) {
  final spans = <(int, int)>[];
  var i = 0;
  while (i < s.length) {
    final c = s.codeUnitAt(i);
    if (c == 0x5C) {
      i += 2;
      continue;
    }
    if (c != 0x60) {
      i++;
      continue;
    }
    final run = _runLength(s, i, 0x60);
    var j = i + run;
    var closed = false;
    while (j < s.length) {
      if (s.codeUnitAt(j) == 0x60) {
        final r = _runLength(s, j, 0x60);
        if (r == run) {
          closed = true;
          j += r;
          break;
        }
        j += r;
      } else {
        j++;
      }
    }
    if (!closed) {
      return (
        openAt: i,
        runLength: run,
        spans: spans,
        lastSpanEnd: spans.isEmpty ? 0 : spans.last.$2,
      );
    }
    spans.add((i, j));
    i = j;
  }
  return (
    openAt: -1,
    runLength: 0,
    spans: spans,
    lastSpanEnd: spans.isEmpty ? 0 : spans.last.$2,
  );
}

int _runLength(String s, int i, int char) {
  var n = 0;
  while (i + n < s.length && s.codeUnitAt(i + n) == char) {
    n++;
  }
  return n;
}

final _trailingLink = RegExp(r'(!?)\[([^\[\]]*)(\](\([^()]*)?)?$');

String _repairTrailingLink(String s, int notBefore) {
  final m = _trailingLink.firstMatch(s);
  if (m == null || m.start < notBefore) return s;
  final bracket = m.start + m[1]!.length;
  // `x[0` is an index expression, not a link: require the bracket to start
  // a word.
  if (bracket > 0) {
    final p = s.codeUnitAt(bracket - 1);
    if (!isWhitespaceChar(p) && !isPunctuationChar(p)) return s;
    if (p == 0x5C) return s; // escaped `\[`
  }
  final image = m[1]!.isNotEmpty;
  final label = m[2]!;
  final dest = m[4];
  final before = s.substring(0, m.start);
  if (dest != null) {
    return '$before${m[1]}[$label]($kPendingHref)';
  }
  // `![alt` / `![alt]`: nothing to show until the destination starts.
  if (image) return before;
  // `[text` / `[text]`: show the text; brackets appear only if the next
  // character proves it is not a link.
  return '$before$label';
}

/// Delimiter run of `*`, `_` or `~~`.
final class _Run {
  _Run(this.char, this.start, this.length, this.canOpen, this.canClose);

  final int char;
  final int start;
  int length;
  final bool canOpen;
  final bool canClose;
  int remaining = 0;
}

({String head, String closers}) _closeEmphasis(
  String input,
  List<(int, int)> codeSpans, {
  required bool atEnd,
}) {
  // Closers are appended right after the last visible character; trailing
  // whitespace would stop them from being right-flanking.
  final s = atEnd ? input.trimRight() : input;
  // Regions whose characters are not delimiters: code spans, link
  // destinations, autolinks, bare URLs, inline math, escapes.
  final skip = <(int, int)>[...codeSpans];
  for (final m in _bareUrl.allMatches(s)) {
    skip.add((m.start, m.end));
  }
  for (final m in RegExp(r'\]\([^)]*\)?').allMatches(s)) {
    skip.add((m.start + 1, m.end));
  }
  for (final m in RegExp(r'<[A-Za-z][A-Za-z0-9+.-]*:[^\s<>]*>').allMatches(s)) {
    skip.add((m.start, m.end));
  }
  skip.sort((a, b) => a.$1.compareTo(b.$1));

  final stack = <_Run>[];
  _Run? lastRun;
  var i = 0;
  var skipIndex = 0;
  while (i < s.length) {
    while (skipIndex < skip.length && skip[skipIndex].$2 <= i) {
      skipIndex++;
    }
    if (skipIndex < skip.length && skip[skipIndex].$1 <= i) {
      i = skip[skipIndex].$2;
      continue;
    }
    final c = s.codeUnitAt(i);
    if (c == 0x24 || c == 0x5C) {
      final math = matchInlineMath(s, i);
      if (math != null) {
        i = math.end;
        continue;
      }
    }
    if (c == 0x5C) {
      i += 2;
      continue;
    }
    if (c != 0x2A && c != 0x5F && c != 0x7E) {
      i++;
      continue;
    }
    final n = _runLength(s, i, c);
    if (c == 0x7E && n != 2) {
      i += n;
      continue;
    }
    final before = i == 0 ? 0x20 : s.codeUnitAt(i - 1);
    final after = i + n >= s.length ? 0x20 : s.codeUnitAt(i + n);
    final left =
        !isWhitespaceChar(after) &&
        (!isPunctuationChar(after) ||
            isWhitespaceChar(before) ||
            isPunctuationChar(before));
    final right =
        !isWhitespaceChar(before) &&
        (!isPunctuationChar(before) ||
            isWhitespaceChar(after) ||
            isPunctuationChar(after));
    final bool canOpen;
    final bool canClose;
    if (c == 0x5F) {
      canOpen = left && (!right || isPunctuationChar(before));
      canClose = right && (!left || isPunctuationChar(after));
    } else {
      canOpen = left;
      canClose = right;
    }
    final run = _Run(c, i, n, canOpen, canClose)..remaining = n;
    if (canClose) {
      while (run.remaining > 0) {
        final idx = stack.lastIndexWhere((o) => o.char == c);
        if (idx < 0) break;
        final opener = stack[idx];
        // Openers between the match and the top can never close now.
        stack.removeRange(idx + 1, stack.length);
        final used = opener.remaining < run.remaining
            ? opener.remaining
            : run.remaining;
        opener.remaining -= used;
        run.remaining -= used;
        if (opener.remaining == 0) stack.removeLast();
      }
    }
    if (run.remaining > 0 && canOpen) stack.add(run);
    lastRun = run;
    i += n;
  }

  var head = s;
  // A trailing run that closed nothing is an opener still being typed
  // (`Hello **`): hide what is left of it.
  if (atEnd &&
      lastRun != null &&
      lastRun.start + lastRun.length == s.length &&
      lastRun.remaining > 0 &&
      !stack.contains(lastRun)) {
    head = s.substring(0, s.length - lastRun.remaining).trimRight();
  }
  final closers = StringBuffer();
  for (final opener in stack.reversed) {
    if (opener.start >= head.length) continue;
    closers.write(String.fromCharCode(opener.char) * opener.remaining);
  }
  return (head: head, closers: closers.toString());
}
