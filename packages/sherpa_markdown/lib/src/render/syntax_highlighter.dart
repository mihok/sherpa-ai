import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:re_highlight/languages/bash.dart';
import 'package:re_highlight/languages/c.dart';
import 'package:re_highlight/languages/cmake.dart';
import 'package:re_highlight/languages/cpp.dart';
import 'package:re_highlight/languages/csharp.dart';
import 'package:re_highlight/languages/css.dart';
import 'package:re_highlight/languages/dart.dart';
import 'package:re_highlight/languages/diff.dart';
import 'package:re_highlight/languages/dockerfile.dart';
import 'package:re_highlight/languages/elixir.dart';
import 'package:re_highlight/languages/go.dart';
import 'package:re_highlight/languages/graphql.dart';
import 'package:re_highlight/languages/groovy.dart';
import 'package:re_highlight/languages/haskell.dart';
import 'package:re_highlight/languages/ini.dart';
import 'package:re_highlight/languages/java.dart';
import 'package:re_highlight/languages/javascript.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/languages/julia.dart';
import 'package:re_highlight/languages/kotlin.dart';
import 'package:re_highlight/languages/latex.dart';
import 'package:re_highlight/languages/lua.dart';
import 'package:re_highlight/languages/makefile.dart';
import 'package:re_highlight/languages/markdown.dart';
import 'package:re_highlight/languages/nginx.dart';
import 'package:re_highlight/languages/objectivec.dart';
import 'package:re_highlight/languages/perl.dart';
import 'package:re_highlight/languages/php.dart';
import 'package:re_highlight/languages/plaintext.dart';
import 'package:re_highlight/languages/powershell.dart';
import 'package:re_highlight/languages/protobuf.dart';
import 'package:re_highlight/languages/python.dart';
import 'package:re_highlight/languages/r.dart';
import 'package:re_highlight/languages/ruby.dart';
import 'package:re_highlight/languages/rust.dart';
import 'package:re_highlight/languages/scala.dart';
import 'package:re_highlight/languages/scss.dart';
import 'package:re_highlight/languages/shell.dart';
import 'package:re_highlight/languages/sql.dart';
import 'package:re_highlight/languages/swift.dart';
import 'package:re_highlight/languages/typescript.dart';
import 'package:re_highlight/languages/xml.dart';
import 'package:re_highlight/languages/yaml.dart';
import 'package:re_highlight/re_highlight.dart';

/// A highlighted run: `code.substring(start, end)` has highlight.js scope
/// [scope] (null = plain).
@immutable
final class HighlightToken {
  const HighlightToken(this.start, this.end, this.scope);

  final int start;
  final int end;
  final String? scope;

  @override
  bool operator ==(Object other) =>
      other is HighlightToken &&
      start == other.start &&
      end == other.end &&
      scope == other.scope;

  @override
  int get hashCode => Object.hash(start, end, scope);
}

/// Syntax highlighting with `re_highlight` (a highlight.js port).
///
/// Only a curated set of languages is registered: each grammar is code in
/// the app binary, and chat output overwhelmingly uses these. Highlighting
/// produces plain offset/scope tokens rather than `TextSpan`s so the work
/// can run on a background isolate and the styling (which depends on the
/// theme) stays on the UI side.
abstract final class SyntaxHighlighter {
  /// Blocks longer than this many characters are highlighted with
  /// `compute` instead of on the UI isolate. With Flutter's merged
  /// platform/UI thread a long synchronous highlight would also stall
  /// platform input; below this size highlighting takes well under a
  /// millisecond.
  static int isolateThreshold = 2000;

  static const _cacheSize = 64;
  static final _cache = <String, List<HighlightToken>>{};

  /// Common fence labels that highlight.js does not alias the way chat
  /// output means them. `shell` in highlight.js is a *session* grammar
  /// (prompt + output); models use it for plain commands.
  static const _extraAliases = <String, String>{
    'shell': 'bash',
    'zsh': 'bash',
    'console': 'shell',
    'terminal': 'shell',
    'jsonc': 'json',
    'json5': 'json',
    'toml': 'ini',
    'html': 'xml',
    'vue': 'xml',
    'kt': 'kotlin',
    'objc': 'objectivec',
    'text': 'plaintext',
    'txt': 'plaintext',
  };

  /// The registered grammar name for a fence [language], or null if none.
  static String? resolve(String? language) {
    if (language == null || language.isEmpty) return null;
    final key = _extraAliases[language] ?? language;
    return _highlight.getLanguage(key) == null ? null : key;
  }

  /// Cached tokens for [code] in [language], if any.
  static List<HighlightToken>? cached(String code, String language) {
    final key = _key(code, language);
    final hit = _cache.remove(key);
    if (hit != null) _cache[key] = hit;
    return hit;
  }

  /// Highlights on the calling isolate.
  static List<HighlightToken> highlightSync(String code, String language) {
    final tokens = tokenize((code: code, language: language));
    _store(code, language, tokens);
    return tokens;
  }

  /// Highlights on a background isolate.
  static Future<List<HighlightToken>> highlightAsync(
    String code,
    String language,
  ) async {
    final tokens = await compute(
      tokenize,
      (code: code, language: language),
      debugLabel: 'sherpa_markdown highlight',
    );
    _store(code, language, tokens);
    return tokens;
  }

  /// Builds a styled span for [code] from [tokens].
  static TextSpan toSpan(
    String code,
    List<HighlightToken> tokens,
    TextStyle base,
    Map<String, TextStyle> theme,
  ) {
    final children = <TextSpan>[
      for (final t in tokens)
        TextSpan(
          text: code.substring(t.start, t.end),
          style: t.scope == null ? null : _styleFor(t.scope!, theme),
        ),
    ];
    return TextSpan(style: base, children: children);
  }

  static TextStyle? _styleFor(String scope, Map<String, TextStyle> theme) {
    var s = scope;
    while (true) {
      final style = theme[s];
      if (style != null) {
        // Themes set a page background on `root`; the code block owns the
        // background, so only per-token colours and weights are kept.
        return TextStyle(
          color: style.color,
          fontWeight: style.fontWeight,
          fontStyle: style.fontStyle,
          decoration: style.decoration,
        );
      }
      final dot = s.lastIndexOf('.');
      if (dot <= 0) return null;
      s = s.substring(0, dot);
    }
  }

  static String _key(String code, String language) => '$language\u0000$code';

  static void _store(String code, String language, List<HighlightToken> t) {
    _cache[_key(code, language)] = t;
    if (_cache.length > _cacheSize) _cache.remove(_cache.keys.first);
  }

  @visibleForTesting
  static void clearCache() => _cache.clear();
}

/// Top-level so `compute` can send it to another isolate. Each isolate
/// builds its own [Highlight] registry lazily.
List<HighlightToken> tokenize(({String code, String language}) request) {
  final result = _highlight.highlight(
    code: request.code,
    language: request.language,
  );
  final collector = _TokenCollector();
  result.render(collector);
  // If the grammar ever rewrote the text, offsets would be wrong: fall back
  // to a single plain run rather than mis-coloured code.
  if (collector.offset != request.code.length) {
    return [HighlightToken(0, request.code.length, null)];
  }
  return collector.tokens;
}

final Highlight _highlight = Highlight()
  ..registerLanguages({
    'bash': langBash,
    'c': langC,
    'cmake': langCmake,
    'cpp': langCpp,
    'csharp': langCsharp,
    'css': langCss,
    'dart': langDart,
    'diff': langDiff,
    'dockerfile': langDockerfile,
    'elixir': langElixir,
    'go': langGo,
    'graphql': langGraphql,
    'groovy': langGroovy,
    'haskell': langHaskell,
    'ini': langIni,
    'java': langJava,
    'javascript': langJavascript,
    'json': langJson,
    'julia': langJulia,
    'kotlin': langKotlin,
    'latex': langLatex,
    'lua': langLua,
    'makefile': langMakefile,
    'markdown': langMarkdown,
    'nginx': langNginx,
    'objectivec': langObjectivec,
    'perl': langPerl,
    'php': langPhp,
    'plaintext': langPlaintext,
    'powershell': langPowershell,
    'protobuf': langProtobuf,
    'python': langPython,
    'r': langR,
    'ruby': langRuby,
    'rust': langRust,
    'scala': langScala,
    'scss': langScss,
    'shell': langShell,
    'sql': langSql,
    'swift': langSwift,
    'typescript': langTypescript,
    'xml': langXml,
    'yaml': langYaml,
  });

final class _TokenCollector implements HighlightRenderer {
  final tokens = <HighlightToken>[];
  final _scopes = <String?>[];
  int offset = 0;

  @override
  void addText(String text) {
    if (text.isEmpty) return;
    String? scope;
    for (var i = _scopes.length - 1; i >= 0; i--) {
      if (_scopes[i] != null) {
        scope = _scopes[i];
        break;
      }
    }
    final end = offset + text.length;
    if (tokens.isNotEmpty &&
        tokens.last.scope == scope &&
        tokens.last.end == offset) {
      tokens[tokens.length - 1] = HighlightToken(tokens.last.start, end, scope);
    } else {
      tokens.add(HighlightToken(offset, end, scope));
    }
    offset = end;
  }

  @override
  void openNode(DataNode node) => _scopes.add(node.scope);

  @override
  void closeNode(DataNode node) {
    if (_scopes.isNotEmpty) _scopes.removeLast();
  }
}
