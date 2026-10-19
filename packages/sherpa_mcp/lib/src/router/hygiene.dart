/// Pin, diff and quarantine MCP tool definitions on every `tools/list`
/// (R11 §(e) "rug pulls", §9.7).
library;

import 'dart:async';
import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart' show Clock, JsonMap, SystemClock;

import '../config.dart';
import '../protocol/primitives.dart';
import 'canonical.dart';
import 'injection_scanner.dart';
import 'tool_names.dart';
import 'tool_pin.dart';

/// Where a tool stands after the last review.
enum ToolReviewStatus {
  /// Pinned and unchanged: offered and executable.
  approved,

  /// Never approved (an untrusted server's new tool, or a trusted server's
  /// tool with a critical finding): hidden and not executable.
  quarantinedNew,

  /// Differs from its pin (a "rug pull" until proven otherwise): hidden and
  /// not executable until re-approved from [ToolReview.diff].
  quarantinedChanged,
}

/// The hygiene verdict for one tool.
@immutable
final class ToolReview {
  const ToolReview({
    required this.key,
    required this.status,
    required this.current,
    required this.currentHash,
    required this.findings,
    this.pin,
  });

  final McpToolKey key;
  final ToolReviewStatus status;

  /// The definition as last listed ([pinnedDefinition] subset).
  final JsonMap current;
  final String currentHash;

  /// The approved definition, when there is one.
  final ToolPin? pin;

  /// Injection-marker findings for [current].
  final List<HygieneFinding> findings;

  bool get quarantined => status != ToolReviewStatus.approved;

  /// Any finding: calls need the user's confirmation even where the policy
  /// would auto-approve ("flagged tools require approval").
  bool get flagged => findings.isNotEmpty;

  bool get hasCriticalFinding => findings.any((f) => f.isCritical);

  /// What changed since the pin (null unless [ToolReviewStatus.quarantinedChanged]).
  ToolDefinitionDiff? get diff => status == ToolReviewStatus.quarantinedChanged && pin != null
      ? ToolDefinitionDiff(pin!.definition, current)
      : null;

  /// A human-readable review text for the approval screen: the full new
  /// definition for a new tool, the diff for a changed one, then findings.
  String describe({String? serverName}) {
    final label = '"${key.toolName}"${serverName == null ? '' : ' on $serverName'}';
    final out = StringBuffer();
    switch (status) {
      case ToolReviewStatus.approved:
        out.writeln('Tool $label is approved (${pin?.origin.name ?? 'pinned'}).');
      case ToolReviewStatus.quarantinedNew:
        out
          ..writeln('New tool $label needs your approval before the assistant can use it.')
          ..write(describeDefinition(current));
      case ToolReviewStatus.quarantinedChanged:
        out
          ..writeln('Tool $label changed since you approved it. It is blocked until you review the change.')
          ..writeln(diff!.describe());
    }
    if (findings.isNotEmpty) {
      out.writeln('Warnings:');
      for (final f in findings) {
        out.writeln('  ! ${f.severity == HygieneSeverity.critical ? 'Critical' : 'Warning'}: ${f.message}'
            ' (${f.location})${f.excerpt == null ? '' : ' — ${f.excerpt}'}');
      }
    }
    return out.toString().trimRight();
  }
}

/// What one `tools/list` review found for a server.
@immutable
final class ToolListReview {
  const ToolListReview({
    required this.serverId,
    required this.reviews,
    required this.newlySeen,
    required this.changed,
    required this.removed,
  });

  final String serverId;

  /// Every listed tool, in server order.
  final List<ToolReview> reviews;

  /// Listed now but not in the previous review (first review: all).
  final List<McpToolKey> newlySeen;

  /// Definition differs from its pin (quarantined, or auto-re-pinned for a
  /// built-in server).
  final List<McpToolKey> changed;

  /// In the previous review but gone now (pins are kept).
  final List<McpToolKey> removed;

  List<McpToolKey> get quarantined => [for (final r in reviews) if (r.quarantined) r.key];

  bool get hasChanges => newlySeen.isNotEmpty || changed.isNotEmpty || removed.isNotEmpty;
}

/// Pins every tool's definition hash at first approval, re-checks it on
/// EVERY `tools/list` (not only after `list_changed`: a server can change
/// what it returns without notifying), and quarantines what is new from an
/// untrusted server or changed anywhere, until the user approves it from a
/// readable diff (R11 §9.7; Invariant Labs' rug-pull / poisoning attacks).
///
/// Rules:
/// * NEW tool (no pin): pinned automatically when the server is trusted and
///   the scan has no critical finding; otherwise quarantined.
/// * CHANGED tool (hash ≠ pin): quarantined — trusted or not — except on
///   app-shipped servers ([autoApproveChanges], default: in-process
///   servers), whose definitions only change with an app update.
/// * REMOVED tool: reported; its pin is kept so a comeback is diffed.
/// * Findings are recomputed on every review; any finding flags the tool
///   (per-call confirmation), a critical one also blocks auto-pinning.
final class ToolHygiene {
  ToolHygiene({
    ToolPinStore? store,
    this.scanner = const ToolDescriptionScanner(),
    Clock clock = const SystemClock(),
    bool Function(McpServerConfig server)? autoApproveChanges,
  })  : store = store ?? InMemoryToolPinStore(),
        _clock = clock,
        _autoApproveChanges = autoApproveChanges ?? _isInProcess;

  static bool _isInProcess(McpServerConfig s) => s.transport == McpTransportPreference.inProcess;

  final ToolPinStore store;
  final ToolDescriptionScanner scanner;
  final Clock _clock;
  final bool Function(McpServerConfig server) _autoApproveChanges;

  final Map<String, Map<McpToolKey, ToolReview>> _byServer = {};
  final StreamController<ToolListReview> _changes = StreamController.broadcast(sync: true);

  /// Reviews with changes, and re-emitted reviews after approvals.
  Stream<ToolListReview> get changes => _changes.stream;

  /// Called after the user approved [key]; [wasChange] when it replaced an
  /// older pin. Wire it to revoke approval grants of the old definition
  /// (R11 §9.7: "always allow" is granted for a server + tool + hash).
  void Function(McpToolKey key, {required bool wasChange})? onApproved;

  ToolReview? reviewOf(McpToolKey key) => _byServer[key.serverId]?[key];

  List<ToolReview> reviewsFor(String serverId) => List.unmodifiable(_byServer[serverId]?.values ?? const []);

  /// All quarantined tools, for a "needs review" badge.
  List<ToolReview> get pending => [
        for (final m in _byServer.values)
          for (final r in m.values)
            if (r.quarantined) r,
      ];

  /// Reviews one server's complete tool list. [otherToolNames] are names of
  /// OTHER servers' tools (shadowing detection).
  Future<ToolListReview> review(
    McpServerConfig server,
    List<McpTool> tools, {
    Iterable<String> otherToolNames = const [],
  }) async {
    final pins = {for (final p in await store.forServer(server.id)) p.key: p};
    final previous = _byServer[server.id] ?? const <McpToolKey, ToolReview>{};
    final next = <McpToolKey, ToolReview>{};
    final changed = <McpToolKey>[];
    final others = otherToolNames.toList();
    for (final t in tools) {
      final key = McpToolKey(server.id, t.name);
      final current = pinnedDefinition(t);
      final hash = pinHashOf(current);
      final findings = scanner.scanTool(
        name: t.name,
        title: t.title ?? t.annotations.title,
        description: t.description,
        inputSchema: t.inputSchema,
        outputSchema: t.outputSchema,
        otherToolNames: others,
      );
      final critical = findings.any((f) => f.isCritical);
      var pin = pins[key];
      final ToolReviewStatus status;
      if (pin == null) {
        final builtin = _autoApproveChanges(server);
        if ((server.trusted || builtin) && !critical) {
          pin = ToolPin(
            key: key,
            hash: hash,
            definition: current,
            approvedAt: _clock.now(),
            origin: builtin ? PinOrigin.builtin : PinOrigin.trustedServer,
          );
          await store.put(pin);
          status = ToolReviewStatus.approved;
        } else {
          status = ToolReviewStatus.quarantinedNew;
        }
      } else if (pin.hash == hash) {
        status = ToolReviewStatus.approved;
      } else {
        changed.add(key);
        if (_autoApproveChanges(server) && !critical) {
          pin = ToolPin(key: key, hash: hash, definition: current, approvedAt: _clock.now(), origin: PinOrigin.builtin);
          await store.put(pin);
          status = ToolReviewStatus.approved;
        } else {
          status = ToolReviewStatus.quarantinedChanged;
        }
      }
      next[key] = ToolReview(
        key: key,
        status: status,
        current: current,
        currentHash: hash,
        findings: List.unmodifiable(findings),
        pin: pin,
      );
    }
    _byServer[server.id] = next;
    final result = ToolListReview(
      serverId: server.id,
      reviews: List.unmodifiable(next.values),
      newlySeen: [for (final k in next.keys) if (!previous.containsKey(k)) k],
      changed: changed,
      removed: [for (final k in previous.keys) if (!next.containsKey(k)) k],
    );
    if (result.hasChanges) _changes.add(result);
    return result;
  }

  /// Approves the CURRENT definition of [key] (pins its hash). Returns false
  /// when the tool is unknown (never listed). Approving an already approved
  /// tool is a no-op that returns true.
  Future<bool> approve(McpToolKey key) async {
    final r = reviewOf(key);
    if (r == null) return false;
    if (!r.quarantined) return true;
    final pin = ToolPin(
      key: key,
      hash: r.currentHash,
      definition: r.current,
      approvedAt: _clock.now(),
      origin: PinOrigin.user,
    );
    await store.put(pin);
    final wasChange = r.status == ToolReviewStatus.quarantinedChanged;
    _byServer[key.serverId]![key] = ToolReview(
      key: key,
      status: ToolReviewStatus.approved,
      current: r.current,
      currentHash: r.currentHash,
      findings: r.findings,
      pin: pin,
    );
    onApproved?.call(key, wasChange: wasChange);
    _emitState(key.serverId);
    return true;
  }

  /// Approves every quarantined tool of a server ("review all" after the
  /// user went through the list). Returns how many were approved.
  Future<int> approveServer(String serverId) async {
    var n = 0;
    for (final r in reviewsFor(serverId)) {
      if (r.quarantined && await approve(r.key)) n++;
    }
    return n;
  }

  /// Forgets a removed server: its reviews and pins.
  Future<void> forgetServer(String serverId) async {
    _byServer.remove(serverId);
    await store.removeServer(serverId);
  }

  void _emitState(String serverId) {
    final m = _byServer[serverId];
    if (m == null) return;
    _changes.add(ToolListReview(
      serverId: serverId,
      reviews: List.unmodifiable(m.values),
      newlySeen: const [],
      changed: const [],
      removed: const [],
    ));
  }

  Future<void> dispose() => _changes.close();
}

/// One difference between two pinned definitions.
@immutable
final class ToolChangeItem {
  const ToolChangeItem(this.path, {this.before, this.after, this.hadBefore = true, this.hasAfter = true});

  /// Dotted path, e.g. `inputSchema.properties.title.type`.
  final String path;
  final Object? before;
  final Object? after;
  final bool hadBefore;
  final bool hasAfter;

  bool get isAddition => !hadBefore && hasAfter;

  bool get isRemoval => hadBefore && !hasAfter;

  @override
  String toString() => isAddition
      ? '+ $path = ${_show(after)}'
      : isRemoval
          ? '- $path (was ${_show(before)})'
          : '~ $path: ${_show(before)} → ${_show(after)}';
}

String _show(Object? v, [int max = 120]) {
  final s = v is String ? jsonEncode(v) : canonicalJson(v);
  return s.length > max ? '${s.substring(0, max - 1)}…' : s;
}

/// A readable diff between a pinned and a current definition (R11 §9.7:
/// "re-approves from a readable diff").
final class ToolDefinitionDiff {
  ToolDefinitionDiff(this.before, this.after) {
    _diff(before, after, '', items);
  }

  final JsonMap before;
  final JsonMap after;

  /// Every leaf-level difference (capped at [maxItems]).
  final List<ToolChangeItem> items = [];

  static const int maxItems = 60;

  bool get isEmpty => items.isEmpty;

  bool get descriptionChanged => items.any((i) => i.path == 'description' || i.path == 'title');

  bool get schemaChanged => items.any((i) => i.path.startsWith('inputSchema') || i.path.startsWith('outputSchema'));

  bool get annotationsChanged => items.any((i) => i.path.startsWith('annotations'));

  static void _diff(Object? a, Object? b, String path, List<ToolChangeItem> out) {
    if (out.length >= maxItems) return;
    if (a is Map && b is Map) {
      final keys = {...a.keys.map((k) => '$k'), ...b.keys.map((k) => '$k')}.toList()..sort();
      for (final k in keys) {
        final p = path.isEmpty ? k : '$path.$k';
        final inA = a.containsKey(k);
        final inB = b.containsKey(k);
        if (inA && !inB) {
          out.add(ToolChangeItem(p, before: a[k], hasAfter: false));
        } else if (!inA && inB) {
          out.add(ToolChangeItem(p, after: b[k], hadBefore: false));
        } else {
          _diff(a[k], b[k], p, out);
        }
        if (out.length >= maxItems) return;
      }
      return;
    }
    if (canonicalJson(a) != canonicalJson(b)) out.add(ToolChangeItem(path, before: a, after: b));
  }

  /// Text for the review screen: description changes first (with the
  /// inserted / removed passage isolated, since that is where poisoning
  /// hides), then parameters, then annotations and everything else.
  String describe() {
    final out = StringBuffer();
    for (final key in const ['title', 'description']) {
      final item = items.where((i) => i.path == key).firstOrNull;
      if (item == null) continue;
      final b = item.before is String ? item.before! as String : '';
      final a = item.after is String ? item.after! as String : '';
      out.writeln('${key == 'title' ? 'Title' : 'Description'} changed:');
      out
        ..writeln('  before: ${_quoteBlock(b)}')
        ..writeln('  after:  ${_quoteBlock(a)}');
      final (removed, added) = _middle(b, a);
      if (added.isNotEmpty) out.writeln('  added text: ${_quoteBlock(added)}');
      if (removed.isNotEmpty) out.writeln('  removed text: ${_quoteBlock(removed)}');
    }
    final params = <String>[];
    final handled = <ToolChangeItem>{};
    for (final i in items) {
      final m = RegExp(r'^inputSchema\.properties\.([^.]+)$').firstMatch(i.path);
      if (m != null && (i.isAddition || i.isRemoval)) {
        handled.add(i);
        final name = m.group(1)!;
        params.add(i.isAddition
            ? '+ new parameter "$name": ${describeParameter(i.after, required: _required(after).contains(name))}'
            : '- parameter "$name" removed');
      }
    }
    final reqBefore = _required(before);
    final reqAfter = _required(after);
    final nowRequired = reqAfter.difference(reqBefore).where((n) => !params.any((p) => p.contains('"$n"'))).toList();
    final noLonger = reqBefore.difference(reqAfter).toList();
    for (final i in items) {
      if (i.path.startsWith('inputSchema.required')) handled.add(i);
    }
    if (nowRequired.isNotEmpty) params.add('~ now required: ${nowRequired.join(', ')}');
    if (noLonger.isNotEmpty) params.add('~ no longer required: ${noLonger.join(', ')}');
    for (final i in items) {
      final m = RegExp(r'^inputSchema\.properties\.([^.]+)\.(.+)$').firstMatch(i.path);
      if (m == null) continue;
      handled.add(i);
      final change = i.isAddition
          ? 'added ${_show(i.after)}'
          : i.isRemoval
              ? 'removed (was ${_show(i.before)})'
              : '${_show(i.before)} → ${_show(i.after)}';
      params.add('~ "${m.group(1)}" ${m.group(2)}: $change');
    }
    if (params.isNotEmpty) {
      out.writeln('Parameters:');
      for (final p in params) {
        out.writeln('  $p');
      }
    }
    final rest = [
      for (final i in items)
        if (!handled.contains(i) && i.path != 'title' && i.path != 'description') i,
    ];
    final annotations = [for (final i in rest) if (i.path.startsWith('annotations')) i];
    if (annotations.isNotEmpty) {
      out.writeln('Annotations:');
      for (final i in annotations) {
        out.writeln('  $i');
      }
    }
    final other = [for (final i in rest) if (!i.path.startsWith('annotations')) i];
    if (other.isNotEmpty) {
      out.writeln('Other changes:');
      for (final i in other) {
        out.writeln('  $i');
      }
    }
    if (items.length >= maxItems) out.writeln('  … (more changes not shown)');
    return out.toString().trimRight();
  }

  static Set<String> _required(JsonMap def) {
    final schema = def['inputSchema'];
    final r = schema is Map ? schema['required'] : null;
    return r is List ? {...r.whereType<String>()} : <String>{};
  }

  static String _quoteBlock(String s) => s.isEmpty ? '(none)' : jsonEncode(s);

  /// The differing middle of two strings after removing their common
  /// prefix and suffix: (removed from [a], added in [b]).
  static (String, String) _middle(String a, String b) {
    var p = 0;
    while (p < a.length && p < b.length && a.codeUnitAt(p) == b.codeUnitAt(p)) {
      p++;
    }
    var s = 0;
    while (s < a.length - p && s < b.length - p && a.codeUnitAt(a.length - 1 - s) == b.codeUnitAt(b.length - 1 - s)) {
      s++;
    }
    return (a.substring(p, a.length - s).trim(), b.substring(p, b.length - s).trim());
  }
}

/// A compact description of a parameter schema: `string, required — text`.
String describeParameter(Object? schema, {bool required = false}) {
  final s = schema is Map ? schema.cast<String, Object?>() : const <String, Object?>{};
  final type = switch (s['type']) {
    final String t => t,
    final List<Object?> l => l.whereType<String>().join('|'),
    _ => s['enum'] is List ? 'enum' : (s[r'$ref'] != null ? 'object' : 'any'),
  };
  final en = s['enum'];
  final enumText = en is List && en.isNotEmpty
      ? ' one of ${en.take(6).map((e) => e is String ? e : jsonEncode(e)).join('|')}${en.length > 6 ? '|…' : ''}'
      : '';
  final d = s['description'];
  return '$type$enumText${required ? ', required' : ''}${d is String && d.isNotEmpty ? ' — ${d.trim()}' : ''}';
}

/// A readable card of a whole (pinned-subset) definition, for new tools.
String describeDefinition(JsonMap def) {
  final out = StringBuffer();
  final d = def['description'];
  out.writeln('Description: ${d is String && d.isNotEmpty ? jsonEncode(d) : '(none)'}');
  final schema = def['inputSchema'];
  final props = schema is Map ? schema['properties'] : null;
  final req = schema is Map && schema['required'] is List ? {...(schema['required']! as List).whereType<String>()} : <String>{};
  if (props is Map && props.isNotEmpty) {
    out.writeln('Parameters:');
    for (final e in props.entries) {
      out.writeln('  - ${e.key}: ${describeParameter(e.value, required: req.contains(e.key))}');
    }
  } else {
    out.writeln('Parameters: none');
  }
  final a = def['annotations'];
  if (a is Map && a.isNotEmpty) out.writeln('Declared hints (unverified): ${canonicalJson(a)}');
  final ui = def['ui'];
  if (ui is Map && ui.isNotEmpty) out.writeln('App UI: ${canonicalJson(ui)}');
  return out.toString();
}
