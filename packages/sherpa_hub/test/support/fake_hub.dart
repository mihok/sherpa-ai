import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;

/// A request as the fake servers saw it.
final class SeenRequest {
  SeenRequest(this.method, this.uri, this.headers);

  final String method;
  final Uri uri;
  final Map<String, String> headers;

  String? get authorization => headers['authorization'];
}

/// A file the fake Hub can resolve and the fake CDN can serve.
final class FakeFile {
  FakeFile({required this.path, required this.size, this.sha256, this.xetHash, this.bytes, this.diskPath, this.lfs = true});

  final String path;
  final int size;
  final String? sha256;
  final String? xetHash;

  /// In-memory content (small files) or a file on disk served by range.
  final Uint8List? bytes;
  final String? diskPath;
  final bool lfs;

  Uint8List read(int start, int endInclusive) {
    final b = bytes;
    if (b != null) return Uint8List.sublistView(b, start, endInclusive + 1);
    final raf = File(diskPath!).openSync();
    try {
      raf.setPositionSync(start);
      return raf.readSync(endInclusive - start + 1);
    } finally {
      raf.closeSync();
    }
  }
}

/// Fake huggingface.co + a CDN on a *different origin*, reproducing the
/// live response shapes from R08 (§2.3 Link pagination, §5.1 302 + X-Linked-*
/// headers, §5.2 Range/206/416 and ignored If-Range, §5.3 307 to
/// resolve-cache, §6 rate-limit headers and the `retryAfter` body, §7.2
/// GatedRepo/EntryNotFound/RevisionNotFound, expired-URL 403).
final class FakeHub {
  FakeHub._(this._hub, this._cdn);

  static Future<FakeHub> start() async {
    late FakeHub fake;
    final hub = await io.serve((Request r) => fake._hubHandler(r), InternetAddress.loopbackIPv4, 0);
    final cdn = await io.serve((Request r) => fake._cdnHandler(r), InternetAddress.loopbackIPv4, 0);
    fake = FakeHub._(hub, cdn);
    return fake;
  }

  final HttpServer _hub;
  final HttpServer _cdn;

  Uri get hubUri => Uri.parse('http://127.0.0.1:${_hub.port}');
  Uri get cdnUri => Uri.parse('http://127.0.0.1:${_cdn.port}');

  final List<SeenRequest> hubRequests = [];
  final List<SeenRequest> cdnRequests = [];

  static const commit = '067b946cf014b7c697f3654f621d577a3e3afd1c';
  static const goodToken = 'hf_testTokenAbcdefghijklmnopqrstuv';

  /// repo → files.
  final Map<String, List<FakeFile>> repos = {};

  /// Repos whose content needs a token (`gated: auto`).
  final Set<String> gated = {};

  /// Per-path count of 429s to send before succeeding, and the body's `retryAfter`.
  final Map<String, int> throttle = {};
  int throttleRetryAfter = 1;

  /// Per-path count of 503s to send before succeeding.
  final Map<String, int> flaky = {};

  /// Paths whose next resolve hands out an already-expired signed URL.
  final Set<String> expireNext = {};

  /// CDN paths (xet hashes) that ignore Range and answer 200.
  final Set<String> ignoreRange = {};

  /// Every Hub response carries these remaining/reset values.
  int apiRemaining = 425;
  int apiReset = 157;
  String? redirectOverride;

  List<Map<String, Object?>> treeEntries = const [];
  int treePageSize = 7;
  Object? modelInfo;
  Object? page1;
  Object? page2;

  Future<void> close() async {
    await _hub.close(force: true);
    await _cdn.close(force: true);
  }

  Map<String, String> get _rl => {
        'ratelimit': '"api";r=$apiRemaining;t=$apiReset',
        'ratelimit-policy': '"fixed window";"api";q=500;w=300',
        'x-request-id': 'Root=1-fake',
      };

  Response _json(Object? body, {int status = 200, Map<String, String> headers = const {}}) =>
      Response(status, body: jsonEncode(body), headers: {'content-type': 'application/json', ..._rl, ...headers});

  Response _error(int status, String code, String message, {bool json = true}) => Response(status,
      body: json ? jsonEncode({'error': message}) : message,
      headers: {
        'content-type': json ? 'application/json' : 'text/plain',
        'x-error-code': code,
        'x-error-message': message,
        ..._rl,
      });

  FutureOr<Response> _hubHandler(Request r) {
    hubRequests.add(SeenRequest(r.method, r.requestedUri, Map.of(r.headers)));
    final path = r.requestedUri.path;
    final n = throttle[path];
    if (n != null && n > 0) {
      throttle[path] = n - 1;
      return Response(429,
          body: jsonEncode({
            'error': 'We had to rate limit your IP (x.x.x.x). To continue using our service, create a HF account '
                'or login to your existing account, and make sure you pass a HF_TOKEN if you are using the API.',
            'retryAfter': throttleRetryAfter,
          }),
          headers: {'content-type': 'application/json', 'ratelimit': '"api";r=0;t=$throttleRetryAfter'});
    }
    final f = flaky[path];
    if (f != null && f > 0) {
      flaky[path] = f - 1;
      return Response(503, body: 'upstream unavailable');
    }

    if (path == '/api/models') return _models(r);
    if (path == '/api/whoami-v2') {
      if (r.headers['authorization'] != 'Bearer $goodToken') {
        return _json({'error': 'Invalid username or password.'}, status: 401);
      }
      return _json({
        'type': 'user',
        'name': 'sherpa-tester',
        'fullname': 'Sherpa Tester',
        'isPro': false,
        'orgs': [
          {'name': 'sherpa-org'},
        ],
        'auth': {
          'type': 'access_token',
          'accessToken': {'displayName': 'sherpa', 'role': 'fineGrained'},
        },
      });
    }
    final m = RegExp(r'^/api/models/([^/]+/[^/]+)(.*)$').firstMatch(path);
    if (m != null) return _api(r, m.group(1)!, m.group(2)!);
    final res = RegExp(r'^/([^/]+/[^/]+)/resolve/([^/]+)/(.+)$').firstMatch(path);
    if (res != null) return _resolve(r, res.group(1)!, Uri.decodeComponent(res.group(2)!), res.group(3)!);
    final cache = RegExp(r'^/api/resolve-cache/models/([^/]+/[^/]+)/([^/]+)/(.+)$').firstMatch(path);
    if (cache != null) return _serveSmall(r, cache.group(1)!, cache.group(3)!);
    return Response.notFound('not found');
  }

  Response _models(Request r) {
    final q = r.requestedUri.queryParametersAll;
    if (q.containsKey('library')) return _json({'error': 'library is ignored by the real Hub; tests must use filter'}, status: 418);
    final cursor = q['cursor']?.single;
    if (cursor == 'garbage') return _json({'error': 'Error parsing pagination cursor'}, status: 400);
    final dir = q['direction']?.single;
    final sort = q['sort']?.single ?? 'trendingScore';
    if (dir == '1' && sort != 'createdAt') {
      return _json({'error': 'Invalid sort direction, only descending sort is supported for $sort'}, status: 400);
    }
    final author = q['author']?.single;
    if (author != null) {
      final all = [...(page1! as List), ...(page2! as List)].cast<Map<String, Object?>>();
      final mine = all.where((m) => m['author'] == author).toList();
      if (cursor == null && mine.length > 1) {
        final next = r.requestedUri.replace(queryParameters: {...r.requestedUri.queryParametersAll, 'cursor': '$author-2'});
        return _json(mine.take(1).toList(), headers: {'link': '<$next>; rel="next"'});
      }
      return _json(cursor == null ? mine : mine.skip(1).toList());
    }
    if (cursor == null) {
      // Real Link shape: absolute URL, comma-separated filters, opaque cursor.
      final next = '${hubUri.replace(path: '/api/models')}?filter=gguf,conversational&sort=$sort&limit=2&cursor=eyIkb3IiOlt7ImRvd25sb2Fkcy4uLiJ9XX0%3D';
      return _json(page1, headers: {'link': '<$next>; rel="next"'});
    }
    return _json(page2);
  }

  FutureOr<Response> _api(Request r, String repo, String rest) async {
    if (rest.startsWith('/revision/nope')) return _error(404, 'RevisionNotFound', 'Invalid rev id: nope-branch');
    if (repo == 'nobody/missing') return _json({'error': 'Invalid username or password.'}, status: 401);
    if (rest.isEmpty || rest.startsWith('/revision/')) return _json(modelInfo);
    if (rest.startsWith('/tree/')) {
      final start = int.tryParse(r.requestedUri.queryParameters['cursor'] ?? '0') ?? 0;
      final end = min(start + treePageSize, treeEntries.length);
      final headers = <String, String>{};
      if (end < treeEntries.length) {
        final next = r.requestedUri.replace(queryParameters: {...r.requestedUri.queryParameters, 'cursor': '$end'});
        headers['link'] = '<$next>; rel="next"';
      }
      return _json(treeEntries.sublist(start, end), headers: headers);
    }
    if (rest.startsWith('/paths-info/')) {
      final body = await r.readAsString();
      final paths = ((jsonDecode(body) as Map)['paths'] as List).cast<String>().toSet();
      return _json([for (final e in treeEntries) if (paths.contains(e['path'])) e]);
    }
    return Response.notFound('');
  }

  FutureOr<Response> _resolve(Request r, String repo, String rev, String path) {
    final files = repos[repo];
    if (files == null) return _json({'error': 'Invalid username or password.'}, status: 401);
    if (gated.contains(repo) && r.headers['authorization'] != 'Bearer $goodToken') {
      return _error(401, 'GatedRepo',
          'Access to model $repo is restricted. You must have access to it and be authenticated to access it. Please log in.',
          json: false);
    }
    if (rev == 'nope-branch') return _error(404, 'RevisionNotFound', 'Invalid rev id: nope-branch', json: false);
    final file = files.where((f) => f.path == path).firstOrNull;
    if (file == null) return _error(404, 'EntryNotFound', 'Entry not found', json: false);
    if (redirectOverride != null) return Response(302, headers: {'location': redirectOverride!});
    if (!file.lfs) {
      return Response(307, headers: {
        'location': '/api/resolve-cache/models/$repo/$commit/$path?%2F$repo=&etag=%22${file.xetHash ?? 'x'}%22',
        'x-repo-commit': commit,
        'x-linked-etag': '"${file.xetHash ?? 'x'}"',
        ..._rl,
      });
    }
    final expired = expireNext.remove(path);
    final exp = DateTime.now().toUtc().add(Duration(seconds: expired ? -60 : 3600)).millisecondsSinceEpoch ~/ 1000;
    final location = cdnUri.replace(
      path: '/xet-bridge-us/66f457ed2dc07e76a1bde8d6/${file.xetHash}',
      queryParameters: {
        'response-content-disposition': 'inline',
        'Expires': '$exp',
        'Policy': 'eyJTdGF0ZW1lbnQiOltdfQ__',
        'Signature': 'c2lnbmF0dXJl',
        'Key-Pair-Id': 'K24J24Z295AEI9',
      },
    );
    return Response(302, body: 'Found. Redirecting to $location', headers: {
      'location': '$location',
      'x-repo-commit': commit,
      'accept-ranges': 'bytes',
      'x-linked-size': '${file.size}',
      'x-linked-etag': '"${file.sha256}"',
      'x-xet-hash': '${file.xetHash}',
      'cache-control': 'no-store',
      'ratelimit': '"resolvers";r=2993;t=279',
      'ratelimit-policy': '"fixed window";"resolvers";q=3000;w=300',
    });
  }

  Response _serveSmall(Request r, String repo, String path) {
    final f = repos[repo]!.firstWhere((f) => f.path == path);
    return Response.ok(f.bytes, headers: {'content-type': 'application/octet-stream', 'etag': '"${f.xetHash}"'});
  }

  Response _cdnHandler(Request r) {
    cdnRequests.add(SeenRequest(r.method, r.requestedUri, Map.of(r.headers)));
    final exp = int.tryParse(r.requestedUri.queryParameters['Expires'] ?? '');
    if (exp == null || exp * 1000 < DateTime.now().millisecondsSinceEpoch) {
      return Response.forbidden('Auth failed: credentials expired', headers: {'content-type': 'text/plain'});
    }
    final hash = r.requestedUri.pathSegments.last;
    final file = repos.values.expand((f) => f).where((f) => f.xetHash == hash).firstOrNull;
    if (file == null) return Response.notFound('');
    final etag = '"${file.xetHash}"';
    final range = r.headers['range'];
    // The real CDN ignores If-Range (R08 §0.9), so this fake does too.
    if (range == null || ignoreRange.contains(hash)) {
      return Response.ok(r.method == 'HEAD' ? null : file.read(0, file.size - 1),
          headers: {'etag': etag, 'accept-ranges': 'bytes', 'content-length': '${file.size}'});
    }
    final m = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range)!;
    final start = int.parse(m.group(1)!);
    if (start >= file.size) return Response(416, headers: {'content-range': 'bytes */${file.size}'});
    final end = min(m.group(2)!.isEmpty ? file.size - 1 : int.parse(m.group(2)!), file.size - 1);
    return Response(206, body: file.read(start, end), headers: {
      'etag': etag,
      'content-range': 'bytes $start-$end/${file.size}',
      'content-type': 'application/octet-stream',
      'x-hf-cdn-pop': 'fake-pop',
    });
  }
}
