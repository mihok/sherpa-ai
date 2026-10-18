import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa_markdown/sherpa_markdown.dart';

/// Wraps [child] the way the chat UI does: a themed app, a scrollable
/// message column and a per-message `SelectionArea`.
Widget markdownApp(
  Widget child, {
  Brightness brightness = Brightness.light,
  double textScale = 1.0,
  bool accessibleNavigation = false,
}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    themeAnimationDuration: Duration.zero,
    theme: ThemeData(
      brightness: brightness,
      colorSchemeSeed: const Color(0xFF3A6EA5),
    ),
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          accessibleNavigation: accessibleNavigation,
        ),
        child: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: SelectionArea(child: child),
          ),
        ),
      ),
    ),
  );
}

/// Pumps a [StreamingMarkdown] for [text].
Future<void> pumpMarkdown(
  WidgetTester tester,
  String text, {
  bool streaming = false,
  void Function(Uri uri)? onLinkTap,
  void Function(String code)? onCopyCode,
  SherpaMarkdownStyle style = const SherpaMarkdownStyle(),
  Brightness brightness = Brightness.light,
  double textScale = 1.0,
  bool accessibleNavigation = false,
  bool selectable = true,
}) async {
  await tester.pumpWidget(
    markdownApp(
      StreamingMarkdown(
        text: text,
        streaming: streaming,
        onLinkTap: onLinkTap,
        onCopyCode: onCopyCode,
        style: style,
        selectable: selectable,
      ),
      brightness: brightness,
      textScale: textScale,
      accessibleNavigation: accessibleNavigation,
    ),
  );
}

/// Sets the test surface to [width]×[height] logical pixels at DPR 1.
void setSurface(
  WidgetTester tester,
  double width,
  double height, {
  double dpr = 1,
}) {
  tester.view.physicalSize = Size(width * dpr, height * dpr);
  tester.view.devicePixelRatio = dpr;
  addTearDown(tester.view.reset);
}
