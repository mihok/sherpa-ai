import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http_pkg;
import 'package:http/io_client.dart';
import 'package:http/testing.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_hub/sherpa_hub.dart';
import 'package:sherpa_net/sherpa_net.dart';
import 'package:test/test.dart';

import 'support/fake_hub.dart';
import 'support/gguf_builder.dart';

const _realModel = '/opt/models/Qwen3-0.6B-Q4_K_M.gguf';

Object? _fixture(String name) => jsonDecode(File('test/fixtures/hub/$name').readAsStringSync());

void main() {
  late FakeHub hub;
  late IOClient http;
  late FakeClock clock;
  late List<Duration> sleeps;

  HfHubClient client({String? token, int maxRetries = 3}) => HfHubClient(
        httpClient: http,
        tokenProvider: token == null ? null : () async => token,
        baseUri: hub.hubUri,
        clock: clock,
        sleep: (d) async {
          sleeps.add(d);
          clock.advance(d);
        },
        backoff: Backoff(random: Random(1), base: const Duration(milliseconds: 10)),
        retryPolicy: HubRetryPolicy(maxRetries: maxRetries),
        // The fake CDN is plain http on loopback; production keeps the default (public https only).
        redirectPolicy: const UrlPolicy(scope: NetworkScope.loopback, allowHttp: true),
      );

  final tinyGguf = (GgufBuilder()
        ..string('general.architecture', 'llama')
        ..u32('llama.block_count', 2)
        ..u32('llama.context_length', 2048)
        ..u32('llama.attention.head_count', 4)
        ..u32('llama.attention.head_count_kv', 2)
        ..u32('llama.embedding_length', 256)
        ..stringArray('tokenizer.ggml.tokens', List.generate(20000, (i) => 'tok$i')))
      .build();

  setUp(() async {
    hub = await FakeHub.start();
    http = IOClient();
    clock = FakeClock(DateTime.now().toUtc());
    sleeps = [];
    hub.page1 = _fixture('models_page1.json');
    hub.page2 = _fixture('models_page2.json');
    hub.modelInfo = _fixture('model_info.json');
    hub.treeEntries = (_fixture('tree_qwen38_gguf.json')! as List).cast<Map<String, Object?>>();
    hub.repos['bartowski/Llama-3.2-1B-Instruct-GGUF'] = [
      FakeFile(
          path: 'Llama-3.2-1B-Instruct-IQ3_M.gguf',
          size: 657289344,
          sha256: 'c80cc062a721c267ec50fee83fe6b55d36fc7abe708392dbe22e16fbd42687e8',
          xetHash: '6d98e192e0c830d32a001c71ac58d103d67dbe66347c67c75129d99c66e265ee'),
      FakeFile(path: 'config.json', size: 13, bytes: Uint8List.fromList(utf8.encode('{"a":"b"}    ')), xetHash: '36293b60', lfs: false),
    ];
    hub.repos['meta-llama/Llama-3.2-1B-Instruct'] = [
      FakeFile(path: 'config.json', size: 2, bytes: Uint8List.fromList(utf8.encode('{}')), xetHash: 'cfg', lfs: false),
    ];
    hub.gated.add('meta-llama/Llama-3.2-1B-Instruct');
    hub.repos['synthetic/Tiny-GGUF'] = [
      FakeFile(path: 'tiny.gguf', size: tinyGguf.length, sha256: 'e' * 64, xetHash: 'f' * 64, bytes: tinyGguf),
      FakeFile(path: 'notes.gguf', size: 12, sha256: '1' * 64, xetHash: '2' * 64,
          bytes: Uint8List.fromList(utf8.encode('not a model!'))),
    ];
    if (File(_realModel).existsSync()) {
      hub.repos['unsloth/Qwen3-0.6B-GGUF'] = [
        FakeFile(path: 'Qwen3-0.6B-Q4_K_M.gguf', size: 396705472, sha256: 'ac2d9771' * 8, xetHash: '9' * 64, diskPath: _realModel),
      ];
    }
  });

  tearDown(() async {
    http.close();
    await hub.close();
  });

  group('search', () {
    test('filter= (never library=), sort, expand, limit; Link cursor pagination', () async {
      final c = client();
      final p1 = await c.searchModels(const ModelSearchQuery(
          text: 'llama', format: HubFormatFilter.gguf, pipelineTag: 'text-generation', sort: HubSort.downloads, limit: 2));
      final q = hub.hubRequests.single.uri.queryParametersAll;
      expect(q['filter'], ['gguf']);
      expect(q.containsKey('library'), isFalse);
      expect(q['search'], ['llama']);
      expect(q['sort'], ['downloads']);
      expect(q['pipeline_tag'], ['text-generation']);
      expect(q['limit'], ['2']);
      expect(q['expand'], containsAll(['downloads', 'gguf', 'gated']));
      expect(q['expand'], isNot(contains('siblings')), reason: 'cards never use the file list; it only weighs the page');
      expect(q.containsKey('direction'), isFalse);
      expect(p1.items.map((m) => m.id), ['bartowski/Llama-3.2-1B-Instruct-GGUF', 'ggml-org/vllm-d3-mini-GGUF']);
      final first = p1.items.first;
      expect(first.downloads, 155390);
      expect(first.gguf!.architecture, 'llama');
      expect(first.siblings, contains('Llama-3.2-1B-Instruct-Q4_K_M.gguf'));
      expect(p1.nextCursor, 'eyIkb3IiOlt7ImRvd25sb2Fkcy4uLiJ9XX0=');
      expect(c.rateLimiter.remaining('api'), 425);

      final p2 = await c.searchModels(const ModelSearchQuery(format: HubFormatFilter.gguf, sort: HubSort.downloads),
          cursor: p1.nextCursor);
      expect(hub.hubRequests.last.uri.queryParameters['cursor'], p1.nextCursor);
      expect(p2.items.first.gating, HubGating.auto);
      expect(p2.items.first.safetensors!.total, 27000000000);
      expect(p2.nextCursor, isNull);
    });

    test('only createdAt sorts ascending; bad cursors are 400s', () async {
      final c = client();
      expect(() => c.searchModels(const ModelSearchQuery(sort: HubSort.likes, ascending: true)), throwsArgumentError);
      expect(hub.hubRequests, isEmpty);
      await c.searchModels(const ModelSearchQuery(sort: HubSort.createdAt, ascending: true));
      expect(hub.hubRequests.single.uri.queryParameters['direction'], '1');
      await expectLater(c.searchModels(const ModelSearchQuery(), cursor: 'garbage'),
          throwsA(isA<HubBadRequestException>().having((e) => e.message, 'message', contains('cursor'))));
    });

    test('several authors fan out and merge by the sort key', () async {
      final c = client();
      const q = ModelSearchQuery(authors: ['bartowski', 'unsloth', 'ggml-org'], sort: HubSort.downloads, limit: 1);
      final p1 = await c.searchModels(q);
      expect(hub.hubRequests.map((r) => r.uri.queryParameters['author']).toSet(), {'bartowski', 'unsloth', 'ggml-org'});
      expect(p1.items.map((m) => m.id),
          ['unsloth/Qwen3.8-27B-GGUF', 'bartowski/Llama-3.2-1B-Instruct-GGUF', 'ggml-org/vllm-d3-mini-GGUF']);
      expect(p1.nextCursor, isNotNull);
      hub.hubRequests.clear();
      final p2 = await c.searchModels(q, cursor: p1.nextCursor);
      expect(hub.hubRequests.single.uri.queryParameters, containsPair('author', 'bartowski'));
      expect(p2.items.single.id, 'bartowski/Qwen_Qwen3.6-35B-A3B-GGUF');
      expect(p2.nextCursor, isNull);
    });
  });

  group('model info and files', () {
    test('blobs + securityStatus in one call', () async {
      final info = await client().modelInfo('bartowski/Llama-3.2-1B-Instruct-GGUF');
      final req = hub.hubRequests.single.uri;
      expect(req.path, '/api/models/bartowski/Llama-3.2-1B-Instruct-GGUF');
      expect(req.queryParameters, {'blobs': 'true', 'securityStatus': 'true'});
      expect(info.sha, '067b946cf014b7c697f3654f621d577a3e3afd1c');
      expect(info.cardData!.license, 'llama3.2');
      expect(info.cardData!.baseModels, ['meta-llama/Llama-3.2-1B-Instruct']);
      expect(info.cardData!.gateFields['Job title'], 'select');
      expect(info.security!.scansDone, isFalse);
      final q4 = info.files.firstWhere((f) => f.path.endsWith('Q4_K_M.gguf'));
      expect(q4.size, 807694464);
      expect(q4.lfsSha256, '6f85a640a97cf2bf5b8e764087b1e83da0fdb51d7c9fab7d0fece9385611df83');
      expect(info.files.firstWhere((f) => f.path == 'README.md').isLfs, isFalse);
      expect(info.usedStorage, 17157953114);
    });

    test('revision pinning and error codes', () async {
      final c = client();
      await c.modelInfo('bartowski/Llama-3.2-1B-Instruct-GGUF', revision: 'SC_4.00bpw_H5_V6');
      expect(hub.hubRequests.last.uri.path, '/api/models/bartowski/Llama-3.2-1B-Instruct-GGUF/revision/SC_4.00bpw_H5_V6');
      await expectLater(c.modelInfo('bartowski/Llama-3.2-1B-Instruct-GGUF', revision: 'nope-branch'),
          throwsA(isA<HubRevisionNotFoundException>().having((e) => e.errorCode, 'code', 'RevisionNotFound')));
      await expectLater(c.modelInfo('nobody/missing'),
          throwsA(isA<HubRepoNotFoundException>().having((e) => e.mayBePrivate, 'mayBePrivate', isTrue)));
      expect(() => c.modelInfo('../etc/passwd'), throwsArgumentError);
    });

    test('tree listing follows Link pagination and keeps scan results', () async {
      final files = await client().listFiles('unsloth/Qwen3.8-27B-GGUF', revision: FakeHub.commit);
      expect(hub.hubRequests, hasLength(3), reason: '19 entries, 7 per page');
      expect(hub.hubRequests.first.uri.queryParameters, {'recursive': 'true', 'expand': 'true'});
      expect(files, hasLength(19));
      final bad = files.firstWhere((f) => f.path == 'Qwen3.8-27B-Q5_K_M.gguf');
      expect(bad.security!.status, HubScanStatus.unsafe);
      expect(bad.security!.pickleImports.map((i) => i.safety), contains('dangerous'));
      expect(bad.security!.blocks, isTrue);
      expect(files.where((f) => f.isDirectory), hasLength(3));
      final shard = files.firstWhere((f) => f.path.startsWith('BF16/') && !f.isDirectory);
      expect(shard.xetHash, hasLength(64));
      expect(shard.lfsSize, shard.size);
    });

    test('paths-info returns only the requested paths', () async {
      final got = await client().pathsInfo('unsloth/Qwen3.8-27B-GGUF', FakeHub.commit, ['mmproj-F16.gguf', 'nope.gguf']);
      expect(got.map((f) => f.path), ['mmproj-F16.gguf']);
      expect(hub.hubRequests.single.method, 'POST');
    });
  });

  group('resolve', () {
    test('302 is not followed; X-Linked-* captured; token only to the Hub', () async {
      final r = await client(token: 'hf_secretTokenValue123456789').resolveDownload(
          'bartowski/Llama-3.2-1B-Instruct-GGUF', FakeHub.commit, 'Llama-3.2-1B-Instruct-IQ3_M.gguf');
      expect(hub.cdnRequests, isEmpty, reason: 'the redirect target was not fetched');
      final req = hub.hubRequests.single;
      expect(req.method, 'HEAD');
      expect(req.authorization, 'Bearer hf_secretTokenValue123456789');
      expect(req.headers['accept-encoding'], 'identity');
      expect(r.statusCode, 302);
      expect(r.url.origin, hub.cdnUri.origin);
      expect(r.sendAuthorization, isFalse);
      expect(r.size, 657289344);
      expect(r.sha256, 'c80cc062a721c267ec50fee83fe6b55d36fc7abe708392dbe22e16fbd42687e8');
      expect(r.xetHash, '6d98e192e0c830d32a001c71ac58d103d67dbe66347c67c75129d99c66e265ee');
      expect(r.commit, FakeHub.commit);
      expect(r.expiresAt!.difference(DateTime.now().toUtc()).inMinutes, inInclusiveRange(58, 60));
      expect(r.toString(), isNot(contains('c2lnbmF0dXJl')), reason: 'signature redacted');
      expect(ResolvedDownload.fromJson(r.toJson()).toJson(), r.toJson());
    });

    test('small files: 307 to a relative resolve-cache URL on the Hub origin', () async {
      final r = await client().resolveDownload('bartowski/Llama-3.2-1B-Instruct-GGUF', 'main', 'config.json');
      expect(r.statusCode, 307);
      expect(r.url.origin, hub.hubUri.origin);
      expect(r.url.path, startsWith('/api/resolve-cache/models/bartowski/'));
      expect(r.sendAuthorization, isTrue);
      expect(r.linkedEtag, '36293b60');
    });

    test('gated repo: 401 GatedRepo without a token, OK with one', () async {
      await expectLater(client().resolveDownload('meta-llama/Llama-3.2-1B-Instruct', 'main', 'config.json'),
          throwsA(isA<HubGatedRepoException>()
              .having((e) => e.needsSignIn, 'needsSignIn', isTrue)
              .having((e) => e.accessPage.toString(), 'accessPage', 'https://huggingface.co/meta-llama/Llama-3.2-1B-Instruct')));
      final ok = await client(token: FakeHub.goodToken).resolveDownload('meta-llama/Llama-3.2-1B-Instruct', 'main', 'config.json');
      expect(ok.statusCode, 307);
    });

    test('EntryNotFound / RevisionNotFound', () async {
      final c = client();
      await expectLater(c.resolveDownload('bartowski/Llama-3.2-1B-Instruct-GGUF', 'main', 'nope.gguf'),
          throwsA(isA<HubEntryNotFoundException>()));
      await expectLater(c.resolveDownload('bartowski/Llama-3.2-1B-Instruct-GGUF', 'nope-branch', 'config.json'),
          throwsA(isA<HubRevisionNotFoundException>()));
      expect(() => c.resolveDownload('bartowski/Llama-3.2-1B-Instruct-GGUF', 'main', '../x'), throwsArgumentError);
    });

    test('redirects to link-local/metadata addresses are refused', () async {
      hub.redirectOverride = 'http://169.254.169.254/latest/meta-data';
      await expectLater(
          client().resolveDownload('bartowski/Llama-3.2-1B-Instruct-GGUF', 'main', 'Llama-3.2-1B-Instruct-IQ3_M.gguf'),
          throwsA(isA<HubProtocolException>()));
    });
  });

  group('rate limits and retries', () {
    test('429 with a short JSON retryAfter is retried after waiting', () async {
      hub.throttle['/api/models'] = 2;
      hub.throttleRetryAfter = 1;
      final page = await client().searchModels(const ModelSearchQuery());
      expect(page.items, isNotEmpty);
      expect(sleeps, [const Duration(seconds: 1), const Duration(seconds: 1)]);
      expect(hub.hubRequests, hasLength(3));
    });

    test('429 with a long retryAfter surfaces and blocks the bucket locally', () async {
      hub.throttle['/api/models'] = 1;
      hub.throttleRetryAfter = 48;
      final c = client();
      await expectLater(c.searchModels(const ModelSearchQuery()),
          throwsA(isA<HubRateLimitedException>()
              .having((e) => e.retryAfter, 'retryAfter', const Duration(seconds: 48))
              .having((e) => e.bucket, 'bucket', 'api')
              .having((e) => e.message, 'message', contains('rate limit your IP'))));
      final before = hub.hubRequests.length;
      await expectLater(c.modelInfo('bartowski/Llama-3.2-1B-Instruct-GGUF'), throwsA(isA<HubRateLimitedException>()));
      expect(hub.hubRequests.length, before, reason: 'no request while the bucket is known to be empty');
      clock.advance(const Duration(seconds: 49));
      await c.modelInfo('bartowski/Llama-3.2-1B-Instruct-GGUF');
    });

    test('ratelimit r=0 on a 200 makes the next request wait for t', () async {
      hub.apiRemaining = 0;
      hub.apiReset = 157;
      final c = client();
      await c.searchModels(const ModelSearchQuery());
      await expectLater(c.searchModels(const ModelSearchQuery()), throwsA(isA<HubRateLimitedException>()));
      expect(hub.hubRequests, hasLength(1));
      hub.apiReset = 5;
      hub.apiRemaining = 0;
      final c2 = client();
      await c2.searchModels(const ModelSearchQuery());
      hub.apiRemaining = 400;
      await c2.searchModels(const ModelSearchQuery());
      expect(sleeps.last, const Duration(seconds: 5));
    });

    test('5xx is retried with backoff', () async {
      hub.flaky['/api/models'] = 2;
      await client().searchModels(const ModelSearchQuery());
      expect(sleeps, hasLength(2));
      hub.flaky['/api/models'] = 5;
      await expectLater(client(maxRetries: 1).searchModels(const ModelSearchQuery()), throwsA(isA<HubServerException>()));
    });

    test('connection failures become HubNetworkException after retries', () async {
      final dead = HfHubClient(
          httpClient: http, baseUri: Uri.parse('http://127.0.0.1:1'), sleep: (_) async {}, retryPolicy: const HubRetryPolicy(maxRetries: 1));
      await expectLater(dead.searchModels(const ModelSearchQuery()), throwsA(isA<HubNetworkException>()));
    });
  });

  group('transport', () {
    test('a response body that stalls becomes HubNetworkException instead of loading forever', () async {
      final stalled = StreamController<List<int>>();
      addTearDown(stalled.close);
      final c = HfHubClient(
        httpClient: MockClient.streaming((req, _) async => http_pkg.StreamedResponse(stalled.stream, 200)),
        sleep: (_) async {},
        retryPolicy: const HubRetryPolicy(bodyTimeout: Duration(milliseconds: 50)),
      );
      stalled.add(utf8.encode('[{"id":"a/b"'));
      await expectLater(c.searchModels(const ModelSearchQuery()).timeout(const Duration(seconds: 5)),
          throwsA(isA<HubNetworkException>().having((e) => e.code, 'code', 'hub_network')));
    });

    const gapPolicy = HubRetryPolicy(bodyTimeout: Duration(milliseconds: 150));

    test('bodyTimeout is a gap between bytes: a slow but steady body loads', () async {
      // Ten chunks 30 ms apart: about 300 ms in total, twice the timeout.
      final json = utf8.encode(jsonEncode([for (var i = 0; i < 10; i++) {'id': 'org/model-$i'}]));
      final step = (json.length / 10).ceil();
      final steady = StreamController<List<int>>();
      var sent = 0;
      final ticks = Timer.periodic(const Duration(milliseconds: 30), (t) {
        steady.add(json.sublist(sent, min(sent + step, json.length)));
        sent += step;
        if (sent >= json.length) {
          t.cancel();
          steady.close();
        }
      });
      addTearDown(ticks.cancel);
      final slow = HfHubClient(
        httpClient: MockClient.streaming((req, _) async => http_pkg.StreamedResponse(steady.stream, 200)),
        sleep: (_) async {},
        retryPolicy: gapPolicy,
      );
      final watch = Stopwatch()..start();
      final page = await slow.searchModels(const ModelSearchQuery()).timeout(const Duration(seconds: 5));
      expect(page.items.map((m) => m.id), [for (var i = 0; i < 10; i++) 'org/model-$i']);
      expect(watch.elapsed, greaterThan(gapPolicy.bodyTimeout), reason: 'the whole body took longer than one gap');
    });

    test('a stalled body is cancelled, so its connection is released', () async {
      final cancelled = Completer<void>();
      final stalled = StreamController<List<int>>(onCancel: cancelled.complete);
      addTearDown(stalled.close);
      final stuck = HfHubClient(
        httpClient: MockClient.streaming((req, _) async => http_pkg.StreamedResponse(stalled.stream, 200)),
        sleep: (_) async {},
        retryPolicy: gapPolicy,
      );
      stalled.add(utf8.encode('[{"id":"a/b"'));
      await expectLater(stuck.searchModels(const ModelSearchQuery()).timeout(const Duration(seconds: 5)),
          throwsA(isA<HubNetworkException>()));
      await expectLater(cancelled.future.timeout(const Duration(seconds: 1)), completes,
          reason: 'the response stream was cancelled');
    });

    test("today's Xet CDN (us.aws.cdn.hf.co) is not the Hub origin: no token goes there", () async {
      const cdn = 'https://us.aws.cdn.hf.co/xet-bridge-us/68b0/2c1e?X-Xet-Cas-Uid=public'
          '&Expires=1793000000&Policy=p&Signature=s&Key-Pair-Id=K';
      final seen = <http_pkg.BaseRequest>[];
      final c = HfHubClient(
        tokenProvider: () async => 'hf_secret',
        httpClient: MockClient((req) async {
          seen.add(req);
          if (req.url.host == 'huggingface.co') {
            return http_pkg.Response('', 302, headers: {
              'location': cdn,
              'x-linked-size': '1107409472',
              'x-linked-etag': '"${'a' * 64}"',
              'x-xet-hash': '2c1e',
              'x-repo-commit': 'b' * 40,
            });
          }
          return http_pkg.Response.bytes(List<int>.filled(16, 0), 206, headers: {'content-range': 'bytes 0-15/1107409472'});
        }),
      );
      final r = await c.resolveDownload('unsloth/Qwen3-1.7B-GGUF', 'b' * 40, 'Qwen3-1.7B-Q4_K_M.gguf');
      expect(r.url.host, 'us.aws.cdn.hf.co');
      expect(r.sendAuthorization, isFalse);
      expect(r.size, 1107409472);
      expect(r.sha256, 'a' * 64);
      expect(seen.single.headers['authorization'], 'Bearer hf_secret', reason: 'the resolve on huggingface.co');
      await expectLater(c.readGgufHeader('unsloth/Qwen3-1.7B-GGUF', 'b' * 40, 'Qwen3-1.7B-Q4_K_M.gguf', maxBytes: 16),
          throwsA(anything));
      final cdnRequests = seen.where((q) => q.url.host == 'us.aws.cdn.hf.co').toList();
      expect(cdnRequests, isNotEmpty);
      expect(cdnRequests.map((q) => q.headers.keys.map((k) => k.toLowerCase())), everyElement(isNot(contains('authorization'))));
    });
  });

  group('GGUF header peek over Range', () {
    test('real Qwen3-0.6B: incremental ranges from the CDN, no token sent there', () async {
      final peek = await client(token: FakeHub.goodToken)
          .readGgufHeader('unsloth/Qwen3-0.6B-GGUF', FakeHub.commit, 'Qwen3-0.6B-Q4_K_M.gguf');
      final m = peek.header.metadata;
      expect(m.architecture, 'qwen3');
      expect(m.blockCount, 28);
      expect(m.headCountKv, 8);
      expect(m.keyLength, 128);
      expect(m.contextLength, 40960);
      expect(peek.fileSize, 396705472);
      expect(peek.bytesFetched, greaterThanOrEqualTo(5933927));
      expect(peek.bytesFetched, lessThanOrEqualTo(8 << 20), reason: 'one ~8 MB budget covers it (R08 §0.21)');
      expect(hub.cdnRequests.length, inInclusiveRange(2, 3));
      for (final r in hub.cdnRequests) {
        expect(r.authorization, isNull, reason: 'the token never reaches the CDN');
        expect(r.headers['accept-encoding'], 'identity');
        expect(r.headers['range'], matches(RegExp(r'^bytes=\d+-\d+$')));
      }
      expect(hub.cdnRequests.first.headers['range'], 'bytes=0-2097151');
      final kv = estimateKvCache(ModelArchitecture.fromGguf(m)!, contextLength: 4096);
      expect(kv.bytes, 238 << 20);
    }, skip: File(_realModel).existsSync() ? false : 'needs $_realModel');

    test('an expired signed URL is re-resolved once (403 credentials expired)', () async {
      hub.expireNext.add('tiny.gguf');
      final peek = await client().readGgufHeader('synthetic/Tiny-GGUF', 'main', 'tiny.gguf', initialBytes: 1024);
      expect(peek.header.metadata.blockCount, 2);
      expect(hub.hubRequests.where((r) => r.uri.path.contains('/resolve/')), hasLength(2));
      expect(hub.cdnRequests.first.uri.queryParameters['Expires'], isNotNull);
    });

    test('a CDN that ignores Range still yields only the needed prefix', () async {
      hub.ignoreRange.add('f' * 64);
      final peek = await client().readGgufHeader('synthetic/Tiny-GGUF', 'main', 'tiny.gguf', initialBytes: 64);
      expect(peek.header.metadata.vocabSize, 20000);
    });

    test('limits and non-GGUF files', () async {
      await expectLater(client().readGgufHeader('synthetic/Tiny-GGUF', 'main', 'tiny.gguf', initialBytes: 64, maxBytes: 1024),
          throwsA(isA<HubProtocolException>()));
      await expectLater(client().readGgufHeader('synthetic/Tiny-GGUF', 'main', 'notes.gguf'),
          throwsA(isA<GgufFormatException>()));
    });
  });

  test('whoami validates the token explicitly', () async {
    await expectLater(client(token: 'hf_bogusTokenValue1234567890').whoami(), throwsA(isA<HubUnauthorizedException>()));
    final me = await client(token: FakeHub.goodToken).whoami();
    expect(me.name, 'sherpa-tester');
    expect(me.orgs, ['sherpa-org']);
    expect(me.tokenRole, 'fineGrained');
  });

  test('HfHubCatalog: search → details → files', () async {
    final catalog = HfHubCatalog(client());
    final page = await catalog.search(const ModelSearchQuery(format: HubFormatFilter.gguf));
    final llama = page.items.first;
    expect(llama.name.family!.value, 'Llama');
    expect(llama.toolUseHint, isTrue);
    final d = await catalog.details('bartowski/Llama-3.2-1B-Instruct-GGUF');
    expect(d.commit, '067b946cf014b7c697f3654f621d577a3e3afd1c');
    expect(d.variants.map((v) => v.label), ['Q8_0', 'Q4_K_M', 'IQ3_M']);
    expect(d.defaultVariant!.label, 'Q4_K_M');
    expect(d.license, 'llama3.2');
    expect(d.executionLocation, ExecutionLocation.onDevice);
    final plan = planDownload(repo: d.id, commit: d.commit, files: d.files.map((f) => f.file).toList());
    expect(plan, isA<DownloadPlan>().having((p) => p.totalBytes, 'bytes', 807694464));
    final files = await catalog.files('unsloth/Qwen3.8-27B-GGUF', revision: FakeHub.commit);
    expect(files.where((f) => f.name.role.value == FileRole.mmproj), hasLength(3));
  });
}
