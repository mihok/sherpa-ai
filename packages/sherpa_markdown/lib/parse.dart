/// The pure-Dart incremental Markdown parser behind `StreamingMarkdown`.
///
/// No Flutter imports: usable from pure-Dart packages and isolates.
library;

export 'src/parse/incremental_parser.dart' show IncrementalMarkdownParser;
export 'src/parse/md_ast.dart' hide mdListEquals;
export 'src/parse/md_block.dart';
