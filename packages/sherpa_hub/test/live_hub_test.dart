@Tags(['live'])
library;

import 'dart:io';

import 'package:http/io_client.dart';
import 'package:sherpa_hub/sherpa_hub.dart';
import 'package:test/test.dart';

/// Smoke test against the real huggingface.co. Off by default:
///
///     SHERPA_LIVE_HUB=1 dart test test/live_hub_test.dart
///
/// Honours HTTPS_PROXY, and SHERPA_LIVE_CA (a PEM bundle) for TLS-inspecting
/// proxies. Uses anonymous requests only (a handful, well under the 500/5 min
/// anonymous API quota, R08 §6).
void main() {
  final enabled = Platform.environment['SHERPA_LIVE_HUB'] == '1';
  late IOClient http;
  late HfHubClient hub;

  setUpAll(() {
    if (!enabled) return;
    final ca = Platform.environment['SHERPA_LIVE_CA'];
    final ctx = SecurityContext(withTrustedRoots: true);
    if (ca != null && File(ca).existsSync()) ctx.setTrustedCertificates(ca);
    final io = HttpClient(context: ctx)..findProxy = HttpClient.findProxyFromEnvironment;
    http = IOClient(io);
    hub = HfHubClient(httpClient: http);
  });

  tearDownAll(() {
    if (enabled) http.close();
  });

  final skip = enabled ? false : 'set SHERPA_LIVE_HUB=1 to run against huggingface.co';

  test('search with filter=gguf returns GGUF repos and a Link cursor', () async {
    final page = await hub.searchModels(const ModelSearchQuery(
        format: HubFormatFilter.gguf, authors: ['bartowski'], sort: HubSort.downloads, limit: 3));
    expect(page.items, isNotEmpty);
    expect(page.items.every((m) => m.id.startsWith('bartowski/')), isTrue);
    expect(page.items.every((m) => m.tags.contains('gguf')), isTrue);
    expect(page.nextCursor, isNotNull);
  }, skip: skip);

  test('model info + resolve + header peek on a small public GGUF', () async {
    const repo = 'bartowski/Llama-3.2-1B-Instruct-GGUF';
    final info = await hub.modelInfo(repo);
    expect(info.sha, hasLength(40));
    final file = info.files.firstWhere((f) => f.path.endsWith('Q4_K_M.gguf'));
    expect(file.lfsSha256, hasLength(64));
    final r = await hub.resolveDownload(repo, info.sha!, file.path);
    expect(r.sendAuthorization, isFalse, reason: 'LFS files redirect to the CDN');
    expect(r.size, file.size);
    expect(r.sha256, file.lfsSha256);
    expect(r.commit, info.sha);
    final peek = await hub.readGgufHeader(repo, info.sha!, file.path);
    expect(peek.header.metadata.architecture, 'llama');
    expect(peek.header.metadata.blockCount, 16);
    expect(peek.header.metadata.fileType, 15);
    final plan = planDownload(repo: repo, commit: info.sha!, files: info.files, quant: 'Q4_K_M');
    expect(plan, isA<DownloadPlan>());
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));

  test('a typed query and a pasted repo id find GGUF repos (the browser default: trending, filter=gguf)', () async {
    final catalog = HfHubCatalog(hub);
    final typed = await catalog.search(const ModelSearchQuery(text: 'qwen3 0.6b', format: HubFormatFilter.gguf));
    expect(typed.items.map((e) => e.id.toLowerCase()), contains(contains('qwen3-0.6b')));
    final byId = await catalog.search(const ModelSearchQuery(text: 'Qwen/Qwen3-0.6B-GGUF', format: HubFormatFilter.gguf));
    expect(byId.items.map((e) => e.id), contains('Qwen/Qwen3-0.6B-GGUF'));
  }, skip: skip);

  test("a starter model's resolve leaves the Hub origin for a signed CDN URL (no token goes there)", () async {
    const repo = 'unsloth/Qwen3-0.6B-GGUF';
    final info = await hub.modelInfo(repo);
    final file = info.files.firstWhere((f) => f.path.endsWith('Q4_K_M.gguf'));
    final r = await hub.resolveDownload(repo, info.sha!, file.path);
    expect(r.url.host, isNot('huggingface.co'));
    expect(r.sendAuthorization, isFalse);
    expect(r.size, file.size);
    expect(r.sha256, file.lfsSha256);
    expect(r.expiresAt!.isAfter(DateTime.now().toUtc()), isTrue);
  }, skip: skip);

  test('gated content without a token is 401 GatedRepo', () async {
    await expectLater(hub.resolveDownload('meta-llama/Llama-3.2-1B-Instruct', 'main', 'config.json'),
        throwsA(isA<HubGatedRepoException>()));
  }, skip: skip);
}
