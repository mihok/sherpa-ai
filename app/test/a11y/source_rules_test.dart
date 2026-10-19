import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Rules the widget audit can't see, checked in the source of every screen
/// the M6 audit covers (lib/design, lib/routing, lib/shell and every
/// feature; see docs/milestones/M6-accessibility.md):
///
/// - RTL: no hard-coded left/right (`EdgeInsetsDirectional`,
///   `AlignmentDirectional`, `BorderDirectional`, start/end), and no
///   `SafeArea`/`MediaQuery.removePadding` on one physical side only;
/// - reduced motion: every framework animation that ignores
///   `MediaQuery.disableAnimations` is given the motion tokens' style;
/// - headings go through `Heading` (headingLevel + header), not ad hoc
///   (`header: true` alone is not announced as a heading).
void main() {
  final root = Directory('lib');
  final files = [
    for (final f in root.listSync(recursive: true).whereType<File>())
      if (f.path.endsWith('.dart') && _audited(f.path.replaceAll(r'\', '/'))) f,
  ]..sort((a, b) => a.path.compareTo(b.path));

  test('the audited sources are found', () {
    expect(files.length, greaterThan(100));
    expect(files.any((f) => f.path.endsWith('settings_screen.dart')), isTrue);
    for (final area in ['/features/chat/', '/features/home/', '/shell/']) {
      expect(files.any((f) => f.path.contains(area)), isTrue, reason: area);
    }
    expect(files.any((f) => f.path.contains('/services/')), isFalse);
  });

  test('the call scanner reads nested type arguments and whole names only', () {
    const src = 'final a = showModalBottomSheet<Map<String, String>>(\n  context: c,\n  builder: (_) => X(),\n);\n'
        'm.showSnackBar(SnackBar(content: t));\nconst b = SnackBarAction(label: l);\n';
    final sheet = _calls(src, 'showModalBottomSheet').single;
    expect((sheet.line, sheet.text.endsWith('X(),\n)')), (1, true));
    expect(_calls(src, 'SnackBar').map((c) => c.line), [5], reason: 'not showSnackBar, not SnackBarAction');
    expect(_calls('RoundedRectangleBorder(side: s)', 'Border'), isEmpty);
    expect(_args('SafeArea(\n  right: false,\n  child: Padding(padding: EdgeInsets.only(left: 4)),\n)'), [
      'right: false',
      'child: Padding(padding: EdgeInsets.only(left: 4))',
    ]);
  });

  List<String> violations(String Function(String path, String source) check) => [
        for (final f in files) ...check(f.path, f.readAsStringSync()).split('\n').where((l) => l.isNotEmpty),
      ];

  test('no hard-coded left or right (RTL)', () {
    final lineRules = <String, RegExp>{
      'Alignment.*Left/Right: use AlignmentDirectional': RegExp(r'\bAlignment\.(center|top|bottom)(Left|Right)\b'),
      'TextAlign.left/right: use start/end': RegExp(r'\bTextAlign\.(left|right)\b'),
    };
    // Checked on each call's top-level arguments, however it is wrapped.
    final namedSides = <String, (Set<String>, String)>{
      'EdgeInsets.only': ({'left', 'right'}, 'use EdgeInsetsDirectional.only(start/end)'),
      'Border': ({'left', 'right'}, 'use BorderDirectional(start/end)'),
      'BorderRadius.only': ({'topLeft', 'topRight', 'bottomLeft', 'bottomRight'}, 'use BorderRadiusDirectional'),
      'Positioned': ({'left', 'right'}, 'use PositionedDirectional'),
    };
    // One physical side only: the side facing a neighbour swaps in RTL, so
    // pick it from the Directionality (as the shell's panes do).
    final oneSided = <String, (String, String)>{
      'SafeArea': ('left: false', 'right: false'),
      'MediaQuery.removePadding': ('removeLeft: true', 'removeRight: true'),
    };
    final bad = violations((path, src) {
      final out = StringBuffer();
      for (final (i, line) in src.split('\n').indexed) {
        for (final r in lineRules.entries) {
          if (r.value.hasMatch(line)) out.writeln('$path:${i + 1}: ${r.key}');
        }
      }
      for (final rule in namedSides.entries) {
        for (final call in _calls(src, rule.key)) {
          final names = {for (final a in _args(call.text)) a.split(':').first.trim()};
          if (names.any(rule.value.$1.contains)) out.writeln('$path:${call.line}: ${rule.key} with left/right: ${rule.value.$2}');
        }
      }
      for (final rule in oneSided.entries) {
        for (final call in _calls(src, rule.key)) {
          final args = _args(call.text).toSet();
          if (args.contains(rule.value.$1) != args.contains(rule.value.$2)) {
            out.writeln('$path:${call.line}: ${rule.key} on one physical side: choose it by text direction');
          }
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
      // How long a SnackBar stays up is not an animation.
      final snackBarLines = {
        for (final call in _calls(src, 'SnackBar'))
          for (var l = call.line; l < call.line + '\n'.allMatches(call.text).length + 1; l++) l,
      };
      for (final (i, line) in src.split('\n').indexed) {
        if (RegExp(r'\bMaterialPageRoute\b').hasMatch(line) &&
            !line.trimLeft().startsWith('///') &&
            !path.endsWith('design/motion.dart')) {
          out.writeln('$path:${i + 1}: MaterialPageRoute ignores reduced motion: use MotionPageRoute');
        }
        // A literal duration on an animation; SnackBar display times and
        // the fallback after the tokens (`motion?.medium ?? …`) are not.
        if (RegExp(r'\bduration: (const )?Duration\(').hasMatch(line) &&
            !line.contains('SnackBar') &&
            !snackBarLines.contains(i + 1)) {
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
        if (line.trimLeft().startsWith('//')) continue;
        // `header: true` alone is not announced as a heading since 3.47.
        if (line.contains('headingLevel:') || RegExp(r'\bheader: true\b').hasMatch(line)) {
          out.writeln('$path:${i + 1}: use Heading(level: …) (sets headingLevel and header)');
        }
      }
      return out.toString();
    });
    expect(bad, isEmpty, reason: bad.join('\n'));
  });
}

/// The screens the M6 audit covers: every feature, the shell, the design
/// system and routing. App state and services draw no UI.
bool _audited(String path) {
  const excluded = ['lib/state/', 'lib/services/'];
  return !excluded.any(path.contains);
}

/// Each call of [name] in [src]: its full text, `name(` to the matching
/// `)`, and the line it starts on. Type arguments may nest
/// (`showModalBottomSheet<Map<String, String>>(`). Doc comments are skipped.
Iterable<({String text, int line})> _calls(String src, String name) sync* {
  final start = RegExp('\\b${RegExp.escape(name)}(<[^(]*?>)?\\(');
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
