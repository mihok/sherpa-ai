import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa/services/downloads/downloads.dart';
import 'package:sherpa_data/sherpa_data.dart';
import 'package:sherpa_hub/sherpa_hub.dart';

import '../support/fake_hub.dart';
import '../support/gguf_fixture.dart';

const meta = DownloadMeta(displayName: 'Tiny 1B', quant: 'Q4_K_M', recommendedContext: 4096, contextLength: 8192);

void main() {
  late ManagerRig rig;

  Future<ManagerRig> setUpRig({FakeHub? hub, int? free = 64 << 30, NetworkKind net = NetworkKind.wifi, String? token}) async {
    rig = await ManagerRig.create(hub: hub ?? tinyRepo(), freeStorageBytes: free, network: net, token: token);
    await rig.manager.init();
    return rig;
  }

  tearDown(() async => rig.dispose());

  Future<String> enqueue({DownloadPlan? plan}) async {
    final o = await rig.manager.enqueue(plan ?? rig.plan(), meta: meta);
    expect(o, isA<Enqueued>(), reason: o is EnqueueRefused ? o.reasons.join() : '$o');
    return (o as Enqueued).jobId;
  }

  List<String> partFiles() => Directory(rig.layout.partialDir).existsSync()
      ? [for (final f in Directory(rig.layout.partialDir).listSync()) f.path.split('/').last]
      : const [];

  /// A manager like the rig's, over [backend] instead of the rig's own
  /// (and [network], when given, instead of the rig's fake).
  Future<DownloadManager> managerOver(TransferBackend backend, {NetworkMonitor? network}) async {
    final m = DownloadManager(
      store: rig.store,
      layout: rig.layout,
      backend: backend,
      hubBackend: rig.hubBackend,
      resolver: HubDownloadResolver(rig.hub.hubClient()),
      library: rig.library,
      device: rig.device,
      network: network ?? rig.network,
      ids: rig.ids,
      sleep: (_) async {},
      largeFileBytes: 1 << 20,
    );
    // Before the rig's tearDown deletes the directory under it.
    addTearDown(m.dispose);
    await m.init();
    return m;
  }

  /// The manager has applied the stop: the transfer's end reaches the
  /// record a moment after the backend goes idle, and after the view
  /// already reads paused.
  bool settled(DownloadJobView v) => v.job.files.every((f) => f.state != DownloadState.downloading);

  Future<DownloadJobView> waitOn(DownloadManager m, String id, bool Function(DownloadJobView v) test) async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (true) {
      final v = m.job(id);
      if (v != null && test(v)) return v;
      if (DateTime.now().isAfter(deadline)) throw TimeoutException('job $id: ${v?.phase} ${v?.error}');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  test('happy path: resolve, transfer, verify SHA-256, install with sidecar paired', () async {
    await setUpRig(token: hfToken);
    final id = await enqueue();
    final v = await rig.waitFor(id, (v) => v.phase == JobPhase.done);

    final model = rig.library.byId(v.job.libraryModelId!)!;
    expect(model.repo, 'acme/Tiny-1B-GGUF');
    expect(model.revision, testCommit);
    expect(model.quant, 'Q4_K_M');
    expect(model.format, ModelFormat.gguf);
    expect(model.mmprojPath, endsWith('mmproj-Tiny-1B-F16.gguf'));
    expect(model.architecture, 'llama');
    expect(model.contextLength, 8192);
    expect(model.defaultContextLength, 4096);
    expect(model.toolUse, isTrue, reason: "from the file's own chat template");
    expect(model.files, hasLength(2));
    for (final f in model.files) {
      final remote = rig.hub.files[f.repoPath]!;
      expect(f.sha256, remote.sha256);
      expect(f.sizeBytes, remote.size);
      final onDisk = File(rig.layout.libraryPath(f.path));
      expect(sha256Hex(onDisk.readAsBytesSync()), remote.sha256);
    }
    expect(partFiles(), isEmpty, reason: 'temp files are moved, not copied');
    expect(rig.library.diskUsageBytes, rig.hub.files.values.fold<int>(0, (a, f) => a + f.size));

    // The token went to huggingface.co only, never to the CDN.
    expect(rig.hub.calls, everyElement(predicate<HubCall>((c) => c.authorization == 'Bearer $hfToken')));
    expect(rig.backend.requests.map((r) => r.url.host), everyElement('us.aws.cdn.hf.co'));
    expect(rig.backend.requests.map((r) => r.headers.keys), everyElement(isNot(contains('authorization'))));
    expect(rig.backend.requests.map((r) => r.headers['accept-encoding']), everyElement('identity'));
  });

  test('SHA-256 mismatch fails the file and deletes the temp file', () async {
    await setUpRig();
    rig.backend.corrupt.add(rig.hub.files['Tiny-1B-Q4_K_M.gguf']!.xetHash);
    final id = await enqueue();
    final v = await rig.waitFor(id, (v) => v.phase == JobPhase.failed);
    expect(v.error, contains("didn't match its SHA-256"));
    final failed = v.job.files.firstWhere((f) => f.path == 'Tiny-1B-Q4_K_M.gguf');
    expect(failed.state, DownloadState.failed);
    expect(File(rig.layout.partPath(failed.id)).existsSync(), isFalse);
    expect(File(rig.layout.libraryPath(failed.localPath)).existsSync(), isFalse);
    expect(rig.library.models, isEmpty);

    // Retry downloads it again from zero and installs.
    rig.backend.corrupt.clear();
    expect(await rig.manager.resume(id), isNull);
    await rig.waitFor(id, (v) => v.phase == JobPhase.done);
  });

  test('refuses a job that does not fit in free storage, and explains', () async {
    await setUpRig(free: 2 << 20);
    final o = await rig.manager.enqueue(rig.plan(), meta: meta);
    expect(o, isA<EnqueueRefused>());
    final refused = o as EnqueueRefused;
    expect(refused.storage!.verdict, StorageVerdict.insufficient);
    expect(refused.reasons.single, allOf(contains('Not enough free space'), contains('is free')));
    expect(rig.manager.jobs, isEmpty);
    expect(rig.backend.requests, isEmpty);
  });

  test('403 expiry mid-file: re-resolves and resumes with Range from the bytes on disk', () async {
    await setUpRig();
    rig.backend.expireAfter.add(1 << 20);
    final id = await enqueue();
    await rig.waitFor(id, (v) => v.phase == JobPhase.done);
    final model = rig.backend.requests.where((r) => r.url.path.endsWith(rig.hub.files['Tiny-1B-Q4_K_M.gguf']!.xetHash));
    expect(model, hasLength(2));
    expect(model.first.offset, 0);
    expect(model.last.offset, 1 << 20, reason: 'resumed, not restarted');
    expect(rig.hub.resolvesOf('Tiny-1B-Q4_K_M.gguf'), 2, reason: 'a fresh signed URL after the 403');
  });

  test('Xet hash changed between resolves: the partial file is discarded and the file restarts', () async {
    await setUpRig();
    final file = rig.hub.files['Tiny-1B-Q4_K_M.gguf']!;
    final gate = Completer<void>();
    rig.backend.gate = gate;
    final id = await enqueue();
    await rig.waitFor(id, (v) => v.phase == JobPhase.downloading && v.bytesDone > 0);
    await rig.manager.pause(id);
    await rig.waitFor(id, (v) => v.phase == JobPhase.paused && rig.backend.active == 0 && settled(v));
    final rec = rig.manager.job(id)!.job.files.firstWhere((f) => f.path == file.path);
    expect(File(rig.layout.partPath(rec.id)).lengthSync(), greaterThan(0));

    // Same commit, same SHA-256, but the CDN now serves it under another
    // content hash. If-Range is ignored by the CDN (R08 §0.9), so the only
    // safe answer is to discard the partial bytes.
    file.xetHash = 'xet-rechunked-0000000000000000000000000000';
    rig.backend.gate = null;
    await rig.manager.resume(id);
    final v = await rig.waitFor(id, (v) => v.phase == JobPhase.done);
    final reqs = rig.backend.requests.where((r) => r.url.pathSegments.last == file.xetHash).toList();
    expect(reqs.first.offset, 0, reason: 'restarted, not resumed');
    expect(v.job.notice, contains('Xet hash changed'));
    expect(sha256Hex(File(rig.layout.libraryPath(rec.localPath)).readAsBytesSync()), file.sha256);
  });

  test('pause keeps bytes on disk; resume continues from them', () async {
    await setUpRig();
    final gate = Completer<void>();
    rig.backend.gate = gate;
    final id = await enqueue();
    await rig.waitFor(id, (v) => v.phase == JobPhase.downloading && v.bytesDone > 0);
    final pausing = rig.manager.pause(id);
    gate.complete();
    await pausing;
    final paused = await rig.waitFor(id, (v) => v.phase == JobPhase.paused && rig.backend.active == 0 && settled(v));
    final rec = paused.job.files.firstWhere((f) => f.path == 'Tiny-1B-Q4_K_M.gguf');
    expect(rec.state, DownloadState.paused);
    final have = File(rig.layout.partPath(rec.id)).lengthSync();
    expect(have, greaterThan(0));
    expect(rec.bytesDownloaded, have);
    final started = rig.backend.requests.length;

    rig.backend.gate = null;
    await rig.manager.resume(id);
    await rig.waitFor(id, (v) => v.phase == JobPhase.done);
    final resumed = rig.backend.requests.skip(started).firstWhere((r) => r.id == rec.id);
    expect(resumed.offset, have);
  });

  test('pause reads as paused from the tap on, while the transfer is still winding down', () async {
    await setUpRig();
    rig.backend.gate = Completer<void>();
    final backend = _SlowStopBackend(rig.backend);
    final m = await managerOver(backend);
    final id = ((await m.enqueue(rig.plan(), meta: meta)) as Enqueued).jobId;
    await waitOn(m, id, (v) => v.phase == JobPhase.downloading && v.bytesDone > 0);
    final emitted = <JobPhase>[];
    final sub = m.changes.listen((jobs) => emitted.add(jobs.single.phase));
    final pausing = m.pause(id);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    // The plugin has not confirmed the stop yet; the screen already knows.
    expect(rig.backend.active, 1);
    expect(m.job(id)!.phase, JobPhase.paused);
    expect(emitted, isNotEmpty, reason: 'the list updates at the tap, not when the plugin answers');
    backend.stopConfirmed.complete();
    await pausing;
    await waitOn(m, id, (v) => rig.backend.active == 0 && settled(v));
    await sub.cancel();
    expect(emitted, everyElement(JobPhase.paused), reason: 'no flicker back to downloading');
    final rec = m.job(id)!.job.files.firstWhere((f) => f.path == 'Tiny-1B-Q4_K_M.gguf');
    expect(rec.state, DownloadState.paused);
    expect(rec.bytesDownloaded, File(rig.layout.partPath(rec.id)).lengthSync());

    rig.backend.gate = null;
    await m.resume(id);
    await waitOn(m, id, (v) => v.phase == JobPhase.done);
  });

  test('Wi-Fi only: waits on cellular, starts on Wi-Fi, stops again when Wi-Fi is lost', () async {
    await setUpRig(net: NetworkKind.cellular);
    final id = await enqueue();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(rig.manager.job(id)!.phase, JobPhase.waitingForWifi);
    expect(rig.backend.requests, isEmpty, reason: 'nothing transfers over mobile data');

    final gate = Completer<void>();
    rig.backend.gate = gate;
    rig.network.current = NetworkKind.wifi;
    await rig.waitFor(id, (v) => v.phase == JobPhase.downloading);
    expect(rig.backend.requests.first.requiresWiFi, isTrue, reason: 'the OS enforces it too');

    rig.network.current = NetworkKind.cellular;
    gate.complete();
    await rig.waitFor(id, (v) => v.phase == JobPhase.waitingForWifi && rig.backend.active == 0);
    final count = rig.backend.requests.length;

    rig.backend.gate = null;
    rig.network.current = NetworkKind.wifi;
    await rig.waitFor(id, (v) => v.phase == JobPhase.done);
    expect(rig.backend.requests.length, greaterThan(count));
  });

  test('"Download over cellular" for one job bypasses Wi-Fi only', () async {
    await setUpRig(net: NetworkKind.cellular);
    final id = await enqueue();
    await rig.manager.allowCellular(id);
    await rig.waitFor(id, (v) => v.phase == JobPhase.done);
    expect(rig.backend.requests.first.requiresWiFi, isFalse);
  });

  test('the OS holds a Wi-Fi-only transfer our monitor could not classify: it says so, and mobile data restarts it',
      () async {
    // VPN-only (or another link connectivity_plus can't name) on mobile data:
    // our monitor says "unknown", so the transfer starts and the OS holds it.
    await setUpRig(net: NetworkKind.unknown);
    rig.backend.osOnCellular = true;
    final id = await enqueue();
    final held = await rig.waitFor(id, (v) => v.phase == JobPhase.waitingForWifi && rig.backend.active == 0);
    expect(held.wifiOnly, isTrue, reason: 'the "Use mobile data" button shows for waitingForWifi');
    final count = rig.backend.requests.length;

    // "Use mobile data for this download" must not wait for a network change.
    await rig.manager.allowCellular(id);
    await rig.waitFor(id, (v) => v.phase == JobPhase.done);
    expect(rig.backend.requests.skip(count).first.requiresWiFi, isFalse);
  });

  test('the network monitor reports a VPN going on or off over Wi-Fi; a repeat is not a change', () async {
    // Android doesn't start a Wi-Fi-only transfer while a VPN carries the
    // traffic, so the manager has to hear when it goes off, although the
    // kind stays Wi-Fi.
    final links = StreamController<List<ConnectivityResult>>();
    final monitor = ConnectivityNetworkMonitor(links.stream);
    final seen = <NetworkKind>[];
    final sub = monitor.changes.listen(seen.add);
    for (final r in [
      [ConnectivityResult.wifi, ConnectivityResult.vpn],
      [ConnectivityResult.vpn, ConnectivityResult.wifi],
      [ConnectivityResult.wifi],
      [ConnectivityResult.wifi],
      [ConnectivityResult.wifi, ConnectivityResult.vpn],
      [ConnectivityResult.mobile],
    ]) {
      links.add(r);
      await pumpEventQueue();
    }
    expect(seen, [NetworkKind.wifi, NetworkKind.wifi, NetworkKind.wifi, NetworkKind.cellular]);
    expect(monitor.current, NetworkKind.cellular);
    await sub.cancel();
    await monitor.dispose();
    await links.close();

    // The first event states where things are: a change only when it
    // differs from what the monitor started with.
    final first = StreamController<List<ConnectivityResult>>();
    final quiet = ConnectivityNetworkMonitor(first.stream, initial: NetworkKind.wifi);
    final none = <NetworkKind>[];
    final sub2 = quiet.changes.listen(none.add);
    first.add([ConnectivityResult.wifi, ConnectivityResult.vpn]);
    await pumpEventQueue();
    expect(none, isEmpty);
    await sub2.cancel();
    await quiet.dispose();
    await first.close();
  });

  group('Android never starts a Wi-Fi-only transfer although the phone shows Wi-Fi', () {
    late _NotStartingBackend backend;
    late DownloadManager m;

    Future<String> heldJob({NetworkMonitor? network}) async {
      await setUpRig();
      backend = _NotStartingBackend(rig.backend);
      m = await managerOver(backend, network: network);
      final id = ((await m.enqueue(rig.plan(), meta: meta)) as Enqueued).jobId;
      final held = await waitOn(m, id, (v) => v.phase == JobPhase.waitingForWifi);
      // Not "you're off Wi-Fi": what Android is doing, and what helps.
      expect((network ?? rig.network).current, NetworkKind.wifi);
      expect(held.job.notice, DownloadManager.notStartedNotice);
      expect(
        held.job.notice,
        allOf(contains("hasn't started"), contains('may not count'), contains('VPN'), contains('use mobile data')),
        reason: 'what was seen, not a cause the check cannot know',
      );
      expect(held.job.notice, isNot(contains('because')));
      expect(held.job.notice, contains('goes on over mobile data if you leave Wi-Fi'),
          reason: 'the choice lasts for the rest of the download, so say so');
      expect(held.wifiOnly, isTrue, reason: 'the "Use mobile data" button shows for waitingForWifi');
      final doc = await rig.store.get(DocumentCollections.downloads, id);
      expect(DownloadJob.fromJson(doc!).notice, DownloadManager.notStartedNotice, reason: 'survives a relaunch');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(backend.requests, hasLength(1), reason: 'held until the network changes or the user acts, not retried in a loop');
      return id;
    }

    test('the job waits and says why; "use mobile data" runs it on this connection', () async {
      final id = await heldJob();
      await m.allowCellular(id);
      expect(m.job(id)!.job.notice, isNull, reason: 'the advice was taken');
      await waitOn(m, id, (v) => v.phase == JobPhase.done);
      expect(backend.requests.skip(1).first.requiresWiFi, isFalse);
    });

    test('turning the VPN off tries it again, though the phone stays on Wi-Fi; the notice goes', () async {
      // connectivity_plus as on a phone: `[wifi, vpn]` with the VPN on,
      // `[wifi]` once it is off. Both are Wi-Fi, so only the link changed.
      final links = StreamController<List<ConnectivityResult>>.broadcast();
      final network = ConnectivityNetworkMonitor(links.stream);
      addTearDown(() async {
        await network.dispose();
        await links.close();
      });
      links.add([ConnectivityResult.wifi, ConnectivityResult.vpn]);
      await pumpEventQueue();
      final id = await heldJob(network: network);
      backend.osWontStart = false;
      links.add([ConnectivityResult.wifi]);
      final v = await waitOn(m, id, (v) => v.phase == JobPhase.done);
      expect(v.job.notice, isNull);
      expect(backend.requests.skip(1).first.requiresWiFi, isTrue, reason: 'still Wi-Fi only');
    });

    test('turning Wi-Fi only off clears the notice and runs the held job', () async {
      final id = await heldJob();
      await m.setWifiOnly(false);
      expect(m.job(id)!.job.notice, isNull, reason: "it isn't a Wi-Fi-only download any more");
      await waitOn(m, id, (v) => v.phase == JobPhase.done);
      expect(backend.requests.skip(1).first.requiresWiFi, isFalse);
    });

    test('Wi-Fi only turned off while Android sits on the task: it runs at once, without the notice', () async {
      await setUpRig();
      backend = _NotStartingBackend(rig.backend);
      final release = Completer<void>();
      // The backend reports "not started" only after its grace; the user
      // turns Wi-Fi only off before that.
      backend.holdUntil = release.future;
      m = await managerOver(backend);
      final id = ((await m.enqueue(rig.plan(), meta: meta)) as Enqueued).jobId;
      while (backend.requests.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await m.setWifiOnly(false);
      release.complete();
      final v = await waitOn(m, id, (v) => v.phase == JobPhase.done);
      expect(v.job.notice, isNull);
      expect(backend.requests.first.requiresWiFi, isTrue);
      expect(backend.requests.skip(1).map((r) => r.requiresWiFi), everyElement(isFalse));
    });

    test('Pause then Resume tries it again on the same connection', () async {
      final id = await heldJob();
      await m.pause(id);
      expect(m.job(id)!.phase, JobPhase.paused);
      backend.osWontStart = false;
      expect(await m.resume(id), isNull);
      final v = await waitOn(m, id, (v) => v.phase == JobPhase.done);
      expect(v.job.notice, isNull);
      expect(backend.requests.skip(1).first.requiresWiFi, isTrue, reason: 'still Wi-Fi only');
    });
  });

  test('a failed start-up is not cached: the download explains it, and the next try works', () async {
    final store = _FlakyStore(failLists: 1);
    rig = await ManagerRig.create(hub: tinyRepo(), store: store);
    final first = await rig.manager.enqueue(rig.plan(), meta: meta);
    expect(first, isA<EnqueueRefused>());
    expect((first as EnqueueRefused).reasons.single, contains("couldn't open its downloads list"));
    expect(rig.reported.map((r) => r.$2), ['init']);

    final second = await rig.manager.enqueue(rig.plan(), meta: meta);
    expect(second, isA<Enqueued>());
    await rig.waitFor((second as Enqueued).jobId, (v) => v.phase == JobPhase.done);
  });

  test('every failed file is reported for diagnostics with a code, never just shown', () async {
    await setUpRig();
    rig.backend.corrupt.add(rig.hub.files['Tiny-1B-Q4_K_M.gguf']!.xetHash);
    final id = await enqueue();
    await rig.waitFor(id, (v) => v.phase == JobPhase.failed);
    expect(rig.reported.map((r) => r.$2), contains('verify_failed'));

    final hub = tinyRepo()..gated = true;
    await rig.dispose();
    await setUpRig(hub: hub);
    final gated = await enqueue();
    await rig.waitFor(gated, (v) => v.phase == JobPhase.failed);
    expect(rig.reported, isNotEmpty);
    for (final (error, code) in rig.reported) {
      expect(error, isA<HubGatedRepoException>());
      expect(code, startsWith('hub_gated'));
    }
  });

  test('one large file at a time', () async {
    final hub = FakeHub('acme/Two-GGUF', [
      RemoteFile('A-Q4_K_M.gguf', syntheticGguf(totalBytes: 2 << 20, seed: 1)),
      RemoteFile('B-Q4_K_M.gguf', syntheticGguf(totalBytes: 2 << 20, seed: 2)),
    ]);
    await setUpRig(hub: hub);
    final a = await enqueue(plan: rig.plan(quant: 'A-Q4_K_M'));
    final b = await enqueue(plan: rig.plan(quant: 'B-Q4_K_M'));
    await rig.waitFor(a, (v) => v.phase == JobPhase.done);
    await rig.waitFor(b, (v) => v.phase == JobPhase.done);
    expect(rig.backend.maxActive, 1);
  });

  test('cancel stops the transfer and deletes partial files', () async {
    await setUpRig();
    final gate = Completer<void>();
    rig.backend.gate = gate;
    final id = await enqueue();
    await rig.waitFor(id, (v) => v.bytesDone > 0);
    final cancelling = rig.manager.cancel(id);
    gate.complete();
    await cancelling;
    expect(rig.manager.job(id), isNull);
    expect(partFiles(), isEmpty);
    expect(await rig.store.get(DocumentCollections.downloads, id), isNull);
    expect(rig.library.models, isEmpty);
  });

  test('crash and relaunch: state survives without the signed URL, bytes are re-synced, the file resumes', () async {
    final db = SherpaDatabase.inMemory();
    addTearDown(db.close);
    final store = JsonDocumentRecordStore(JsonDocumentStore(db));
    rig = await ManagerRig.create(hub: tinyRepo(), store: store);
    await rig.manager.init();
    final gate = Completer<void>();
    rig.backend.gate = gate;
    final id = await enqueue();
    await rig.waitFor(id, (v) => v.phase == JobPhase.downloading && v.bytesDone > 0);

    // What reached the database mid-download.
    final doc = await store.get(DocumentCollections.downloads, id);
    final json = jsonEncode(doc);
    expect(json, isNot(contains('Signature')), reason: 'signed CDN URLs are credentials; memory only');
    expect(json, isNot(contains('resolvedUrl')));
    expect(json, isNot(contains('cdn.hf.co')));
    expect(DownloadJob.fromJson(doc!).files.first.state, DownloadState.downloading);

    // "Kill" the process: a new manager over the same store and disk, with
    // the old transfer never finishing.
    final rec = DownloadJob.fromJson(doc).files.first;
    final onDisk = File(rig.layout.partPath(rec.id)).lengthSync();
    final relaunched = rig.newManager(library: ModelLibrary(store: store, layout: rig.layout));
    rig.backend.gate = null;
    final started = rig.backend.requests.length;
    await relaunched.init();
    expect(rig.backend.recovered, isTrue);
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (relaunched.job(id)?.phase != JobPhase.done) {
      if (DateTime.now().isAfter(deadline)) fail('relaunched job never finished: ${relaunched.job(id)?.phase}');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final resumed = rig.backend.requests.skip(started).firstWhere((r) => r.id == rec.id);
    expect(resumed.offset, onDisk, reason: 'resumed from the .part file, not from zero');
    expect(resumed.offset, greaterThan(0));
    expect(rig.hub.resolvesOf(rec.path), 2, reason: 'relaunch re-resolves');
    await relaunched.dispose();
  });

  test('launch integrity check flags a model whose file vanished', () async {
    await setUpRig();
    final id = await enqueue();
    final v = await rig.waitFor(id, (v) => v.phase == JobPhase.done);
    final model = rig.library.byId(v.job.libraryModelId!)!;
    File(rig.layout.libraryPath(model.loadPath)).deleteSync();
    final library = ModelLibrary(store: rig.store, layout: rig.layout);
    await library.load();
    final changed = await library.verifyIntegrity();
    expect(changed.single.issue, LibraryIssue.missingFiles);
    expect(library.byId(model.id)!.usable, isFalse);
  });

  test('a corrupt installed file is caught by the optional re-hash', () async {
    await setUpRig();
    final id = await enqueue();
    final v = await rig.waitFor(id, (v) => v.phase == JobPhase.done);
    final model = rig.library.byId(v.job.libraryModelId!)!;
    final f = File(rig.layout.libraryPath(model.loadPath));
    final bytes = f.readAsBytesSync();
    bytes[bytes.length - 1] ^= 0x01;
    f.writeAsBytesSync(bytes);
    expect(await rig.library.verifyIntegrity(), isEmpty, reason: 'same size: the cheap check passes');
    final changed = await rig.library.verifyIntegrity(rehash: true);
    expect(changed.single.issue, LibraryIssue.hashMismatch);
  });

  test('gated repo without a token fails with what to do', () async {
    final hub = tinyRepo()..gated = true;
    await setUpRig(hub: hub);
    final id = await enqueue();
    final v = await rig.waitFor(id, (v) => v.phase == JobPhase.failed);
    expect(v.error, allOf(contains('gated'), contains('Hugging Face token')));
    // Onboarding shows this error too: no Settings there yet, and its
    // button reads "Try again". The model's page has Add token in both.
    expect(v.error, allOf(contains('huggingface.co/acme/Tiny-1B-GGUF'), contains("Add token on the model's page"),
        contains('try again')));
    expect(v.error, isNot(anyOf(contains('Settings'), contains('Retry'))));
    expect(rig.backend.requests, isEmpty);
  });

  test('refuses unsafe files even when handed a plan directly', () async {
    await setUpRig();
    final good = rig.plan();
    final unsafe = DownloadPlan(
      repo: good.repo,
      commit: good.commit,
      variant: good.variant,
      files: [
        const PlannedFile(path: 'pytorch_model.bin', role: FileRole.model, sizeBytes: 10, sha256: 'ab'),
      ],
      totalBytes: 10,
      tempBytes: 0,
    );
    final o = await rig.manager.enqueue(unsafe, meta: meta);
    expect(o, isA<EnqueueRefused>());
    expect((o as EnqueueRefused).reasons.single, contains('pickle'));
    expect(rig.manager.jobs, isEmpty);
  });

  test('the same variant twice is not queued twice', () async {
    await setUpRig();
    final gate = Completer<void>();
    rig.backend.gate = gate;
    final id = await enqueue();
    final again = await rig.manager.enqueue(rig.plan(), meta: meta);
    expect(again, isA<AlreadyPresent>());
    expect((again as AlreadyPresent).jobId, id);
    gate.complete();
    await rig.waitFor(id, (v) => v.phase == JobPhase.done);
    final installed = await rig.manager.enqueue(rig.plan(), meta: meta);
    expect((installed as AlreadyPresent).libraryModelId, isNotNull);
  });

  test('the HF token never reaches the background backend; Hub-origin files are fetched in-process', () async {
    // An MLX repo: LFS weights (signed CDN URL) + non-LFS configs that the
    // Hub serves from /api/resolve-cache on its own origin (R08 §5.3).
    final hub = FakeHub('mlx-community/Qwen3-0.6B-4bit', [
      RemoteFile('model.safetensors', syntheticGguf(totalBytes: 2 << 20, seed: 3)),
      RemoteFile('config.json', Uint8List.fromList(utf8.encode('{"model_type":"qwen3","quantization":{"bits":4}}')), lfs: false),
      RemoteFile('tokenizer_config.json', Uint8List.fromList(utf8.encode('{"chat_template":"{{ tools }}"}')), lfs: false),
    ])
      ..gated = true;
    await setUpRig(hub: hub, token: hfToken);
    final plan = rig.plan();
    expect(plan.files.where((f) => f.gitBlobSha1 != null), hasLength(2), reason: 'configs verify by git blob sha1');
    final id = await enqueue(plan: plan);
    final v = await rig.waitFor(id, (v) => v.phase == JobPhase.done || v.phase == JobPhase.failed);
    expect(v.phase, JobPhase.done, reason: v.error);

    // The background backend saw the CDN weights only, and no credential.
    expect(rig.backend.requests, isNotEmpty);
    for (final r in rig.backend.requests) {
      expect(r.hubOrigin, isFalse);
      expect(r.url.host, 'us.aws.cdn.hf.co');
      expect(r.headers.keys.map((k) => k.toLowerCase()), isNot(contains('authorization')));
    }
    expect(rig.backend.requests.map((r) => r.id).toSet(), hasLength(1));

    // The configs came from huggingface.co with the token, in-process.
    final cacheCalls = rig.hub.calls.where((c) => c.url.path.startsWith('/api/resolve-cache/')).toList();
    expect(cacheCalls, hasLength(2));
    expect(cacheCalls.map((c) => c.authorization), everyElement('Bearer $hfToken'));
    final model = rig.library.byId(v.job.libraryModelId!)!;
    expect(model.format, ModelFormat.mlx);
    final config = model.files.firstWhere((f) => f.path.endsWith('config.json') && !f.path.contains('tokenizer'));
    expect(File(rig.layout.libraryPath(config.path)).readAsStringSync(), contains('qwen3'));
  });

  test('transfer requests refuse credential headers, and the background backend refuses Hub-origin URLs', () async {
    await setUpRig();
    for (final h in ['authorization', 'Authorization', 'cookie', 'x-hf-token']) {
      expect(
        () => TransferRequest(id: 'x', url: cdnBase, partPath: '/tmp/x.part', offset: 0, expectedBytes: 1, headers: {h: 'v'}),
        throwsArgumentError,
        reason: h,
      );
    }
    final refused = BackgroundTransferBackend().start(TransferRequest(
      id: 'x',
      url: Uri.parse('https://huggingface.co/api/resolve-cache/models/a/b/c/config.json'),
      partPath: '${rig.dir.path}/x.part',
      offset: 0,
      expectedBytes: 10,
      hubOrigin: true,
    ));
    expect(await refused.done, isA<TransferFailed>());
  });

  test('delete removes the files and the record', () async {
    await setUpRig();
    final id = await enqueue();
    final v = await rig.waitFor(id, (v) => v.phase == JobPhase.done);
    final model = rig.library.byId(v.job.libraryModelId!)!;
    await rig.library.delete(model.id);
    expect(rig.library.models, isEmpty);
    for (final f in model.files) {
      expect(File(rig.layout.libraryPath(f.path)).existsSync(), isFalse);
    }
    expect(Directory(rig.layout.libraryPath(v.job.folder)).existsSync(), isFalse, reason: 'empty folders go too');
    expect(await rig.store.get(DocumentCollections.modelLibrary, model.id), isNull);
  });
}

/// A record store whose first [failLists] `list` calls throw, like a
/// database that is briefly unavailable at launch.
final class _FlakyStore implements ModelRecordStore {
  _FlakyStore({this.failLists = 1});

  final InMemoryRecordStore _inner = InMemoryRecordStore();
  int failLists;

  @override
  Future<Map<String, Object?>?> get(String collection, String id) => _inner.get(collection, id);

  @override
  Future<void> put(String collection, String id, Map<String, Object?> doc) => _inner.put(collection, id, doc);

  @override
  Future<void> delete(String collection, String id) => _inner.delete(collection, id);

  @override
  Future<List<Map<String, Object?>>> list(String collection) async {
    if (failLists > 0) {
      failLists--;
      throw StateError('database is locked');
    }
    return _inner.list(collection);
  }
}

/// [FakeCdnBackend] behind Android's Wi-Fi constraint: while [osWontStart]
/// is set, a Wi-Fi-only transfer ends the way [BackgroundTransferBackend]
/// reports a task Android never started.
final class _NotStartingBackend implements TransferBackend {
  _NotStartingBackend(this._inner);

  final FakeCdnBackend _inner;
  final List<TransferRequest> requests = [];
  bool osWontStart = true;

  /// When set, "not started" comes only once this completes (the
  /// backend's grace).
  Future<void>? holdUntil;

  @override
  int get transientBytes => _inner.transientBytes;

  @override
  Future<void> recover() => _inner.recover();

  @override
  TransferHandle start(TransferRequest request) {
    requests.add(request);
    if (request.requiresWiFi && osWontStart) {
      const outcome = TransferWaitingForWifi(notStarted: true);
      final hold = holdUntil;
      return hold == null ? const _Ended(outcome) : _Later(hold.then((_) => outcome));
    }
    return _inner.start(request);
  }
}

final class _Later implements TransferHandle {
  _Later(this.done);

  @override
  final Future<TransferOutcome> done;

  @override
  Stream<TransferProgress> get progress => const Stream.empty();

  @override
  Future<void> stop() async {}
}

final class _Ended implements TransferHandle {
  const _Ended(this.outcome);

  final TransferOutcome outcome;

  @override
  Stream<TransferProgress> get progress => const Stream.empty();

  @override
  Future<TransferOutcome> get done => Future.value(outcome);

  @override
  Future<void> stop() async {}
}

/// [FakeCdnBackend] whose stop takes a while to be confirmed, like the
/// plugin's: `stop` returns once [stopConfirmed] completes.
final class _SlowStopBackend implements TransferBackend {
  _SlowStopBackend(this._inner);

  final FakeCdnBackend _inner;
  final Completer<void> stopConfirmed = Completer();

  @override
  int get transientBytes => _inner.transientBytes;

  @override
  Future<void> recover() => _inner.recover();

  @override
  TransferHandle start(TransferRequest request) => _SlowStop(_inner.start(request), stopConfirmed.future);
}

final class _SlowStop implements TransferHandle {
  _SlowStop(this._inner, this._confirmed);

  final TransferHandle _inner;
  final Future<void> _confirmed;

  @override
  Stream<TransferProgress> get progress => _inner.progress;

  @override
  Future<TransferOutcome> get done => _inner.done;

  @override
  Future<void> stop() async {
    await _confirmed;
    await _inner.stop();
  }
}
