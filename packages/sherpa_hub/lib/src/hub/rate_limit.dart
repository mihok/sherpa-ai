import 'dart:convert';
import 'dart:math' as math;

import 'package:meta/meta.dart';
import 'package:sherpa_net/sherpa_net.dart';

/// Hub rate-limit buckets: `/api/*`, anything under `/resolve/` (incl.
/// `/api/resolve-cache`), and HTML pages (R08 §6).
enum HubBucket { api, resolvers, pages }

HubBucket bucketForPath(String path) {
  if (path.contains('/resolve/') || path.startsWith('/api/resolve-cache')) return HubBucket.resolvers;
  if (path.startsWith('/api/')) return HubBucket.api;
  return HubBucket.pages;
}

/// One reading of the IETF-draft headers the Hub sends on every response:
/// `ratelimit: "api";r=425;t=157` and
/// `ratelimit-policy: "fixed window";"api";q=500;w=300` (R08 §6, LIVE).
@immutable
final class RateLimitReading {
  const RateLimitReading({required this.bucket, this.remaining, this.resetSeconds, this.quota, this.windowSeconds});

  final String bucket;
  final int? remaining;
  final int? resetSeconds;
  final int? quota;
  final int? windowSeconds;
}

({List<String> names, Map<String, String> params}) _parseStructured(String header) {
  final names = <String>[];
  final params = <String, String>{};
  for (final raw in header.split(';')) {
    final item = raw.trim();
    if (item.isEmpty) continue;
    if (item.startsWith('"') && item.endsWith('"') && item.length >= 2) {
      names.add(item.substring(1, item.length - 1));
      continue;
    }
    final eq = item.indexOf('=');
    if (eq > 0) params[item.substring(0, eq).trim().toLowerCase()] = item.substring(eq + 1).trim();
  }
  return (names: names, params: params);
}

/// Parses `ratelimit` / `ratelimit-policy`; null when absent or malformed.
RateLimitReading? parseRateLimitHeaders(Map<String, String> headers) {
  String? h(String k) => headers[k] ?? headers[k.toLowerCase()];
  final rl = h('ratelimit');
  final policy = h('ratelimit-policy');
  if (rl == null && policy == null) return null;
  String? bucket;
  int? remaining;
  int? reset;
  int? quota;
  int? window;
  if (rl != null) {
    final p = _parseStructured(rl);
    if (p.names.isNotEmpty) bucket = p.names.last;
    remaining = int.tryParse(p.params['r'] ?? '');
    reset = int.tryParse(p.params['t'] ?? '');
  }
  if (policy != null) {
    final p = _parseStructured(policy);
    if (p.names.isNotEmpty) bucket ??= p.names.last;
    quota = int.tryParse(p.params['q'] ?? '');
    window = int.tryParse(p.params['w'] ?? '');
  }
  if (bucket == null) return null;
  return RateLimitReading(bucket: bucket, remaining: remaining, resetSeconds: reset, quota: quota, windowSeconds: window);
}

/// How long a 429 asks us to wait: the JSON `retryAfter` body field (seen
/// live: `{"error":"We had to rate limit your IP…","retryAfter":48}`), then
/// `Retry-After` / vendor headers (`parseRetryAfter`), then `ratelimit` `t=`.
Duration? retryAfterFrom(Map<String, String> headers, String body, {DateTime? now}) {
  try {
    final j = jsonDecode(body);
    if (j is Map && j['retryAfter'] is num) {
      return Duration(milliseconds: ((j['retryAfter'] as num) * 1000).round());
    }
  } on FormatException {
    // Not JSON: fall through to headers.
  }
  final header = parseRetryAfter(headers, now: now);
  if (header != null) return header;
  final rl = parseRateLimitHeaders(headers);
  if (rl?.resetSeconds != null) return Duration(seconds: rl!.resetSeconds!);
  return null;
}

/// Client-side view of the Hub's fixed windows, fed by every response.
///
/// huggingface_hub sleeps `t` seconds when `r=0` (R08 §6); Sherpa also
/// spreads the last 10 % of a window's quota so a browsing session doesn't
/// hit the wall and get a 429 from a shared CGNAT address.
final class HubRateLimiter {
  HubRateLimiter({this.proactiveShare = 0.1, this.proactiveDelayCap = const Duration(seconds: 1)});

  final double proactiveShare;
  final Duration proactiveDelayCap;
  final Map<String, _BucketState> _state = {};

  void observe(Map<String, String> headers, DateTime now) {
    final r = parseRateLimitHeaders(headers);
    if (r == null) return;
    final s = _state.putIfAbsent(r.bucket, _BucketState.new);
    if (r.remaining != null) s.remaining = r.remaining;
    if (r.resetSeconds != null) s.resetAt = now.add(Duration(seconds: r.resetSeconds!));
    if (r.quota != null) s.quota = r.quota;
  }

  /// Records an explicit 429 so other requests in the bucket wait too.
  void blockUntil(String bucket, DateTime until) {
    final s = _state.putIfAbsent(bucket, _BucketState.new);
    s.remaining = 0;
    s.resetAt = until;
  }

  /// Delay before the next request in [bucket], or zero.
  Duration delayFor(String bucket, DateTime now) {
    final s = _state[bucket];
    final reset = s?.resetAt;
    final remaining = s?.remaining;
    if (s == null || reset == null || remaining == null || !reset.isAfter(now)) return Duration.zero;
    final left = reset.difference(now);
    if (remaining <= 0) return left;
    final quota = s.quota;
    if (quota != null && quota > 0 && remaining < quota * proactiveShare) {
      final spread = Duration(microseconds: left.inMicroseconds ~/ math.max(1, remaining));
      return spread > proactiveDelayCap ? proactiveDelayCap : spread;
    }
    return Duration.zero;
  }

  /// Remaining requests in [bucket] as last reported (null = unknown).
  int? remaining(String bucket) => _state[bucket]?.remaining;

  void noteRequest(String bucket) {
    final s = _state[bucket];
    if (s?.remaining != null && s!.remaining! > 0) s.remaining = s.remaining! - 1;
  }
}

final class _BucketState {
  int? remaining;
  int? quota;
  DateTime? resetAt;
}

/// RFC 8288 `Link` header → rel → target. URLs may contain commas
/// (`filter=gguf,mlx`), so entries are matched by their `<…>` brackets.
Map<String, Uri> parseLinkHeader(String? header, {Uri? base}) {
  final out = <String, Uri>{};
  if (header == null || header.isEmpty) return out;
  final re = RegExp(r'<([^>]*)>((?:\s*;\s*[^;,<]+)*)');
  for (final m in re.allMatches(header)) {
    final target = Uri.tryParse(m.group(1)!.trim());
    if (target == null) continue;
    final rel = RegExp(r'rel\s*=\s*"?([^";,]+)"?', caseSensitive: false).firstMatch(m.group(2) ?? '');
    if (rel == null) continue;
    final resolved = base == null ? target : base.resolveUri(target);
    for (final r in rel.group(1)!.trim().split(RegExp(r'\s+'))) {
      out.putIfAbsent(r.toLowerCase(), () => resolved);
    }
  }
  return out;
}
