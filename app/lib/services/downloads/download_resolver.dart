import 'package:sherpa_hub/sherpa_hub.dart';

/// Turns a pinned repo file into the URL its bytes come from.
///
/// Every (re)start of a transfer resolves again: signed CDN URLs expire
/// after one hour (R08 §0.10), and a fresh resolve also re-reads
/// `X-Xet-Hash` / `X-Linked-ETag` / `X-Linked-Size`, which is how a resume
/// proves the bytes on disk still belong to the same content (the CDN
/// ignores `If-Range`, R08 §0.9).
abstract interface class DownloadResolver {
  Future<ResolvedDownload> resolve(String repo, String commit, String path);
}

/// [DownloadResolver] over [HfHubClient.resolveDownload]: `HEAD` without
/// following the redirect, token attached only on `huggingface.co`.
final class HubDownloadResolver implements DownloadResolver {
  HubDownloadResolver(this.client);

  final HfHubClient client;

  @override
  Future<ResolvedDownload> resolve(String repo, String commit, String path) =>
      client.resolveDownload(repo, commit, path);
}
