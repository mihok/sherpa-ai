import 'package:flutter/foundation.dart' show immutable;
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_hub/sherpa_hub.dart';

/// What the UI knew about the model when the user tapped Download; copied
/// into the library entry once every file is verified.
@immutable
final class DownloadMeta {
  const DownloadMeta({
    required this.displayName,
    this.quant,
    this.format = ModelFormat.gguf,
    this.contextLength,
    this.recommendedContext,
    this.architecture,
    this.parameterCount,
    this.license,
    this.toolUse = false,
    this.reasoning = false,
  });

  factory DownloadMeta.fromJson(JsonMap j) => DownloadMeta(
        displayName: j.opt<String>('displayName') ?? '',
        quant: j.opt<String>('quant'),
        format: ModelFormat.values.asNameMap()[j.opt<String>('format')] ?? ModelFormat.gguf,
        contextLength: j.optInt('contextLength'),
        recommendedContext: j.optInt('recommendedContext'),
        architecture: j.opt<String>('architecture'),
        parameterCount: j.optInt('parameterCount'),
        license: j.opt<String>('license'),
        toolUse: j.opt<bool>('toolUse') ?? false,
        reasoning: j.opt<bool>('reasoning') ?? false,
      );

  /// "Qwen 3 8B".
  final String displayName;

  /// Quant label (`Q4_K_M`, `UD-Q4_K_XL`).
  final String? quant;
  final ModelFormat format;

  /// Trained context (`<arch>.context_length` from the header peek).
  final int? contextLength;

  /// Largest context that Fits on this device (`FitResult.recommendedMaxContext`).
  final int? recommendedContext;
  final String? architecture;
  final int? parameterCount;
  final String? license;
  final bool toolUse;
  final bool reasoning;

  DownloadMeta withFormat(ModelFormat f) => DownloadMeta(
        displayName: displayName,
        quant: quant,
        format: f,
        contextLength: contextLength,
        recommendedContext: recommendedContext,
        architecture: architecture,
        parameterCount: parameterCount,
        license: license,
        toolUse: toolUse,
        reasoning: reasoning,
      );

  JsonMap toJson() => compact({
        'displayName': displayName,
        'quant': quant,
        'format': format.name,
        'contextLength': contextLength,
        'recommendedContext': recommendedContext,
        'architecture': architecture,
        'parameterCount': parameterCount,
        'license': license,
        'toolUse': toolUse,
        'reasoning': reasoning,
      });
}

/// One download the user asked for: every file of a [DownloadPlan]
/// (shards, projector, draft, support files), pinned to one commit.
///
/// Persisted as one document in `DocumentCollections.downloads` so a job's
/// files change together. [files] are the hub package's [DownloadRecord]s,
/// whose state machine guards every transition.
@immutable
final class DownloadJob {
  const DownloadJob({
    required this.id,
    required this.repo,
    required this.commit,
    required this.variantId,
    required this.label,
    required this.folder,
    required this.loadPath,
    required this.meta,
    required this.files,
    required this.createdAt,
    required this.updatedAt,
    this.mmprojPath,
    this.draftPath,
    this.tempBytes = 0,
    this.userPaused = false,
    this.allowCellular = false,
    this.completedAt,
    this.libraryModelId,
    this.notice,
    this.error,
  });

  factory DownloadJob.fromJson(JsonMap j) => DownloadJob(
        id: j.req<String>('id'),
        repo: j.req<String>('repo'),
        commit: j.req<String>('commit'),
        variantId: j.req<String>('variantId'),
        label: j.req<String>('label'),
        folder: j.req<String>('folder'),
        loadPath: j.req<String>('loadPath'),
        meta: DownloadMeta.fromJson(j.opt<JsonMap>('meta') ?? const {}),
        files: [
          for (final f in j.opt<List<Object?>>('files') ?? const <Object?>[])
            if (f is Map) DownloadRecord.fromJson(f.cast<String, Object?>()),
        ],
        createdAt: DateTime.parse(j.req<String>('createdAt')),
        updatedAt: DateTime.parse(j.req<String>('updatedAt')),
        mmprojPath: j.opt<String>('mmprojPath'),
        draftPath: j.opt<String>('draftPath'),
        tempBytes: j.optInt('tempBytes') ?? 0,
        userPaused: j.opt<bool>('userPaused') ?? false,
        allowCellular: j.opt<bool>('allowCellular') ?? false,
        completedAt: j.optDate('completedAt'),
        libraryModelId: j.opt<String>('libraryModelId'),
        notice: j.opt<String>('notice'),
        error: j.opt<String>('error'),
      );

  /// The plan's group id.
  final String id;
  final String repo;
  final String commit;
  final String variantId;

  /// Quant label or file name, as the detail screen showed it.
  final String label;

  /// Library folder for this commit (`DownloadPlan.folder`).
  final String folder;

  /// Library-relative path the engine opens (shard 1 / the joined file).
  final String loadPath;
  final String? mmprojPath;
  final String? draftPath;
  final DownloadMeta meta;
  final List<DownloadRecord> files;

  /// Transient bytes the plan needs beyond its files (byte-split joins).
  final int tempBytes;

  /// Paused by the user (not by a lost Wi-Fi link): stays paused across
  /// relaunches until the user resumes.
  final bool userPaused;

  /// "Download over cellular anyway" for this job only.
  final bool allowCellular;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? completedAt;
  final String? libraryModelId;

  /// Something the user should know but that did not fail the job
  /// ("Restarted: the file changed upstream").
  final String? notice;

  /// Job-level failure (install step); file failures live on the records.
  final String? error;

  int get totalBytes => files.fold(0, (a, f) => a + f.expectedBytes);

  bool get isInstalled => libraryModelId != null;

  DownloadJob copyWith({
    List<DownloadRecord>? files,
    DateTime? updatedAt,
    bool? userPaused,
    bool? allowCellular,
    DateTime? completedAt,
    String? libraryModelId,
    String? notice,
    bool clearNotice = false,
    String? error,
    bool clearError = false,
  }) =>
      DownloadJob(
        id: id,
        repo: repo,
        commit: commit,
        variantId: variantId,
        label: label,
        folder: folder,
        loadPath: loadPath,
        meta: meta,
        files: files ?? this.files,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        mmprojPath: mmprojPath,
        draftPath: draftPath,
        tempBytes: tempBytes,
        userPaused: userPaused ?? this.userPaused,
        allowCellular: allowCellular ?? this.allowCellular,
        completedAt: completedAt ?? this.completedAt,
        libraryModelId: libraryModelId ?? this.libraryModelId,
        notice: clearNotice ? null : (notice ?? this.notice),
        error: clearError ? null : (error ?? this.error),
      );

  DownloadJob withFile(DownloadRecord r, {required DateTime at}) => copyWith(
        files: [for (final f in files) f.id == r.id ? r : f],
        updatedAt: at,
      );

  /// What reaches the database. The signed CDN URL is a credential for an
  /// hour (CloudFront `Signature`), so it is stripped here and lives only
  /// in the manager's memory; a relaunch re-resolves, which R08 §5.5 step 4
  /// requires anyway.
  JsonMap toJson() => compact({
        'id': id,
        'repo': repo,
        'commit': commit,
        'variantId': variantId,
        'label': label,
        'folder': folder,
        'loadPath': loadPath,
        'mmprojPath': mmprojPath,
        'draftPath': draftPath,
        'meta': meta.toJson(),
        'files': [for (final f in files) persistableRecord(f)],
        'tempBytes': tempBytes,
        'userPaused': userPaused,
        'allowCellular': allowCellular,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'updatedAt': updatedAt.toUtc().toIso8601String(),
        'completedAt': completedAt?.toUtc().toIso8601String(),
        'libraryModelId': libraryModelId,
        'notice': notice,
        'error': error,
      });
}

/// [DownloadRecord.toJson] without the signed URL and what only makes sense
/// with it.
JsonMap persistableRecord(DownloadRecord r) => r.toJson()
  ..remove('resolvedUrl')
  ..remove('cdnUrlExpiry')
  ..remove('sendAuthorization');

/// The same record without its in-memory URL (what a reload would see).
DownloadRecord withoutSignedUrl(DownloadRecord r) => DownloadRecord.fromJson(persistableRecord(r));

/// What a job is doing, in the words the Downloads screen uses.
enum JobPhase {
  queued,

  /// Wi-Fi only is on and the phone is on mobile data.
  waitingForWifi,

  /// No network at all.
  waitingForNetwork,

  /// Asking the Hub for a signed URL.
  resolving,
  downloading,

  /// Streaming SHA-256 over a finished file.
  verifying,

  /// Moving verified files into the library and reading the header.
  installing,
  paused,
  failed,

  /// Verified and in the library.
  done;

  bool get isActive => this == resolving || this == downloading || this == verifying || this == installing;

  bool get isWaiting => this == queued || this == waitingForWifi || this == waitingForNetwork;

  bool get canPause => isActive || isWaiting;

  bool get canResume => this == paused || this == failed;
}

/// One immutable snapshot of a job for the UI: persisted state plus the
/// live numbers only the manager knows (bytes in flight, speed, ETA).
@immutable
final class DownloadJobView {
  const DownloadJobView({
    required this.job,
    required this.phase,
    required this.bytesDone,
    required this.wifiOnly,
    this.bytesPerSecond,
    this.eta,
    this.verifyProgress,
    this.error,
    this.currentFile,
  });

  final DownloadJob job;
  final JobPhase phase;

  /// Bytes on disk across all files (live).
  final int bytesDone;

  /// Effective Wi-Fi-only policy for this job.
  final bool wifiOnly;

  /// Smoothed transfer speed; null until measured.
  final double? bytesPerSecond;

  /// Time left at [bytesPerSecond]; null when unknown.
  final Duration? eta;

  /// 0..1 while hashing.
  final double? verifyProgress;

  /// User-facing failure text.
  final String? error;

  /// The file being transferred or verified (repo path).
  final String? currentFile;

  String get id => job.id;

  int get totalBytes => job.totalBytes;

  double get progress => totalBytes <= 0 ? 0 : (bytesDone / totalBytes).clamp(0, 1).toDouble();

  @override
  bool operator ==(Object other) =>
      other is DownloadJobView &&
      identical(other.job, job) &&
      other.phase == phase &&
      other.bytesDone == bytesDone &&
      other.wifiOnly == wifiOnly &&
      other.bytesPerSecond == bytesPerSecond &&
      other.eta == eta &&
      other.verifyProgress == verifyProgress &&
      other.error == error &&
      other.currentFile == currentFile;

  @override
  int get hashCode => Object.hash(job, phase, bytesDone, wifiOnly, bytesPerSecond, eta, verifyProgress, error, currentFile);
}

/// Result of asking for a download.
sealed class EnqueueOutcome {
  const EnqueueOutcome();
}

final class Enqueued extends EnqueueOutcome {
  const Enqueued(this.jobId, {this.warnings = const []});

  final String jobId;

  /// e.g. "Only 0.8 GB would be left afterwards."
  final List<String> warnings;
}

/// Not started; [reasons] are ready to show.
final class EnqueueRefused extends EnqueueOutcome {
  const EnqueueRefused(this.reasons, {this.storage});

  final List<String> reasons;
  final StorageCheck? storage;
}

/// The same variant at the same commit is already downloading or installed.
final class AlreadyPresent extends EnqueueOutcome {
  const AlreadyPresent({this.jobId, this.libraryModelId});

  final String? jobId;
  final String? libraryModelId;
}
