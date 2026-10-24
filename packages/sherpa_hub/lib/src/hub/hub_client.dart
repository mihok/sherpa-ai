import 'dart:async';
import 'dart:convert';
import 'dart:io' show IOException;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_net/sherpa_net.dart';

import '../gguf/gguf_reader.dart';
import 'hub_exception.dart';
import 'hub_models.dart';
import 'rate_limit.dart';

/// Returns the current Hub token (OAuth access token or `hf_…` user token),
/// or null when signed out. Called per request so a refreshed token is used
/// without rebuilding the client.
typedef HubTokenProvider = Future<String?> Function();

typedef HubSleep = Future<void> Function(Duration);

@immutable
final class HubRetryPolicy {
  const HubRetryPolicy({
    this.maxRetries = 3,
    this.maxAutoWait = const Duration(seconds: 15),
    this.requestTimeout = const Duration(seconds: 30),
    this.bodyTimeout = const Duration(seconds: 60),
  });

  /// Retries for 408/429/5xx and connection errors (huggingface_hub retries
  /// 408/429/500/502/503/504, R08 §6).
  final int maxRetries;

  /// Longer rate-limit waits are surfaced as [HubRateLimitedException] for
  /// the UI ("signed-in users get higher limits") instead of blocking.
  final Duration maxAutoWait;

  /// Until the response headers arrive.
  final Duration requestTimeout;

  /// Reading a buffered (JSON) response body after its headers: a body
  /// that stalls on a weak mobile link becomes a [HubNetworkException]
  /// instead of a list that loads forever.
  final Duration bodyTimeout;
}

/// Result of [HfHubClient.readGgufHeader].
@immutable
final class GgufPeek {
  const GgufPeek({required this.resolved, required this.header, required this.bytesFetched, this.fileSize});

  final ResolvedDownload resolved;
  final GgufHeader header;

  /// Bytes downloaded to read the header (one to three Range requests).
  final int bytesFetched;
  final int? fileSize;
}

/// Hugging Face Hub REST client (R08 §2–§7).
///
/// - Search uses `filter=` (not `library=`, which is ignored), Link-header
///   cursors, and `expand[]` so one request fills a page of cards.
/// - Downloads are *resolved*, not fetched: the resolve request does not
///   follow redirects, so the token is sent to `huggingface.co` only and the
///   app's download manager fetches the signed CDN URL itself.
/// - Every response feeds a [HubRateLimiter]; 429s honour the JSON
///   `retryAfter`, `Retry-After`, or the `ratelimit` reset.
final class HfHubClient {
  HfHubClient({
    required http.Client httpClient,
    HubTokenProvider? tokenProvider,
    Uri? baseUri,
    Clock clock = const SystemClock(),
    HubSleep? sleep,
    this.retryPolicy = const HubRetryPolicy(),
    Backoff? backoff,
    UrlPolicy redirectPolicy = const UrlPolicy(),
    this.userAgent = 'sherpa-hub/0.1',
    HubRateLimiter? rateLimiter,
  })  : _http = httpClient,
        _token = tokenProvider,
        baseUri = baseUri ?? defaultBase,
        _clock = clock,
        _sleep = sleep ?? Future<void>.delayed,
        _backoff = backoff ?? Backoff(),
        _redirectPolicy = redirectPolicy,
        rateLimiter = rateLimiter ?? HubRateLimiter();

  static final Uri defaultBase = Uri.parse('https://huggingface.co');

  final http.Client _http;
  final HubTokenProvider? _token;
  final Uri baseUri;
  final Clock _clock;
  final HubSleep _sleep;
  final Backoff _backoff;

  /// Validates cross-origin redirect targets (the CDN) before handing them
  /// to the download manager.
  final UrlPolicy _redirectPolicy;
  final HubRetryPolicy retryPolicy;
  final String userAgent;
  final HubRateLimiter rateLimiter;

  static final RegExp _repoId = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9._-]+$');

  // ---- search -------------------------------------------------------------

  /// One page of `GET /api/models`.
  ///
  /// With several [ModelSearchQuery.authors] (e.g. the pinned quantizers),
  /// one request per author is sent and the results are merged by the sort
  /// key; the cursor then encodes every author's position, and a page can
  /// hold up to `limit` items per author. Global order across fan-out pages
  /// is approximate.
  Future<HubPage<HubModelSummary>> searchModels(ModelSearchQuery query, {String? cursor}) async {
    if (query.ascending && query.sort != HubSort.createdAt) {
      // The server answers 400 "only descending sort is supported" (R08 §0.2).
      throw ArgumentError.value(query.sort, 'sort', 'only createdAt supports ascending order');
    }
    if (query.authors.length <= 1) {
      return _searchOne(query, query.authors.isEmpty ? null : query.authors.single, cursor);
    }
    final positions = cursor == null ? {for (final a in query.authors) a: ''} : _decodeFanOut(cursor);
    final pages = await Future.wait([
      for (final a in query.authors)
        if (positions[a] != null)
          _searchOne(query, a, positions[a]!.isEmpty ? null : positions[a]).then((p) => MapEntry(a, p)),
    ]);
    final seen = <String>{};
    final merged = <HubModelSummary>[
      for (final p in pages)
        for (final m in p.value.items)
          if (seen.add(m.dedupeKey)) m,
    ];
    final dir = query.ascending ? 1 : -1;
    merged.sort((x, y) => dir * x.sortValue(query.sort).compareTo(y.sortValue(query.sort)));
    final next = <String, String?>{for (final a in query.authors) a: null};
    for (final p in pages) {
      next[p.key] = p.value.nextCursor;
    }
    final more = next.values.any((c) => c != null);
    return HubPage(List.unmodifiable(merged), nextCursor: more ? _encodeFanOut(next) : null);
  }

  Future<HubPage<HubModelSummary>> _searchOne(ModelSearchQuery q, String? author, String? cursor) async {
    final params = <String, List<String>>{
      if (q.text != null && q.text!.trim().isNotEmpty) 'search': [q.text!.trim()],
      if (author != null) 'author': [author],
      'filter': [if (q.format != null) q.format!.tag, ...q.tags],
      if (q.pipelineTag != null) 'pipeline_tag': [q.pipelineTag!],
      if (q.gated != null) 'gated': ['${q.gated}'],
      'sort': [q.sort.apiValue],
      if (q.ascending) 'direction': ['1'],
      'limit': ['${q.limit.clamp(1, 1000)}'],
      if (q.expand.isNotEmpty) 'expand': q.expand,
      if (cursor != null) 'cursor': [cursor],
    }..removeWhere((_, v) => v.isEmpty);
    final url = baseUri.replace(path: '/api/models', queryParameters: params);
    final resp = await _getJson(url);
    final body = resp.json;
    if (body is! List) throw HubProtocolException('model list is not a JSON array', url: url);
    final items = [for (final e in body) if (e is Map) HubModelSummary.fromJson(e.cast<String, Object?>())];
    final next = parseLinkHeader(resp.headers['link'], base: url)['next'];
    return HubPage(List.unmodifiable(items), nextCursor: next?.queryParameters['cursor']);
  }

  String _encodeFanOut(Map<String, String?> positions) =>
      base64Url.encode(utf8.encode(jsonEncode({'v': 1, 'authors': positions})));

  Map<String, String?> _decodeFanOut(String cursor) {
    try {
      final j = jsonDecode(utf8.decode(base64Url.decode(cursor)));
      final a = (j as Map)['authors'] as Map;
      return {for (final e in a.entries) '${e.key}': e.value as String?};
    } on Object {
      throw ArgumentError.value(cursor, 'cursor', 'not a cursor from this client');
    }
  }

  // ---- model details ---------------------------------------------------

  /// `GET /api/models/{repo}[/revision/{rev}]` with sizes + sha256 of every
  /// file (`blobs=true`) and the scan summary (`securityStatus=true`). One
  /// API call per detail screen (R08 §15.2); pin downloads to `sha`.
  Future<HubModelInfo> modelInfo(String repo, {String? revision, bool blobs = true, bool securityStatus = true}) async {
    _checkRepo(repo);
    final segments = ['api', 'models', ...repo.split('/'), if (revision != null) ...['revision', revision]];
    final url = baseUri.replace(pathSegments: segments, queryParameters: {
      if (blobs) 'blobs': 'true',
      if (securityStatus) 'securityStatus': 'true',
    });
    final resp = await _getJson(url, repo: repo);
    final body = resp.json;
    if (body is! Map) throw HubProtocolException('model info is not a JSON object', url: url);
    return HubModelInfo.fromJson(body.cast<String, Object?>());
  }

  /// Every file under [path] at [revision] via the tree endpoint
  /// (`recursive` + `expand` for `lastCommit` and `securityFileStatus`),
  /// following `Link` pagination (100 entries per page with expand).
  Future<List<HubRepoFile>> listFiles(
    String repo, {
    String revision = 'main',
    String? path,
    bool recursive = true,
    bool expand = true,
    int maxPages = 200,
  }) async {
    _checkRepo(repo);
    final segments = ['api', 'models', ...repo.split('/'), 'tree', revision, if (path != null) ...path.split('/')];
    var url = baseUri.replace(pathSegments: segments, queryParameters: {
      'recursive': '$recursive',
      'expand': '$expand',
    });
    final prefix = '/api/models/$repo/tree/';
    final out = <HubRepoFile>[];
    for (var page = 0; page < maxPages; page++) {
      final resp = await _getJson(url, repo: repo);
      final body = resp.json;
      if (body is! List) throw HubProtocolException('tree listing is not a JSON array', url: url);
      out.addAll([for (final e in body) if (e is Map) HubRepoFile.fromTreeJson(e.cast<String, Object?>())]);
      final next = parseLinkHeader(resp.headers['link'], base: url)['next'];
      if (next == null) return List.unmodifiable(out);
      if (!_sameOrigin(next) || !next.path.startsWith(prefix)) {
        throw HubProtocolException('tree pagination left the repository', url: next);
      }
      url = next;
    }
    throw HubProtocolException('tree listing exceeded $maxPages pages', url: url);
  }

  /// `POST /api/models/{repo}/paths-info/{rev}`: sizes/hashes for just the
  /// files a plan needs. Unknown paths are silently omitted by the server
  /// (R08 §4.2) — compare the result with [paths].
  Future<List<HubRepoFile>> pathsInfo(String repo, String revision, List<String> paths, {bool expand = true}) async {
    _checkRepo(repo);
    final url = baseUri.replace(pathSegments: ['api', 'models', ...repo.split('/'), 'paths-info', revision]);
    final resp = await _request('POST', url,
        repo: repo,
        headers: {'content-type': 'application/json', 'accept': 'application/json'},
        body: jsonEncode({'paths': paths, 'expand': expand}));
    final body = _decode(resp, url);
    if (body is! List) throw HubProtocolException('paths-info is not a JSON array', url: url);
    return List.unmodifiable([for (final e in body) if (e is Map) HubRepoFile.fromTreeJson(e.cast<String, Object?>())]);
  }

  /// Validates the token (`/api/whoami-v2`): an invalid token is silently
  /// ignored on public reads, so sign-in must check explicitly (R08 §1).
  Future<HubWhoAmI> whoami() async {
    final url = baseUri.replace(path: '/api/whoami-v2');
    final resp = await _getJson(url, unauthorizedIsMissingRepo: false);
    final body = resp.json;
    if (body is! Map) throw HubProtocolException('whoami is not a JSON object', url: url);
    return HubWhoAmI.fromJson(body.cast<String, Object?>());
  }

  // ---- downloads -----------------------------------------------------------

  /// Resolves a file to the URL its bytes come from, without following the
  /// redirect (R08 §5.5 step 2).
  ///
  /// LFS/Xet files answer 302 to a CloudFront-signed CDN URL valid for one
  /// hour plus `X-Linked-Size` (real size), `X-Linked-ETag` (SHA-256),
  /// `X-Xet-Hash` (CDN ETag) and `X-Repo-Commit`; small files answer 307 to a
  /// relative `resolve-cache` URL on the Hub itself. The token is attached
  /// here (Hub origin) and [ResolvedDownload.sendAuthorization] tells the
  /// download manager whether it may attach it to [ResolvedDownload.url].
  Future<ResolvedDownload> resolveDownload(String repo, String revision, String path) async {
    _checkRepo(repo);
    _checkPath(path);
    final url = baseUri.replace(pathSegments: [...repo.split('/'), 'resolve', revision, ...path.split('/')]);
    final resp = await _send('HEAD', url, followRedirects: false, headers: const {'accept-encoding': 'identity'});
    await resp.stream.drain<void>();
    final h = resp.headers;
    final status = resp.statusCode;
    Uri target;
    if (const {301, 302, 303, 307, 308}.contains(status)) {
      final location = h['location'];
      if (location == null || location.isEmpty) {
        throw HubProtocolException('redirect without Location', statusCode: status, url: url);
      }
      target = url.resolve(location);
      if (!_sameOrigin(target)) {
        try {
          _redirectPolicy.checkSyntax(target.toString());
        } on UrlPolicyViolation catch (e) {
          throw HubProtocolException('refusing redirect: ${e.reason}', statusCode: status, url: target);
        }
      }
    } else if (status >= 200 && status < 300) {
      target = url;
    } else {
      throw _error(status, h, '', url, repo: repo);
    }
    final linked = _unquote(h['x-linked-etag']);
    final expires = int.tryParse(target.queryParameters['Expires'] ?? '');
    return ResolvedDownload(
      repo: repo,
      revision: revision,
      path: path,
      url: target,
      sendAuthorization: _sameOrigin(target),
      statusCode: status,
      commit: h['x-repo-commit'],
      size: int.tryParse(h['x-linked-size'] ?? '') ?? (status == 200 ? int.tryParse(h['content-length'] ?? '') : null),
      linkedEtag: linked,
      xetHash: h['x-xet-hash'] ?? (_sameOrigin(target) ? null : _unquote(h['etag'])),
      expiresAt: expires == null ? null : DateTime.fromMillisecondsSinceEpoch(expires * 1000, isUtc: true),
    );
  }

  /// Reads GGUF metadata from the head of a remote file with Range
  /// requests: [initialBytes] first, then more if the KV section is longer
  /// (big-vocab models need ~8 MB, R08 §5.6), never beyond [maxBytes].
  /// Re-resolves once if the signed URL expired mid-way. Throws
  /// [GgufFormatException] for files llama.cpp would refuse (big-endian,
  /// wrong magic) and [HubProtocolException] if the metadata exceeds
  /// [maxBytes].
  Future<GgufPeek> readGgufHeader(
    String repo,
    String revision,
    String path, {
    int maxBytes = 32 << 20,
    int initialBytes = 2 << 20,
    bool readTensorInfo = false,
  }) async {
    var resolved = await resolveDownload(repo, revision, path);
    final buffer = BytesBuilder(copy: false);
    int? fileSize = resolved.size;
    var want = math.min(initialBytes, maxBytes);
    var reResolved = false;
    while (true) {
      if (fileSize != null) want = math.min(want, fileSize);
      final have = buffer.length;
      if (want > have) {
        ({Uint8List bytes, int? total}) chunk;
        try {
          chunk = await _rangeGet(resolved, have, want - 1);
        } on HubUrlExpiredException {
          if (reResolved) rethrow;
          reResolved = true;
          resolved = await resolveDownload(repo, revision, path);
          continue;
        }
        if (chunk.bytes.isEmpty) {
          throw HubProtocolException('empty range response at byte $have', url: resolved.url);
        }
        buffer.add(chunk.bytes);
        fileSize ??= chunk.total;
      }
      final bytes = buffer.toBytes();
      final r = GgufReader.parse(bytes, fileSize: fileSize, readTensorInfo: readTensorInfo);
      switch (r) {
        case GgufNeedMoreBytes(:final requiredBytes):
          if (requiredBytes > maxBytes) {
            throw HubProtocolException('GGUF metadata needs $requiredBytes bytes (limit $maxBytes)', url: resolved.url);
          }
          if (fileSize != null && bytes.length >= fileSize) {
            throw HubProtocolException('GGUF file ends inside its metadata', url: resolved.url);
          }
          want = math.min(maxBytes, math.max(requiredBytes, bytes.length * 2));
        case GgufHeader():
          final need = r.tensorInfoRequiredBytes;
          if (readTensorInfo && !r.hasTensorInfo && need != null && need <= maxBytes && bytes.length < need) {
            want = math.min(maxBytes, math.max(need, bytes.length * 2));
            continue;
          }
          return GgufPeek(resolved: resolved, header: r, bytesFetched: bytes.length, fileSize: fileSize);
      }
    }
  }

  Future<({Uint8List bytes, int? total})> _rangeGet(ResolvedDownload d, int start, int end) async {
    final resp = await _send('GET', d.url,
        headers: {'range': 'bytes=$start-$end', 'accept-encoding': 'identity'},
        attachToken: d.sendAuthorization);
    final status = resp.statusCode;
    if (status == 416) {
      await resp.stream.drain<void>();
      return (bytes: Uint8List(0), total: _contentRangeTotal(resp.headers['content-range']));
    }
    if (status != 206 && status != 200) {
      final body = await _readText(resp);
      throw _error(status, resp.headers, body, d.url, repo: d.repo);
    }
    final total = _contentRangeTotal(resp.headers['content-range']);
    if (status == 206) {
      final cr = RegExp(r'bytes\s+(\d+)-').firstMatch(resp.headers['content-range'] ?? '');
      if (cr != null && int.parse(cr.group(1)!) != start) {
        await resp.stream.drain<void>();
        throw HubProtocolException('server returned a different range than requested', statusCode: status, url: d.url);
      }
    }
    // 200 = Range ignored: skip to `start` and stop reading at `end`.
    final skip = status == 200 ? start : 0;
    final wantLen = end - start + 1;
    final out = BytesBuilder(copy: false);
    var seen = 0;
    await for (final chunk in resp.stream) {
      var c = chunk;
      if (seen < skip) {
        final drop = math.min(skip - seen, c.length);
        seen += drop;
        c = c.sublist(drop);
        if (c.isEmpty) continue;
      }
      final room = wantLen - out.length;
      out.add(c.length > room ? c.sublist(0, room) : c);
      if (out.length >= wantLen) break;
    }
    return (bytes: out.toBytes(), total: total ?? (status == 200 ? int.tryParse(resp.headers['content-length'] ?? '') : null));
  }

  // ---- transport --------------------------------------------------------------

  Future<({Object? json, Map<String, String> headers})> _getJson(
    Uri url, {
    String? repo,
    bool unauthorizedIsMissingRepo = true,
  }) async {
    final resp = await _request('GET', url,
        repo: repo, headers: const {'accept': 'application/json'}, unauthorizedIsMissingRepo: unauthorizedIsMissingRepo);
    return (json: _decode(resp, url), headers: resp.headers);
  }

  Object? _decode(http.Response resp, Uri url) {
    try {
      return jsonDecode(resp.body);
    } on FormatException {
      throw HubProtocolException('invalid JSON', statusCode: resp.statusCode, url: url);
    }
  }

  /// Buffered request with error mapping.
  Future<http.Response> _request(
    String method,
    Uri url, {
    String? repo,
    Map<String, String> headers = const {},
    String? body,
    bool unauthorizedIsMissingRepo = true,
  }) async {
    final streamed = await _send(method, url, headers: headers, body: body);
    final http.Response resp;
    try {
      resp = await http.Response.fromStream(streamed).timeout(retryPolicy.bodyTimeout);
    } on TimeoutException catch (e) {
      throw HubNetworkException('the response stalled for ${retryPolicy.bodyTimeout.inSeconds} s', cause: e, url: url);
    } on http.ClientException catch (e) {
      throw HubNetworkException(Redactor.text(e.message), cause: e, url: url);
    } on IOException catch (e) {
      throw HubNetworkException(Redactor.text('$e'), cause: e, url: url);
    }
    if (resp.statusCode >= 200 && resp.statusCode < 300) return resp;
    throw _error(resp.statusCode, resp.headers, resp.body, url,
        repo: repo, unauthorizedIsMissingRepo: unauthorizedIsMissingRepo);
  }

  /// One logical request with rate-limit waits, retries and auth scoping.
  Future<http.StreamedResponse> _send(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    String? body,
    bool followRedirects = true,
    bool attachToken = true,
  }) async {
    // Only Hub requests count against Hub buckets; CDN range reads do not
    // ("only the resolve hits the resolvers bucket", R08 §5.5 step 6).
    final bucket = _sameOrigin(url) ? bucketForPath(url.path).name : 'cdn';
    for (var attempt = 0;; attempt++) {
      final wait = rateLimiter.delayFor(bucket, _clock.now());
      if (wait > Duration.zero) {
        if (wait > retryPolicy.maxAutoWait) {
          throw HubRateLimitedException('rate limit for "$bucket" resets in ${wait.inSeconds} s',
              retryAfter: wait, bucket: bucket, url: url);
        }
        await _sleep(wait);
      }
      final req = http.Request(method, url)
        ..followRedirects = followRedirects
        ..headers['user-agent'] = userAgent
        ..headers.addAll(headers);
      // Never send the token off the Hub's origin (CDN, mirrors, redirects).
      if (attachToken && _sameOrigin(url) && _token != null) {
        final t = await _token();
        if (t != null && t.isNotEmpty) req.headers['authorization'] = 'Bearer $t';
      }
      if (body != null) req.body = body;

      http.StreamedResponse resp;
      try {
        resp = await _http.send(req).timeout(retryPolicy.requestTimeout);
      } on Object catch (e) {
        if (e is! TimeoutException && e is! http.ClientException && e is! IOException) rethrow;
        if (attempt < retryPolicy.maxRetries) {
          await _sleep(_backoff.delay(attempt));
          continue;
        }
        throw HubNetworkException(Redactor.text('$e'), cause: e, url: url);
      }
      final now = _clock.now();
      rateLimiter.observe(resp.headers, now);

      if (resp.statusCode == 429) {
        final text = await _readText(resp);
        final after = retryAfterFrom(resp.headers, text, now: now);
        if (after != null) rateLimiter.blockUntil(bucket, now.add(after));
        if (attempt < retryPolicy.maxRetries && (after == null || after <= retryPolicy.maxAutoWait)) {
          await _sleep(after ?? _backoff.delay(attempt));
          continue;
        }
        throw HubRateLimitedException(_message(resp.headers, text) ?? 'rate limited',
            retryAfter: after,
            bucket: bucket,
            statusCode: 429,
            errorCode: resp.headers['x-error-code'],
            requestId: resp.headers['x-request-id'],
            url: url);
      }
      if (const {408, 500, 502, 503, 504}.contains(resp.statusCode) && attempt < retryPolicy.maxRetries) {
        await resp.stream.drain<void>();
        await _sleep(_backoff.delay(attempt));
        continue;
      }
      return resp;
    }
  }

  Future<String> _readText(http.StreamedResponse resp, {int limit = 64 << 10}) async {
    final out = BytesBuilder(copy: false);
    await for (final c in resp.stream) {
      out.add(c);
      if (out.length >= limit) break;
    }
    return utf8.decode(out.toBytes(), allowMalformed: true);
  }

  String? _message(Map<String, String> headers, String body) {
    final h = headers['x-error-message'];
    if (h != null && h.isNotEmpty) return h;
    try {
      final j = jsonDecode(body);
      if (j is Map && j['error'] is String) return j['error'] as String;
    } on FormatException {
      // Plain-text body (`/resolve/`, the CDN).
    }
    final t = body.trim();
    return t.isEmpty ? null : (t.length > 300 ? '${t.substring(0, 300)}…' : t);
  }

  /// R08 §7.2 error matrix: `X-Error-Code` first, status second.
  HubException _error(
    int status,
    Map<String, String> headers,
    String body,
    Uri url, {
    String? repo,
    bool unauthorizedIsMissingRepo = true,
  }) {
    final code = headers['x-error-code'];
    final rid = headers['x-request-id'];
    final msg = _message(headers, body) ?? 'HTTP $status';
    switch (code) {
      case 'GatedRepo':
        return HubGatedRepoException(msg,
            repo: repo ?? '', statusCode: status, errorCode: code, requestId: rid, url: url);
      case 'EntryNotFound':
        return HubEntryNotFoundException(msg, statusCode: status, errorCode: code, requestId: rid, url: url);
      case 'RevisionNotFound':
        return HubRevisionNotFoundException(msg, statusCode: status, errorCode: code, requestId: rid, url: url);
      case 'RepoNotFound':
        return HubRepoNotFoundException(msg, statusCode: status, errorCode: code, requestId: rid, url: url);
    }
    final lower = msg.toLowerCase();
    return switch (status) {
      400 => HubBadRequestException(msg, statusCode: status, errorCode: code, requestId: rid, url: url),
      401 when unauthorizedIsMissingRepo && repo != null =>
        HubRepoNotFoundException(msg, statusCode: status, errorCode: code, requestId: rid, url: url),
      401 => HubUnauthorizedException(msg, statusCode: status, errorCode: code, requestId: rid, url: url),
      403 when lower.contains('expired') =>
        HubUrlExpiredException(msg, statusCode: status, errorCode: code, requestId: rid, url: url),
      403 when lower.contains('disabled') =>
        HubDisabledRepoException(msg, statusCode: status, errorCode: code, requestId: rid, url: url),
      403 => HubForbiddenException(msg, statusCode: status, errorCode: code, requestId: rid, url: url),
      404 => HubNotFoundException(msg, statusCode: status, errorCode: code, requestId: rid, url: url),
      >= 500 => HubServerException(msg, statusCode: status, errorCode: code, requestId: rid, url: url),
      _ => HubHttpException(msg, statusCode: status, errorCode: code, requestId: rid, url: url),
    };
  }

  bool _sameOrigin(Uri u) =>
      u.scheme == baseUri.scheme && u.host.toLowerCase() == baseUri.host.toLowerCase() && u.port == baseUri.port;

  void _checkRepo(String repo) {
    if (!_repoId.hasMatch(repo) || repo.contains('..')) throw ArgumentError.value(repo, 'repo', 'not a repo id');
  }

  void _checkPath(String path) {
    if (path.isEmpty || path.startsWith('/') || path.split('/').any((s) => s.isEmpty || s == '.' || s == '..')) {
      throw ArgumentError.value(path, 'path', 'not a repo-relative file path');
    }
  }

  static String? _unquote(String? v) {
    if (v == null) return null;
    var s = v.trim();
    if (s.startsWith('W/')) s = s.substring(2);
    if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) s = s.substring(1, s.length - 1);
    return s;
  }

  static int? _contentRangeTotal(String? v) {
    final m = RegExp(r'/(\d+)\s*$').firstMatch(v ?? '');
    return m == null ? null : int.parse(m.group(1)!);
  }
}
