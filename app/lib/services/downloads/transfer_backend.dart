import 'package:flutter/foundation.dart' show immutable;
import 'package:sherpa_net/sherpa_net.dart' show Redactor;

/// One byte transfer: fetch [url] from [offset] to the end (or to
/// [endInclusive]) and **append** the bytes to [partPath].
///
/// The [DownloadManager] owns everything above the bytes — resolving the
/// signed URL, deciding whether a partial file may be resumed, hashing,
/// moving into the library — so a backend only has to move bytes. That
/// keeps the R08 §5.5 rules in one testable place and lets the real
/// backend be swapped (background_downloader on devices, a fake in tests).
///
/// Invariants every backend keeps:
/// - Requests never carry credentials ([TransferRequest] refuses them).
/// - Bytes on disk in [partPath] are always a prefix of the remote file:
///   a backend appends only after the server confirmed the range it asked
///   for (`206` with a matching `Content-Range` start, or `200` from 0).
/// - [headers] go to [url] verbatim. The Hub token is never among them:
///   signed CDN URLs need none (R08 §5.5 step 2), and Hub-origin URLs
///   ([hubOrigin]) go to the in-process backend, which adds it itself.
/// - [url] is a short-lived credential (CloudFront signature, 1 h): never
///   log it unredacted and never persist it.
@immutable
final class TransferRequest {
  /// Throws [ArgumentError] when [headers] carry a credential: tokens never
  /// travel inside a request, because a background backend serializes the
  /// whole request into OS/plugin storage (background_downloader keeps tasks
  /// in SharedPreferences / WorkManager extras on Android and in
  /// `URLSessionTask.taskDescription` / UserDefaults on iOS).
  TransferRequest({
    required this.id,
    required this.url,
    required this.partPath,
    required this.offset,
    required this.expectedBytes,
    this.headers = const {},
    this.requiresWiFi = false,
    this.displayName,
    this.hubOrigin = false,
  }) {
    for (final k in headers.keys) {
      if (Redactor.isSensitiveHeader(k)) {
        throw ArgumentError.value(k, 'headers', 'credentials must not be passed in a transfer request');
      }
    }
  }

  /// Stable per file (the download record id).
  final String id;
  final Uri url;
  final Map<String, String> headers;

  /// Absolute path of the `.part` file to append to.
  final String partPath;

  /// Bytes already in [partPath]; the request asks for `bytes=<offset>-`.
  final int offset;

  /// Full size of the remote file (`X-Linked-Size`).
  final int expectedBytes;

  /// Defense in depth for "Wi-Fi only": the manager already holds jobs on
  /// cellular, and this asks the OS (Android `TRANSPORT_WIFI`, iOS
  /// `allowsCellularAccess = false`) to enforce it too (R09 §6).
  final bool requiresWiFi;

  /// For system notifications ("Downloading Qwen3 8B Q4_K_M").
  final String? displayName;

  /// [url] is on huggingface.co itself (`ResolvedDownload.sendAuthorization`:
  /// small non-LFS files via `/api/resolve-cache`). Only the in-process
  /// backend accepts these, and it attaches the user's token itself; a
  /// background backend refuses them so the token can never reach its
  /// persisted task records.
  final bool hubOrigin;

  @override
  String toString() => 'TransferRequest($id ${Redactor.uri(url)} from $offset/$expectedBytes)';
}

/// Progress of one transfer.
@immutable
final class TransferProgress {
  const TransferProgress({required this.bytesOnDisk, this.bytesPerSecond});

  /// Absolute size of the `.part` file (offset + received).
  final int bytesOnDisk;

  /// The backend's own speed estimate, when it has one.
  final double? bytesPerSecond;
}

/// Why a transfer ended. The manager re-reads the `.part` length after
/// every outcome — the file, not the backend's counter, is the truth.
sealed class TransferOutcome {
  const TransferOutcome();
}

/// The server sent everything up to the end of the requested range.
final class TransferCompleted extends TransferOutcome {
  const TransferCompleted({this.etag});

  /// CDN `ETag` (the Xet hash on the bridge, R08 §5.2), when reported.
  final String? etag;
}

/// Stopped because the manager asked ([TransferHandle.stop]).
final class TransferStopped extends TransferOutcome {
  const TransferStopped();
}

/// The server answered with an error status.
final class TransferHttpError extends TransferOutcome {
  const TransferHttpError(this.statusCode, {this.message});

  final int statusCode;
  final String? message;

  /// The CDN's `403 Auth failed: credentials expired` (R08 §5.2). Any 403
  /// from a signed URL is treated as expiry: the fix is the same (resolve
  /// again), and a real permission problem surfaces from the Hub on that
  /// resolve as a typed error.
  bool get isExpired => statusCode == 403 || (message?.toLowerCase().contains('expired') ?? false);
}

/// Connection lost, timeout, DNS — retry later.
final class TransferNetworkError extends TransferOutcome {
  const TransferNetworkError(this.message);

  final String message;
}

/// The OS holds the transfer until Wi-Fi is back.
final class TransferWaitingForWifi extends TransferOutcome {
  const TransferWaitingForWifi({this.notStarted = false});

  /// Nothing said the phone was off Wi-Fi, but the OS never started the
  /// Wi-Fi-only transfer: it does not count the current connection as
  /// Wi-Fi (see `watchUnstarted`). The user needs to hear why, because
  /// the phone itself shows Wi-Fi.
  final bool notStarted;
}

/// Disk full, permission denied, unexpected bytes — not retryable as is.
final class TransferFailed extends TransferOutcome {
  const TransferFailed(this.message);

  final String message;
}

/// A running transfer.
abstract interface class TransferHandle {
  Stream<TransferProgress> get progress;

  /// Completes exactly once.
  Future<TransferOutcome> get done;

  /// Stops and keeps whatever was appended so far; [done] then completes
  /// with [TransferStopped].
  Future<void> stop();
}

/// Moves bytes. See [TransferRequest] for the contract.
abstract interface class TransferBackend {
  /// Called once at launch, before any [start]: drop transfers a previous
  /// process left running. The manager resumes from the bytes on disk with
  /// a freshly resolved URL, because a stale signed URL in a native resume
  /// blob would 403 after an hour anyway (R08 §5.5 step 7).
  Future<void> recover();

  TransferHandle start(TransferRequest request);

  /// Extra bytes the backend writes next to the `.part` file while
  /// transferring (e.g. a staging segment); counted in storage checks.
  int get transientBytes;
}
