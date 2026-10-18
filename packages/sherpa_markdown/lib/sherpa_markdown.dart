/// Incremental streaming Markdown rendering for Sherpa.
///
/// * [StreamingMarkdown] renders a (possibly still growing) model reply.
/// * [SherpaMarkdownStyle] lets the host supply its design tokens.
/// * The pure-Dart parser ([IncrementalMarkdownParser], [MdBlock], the
///   `Md*` AST) is also available on its own via `parse.dart`, e.g. for
///   word counts or copy-as-text.
library;

export 'parse.dart';
export 'src/render/markdown_style.dart' show SherpaMarkdownStyle;
export 'src/render/streaming_markdown.dart';
