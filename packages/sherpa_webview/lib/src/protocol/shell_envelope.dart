/// Sherpa-internal envelope between the Dart bridge and the shell page
/// (through the native WebView bridge, as JSON strings). View JSON-RPC
/// travels inside `view` / `post` envelopes; the View can never produce a
/// shell envelope itself because the shell wraps everything it relays.
library;

import 'dart:convert';

import 'package:meta/meta.dart';

/// Shell envelope protocol version (`ready.v`).
const int shellProtocolVersion = 1;

/// A message from the shell.
@immutable
sealed class ShellEvent {
  const ShellEvent();

  /// Parses one shell string; null for anything malformed.
  static ShellEvent? decode(String raw) {
    final Object? j;
    try {
      j = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (j is! Map) return null;
    final Map<Object?, Object?> e = j;
    switch (e['kind']) {
      case 'ready':
        return ShellReady(version: e['v'] is int ? e['v']! as int : 0, cspOk: e['cspOk'] == true);
      case 'view':
        final m = e['message'];
        return m is Map ? ShellViewMessage(m.cast<String, Object?>()) : null;
      case 'frame-loaded':
        return const ShellFrameLoaded();
      case 'stats':
        int n(String k) => e[k] is int ? e[k]! as int : 0;
        return ShellStats(
          forged: n('forged'),
          malformed: n('malformed'),
          oversized: n('oversized'),
          rateLimited: n('rateLimited'),
        );
      case 'error':
        return ShellError(e['reason'] is String ? e['reason']! as String : 'unknown');
      default:
        return null;
    }
  }
}

/// The shell started. [cspOk] is false when native did not substitute a
/// valid policy into the shell's meta tag; the shell then refuses to load
/// any View.
final class ShellReady extends ShellEvent {
  const ShellReady({required this.version, required this.cspOk});
  final int version;
  final bool cspOk;
}

/// A JSON-RPC message the View posted (already source/size/rate checked by
/// the shell; the bridge validates it again).
final class ShellViewMessage extends ShellEvent {
  const ShellViewMessage(this.message);
  final Map<String, Object?> message;
}

/// The View's iframe fired `load`.
final class ShellFrameLoaded extends ShellEvent {
  const ShellFrameLoaded();
}

/// Cumulative counters of what the shell dropped.
final class ShellStats extends ShellEvent {
  const ShellStats({this.forged = 0, this.malformed = 0, this.oversized = 0, this.rateLimited = 0});
  final int forged;
  final int malformed;
  final int oversized;
  final int rateLimited;
}

final class ShellError extends ShellEvent {
  const ShellError(this.reason);
  final String reason;
}

/// Envelopes sent to the shell.
abstract final class ShellCommand {
  /// Creates the sandboxed iframe from [html].
  static String load({
    required String html,
    required Map<String, Object?> limits,
    String? theme,
    String? title,
  }) =>
      jsonEncode({
        'kind': 'load',
        'html': html,
        'limits': limits,
        'theme': ?theme,
        'title': ?title,
      });

  /// Posts one JSON-RPC message to the View.
  static String post(Map<String, Object?> message) => jsonEncode({'kind': 'post', 'message': message});

  /// Shell-level presentation (the shell's own `color-scheme`).
  static String context({String? theme}) => jsonEncode({'kind': 'context', 'theme': ?theme});

  /// Removes the iframe.
  static String teardown() => jsonEncode({'kind': 'teardown'});
}
