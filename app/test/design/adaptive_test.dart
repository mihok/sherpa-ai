import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa/design/adaptive.dart';

void main() {
  test('window classes switch at 600 and 840', () {
    expect(WindowClass.fromWidth(320), WindowClass.compact);
    expect(WindowClass.fromWidth(599.9), WindowClass.compact);
    expect(WindowClass.fromWidth(600), WindowClass.medium);
    expect(WindowClass.fromWidth(839.9), WindowClass.medium);
    expect(WindowClass.fromWidth(840), WindowClass.expanded);
    expect(WindowClass.fromWidth(1600), WindowClass.expanded);
    expect(WindowClass.expanded >= WindowClass.medium, isTrue);
    expect(WindowClass.compact >= WindowClass.medium, isFalse);
  });

  Future<AdaptiveLayout> measure(WidgetTester tester, Size size, {List<DisplayFeature> features = const []}) async {
    late AdaptiveLayout layout;
    await tester.pumpWidget(MediaQuery(
      data: MediaQueryData(size: size, displayFeatures: features),
      child: Builder(builder: (context) {
        layout = AdaptiveLayout.of(context);
        return const SizedBox();
      }),
    ));
    return layout;
  }

  testWidgets('compact: no rail, single pane, 16dp gutter', (tester) async {
    final l = await measure(tester, const Size(400, 800));
    expect(l.showRail, isFalse);
    expect(l.twoPane, isFalse);
    expect(l.gutter, 16);
  });

  testWidgets('medium: rail, single pane', (tester) async {
    final l = await measure(tester, const Size(700, 900));
    expect(l.showRail, isTrue);
    expect(l.twoPane, isFalse);
  });

  testWidgets('expanded: rail and two panes, list pane within bounds', (tester) async {
    final l = await measure(tester, const Size(1200, 800));
    expect(l.twoPane, isTrue);
    final w = l.listPaneWidth(leadingWidth: 81);
    expect(w, inInclusiveRange(300, 400));
  });

  testWidgets('a vertical hinge forces two panes split on the hinge', (tester) async {
    const hinge = DisplayFeature(
      bounds: Rect.fromLTWH(540, 0, 24, 720),
      type: DisplayFeatureType.hinge,
      state: DisplayFeatureState.postureFlat,
    );
    final l = await measure(tester, const Size(1104, 720), features: [hinge]);
    expect(l.separator, hinge.bounds);
    expect(l.twoPane, isTrue);
    expect(l.listPaneWidth(leadingWidth: 81), 540 - 81);
  });

  testWidgets('a flat fold does not split; a half-open fold does', (tester) async {
    const flat = DisplayFeature(
      bounds: Rect.fromLTWH(400, 0, 0, 800),
      type: DisplayFeatureType.fold,
      state: DisplayFeatureState.postureFlat,
    );
    expect((await measure(tester, const Size(800, 800), features: [flat])).separator, isNull);
    const book = DisplayFeature(
      bounds: Rect.fromLTWH(400, 0, 0, 800),
      type: DisplayFeatureType.fold,
      state: DisplayFeatureState.postureHalfOpened,
    );
    final l = await measure(tester, const Size(800, 800), features: [book]);
    expect(l.separator, isNotNull);
    expect(l.twoPane, isTrue);
  });

  testWidgets('a horizontal fold (tabletop) is not a vertical separator', (tester) async {
    const tabletop = DisplayFeature(
      bounds: Rect.fromLTWH(0, 400, 800, 0),
      type: DisplayFeatureType.fold,
      state: DisplayFeatureState.postureHalfOpened,
    );
    expect((await measure(tester, const Size(800, 800), features: [tabletop])).separator, isNull);
  });
}
