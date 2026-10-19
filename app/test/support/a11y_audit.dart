import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show SemanticsAction, Tristate;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa/design/contrast.dart';

import 'harness.dart';

/// The accessibility audit (M6): every screen is opened at each [AuditView]
/// and checked with [expectAudit]. See README › Development › Accessibility.
///
/// One cell of the audit matrix: a window size, a text scale and a theme.
@immutable
final class AuditView {
  const AuditView(this.name, this.size, {this.textScale = 1, this.dark = false, this.rtl = false});

  final String name;

  /// Logical pixels (the audit runs at a device pixel ratio of 1).
  final Size size;
  final double textScale;
  final bool dark;

  /// Right-to-left layout (see [rtlBuilder]); the app ships English only, so
  /// RTL is forced with a [Directionality] rather than a locale.
  final bool rtl;

  /// A small phone, and a landscape tablet (expanded: rail + two panes).
  static const Size phoneSize = Size(360, 740);
  static const Size tabletSize = Size(1200, 840);

  static const phone1x = AuditView('phone 1x', phoneSize);
  static const phone2x = AuditView('phone 2x', phoneSize, textScale: 2);
  static const tablet1x = AuditView('tablet 1x', tabletSize);
  static const tablet2x = AuditView('tablet 2x', tabletSize, textScale: 2);
  static const phoneDark = AuditView('phone 1x dark', phoneSize, dark: true);
  static const phoneRtl = AuditView('phone 1x rtl', phoneSize, rtl: true);

  /// What every screen is audited at.
  static const List<AuditView> all = [phone1x, phone2x, tablet1x, tablet2x, phoneDark];

  ThemeMode get themeMode => dark ? ThemeMode.dark : ThemeMode.light;
  Brightness get brightness => dark ? Brightness.dark : Brightness.light;

  @override
  String toString() => name;
}

/// Sizes the window for [view] (logical size, pixel ratio 1) and sets its
/// text scale on the platform dispatcher, which `MediaQuery.fromView` reads.
/// Rigs that wrap the app in their own `MediaQuery` must pass
/// [AuditView.textScale] through instead; [expectAudit] checks it arrived.
void setAuditWindow(WidgetTester tester, AuditView view) => setWindow(tester, view.size, textScale: view.textScale);

/// A `MaterialApp.builder` that forces right-to-left below the app's own
/// `Directionality` (for [AuditView.rtl]); identity otherwise.
TransitionBuilder rtlBuilder(AuditView view, [TransitionBuilder? inner]) => (context, child) {
      final c = inner?.call(context, child) ?? child ?? const SizedBox.shrink();
      return view.rtl ? Directionality(textDirection: TextDirection.rtl, child: c) : c;
    };

/// Opens a screen for one [AuditView] (pump the app, navigate, open the sheet).
typedef AuditOpen = Future<void> Function(WidgetTester tester, AuditView view);

/// Registers one test per view in [views]: [open] the screen, then
/// [expectAudit] it, scrolled from top to bottom.
///
/// Contrast is checked twice in every view: exactly, from the colours in
/// the widget tree ([expectExactTextContrast]), and by Flutter's
/// `textContrastGuideline`, which samples pixels and takes the most frequent
/// "dark" colour. For short or 12 px text at 1× that colour is often an
/// anti-aliasing shade, or the outline of the button around the label, so
/// the guideline reports ratios the real colours don't have.
/// [pixelContrastSkip] lists the views where it does so for this screen;
/// there the exact check stands alone, and [contrastNote] says what the
/// guideline misread.
void auditScreen(
  String name,
  AuditOpen open, {
  List<AuditView> views = AuditView.all,
  Set<AuditView> pixelContrastSkip = const {},
  String? contrastNote,
  bool scroll = true,
  bool requireHeading = true,
  Future<void> Function(WidgetTester tester)? cleanup,
  bool skip = false,
}) {
  assert(pixelContrastSkip.isEmpty || contrastNote != null, 'say what the pixel contrast check misreads');
  for (final view in views) {
    testWidgets('a11y audit: $name · $view', (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await open(tester, view);
        await expectAudit(
          tester,
          view: view,
          textContrast: !pixelContrastSkip.contains(view),
          scroll: scroll,
          requireHeading: requireHeading,
        );
        // Inside the test body: e.g. let a pending request time out, so no
        // timer outlives the test.
        await cleanup?.call(tester);
      } finally {
        semantics.dispose();
      }
    }, skip: skip);
  }
}

/// Checks what is on screen now, then again after each scroll of the main
/// scrollable (the largest vertical one that is not covered by a modal
/// barrier) until its end:
///
/// - `androidTapTargetGuideline` (48×48), `iOSTapTargetGuideline` (44×44),
///   `labeledTapTargetGuideline` and, unless [textContrast] is false,
///   `textContrastGuideline` (WCAG AA);
/// - exact text contrast ([expectExactTextContrast], always);
/// - no RenderFlex overflows (every visible `Row`/`Column`/`Flex` measured,
///   not only the ones that reported) and no exceptions, so no "A RenderFlex
///   overflowed" either;
/// - every `IconButton` and icon-only FAB has a tooltip;
/// - `Semantics(excludeSemantics: true)` over something tappable keeps the
///   action itself (`container` + `onTap`), or screen readers lose it;
/// - at least one heading (`headingLevel`) is on screen.
///
/// With [view] it first checks that the screen really is at that size,
/// text scale and brightness, so a rig can't silently ignore the matrix.
Future<void> expectAudit(
  WidgetTester tester, {
  AuditView? view,
  bool textContrast = true,
  bool scroll = true,
  bool requireHeading = true,
  int maxPages = 16,
}) async {
  if (view != null) _expectViewApplied(tester, view);
  _expectHeading(tester, required: requireHeading);
  await _checkHere(tester, textContrast: textContrast, where: 'at the top');
  if (!scroll) return;
  final scrollable = _mainScrollable(tester);
  if (scrollable == null) return;
  for (var page = 1; page <= maxPages; page++) {
    final pos = scrollable.position;
    if (pos.pixels >= pos.maxScrollExtent - 0.5) break;
    pos.jumpTo(math.min(pos.maxScrollExtent, pos.pixels + pos.viewportDimension * 0.8));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await _checkHere(tester, textContrast: textContrast, where: 'scrolled ${page}x', scrolled: true);
  }
}

Future<void> _checkHere(
  WidgetTester tester, {
  required bool textContrast,
  required String where,
  bool scrolled = false,
}) async {
  expectNoLayoutErrors(tester, where: where);
  expectExactTextContrast(tester, where: where);
  _expectTooltips(tester, where);
  _expectExcludedSemanticsKeepActions(tester, where);
  // Scrolled by a fixed step, rows are cut off at the viewport's edges and
  // their clipped rect is what the stock guidelines measure; the in-view
  // variants apply the same sizes to every target the viewport shows whole.
  await expectLater(
    tester,
    meetsGuideline(scrolled ? InViewTapTargetGuideline(androidTapTargetGuideline) : androidTapTargetGuideline),
    reason: where,
  );
  await expectLater(
    tester,
    meetsGuideline(scrolled ? InViewTapTargetGuideline(iOSTapTargetGuideline) : iOSTapTargetGuideline),
    reason: where,
  );
  await expectLater(tester, meetsGuideline(labeledTapTargetGuideline), reason: where);
  if (textContrast) await expectLater(tester, meetsGuideline(textContrastGuideline), reason: where);
}

/// No pending exception (an overflow report is one) and no visible
/// RenderFlex whose children run past its edges.
void expectNoLayoutErrors(WidgetTester tester, {String where = ''}) {
  final error = tester.takeException();
  if (error != null) {
    final text = error.toString();
    fail(text.contains('overflowed') ? 'A RenderFlex overflowed ($where):\n$text' : 'Exception ($where):\n$text');
  }
  final overflows = flexOverflows(tester);
  if (overflows.isNotEmpty) fail('RenderFlex overflow ($where):\n${overflows.join('\n')}');
}

/// Every on-screen `Flex` (Row, Column) whose children extend past its main
/// axis, measured from the render tree. Reported overflows fail a test once
/// per render object; this also finds ones already reported, or clipped.
List<String> flexOverflows(WidgetTester tester) {
  final out = <String>[];
  for (final element in find.byWidgetPredicate((w) => w is Flex).evaluate()) {
    final flex = element.renderObject;
    if (flex is! RenderFlex || !flex.hasSize || !flex.attached) continue;
    final horizontal = flex.direction == Axis.horizontal;
    final extent = horizontal ? flex.size.width : flex.size.height;
    var worst = 0.0;
    var child = flex.firstChild;
    while (child != null) {
      final data = child.parentData! as FlexParentData;
      if (child.hasSize) {
        final start = horizontal ? data.offset.dx : data.offset.dy;
        final end = start + (horizontal ? child.size.width : child.size.height);
        worst = math.max(worst, math.max(-start, end - extent));
      }
      child = data.nextSibling;
    }
    if (worst > 0.5) {
      final chain = <String>[];
      element.visitAncestorElements((a) {
        if (chain.length < 6 && !a.widget.runtimeType.toString().startsWith('_')) chain.add('${a.widget.runtimeType}');
        return chain.length < 6;
      });
      out.add('${element.widget.runtimeType} by ${worst.toStringAsFixed(1)} px in ${chain.join(' < ')}');
    }
  }
  return out;
}

/// Inside a subtree whose semantics are replaced (a framework widget that
/// folds a button into its parent's node, such as `DropdownMenu`'s arrow).
bool _semanticsExcluded(Element e) {
  var excluded = false;
  e.visitAncestorElements((a) {
    final w = a.widget;
    excluded = (w is ExcludeSemantics && w.excluding) || (w is Semantics && w.excludeSemantics);
    return !excluded;
  });
  return excluded;
}

void _expectTooltips(WidgetTester tester, String where) {
  final missing = [
    for (final e in find.byType(IconButton).evaluate())
      if (!_semanticsExcluded(e))
        if ((e.widget as IconButton).tooltip?.trim().isEmpty ?? true) 'IconButton(${(e.widget as IconButton).icon})',
    for (final f in tester.widgetList<FloatingActionButton>(find.byType(FloatingActionButton)))
      if (!f.isExtended && (f.tooltip == null || f.tooltip!.trim().isEmpty)) 'FloatingActionButton(${f.child})',
  ];
  if (missing.isNotEmpty) fail('Icon-only buttons without a tooltip ($where): ${missing.join(', ')}');
}

bool _tappable(Widget w) => switch (w) {
      InkResponse(:final onTap) => onTap != null,
      GestureDetector(:final onTap, :final onTapUp) => onTap != null || onTapUp != null,
      ButtonStyleButton(:final onPressed) => onPressed != null,
      IconButton(:final onPressed) => onPressed != null,
      _ => false,
    };

void _expectExcludedSemanticsKeepActions(WidgetTester tester, String where) {
  final bad = <String>[];
  for (final element in find.byWidgetPredicate((w) => w is Semantics && w.excludeSemantics).evaluate()) {
    final s = element.widget as Semantics;
    final below = find.descendant(of: find.byElementPredicate((e) => identical(e, element)), matching: find.byWidgetPredicate(_tappable));
    if (below.evaluate().isEmpty) continue;
    if (!s.container || s.properties.onTap == null) bad.add('"${s.properties.label}"');
  }
  if (bad.isNotEmpty) {
    fail('excludeSemantics over a tappable child without container + onTap ($where): ${bad.join(', ')}');
  }
}

void _expectHeading(WidgetTester tester, {required bool required}) {
  var found = false;
  final inverted = <String>[];
  void visit(SemanticsNode n) {
    final d = n.getSemanticsData();
    if (!n.isMergedIntoParent && d.headingLevel > 0) {
      found = true;
      // Text merged into a node around a heading is read before it.
      for (var a = n.parent; a != null; a = a.parent) {
        final p = a.getSemanticsData();
        if (p.flagsCollection.scopesRoute || p.flagsCollection.namesRoute) break;
        if (p.label.trim().isNotEmpty) {
          inverted.add('"${d.label}" is read after "${p.label.split('\n').first}"');
          break;
        }
      }
    }
    n.visitChildren((c) {
      visit(c);
      return true;
    });
  }

  for (final v in tester.binding.renderViews) {
    final root = v.owner?.semanticsOwner?.rootSemanticsNode;
    if (root != null) visit(root);
  }
  if (required) expect(found, isTrue, reason: 'every screen and sheet names itself with a heading');
  if (inverted.isNotEmpty) {
    fail('Text next to a heading is merged into the node around it, so it is read first '
        '(give the group explicitChildNodes): ${inverted.join('; ')}');
  }
}

void _expectViewApplied(WidgetTester tester, AuditView view) {
  final scaffolds = find.byType(Scaffold);
  final element = tester.element(scaffolds.evaluate().isEmpty ? find.byType(Navigator).last : scaffolds.last);
  final mq = MediaQuery.of(element);
  expect(mq.size, view.size, reason: 'the screen is not at the audit size');
  expect(mq.textScaler.scale(10), moreOrLessEquals(10 * view.textScale), reason: 'the audit text scale did not reach the screen');
  expect(Theme.of(element).brightness, view.brightness, reason: 'the audit theme did not reach the screen');
  if (view.rtl) expect(Directionality.of(element), TextDirection.rtl);
}

/// The vertical scrollable that is the screen's body: the largest one the
/// user can touch (a sheet's list rather than the page under its barrier).
ScrollableState? _mainScrollable(WidgetTester tester) {
  ScrollableState? best;
  var bestArea = 0.0;
  for (final s in tester.stateList<ScrollableState>(find.byType(Scrollable).hitTestable())) {
    if (axisDirectionToAxis(s.axisDirection) != Axis.vertical) continue;
    final box = s.context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) continue;
    final area = box.size.width * box.size.height;
    if (area > bestArea) {
      best = s;
      bestArea = area;
    }
  }
  return best;
}

/// Exact WCAG contrast of every foreground role on every background role,
/// for colours neither check above can see on screen: text in text fields
/// (the fill is painted by the decorator) and labels painted on a canvas
/// (charts). Same idea as the perf lab's token checks.
void expectRoleContrast({
  required Map<String, Color> foregrounds,
  required Map<String, Color> backgrounds,
  double min = 4.5,
}) {
  for (final bg in backgrounds.entries) {
    for (final fg in foregrounds.entries) {
      final opaque = Color.alphaBlend(fg.value, bg.value);
      expect(contrastRatio(opaque, bg.value), greaterThanOrEqualTo(min), reason: '${fg.key} on ${bg.key}');
    }
  }
}

/// WCAG contrast of every visible text run against the surface it sits on,
/// read exactly from the widget tree: the span's colour (times any
/// `Opacity`/`FadeTransition` above it) over the nearest painted ancestor
/// (`ColoredBox`, a `DecoratedBox`/`Ink` colour, a `Material`'s
/// `PhysicalModel`/`PhysicalShape`), translucent layers blended down to an
/// opaque one. Unlike `textContrastGuideline` it does not sample pixels, so
/// anti-aliasing of small text can't fool it. Skipped: disabled controls
/// (WCAG exempts them), text in text fields (their fill is painted by the
/// decorator, checked by the role tests), and text over a picture, a
/// gradient or custom painting, whose background it can't know.
void expectExactTextContrast(WidgetTester tester, {String where = ''}) {
  final problems = exactContrastProblems(tester);
  if (problems.isNotEmpty) fail('Text below WCAG AA contrast ($where):\n${problems.join('\n')}');
}

List<String> exactContrastProblems(WidgetTester tester) {
  final out = <String>[];
  final screen = Offset.zero & tester.view.physicalSize / tester.view.devicePixelRatio;
  void check(Element element, InlineSpan text) {
    final box = element.renderObject;
    if (box is! RenderBox || !box.attached || !box.hasSize || box.size.isEmpty) return;
    final rect = MatrixUtils.transformRect(box.getTransformTo(null), Offset.zero & box.size);
    if (!rect.overlaps(screen) || _disabled(box)) return;
    var opacity = 1.0;
    var inField = false;
    element.visitAncestorElements((a) {
      final w = a.widget;
      if (w is Opacity) opacity *= w.opacity;
      if (w is FadeTransition) opacity *= w.opacity.value;
      if (w is InputDecorator) inField = true;
      return !inField;
    });
    if (inField || opacity < 0.05) return;
    final bg = _backgroundOf(element);
    if (bg == null) return;
    void visit(InlineSpan span, TextStyle inherited) {
      if (span is! TextSpan) return;
      final style = inherited.merge(span.style);
      final value = span.text;
      final color = style.color;
      if (value != null && value.trim().isNotEmpty && color != null) {
        final fg = color.withValues(alpha: color.a * opacity);
        final ratio = contrastRatio(Color.alphaBlend(fg, bg), bg);
        final size = style.fontSize ?? 14;
        final bold = (style.fontWeight ?? FontWeight.normal).value >= FontWeight.w700.value;
        final target = size >= 18 || (bold && size >= 14) ? 3.0 : 4.5;
        if (ratio + 0.01 < target) {
          final shown = value.length > 40 ? '${value.substring(0, 39)}…' : value;
          out.add('"$shown": ${ratio.toStringAsFixed(2)}:1 (needs $target) for $fg on $bg');
        }
      }
      for (final c in span.children ?? const <InlineSpan>[]) {
        visit(c, style);
      }
    }

    visit(text, const TextStyle());
  }

  for (final e in find.byType(RichText).evaluate()) {
    check(e, (e.widget as RichText).text);
  }
  for (final e in find.byType(EditableText).evaluate()) {
    final w = e.widget as EditableText;
    check(e, TextSpan(text: w.controller.text, style: w.style));
  }
  return out;
}

/// The nearest semantics node above [box] says the control is disabled.
bool _disabled(RenderObject box) {
  RenderObject? r = box;
  while (r != null) {
    final node = r.debugSemantics;
    if (node != null) return node.getSemanticsData().flagsCollection.isEnabled == Tristate.isFalse;
    r = r.parent;
  }
  return false;
}

/// The colour [element] is painted on, or null when it can't be known.
Color? _backgroundOf(Element element) {
  final layers = <Color>[];
  Color? opaque;
  var unknown = false;
  void add(Color? c) {
    if (c == null || c.a == 0) return;
    if (c.a >= 1) {
      opaque = c;
    } else {
      layers.add(c);
    }
  }

  element.visitAncestorElements((a) {
    final w = a.widget;
    switch (w) {
      case ColoredBox(:final color):
        add(color);
      case DecoratedBox(:final decoration, :final position) when position == DecorationPosition.background:
        unknown = !_addDecoration(decoration, add);
      case Ink(:final decoration?):
        unknown = !_addDecoration(decoration, add);
      case PhysicalModel(:final color):
        add(color);
      case PhysicalShape(:final color):
        add(color);
      case CustomPaint(painter: _?):
        unknown = true;
      case Image() || RawImage():
        unknown = true;
      default:
        break;
    }
    return opaque == null && !unknown;
  });
  if (unknown || opaque == null) return null;
  var c = opaque!;
  for (final layer in layers.reversed) {
    c = Color.alphaBlend(layer, c);
  }
  return c;
}

/// False when [d] paints something other than a flat colour (a gradient, an
/// image) under the text.
bool _addDecoration(Decoration d, void Function(Color?) add) {
  switch (d) {
    case BoxDecoration(:final gradient, :final image, :final color):
      if (gradient != null || image != null) return false;
      add(color);
    case ShapeDecoration(:final gradient, :final image, :final color):
      if (gradient != null || image != null) return false;
      add(color);
    default:
      return false;
  }
  return true;
}

/// [official]'s minimum size (48×48 Android, 44×44 iOS) for every tappable
/// node a scroll view shows whole. The stock guideline only spares nodes
/// cut off by a viewport that does implicit scrolling (lists); a node cut
/// off by any other scroll view (a `SingleChildScrollView`, a sheet) is
/// measured clipped and "fails" at a few pixels high. Nodes that are only
/// partly in view are skipped here; the audit sees each of them whole at
/// some other scroll position (pages overlap by a fifth).
class InViewTapTargetGuideline extends AccessibilityGuideline {
  InViewTapTargetGuideline(AccessibilityGuideline official) : official = official as MinimumTapTargetGuideline;

  final MinimumTapTargetGuideline official;

  @override
  String get description => '${official.description} (targets in full view)';

  @override
  FutureOr<Evaluation> evaluate(WidgetTester tester) {
    var result = const Evaluation.pass();
    for (final view in tester.binding.renderViews) {
      final root = view.owner?.semanticsOwner?.rootSemanticsNode;
      if (root == null) continue;
      final screen = Offset.zero & view.flutterView.physicalSize;
      result += _visit(root, Matrix4.identity(), screen, view.flutterView.devicePixelRatio);
    }
    return result;
  }

  Evaluation _visit(SemanticsNode node, Matrix4 parent, Rect clip, double dpr) {
    final transform = node.transform;
    final m = transform == null ? parent : (parent.clone()..multiply(transform));
    final rect = MatrixUtils.transformRect(m, node.rect);
    final data = node.getSemanticsData();
    final scrolls = data.flagsCollection.hasImplicitScrolling ||
        data.hasAction(SemanticsAction.scrollUp) ||
        data.hasAction(SemanticsAction.scrollDown);
    final inner = scrolls ? clip.intersect(rect) : clip;
    var result = const Evaluation.pass();
    node.visitChildren((c) {
      result += _visit(c, m, inner, dpr);
      return true;
    });
    if (node.isMergedIntoParent || official.shouldSkipNode(node)) return result;
    const gap = 0.001;
    final whole = rect.left - clip.left > gap &&
        clip.right - rect.right > gap &&
        rect.top - clip.top > gap &&
        clip.bottom - rect.bottom > gap;
    if (!whole) return result;
    final size = rect.size / dpr;
    if (size.width < official.size.width - 1e-10 ||
        size.height < official.size.height - 1e-10) {
      result += Evaluation.fail('$node: expected tap target size of at least ${official.size}, but found $size\n'
          'See also: ${official.link}');
    }
    return result;
  }
}
