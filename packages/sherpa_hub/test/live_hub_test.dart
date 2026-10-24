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

  test("a Transformers repo's GGUF versions: filter=base_model:quantized:<id> finds the official one", () async {
    final page = await HfHubCatalog(hub).search(
        const ModelSearchQuery(format: HubFormatFilter.gguf, quantizedFrom: 'Qwen/Qwen3-0.6B', sort: HubSort.downloads, limit: 50));
    expect(page.items.map((e) => e.id), contains('Qwen/Qwen3-0.6B-GGUF'));
    expect(page.items.every((e) => e.tags.contains('base_model:quantized:Qwen/Qwen3-0.6B')), isTrue);
    expect(page.items.every((e) => e.tags.contains('gguf')), isTrue);
  }, skip: skip);

  test('an MLX conversion without "mlx" in its name is one MLX variant by its tags', () async {
    final found = await hub.searchModels(const ModelSearchQuery(format: HubFormatFilter.mlx, sort: HubSort.trending, limit: 100));
    final unnamed = found.items.where((m) => m.formatHints.contains('mlx') && !m.id.toLowerCase().contains('mlx')).toList();
    expect(unnamed, isNotEmpty, reason: 'the Hub has MLX repos named without "mlx"');
    final catalog = HfHubCatalog(hub);
    var checked = 0;
    for (final m in unnamed.take(5)) {
      final d = await catalog.details(m.id);
      final mlx = d.variants.where((v) => v.runtime == SherpaRuntime.mlx);
      if (d.variants.any((v) => v.blockedReasons.join().contains('Transformers weights'))) {
        fail('${m.id} (tagged mlx) was read as Transformers weights');
      }
      if (mlx.isNotEmpty) checked++;
    }
    expect(checked, greaterThan(0), reason: 'at least one of them holds safetensors read as MLX');
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));

  test('an MLX speech model only tagged mlx is never an MLX variant: the MLX runtime loads language models', () async {
    final found = await hub.searchModels(const ModelSearchQuery(
        format: HubFormatFilter.mlx, pipelineTag: 'automatic-speech-recognition', sort: HubSort.downloads, limit: 50));
    // Named ones (mlx-community/whisper-…) are read as MLX by their names.
    final unnamed = found.items.where((m) => !m.id.toLowerCase().contains('mlx')).toList();
    expect(unnamed, isNotEmpty);
    final catalog = HfHubCatalog(hub);
    for (final m in unnamed.take(3)) {
      final d = await catalog.details(m.id);
      expect(d.variants.where((v) => v.runtime == SherpaRuntime.mlx && v.usable), isEmpty, reason: m.id);
    }
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));

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
