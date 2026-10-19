/// Size, rate and concurrency limits for one MCP App view.
library;

import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart' show Clock, SystemClock;

/// Limits enforced on View → host traffic. The shell enforces
/// [maxMessageBytes] and its own token bucket ([shellBurst],
/// [shellPerSecond]) before anything reaches native code; the Dart bridge
/// re-checks the size and applies the request limits below.
@immutable
final class McpAppLimits {
  const McpAppLimits({
    this.maxMessageBytes = 1024 * 1024,
    this.maxHtmlBytes = 4 * 1024 * 1024,
    this.shellBurst = 64,
    this.shellPerSecond = 32,
    this.requestBurst = 20,
    this.requestsPerSecond = 10,
    this.maxConcurrentToolCalls = 4,
    this.maxMessageTextChars = 8000,
    this.maxModelContextBytes = 32 * 1024,
    this.maxLogsPerMinute = 60,
    this.maxLogChars = 2000,
    this.toolCallTimeout = const Duration(seconds: 120),
    this.teardownTimeout = const Duration(milliseconds: 1500),
  });

  /// One View message, serialized (shell and Dart). Hard cap 4 MiB.
  final int maxMessageBytes;

  /// The UI resource HTML (UTF-8).
  final int maxHtmlBytes;

  /// Shell token bucket: messages the View may send in a burst, and the
  /// sustained rate. Excess messages are dropped in the shell; requests get
  /// a JSON-RPC error so the View's promise settles.
  final int shellBurst;
  final int shellPerSecond;

  /// Dart token bucket for View REQUESTS (notifications such as
  /// size-changed are coalesced instead).
  final int requestBurst;
  final double requestsPerSecond;

  final int maxConcurrentToolCalls;

  /// Total text of one `ui/message`.
  final int maxMessageTextChars;

  /// One `ui/update-model-context` (serialized).
  final int maxModelContextBytes;

  /// `notifications/message` logs kept per minute, and their length.
  final int maxLogsPerMinute;
  final int maxLogChars;

  /// Upper bound for one View-initiated `tools/call`.
  final Duration toolCallTimeout;

  /// How long teardown waits for the View's `ui/resource-teardown` answer.
  final Duration teardownTimeout;

  static const int hardMaxMessageBytes = 4 * 1024 * 1024;

  int get effectiveMaxMessageBytes => maxMessageBytes.clamp(1024, hardMaxMessageBytes);

  /// The part of the limits the shell enforces (sent with `load`).
  Map<String, Object?> toShellJson() => {
        'maxChars': effectiveMaxMessageBytes,
        'burst': shellBurst,
        'perSecond': shellPerSecond,
      };
}

/// Token bucket on an injectable clock.
final class TokenBucket {
  TokenBucket({required this.capacity, required this.perSecond, Clock clock = const SystemClock()})
      : _clock = clock,
        _tokens = capacity.toDouble(),
        _last = clock.now();

  final int capacity;
  final double perSecond;
  final Clock _clock;
  double _tokens;
  DateTime _last;

  /// Takes one token; false when the bucket is empty.
  bool take() {
    final now = _clock.now();
    final elapsed = now.difference(_last).inMicroseconds / 1e6;
    _last = now;
    if (elapsed > 0) _tokens = (_tokens + elapsed * perSecond).clamp(0, capacity.toDouble());
    if (_tokens < 1) return false;
    _tokens -= 1;
    return true;
  }
}
