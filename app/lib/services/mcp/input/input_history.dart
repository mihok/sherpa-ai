/// What each server asked for and how it ended, for the server's debug
/// console. Redacted by construction: answers are never recorded (field
/// names only), URLs lose their query and fragment, sampling keeps counts.
library;

import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart' show immutable;
import 'package:sherpa_mcp/sherpa_mcp.dart';
import 'package:sherpa_net/sherpa_net.dart' show Redactor;

import 'elicitation_form.dart';
import 'input_queue.dart';

enum McpInputKind { form, url, sampling, roots }

@immutable
final class McpInputRecord {
  const McpInputRecord({
    required this.at,
    required this.serverId,
    required this.kind,
    required this.outcome,
    required this.summary,
    this.toolName,
    this.reason,
  });

  final DateTime at;
  final String serverId;
  final McpInputKind kind;
  final McpInputOutcome outcome;

  /// Redacted: what was asked, never what was answered.
  final String summary;
  final String? toolName;

  /// Why it was refused or failed, when it was.
  final String? reason;

  String get kindLabel => switch (kind) {
        McpInputKind.form => 'form',
        McpInputKind.url => 'web page',
        McpInputKind.sampling => 'model use',
        McpInputKind.roots => 'folders',
      };

  String get outcomeLabel => switch (outcome) {
        McpInputOutcome.accepted => 'answered',
        McpInputOutcome.declined => 'declined',
        McpInputOutcome.cancelled => 'cancelled',
        McpInputOutcome.timedOut => 'timed out',
        McpInputOutcome.refused => 'refused by Sherpa',
        McpInputOutcome.failed => 'failed',
      };
}

/// A bounded ring per server (in memory: the console is a debug aid).
final class McpInputHistory {
  McpInputHistory({this.capacity = 50});

  final int capacity;
  final Map<String, ListQueue<McpInputRecord>> _byServer = {};
  final StreamController<String> _changes = StreamController<String>.broadcast();

  Stream<String> get changes => _changes.stream;

  void add(McpInputRecord r) {
    final q = _byServer.putIfAbsent(r.serverId, ListQueue.new);
    q.addLast(r);
    while (q.length > capacity) {
      q.removeFirst();
    }
    if (!_changes.isClosed) _changes.add(r.serverId);
  }

  /// Newest last.
  List<McpInputRecord> of(String serverId) => List.unmodifiable(_byServer[serverId] ?? const <McpInputRecord>[]);

  void forget(String serverId) {
    if (_byServer.remove(serverId) != null && !_changes.isClosed) _changes.add(serverId);
  }

  Future<void> dispose() => _changes.close();

  // ------------------------------------------------------------ summaries

  static String _clip(String s, [int max = 120]) {
    final r = Redactor.text(s.replaceAll(RegExp(r'\s+'), ' ').trim());
    return r.length > max ? '${r.substring(0, max - 1)}…' : r;
  }

  /// "Form: name, email — "Who are you?"" (field names, never values).
  static String formSummary(McpElicitRequest r, ElicitationForm f) {
    final names = [for (final x in f.fields) x.key, ...f.unsupported];
    final shown = names.take(6).join(', ');
    final more = names.length > 6 ? ' +${names.length - 6}' : '';
    final message = r.message.trim().isEmpty ? '' : ' — "${_clip(r.message, 80)}"';
    return 'Fields: ${names.isEmpty ? '(none)' : '$shown$more'}$message';
  }

  /// The URL without query or fragment (they often carry codes or state).
  static String urlSummary(McpElicitRequest r) {
    final u = r.url;
    if (u == null) return 'Open a page';
    final bare = Uri(scheme: u.scheme, host: u.host, port: u.hasPort ? u.port : null, path: u.path);
    final extra = (u.hasQuery || u.hasFragment) ? ' (query removed)' : '';
    return 'Open ${_clip(bare.toString(), 100)}$extra';
  }

  static String samplingSummary(McpSamplingRequest r, {int? maxTokens, String? model, int? outputTokens}) {
    final parts = [
      '${r.messages.length} message${r.messages.length == 1 ? '' : 's'}',
      'up to ${maxTokens ?? r.maxTokens} tokens',
      if (model != null) 'model $model',
      if (outputTokens != null) 'answer ≈$outputTokens tokens',
      if (r.includeContext != null && r.includeContext != 'none') 'asked for context "${_clip(r.includeContext!, 20)}"',
    ];
    return parts.join(', ');
  }
}
