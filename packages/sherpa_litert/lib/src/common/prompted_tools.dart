import 'dart:convert';

import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_providers/tool_arguments.dart';

import 'fingerprint.dart';

/// Sherpa's prompted tool-call format, for models without a native
/// function-calling path (Gemini Nano, LiteRT-LM models whose metadata does
/// not declare function calling).
///
/// The model is told to answer a tool call with a single JSON envelope:
/// `{"tool_calls": [{"name": "...", "arguments": {...}}]}`. Earlier calls
/// are replayed in the same shape and results come back as a "Tool results:"
/// block whose bodies are wrapped as untrusted data
/// ([PromptBoundary.wrapUntrusted]).
abstract final class PromptedToolFormat {
  static const String resultsHeader = 'Tool results:';

  /// The block appended to the system prompt when tools are offered.
  static String instructions(List<ToolDefinition> tools, ToolChoice choice) {
    final b = StringBuffer()
      ..writeln('## Tools')
      ..writeln('You can call the tools listed below. To call tools, reply with only this JSON and nothing else:')
      ..writeln('{"tool_calls": [{"name": "<tool name>", "arguments": {<arguments>}}]}')
      ..writeln('List several calls to run them together. The results come back in a message that starts with '
          '"$resultsHeader". Only call tools from this list. When no tool is needed, answer in plain text.')
      ..writeln()
      ..writeln('Available tools (arguments are JSON Schema):');
    for (final t in tools) {
      b.writeln('- ${t.name}: ${t.description.trim().replaceAll('\n', ' ')}');
      b.writeln('  arguments: ${jsonEncode(normalizeSchema(t.inputSchema))}');
    }
    final must = choiceInstruction(choice);
    if (must != null) b.writeln(must);
    return b.toString().trimRight();
  }

  /// A line that asks for a call, for [ToolChoiceRequired] /
  /// [ToolChoiceSpecific] (no runtime can enforce it here).
  static String? choiceInstruction(ToolChoice choice) => switch (choice) {
        ToolChoiceRequired() => 'You must call at least one tool in your next reply.',
        ToolChoiceSpecific(:final name) => 'You must call the tool "$name" in your next reply.',
        _ => null,
      };

  /// The envelope for calls already in the history.
  static String envelope(List<ToolCall> calls) => jsonEncode({
        'tool_calls': [
          for (final c in calls) {'name': c.name, 'arguments': c.arguments},
        ],
      });

  /// A turn carrying tool results.
  static String results(List<ToolResultPart> results) {
    final b = StringBuffer(resultsHeader);
    for (final r in results) {
      b
        ..writeln()
        ..write(PromptBoundary.wrapUntrusted(toolResultText(r), source: 'tool:${r.toolName}'));
    }
    return b.toString();
  }

  /// What the model sees of a result; errors are flagged in-band.
  static String toolResultText(ToolResultPart r) {
    final lines = <String>[];
    for (final c in r.content) {
      switch (c) {
        case TextPart(:final text):
          lines.add(text);
        case EmbeddedResourcePart(:final uri, :final text?):
          lines.add('[resource $uri]\n$text');
        case ResourceLinkPart(:final uri, :final name, :final title):
          final label = title ?? name;
          lines.add('[resource link${label == null ? '' : ' "$label"'}: $uri]');
        default:
          break;
      }
    }
    var text = lines.join('\n');
    if (text.isEmpty && r.structured != null) text = jsonEncode(r.structured);
    return r.isError ? '[tool error] $text' : text;
  }

  /// Drops annotation-only schema keywords that cost tokens and confuse
  /// small models; constraints and key names are kept. Deterministic.
  static JsonMap normalizeSchema(JsonMap schema) => _normalize(schema)! as JsonMap;

  static const Set<String> _dropKeys = {r'$schema', r'$id', r'$comment', 'title', 'examples'};

  static Object? _normalize(Object? v) {
    if (v is Map) {
      return <String, Object?>{
        for (final e in v.entries)
          if (!_dropKeys.contains(e.key))
            '${e.key}': e.key == 'properties' && e.value is Map
                ? {for (final p in (e.value as Map).entries) '${p.key}': _normalize(p.value)}
                : _normalize(e.value),
      };
    }
    if (v is List) return [for (final x in v) _normalize(x)];
    return v;
  }
}

/// Parses tool calls out of streamed model text in the prompted format.
///
/// Text is passed through as [TextDelta]s as it arrives, except from the
/// first point that may start an envelope (`{"tool_calls"`, `{"name"`, a
/// ```` ```json ```` fence followed by such an object, `<tool_call>`): from
/// there the text is held back until [finish] decides. A held segment that
/// turns out to be ordinary text (a JSON code block, braces in prose) is
/// released at once or at the end, so nothing is ever lost. Arguments that
/// needed repair are marked `repaired` (which forces approval of non
/// read-only tools in the core).
final class PromptedToolParser {
  PromptedToolParser({Set<String> toolNames = const {}, String Function()? newId})
      : _toolNames = toolNames,
        _newId = newId ?? newToolCallId;

  final Set<String> _toolNames;
  final String Function() _newId;
  final StringBuffer _buf = StringBuffer();
  String _text = '';
  int _emitted = 0;
  int? _holdFrom;
  int _calls = 0;

  /// Calls emitted so far.
  int get toolCallCount => _calls;

  List<ModelEvent> add(String delta) {
    if (delta.isEmpty) return const [];
    _buf.write(delta);
    _text = _buf.toString();
    return _scan();
  }

  List<ModelEvent> _scan() {
    if (_holdFrom != null) {
      // A held candidate can still turn out to be plain text (e.g. a code
      // fence in another language): release it as soon as that is certain.
      final verdict = _classify(_text.substring(_holdFrom!));
      if (verdict != _Verdict.no) return const [];
      _emitted = _holdFrom!;
      _holdFrom = null;
      return _scanFrom(_holdSkip(_emitted));
    }
    return _scanFrom(_emitted);
  }

  /// Position after the trigger character at [i], so a released candidate is
  /// not re-detected at the same spot.
  int _holdSkip(int i) => i + 1;

  List<ModelEvent> _scanFrom(int from) {
    var i = from;
    while (i < _text.length) {
      final c = _text.codeUnitAt(i);
      if (c == 0x7b /* { */ || c == 0x60 /* ` */ || c == 0x3c /* < */) {
        final verdict = _classify(_text.substring(i));
        if (verdict == _Verdict.yes) {
          final out = _emit(i);
          _holdFrom = i;
          return out;
        }
        if (verdict == _Verdict.maybe) return _emit(i);
      }
      i++;
    }
    return _emit(_text.length);
  }

  List<ModelEvent> _emit(int upTo) {
    if (upTo <= _emitted) return const [];
    final chunk = _text.substring(_emitted, upTo);
    _emitted = upTo;
    return [TextDelta(chunk)];
  }

  /// Ends the stream: emits held text, or the parsed calls.
  List<ModelEvent> finish() {
    final hold = _holdFrom;
    final out = <ModelEvent>[];
    if (hold == null) {
      out.addAll(_emit(_text.length));
      return out;
    }
    final calls = parseEnvelope(_text.substring(hold));
    if (calls.isEmpty) {
      _holdFrom = null;
      out.addAll(_emit(_text.length));
      return out;
    }
    _emitted = _text.length;
    for (final c in calls) {
      final index = _calls++;
      final call = ToolCall(
        id: _newId(),
        name: c.name,
        arguments: c.arguments,
        rawArguments: c.raw,
        argumentsError: c.error,
        repaired: c.repaired,
      );
      out
        ..add(ToolCallStart(index: index, id: call.id, name: call.name))
        ..add(ToolCallArgsDelta(index: index, fragment: c.raw))
        ..add(ToolCallComplete(index: index, call: call));
    }
    return out;
  }

  // ---------------------------------------------------------------------------

  static const _fenceLangs = {'', 'json', 'tool_call', 'tool_calls', 'tool_code', 'tool', 'tools'};
  static const _keys = ['tool_calls', 'name', 'function'];

  _Verdict _classify(String s) {
    if (s.startsWith('<')) {
      const tag = '<tool_call>';
      if (s.startsWith(tag)) return _Verdict.yes;
      return tag.startsWith(s) ? _Verdict.maybe : _Verdict.no;
    }
    if (s.startsWith('`')) {
      if (!'```'.startsWith(s.length < 3 ? s : s.substring(0, 3))) return _Verdict.no;
      if (s.length < 3) return _Verdict.maybe;
      var i = 3;
      while (i < s.length && _isLangChar(s.codeUnitAt(i))) {
        i++;
      }
      final lang = s.substring(3, i).toLowerCase();
      if (i == s.length) {
        return _fenceLangs.any((l) => l.startsWith(lang)) ? _Verdict.maybe : _Verdict.no;
      }
      if (!_fenceLangs.contains(lang)) return _Verdict.no;
      while (i < s.length && _isSpace(s.codeUnitAt(i))) {
        i++;
      }
      if (i == s.length) return _Verdict.maybe;
      if (s.codeUnitAt(i) != 0x7b) return _Verdict.no;
      return _classifyObject(s.substring(i));
    }
    if (s.startsWith('{')) return _classifyObject(s);
    return _Verdict.no;
  }

  _Verdict _classifyObject(String s) {
    var i = 1;
    while (i < s.length && _isSpace(s.codeUnitAt(i))) {
      i++;
    }
    if (i == s.length) return _Verdict.maybe;
    final q = s.codeUnitAt(i);
    if (q != 0x22 /* " */ && q != 0x27 /* ' */) return _Verdict.no;
    final end = s.indexOf(String.fromCharCode(q), i + 1);
    final key = end < 0 ? s.substring(i + 1) : s.substring(i + 1, end);
    if (end < 0) return _keys.any((k) => k.startsWith(key)) ? _Verdict.maybe : _Verdict.no;
    return _keys.contains(key) ? _Verdict.yes : _Verdict.no;
  }

  static bool _isLangChar(int c) =>
      (c >= 0x61 && c <= 0x7a) || (c >= 0x41 && c <= 0x5a) || (c >= 0x30 && c <= 0x39) || c == 0x5f || c == 0x2d;

  static bool _isSpace(int c) => c == 0x20 || c == 0x0a || c == 0x0d || c == 0x09;

  /// The calls in [text] (an envelope, a bare call object, a list of calls,
  /// or one or more `<tool_call>` blocks). Empty when [text] is not a call.
  List<ParsedToolCall> parseEnvelope(String text) {
    final tagged = RegExp(r'<tool_call>([\s\S]*?)(?:</tool_call>|$)').allMatches(text).toList();
    if (tagged.isNotEmpty) {
      return [for (final m in tagged) ..._parseValue(m[1] ?? '', bareRequiresKnownName: false)];
    }
    return _parseValue(text, bareRequiresKnownName: true);
  }

  List<ParsedToolCall> _parseValue(String text, {required bool bareRequiresKnownName}) {
    final extracted = JsonRepair.extract(text);
    if (extracted == null) return const [];
    // Strict first: the first complete JSON value (models often append
    // chatter or a closing fence after it). Otherwise the shared lenient
    // parser repairs it; the whole envelope is then also run through the
    // strict-mode checks, because its arguments can't be located in text
    // that is not JSON.
    final end = _valueEnd(extracted);
    final strictText = end == null ? extracted : extracted.substring(0, end);
    Object? value;
    String? strictJson;
    _Envelope envelope;
    try {
      value = jsonDecode(strictText);
      strictJson = strictText;
      envelope = const _Envelope.strict();
    } on FormatException {
      try {
        final (v, fixes) = ToolArgumentsRepair.parseValue(extracted);
        value = v;
      } on FormatException {
        return const [];
      }
      final check = value is Map ? ToolArgumentsRepair.parseArguments(extracted) : null;
      envelope = _Envelope.repaired(
        check != null && check.fixes.contains(ToolArgumentsRepair.refusedFix) ? check.error : null,
      );
    }
    if (value == null) return const [];
    final items = <(Object?, List<Object>)>[];
    var bare = false;
    if (value is Map && value['tool_calls'] is List) {
      for (final (i, item) in (value['tool_calls'] as List).indexed) {
        items.add((item, ['tool_calls', i]));
      }
    } else if (value is Map && value['tool_calls'] is Map) {
      items.add((value['tool_calls'], const ['tool_calls']));
    } else if (value is List) {
      for (final (i, item) in value.indexed) {
        items.add((item, [i]));
      }
    } else if (value is Map) {
      items.add((value, const []));
      bare = true;
    } else {
      return const [];
    }
    final out = <ParsedToolCall>[];
    for (final (item, path) in items) {
      final call = _call(item, path: path, strictJson: strictJson, envelope: envelope);
      if (call == null) continue;
      if (bare && bareRequiresKnownName && !call.hadArgumentsKey && !_toolNames.contains(call.name)) continue;
      if (bare && bareRequiresKnownName && _toolNames.isNotEmpty && !_toolNames.contains(call.name) && value is Map &&
          value.length > 2) {
        continue; // an ordinary JSON object that happens to have a "name"
      }
      out.add(call);
    }
    return out;
  }

  /// End offset of the balanced object/array starting at 0, ignoring
  /// brackets inside strings; null when unbalanced.
  static int? _valueEnd(String s) {
    var depth = 0;
    var inString = false;
    var escape = false;
    for (var i = 0; i < s.length; i++) {
      final c = s.codeUnitAt(i);
      if (inString) {
        if (escape) {
          escape = false;
        } else if (c == 0x5c) {
          escape = true;
        } else if (c == 0x22) {
          inString = false;
        }
        continue;
      }
      if (c == 0x22) {
        inString = true;
      } else if (c == 0x7b || c == 0x5b) {
        depth++;
      } else if (c == 0x7d || c == 0x5d) {
        depth--;
        if (depth == 0) return i + 1;
      }
    }
    return null;
  }

  /// One call of an envelope. Its arguments go through the strict shared
  /// parser ([ToolArgumentsRepair], like every other tool-call path):
  /// strict JSON as is; repaired JSON flagged `repaired` (forces approval
  /// of non-read-only tools); duplicate keys, leaked chat-template tokens
  /// and ambiguous unquoted values make the call invalid (`argumentsError`,
  /// never run; the agent loop tells the model).
  ParsedToolCall? _call(
    Object? item, {
    required List<Object> path,
    required String? strictJson,
    required _Envelope envelope,
  }) {
    if (item is! Map) return null;
    var m = item;
    var at = path;
    if (m['function'] is Map) {
      m = m['function'] as Map;
      at = [...at, 'function'];
    }
    final name = m['name'];
    if (name is! String || name.trim().isEmpty) return null;
    final key = const ['arguments', 'parameters', 'args'].where((k) => m[k] != null).firstOrNull;
    final hadArgs = m.containsKey('arguments') || m.containsKey('parameters') || m.containsKey('args');
    final args = key == null ? null : m[key];
    // The call's own text, when the envelope was strict JSON: duplicate keys
    // anywhere in it (two "name"s, or an argument sent twice) are refused.
    final itemRaw = strictJson == null ? null : ToolArgumentsRepair.rawValueAt(strictJson, path);
    final dup = itemRaw == null ? null : ToolArgumentsRepair.duplicateKey(itemRaw);
    ArgumentsParseResult parsed;
    String raw;
    if (dup != null) {
      raw = itemRaw!;
      parsed = ArgumentsParseResult.failed(ToolArgumentsRepair.duplicateKeyError(dup));
    } else if (envelope.refusal != null) {
      raw = jsonEncode(args ?? const <String, Object?>{});
      parsed = ArgumentsParseResult.failed(envelope.refusal!);
    } else if (args == null) {
      raw = '{}';
      parsed = const ArgumentsParseResult.ok({});
    } else if (args is String) {
      // Arguments the model sent as a JSON string.
      raw = args;
      parsed = ToolArgumentsRepair.parseArguments(args);
    } else {
      final argsRaw = strictJson == null ? null : ToolArgumentsRepair.rawValueAt(strictJson, [...at, key!]);
      raw = argsRaw ?? jsonEncode(args);
      parsed = ToolArgumentsRepair.parseArguments(raw);
    }
    final ok = parsed.isOk;
    final map = parsed.value ?? const <String, Object?>{};
    return ParsedToolCall(
      name: name.trim(),
      arguments: map,
      raw: ok ? jsonEncode(map) : raw,
      repaired: ok && (parsed.repaired || envelope.isRepaired),
      error: parsed.error,
      hadArgumentsKey: hadArgs,
    );
  }
}

/// How the envelope around a call was read.
final class _Envelope {
  const _Envelope.strict()
      : isRepaired = false,
        refusal = null;

  const _Envelope.repaired(this.refusal) : isRepaired = true;

  /// The envelope was not valid JSON and needed the lenient parser.
  final bool isRepaired;

  /// The strict-mode refusal of the repaired envelope (duplicate key,
  /// template tokens, ambiguous value), applied to every call in it.
  final String? refusal;
}

enum _Verdict { yes, no, maybe }

/// One call found by [PromptedToolParser.parseEnvelope].
final class ParsedToolCall {
  const ParsedToolCall({
    required this.name,
    required this.arguments,
    required this.raw,
    this.repaired = false,
    this.error,
    this.hadArgumentsKey = true,
  });

  final String name;
  final JsonMap arguments;
  final String raw;
  final bool repaired;
  final String? error;
  final bool hadArgumentsKey;
}
