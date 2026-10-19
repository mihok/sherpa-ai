import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa/design/theme.dart';

import '../support/a11y_audit.dart';

/// The audit's own checks catch what they claim to (a check that passes
/// everything would make every audit green).
void main() {
  Future<void> pump(WidgetTester tester, Widget body, {Size size = const Size(360, 740)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: SherpaTheme.light(), home: Scaffold(body: body)));
  }

  testWidgets('a Row wider than its parent is an overflow, even after it reported once', (tester) async {
    await pump(tester, const SizedBox(width: 100, child: Row(children: [SizedBox(width: 160, height: 10)])));
    expect(tester.takeException(), isA<FlutterError>(), reason: 'the framework reports it once');
    expect(flexOverflows(tester).single, startsWith('Row by 60.0 px'));
  });

  testWidgets('a Row that fits is not', (tester) async {
    await pump(tester, const SizedBox(width: 200, child: Row(children: [SizedBox(width: 160, height: 10)])));
    expect(flexOverflows(tester), isEmpty);
  });

  testWidgets('exact contrast flags grey on grey and passes ink on paper', (tester) async {
    await pump(
      tester,
      const Column(children: [
        ColoredBox(color: Color(0xFFFFFFFF), child: Text('ink', style: TextStyle(color: Color(0xFF111111)))),
        ColoredBox(color: Color(0xFFDDDDDD), child: Text('faint', style: TextStyle(color: Color(0xFF999999)))),
      ]),
    );
    final problems = exactContrastProblems(tester);
    expect(problems, hasLength(1));
    expect(problems.single, startsWith('"faint": 2.10:1 (needs 4.5)'));
  });

  testWidgets('exact contrast blends a translucent surface over the one below', (tester) async {
    // 50% black over white is mid grey: white text on it is ~3.9:1, black ~5.3:1.
    await pump(
      tester,
      const ColoredBox(
        color: Color(0xFFFFFFFF),
        child: ColoredBox(
          color: Color(0x80000000),
          child: Column(children: [
            Text('white', style: TextStyle(color: Color(0xFFFFFFFF))),
            Text('black', style: TextStyle(color: Color(0xFF000000))),
          ]),
        ),
      ),
    );
    expect(exactContrastProblems(tester).single, startsWith('"white"'));
  });

  testWidgets('large text needs 3:1, not 4.5:1', (tester) async {
    await pump(
      tester,
      const ColoredBox(
        color: Color(0xFFFFFFFF),
        child: Text('Heading', style: TextStyle(color: Color(0xFF888888), fontSize: 24)),
      ),
    );
    expect(exactContrastProblems(tester), isEmpty, reason: '#888 on white is 3.5:1');
  });

  testWidgets('disabled controls are exempt (WCAG 1.4.3)', (tester) async {
    final handle = tester.ensureSemantics();
    await pump(tester, const Center(child: FilledButton(onPressed: null, child: Text('Not yet'))));
    expect(exactContrastProblems(tester), isEmpty);
    handle.dispose();
  });

  testWidgets('an icon button without a tooltip fails the audit', (tester) async {
    final handle = tester.ensureSemantics();
    await pump(
      tester,
      Column(children: [
        Semantics(headingLevel: 1, child: const Text('Title')),
        IconButton(onPressed: () {}, icon: const Icon(Icons.close)),
      ]),
    );
    await expectLater(expectAudit(tester, scroll: false), throwsA(isA<TestFailure>()));
    handle.dispose();
  });

  testWidgets('excludeSemantics over a button must carry the tap itself', (tester) async {
    final handle = tester.ensureSemantics();
    Widget card({required bool keepsTap}) => Semantics(
          container: keepsTap,
          label: 'A card',
          onTap: keepsTap ? () {} : null,
          excludeSemantics: true,
          child: InkWell(onTap: () {}, child: const SizedBox(width: 200, height: 60, child: Text('A card'))),
        );
    await pump(tester, Column(children: [Semantics(headingLevel: 1, child: const Text('T')), card(keepsTap: false)]));
    await expectLater(expectAudit(tester, scroll: false, textContrast: false), throwsA(isA<TestFailure>()));
    await pump(tester, Column(children: [Semantics(headingLevel: 1, child: const Text('T')), card(keepsTap: true)]));
    await expectAudit(tester, scroll: false, textContrast: false);
    handle.dispose();
  });

  testWidgets('a screen without a heading fails the audit', (tester) async {
    final handle = tester.ensureSemantics();
    await pump(tester, const Center(child: Text('Nothing names this screen')));
    await expectLater(expectAudit(tester, scroll: false), throwsA(isA<TestFailure>()));
    handle.dispose();
  });
}
