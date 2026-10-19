/// Tool-poisoning markers in server-supplied text (R11 §(e), §9.7).
library;

import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart' show JsonMap;
import 'package:sherpa_net/sherpa_net.dart' show Redactor;

/// How bad a finding is.
enum HygieneSeverity {
  /// Suspicious but common in honest descriptions (imperatives, length):
  /// the tool stays usable, but every call needs the user's confirmation.
  warning,

  /// No honest reason to be there (hidden tags, concealment, hidden
  /// characters, credential paths, cross-server instructions): the tool is
  /// quarantined until the user has looked at it, even on a trusted server.
  critical,
}

/// What kind of marker was found.
enum HygieneFindingKind {
  /// `<IMPORTANT>`, `<SYSTEM>`, chat-template tokens, HTML comments: the
  /// Invariant Labs poisoning carrier.
  hiddenInstructionTag,

  /// "do not tell the user", "without informing the user", …
  concealment,

  /// "ignore previous instructions", "you are now", "system prompt", …
  promptOverride,

  /// Mentions another server's tools or tells the model how to use other
  /// tools (shadowing, R11 §(e)).
  crossToolInstruction,

  /// `~/.ssh`, `id_rsa`, `mcp.json`, `.env`, cloud credential files, …
  sensitivePath,

  /// Asks for secrets ("include the API key", "pass the token").
  credentialRequest,

  /// "always call …", "before any …", "you must …".
  imperative,

  /// Zero-width, bidi-control, tag (ASCII smuggling) and other invisible
  /// format characters.
  hiddenCharacters,

  /// A markdown image or "send … to http…" (exfiltration channel).
  exfiltration,

  /// A long base64-looking run.
  encodedPayload,

  /// The description (or all schema text) is unusually long.
  overlong,

  /// The schema has a `$ref` that is not local (never fetched).
  externalRef,
}

/// One finding, safe to show in the UI.
@immutable
final class HygieneFinding {
  const HygieneFinding({
    required this.kind,
    required this.severity,
    required this.message,
    required this.location,
    this.excerpt,
  });

  factory HygieneFinding.fromJson(JsonMap j) => HygieneFinding(
        kind: HygieneFindingKind.values.byName(j['kind']! as String),
        severity: HygieneSeverity.values.byName(j['severity']! as String),
        message: j['message']! as String,
        location: j['location']! as String,
        excerpt: j['excerpt'] as String?,
      );

  final HygieneFindingKind kind;
  final HygieneSeverity severity;

  /// A sentence for the review screen.
  final String message;

  /// Where: `description`, `title`, `inputSchema.properties.x.description`.
  final String location;

  /// ≤ 80 chars around the match, invisible characters shown as `<U+200B>`,
  /// secrets redacted.
  final String? excerpt;

  bool get isCritical => severity == HygieneSeverity.critical;

  JsonMap toJson() => {
        'kind': kind.name,
        'severity': severity.name,
        'message': message,
        'location': location,
        if (excerpt != null) 'excerpt': excerpt,
      };

  @override
  String toString() => '[${severity.name}] ${kind.name} at $location: $message';
}

/// Scans tool definitions (and server instructions) for injection markers.
///
/// Heuristic and deliberately conservative: it cannot prove a description
/// safe (adaptive attacks beat every prompt-level filter, R11 §(e)); its job
/// is to make the obvious carriers of the published attacks visible and to
/// force a human look (quarantine for critical findings, per-call approval
/// for warnings). Everything a model would read is scanned: title,
/// description and every nested `title`/`description` in the schemas, since
/// a poisoned parameter description works as well as a poisoned tool one.
final class ToolDescriptionScanner {
  const ToolDescriptionScanner({this.maxDescriptionChars = 1024, this.maxTotalChars = 4096});

  /// Longer descriptions get an [HygieneFindingKind.overlong] warning.
  final int maxDescriptionChars;

  /// Total text (description + all schema text) above this is flagged too.
  final int maxTotalChars;

  static final List<(RegExp, HygieneFindingKind, HygieneSeverity, String)> _rules = [
    (
      RegExp(r'<\s*/?\s*(important|system|instructions?|secret|hidden|admin|override|assistant|prompt)\b[^>]*>',
          caseSensitive: false),
      HygieneFindingKind.hiddenInstructionTag,
      HygieneSeverity.critical,
      'Contains a hidden-instruction tag (the tool-poisoning carrier).',
    ),
    (
      RegExp(
          r'<\|(im_start|im_end|system|user|assistant|eot_id|start_header_id|end_header_id)\|>|'
          r'\[/?INST\]|<<\s*/?SYS\s*>>',
          caseSensitive: false),
      HygieneFindingKind.hiddenInstructionTag,
      HygieneSeverity.critical,
      'Contains chat-template control tokens.',
    ),
    (
      RegExp(r'<!--[\s\S]*?-->'),
      HygieneFindingKind.hiddenInstructionTag,
      HygieneSeverity.critical,
      'Contains an HTML comment (text the user would not see).',
    ),
    (
      RegExp(
          r"\b(do\s*n[o']?t|never|must\s+not|should\s*n[o']?t)\s+"
          r'(tell|inform|mention|reveal|show|notify|alert|disclose)\b[^.]{0,80}\b(user|human|them|anyone)\b|'
          r'\bwithout\s+(telling|informing|notifying|alerting|asking)\s+(the\s+)?(user|human)\b|'
          r'\b(hide|conceal|keep)\b[^.]{0,30}\bfrom\s+(the\s+)?(user|human)\b|'
          r'\bthe\s+user\s+(must|should)\s+(not|never)\s+(know|see|notice)\b',
          caseSensitive: false),
      HygieneFindingKind.concealment,
      HygieneSeverity.critical,
      'Tells the model to hide something from the user.',
    ),
    (
      RegExp(
          r'\b(ignore|disregard|forget|override)\s+(all\s+|any\s+)?(the\s+)?(previous|prior|above|'
          r'earlier|other|system|safety)\s+(instructions?|rules?|prompts?|messages?|guidelines?)\b|'
          r'\byou\s+are\s+now\b|\bsystem\s+prompt\b|\bnew\s+instructions?\s*:',
          caseSensitive: false),
      HygieneFindingKind.promptOverride,
      HygieneSeverity.critical,
      'Tries to override the model\'s instructions.',
    ),
    (
      RegExp(
          r'\b(before|after|instead\s+of|when(ever)?)\s+(using|calling|invoking|running)\s+(any|every|'
          r'all|other|another|the\s+other)\b|\b(all|any|every|'
          r'other)\s+(other\s+)?tools?\b[^.]{0,40}\b(must|should|need\s+to|have\s+to|always)\b|\b(send|'
          r'forward|redirect|cc|bcc)\b[^.]{0,30}\b(all|every)\s+(emails?|messages?|requests?)\b',
          caseSensitive: false),
      HygieneFindingKind.crossToolInstruction,
      HygieneSeverity.critical,
      'Gives instructions about other tools (shadowing).',
    ),
    (
      RegExp(
          r'~/\.ssh|\.ssh/|\bid_(rsa|dsa|ecdsa|ed25519)\b|\bmcp\.json\b|claude_desktop_config|\.cursor/|'
          r'\.aws/credentials|\.config/gcloud|\.kube/config|\.docker/config\.json|\.npmrc\b|\.netrc\b|'
          r'\.git-credentials|\.pgpass\b|/etc/(passwd|shadow)\b|(^|[\s/])\.env\b|\bkeychain\b|'
          r'\bwallet\.dat\b',
          caseSensitive: false),
      HygieneFindingKind.sensitivePath,
      HygieneSeverity.critical,
      'Mentions a credential or configuration file.',
    ),
    (
      RegExp(
          r'\b(include|pass|send|provide|add|append|attach|put|read|copy)\b[^.]{0,40}\b(api[\s_-]?keys?|'
          r'access[\s_-]?tokens?|secret[\s_-]?keys?|private[\s_-]?keys?|passwords?|credentials|'
          r'session\s+cookies?|bearer\s+tokens?)\b',
          caseSensitive: false),
      HygieneFindingKind.credentialRequest,
      HygieneSeverity.warning,
      'Asks the model to pass secrets along.',
    ),
    (
      RegExp(
          r'\balways\s+(call|use|run|invoke|include|send|pass|read|add|append|prepend|mention|say|'
          r'respond|reply|ask|first)\b|\bbefore\s+(any|every|all|doing|answering|responding|you)\b|'
          r'\b(you|the\s+(assistant|model|ai|agent))\s+(must|should|need\s+to|have\s+to|'
          r'are\s+required\s+to)\s+(always|first|never|call|use|invoke|run|read|send|include|pass|ignore|'
          r'not)\b',
          caseSensitive: false),
      HygieneFindingKind.imperative,
      HygieneSeverity.warning,
      'Uses imperative "always / before any / you must" phrasing aimed at the model.',
    ),
    (
      RegExp(r'!\[[^\]]*\]\(\s*https?://', caseSensitive: false),
      HygieneFindingKind.exfiltration,
      HygieneSeverity.critical,
      'Contains a markdown image (an exfiltration channel).',
    ),
    (
      RegExp(
          r'\b(send|post|upload|report|forward|transmit|leak)\b[^.]{0,60}\bto\s+(https?://|www\.|'
          r'[a-z0-9.-]+\.[a-z]{2,}/)',
          caseSensitive: false),
      HygieneFindingKind.exfiltration,
      HygieneSeverity.warning,
      'Tells the model to send data to a URL.',
    ),
    (
      RegExp(r'[A-Za-z0-9+/]{120,}={0,2}'),
      HygieneFindingKind.encodedPayload,
      HygieneSeverity.warning,
      'Contains a long encoded-looking payload.',
    ),
  ];

  /// Scans one tool. [otherToolNames] are the model-facing and wire names of
  /// OTHER servers' tools (for shadowing); short or generic names are
  /// ignored to keep false positives down.
  List<HygieneFinding> scanTool({
    required String name,
    String? title,
    String? description,
    JsonMap? inputSchema,
    JsonMap? outputSchema,
    Iterable<String> otherToolNames = const [],
  }) {
    final texts = <(String, String)>[
      if (title != null) ('title', title),
      if (description != null) ('description', description),
      if (inputSchema != null) ..._schemaTexts(inputSchema, 'inputSchema'),
      if (outputSchema != null) ..._schemaTexts(outputSchema, 'outputSchema'),
    ];
    final out = <HygieneFinding>[];
    for (final (where, text) in texts) {
      out.addAll(scanText(text, location: where));
    }
    final distinctive = [
      for (final n in otherToolNames)
        if (n != name && n.length >= 6 && (n.contains('_') || n.contains('-') || n.contains('.'))) n,
    ];
    if (distinctive.isNotEmpty) {
      for (final (where, text) in texts) {
        final lower = text.toLowerCase();
        for (final n in distinctive) {
          final i = lower.indexOf(n.toLowerCase());
          if (i < 0) continue;
          out.add(HygieneFinding(
            kind: HygieneFindingKind.crossToolInstruction,
            severity: HygieneSeverity.critical,
            message: 'Mentions "$n", a tool of another server (shadowing).',
            location: where,
            excerpt: _excerpt(text, i, n.length),
          ));
          break;
        }
      }
    }
    final d = description ?? '';
    if (d.length > maxDescriptionChars) {
      out.add(HygieneFinding(
        kind: HygieneFindingKind.overlong,
        severity: HygieneSeverity.warning,
        message: 'The description is ${d.length} characters long (more room for hidden instructions).',
        location: 'description',
      ));
    } else {
      final total = texts.fold<int>(0, (s, t) => s + t.$2.length);
      if (total > maxTotalChars) {
        out.add(HygieneFinding(
          kind: HygieneFindingKind.overlong,
          severity: HygieneSeverity.warning,
          message: 'The tool carries $total characters of text across its schema.',
          location: 'inputSchema',
        ));
      }
    }
    for (final (where, ref) in [
      if (inputSchema != null) ..._externalRefs(inputSchema, 'inputSchema'),
      if (outputSchema != null) ..._externalRefs(outputSchema, 'outputSchema'),
    ]) {
      out.add(HygieneFinding(
        kind: HygieneFindingKind.externalRef,
        severity: HygieneSeverity.warning,
        message: 'References an external schema ($ref); it is not fetched, so arguments there are unchecked.',
        location: where,
      ));
    }
    return out;
  }

  /// Scans free text (a description, server `instructions`).
  List<HygieneFinding> scanText(String text, {String location = 'text'}) {
    final out = <HygieneFinding>[];
    final hidden = _hiddenChars(text);
    if (hidden.isNotEmpty) {
      final onlyJoiners = hidden.every((h) => h.$2 == 0x200D || (h.$2 >= 0xFE00 && h.$2 <= 0xFE0F));
      out.add(HygieneFinding(
        kind: HygieneFindingKind.hiddenCharacters,
        severity: onlyJoiners ? HygieneSeverity.warning : HygieneSeverity.critical,
        message: 'Contains ${hidden.length} invisible character${hidden.length == 1 ? '' : 's'} '
            '(${{for (final h in hidden) _u(h.$2)}.take(4).join(', ')}).',
        location: location,
        excerpt: _excerpt(text, hidden.first.$1, 1),
      ));
    }
    for (final (re, kind, severity, message) in _rules) {
      final m = re.firstMatch(text);
      if (m == null) continue;
      out.add(HygieneFinding(
        kind: kind,
        severity: severity,
        message: message,
        location: location,
        excerpt: _excerpt(text, m.start, m.end - m.start),
      ));
    }
    return out;
  }

  /// Invisible format characters with their code-unit offset.
  static List<(int, int)> _hiddenChars(String text) {
    final out = <(int, int)>[];
    var offset = 0;
    for (final r in text.runes) {
      if (_isHidden(r)) out.add((offset, r));
      offset += r > 0xFFFF ? 2 : 1;
    }
    return out;
  }

  static bool _isHidden(int r) =>
      r == 0x00AD || // soft hyphen
      r == 0x034F || // combining grapheme joiner
      r == 0x061C || // Arabic letter mark
      r == 0x115F || r == 0x1160 || // Hangul fillers
      r == 0x17B4 || r == 0x17B5 ||
      r == 0x180E || // Mongolian vowel separator
      (r >= 0x200B && r <= 0x200F) || // zero-width space/joiners, LRM/RLM
      (r >= 0x202A && r <= 0x202E) || // bidi embeddings/overrides
      (r >= 0x2060 && r <= 0x206F) || // word joiner, invisible operators, bidi isolates
      r == 0x3164 || r == 0xFFA0 || // Hangul fillers
      r == 0xFEFF || // BOM / zero-width no-break space
      (r >= 0xFE00 && r <= 0xFE0F) || // variation selectors
      (r >= 0xFFF9 && r <= 0xFFFB) || // interlinear annotations
      (r >= 0xE0000 && r <= 0xE007F) || // tag characters ("ASCII smuggling")
      (r >= 0xE0100 && r <= 0xE01EF); // variation selectors supplement

  static String _u(int r) => 'U+${r.toRadixString(16).toUpperCase().padLeft(4, '0')}';

  /// A short, display-safe window around a match.
  static String _excerpt(String text, int start, int length) {
    final from = (start - 20).clamp(0, text.length);
    final to = (start + length + 40).clamp(0, text.length);
    final buf = StringBuffer();
    for (final r in text.substring(from, to).runes) {
      if (_isHidden(r)) {
        buf.write('<${_u(r)}>');
      } else if (r == 0x0A || r == 0x0D || r == 0x09) {
        buf.write(' ');
      } else {
        buf.writeCharCode(r);
      }
    }
    var s = Redactor.text(buf.toString());
    if (s.length > 80) s = '${s.substring(0, 79)}…';
    return '${from > 0 ? '…' : ''}$s${to < text.length ? '…' : ''}';
  }

  /// Every `title`/`description` string in a schema, with its path.
  static List<(String, String)> _schemaTexts(Object? node, String path, [int depth = 0]) {
    if (depth > 24) return const [];
    final out = <(String, String)>[];
    if (node is Map) {
      for (final e in node.entries) {
        final k = '${e.key}';
        final v = e.value;
        if ((k == 'description' || k == 'title') && v is String) {
          out.add(('$path.$k', v));
        } else if (k == 'enum' && v is List) {
          final strings = v.whereType<String>().where((s) => s.length > 24).join(' ');
          if (strings.isNotEmpty) out.add(('$path.enum', strings));
        } else if (k == 'default' && v is String && v.length > 24) {
          out.add(('$path.default', v));
        } else {
          out.addAll(_schemaTexts(v, '$path.$k', depth + 1));
        }
      }
    } else if (node is List) {
      for (final (i, v) in node.indexed) {
        out.addAll(_schemaTexts(v, '$path[$i]', depth + 1));
      }
    }
    return out;
  }

  static List<(String, String)> _externalRefs(Object? node, String path, [int depth = 0]) {
    if (depth > 24) return const [];
    final out = <(String, String)>[];
    if (node is Map) {
      for (final e in node.entries) {
        final k = '${e.key}';
        if (k == r'$ref' && e.value is String && !(e.value! as String).startsWith('#')) {
          out.add((path, e.value! as String));
        } else {
          out.addAll(_externalRefs(e.value, '$path.$k', depth + 1));
        }
      }
    } else if (node is List) {
      for (final (i, v) in node.indexed) {
        out.addAll(_externalRefs(v, '$path[$i]', depth + 1));
      }
    }
    return out;
  }
}
