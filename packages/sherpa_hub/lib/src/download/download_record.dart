import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../hub/hub_models.dart';
import '../naming/name_types.dart';

/// Lifecycle of one file download. The app's download manager persists a
/// [DownloadRecord] after every transition so a download survives process
/// death, app relaunch and the 1-hour expiry of signed CDN URLs.
enum DownloadState {
  queued,

  /// Asking the Hub for a fresh signed URL (first start, 403 expired, relaunch).
  resolving,
  downloading,
  paused,

  /// Streaming SHA-256 over the finished file (CDN ETag is a Xet hash, not
  /// SHA-256, so this is the only integrity check, R08 §0.9).
  verifying,
  done,
  failed;

  static const Map<DownloadState, Set<DownloadState>> _allowed = {
    queued: {resolving, paused, failed},
    resolving: {downloading, paused, failed, queued},
    downloading: {paused, verifying, failed, resolving},
    paused: {queued, resolving, failed},
    verifying: {done, failed, queued},
    failed: {queued},
    done: {},
  };

  bool canTransitionTo(DownloadState next) => _allowed[this]!.contains(next);

  bool get isTerminal => this == done;

  bool get isActive => this == resolving || this == downloading || this == verifying;
}

/// What to do with bytes already on disk after a re-resolve.
@immutable
final class ResumeDecision {
  const ResumeDecision._(this.fromByte, this.reason);

  const ResumeDecision.resume(int fromByte) : this._(fromByte, null);

  const ResumeDecision.restart(String reason) : this._(0, reason);

  /// Send `Range: bytes=<fromByte>-`.
  final int fromByte;

  /// Why the partial file must be discarded; null when resuming.
  final String? reason;

  bool get restarts => reason != null;
}

/// Persistable state of one file download (hand-written JSON, like every
/// sherpa_core type that crosses persistence).
@immutable
final class DownloadRecord {
  const DownloadRecord({
    required this.id,
    required this.groupId,
    required this.repo,
    required this.commit,
    required this.path,
    required this.localPath,
    required this.role,
    required this.expectedBytes,
    required this.state,
    required this.createdAt,
    required this.updatedAt,
    this.sha256,
    this.gitBlobSha1,
    this.expectedXetHash,
    this.bytesDownloaded = 0,
    this.resolvedUrl,
    this.sendAuthorization = false,
    this.cdnUrlExpiry,
    this.etag,
    this.resolvedXetHash,
    this.attempts = 0,
    this.error,
    this.joinInto,
    this.partIndex,
    this.shardIndex,
    this.shardCount,
  });

  factory DownloadRecord.fromJson(JsonMap j) => DownloadRecord(
        id: j.req<String>('id'),
        groupId: j.req<String>('groupId'),
        repo: j.req<String>('repo'),
        commit: j.req<String>('commit'),
        path: j.req<String>('path'),
        localPath: j.req<String>('localPath'),
        role: FileRole.values.byName(j.req<String>('role')),
        expectedBytes: j.req<num>('expectedBytes').toInt(),
        state: DownloadState.values.byName(j.req<String>('state')),
        createdAt: DateTime.parse(j.req<String>('createdAt')),
        updatedAt: DateTime.parse(j.req<String>('updatedAt')),
        sha256: j.opt<String>('sha256'),
        gitBlobSha1: j.opt<String>('gitBlobSha1'),
        expectedXetHash: j.opt<String>('expectedXetHash'),
        bytesDownloaded: j.optInt('bytesDownloaded') ?? 0,
        resolvedUrl: j.opt<String>('resolvedUrl') == null ? null : Uri.parse(j.req<String>('resolvedUrl')),
        sendAuthorization: j.opt<bool>('sendAuthorization') ?? false,
        cdnUrlExpiry: j.optDate('cdnUrlExpiry'),
        etag: j.opt<String>('etag'),
        resolvedXetHash: j.opt<String>('resolvedXetHash'),
        attempts: j.optInt('attempts') ?? 0,
        error: j.opt<String>('error'),
        joinInto: j.opt<String>('joinInto'),
        partIndex: j.optInt('partIndex'),
        shardIndex: j.optInt('shardIndex'),
        shardCount: j.optInt('shardCount'),
      );

  final String id;

  /// Shared by all files of one plan (shards + mmproj + draft).
  final String groupId;
  final String repo;

  /// Pinned commit sha: every shard from one commit (R08 §3.1).
  final String commit;
  final String path;

  /// Destination relative to the model store root.
  final String localPath;
  final FileRole role;
  final int expectedBytes;
  final DownloadState state;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// `lfs.oid` — verify the finished file against it.
  final String? sha256;

  /// Small non-LFS files: git blob sha1 (`sha1("blob <len>\0" + bytes)`).
  final String? gitBlobSha1;

  /// `xetHash` from the tree listing at plan time.
  final String? expectedXetHash;

  /// Bytes in the `.part` file (resume offset).
  final int bytesDownloaded;

  /// Last signed URL; a credential for an hour — encrypted store only.
  final Uri? resolvedUrl;
  final bool sendAuthorization;

  /// `Expires` of [resolvedUrl]; past it the CDN answers 403.
  final DateTime? cdnUrlExpiry;

  /// CDN `ETag` seen while downloading (= Xet hash on the bridge).
  final String? etag;

  /// `X-Xet-Hash` of the resolve that produced the bytes on disk. The CDN
  /// ignores `If-Range`, so a resume compares this instead (R08 §0.9).
  final String? resolvedXetHash;
  final int attempts;
  final String? error;

  /// Byte-split parts (`.gguf.part1of2`): the file they are joined into.
  final String? joinInto;
  final int? partIndex;
  final int? shardIndex;
  final int? shardCount;

  double get progress => expectedBytes <= 0 ? 0 : (bytesDownloaded / expectedBytes).clamp(0, 1).toDouble();

  bool get isComplete => bytesDownloaded >= expectedBytes;

  /// Whether the stored URL can still be used at [now].
  bool needsResolve(DateTime now, {Duration skew = const Duration(minutes: 2)}) {
    final exp = cdnUrlExpiry;
    if (resolvedUrl == null) return true;
    return exp != null && !now.isBefore(exp.subtract(skew));
  }

  /// Moves to [next] or throws [StateError] for an illegal transition.
  DownloadRecord transition(DownloadState next, {required DateTime at, String? error}) {
    if (!state.canTransitionTo(next)) {
      throw StateError('download $id: ${state.name} → ${next.name} is not allowed');
    }
    return _copy(
      state: next,
      updatedAt: at,
      error: next == DownloadState.failed ? (error ?? this.error ?? 'failed') : null,
      clearError: next != DownloadState.failed,
      attempts: next == DownloadState.resolving ? attempts + 1 : attempts,
    );
  }

  DownloadRecord withProgress(int bytes, {required DateTime at, String? etag}) =>
      _copy(bytesDownloaded: bytes, updatedAt: at, etag: etag);

  /// Applies a fresh resolve and decides whether the partial file survives.
  (DownloadRecord, ResumeDecision) applyResolve(ResolvedDownload r, {required DateTime at}) {
    final decision = decideResume(r);
    final next = _copy(
      updatedAt: at,
      resolvedUrl: r.url,
      sendAuthorization: r.sendAuthorization,
      cdnUrlExpiry: r.expiresAt,
      resolvedXetHash: r.xetHash ?? resolvedXetHash,
      bytesDownloaded: decision.fromByte,
    );
    return (next, decision);
  }

  /// Because the CDN ignores `If-Range`, the only safe resume is one where
  /// the content identity is unchanged: same Xet hash, same SHA-256, same
  /// size, and not more bytes than the file has (R08 §5.5 step 4).
  ResumeDecision decideResume(ResolvedDownload fresh) {
    if (bytesDownloaded <= 0) return const ResumeDecision.resume(0);
    final freshSha = fresh.sha256;
    if (sha256 != null && freshSha != null && freshSha != sha256) {
      return const ResumeDecision.restart('the file changed upstream (SHA-256 differs)');
    }
    final known = resolvedXetHash ?? expectedXetHash;
    if (known != null && fresh.xetHash != null && fresh.xetHash != known) {
      return const ResumeDecision.restart('the CDN serves different content (Xet hash changed)');
    }
    if (fresh.size != null && fresh.size != expectedBytes) {
      return const ResumeDecision.restart('the file size changed');
    }
    if (bytesDownloaded > expectedBytes) return const ResumeDecision.restart('more bytes on disk than the file has');
    return ResumeDecision.resume(bytesDownloaded);
  }

  DownloadRecord _copy({
    DownloadState? state,
    DateTime? updatedAt,
    int? bytesDownloaded,
    Uri? resolvedUrl,
    bool? sendAuthorization,
    DateTime? cdnUrlExpiry,
    String? etag,
    String? resolvedXetHash,
    int? attempts,
    String? error,
    bool clearError = false,
  }) =>
      DownloadRecord(
        id: id,
        groupId: groupId,
        repo: repo,
        commit: commit,
        path: path,
        localPath: localPath,
        role: role,
        expectedBytes: expectedBytes,
        state: state ?? this.state,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        sha256: sha256,
        gitBlobSha1: gitBlobSha1,
        expectedXetHash: expectedXetHash,
        bytesDownloaded: bytesDownloaded ?? this.bytesDownloaded,
        resolvedUrl: resolvedUrl ?? this.resolvedUrl,
        sendAuthorization: sendAuthorization ?? this.sendAuthorization,
        cdnUrlExpiry: cdnUrlExpiry ?? this.cdnUrlExpiry,
        etag: etag ?? this.etag,
        resolvedXetHash: resolvedXetHash ?? this.resolvedXetHash,
        attempts: attempts ?? this.attempts,
        error: clearError ? null : (error ?? this.error),
        joinInto: joinInto,
        partIndex: partIndex,
        shardIndex: shardIndex,
        shardCount: shardCount,
      );

  JsonMap toJson() => compact({
        'id': id,
        'groupId': groupId,
        'repo': repo,
        'commit': commit,
        'path': path,
        'localPath': localPath,
        'role': role.name,
        'expectedBytes': expectedBytes,
        'state': state.name,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'updatedAt': updatedAt.toUtc().toIso8601String(),
        'sha256': sha256,
        'gitBlobSha1': gitBlobSha1,
        'expectedXetHash': expectedXetHash,
        'bytesDownloaded': bytesDownloaded,
        'resolvedUrl': resolvedUrl?.toString(),
        'sendAuthorization': sendAuthorization,
        'cdnUrlExpiry': cdnUrlExpiry?.toUtc().toIso8601String(),
        'etag': etag,
        'resolvedXetHash': resolvedXetHash,
        'attempts': attempts,
        'error': error,
        'joinInto': joinInto,
        'partIndex': partIndex,
        'shardIndex': shardIndex,
        'shardCount': shardCount,
      });
}
