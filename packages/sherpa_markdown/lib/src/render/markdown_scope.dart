import 'package:material_ui/material_ui.dart';

import 'markdown_style.dart';

/// Host callbacks, behind a stable object.
///
/// Hosts usually pass fresh closures on every build. Block widgets capture
/// this object instead of the closures, and it always forwards to the
/// latest ones, so cached frozen blocks never need rebuilding just because
/// a callback's identity changed.
final class MarkdownCallbacks {
  void Function(Uri uri)? onLinkTap;
  void Function(String code)? onCopyCode;

  void linkTap(Uri uri) => onLinkTap?.call(uri);

  void copiedCode(String code) => onCopyCode?.call(code);
}

/// Per-`StreamingMarkdown` configuration visible to every block widget.
class MarkdownScope extends InheritedWidget {
  const MarkdownScope({
    super.key,
    required this.theme,
    required this.callbacks,
    required this.linkSchemes,
    required super.child,
  });

  final MarkdownTheme theme;
  final MarkdownCallbacks callbacks;

  /// Lower-case URI schemes that are rendered as tappable links.
  final Set<String> linkSchemes;

  static MarkdownScope of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<MarkdownScope>();
    assert(scope != null, 'No MarkdownScope above this block widget.');
    return scope!;
  }

  bool allowsLink(Uri uri) => linkSchemes.contains(uri.scheme.toLowerCase());

  @override
  bool updateShouldNotify(MarkdownScope oldWidget) =>
      theme != oldWidget.theme ||
      !identical(callbacks, oldWidget.callbacks) ||
      !_setEquals(linkSchemes, oldWidget.linkSchemes);
}

bool _setEquals(Set<String> a, Set<String> b) =>
    identical(a, b) || (a.length == b.length && a.containsAll(b));
