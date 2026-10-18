import 'dart:convert';

import 'package:meta/meta.dart';

import '../common/json.dart';
import '../context/compaction.dart';
import '../context/text.dart';
import '../context/untrusted.dart';
import '../model/message.dart';
import '../provider/capabilities.dart';
import '../session/plan.dart';

/// Thrown when a handoff bundle is malformed, oversized or unsafe.
final class HandoffBundleException implements Exception {
  const HandoffBundleException(this.message);

  final String message;

  @override
  String toString() => 'HandoffBundleException: $message';
}

/// Size and shape limits for parsing bundles from untrusted sources (a QR
/// code, a shared file, another device).
@immutable
final class HandoffLimits {
  const HandoffLimits({
    this.maxBytes = 512 * 1024,
    this.maxDepth = 16,
    this.maxStringChars = 20000,
    this.maxPinned = 32,
    this.maxRecentTurns = 64,
    this.maxConnections = 32,
    this.maxArtifacts = 64,
    this.maxPlanItems = 100,
    this.maxCoveredIds = 10000,
    this.maxArtifactSize = 1 << 40,
  });

  final int maxBytes;
  final int maxDepth;
  final int maxStringChars;
  final int maxPinned;
  final int maxRecentTurns;
  final int maxConnections;
  final int maxArtifacts;
  final int maxPlanItems;
  final int maxCoveredIds;
  final int maxArtifactSize;
}

/// Where the bundle was made. No account, key or device identifiers.
@immutable
final class HandoffSource {
  const HandoffSource({
    required this.appVersion,
    required this.providerKind,
    required this.modelId,
    required this.location,
    this.sessionId,
  });

  final String appVersion;

  /// `ProviderKind.name` of the source provider (kept as text so a newer
  /// app's kinds still parse).
  final String providerKind;
  final String modelId;
  final ExecutionLocation location;

  /// The session the bundle was made from; becomes `handoffFromSessionId`.
  final String? sessionId;

  HandoffSource map(String Function(String) f) => HandoffSource(
        appVersion: f(appVersion),
        providerKind: providerKind,
        modelId: f(modelId),
        location: location,
        sessionId: sessionId,
      );

  JsonMap toJson() => compact({
        'appVersion': appVersion,
        'providerKind': providerKind,
        'modelId': modelId,
        'location': location.name,
        'sessionId': sessionId,
      });
}

/// One turn as plain text: no reasoning, no signatures, no provider ids, so
/// any model can read it.
@immutable
final class HandoffTurn {
  const HandoffTurn({required this.role, required this.text, this.toolName});

  final Role role;
  final String text;

  /// Set for [Role.tool] turns (rendered as untrusted data).
  final String? toolName;

  HandoffTurn map(String Function(String) f) => HandoffTurn(role: role, text: f(text), toolName: toolName);

  JsonMap toJson() => compact({'role': role.name, 'text': text, 'toolName': toolName});
}

enum HandoffAuthKind { none, oauth, header }

/// An MCP server the source session used. Never carries credentials: the
/// receiving app signs in again.
@immutable
final class HandoffConnection {
  const HandoffConnection({required this.name, required this.url, this.authKind = HandoffAuthKind.none});

  static const String type = 'mcp';

  final String name;
  final String url;
  final HandoffAuthKind authKind;

  /// [url] without user info, query or fragment, which is where tokens hide.
  static String sanitizeUrl(String url) {
    final u = Uri.tryParse(url.trim());
    if (u == null || !u.hasScheme) return url.trim();
    return Uri(scheme: u.scheme, host: u.host, port: u.hasPort ? u.port : null, path: u.path).toString();
  }

  JsonMap toJson() => {'type': type, 'name': name, 'url': url, 'authKind': authKind.name};
}

/// A file that travels with the bundle (by content hash).
@immutable
final class HandoffArtifact {
  const HandoffArtifact({
    required this.name,
    required this.mimeType,
    required this.sha256,
    required this.size,
    required this.path,
  });

  final String name;
  final String mimeType;
  final String sha256;
  final int size;

  /// Path inside the exported bundle; relative, no `..`.
  final String path;

  JsonMap toJson() => {'name': name, 'mimeType': mimeType, 'sha256': sha256, 'size': size, 'path': path};
}

/// Handoff bundle v1: everything a fresh session (same app, another device,
/// another model) needs to continue a task, in versioned, model-agnostic
/// JSON (PLAN M3; R11 §9.3 handoff).
@immutable
final class HandoffBundle {
  const HandoffBundle({
    required this.createdAt,
    required this.source,
    required this.task,
    required this.summary,
    this.plan,
    this.pinned = const [],
    this.recentTurns = const [],
    this.connections = const [],
    this.artifacts = const [],
    this.notes,
  });

  /// Strictly parses [text] from an untrusted source: size and nesting are
  /// checked before decoding, unknown keys are rejected, every string is
  /// bounded, URLs and paths are validated.
  factory HandoffBundle.parse(String text, {HandoffLimits limits = const HandoffLimits()}) {
    if (utf8.encode(text).length > limits.maxBytes) {
      throw HandoffBundleException('bundle is larger than ${limits.maxBytes} bytes');
    }
    _checkDepth(text, limits.maxDepth);
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException catch (e) {
      throw HandoffBundleException('not valid JSON: ${e.message}');
    }
    if (decoded is! Map<Object?, Object?>) throw const HandoffBundleException('bundle must be a JSON object');
    return HandoffBundle.fromJson(normalizeJson(decoded)! as JsonMap, limits: limits);
  }

  factory HandoffBundle.fromJson(JsonMap j, {HandoffLimits limits = const HandoffLimits()}) {
    try {
      return _BundleReader(limits).read(j);
    } on FormatError catch (e) {
      throw HandoffBundleException(e.message);
    } on FormatException catch (e) {
      throw HandoffBundleException(e.message);
    }
  }

  static const String format = 'sherpa.handoff';
  static const int version = 1;

  final DateTime createdAt;
  final HandoffSource source;
  final String task;
  final Plan? plan;
  final CompactionSummary summary;
  final List<HandoffTurn> pinned;
  final List<HandoffTurn> recentTurns;
  final List<HandoffConnection> connections;
  final List<HandoffArtifact> artifacts;
  final String? notes;

  String encode() => jsonEncode(toJson());

  JsonMap toJson() => compact({
        'format': format,
        'version': version,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'source': source.toJson(),
        'task': task,
        'plan': plan?.toJson(),
        'summary': summary.toJson(),
        'pinned': pinned.isEmpty ? null : [for (final t in pinned) t.toJson()],
        'recentTurns': recentTurns.isEmpty ? null : [for (final t in recentTurns) t.toJson()],
        'connections': connections.isEmpty ? null : [for (final c in connections) c.toJson()],
        'artifacts': artifacts.isEmpty ? null : [for (final a in artifacts) a.toJson()],
        'notes': notes,
      });

  /// Applies [f] (a secret scrubber) to every free-text field.
  HandoffBundle mapText(String Function(String) f) {
    final p = plan;
    return HandoffBundle(
      createdAt: createdAt,
      source: source.map(f),
      task: f(task),
      plan: p == null
          ? null
          : Plan(
              task: p.task == null ? null : f(p.task!),
              updatedAt: p.updatedAt,
              items: [
                for (final i in p.items)
                  PlanItem(id: i.id, title: f(i.title), status: i.status, notes: i.notes == null ? null : f(i.notes!)),
              ],
            ),
      summary: summary.mapText(f),
      pinned: [for (final t in pinned) t.map(f)],
      recentTurns: [for (final t in recentTurns) t.map(f)],
      connections: [
        for (final c in connections)
          HandoffConnection(name: f(c.name), url: f(HandoffConnection.sanitizeUrl(c.url)), authKind: c.authKind),
      ],
      artifacts: [
        for (final a in artifacts)
          HandoffArtifact(name: f(a.name), mimeType: a.mimeType, sha256: a.sha256, size: a.size, path: f(a.path)),
      ],
      notes: notes == null ? null : f(notes!),
    );
  }

  /// The seed message text for the new session: task, summary (with the
  /// new session's [nonce]), plan, pinned items and recent turns.
  String renderForModel({String? nonce}) {
    final b = StringBuffer('Handoff from an earlier Sherpa session (made ${createdAt.toUtc().toIso8601String()} '
        'with ${source.modelId}). Continue the task from here; do not repeat actions listed as already performed.');
    b.write('\n\nTask: ${task.trim()}');
    final s = summary.copyWith(plan: plan ?? summary.plan, nonce: nonce, clearNonce: nonce == null);
    b.write('\n\n${s.render()}');
    if (pinned.isNotEmpty) {
      b.write('\n\nPinned messages from the earlier session:');
      for (final t in pinned) {
        b.write('\n${_turnForModel(t, nonce)}');
      }
    }
    if (recentTurns.isNotEmpty) {
      b.write('\n\nMost recent turns (oldest first):');
      for (final t in recentTurns) {
        b.write('\n${_turnForModel(t, nonce)}');
      }
    }
    if (connections.isNotEmpty) {
      b.write('\n\nServers the earlier session used (they may need to be reconnected): '
          '${[for (final c in connections) '${c.name} (${c.url})'].join(', ')}');
    }
    if (artifacts.isNotEmpty) {
      b.write('\n\nFiles attached to the handoff: '
          '${[for (final a in artifacts) '${a.name} (${a.mimeType}, ${groupDigits(a.size)} bytes)'].join(', ')}');
    }
    if (notes != null && notes!.trim().isNotEmpty) b.write('\n\nNotes from the user: ${notes!.trim()}');
    return b.toString();
  }

  static String _turnForModel(HandoffTurn t, String? nonce) => t.role == Role.tool
      ? UntrustedData.wrap(t.text, source: 'tool:${t.toolName ?? 'unknown'}', nonce: nonce)
      : '[${t.role.name}] ${t.text.trim()}';

  /// Human-readable rendering for the review screen. Every bundle field is
  /// escaped (an imported bundle is untrusted: no live links, no images, no
  /// HTML), and URLs are shown as code so nothing auto-loads.
  String toMarkdown() {
    final b = StringBuffer('# Handoff: ${_md(clipText(firstLine(task), 120))}\n');
    b.write('\n- **Created:** ${createdAt.toUtc().toIso8601String()}');
    b.write('\n- **From:** ${_md(source.modelId)} (${_md(source.providerKind)}, ${source.location.name}), '
        'Sherpa ${_md(source.appVersion)}');
    b.write('\n\n## Task\n\n${_md(task)}\n');
    final p = plan ?? summary.plan;
    if (p != null && !p.isEmpty) {
      b.write('\n## Plan\n');
      for (final i in p.items) {
        b.write('\n- ${i.status == PlanStatus.done ? '[x]' : '[ ]'} ${_md(i.title)} (${i.status.name})');
      }
      b.write('\n');
    }
    _summaryMarkdown(b);
    if (pinned.isNotEmpty) {
      b.write('\n## Pinned\n');
      for (final t in pinned) {
        b.write('\n- **${t.role.name}:** ${_md(squash(t.text))}');
      }
      b.write('\n');
    }
    if (recentTurns.isNotEmpty) {
      b.write('\n## Recent turns\n');
      for (final t in recentTurns) {
        final who = t.role == Role.tool ? 'tool ${_md(t.toolName ?? '')} (untrusted)' : t.role.name;
        b.write('\n- **$who:** ${_md(squash(clipText(t.text, 600)))}');
      }
      b.write('\n');
    }
    if (connections.isNotEmpty) {
      b.write('\n## Connections\n\nCredentials are never included; you will sign in again.\n');
      for (final c in connections) {
        b.write('\n- ${_md(c.name)}: ${_code(c.url)} (auth: ${c.authKind.name})');
      }
      b.write('\n');
    }
    if (artifacts.isNotEmpty) {
      b.write('\n## Files\n');
      for (final a in artifacts) {
        b.write('\n- ${_md(a.name)} (${_md(a.mimeType)}, ${groupDigits(a.size)} bytes, sha256 '
            '${_code(a.sha256.substring(0, 12))}…)');
      }
      b.write('\n');
    }
    if (notes != null && notes!.trim().isNotEmpty) b.write('\n## Notes\n\n${_md(notes!)}\n');
    return b.toString();
  }

  void _summaryMarkdown(StringBuffer b) {
    final s = summary;
    b.write('\n## Summary\n');
    void field(String title, String? v) {
      if (v != null && v.trim().isNotEmpty) b.write('\n**$title:** ${_md(squash(v))}\n');
    }

    void list(String title, List<String> items) {
      if (items.isEmpty) return;
      b.write('\n### $title\n');
      for (final i in items) {
        final untrusted = Provenance.isTool(i) ? ' *(from tool output, untrusted)*' : '';
        b.write('\n- ${_md(squash(i))}$untrusted');
      }
      b.write('\n');
    }

    field('Goal', s.goal);
    list('Constraints', s.constraints);
    list('Preferences', s.userPreferences);
    list('Decisions', s.decisions);
    list('Done', s.completed);
    list('Open tasks', s.openTasks);
    field('Current work', s.currentWork);
    field('Next step', s.nextStep);
    list('Key facts', s.keyFacts);
    list('Failed approaches', s.failedApproaches);
    field('Notes', s.notes);
    if (s.sideEffectLedger.isNotEmpty) {
      b.write('\n### Actions already performed\n');
      for (final e in s.sideEffectLedger) {
        b.write('\n- ${_md(e.tool)} ${e.argsPreview == null ? '' : _code(e.argsPreview!)} → ${e.outcome.name}');
      }
      b.write('\n');
    }
    if (s.artifacts.isNotEmpty) {
      b.write('\n### Files and links\n');
      for (final a in s.artifacts) {
        b.write('\n- ${_code(a)}');
      }
      b.write('\n');
    }
    if (s.userMessages.isNotEmpty) {
      b.write('\n### Your earlier messages\n');
      for (final m in s.userMessages) {
        b.write('\n> ${_md(squash(clipText(m, 600)))}\n');
      }
    }
  }

  static final RegExp _mdSpecial = RegExp(r'([\\`*_\[\]{}()<>#+!|~])');

  static String _md(String s) => s.replaceAllMapped(_mdSpecial, (m) => '\\${m[1]}');

  static String _code(String s) => '`${s.replaceAll('`', "'")}`';

  /// Rejects nesting deeper than [max] before `jsonDecode` sees the text.
  static void _checkDepth(String text, int max) {
    var depth = 0;
    var inString = false;
    for (var i = 0; i < text.length; i++) {
      final c = text.codeUnitAt(i);
      if (inString) {
        if (c == 0x5C) {
          i++;
        } else if (c == 0x22) {
          inString = false;
        }
        continue;
      }
      if (c == 0x22) {
        inString = true;
      } else if (c == 0x7B || c == 0x5B) {
        if (++depth > max) throw HandoffBundleException('bundle nests deeper than $max levels');
      } else if (c == 0x7D || c == 0x5D) {
        depth--;
      }
    }
  }
}

/// Strict reader behind [HandoffBundle.fromJson].
final class _BundleReader {
  _BundleReader(this.limits);

  final HandoffLimits limits;

  static const Set<String> _topKeys = {
    'format', 'version', 'createdAt', 'source', 'task', 'plan', 'summary', //
    'pinned', 'recentTurns', 'connections', 'artifacts', 'notes',
  };
  static const Set<String> _summaryKeys = {
    'schemaVersion', 'goal', 'constraints', 'userPreferences', 'decisions', 'completed', 'openTasks', //
    'currentWork', 'nextStep', 'keyFacts', 'failedApproaches', 'notes', 'task', 'userMessages', //
    'nextStepQuote', 'artifacts', 'stateHandles', 'sideEffectLedger', 'pendingApprovals', 'taint', //
    'compactionCount', 'coveredMessageIds', 'plan', 'nonce',
  };
  static final RegExp _forbiddenChars = RegExp(r'[\x00\u202A-\u202E\u2066-\u2069]');
  static final RegExp _mime = RegExp(r'^[A-Za-z0-9][\w.+-]*/[\w.+-]+$');
  static final RegExp _sha256 = RegExp(r'^[0-9a-f]{64}$');
  static final RegExp _secretParam = RegExp(
      r'^(api[-_]?key|key|token|access[-_]?token|refresh[-_]?token|code|secret|client[-_]?secret|password|sig|signature)$',
      caseSensitive: false);

  HandoffBundle read(JsonMap j) {
    _keys(j, _topKeys, 'bundle');
    if (j['format'] != HandoffBundle.format) throw const FormatError('not a Sherpa handoff bundle');
    final v = j['version'];
    if (v is! int) throw const FormatError('missing bundle version');
    if (v > HandoffBundle.version) throw FormatError('bundle version $v was made by a newer Sherpa');
    if (v < 1) throw FormatError('invalid bundle version $v');
    _scan(j, 'bundle');
    final summaryJson = j.obj('summary');
    _keys(summaryJson, _summaryKeys, 'summary');
    if (summaryJson['schemaVersion'] != CompactionSummary.currentSchemaVersion) {
      throw const FormatError('summary must be schema version 2');
    }
    if ((summaryJson['coveredMessageIds'] as List<Object?>? ?? const []).length > limits.maxCoveredIds) {
      throw const FormatError('summary covers too many messages');
    }
    final summary = CompactionSummary.fromJson(summaryJson).normalized().copyWith(clearNonce: true);
    return HandoffBundle(
      createdAt: DateTime.parse(j.req<String>('createdAt')),
      source: _source(j.obj('source')),
      task: j.req<String>('task'),
      plan: j.optObj('plan') == null ? null : _plan(j.obj('plan')),
      summary: summary,
      pinned: _turns(j, 'pinned', limits.maxPinned),
      recentTurns: _turns(j, 'recentTurns', limits.maxRecentTurns),
      connections: [for (final c in _list(j, 'connections', limits.maxConnections)) _connection(c)],
      artifacts: [for (final a in _list(j, 'artifacts', limits.maxArtifacts)) _artifact(a)],
      notes: j.opt<String>('notes'),
    );
  }

  void _keys(JsonMap j, Set<String> allowed, String where) {
    for (final k in j.keys) {
      if (!allowed.contains(k)) throw FormatError('unknown key "$k" in $where');
    }
  }

  /// Bounds every string anywhere in the bundle and rejects control and
  /// bidi-override characters (they can disguise text on the review screen).
  void _scan(Object? v, String where) {
    switch (v) {
      case String():
        if (v.length > limits.maxStringChars) throw FormatError('a string in $where is too long');
        if (_forbiddenChars.hasMatch(v)) throw FormatError('a string in $where has forbidden characters');
      case Map<Object?, Object?>():
        for (final e in v.entries) {
          _scan(e.key, where);
          _scan(e.value, where);
        }
      case List<Object?>():
        for (final e in v) {
          _scan(e, where);
        }
      default:
        break;
    }
  }

  List<JsonMap> _list(JsonMap j, String key, int max) {
    final raw = j.opt<List<Object?>>(key) ?? const [];
    if (raw.length > max) throw FormatError('too many $key (max $max)');
    return [
      for (final e in raw)
        if (e is Map<Object?, Object?>) e.cast<String, Object?>() else throw FormatError('$key must hold objects'),
    ];
  }

  HandoffSource _source(JsonMap j) {
    _keys(j, const {'appVersion', 'providerKind', 'modelId', 'location', 'sessionId'}, 'source');
    final loc = j.req<String>('location');
    return HandoffSource(
      appVersion: _short(j.req<String>('appVersion'), 'appVersion'),
      providerKind: _short(j.req<String>('providerKind'), 'providerKind'),
      modelId: _short(j.req<String>('modelId'), 'modelId'),
      location: ExecutionLocation.values.firstWhere(
        (l) => l.name == loc,
        orElse: () => throw FormatError('unknown location $loc'),
      ),
      sessionId: j.opt<String>('sessionId') == null ? null : _short(j.req<String>('sessionId'), 'sessionId'),
    );
  }

  String _short(String s, String what) => s.length > 200 ? throw FormatError('$what is too long') : s;

  Plan _plan(JsonMap j) {
    _keys(j, const {'task', 'items', 'updatedAt'}, 'plan');
    final plan = Plan.fromJson(j);
    if (plan.items.length > limits.maxPlanItems) throw const FormatError('plan has too many items');
    return plan;
  }

  List<HandoffTurn> _turns(JsonMap j, String key, int max) => [
        for (final t in _list(j, key, max))
          () {
            _keys(t, const {'role', 'text', 'toolName'}, key);
            final role = t.req<String>('role');
            final r = switch (role) {
              'user' => Role.user,
              'assistant' => Role.assistant,
              'tool' => Role.tool,
              _ => throw FormatError('invalid role "$role" in $key'),
            };
            return HandoffTurn(role: r, text: t.req<String>('text'), toolName: t.opt<String>('toolName'));
          }(),
      ];

  HandoffConnection _connection(JsonMap c) {
    _keys(c, const {'type', 'name', 'url', 'authKind'}, 'connections');
    if (c['type'] != HandoffConnection.type) throw FormatError('unsupported connection type ${c['type']}');
    final url = c.req<String>('url');
    final u = Uri.tryParse(url);
    if (u == null || !(u.isScheme('https') || u.isScheme('http')) || u.host.isEmpty) {
      throw FormatError('connection url must be http(s): $url');
    }
    if (u.userInfo.isNotEmpty) throw const FormatError('connection url must not contain credentials');
    if (u.hasFragment || u.queryParameters.keys.any(_secretParam.hasMatch)) {
      throw const FormatError('connection url must not carry tokens');
    }
    final auth = c.opt<String>('authKind') ?? 'none';
    return HandoffConnection(
      name: _short(c.req<String>('name'), 'connection name'),
      url: url,
      authKind: HandoffAuthKind.values.firstWhere(
        (k) => k.name == auth,
        orElse: () => throw FormatError('unknown authKind $auth'),
      ),
    );
  }

  HandoffArtifact _artifact(JsonMap a) {
    _keys(a, const {'name', 'mimeType', 'sha256', 'size', 'path'}, 'artifacts');
    final mime = a.req<String>('mimeType');
    if (!_mime.hasMatch(mime)) throw FormatError('invalid mimeType $mime');
    final sha = a.req<String>('sha256');
    if (!_sha256.hasMatch(sha)) throw const FormatError('artifact sha256 must be 64 lowercase hex chars');
    final size = a.req<int>('size');
    if (size < 0 || size > limits.maxArtifactSize) throw const FormatError('artifact size out of range');
    final path = a.req<String>('path');
    final segments = path.split('/');
    final unsafe = path.isEmpty ||
        path.length > 400 ||
        path.startsWith('/') ||
        path.contains(r'\') ||
        path.contains(':') ||
        segments.any((s) => s == '..' || s.isEmpty) ||
        path.codeUnits.any((u) => u < 0x20);
    if (unsafe) throw FormatError('unsafe artifact path "$path"');
    return HandoffArtifact(name: _short(a.req<String>('name'), 'artifact name'), mimeType: mime, sha256: sha, size: size, path: path);
  }
}
