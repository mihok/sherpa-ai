import 'package:material_ui/material_ui.dart';
import 'package:re_highlight/styles/github-dark.dart';
import 'package:re_highlight/styles/github.dart';

/// Colors and text styles the host app supplies (sherpa_markdown cannot
/// depend on the app's design tokens). Every field is optional; unset
/// fields are derived from the ambient [Theme] so light and dark mode work
/// without configuration.
@immutable
class SherpaMarkdownStyle {
  const SherpaMarkdownStyle({
    this.body,
    this.code,
    this.codeBackground,
    this.quoteColor,
    this.linkColor,
    this.dividerColor,
    this.headings,
    this.inlineCode,
    this.syntaxTheme,
    this.tableBorderColor,
    this.tableHeaderBackground,
    this.blockSpacing,
    this.maxImageHeight,
  });

  /// Paragraph text. Defaults to the theme's `bodyLarge`.
  final TextStyle? body;

  /// Code-block text. Defaults to a monospace variant of [body].
  final TextStyle? code;

  /// Background of code blocks and inline code.
  final Color? codeBackground;

  /// Colour of the bar at the start of a block quote.
  final Color? quoteColor;
  final Color? linkColor;

  /// Thematic breaks and table borders (unless [tableBorderColor] is set).
  final Color? dividerColor;

  /// Overrides for heading levels 1–6, in order; shorter lists override
  /// only the first levels. Merged over the derived defaults.
  final List<TextStyle>? headings;

  /// Inline `code` spans. Defaults to [code] at body size on
  /// [codeBackground].
  final TextStyle? inlineCode;

  /// A `re_highlight` theme (scope → style). Defaults to GitHub light/dark
  /// by brightness.
  final Map<String, TextStyle>? syntaxTheme;
  final Color? tableBorderColor;
  final Color? tableHeaderBackground;

  /// Vertical gap between blocks. Defaults to 0.75 × the body font size.
  final double? blockSpacing;

  /// Height cap for loaded images (logical pixels). Defaults to 320.
  final double? maxImageHeight;

  SherpaMarkdownStyle copyWith({
    TextStyle? body,
    TextStyle? code,
    Color? codeBackground,
    Color? quoteColor,
    Color? linkColor,
    Color? dividerColor,
    List<TextStyle>? headings,
    TextStyle? inlineCode,
    Map<String, TextStyle>? syntaxTheme,
    Color? tableBorderColor,
    Color? tableHeaderBackground,
    double? blockSpacing,
    double? maxImageHeight,
  }) => SherpaMarkdownStyle(
    body: body ?? this.body,
    code: code ?? this.code,
    codeBackground: codeBackground ?? this.codeBackground,
    quoteColor: quoteColor ?? this.quoteColor,
    linkColor: linkColor ?? this.linkColor,
    dividerColor: dividerColor ?? this.dividerColor,
    headings: headings ?? this.headings,
    inlineCode: inlineCode ?? this.inlineCode,
    syntaxTheme: syntaxTheme ?? this.syntaxTheme,
    tableBorderColor: tableBorderColor ?? this.tableBorderColor,
    tableHeaderBackground: tableHeaderBackground ?? this.tableHeaderBackground,
    blockSpacing: blockSpacing ?? this.blockSpacing,
    maxImageHeight: maxImageHeight ?? this.maxImageHeight,
  );

  // Value equality lets a host build a new style object every frame without
  // invalidating the renderer's cached, frozen blocks.
  @override
  bool operator ==(Object other) =>
      other is SherpaMarkdownStyle &&
      body == other.body &&
      code == other.code &&
      codeBackground == other.codeBackground &&
      quoteColor == other.quoteColor &&
      linkColor == other.linkColor &&
      dividerColor == other.dividerColor &&
      _listEq(headings, other.headings) &&
      inlineCode == other.inlineCode &&
      identical(syntaxTheme, other.syntaxTheme) &&
      tableBorderColor == other.tableBorderColor &&
      tableHeaderBackground == other.tableHeaderBackground &&
      blockSpacing == other.blockSpacing &&
      maxImageHeight == other.maxImageHeight;

  @override
  int get hashCode => Object.hash(
    body,
    code,
    codeBackground,
    quoteColor,
    linkColor,
    dividerColor,
    headings == null ? null : Object.hashAll(headings!),
    inlineCode,
    syntaxTheme == null ? null : identityHashCode(syntaxTheme),
    tableBorderColor,
    tableHeaderBackground,
    blockSpacing,
    maxImageHeight,
  );
}

bool _listEq(List<TextStyle>? a, List<TextStyle>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null || a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Monospace families tried in order: Android resolves `monospace`; iOS
/// has Menlo; desktop test hosts usually have one of the others.
const kMonospaceFallback = <String>[
  'Roboto Mono',
  'Menlo',
  'SF Mono',
  'Consolas',
  'Courier New',
  'Courier',
];

/// [SherpaMarkdownStyle] with every value resolved against the ambient
/// theme. Computed once per build of `StreamingMarkdown` and shared with
/// all block widgets through an inherited scope; value equality means a
/// rebuild with an unchanged theme does not ripple into frozen blocks.
@immutable
final class MarkdownTheme {
  const MarkdownTheme({
    required this.brightness,
    required this.body,
    required this.code,
    required this.inlineCode,
    required this.inlineCodeColor,
    required this.codeBackground,
    required this.codeChrome,
    required this.quoteBar,
    required this.quoteText,
    required this.link,
    required this.divider,
    required this.tableBorder,
    required this.tableHeaderBackground,
    required this.headings,
    required this.syntax,
    required this.blockSpacing,
    required this.maxImageHeight,
    required this.chipBackground,
    required this.chipForeground,
    required this.taskChecked,
    required this.taskUnchecked,
  });

  /// Resolves [style] against [Theme] and [DefaultTextStyle].
  factory MarkdownTheme.resolve(
    BuildContext context,
    SherpaMarkdownStyle style,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final body = DefaultTextStyle.of(context).style
        .merge(theme.textTheme.bodyLarge)
        .merge(style.body);
    final size = body.fontSize ?? 16;
    final code =
        style.code ??
        body.copyWith(
          fontFamily: 'monospace',
          fontFamilyFallback: kMonospaceFallback,
          fontSize: size * 0.875,
          height: 1.45,
        );
    final codeBackground =
        style.codeBackground ?? scheme.surfaceContainerHighest;
    final inlineCode =
        style.inlineCode ??
        code.copyWith(
          fontSize: size * 0.9,
          height: body.height,
          backgroundColor: codeBackground,
        );
    final defaults = <TextStyle>[
      body.copyWith(
        fontSize: size * 1.5,
        fontWeight: FontWeight.w700,
        height: 1.25,
      ),
      body.copyWith(
        fontSize: size * 1.3,
        fontWeight: FontWeight.w700,
        height: 1.3,
      ),
      body.copyWith(
        fontSize: size * 1.15,
        fontWeight: FontWeight.w600,
        height: 1.3,
      ),
      body.copyWith(fontSize: size * 1.05, fontWeight: FontWeight.w600),
      body.copyWith(fontWeight: FontWeight.w600),
      body.copyWith(
        fontSize: size * 0.95,
        fontWeight: FontWeight.w600,
        color: scheme.onSurfaceVariant,
      ),
    ];
    final overrides = style.headings ?? const <TextStyle>[];
    final dark = theme.brightness == Brightness.dark;
    final divider = style.dividerColor ?? scheme.outlineVariant;
    return MarkdownTheme(
      brightness: theme.brightness,
      body: body,
      code: code,
      inlineCode: inlineCode,
      inlineCodeColor: style.inlineCode?.color,
      codeBackground: codeBackground,
      codeChrome: scheme.onSurfaceVariant,
      quoteBar: style.quoteColor ?? scheme.outlineVariant,
      quoteText: scheme.onSurfaceVariant,
      link: style.linkColor ?? scheme.primary,
      divider: divider,
      tableBorder: style.tableBorderColor ?? divider,
      tableHeaderBackground:
          style.tableHeaderBackground ?? scheme.surfaceContainerHigh,
      headings: [
        for (var i = 0; i < 6; i++)
          i < overrides.length ? defaults[i].merge(overrides[i]) : defaults[i],
      ],
      syntax: style.syntaxTheme ?? (dark ? githubDarkTheme : githubTheme),
      blockSpacing: style.blockSpacing ?? size * 0.75,
      maxImageHeight: style.maxImageHeight ?? 320,
      chipBackground: scheme.secondaryContainer,
      chipForeground: scheme.onSecondaryContainer,
      taskChecked: scheme.primary,
      taskUnchecked: scheme.outline,
    );
  }

  final Brightness brightness;
  final TextStyle body;
  final TextStyle code;
  final TextStyle inlineCode;

  /// The host's explicit inline-code colour, if any.
  final Color? inlineCodeColor;
  final Color codeBackground;

  /// Language label and copy icon on code blocks.
  final Color codeChrome;
  final Color quoteBar;
  final Color quoteText;
  final Color link;
  final Color divider;
  final Color tableBorder;
  final Color tableHeaderBackground;

  /// Heading styles for levels 1–6.
  final List<TextStyle> headings;
  final Map<String, TextStyle> syntax;
  final double blockSpacing;
  final double maxImageHeight;
  final Color chipBackground;
  final Color chipForeground;
  final Color taskChecked;
  final Color taskUnchecked;

  double get fontSize => body.fontSize ?? 16;

  @override
  bool operator ==(Object other) =>
      other is MarkdownTheme &&
      brightness == other.brightness &&
      body == other.body &&
      code == other.code &&
      inlineCode == other.inlineCode &&
      inlineCodeColor == other.inlineCodeColor &&
      codeBackground == other.codeBackground &&
      codeChrome == other.codeChrome &&
      quoteBar == other.quoteBar &&
      quoteText == other.quoteText &&
      link == other.link &&
      divider == other.divider &&
      tableBorder == other.tableBorder &&
      tableHeaderBackground == other.tableHeaderBackground &&
      _listEq(headings, other.headings) &&
      identical(syntax, other.syntax) &&
      blockSpacing == other.blockSpacing &&
      maxImageHeight == other.maxImageHeight &&
      chipBackground == other.chipBackground &&
      chipForeground == other.chipForeground &&
      taskChecked == other.taskChecked &&
      taskUnchecked == other.taskUnchecked;

  @override
  int get hashCode => Object.hash(
    brightness,
    body,
    code,
    inlineCode,
    codeBackground,
    link,
    Object.hashAll(headings),
    identityHashCode(syntax),
    blockSpacing,
    maxImageHeight,
  );
}
