import 'package:sherpa/services/downloads/downloads.dart';
import 'package:sherpa_hub/sherpa_hub.dart';

import 'models_rig.dart';

/// Deterministic jobs for the numbers test and the golden.
List<DownloadJobView> sampleJobs() {
  final t = DateTime.utc(2026, 10, 18, 12);
  DownloadRecord rec(String id, String path, int size, DownloadState state, {int done = 0, String? error}) => DownloadRecord(
        id: id,
        groupId: 'g_$id',
        repo: 'r',
        commit: fixtureCommit,
        path: path,
        localPath: 'f/$path',
        role: FileRole.model,
        expectedBytes: size,
        state: state,
        createdAt: t,
        updatedAt: t,
        bytesDownloaded: done,
        error: error,
      );
  DownloadJob job(String id, String name, String repo, String label, List<DownloadRecord> files) => DownloadJob(
        id: id,
        repo: repo,
        commit: fixtureCommit,
        variantId: label,
        label: label,
        folder: 'f',
        loadPath: 'f/${files.first.path}',
        meta: DownloadMeta(displayName: name, quant: label),
        files: files,
        createdAt: t,
        updatedAt: t,
      );
  const g = 1024 * 1024 * 1024;
  final a = job('a', 'Llama 3.2 1B', llama1b, 'F16', [rec('a1', 'Llama-3.2-1B-Instruct-f16.gguf', (2.3 * g).round(), DownloadState.downloading, done: (1.2 * g).round())]);
  final b = job('b', 'Qwen 3 8B', 'unsloth/Qwen3-8B-GGUF', 'Q4_K_M', [rec('b1', 'Qwen3-8B-Q4_K_M.gguf', (4.7 * g).round(), DownloadState.queued)]);
  final c = job('c', 'Gemma 3 270M', 'ggml-org/gemma-3-270m-it-GGUF', 'Q8_0', [
    rec('c1', 'gemma-3-270m-it-Q8_0.gguf', 291 << 20, DownloadState.failed,
        error: "gemma-3-270m-it-Q8_0.gguf didn't match its SHA-256 (corrupted in transit or changed upstream). "
            'The partial file was deleted; tap Retry to download it again.'),
  ]);
  final d = job('d', 'SmolLM 3 3B', 'ggml-org/SmolLM3-3B-GGUF', 'Q4_K_M', [rec('d1', 'SmolLM3-Q4_K_M.gguf', 1900 << 20, DownloadState.done, done: 1900 << 20)])
      .copyWith(libraryModelId: 'm', completedAt: t);
  return [
    DownloadJobView(job: a, phase: JobPhase.downloading, bytesDone: a.files.single.bytesDownloaded, wifiOnly: true, bytesPerSecond: 3 * 1024 * 1024, eta: const Duration(minutes: 6), currentFile: a.files.single.path),
    DownloadJobView(job: b, phase: JobPhase.waitingForWifi, bytesDone: 0, wifiOnly: true),
    DownloadJobView(job: c, phase: JobPhase.failed, bytesDone: 0, wifiOnly: true, error: c.files.single.error),
    DownloadJobView(job: d, phase: JobPhase.done, bytesDone: d.totalBytes, wifiOnly: true),
  ];
}
