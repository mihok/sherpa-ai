import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sherpa/services/device/device_profile_source.dart';
import 'package:sherpa/services/downloads/downloads.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_hub/sherpa_hub.dart';

import 'gguf_fixture.dart';

const testCommit = '067b946cf014b7c697f3654f621d577a3e3afd1c';
const hfToken = 'hf_testTokenAbcdefghijklmnopqrstuv';
final cdnBase = Uri.parse('https://us.aws.cdn.hf.co');

/// A file the fake Hub resolves and the fake CDN serves.
final class RemoteFile {
  RemoteFile(this.path, this.bytes, {String? xetHash, this.lfs = true})
      : sha256 = sha256Hex(bytes),
        xetHash = xetHash ?? 'xet${sha256Hex(bytes).substring(0, 40)}';

  /// Non-LFS files (configs) resolve with a 307 to `/api/resolve-cache` on
  /// huggingface.co itself and are identified by their git blob sha1.
  final bool lfs;

  String get gitSha1 => gitBlobSha1(bytes);

  final String path;
  Uint8List bytes;
  final String sha256;

  /// Mutable: tests change it to simulate the CDN serving other content.
  String xetHash;

  int get size => bytes.length;

  HubRepoFile get listing => lfs
      ? HubRepoFile(path: path, size: size, lfsSha256: sha256, lfsSize: size, xetHash: xetHash)
      : HubRepoFile(path: path, size: size, oid: gitSha1);
}

/// What the fake Hub saw.
final class HubCall {
  HubCall(this.method, this.url, this.authorization);

  final String method;
  final Uri url;
  final String? authorization;
}

/// huggingface.co for `HfHubClient`, reproducing R08 §5.1:
/// `HEAD /resolve/<rev>/<path>` answers 302 to a CloudFront-signed CDN URL on
/// another origin with `X-Linked-Size`, `X-Linked-ETag` (SHA-256),
/// `X-Xet-Hash` and `X-Repo-Commit`. Gated repos answer 401 `GatedRepo`
/// without the right token.
final class FakeHub {
  FakeHub(this.repo, List<RemoteFile> files) : files = {for (final f in files) f.path: f};

  final String repo;
  final Map<String, RemoteFile> files;
  final List<HubCall> calls = [];
  bool gated = false;
  String commit = testCommit;

  /// Seconds the signed URL is valid (3600 live).
  int urlLifetime = 3600;

  int resolvesOf(String path) => calls.where((c) => c.url.path.endsWith('/resolve/$commit/$path')).length;

  late final http.Client client = MockClient(_handle);

  HfHubClient hubClient({String? token}) => HfHubClient(
        httpClient: client,
        tokenProvider: () async => token,
        sleep: (_) async {},
      );

  Future<http.Response> _serveSmall(http.Request req, String path) async {
    if (gated && req.headers['authorization'] != 'Bearer $hfToken') {
      return http.Response('Access restricted', 401, headers: {'x-error-code': 'GatedRepo'});
    }
    final f = files[path];
    if (f == null) return http.Response('Entry not found', 404);
    final range = RegExp(r'^bytes=(\d+)-$').firstMatch(req.headers['range'] ?? '');
    if (range == null) return http.Response.bytes(f.bytes, 200, headers: {'etag': '"${f.gitSha1}"'});
    final start = int.parse(range.group(1)!);
    return http.Response.bytes(f.bytes.sublist(start), 206,
        headers: {'etag': '"${f.gitSha1}"', 'content-range': 'bytes $start-${f.size - 1}/${f.size}'});
  }

  RemoteFile? byXet(String hash) => files.values.where((f) => f.xetHash == hash).firstOrNull;

  Future<http.Response> _handle(http.Request req) async {
    calls.add(HubCall(req.method, req.url, req.headers['authorization']));
    final cache = RegExp(r'^/api/resolve-cache/models/([^/]+/[^/]+)/([^/]+)/(.+)$').firstMatch(req.url.path);
    if (cache != null) return _serveSmall(req, Uri.decodeComponent(cache.group(3)!));
    final m = RegExp(r'^/([^/]+/[^/]+)/resolve/([^/]+)/(.+)$').firstMatch(req.url.path);
    if (m == null || m.group(1) != repo) return http.Response('{"error":"Invalid username or password."}', 401);
    if (gated && req.headers['authorization'] != 'Bearer $hfToken') {
      return http.Response('Access restricted', 401, headers: {
        'x-error-code': 'GatedRepo',
        'x-error-message': 'Access to model $repo is restricted. You must have access to it and be authenticated.',
      });
    }
    final f = files[Uri.decodeComponent(m.group(3)!)];
    if (f == null) return http.Response('Entry not found', 404, headers: {'x-error-code': 'EntryNotFound'});
    if (!f.lfs) {
      // R08 §5.3: 307 to a relative resolve-cache URL on the Hub's origin.
      return http.Response('', 307, headers: {
        'location': '/api/resolve-cache/models/$repo/$commit/${f.path}?etag=%22${f.gitSha1}%22',
        'x-repo-commit': commit,
        'x-linked-etag': '"${f.gitSha1}"',
      });
    }
    final exp = DateTime.now().toUtc().add(Duration(seconds: urlLifetime)).millisecondsSinceEpoch ~/ 1000;
    final location = cdnBase.replace(
      path: '/xet-bridge-us/66f457ed2dc07e76a1bde8d6/${f.xetHash}',
      queryParameters: {'Expires': '$exp', 'Policy': 'eyJ9', 'Signature': 'c2lnbmF0dXJl', 'Key-Pair-Id': 'K24'},
    );
    return http.Response('', 302, headers: {
      'location': '$location',
      'x-repo-commit': commit,
      'x-linked-size': '${f.size}',
      'x-linked-etag': '"${f.sha256}"',
      'x-xet-hash': f.xetHash,
      'accept-ranges': 'bytes',
    });
  }
}

/// Scripted CDN behind [TransferBackend]: appends real bytes to the part
/// file in chunks, honours stop, and can expire / corrupt / hold.
final class FakeCdnBackend implements TransferBackend {
  FakeCdnBackend(this.hub, {this.chunkBytes = 256 << 10});

  final FakeHub hub;
  final int chunkBytes;
  final List<TransferRequest> requests = [];
  int active = 0;
  int maxActive = 0;
  bool recovered = false;

  /// Next request(s) answer 403 "credentials expired" after this many bytes.
  final List<int> expireAfter = [];

  /// Xet hashes whose bytes arrive with one flipped byte.
  final Set<String> corrupt = {};

  /// When set, transfers wait here after the first chunk until completed.
  Completer<void>? gate;

  /// Simulates the OS refusing metered networks for `requiresWiFi` tasks.
  bool osOnCellular = false;

  @override
  int get transientBytes => 0;

  @override
  Future<void> recover() async => recovered = true;

  @override
  TransferHandle start(TransferRequest request) {
    requests.add(request);
    final h = _FakeHandle();
    unawaited(_run(request, h));
    return h;
  }

  Future<void> _run(TransferRequest r, _FakeHandle h) async {
    active++;
    maxActive = max(maxActive, active);
    try {
      await Future<void>.delayed(Duration.zero);
      if (r.headers.containsKey('authorization') && r.url.host == cdnBase.host) {
        return h.finish(const TransferFailed('token leaked to the CDN'));
      }
      if (r.requiresWiFi && osOnCellular) return h.finish(const TransferWaitingForWifi());
      final hash = r.url.pathSegments.last;
      final file = hub.byXet(hash);
      if (file == null) return h.finish(const TransferHttpError(404));
      final exp = int.parse(r.url.queryParameters['Expires']!);
      if (exp * 1000 < DateTime.now().millisecondsSinceEpoch) {
        return h.finish(const TransferHttpError(403, message: 'Auth failed: credentials expired'));
      }
      final bytes = Uint8List.fromList(file.bytes);
      if (corrupt.contains(hash)) bytes[bytes.length ~/ 2] ^= 0xff;
      final expireAt = expireAfter.isEmpty ? null : expireAfter.removeAt(0);
      final out = File(r.partPath).openSync(mode: FileMode.append);
      var pos = r.offset;
      var sent = 0;
      var chunks = 0;
      try {
        while (pos < bytes.length) {
          if (h.stopped) return h.finish(const TransferStopped());
          if (expireAt != null && sent >= expireAt) {
            return h.finish(const TransferHttpError(403, message: 'Auth failed: credentials expired'));
          }
          final n = min(chunkBytes, bytes.length - pos);
          out.writeFromSync(bytes, pos, pos + n);
          out.flushSync();
          pos += n;
          sent += n;
          h.emit(TransferProgress(bytesOnDisk: pos));
          if (++chunks == 1 && gate != null) await Future.any([gate!.future, h.stopSignal.future]);
          await Future<void>.delayed(Duration.zero);
        }
      } finally {
        out.closeSync();
      }
      if (h.stopped) return h.finish(const TransferStopped());
      h.finish(TransferCompleted(etag: hash));
    } finally {
      active--;
    }
  }
}

final class _FakeHandle implements TransferHandle {
  final StreamController<TransferProgress> _p = StreamController.broadcast();
  final Completer<TransferOutcome> _done = Completer();
  final Completer<void> stopSignal = Completer();
  bool stopped = false;

  void emit(TransferProgress p) {
    if (!_p.isClosed) _p.add(p);
  }

  void finish(TransferOutcome o) {
    if (!_done.isCompleted) _done.complete(o);
    unawaited(_p.close());
  }

  @override
  Stream<TransferProgress> get progress => _p.stream;

  @override
  Future<TransferOutcome> get done => _done.future;

  @override
  Future<void> stop() async {
    stopped = true;
    if (!stopSignal.isCompleted) stopSignal.complete();
  }
}

/// Everything a manager test needs, over a real temp directory.
final class ManagerRig {
  ManagerRig._(this.dir, this.hub, this.store, this.backend, this.network, this.device, this.token);

  static Future<ManagerRig> create({
    required FakeHub hub,
    ModelRecordStore? store,
    int? freeStorageBytes = 64 << 30,
    NetworkKind network = NetworkKind.wifi,
    Directory? dir,
    String? token,
  }) async {
    final d = dir ?? await Directory.systemTemp.createTemp('sherpa_dl_');
    final device = FixedDeviceProfileSource(DeviceProfile(
      platform: DevicePlatform.android,
      totalRamBytes: 12 << 30,
      freeStorageBytes: freeStorageBytes,
    ));
    return ManagerRig._(d, hub, store ?? InMemoryRecordStore(), FakeCdnBackend(hub), FakeNetworkMonitor(network),
        device, token);
  }

  final Directory dir;
  final FakeHub hub;
  final ModelRecordStore store;
  final FakeCdnBackend backend;
  final FakeNetworkMonitor network;
  final FixedDeviceProfileSource device;
  final String? token;
  final SequentialIdGenerator ids = SequentialIdGenerator();
  late final ModelStorageLayout layout = ModelStorageLayout('${dir.path}/models');
  late final ModelLibrary library = ModelLibrary(store: store, layout: layout, ids: ids);
  late final DownloadManager manager = newManager();

  /// The only backend allowed to attach the token (huggingface.co only).
  late final InProcessTransferBackend hubBackend =
      InProcessTransferBackend(client: hub.client, token: () async => token, hubOrigin: HfHubClient.defaultBase);

  DownloadManager newManager({ModelLibrary? library}) => DownloadManager(
        store: store,
        layout: layout,
        backend: backend,
        hubBackend: hubBackend,
        resolver: HubDownloadResolver(hub.hubClient(token: token)),
        library: library ?? this.library,
        device: device,
        network: network,
        ids: ids,
        sleep: (_) async {},
        largeFileBytes: 1 << 20,
      );

  DownloadPlan plan({String? quant, bool? includeMmproj}) {
    final o = planDownload(
      repo: hub.repo,
      commit: hub.commit,
      files: [for (final f in hub.files.values) f.listing],
      quant: quant,
      includeMmproj: includeMmproj,
    );
    if (o is PlanRefused) throw StateError('plan refused: ${o.reasons}');
    return o as DownloadPlan;
  }

  /// Waits until [test] holds for the manager's jobs.
  Future<DownloadJobView> waitFor(String jobId, bool Function(DownloadJobView v) test,
      {Duration timeout = const Duration(seconds: 20)}) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final v = manager.job(jobId);
      if (v != null && test(v)) return v;
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('job $jobId: ${v?.phase} ${v?.error} ${v?.job.files.map((f) => f.state)}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  Future<void> dispose() async {
    await manager.dispose();
    if (dir.existsSync()) await dir.delete(recursive: true);
  }
}

/// A two-file GGUF repo: a model and a vision projector.
FakeHub tinyRepo({int modelBytes = 3 << 20, int mmprojBytes = 1 << 20}) => FakeHub('acme/Tiny-1B-GGUF', [
      RemoteFile('Tiny-1B-Q4_K_M.gguf', syntheticGguf(totalBytes: modelBytes)),
      RemoteFile('mmproj-Tiny-1B-F16.gguf', syntheticGguf(totalBytes: mmprojBytes, seed: 7, fileType: 1)),
    ]);
