import 'package:flutter_math_fork/flutter_math.dart';
import 'package:material_ui/material_ui.dart';

import 'markdown_scope.dart';

/// TeX rendered with flutter_math_fork, falling back to the raw source.
///
/// `Math` only needs `DefaultTextStyle` and `MediaQuery`, so it works under
/// `material_ui` without the legacy-Material compatibility bridge (its
/// default error widget would need one; we always pass our own fallback).
class MathView extends StatelessWidget {
  const MathView({
    super.key,
    required this.tex,
    required this.display,
    required this.style,
    required this.fallbackStyle,
    this.inline = false,
    this.complete = true,
  });

  final String tex;

  /// Display style (large operators, centred) vs. text style.
  final bool display;
  final TextStyle style;

  /// Monospace style used for raw TeX (incomplete or unparsable).
  final TextStyle fallbackStyle;

  /// Inside a `WidgetSpan`: the span already applies text scaling.
  final bool inline;

  /// False while a `$$` block is still streaming: partial TeX is shown raw
  /// instead of flipping between "parse error" and "formula" per token.
  final bool complete;

  @override
  Widget build(BuildContext context) {
    final Widget content;
    if (!complete) {
      content = _raw();
    } else {
      final fontSize = style.fontSize ?? 16;
      final scaler = inline
          ? TextScaler.noScaling
          : MediaQuery.textScalerOf(context);
      content = Math.tex(
        tex,
        mathStyle: display ? MathStyle.display : MathStyle.text,
        textStyle: style,
        textScaleFactor: scaler.scale(fontSize) / fontSize,
        onErrorFallback: (_) => _raw(),
      );
    }
    final labelled = Semantics(
      label: tex,
      container: !inline,
      child: ExcludeSemantics(child: content),
    );
    if (inline) return labelled;
    // Wide equations scroll horizontally instead of overflowing; narrow
    // ones are centred.
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: constraints.maxWidth),
          child: Center(child: labelled),
        ),
      ),
    );
  }

  Widget _raw() => Text(tex, style: fallbackStyle, softWrap: inline);
}

/// A `$$ … $$` / `\[ … \]` block.
class MathBlockView extends StatelessWidget {
  const MathBlockView({super.key, required this.tex, required this.complete});

  final String tex;
  final bool complete;

  @override
  Widget build(BuildContext context) {
    final theme = MarkdownScope.of(context).theme;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: theme.fontSize * 0.25),
      child: MathView(
        tex: tex,
        display: true,
        complete: complete,
        style: theme.body.copyWith(fontSize: theme.fontSize * 1.1),
        fallbackStyle: theme.code.copyWith(color: theme.quoteText),
      ),
    );
  }
}
