import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_hub/sherpa_hub.dart';
import 'package:test/test.dart';

const _commit = 'c03ac9c3bdc5ae949111acb945338933f396e4d7';
const _repo = 'unsloth/Qwen3.8-27B-GGUF';

/// Tree entries in the live response shape (R08 §4.1/§11); sizes follow the
/// real repos, hashes are synthetic.
List<HubRepoFile> _tree() => [
      for (final e in jsonDecode(File('test/fixtures/hub/tree_qwen38_gguf.json').readAsStringSync()) as List)
        HubRepoFile.fromTreeJson((e as Map).cast<String, Object?>()),
    ];

HubRepoFile _lfs(String path, int size) =>
    HubRepoFile(path: path, size: size, lfsSha256: 'a' * 64, lfsSize: size, xetHash: 'b' * 64, oid: 'c' * 40);

HubRepoFile _small(String path, int size) => HubRepoFile(path: path, size: size, oid: 'd' * 40);

T _ok<T extends PlanOutcome>(PlanOutcome o) {
  if (o is PlanRefused) fail('refused: ${o.reasons}');
  return o as T;
}

void main() {
  group('variant grouping', () {
    test('quants, shard sets and blocked variants of a GGUF repo', () {
      final vs = groupVariants(_repo, _tree());
      final byLabel = {for (final v in vs) v.label: v};
      expect(byLabel.keys, containsAll(['BF16', 'Q8_0', 'Q4_K_M', 'UD-Q4_K_XL', 'UD-IQ1_S', 'Q4_0_4_4', 'Q5_K_M']));
      expect(byLabel.keys.where((l) => l.contains('mmproj') || l.contains('mtp') || l.contains('imatrix')), isEmpty,
          reason: 'sidecars are not variants');
      expect(byLabel['BF16']!.weights.map((f) => f.path),
          ['BF16/Qwen3.8-27B-BF16-00001-of-00002.gguf', 'BF16/Qwen3.8-27B-BF16-00002-of-00002.gguf']);
      expect(byLabel['BF16']!.weightBytes, 49655154016 + 4440652032);
      expect(byLabel['BF16']!.id, 'BF16/Qwen3.8-27B-BF16');
      expect(byLabel['UD-IQ1_S']!.missingParts, [2]);
      expect(byLabel['UD-IQ1_S']!.usable, isFalse);
      expect(byLabel['Q4_0_4_4']!.blockedReasons.single, contains('removed'));
      expect(byLabel['Q5_K_M']!.blockedReasons.single, contains('flags'));
      expect(byLabel['Q8_0']!.usable, isTrue);
      expect(byLabel['Q8_0']!.warnings.single, contains('caution'));
      final pickle = vs.firstWhere((v) => v.format == ModelFormat.pickle);
      expect(pickle.usable, isFalse);
      expect(vs.takeWhile((v) => v.usable).map((v) => v.label), ['BF16', 'Q8_0', 'Q4_K_M', 'UD-Q4_K_XL'],
          reason: 'usable first, best quality first');
      expect(defaultVariant(vs)!.label, 'Q4_K_M', reason: "llama.cpp's -hf default");
    });

    test('MLX repo: one variant with its config/tokenizer files', () {
      final files = [
        _small('.gitattributes', 1519),
        _small('README.md', 3000),
        _small('config.json', 1200),
        _small('tokenizer_config.json', 9700),
        _lfs('tokenizer.json', 11422654),
        _lfs('model.safetensors', 4610000000),
        _small('model.safetensors.index.json', 64000),
      ];
      final vs = groupVariants('mlx-community/Qwen3-8B-4bit', files);
      expect(vs, hasLength(1));
      final v = vs.single;
      expect(v.format, ModelFormat.mlx);
      expect(v.runtime, SherpaRuntime.mlx);
      expect(v.usable, isTrue);
      expect(v.support.map((f) => f.path).toSet(),
          {'config.json', 'tokenizer_config.json', 'tokenizer.json', 'model.safetensors.index.json'});
      final plan = _ok<DownloadPlan>(planDownload(repo: 'mlx-community/Qwen3-8B-4bit', commit: _commit, files: files));
      expect(plan.files.first.path, 'model.safetensors');
      final cfg = plan.files.firstWhere((f) => f.path == 'config.json');
      expect(cfg.gitBlobSha1, 'd' * 40, reason: 'small files verify by git blob sha1');
      expect(cfg.sha256, isNull);
      expect(plan.totalBytes, 4610000000 + 11422654 + 1200 + 9700 + 64000);
    });

    test('formats Sherpa cannot run are kept but blocked', () {
      final gptq = groupVariants('Qwen/Qwen2.5-7B-Instruct-GPTQ-Int4',
          [_small('config.json', 900), _lfs('model-00001-of-00002.safetensors', 3e9.toInt()), _lfs('model-00002-of-00002.safetensors', 2e9.toInt())]);
      expect(gptq.single.usable, isFalse);
      expect(gptq.single.blockedReasons.join(), contains('CUDA'));
      final onnx = groupVariants('HuggingFaceTB/SmolLM2-135M-Instruct', [_lfs('onnx/model_q4f16.onnx', 1e8.toInt())]);
      expect(onnx.single.blockedReasons, contains('Sherpa has no ONNX runtime'));
    });
  });

  group('plans', () {
    test('Q4_K_M + auto-paired mmproj, pinned and hashed', () {
      final plan = _ok<DownloadPlan>(planDownload(repo: _repo, commit: _commit, files: _tree(), quant: 'Q4_K_M'));
      expect(plan.files.map((f) => f.path), ['Qwen3.8-27B-Q4_K_M.gguf', 'mmproj-F16.gguf']);
      expect(plan.mmproj!.path, 'mmproj-F16.gguf', reason: 'closest bit width; F16 wins the BF16 tie; F32 never');
      expect(plan.files.every((f) => f.sha256 != null && f.sha256!.length == 64), isTrue);
      expect(plan.totalBytes, 16470000000 + 931000000);
      expect(plan.tempBytes, 0);
      expect(plan.variant.loadPath, 'Qwen3.8-27B-Q4_K_M.gguf');
      expect(planDownload(repo: _repo, commit: _commit, files: _tree(), quant: 'Q4_K_M', includeMmproj: false),
          isA<DownloadPlan>().having((p) => p.mmproj, 'mmproj', isNull));
    });

    test('sharded BF16 keeps every shard; the draft comes from MTP/', () {
      final plan = _ok<DownloadPlan>(
          planDownload(repo: _repo, commit: _commit, files: _tree(), quant: 'BF16', draft: DraftKind.mtp));
      expect(plan.files.where((f) => f.role == FileRole.model).map((f) => '${f.shardIndex}/${f.shardCount}'), ['1/2', '2/2']);
      expect(plan.mmproj!.path, 'mmproj-F16.gguf', reason: 'same bit width as the model; F16 preferred over BF16');
      expect(plan.draft!.path, 'MTP/mtp-Qwen3.8-27B-Q4_0.gguf');
      final records = plan.toRecords(now: DateTime.utc(2026, 10, 18), ids: SequentialIdGenerator());
      expect(records.map((r) => r.localPath).first, 'unsloth__Qwen3.8-27B-GGUF@c03ac9c3bdc5/BF16/Qwen3.8-27B-BF16-00001-of-00002.gguf');
      expect(records.map((r) => r.groupId).toSet(), {'dlg_1'});
      expect(records.every((r) => r.state == DownloadState.queued && r.commit == _commit), isTrue);
    });

    test('refusals are explicit', () {
      List<String> refused(PlanOutcome o) => (o as PlanRefused).reasons;
      expect(refused(planDownload(repo: _repo, commit: 'main', files: _tree())).single, contains('pinned'));
      expect(refused(planDownload(repo: _repo, commit: _commit, files: _tree(), quant: 'UD-IQ1_S')).join(), contains('Missing part'));
      expect(refused(planDownload(repo: _repo, commit: _commit, files: _tree(), quant: 'Q4_0_4_4')).join(), contains('removed'));
      expect(refused(planDownload(repo: _repo, commit: _commit, files: _tree(), quant: 'Q5_K_M')).join(), contains('unsafe'));
      expect(refused(planDownload(repo: _repo, commit: _commit, files: _tree(), quant: 'IQ2_XXS')).single, contains('No "IQ2_XXS"'));
      expect(
          refused(planDownload(repo: _repo, commit: _commit, files: _tree(), quant: 'Q4_K_M', unsupportedQuants: {'Q4_K_M'}))
              .join(),
          contains('newer llama.cpp'));
      final noHash = [HubRepoFile(path: 'X-7B-Q4_K_M.gguf', size: 100)];
      expect(refused(planDownload(repo: 'a/X-7B-GGUF', commit: _commit, files: noHash)).join(), contains('SHA-256'));
      final pickles = [_lfs('pytorch_model-00001-of-00002.bin', 9), _lfs('pytorch_model-00002-of-00002.bin', 9)];
      expect(refused(planDownload(repo: 'mistralai/Mistral-7B-Instruct-v0.2', commit: _commit, files: pickles, quant: 'pytorch_model'))
              .join(),
          contains('pickle'));
    });

    test('repo-level scan results block too (securityRepoStatus)', () {
      final files = [_lfs('Foo-7B-Q4_K_M.gguf', 4e9.toInt())];
      const sec = HubRepoSecurity(scansDone: true, filesWithIssues: {'Foo-7B-Q4_K_M.gguf': HubScanStatus.unsafe});
      expect(planDownload(repo: 'a/Foo-7B-GGUF', commit: _commit, files: files, repoSecurity: sec), isA<PlanRefused>());
    });

    test('byte-split parts are joined; temp space is the largest part', () {
      final files = [
        _lfs('Llama-3.3-70B-Instruct-abliterated.Q8_0.gguf.part1of2', 39000000000),
        _lfs('Llama-3.3-70B-Instruct-abliterated.Q8_0.gguf.part2of2', 35975790000),
        _lfs('Llama-3.3-70B-Instruct-abliterated.Q4_K_M.gguf', 42520000000),
      ];
      final plan = _ok<DownloadPlan>(planDownload(
          repo: 'mradermacher/Llama-3.3-70B-Instruct-abliterated-GGUF', commit: _commit, files: files, quant: 'Q8_0'));
      expect(plan.files.map((f) => f.joinInto).toSet(), {'Llama-3.3-70B-Instruct-abliterated.Q8_0.gguf'});
      expect(plan.tempBytes, 39000000000);
      expect(plan.variant.loadPath, 'Llama-3.3-70B-Instruct-abliterated.Q8_0.gguf');
      expect(plan.warnings.join(), contains('join'));
      final storage = assessStorage(downloadBytes: plan.totalBytes, tempBytes: plan.tempBytes, freeBytes: 80000000000);
      expect(storage.verdict, StorageVerdict.insufficient);
    });

    test('a .bin proven to be safetensors by its first bytes is allowed', () {
      final header = utf8.encode('{"__metadata__":{}}');
      final head = Uint8List(8 + header.length)
        ..buffer.asByteData().setUint64(0, header.length, Endian.little)
        ..setRange(8, 8 + header.length, header);
      final f = _lfs('weights.bin', 1000);
      expect(FileSafety.check(f).allowed, isFalse);
      final ok = FileSafety.check(f, head: head);
      expect(ok.allowed, isTrue);
      expect(ok.warnings.single, contains('safetensors'));
    });
  });

  group('format sniffing', () {
    Uint8List b(List<int> v) => Uint8List.fromList([...v, ...List.filled(16, 0)]);
    test('magic bytes', () {
      expect(sniffWeightFormat(b([0x47, 0x47, 0x55, 0x46, 3, 0, 0, 0])), SniffedFormat.gguf);
      expect(sniffWeightFormat(b([0x47, 0x47, 0x55, 0x46, 0, 0, 0, 3])), SniffedFormat.ggufBigEndian);
      expect(sniffWeightFormat(b([0x80, 0x04, 0x95])), SniffedFormat.pickle);
      expect(sniffWeightFormat(b([0x50, 0x4b, 0x03, 0x04])), SniffedFormat.zipArchive);
      expect(sniffWeightFormat(b('tjgg'.codeUnits)), SniffedFormat.legacyGgml);
      expect(sniffWeightFormat(b([1, 2, 3])), SniffedFormat.unknown);
      expect(FileSafety.check(_lfs('model.gguf', 1), head: b([0x80, 0x02])).allowed, isFalse);
      expect(FileSafety.check(_lfs('model.exe', 1)).allowed, isFalse);
      expect(FileSafety.extensionOf('a/b.Q8_0.gguf.part2of2'), '.gguf');
    });
  });

  group('DownloadRecord', () {
    final t0 = DateTime.utc(2026, 10, 18, 12);
    DownloadRecord rec() => DownloadRecord(
          id: 'dl_1',
          groupId: 'dlg_1',
          repo: _repo,
          commit: _commit,
          path: 'Qwen3.8-27B-Q4_K_M.gguf',
          localPath: 'x/Qwen3.8-27B-Q4_K_M.gguf',
          role: FileRole.model,
          expectedBytes: 1000,
          state: DownloadState.queued,
          createdAt: t0,
          updatedAt: t0,
          sha256: 'a' * 64,
          expectedXetHash: 'b' * 64,
        );
    ResolvedDownload resolved({String? xet, String? sha, int size = 1000, DateTime? expires}) => ResolvedDownload(
          repo: _repo,
          revision: _commit,
          path: 'Qwen3.8-27B-Q4_K_M.gguf',
          url: Uri.parse('https://us.aws.cdn.hf.co/xet-bridge-us/abc/${xet ?? 'b' * 64}?Expires=1&Signature=s'),
          sendAuthorization: false,
          statusCode: 302,
          size: size,
          linkedEtag: sha ?? 'a' * 64,
          xetHash: xet ?? 'b' * 64,
          expiresAt: expires ?? t0.add(const Duration(hours: 1)),
        );

    test('state machine', () {
      var r = rec().transition(DownloadState.resolving, at: t0);
      expect(r.attempts, 1);
      r = r.transition(DownloadState.downloading, at: t0);
      r = r.transition(DownloadState.resolving, at: t0); // 403 expired → re-resolve
      expect(r.attempts, 2);
      r = r.transition(DownloadState.downloading, at: t0).transition(DownloadState.verifying, at: t0);
      r = r.transition(DownloadState.done, at: t0);
      expect(r.state.isTerminal, isTrue);
      expect(() => r.transition(DownloadState.downloading, at: t0), throwsStateError);
      expect(() => rec().transition(DownloadState.done, at: t0), throwsStateError);
      final failed = rec().transition(DownloadState.failed, at: t0, error: 'disk full');
      expect(failed.error, 'disk full');
      expect(failed.transition(DownloadState.queued, at: t0).error, isNull);
    });

    test('resume only when the content identity is unchanged (If-Range is ignored)', () {
      final partial = rec().withProgress(600, at: t0);
      expect(partial.decideResume(resolved()).fromByte, 600);
      expect(partial.decideResume(resolved(xet: 'e' * 64)).restarts, isTrue);
      expect(partial.decideResume(resolved(sha: 'f' * 64)).restarts, isTrue);
      expect(partial.decideResume(resolved(size: 999)).restarts, isTrue);
      final (next, decision) = partial.applyResolve(resolved(xet: 'e' * 64), at: t0);
      expect(decision.reason, contains('Xet'));
      expect(next.bytesDownloaded, 0);
      expect(next.resolvedXetHash, 'e' * 64);
      expect(next.cdnUrlExpiry, t0.add(const Duration(hours: 1)));
    });

    test('signed URL expiry triggers a re-resolve', () {
      final (r, _) = rec().applyResolve(resolved(), at: t0);
      expect(r.needsResolve(t0), isFalse);
      expect(r.needsResolve(t0.add(const Duration(minutes: 59))), isTrue, reason: '2-minute skew');
      expect(rec().needsResolve(t0), isTrue);
    });

    test('JSON round-trip', () {
      final (r, _) = rec().withProgress(10, at: t0).applyResolve(resolved(), at: t0);
      final back = DownloadRecord.fromJson(jsonDecode(jsonEncode(r.toJson())) as Map<String, Object?>);
      expect(back.toJson(), r.toJson());
    });
  });

  group('integrity helpers', () {
    test('sha256 streaming and git blob sha1', () async {
      expect(await sha256Of(Stream.fromIterable([utf8.encode('a'), utf8.encode('bc')])),
          'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
      expect(await verifySha256(Stream.value(utf8.encode('abc')),
          'BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD'), isTrue);
      // `printf 'hello\n' | git hash-object --stdin`
      expect(gitBlobSha1(Uint8List.fromList(utf8.encode('hello\n'))), 'ce013625030ba8dba906f756967f9e9ca394464a');
    });
  });
}
