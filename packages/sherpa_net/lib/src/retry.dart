import 'dart:io' show HttpDate;
import 'dart:math';

/// Exponential backoff with full jitter, capped.
final class Backoff {
  Backoff({
    this.base = const Duration(milliseconds: 500),
    this.max = const Duration(seconds: 30),
    Random? random,
  }) : _random = random ?? Random();

  final Duration base;
  final Duration max;
  final Random _random;

  Duration delay(int attempt) {
    final ceiling = base.inMilliseconds * pow(2, attempt).toInt();
    final capped = ceiling > max.inMilliseconds ? max.inMilliseconds : ceiling;
    return Duration(milliseconds: _random.nextInt(capped + 1));
  }
}

/// Parses `Retry-After` (delta-seconds or HTTP-date) and the common
/// vendor variants (`retry-after-ms`, `x-ratelimit-reset-requests: 1.5s`).
Duration? parseRetryAfter(Map<String, String> headers, {DateTime? now}) {
  String? h(String k) => headers[k] ?? headers[k.toLowerCase()];
  final ms = h('retry-after-ms');
  if (ms != null) {
    final v = double.tryParse(ms.trim());
    if (v != null && v >= 0) return Duration(milliseconds: v.round());
  }
  final ra = h('retry-after');
  if (ra != null) {
    final secs = double.tryParse(ra.trim());
    if (secs != null && secs >= 0) return Duration(milliseconds: (secs * 1000).round());
    try {
      final date = HttpDate.parse(ra.trim());
      final d = date.difference(now ?? DateTime.now().toUtc());
      return d.isNegative ? Duration.zero : d;
    } on FormatException {
      return null;
    }
  }
  final reset = h('x-ratelimit-reset-requests') ?? h('x-ratelimit-reset');
  if (reset != null) {
    final m = RegExp(r'^(?:(\d+)m)?(?:([\d.]+)s)?(?:(\d+)ms)?$').firstMatch(reset.trim());
    if (m != null && m.group(0)!.isNotEmpty) {
      final minutes = int.tryParse(m.group(1) ?? '') ?? 0;
      final seconds = double.tryParse(m.group(2) ?? '') ?? 0;
      final millis = int.tryParse(m.group(3) ?? '') ?? 0;
      return Duration(milliseconds: minutes * 60000 + (seconds * 1000).round() + millis);
    }
  }
  return null;
}
