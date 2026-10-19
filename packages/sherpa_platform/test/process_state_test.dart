import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa_platform/sherpa_platform.dart';
import 'package:sherpa_platform/testing.dart';

void main() {
  setUp(ProcessStateRecorder.reset);

  group('ProcessStateRecorder', () {
    test('writes UTF-8 bytes', () async {
      final b = FakePlatformBackend();
      expect(await ProcessStateRecorder.write('loading model X ctx 8192', backend: b), isTrue);
      expect(utf8.decode(b.summaries.single), 'loading model X ctx 8192');
    });

    test('cuts at 128 bytes without splitting a character', () async {
      final b = FakePlatformBackend();
      // 127 ASCII bytes + a 2-byte "é" = 129 bytes: the é must go entirely.
      await ProcessStateRecorder.write('${'a' * 127}é', backend: b);
      expect(b.summaries.single.length, 127);
      expect(utf8.decode(b.summaries.single), 'a' * 127);
      final t = ProcessStateRecorder.truncateUtf8('😀' * 40, 128);
      expect(t.length, 128);
      expect(utf8.decode(t), '😀' * 32);
      expect(ProcessStateRecorder.truncateUtf8('short', 128).length, 5);
    });

    test('repeating the same summary is skipped (the OS may throttle)', () async {
      final b = FakePlatformBackend();
      await ProcessStateRecorder.write('p=load', backend: b);
      await ProcessStateRecorder.write('p=load', backend: b);
      await ProcessStateRecorder.write('p=decode', backend: b);
      await ProcessStateRecorder.write('p=load', backend: b);
      expect(b.summaries.map(utf8.decode), ['p=load', 'p=decode', 'p=load']);
    });

    test('is a no-op returning false where unsupported', () async {
      expect(await ProcessStateRecorder.write('x', backend: const UnsupportedPlatformBackend()), isFalse);
    });

    test('record() writes the structured form', () async {
      final b = FakePlatformBackend();
      await ProcessStateRecorder.record(
        ProcessStateSummary.forModel(
            phase: ProcessPhase.load, modelId: 'unsloth/Qwen3-4B-GGUF/Qwen3-4B-Q4_K_M.gguf', contextTokens: 8192),
        backend: b,
      );
      final text = utf8.decode(b.summaries.single);
      expect(text, startsWith('v1 p=load m='));
      expect(text, isNot(contains('Qwen')), reason: 'the model id is hashed');
      expect(text, endsWith(' c=8192'));
    });
  });

  group('ProcessStateSummary', () {
    test('encode/parse round trip, well under 128 bytes', () {
      const s = ProcessStateSummary(
        phase: ProcessPhase.decode,
        modelHash: 'deadbeef',
        backend: 'opencl',
        contextTokens: 32768,
        foreground: true,
      );
      final text = s.encode();
      expect(text, 'v1 p=decode m=deadbeef b=opencl c=32768 fg=1');
      expect(utf8.encode(text).length, lessThan(64));
      expect(ProcessStateSummary.tryParse(text), s);
      expect(s.toString(), text);
    });

    test('backend names are sanitized and capped', () {
      const s = ProcessStateSummary(phase: ProcessPhase.idle, backend: 'my backend=with spaces and more');
      expect(s.encode(), 'v1 p=idle b=my_backend_with_');
    });

    test('free text and unknown versions do not parse', () {
      expect(ProcessStateSummary.tryParse(null), isNull);
      expect(ProcessStateSummary.tryParse('loading model X'), isNull);
      expect(ProcessStateSummary.tryParse('v2 p=decode'), isNull);
      expect(ProcessStateSummary.tryParse('v1 p=nope'), isNull);
      expect(ProcessStateSummary.tryParse('v1 p=idle'), const ProcessStateSummary(phase: ProcessPhase.idle));
    });

    test('model hash is stable FNV-1a 32', () {
      // Reference values for FNV-1a 32-bit.
      expect(ProcessStateSummary.hashModelId(''), '811c9dc5');
      expect(ProcessStateSummary.hashModelId('a'), 'e40c292c');
      expect(ProcessStateSummary.hashModelId('foobar'), 'bf9cf968');
    });
  });

  group('BackupExclusion', () {
    test('delegates to the backend with sidecars by default', () async {
      final b = FakePlatformBackend();
      final paths = await BackupExclusion.exclude('/data/sherpa.db', backend: b);
      expect(paths, ['/data/sherpa.db', '/data/sherpa.db-wal', '/data/sherpa.db-shm']);
      await BackupExclusion.exclude('/data/models', includeSqliteSidecars: false, backend: b);
      expect(b.excluded.last, '/data/models');
    });

    test('is a no-op where unsupported', () async {
      expect(await BackupExclusion.exclude('/x', backend: const UnsupportedPlatformBackend()), isEmpty);
    });
  });
}
