import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa_markdown/sherpa_markdown.dart';
import 'package:sherpa_markdown/src/render/block_view.dart';
import 'package:sherpa_markdown/src/render/syntax_highlighter.dart';

import '../support/harness.dart';
import '../support/sample_document.dart';
import '../support/span_helpers.dart';

void main() {
  tearDown(() => MarkdownBlockView.debugOnBuild = null);

  testWidgets('a new token rebuilds only the open block', (tester) async {
    final built = <String>[];
    MarkdownBlockView.debugOnBuild = (block) => built.add(block.id);
    const head = '# Title\n\nFirst paragraph.\n\n```dart\nvoid main() {}\n```\n\nStreaming';
    await pumpMarkdown(tester, head, streaming: true);
    expect(built, ['b0', 'b1', 'b2', 'b3']);

    for (final token in [' text', ' goes', ' on', '.']) {
      built.clear();
      await pumpMarkdown(tester, '$head${'' /* grows */}$token', streaming: true);
    }
    // Each update rebuilt just the last block.
    built.clear();
    await pumpMarkdown(tester, '$head and more', streaming: true);
    expect(built, ['b3']);

    // Finishing the stream rebuilds only the block that froze.
    built.clear();
    await pumpMarkdown(tester, '$head and more');
    expect(built, ['b3']);
  });

  testWidgets('a rebuilt host with an equal style does not rebuild blocks', (tester) async {
    final built = <String>[];
    await pumpMarkdown(tester, sampleDocument);
    MarkdownBlockView.debugOnBuild = (block) => built.add(block.id);
    await pumpMarkdown(tester, sampleDocument, style: const SherpaMarkdownStyle());
    expect(built, isEmpty);
  });

  testWidgets('every block sits in its own RepaintBoundary', (tester) async {
    await pumpMarkdown(tester, '# A\n\nB\n\n- c\n\nlive', streaming: true);
    final views = find.byType(MarkdownBlockView);
    expect(views, findsNWidgets(4));
    for (final element in views.evaluate()) {
      final boundary = element.findAncestorWidgetOfExactType<RepaintBoundary>();
      expect(boundary, isNotNull);
      expect(boundary!.key, isA<ValueKey<String>>());
    }
  });

  testWidgets('code is highlighted only after the fence closes', (tester) async {
    const open = '```dart\nfinal x = 1;';
    await pumpMarkdown(tester, open, streaming: true);
    final plainSpans = leafSpans(tester).where((s) => s.span.text!.contains('final'));
    expect(plainSpans.single.span.text, 'final x = 1;');

    await pumpMarkdown(tester, '$open\n```\n', streaming: true);
    final keyword = spanContaining(tester, 'final');
    expect(keyword.span.text, 'final');
    expect(keyword.style.color, isNot(spanContaining(tester, ' x ').style.color));
  });

  testWidgets('large blocks are highlighted off the UI isolate', (tester) async {
    SyntaxHighlighter.clearCache();
    final code = List.generate(200, (i) => 'final value$i = compute($i);').join('\n');
    expect(code.length, greaterThan(SyntaxHighlighter.isolateThreshold));
    await pumpMarkdown(tester, '```dart\n$code\n```');
    // First frame: plain text while the isolate works.
    expect(leafSpans(tester).where((s) => s.span.text == 'final'), isEmpty);
    bool highlighted() => leafSpans(tester).where((s) => s.span.text == 'final').length == 200;
    // The isolate runs in real time; its result is delivered on a pump.
    for (var i = 0; i < 200 && !highlighted(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(highlighted(), isTrue);
  });

  testWidgets('tokenizer output covers the code exactly', (tester) async {
    const code = 'def f(x):\n    return x * 2  # double\n';
    final tokens = tokenize((code: code, language: 'python'));
    expect(tokens.first.start, 0);
    expect(tokens.last.end, code.length);
    for (var i = 1; i < tokens.length; i++) {
      expect(tokens[i].start, tokens[i - 1].end);
    }
    expect(tokens.map((t) => t.scope), contains('keyword'));
  });

  group('accessibility', () {
    testWidgets('no node is a live region', (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpMarkdown(tester, sampleDocument.substring(0, 600), streaming: true);
      final root = tester.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!;
      var liveRegions = 0;
      bool visit(SemanticsNode node) {
        if (node.getSemanticsData().flagsCollection.isLiveRegion) liveRegions++;
        node.visitChildren(visit);
        return true;
      }

      visit(root);
      expect(liveRegions, 0);
      semantics.dispose();
    });

    testWidgets('with a screen reader on, the live tail is hidden until it freezes',
        (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpMarkdown(
        tester,
        'Settled paragraph.\n\nStill streaming',
        streaming: true,
        accessibleNavigation: true,
      );
      expect(find.bySemanticsLabel('Settled paragraph.'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('Still streaming')), findsNothing);

      await pumpMarkdown(
        tester,
        'Settled paragraph.\n\nStill streaming',
        accessibleNavigation: true,
      );
      expect(find.bySemanticsLabel(RegExp('Still streaming')), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('without a screen reader the tail stays readable', (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpMarkdown(tester, 'one\n\ntwo', streaming: true);
      expect(find.bySemanticsLabel('two'), findsOneWidget);
      semantics.dispose();
    });
  });

  testWidgets('selectable participates in the host SelectionArea', (tester) async {
    await pumpMarkdown(tester, 'pick me');
    expect(
      tester.widget<RichText>(find.text('pick me', findRichText: true)).selectionRegistrar,
      isNotNull,
    );
    await pumpMarkdown(tester, 'pick me', selectable: false);
    expect(
      tester.widget<RichText>(find.text('pick me', findRichText: true)).selectionRegistrar,
      isNull,
    );
  });

  testWidgets('tentative bold while streaming never shows asterisks', (tester) async {
    for (final partial in ['Say **', 'Say **he', 'Say **hello', 'Say **hello**']) {
      await pumpMarkdown(tester, partial, streaming: true);
      final text = leafSpans(tester).map((s) => s.span.text).join();
      expect(text, isNot(contains('*')), reason: partial);
    }
    expect(spanContaining(tester, 'hello').style.fontWeight, FontWeight.w700);
  });
}
