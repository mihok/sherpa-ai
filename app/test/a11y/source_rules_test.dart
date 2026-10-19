import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Rules the widget audit can't see, checked in the source of every screen
/// the M6 audit covers (lib/design, lib/routing, lib/features except chat
/// and home; see docs/milestones/M6-accessibility.md):
///
/// - RTL: no hard-coded left/right (`EdgeInsetsDirectional`,
///   `AlignmentDirectional`, `BorderDirectional`, start/end);
/// - reduced motion: every framework animation that ignores
///   `MediaQuery.disableAnimations` is given the motion tokens' style;
/// - headings go through `Heading` (headingLevel + header), not ad hoc.
void main() {
  final root = Directory('lib');
  final files = [
    for (final f in root.listSync(recursive: true).whereType<File>())
      if (f.path.endsWith('.dart') && _audited(f.path.replaceAll(r'\', '/'))) f,
  ]..sort((a, b) => a.path.compareTo(b.path));

  test('the audited sources are found', () {
    expect(files.length, greaterThan(100));
    expect(files.any((f) => f.path.endsWith('settings_screen.dart')), isTrue);
    expect(files.any((f) => f.path.contains('/chat/')), isFalse);
  });

  List<String> violations(String Function(String path, String source) check) => [
        for (final f in files) ...check(f.path, f.readAsStringSync()).split('\n').where((l) => l.isNotEmpty),
      ];

  test('no hard-coded left or right (RTL)', () {
    final lineRules = <String, RegExp>{
      'EdgeInsets.only with left/right: use EdgeInsetsDirectional.only(start/end)': RegExp(r'EdgeInsets\.only\([^)]*\b(left|right):'),
      'Border(left/right): use BorderDirectional(start/end)': RegExp(r'\bBorder\(\s*(left|right):'),
      'Alignment.*Left/Right: use AlignmentDirectional': RegExp(r'\bAlignment\.(center|top|bottom)(Left|Right)\b'),
      'TextAlign.left/right: use start/end': RegExp(r'\bTextAlign\.(left|right)\b'),
      'BorderRadius.only(topLeft…): use BorderRadiusDirectional': RegExp(r'BorderRadius\.only\([^)]*\b(top|bottom)(Left|Right):'),
      'Positioned(left/right): use PositionedDirectional': RegExp(r'\bPositioned\([^)]*\b(left|right):'),
    };
    final bad = violations((path, src) {
      final out = StringBuffer();
      for (final (i, line) in src.split('\n').indexed) {
        for (final r in lineRules.entries) {
          if (r.value.hasMatch(line)) out.writeln('$path:${i + 1}: ${r.key}');
        }
      }
      for (final call in _calls(src, 'EdgeInsets.fromLTRB')) {
        final args = _args(call.text);
        if (args.length == 4 && args[0] != args[2]) {
          out.writeln('$path:${call.line}: EdgeInsets.fromLTRB with different left and right: use EdgeInsetsDirectional.fromSTEB');
        }
      }
      return out.toString();
    });
    expect(bad, isEmpty, reason: bad.join('\n'));
  });

  test('framework animations follow reduced motion', () {
    final callRules = <String, String>{
      'showModalBottomSheet': 'sheetAnimationStyle:',
      'showDialog': 'animationStyle:',
      'ExpansionTile': 'expansionAnimationStyle:',
      'DefaultTabController': 'animationDuration:',
    };
    final bad = violations((path, src) {
      final out = StringBuffer();
      for (final r in callRules.entries) {
        for (final call in _calls(src, r.key)) {
          if (!call.text.contains(r.value)) {
            out.writeln('$path:${call.line}: ${r.key} without ${r.value} motionStyleOf(context) / motion tokens');
          }
        }
      }
      for (final (i, line) in src.split('\n').indexed) {
        if (RegExp(r'\bMaterialPageRoute\b').hasMatch(line) &&
            !line.trimLeft().startsWith('///') &&
            !path.endsWith('design/motion.dart')) {
          out.writeln('$path:${i + 1}: MaterialPageRoute ignores reduced motion: use MotionPageRoute');
        }
        // A literal duration on an animation; SnackBar display times and
        // the fallback after the tokens (`motion?.medium ?? …`) are not.
        if (RegExp(r'\bduration: (const )?Duration\(').hasMatch(line) && !line.contains('SnackBar')) {
          out.writeln('$path:${i + 1}: a literal animation duration: use SherpaTokens.of(context).motion');
        }
      }
      return out.toString();
    });
    expect(bad, isEmpty, reason: bad.join('\n'));
  });

  test('headings go through Heading', () {
    final bad = violations((path, src) {
      if (path.endsWith('design/widgets/a11y.dart')) return '';
      final out = StringBuffer();
      for (final (i, line) in src.split('\n').indexed) {
        if (line.contains('headingLevel:') && !line.trimLeft().startsWith('//')) {
          out.writeln('$path:${i + 1}: use Heading(level: …) (sets headingLevel and header)');
        }
      }
      return out.toString();
    });
    expect(bad, isEmpty, reason: bad.join('\n'));
  });
}

/// The screens the M6 audit covers; chat, home, the shell and app state
/// are audited with the chat work.
bool _audited(String path) {
  const excluded = ['lib/features/chat/', 'lib/features/home/', 'lib/shell/', 'lib/state/', 'lib/services/'];
  return !excluded.any(path.contains);
}

/// Each call of [name] in [src]: its full text, `name(` to the matching
/// `)`, and the line it starts on. Doc comments are skipped.
Iterable<({String text, int line})> _calls(String src, String name) sync* {
  final start = RegExp('\\b${RegExp.escape(name)}(<[^>(]*>)?\\(');
  for (final m in start.allMatches(src)) {
    final lineStart = src.lastIndexOf('\n', m.start) + 1;
    if (src.substring(lineStart, m.start).trimLeft().startsWith('//')) continue;
    var depth = 0;
    var i = m.end - 1;
    for (; i < src.length; i++) {
      final c = src[i];
      if (c == '(') depth++;
      if (c == ')' && --depth == 0) break;
    }
    yield (text: src.substring(m.start, i + 1), line: '\n'.allMatches(src.substring(0, m.start)).length + 1);
  }
}

/// The top-level arguments of a call's text, trimmed.
List<String> _args(String call) {
  final inner = call.substring(call.indexOf('(') + 1, call.length - 1);
  final out = <String>[];
  var depth = 0;
  var from = 0;
  for (var i = 0; i < inner.length; i++) {
    final c = inner[i];
    if ('([{'.contains(c)) depth++;
    if (')]}'.contains(c)) depth--;
    if (c == ',' && depth == 0) {
      out.add(inner.substring(from, i).trim());
      from = i + 1;
    }
  }
  final last = inner.substring(from).trim();
  if (last.isNotEmpty) out.add(last);
  return out;
}
