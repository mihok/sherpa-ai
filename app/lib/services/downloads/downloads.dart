/// Model downloads and the local model library (M2).
///
/// - [DownloadManager]: resolve → Range transfer → SHA-256 verify → install,
///   persisted per job, Wi-Fi-only, one large file at a time.
/// - [ModelLibrary]: installed models, delete, disk usage, GGUF import.
/// - [TransferBackend]: the byte mover (background_downloader on devices).
library;

export 'background_transfer_backend.dart';
export 'download_job.dart';
export 'download_manager.dart';
export 'download_resolver.dart';
export 'file_hasher.dart';
export 'http_transfer_backend.dart';
export 'local_model_file.dart';
export 'model_library.dart';
export 'network_monitor.dart';
export 'record_store.dart';
export 'storage_layout.dart';
export 'transfer_backend.dart';
