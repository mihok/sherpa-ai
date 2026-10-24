import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_data/sherpa_data.dart' show DocumentCollections;
import 'package:sherpa_hub/sherpa_hub.dart';
import 'package:sherpa_net/sherpa_net.dart' show Backoff;

import '../device/device_profile_source.dart';
import 'download_job.dart';
import 'download_resolver.dart';
import 'file_hasher.dart';
import 'model_library.dart';
import 'network_monitor.dart';
import 'record_store.dart';
import 'storage_layout.dart';
import 'transfer_backend.dart';

/// Downloads Hub models into the [ModelLibrary], one verified file at a
/// time, surviving app kills, 1-hour URL expiry and network changes.
///
/// Per file of a [DownloadPlan] (R08 §5.5, PLAN finding 9):
/// 1. **Resolve** the pinned commit's file (`HEAD /resolve/<sha>/<path>`,
///    redirects not followed, token sent to huggingface.co only).
/// 2. **Decide resume vs restart** with [DownloadRecord.decideResume]: the
///    CDN ignores `If-Range`, so bytes on disk are kept only when the fresh
///    `X-Xet-Hash`, SHA-256 and size match what produced them.
/// 3. **Transfer** the signed CDN URL with `Range: bytes=<have>-` into a
///    `.part` file through the [TransferBackend]. A `403` (expired
///    signature) → resolve again and continue from the bytes on disk.
///    The background backend never receives a token: CDN URLs need none,
///    and Hub-origin URLs (small non-LFS files that may be gated) go to the
///    in-process `hubBackend`, which attaches it itself — background tasks
///    are serialized into plugin/OS storage the Keychain promise excludes.
/// 4. **Verify** SHA-256 against `lfs.oid` on a background isolate (the
///    CDN ETag is a Xet hash, not SHA-256; background_downloader has no
///    checksums, R09 §6). Mismatch → the part is deleted and the file fails.
/// 5. **Install**: atomic rename into the library folder; when every file
///    of the job is verified, read the GGUF header and write the
///    [LibraryModel].
///
/// Policies:
/// - Storage is checked with [assessStorage] before a job is accepted and
///   again on resume; a job that cannot fit is refused with the reason.
/// - Wi-Fi only (default on, R12 §2 "Downloading multi-GB models over
///   cellular by default" is an anti-pattern): jobs wait on mobile data,
///   and a running transfer stops when the phone leaves Wi-Fi.
/// - At most one large file transfers at a time (bandwidth goes to the file
///   the user waits for, and peak temp storage stays one file).
/// - Every state change is persisted as a [DownloadJob] document; the signed
///   URL is not (it is a credential for an hour). A relaunch re-resolves.
final class DownloadManager {
  DownloadManager({
    required ModelRecordStore store,
    required this.layout,
    required TransferBackend backend,
    TransferBackend? hubBackend,
    required DownloadResolver resolver,
    required ModelLibrary library,
    required DeviceProfileSource device,
    NetworkMonitor? network,
    FileHasher hasher = const IsolateFileHasher(),
    Clock clock = const SystemClock(),
    IdGenerator? ids,
    Future<void> Function(Duration)? sleep,
    Backoff? backoff,
    this.largeFileBytes = 64 << 20,
    this.maxConcurrent = 2,
    this.maxResolvesWithoutProgress = 4,
    this.transientRetries = 3,
    this.maxRateLimitWait = const Duration(seconds: 60),
    this.persistInterval = const Duration(seconds: 2),
    void Function(Object error, String code)? onError,
  })  : _store = store,
        _onError = onError,
        _backend = backend,
        _hubBackend = hubBackend,
        _resolver = resolver,
        _library = library,
        _device = device,
        _network = network,
        _hasher = hasher,
        _clock = clock,
        _ids = ids ?? RandomIdGenerator(),
        _sleep = sleep ?? Future<void>.delayed,
        _backoff = backoff ?? Backoff(base: const Duration(seconds: 2), max: const Duration(seconds: 30));

  static const String collection = DocumentCollections.downloads;
  static const String _prefsCollection = DocumentCollections.preferences;

  final ModelRecordStore _store;
  final ModelStorageLayout layout;
  /// Moves signed-CDN bytes: background_downloader on devices. Never sees a
  /// token.
  final TransferBackend _backend;

  /// In-process transfers for URLs on huggingface.co itself (small non-LFS
  /// files via resolve-cache). The only path the Hub token can take
  /// (see [InProcessTransferBackend]); null → such files fail with a reason.
  final TransferBackend? _hubBackend;
  final DownloadResolver _resolver;
  final ModelLibrary _library;
  final DeviceProfileSource _device;
  final NetworkMonitor? _network;
  final FileHasher _hasher;
  final Clock _clock;
  final IdGenerator _ids;
  final Future<void> Function(Duration) _sleep;
  final Backoff _backoff;

  /// Where failures are reported for diagnostics (the app's error ring):
  /// the error (or a [DownloadFailure]) and a short code naming the step.
  /// The user-facing message stays on the job.
  final void Function(Object error, String code)? _onError;

  /// Files at least this big count as "large" for the one-at-a-time rule.
  final int largeFileBytes;

  /// Transfers running at once (one large + small config files).
  final int maxConcurrent;

  /// Consecutive 403/re-resolve rounds without new bytes before giving up
  /// (a clock far off, or a CDN that keeps refusing).
  final int maxResolvesWithoutProgress;

  /// Retries for connection drops and 5xx before a file is marked failed
  /// (the user can always Resume).
  final int transientRetries;
  final Duration maxRateLimitWait;
  final Duration persistInterval;

  final Map<String, DownloadJob> _jobs = {};
  final Map<String, _Active> _active = {};
  final Set<String> _installing = {};

  /// Jobs being cancelled: the scheduler must not start their next file
  /// while the running one winds down.
  final Set<String> _cancelling = {};

  /// Jobs the OS held for Wi-Fi although our monitor saw no reason; they
  /// wait for the next network change (a VPN going on or off counts) or
  /// the user's Resume instead of retrying in a loop.
  final Set<String> _osHeld = {};
  final StreamController<List<DownloadJobView>> _changes = StreamController.broadcast();
  final Map<String, Future<void>> _writes = {};
  StreamSubscription<NetworkKind>? _netSub;
  Future<void>? _init;
  bool _ready = false;
  bool _disposed = false;
  bool _wifiOnly = true;
  DateTime? _lastEmit;

  /// Snapshots, oldest job first.
  List<DownloadJobView> get jobs {
    final list = _jobs.values.toList()..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return [for (final j in list) _view(j)];
  }

  Stream<List<DownloadJobView>> get changes => _changes.stream;

  DownloadJobView? job(String id) {
    final j = _jobs[id];
    return j == null ? null : _view(j);
  }

  /// The job downloading [variantId] of [repo] at [commit], if any.
  DownloadJobView? jobFor({required String repo, required String commit, required String variantId}) {
    for (final j in _jobs.values) {
      if (j.repo == repo && j.commit == commit && j.variantId == variantId) return _view(j);
    }
    return null;
  }

  ModelLibrary get library => _library;

  /// Global "Download over Wi-Fi only" policy (default on).
  bool get wifiOnly => _wifiOnly;

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  /// Loads persisted jobs and repairs what a killed process left behind:
  /// - files caught mid-transfer or mid-verify go back to the queue (their
  ///   `.part` bytes are kept; the next resolve decides whether they are
  ///   still valid);
  /// - each record's byte count is re-synced with its `.part` length (the
  ///   database lags the file by up to [persistInterval]);
  /// - verified-but-vanished files are queued again;
  /// - `.part` files no job owns are deleted;
  /// - every installed model's files are checked for presence and size
  ///   (and SHA-256 with [rehashLibrary]).
  Future<void> init({bool rehashLibrary = false}) {
    // Once ready, hand out a fresh completed future rather than the original:
    // callers in another zone (UI isolates under test, background handlers)
    // must not depend on the zone the first call ran in.
    if (_ready) return Future<void>.value();
    return _init ??= _doInit(rehashLibrary).catchError((Object e, StackTrace s) {
      // Not cached: a transient failure (storage, the database) must not
      // refuse every later download until the app restarts.
      _init = null;
      _report(e, 'init');
      Error.throwWithStackTrace(e, s);
    });
  }

  /// Whether [init] has finished.
  bool get isReady => _ready;

  Future<void> _doInit(bool rehash) async {
    await layout.ensure();
    await _library.load();
    try {
      await _backend.recover();
    } on Object {
      // A plugin failure must not keep the library from opening.
    }
    final prefs = await _store.get(_prefsCollection, ModelPreferenceIds.models);
    _wifiOnly = prefs?.opt<bool>('wifiOnly') ?? true;

    for (final doc in await _store.list(collection)) {
      DownloadJob job;
      try {
        job = DownloadJob.fromJson(doc);
      } on Object {
        continue;
      }
      final repaired = await _repair(job);
      _jobs[job.id] = repaired;
      await _save(repaired.id);
    }
    await _deleteOrphans();
    await _library.verifyIntegrity(rehash: rehash);
    _netSub = _network?.changes.listen(_onNetwork);
    _ready = true;
    _emit(force: true);
    for (final j in _jobs.values.toList()) {
      if (!j.isInstalled && j.files.every((f) => f.state == DownloadState.done)) unawaited(_install(j.id));
    }
    _pump();
  }

  Future<DownloadJob> _repair(DownloadJob job) async {
    final now = _clock.now();
    final files = <DownloadRecord>[];
    for (var r in job.files) {
      if (r.state == DownloadState.done) {
        final f = File(layout.libraryPath(r.localPath));
        final joined = r.joinInto != null && File(layout.libraryPath(r.joinInto!)).existsSync();
        if (job.isInstalled || joined || (f.existsSync() && f.lengthSync() == r.expectedBytes)) {
          files.add(r);
        } else {
          files.add(_reset(r, now));
        }
        continue;
      }
      // Interrupted mid-flight: back to the queue, keeping the bytes.
      if (r.state == DownloadState.downloading) r = r.transition(DownloadState.resolving, at: now);
      if (r.state == DownloadState.resolving || r.state == DownloadState.verifying) {
        r = r.transition(DownloadState.queued, at: now);
      }
      if (r.state == DownloadState.paused && !job.userPaused) r = r.transition(DownloadState.queued, at: now);
      final part = File(layout.partPath(r.id));
      final have = part.existsSync() ? part.lengthSync() : 0;
      files.add(r.withProgress(have, at: now));
    }
    return job.copyWith(files: files, updatedAt: now);
  }

  /// A fresh queued copy (the state machine has no way out of `done`).
  DownloadRecord _reset(DownloadRecord r, DateTime now) {
    final j = persistableRecord(r)
      ..['state'] = DownloadState.queued.name
      ..['bytesDownloaded'] = 0
      ..remove('error')
      ..['updatedAt'] = now.toUtc().toIso8601String();
    return DownloadRecord.fromJson(j);
  }

  Future<void> _deleteOrphans() async {
    final known = {for (final j in _jobs.values) for (final f in j.files) '${f.id}.part'};
    final dir = Directory(layout.partialDir);
    if (!dir.existsSync()) return;
    await for (final e in dir.list()) {
      if (e is! File) continue;
      if (!known.contains(p.basename(e.path))) {
        try {
          await e.delete();
        } on FileSystemException {
          // Next launch.
        }
      }
    }
  }

  /// Stops transfers (keeping their bytes and records for the next launch)
  /// and flushes pending writes.
  Future<void> dispose() async {
    _disposed = true;
    await _netSub?.cancel();
    final running = [for (final a in _active.values) a.finished.future];
    for (final a in _active.values.toList()) {
      await _stop(a, _Stop.hold);
    }
    await Future.wait(running);
    await Future.wait(_writes.values.toList());
    await _changes.close();
  }

  // ---------------------------------------------------------------------------
  // Commands
  // ---------------------------------------------------------------------------

  /// Accepts a plan, or refuses it with reasons the UI can show as is.
  Future<EnqueueOutcome> enqueue(DownloadPlan plan, {required DownloadMeta meta}) async {
    try {
      await init();
    } on Object catch (e) {
      return EnqueueRefused([initFailureMessage(e)]);
    }
    // Defense in depth: the planner already refuses pickles, but the
    // manager never writes a file whose name fails the allowlist.
    final reasons = <String>[];
    for (final f in plan.files) {
      final s = FileSafety.check(HubRepoFile(path: f.path, size: f.sizeBytes, lfsSha256: f.sha256));
      if (!s.allowed) reasons.add(s.reason!);
      if (f.sha256 == null && f.gitBlobSha1 == null) reasons.add('${f.path} has no hash to verify against.');
    }
    if (reasons.isNotEmpty) return EnqueueRefused(reasons);

    final installed = _library.find(repo: plan.repo, revision: plan.commit, variantId: plan.variant.id);
    if (installed != null) return AlreadyPresent(libraryModelId: installed.id);
    for (final j in _jobs.values) {
      if (j.repo == plan.repo && j.commit == plan.commit && j.variantId == plan.variant.id && !j.isInstalled) {
        return AlreadyPresent(jobId: j.id);
      }
    }

    final device = await _device.current();
    final check = assessStorage(
      downloadBytes: plan.totalBytes,
      freeBytes: device.freeStorageBytes,
      tempBytes: plan.tempBytes + _backend.transientBytes,
    );
    if (check.verdict == StorageVerdict.insufficient) {
      return EnqueueRefused([
        'Not enough free space. ${check.message} Free up space or delete a model you no longer use, then try again.',
      ], storage: check);
    }

    final now = _clock.now();
    final records = plan.toRecords(now: now, ids: _ids);
    final job = DownloadJob(
      id: records.first.groupId,
      repo: plan.repo,
      commit: plan.commit,
      variantId: plan.variant.id,
      label: plan.variant.label,
      folder: plan.folder,
      loadPath: '${plan.folder}/${plan.variant.loadPath}',
      mmprojPath: plan.mmproj == null ? null : '${plan.folder}/${plan.mmproj!.path}',
      draftPath: plan.draft == null ? null : '${plan.folder}/${plan.draft!.path}',
      // The plan's variant is authoritative for the container format.
      meta: meta.withFormat(plan.variant.format == ModelFormat.ggufPart ? ModelFormat.gguf : plan.variant.format),
      files: records,
      tempBytes: plan.tempBytes,
      createdAt: now,
      updatedAt: now,
    );
    _jobs[job.id] = job;
    await _save(job.id);
    _emit(force: true);
    _pump();
    return Enqueued(job.id, warnings: [
      if (check.verdict == StorageVerdict.tight) check.message,
      if (check.verdict == StorageVerdict.unknown) 'Free space could not be checked on this device.',
      ...plan.warnings,
    ]);
  }

  /// Pauses every file of the job; stays paused across relaunches.
  Future<void> pause(String jobId) async {
    final job = _jobs[jobId];
    if (job == null || job.isInstalled) return;
    final now = _clock.now();
    _jobs[jobId] = job.copyWith(
      userPaused: true,
      updatedAt: now,
      files: [
        for (final f in job.files)
          f.state == DownloadState.queued && !_active.containsKey(f.id) ? f.transition(DownloadState.paused, at: now) : f,
      ],
    );
    final stops = <Future<void>>[];
    for (final f in job.files) {
      final a = _active[f.id];
      if (a != null && a.stop == null) stops.add(_stop(a, _Stop.pause));
    }
    // The view reads paused from here on (see [_view]); the transfers wind
    // down behind it.
    _emit(force: true);
    await Future.wait(stops);
    await _save(jobId);
    _emit(force: true);
  }

  /// Resumes a paused job, or retries a failed one from the bytes on disk.
  Future<String?> resume(String jobId) async {
    final job = _jobs[jobId];
    if (job == null || job.isInstalled) return null;
    final remaining = job.files.fold<int>(0, (a, f) => a + math.max(0, f.expectedBytes - f.bytesDownloaded));
    final device = await _device.current();
    final check = assessStorage(
      downloadBytes: remaining,
      freeBytes: device.freeStorageBytes,
      tempBytes: job.tempBytes + _backend.transientBytes,
    );
    if (check.verdict == StorageVerdict.insufficient) {
      return 'Not enough free space to continue. ${check.message}';
    }
    // Asked to try now: an OS hold waits for no network change.
    _osHeld.remove(jobId);
    final now = _clock.now();
    _jobs[jobId] = job.copyWith(
      userPaused: false,
      clearError: true,
      updatedAt: now,
      files: [
        for (final f in job.files)
          if (f.state == DownloadState.paused || f.state == DownloadState.failed)
            f.transition(DownloadState.queued, at: now)
          else
            f,
      ],
    );
    await _save(jobId);
    _emit(force: true);
    _pump();
    if (_jobs[jobId]!.files.every((f) => f.state == DownloadState.done)) unawaited(_install(jobId));
    return null;
  }

  /// Stops the job and deletes its partial and not-yet-installed files.
  /// For an installed job this only clears it from the list (the model
  /// stays in the library; delete it there).
  Future<void> cancel(String jobId) async {
    final job = _jobs[jobId];
    if (job == null) return;
    _cancelling.add(jobId);
    final running = <Future<void>>[];
    for (final f in job.files) {
      final a = _active[f.id];
      if (a != null) {
        running.add(a.finished.future);
        await _stop(a, _Stop.cancel);
      }
    }
    await Future.wait(running);
    _jobs.remove(jobId);
    _cancelling.remove(jobId);
    // Submitted after any pending put of this job, so it wins.
    await _store.delete(collection, jobId);
    if (!job.isInstalled) {
      for (final f in job.files) {
        await _deleteQuietly(layout.partPath(f.id));
        await _deleteQuietly(layout.libraryPath(f.localPath));
        if (f.joinInto != null) await _deleteQuietly(layout.libraryPath(f.joinInto!));
      }
      await _removeEmptyDirs(layout.libraryPath(job.folder));
    }
    _emit(force: true);
  }

  /// "Download over cellular anyway" for one job.
  Future<void> allowCellular(String jobId) async {
    final job = _jobs[jobId];
    if (job == null) return;
    // The OS held it for Wi-Fi; mobile data is now allowed, so try again
    // without waiting for the next network change.
    _osHeld.remove(jobId);
    _jobs[jobId] = job.copyWith(allowCellular: true, updatedAt: _clock.now(), clearNotice: job.notice == notStartedNotice);
    await _save(jobId);
    _emit(force: true);
    _pump();
  }

  /// Turns the global Wi-Fi-only policy on or off.
  Future<void> setWifiOnly(bool value) async {
    await init();
    _wifiOnly = value;
    if (!value) {
      // "Hasn't started this Wi-Fi-only download" no longer applies.
      for (final j in _jobs.values.where((j) => j.notice == notStartedNotice).toList()) {
        _jobs[j.id] = j.copyWith(clearNotice: true, updatedAt: _clock.now());
        await _save(j.id);
      }
    }
    final prefs = await _store.get(_prefsCollection, ModelPreferenceIds.models) ?? <String, Object?>{};
    await _store.put(_prefsCollection, ModelPreferenceIds.models, {...prefs, 'wifiOnly': value});
    _onNetwork(_network?.current ?? NetworkKind.unknown);
    _emit(force: true);
  }

  /// Removes finished jobs from the list (models stay installed).
  Future<void> clearFinished() async {
    for (final j in _jobs.values.where((j) => j.isInstalled).toList()) {
      _jobs.remove(j.id);
      await _store.delete(collection, j.id);
    }
    _emit(force: true);
  }

  // ---------------------------------------------------------------------------
  // Scheduling
  // ---------------------------------------------------------------------------

  bool _wifiRequired(DownloadJob j) => _wifiOnly && !j.allowCellular;

  bool _runnable(DownloadJob job, DownloadRecord r) =>
      r.state == DownloadState.queued || (r.state == DownloadState.paused && !job.userPaused);

  void _pump() {
    if (!_ready || _disposed) return;
    final net = _network?.current ?? NetworkKind.unknown;
    if (!net.isOnline) return;
    var running = _active.length;
    var large = _active.values.where((a) => a.large).length;
    final order = _jobs.values.toList()..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    for (final job in order) {
      if (job.userPaused || job.isInstalled || job.error != null) continue;
      if (_cancelling.contains(job.id) || (_osHeld.contains(job.id) && _wifiRequired(job))) continue;
      if (_wifiRequired(job) && net == NetworkKind.cellular) continue;
      for (final r in job.files) {
        if (running >= maxConcurrent) return;
        if (_active.containsKey(r.id) || !_runnable(job, r)) continue;
        final isLarge = r.expectedBytes >= largeFileBytes;
        if (isLarge && large > 0) continue;
        final a = _Active(job.id, large: isLarge);
        _active[r.id] = a;
        running++;
        if (isLarge) large++;
        unawaited(_runGuarded(job.id, r.id, a));
      }
    }
  }

  Future<void> _runGuarded(String jobId, String recordId, _Active a) async {
    try {
      await _runFile(jobId, recordId, a);
    } on Object catch (e) {
      // Programming errors (an illegal transition) must not wedge the queue.
      await _fail(jobId, recordId, 'Unexpected error: ${e.runtimeType}. Try again.', code: 'unexpected', cause: e);
    } finally {
      _active.remove(recordId);
      a.finished.complete();
      _emit(force: true);
      if (!_disposed) {
        final job = _jobs[jobId];
        if (job != null && !job.isInstalled && job.files.every((f) => f.state == DownloadState.done)) {
          unawaited(_install(jobId));
        }
        _pump();
      }
    }
  }

  void _onNetwork(NetworkKind kind) {
    if (_disposed) return;
    _osHeld.clear();
    for (final e in _active.entries.toList()) {
      final job = _jobs[e.value.jobId];
      if (job == null || e.value.stop != null) continue;
      if (!kind.isOnline || (kind == NetworkKind.cellular && _wifiRequired(job))) {
        unawaited(_stop(e.value, _Stop.hold));
      }
    }
    _emit(force: true);
    _pump();
  }

  Future<void> _stop(_Active a, _Stop reason) async {
    a.stop = reason;
    await a.handle?.stop();
  }

  // ---------------------------------------------------------------------------
  // One file
  // ---------------------------------------------------------------------------

  DownloadRecord? _rec(String jobId, String id) {
    final j = _jobs[jobId];
    if (j == null) return null;
    for (final f in j.files) {
      if (f.id == id) return f;
    }
    return null;
  }

  void _put(String jobId, DownloadRecord r) {
    final j = _jobs[jobId];
    if (j == null) return;
    _jobs[jobId] = j.withFile(r, at: _clock.now());
  }

  Future<void> _runFile(String jobId, String id, _Active a) async {
    var resolvesWithoutProgress = 0;
    var transient = 0;
    var restarts = 0;
    while (!_disposed) {
      var r = _rec(jobId, id);
      if (r == null || r.state == DownloadState.done || r.state == DownloadState.failed) return;
      if (a.stop != null) return _applyStop(jobId, id, a);
      final part = File(layout.partPath(id));
      var onDisk = part.existsSync() ? await part.length() : 0;
      if (r.state != DownloadState.resolving) r = r.transition(DownloadState.resolving, at: _clock.now());
      r = r.withProgress(onDisk, at: _clock.now());
      _put(jobId, r);
      _emit();

      ResolvedDownload? resolved;
      if (onDisk != r.expectedBytes) {
        try {
          resolved = await _resolver.resolve(r.repo, r.commit, r.path);
        } on HubRateLimitedException catch (e) {
          final wait = e.retryAfter ?? _backoff.delay(transient);
          if (transient++ < transientRetries && wait <= maxRateLimitWait) {
            await _sleep(wait);
            continue;
          }
          return _fail(jobId, id, 'Hugging Face is rate limiting downloads. Try again in a few minutes; '
              'signing in to Hugging Face raises the limit.', code: e.code, cause: e);
        } on HubException catch (e) {
          if (e.retryable && transient++ < transientRetries) {
            await _sleep(_backoff.delay(transient));
            continue;
          }
          return _fail(jobId, id, _hubMessage(e, r.repo), code: e.code, cause: e);
        }
        if (a.stop != null) return _applyStop(jobId, id, a);
        final problem = _identityProblem(r, resolved);
        if (problem != null) {
          await _deleteQuietly(part.path);
          return _fail(jobId, id, problem, code: 'identity_mismatch');
        }
        final (next, decision) = r.applyResolve(resolved, at: _clock.now());
        r = next;
        if (decision.restarts) {
          await _deleteQuietly(part.path);
          onDisk = 0;
          _note(jobId, 'Restarted ${p.basename(r.path)}: ${decision.reason}.');
        }
        _put(jobId, r);
        await _save(jobId);
      }

      if (r.bytesDownloaded < r.expectedBytes) {
        r = r.transition(DownloadState.downloading, at: _clock.now());
        _put(jobId, r);
        await _save(jobId);
        _emit(force: true);
        final before = r.bytesDownloaded;
        final outcome = await _transfer(jobId, r, resolved!, a);
        onDisk = part.existsSync() ? await part.length() : 0;
        r = _rec(jobId, id)!.withProgress(onDisk, at: _clock.now());
        _put(jobId, r);
        final progressed = onDisk > before;
        if (progressed) {
          resolvesWithoutProgress = 0;
          transient = 0;
        }
        switch (outcome) {
          case TransferCompleted(:final etag):
            final xet = resolved.xetHash;
            if (etag != null && xet != null && etag != xet && restarts++ < 2) {
              // The CDN served other content than the resolve promised.
              await _deleteQuietly(part.path);
              _note(jobId, 'Restarted ${p.basename(r.path)}: the CDN served different content.');
              _put(jobId, r.withProgress(0, at: _clock.now()).transition(DownloadState.resolving, at: _clock.now()));
              continue;
            }
            if (onDisk > r.expectedBytes) {
              await _deleteQuietly(part.path);
              if (restarts++ >= 2) {
                return _fail(jobId, id, 'The server sent more bytes than the file has.', code: 'overlong');
              }
              _put(jobId, r.withProgress(0, at: _clock.now()).transition(DownloadState.resolving, at: _clock.now()));
              continue;
            }
            if (onDisk < r.expectedBytes) {
              // Connection closed early: resume from what arrived.
              if (!progressed && ++resolvesWithoutProgress > maxResolvesWithoutProgress) {
                return _fail(jobId, id, 'The download keeps stopping early. Try again.', code: 'short_reads');
              }
              _put(jobId, r.transition(DownloadState.resolving, at: _clock.now()));
              continue;
            }
          case TransferStopped():
            return _applyStop(jobId, id, a);
          case TransferWaitingForWifi(:final notStarted):
            // Nothing told the user the phone is off Wi-Fi (it usually shows
            // Wi-Fi), so "Waiting for Wi-Fi" alone would read as a mistake:
            // say what Android is doing and what helps.
            // A job that stopped needing Wi-Fi while it waited (the setting
            // went off, or mobile data was allowed) is not held: the pump
            // runs it again right away, without the Wi-Fi constraint.
            final job = _jobs[jobId];
            final wifiRequired = job != null && _wifiRequired(job);
            if (notStarted && a.stop == null && wifiRequired) _note(jobId, notStartedNotice);
            a.stop ??= _Stop.hold;
            if (wifiRequired) _osHeld.add(jobId);
            return _applyStop(jobId, id, a);
          case TransferHttpError(:final statusCode) when statusCode == 416:
            if (onDisk < r.expectedBytes) {
              await _deleteQuietly(part.path);
              if (restarts++ >= 2) return _fail(jobId, id, 'The server refused the byte range.', code: 'http_416');
              _put(jobId, r.withProgress(0, at: _clock.now()).transition(DownloadState.resolving, at: _clock.now()));
              continue;
            }
          case TransferHttpError(:final statusCode) when resolved.sendAuthorization && (statusCode == 401 || statusCode == 403):
            // Hub origin, not a signed URL: this is access, not expiry.
            return _fail(jobId, id, _hubMessage(
                HubGatedRepoException('refused', repo: r.repo, statusCode: statusCode), r.repo),
                code: 'hub_origin_$statusCode');
          case final TransferHttpError e when e.isExpired:
            // R08 §5.2: "403 Auth failed: credentials expired" → re-resolve
            // and continue with Range from the bytes on disk.
            if (!progressed && ++resolvesWithoutProgress > maxResolvesWithoutProgress) {
              return _fail(jobId, id, 'The download link keeps expiring. Check the date and time on this device, '
                  'then try again.', code: 'url_expiry_loop');
            }
            _put(jobId, r.transition(DownloadState.resolving, at: _clock.now()));
            continue;
          case TransferHttpError(:final statusCode, :final message):
            if (statusCode >= 500 && transient++ < transientRetries) {
              await _sleep(_backoff.delay(transient));
              _put(jobId, r.transition(DownloadState.resolving, at: _clock.now()));
              continue;
            }
            return _fail(jobId, id, 'The download server answered HTTP $statusCode'
                '${message == null || message.isEmpty ? '' : ' (${message.trim()})'}. Try again.', code: 'http_$statusCode');
          case TransferNetworkError():
            final net = _network?.current ?? NetworkKind.unknown;
            if (!net.isOnline) {
              a.stop ??= _Stop.hold;
              return _applyStop(jobId, id, a);
            }
            if (transient++ < transientRetries) {
              await _sleep(_backoff.delay(transient));
              _put(jobId, _rec(jobId, id)!.transition(DownloadState.resolving, at: _clock.now()));
              continue;
            }
            return _fail(jobId, id, 'The connection keeps dropping. Your progress is saved; try again to continue.',
                code: 'connection_dropping');
          case TransferFailed(:final message):
            return _fail(jobId, id, message, code: 'transfer_failed');
        }
      } else {
        // Already complete on disk (relaunch after the last byte arrived).
        r = r.transition(DownloadState.downloading, at: _clock.now());
        _put(jobId, r);
      }

      // Verify and install this file.
      r = _rec(jobId, id)!.transition(DownloadState.verifying, at: _clock.now());
      _put(jobId, r);
      await _save(jobId);
      _emit(force: true);
      final verdict = await _verify(jobId, r, part.path, a);
      if (a.stop == _Stop.cancel) return;
      if (verdict != null) {
        await _deleteQuietly(part.path);
        return _fail(jobId, id, verdict, code: 'verify_failed');
      }
      final dest = layout.libraryPath(r.localPath);
      try {
        await Directory(p.dirname(dest)).create(recursive: true);
        // Same volume as the part file: rename is atomic, so the engine never
        // sees a half-moved model.
        await part.rename(dest);
      } on FileSystemException catch (e) {
        return _fail(jobId, id, 'Could not move the verified file into the library: ${e.osError?.message ?? e.message}.',
            code: 'install_move', cause: e);
      }
      _put(jobId, _rec(jobId, id)!.transition(DownloadState.done, at: _clock.now()));
      await _save(jobId);
      return;
    }
  }

  /// Checks a fresh resolve against the plan. The plan pinned a commit and
  /// read sizes/hashes from the same listing, so any difference means the
  /// URL is not for the bytes the user approved.
  String? _identityProblem(DownloadRecord r, ResolvedDownload d) {
    final commit = d.commit;
    if (commit != null && commit.isNotEmpty && commit != r.commit) {
      return 'The Hub served a different commit (${commit.substring(0, math.min(7, commit.length))}) than the one '
          'this download is pinned to.';
    }
    if (r.sha256 != null && d.sha256 != null && d.sha256 != r.sha256) {
      return 'The file at this commit has a different SHA-256 than planned.';
    }
    if (d.size != null && d.size != r.expectedBytes) {
      return 'The file is ${d.size} bytes, not the ${r.expectedBytes} the listing promised.';
    }
    return null;
  }

  Future<TransferOutcome> _transfer(String jobId, DownloadRecord r, ResolvedDownload d, _Active a) async {
    final job = _jobs[jobId]!;
    // Hub-origin URLs (resolve-cache) may need the token: in-process only.
    final viaHub = d.sendAuthorization;
    final backend = viaHub ? _hubBackend : _backend;
    if (backend == null) {
      return const TransferFailed('This file has to be fetched from huggingface.co directly, which this build '
          'cannot do.');
    }
    a
      ..bytes = r.bytesDownloaded
      ..meter = _SpeedMeter()
      ..lastPersist = _clock.now();
    final TransferHandle handle;
    try {
      handle = backend.start(TransferRequest(
        id: r.id,
        url: d.url,
        partPath: layout.partPath(r.id),
        offset: r.bytesDownloaded,
        expectedBytes: r.expectedBytes,
        headers: const {'accept-encoding': 'identity'},
        requiresWiFi: _wifiRequired(job),
        displayName: '${job.meta.displayName} ${job.label}',
        hubOrigin: viaHub,
      ));
    } on Object catch (e) {
      return TransferFailed('Could not start the download: ${e.runtimeType}.');
    }
    a.handle = handle;
    if (a.stop != null) unawaited(handle.stop());
    final sub = handle.progress.listen((p) => _onProgress(jobId, r.id, a, p));
    try {
      return await handle.done;
    } finally {
      await sub.cancel();
      a.handle = null;
    }
  }

  void _onProgress(String jobId, String id, _Active a, TransferProgress progress) {
    final now = _clock.now();
    // Bytes flow, so Android started it after all (another network, a VPN
    // turned off): the "hasn't started" notice no longer holds.
    final job = _jobs[jobId];
    if (job != null && job.notice == notStartedNotice && progress.bytesOnDisk > a.bytes) {
      _jobs[jobId] = job.copyWith(clearNotice: true, updatedAt: now);
    }
    a.bytes = progress.bytesOnDisk;
    a.meter?.add(progress.bytesOnDisk, now, reported: progress.bytesPerSecond);
    if (now.difference(a.lastPersist ?? now) >= persistInterval) {
      a.lastPersist = now;
      final r = _rec(jobId, id);
      if (r != null) {
        _put(jobId, r.withProgress(progress.bytesOnDisk, at: now));
        unawaited(_save(jobId));
      }
    }
    _emit();
  }

  /// Null when the file matches its hash; else the user-facing reason.
  Future<String?> _verify(String jobId, DownloadRecord r, String path, _Active a) async {
    a.verifyProgress = 0;
    try {
      final sha = r.sha256;
      if (sha != null) {
        final got = await _hasher.sha256(path, onProgress: (n) {
          a.verifyProgress = r.expectedBytes <= 0 ? 1 : n / r.expectedBytes;
          _emit();
        });
        if (got != sha.toLowerCase()) {
          return "${p.basename(r.path)} didn't match its SHA-256 (corrupted in transit or changed upstream). "
              'The partial file was deleted; try again to download it from the start.';
        }
        return null;
      }
      final blob = r.gitBlobSha1;
      if (blob != null) {
        final got = await gitBlobSha1OfFile(path);
        return got == blob ? null : "${p.basename(r.path)} didn't match its git hash. Try again.";
      }
      return '${p.basename(r.path)} has no hash to verify against.';
    } on FileSystemException catch (e) {
      return 'Could not read ${p.basename(r.path)} to verify it: ${e.message}.';
    } finally {
      a.verifyProgress = null;
    }
  }

  Future<void> _applyStop(String jobId, String id, _Active a) async {
    final reason = a.stop;
    if (reason == _Stop.cancel) return;
    final r = _rec(jobId, id);
    if (r == null) return;
    final part = File(layout.partPath(id));
    final have = part.existsSync() ? await part.length() : r.bytesDownloaded;
    var next = r.withProgress(have, at: _clock.now());
    if (next.state.canTransitionTo(DownloadState.paused)) next = next.transition(DownloadState.paused, at: _clock.now());
    _put(jobId, next);
    await _save(jobId);
  }

  Future<void> _fail(String jobId, String id, String message, {required String code, Object? cause}) async {
    _report(cause ?? DownloadFailure(code), code);
    final r = _rec(jobId, id);
    if (r == null) return;
    if (r.state.canTransitionTo(DownloadState.failed)) {
      _put(jobId, r.transition(DownloadState.failed, at: _clock.now(), error: message));
    }
    await _save(jobId);
    _emit(force: true);
  }

  void _report(Object error, String code) {
    try {
      _onError?.call(error, code);
    } on Object {
      // Diagnostics must never break a download.
    }
  }

  /// What the user reads when the manager cannot open its library or
  /// download records (the first step of every download).
  static String initFailureMessage(Object e) => switch (e) {
        FileSystemException(:final osError) when osError?.errorCode == 28 =>
          'This phone is out of storage, so Sherpa could not prepare its model folder. Free up space, then try again.',
        FileSystemException(:final osError) =>
          "Sherpa couldn't prepare its model folder (${osError?.message ?? 'file system error'}). "
              'Free up some space or restart Sherpa, then try again.',
        _ => "Sherpa couldn't open its downloads list (${e.runtimeType}). Try again; if it keeps happening, "
            'restart Sherpa and export diagnostics from Settings › About.',
      };

  /// Shown on a job whose Wi-Fi-only transfer the OS never started
  /// ([TransferWaitingForWifi.notStarted]). It must not say the phone is
  /// off Wi-Fi: the phone shows Wi-Fi. It says what was seen, not a cause
  /// it can't know, and what the mobile data option really does: it lasts
  /// for the rest of the download ([allowCellular]). Turning a VPN off is
  /// a network change, which tries the job again. Cleared when the user
  /// allows mobile data or bytes start to flow.
  static const String notStartedNotice = "Android hasn't started this Wi-Fi-only download. It may not count this "
      'connection as Wi-Fi; a VPN can cause this, and turning the VPN off lets the download start. Or use mobile '
      'data for this download: it starts now, and goes on over mobile data if you leave Wi-Fi.';

  void _note(String jobId, String notice) {
    final j = _jobs[jobId];
    if (j != null) _jobs[jobId] = j.copyWith(notice: notice, updatedAt: _clock.now());
  }

  /// The job's error for a Hub refusal. Onboarding shows it too, where
  /// Settings can't be opened yet and the button reads "Try again", so it
  /// names neither: a gated model's own page has Add token in both places
  /// (as `downloadStartMessage` says).
  String _hubMessage(HubException e, String repo) => switch (e) {
        HubGatedRepoException(:final needsSignIn) => needsSignIn
            ? 'This model is gated. Accept its terms at huggingface.co/$repo and use a Hugging Face token that can '
                "read gated models (Add token on the model's page; if you added one already, replace it on the "
                'Hugging Face account screen), then try again.'
            : 'Your Hugging Face account has no access to this model yet. Accept its terms at huggingface.co/$repo '
                '(some authors approve requests by hand, which can take days), then try again.',
        HubRepoNotFoundException() => 'This repository is gone or private.',
        HubEntryNotFoundException() => 'This file is no longer in the pinned commit.',
        HubRevisionNotFoundException() => 'The pinned commit is gone from the repository.',
        HubDisabledRepoException() => 'Hugging Face disabled this repository.',
        HubNetworkException() => 'Could not reach Hugging Face. Your progress is saved; try again to continue.',
        HubServerException() => 'Hugging Face is having trouble right now. Your progress is saved; try again later.',
        HubUnauthorizedException() || HubForbiddenException() =>
          'Hugging Face refused the download. If you added a Hugging Face token, it may have been revoked or may '
              'not cover this model: replace it on the Hugging Face account screen, then try again. Or choose '
              'another model.',
        _ => 'Hugging Face answered: ${e.message}',
      };

  // ---------------------------------------------------------------------------
  // Install
  // ---------------------------------------------------------------------------

  Future<void> _install(String jobId) async {
    if (!_installing.add(jobId)) return;
    _emit(force: true);
    try {
      final job = _jobs[jobId];
      if (job == null || job.isInstalled) return;
      await _joinByteSplits(job);
      final loadAbs = layout.libraryPath(job.loadPath);
      final isGguf = job.loadPath.toLowerCase().endsWith('.gguf');
      LocalGgufInfo? info;
      if (isGguf) {
        try {
          info = await readLocalGgufHeader(loadAbs);
        } on GgufFormatException catch (e) {
          _report(e, 'install_gguf');
          _jobs[jobId] = job.copyWith(error: "Downloaded, but llama.cpp can't load it: ${e.message}.", updatedAt: _clock.now());
          await _save(jobId);
          return;
        } on FileSystemException catch (e) {
          _report(e, 'install_read');
          _jobs[jobId] = job.copyWith(error: 'Downloaded, but the model file could not be read: ${e.message}.');
          await _save(jobId);
          return;
        }
      }
      final meta = info?.metadata;
      var defaultCtx = job.meta.recommendedContext;
      final trained = job.meta.contextLength ?? meta?.contextLength;
      if (defaultCtx == null && info != null) {
        final arch = ModelArchitecture.fromGguf(info.metadata, parameterCount: info.header.parameterCount);
        if (arch != null) {
          final device = await _device.current();
          final fit = assessFit(
            device,
            ModelFootprintInput(
              architecture: arch,
              weightBytes: job.files.where((f) => f.role == FileRole.model).fold(0, (a, f) => a + f.expectedBytes),
              mmprojBytes: job.files.where((f) => f.role == FileRole.mmproj).fold(0, (a, f) => a + f.expectedBytes),
              quant: meta?.fileTypeInfo,
            ),
          );
          defaultCtx = fit.recommendedMaxContext;
        }
      }
      if (defaultCtx != null && trained != null) defaultCtx = math.min(defaultCtx, trained);
      final files = <LibraryFile>[];
      final joined = <String>{};
      for (final f in job.files) {
        final target = f.joinInto;
        if (target != null) {
          if (joined.add(target)) {
            files.add(LibraryFile(
              path: target,
              role: f.role,
              sizeBytes: job.files.where((g) => g.joinInto == target).fold(0, (a, g) => a + g.expectedBytes),
            ));
          }
          continue;
        }
        files.add(LibraryFile(path: f.localPath, role: f.role, sizeBytes: f.expectedBytes, sha256: f.sha256, repoPath: f.path));
      }
      final model = LibraryModel(
        id: _ids.next('model'),
        source: LibrarySource.hub,
        displayName: job.meta.displayName,
        format: job.meta.format,
        files: files,
        loadPath: job.loadPath,
        installedAt: _clock.now(),
        repo: job.repo,
        revision: job.commit,
        variantId: job.variantId,
        quant: job.meta.quant ?? meta?.fileTypeInfo?.id,
        mmprojPath: job.mmprojPath,
        draftPath: job.draftPath,
        contextLength: trained,
        defaultContextLength: defaultCtx,
        architecture: job.meta.architecture ?? meta?.architecture,
        parameterCount: job.meta.parameterCount ?? info?.header.parameterCount,
        license: job.meta.license ?? meta?.license,
        toolUse: meta?.chatTemplateMentionsTools ?? job.meta.toolUse,
        reasoning: meta?.chatTemplateMentionsReasoning ?? job.meta.reasoning,
      );
      await _library.add(model);
      _jobs[jobId] = job.copyWith(libraryModelId: model.id, completedAt: _clock.now(), updatedAt: _clock.now());
      await _save(jobId);
    } finally {
      _installing.remove(jobId);
      _emit(force: true);
    }
  }

  /// mradermacher `.gguf.partNofM` byte splits: each verified part is
  /// appended to the target in order and deleted, so peak extra space is
  /// one part (the planner's `tempBytes`, R08 §15.4).
  Future<void> _joinByteSplits(DownloadJob job) async {
    final byTarget = <String, List<DownloadRecord>>{};
    for (final f in job.files) {
      if (f.joinInto != null) (byTarget[f.joinInto!] ??= []).add(f);
    }
    for (final e in byTarget.entries) {
      final target = layout.libraryPath(e.key);
      if (File(target).existsSync() && e.value.every((f) => !File(layout.libraryPath(f.localPath)).existsSync())) {
        continue;
      }
      final parts = e.value..sort((a, b) => (a.partIndex ?? 0).compareTo(b.partIndex ?? 0));
      final tmp = '$target.joining';
      final sink = File(tmp).openWrite();
      try {
        for (final f in parts) {
          await sink.addStream(File(layout.libraryPath(f.localPath)).openRead());
        }
      } finally {
        await sink.close();
      }
      await File(tmp).rename(target);
      for (final f in parts) {
        await _deleteQuietly(layout.libraryPath(f.localPath));
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Persistence and views
  // ---------------------------------------------------------------------------

  /// Writes the job's current state. The snapshot is taken now, and the
  /// store applies writes in submission order (drift runs statements on one
  /// connection in order), so a later state can never be overwritten by an
  /// earlier one.
  Future<void> _save(String jobId) {
    final job = _jobs[jobId];
    if (job == null) return Future<void>.value();
    late final Future<void> f;
    f = _store.put(collection, jobId, job.toJson()).catchError((Object _) {}).whenComplete(() {
      // Only writes still in flight are remembered (dispose flushes them).
      if (identical(_writes[jobId], f)) _writes.remove(jobId);
    });
    _writes[jobId] = f;
    return f;
  }

  void _emit({bool force = false}) {
    if (_changes.isClosed || !_ready) return;
    final now = _clock.now();
    final last = _lastEmit;
    // Progress callbacks can fire hundreds of times a second; the list
    // needs a few frames' worth. A fake clock that never advances still
    // emits on every forced change.
    if (!force && last != null && now.difference(last) < const Duration(milliseconds: 200) && now != last) return;
    _lastEmit = now;
    _changes.add(jobs);
  }

  DownloadJobView _view(DownloadJob job) {
    final net = _network?.current ?? NetworkKind.unknown;
    var bytes = 0;
    double? speed;
    double? verify;
    String? current;
    var activeState = DownloadState.queued;
    var anyActive = false;
    for (final f in job.files) {
      final a = _active[f.id];
      if (a != null) {
        bytes += f.state == DownloadState.downloading ? a.bytes : f.bytesDownloaded;
        // A transfer told to pause takes a moment to wind down (the plugin
        // cancels natively, then reports back); the job reads as paused
        // from the tap on. A pause does not interrupt hashing, so that
        // still shows.
        if (job.userPaused && a.stop == _Stop.pause && f.state != DownloadState.verifying) continue;
        anyActive = true;
        final s = a.meter?.bytesPerSecond;
        if (s != null && f.state == DownloadState.downloading) speed = (speed ?? 0) + s;
        if (f.state == DownloadState.verifying) verify = a.verifyProgress;
        if (f.state.index > activeState.index || current == null) {
          activeState = f.state;
          current = f.path;
        }
      } else {
        bytes += f.bytesDownloaded;
      }
    }
    final failed = job.files.where((f) => f.state == DownloadState.failed).firstOrNull;
    final wifi = _wifiRequired(job);
    final JobPhase phase;
    if (job.isInstalled) {
      phase = JobPhase.done;
    } else if (job.error != null || (failed != null && !anyActive)) {
      phase = JobPhase.failed;
    } else if (job.userPaused && !anyActive) {
      phase = JobPhase.paused;
    } else if (_installing.contains(job.id) || job.files.every((f) => f.state == DownloadState.done)) {
      phase = JobPhase.installing;
    } else if (anyActive) {
      phase = switch (activeState) {
        DownloadState.verifying => JobPhase.verifying,
        DownloadState.downloading => JobPhase.downloading,
        _ => JobPhase.resolving,
      };
    } else if (!net.isOnline) {
      phase = JobPhase.waitingForNetwork;
    } else if (wifi && (net == NetworkKind.cellular || _osHeld.contains(job.id))) {
      // Our monitor saw mobile data, or the OS held the transfer for Wi-Fi
      // (a VPN or other link the monitor can't classify): either way the
      // user can allow mobile data for this job.
      phase = JobPhase.waitingForWifi;
    } else if (failed != null) {
      phase = JobPhase.failed;
    } else {
      phase = JobPhase.queued;
    }
    final remaining = math.max(0, job.totalBytes - bytes);
    final eta = speed == null || speed <= 0 ? null : Duration(seconds: (remaining / speed).ceil());
    return DownloadJobView(
      job: job,
      phase: phase,
      bytesDone: math.min(bytes, job.totalBytes),
      wifiOnly: wifi,
      bytesPerSecond: phase == JobPhase.downloading ? speed : null,
      eta: phase == JobPhase.downloading ? eta : null,
      verifyProgress: verify,
      error: job.error ?? failed?.error,
      currentFile: current,
    );
  }

  Future<void> _deleteQuietly(String path) async {
    try {
      final f = File(path);
      if (f.existsSync()) await f.delete();
    } on FileSystemException {
      // Orphan cleanup at the next launch catches it.
    }
  }

  Future<void> _removeEmptyDirs(String dir) async {
    var d = dir;
    while (p.isWithin(layout.libraryDir, d)) {
      final dd = Directory(d);
      if (!dd.existsSync()) {
        d = p.dirname(d);
        continue;
      }
      if (dd.listSync().isNotEmpty) return;
      await dd.delete();
      d = p.dirname(d);
    }
  }
}

enum _Stop { pause, cancel, hold }

/// A download step that failed, as the diagnostics ring records it (type and
/// [code] only; the user-facing message stays on the job).
final class DownloadFailure implements Exception {
  const DownloadFailure(this.code);

  final String code;

  @override
  String toString() => 'DownloadFailure($code)';
}

/// Bookkeeping for one running file.
final class _Active {
  _Active(this.jobId, {required this.large});

  final String jobId;
  final bool large;
  final Completer<void> finished = Completer<void>();
  TransferHandle? handle;
  _Stop? stop;
  int bytes = 0;
  _SpeedMeter? meter;
  DateTime? lastPersist;
  double? verifyProgress;
}

/// Exponentially smoothed throughput, so the ETA doesn't jump with every
/// TCP burst. Samples closer than 500 ms are merged.
final class _SpeedMeter {
  int? _bytes;
  DateTime? _at;
  double? _ewma;

  double? get bytesPerSecond => _ewma;

  void add(int bytes, DateTime at, {double? reported}) {
    final lastBytes = _bytes;
    final lastAt = _at;
    if (lastBytes == null || lastAt == null) {
      _bytes = bytes;
      _at = at;
      if (reported != null && reported > 0) _ewma = reported;
      return;
    }
    final dt = at.difference(lastAt).inMicroseconds / 1e6;
    if (dt < 0.5) return;
    final inst = math.max(0, bytes - lastBytes) / dt;
    _ewma = _ewma == null ? inst : 0.3 * inst + 0.7 * _ewma!;
    _bytes = bytes;
    _at = at;
  }
}
