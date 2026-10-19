import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_inference/sherpa_inference.dart';
import 'package:sherpa_inference/testing.dart';

PrefixCacheKey _key(String session, {String model = 'sha256:m', int ctx = 4096, String kv = 'q8_0/q8_0+fa', String lora = ''}) =>
    PrefixCacheKey(sessionId: session, modelId: model, nCtx: ctx, kvLayout: kv, loraSet: lora);

void main() {
  late Directory dir;
  late FakeEngineHost host;
  late FakeClock clock;
  const s = SessionRef(7, 0);

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('prefix_cache_test');
    host = FakeEngineHost(stateBytesPerToken: 100);
    clock = FakeClock();
  });

  tearDown(() => dir.delete(recursive: true));

  PrefixCacheStore make({int budget = 1 << 30, int maxEntries = 12}) =>
      PrefixCacheStore(directory: dir, budgetBytes: budget, maxEntries: maxEntries, clock: clock);

  group('PrefixCacheKey', () {
    test('every component changes the key', () {
      final base = _key('a');
      expect(_key('a').digest, base.digest);
      expect(_key('a'), base);
      for (final other in [_key('b'), _key('a', model: 'sha256:n'), _key('a', ctx: 8192), _key('a', kv: 'f16/f16'), _key('a', lora: 'x@1')]) {
        expect(other.digest, isNot(base.digest));
      }
      expect(PrefixCacheKey.fromJson(base.toJson()), base);
    });
  });

  group('PrefixFingerprint', () {
    test('is a prefix only when the transcript was appended to', () {
      final a = PrefixFingerprint.of(messages: [
        {'role': 'user', 'content': 'hi'},
      ]);
      final b = PrefixFingerprint.of(messages: [
        {'role': 'user', 'content': 'hi'},
        {'role': 'assistant', 'content': 'yo'},
      ]);
      final edited = PrefixFingerprint.of(messages: [
        {'role': 'user', 'content': 'hey'},
        {'role': 'assistant', 'content': 'yo'},
      ]);
      final otherTools = PrefixFingerprint.of(messages: [
        {'role': 'user', 'content': 'hi'},
      ], tools: [
        {'name': 'x'},
      ]);
      expect(PrefixFingerprint.isPrefix(a, b), isTrue);
      expect(PrefixFingerprint.isPrefix(b, a), isFalse);
      expect(PrefixFingerprint.isPrefix(a, edited), isFalse);
      expect(PrefixFingerprint.isPrefix(a, otherTools), isFalse, reason: 'the tool block is part of the prefix');
    });
  });

  group('PrefixCacheStore', () {
    test('save → restore round trip, and the index survives a reopen', () async {
      host.sessionTokens[s.id] = 120;
      final store = make();
      final e = await store.save(host, s, _key('a'), ['t', 'm1']);
      expect(e, isNotNull);
      expect(e!.bytes, greaterThan(12000));
      expect(store.totalBytes, e.bytes);
      final reopened = make();
      await reopened.open();
      expect(reopened.entries.single.key, _key('a'));
      host.sessionTokens[s.id] = 0;
      clock.advance(const Duration(minutes: 1));
      final r = await reopened.restore(host, s, _key('a'), ['t', 'm1', 'm2']);
      expect(r.outcome, PrefixRestoreOutcome.restored);
      expect(r.tokens, 120);
      expect(r.entry!.lastUsedAt.isAfter(e.lastUsedAt), isTrue);
      expect((await reopened.restore(host, s, _key('zzz'), ['t'])).outcome, PrefixRestoreOutcome.notFound);
    });

    test('a changed transcript invalidates (and deletes) the entry', () async {
      host.sessionTokens[s.id] = 10;
      final store = make();
      final e = await store.save(host, s, _key('a'), ['t', 'm1']);
      final r = await store.restore(host, s, _key('a'), ['t', 'm1-edited']);
      expect(r.outcome, PrefixRestoreOutcome.invalidated);
      expect(store.entries, isEmpty);
      expect(await File('${dir.path}/${e!.fileName}').exists(), isFalse);
    });

    test('an engine mismatch drops the file', () async {
      host.sessionTokens[s.id] = 10;
      final store = make();
      await store.save(host, s, _key('a'), ['t']);
      host.nextLoadStateError = const EngineException(-12, 'state file belongs to another model');
      final r = await store.restore(host, s, _key('a'), ['t']);
      expect(r.outcome, PrefixRestoreOutcome.mismatch);
      expect(store.entries, isEmpty);
    });

    test('LRU eviction keeps the budget and the entry count', () async {
      host.sessionTokens[s.id] = 100; // ~10 KB per file
      final store = make(budget: 35000, maxEntries: 3);
      for (final id in ['a', 'b', 'c']) {
        await store.save(host, s, _key(id), ['t']);
        clock.advance(const Duration(seconds: 1));
      }
      expect(store.entries.map((e) => e.key.sessionId), ['a', 'b', 'c']);
      // Touch 'a' so 'b' becomes the least recently used.
      await store.restore(host, s, _key('a'), ['t']);
      clock.advance(const Duration(seconds: 1));
      await store.save(host, s, _key('d'), ['t']);
      expect(store.entries.map((e) => e.key.sessionId).toSet(), {'a', 'c', 'd'});
      expect(store.totalBytes, lessThanOrEqualTo(35000));
      final files = dir.listSync().whereType<File>().map((f) => f.uri.pathSegments.last).where((n) => n.endsWith('.kv'));
      expect(files, hasLength(3));
    });

    test('a state larger than half the budget is not kept', () async {
      host.sessionTokens[s.id] = 1000; // ~100 KB
      final store = make(budget: 150000);
      expect(await store.save(host, s, _key('big'), ['t']), isNull);
      expect(store.entries, isEmpty);
      expect(dir.listSync().whereType<File>().where((f) => f.path.endsWith('.kv')), isEmpty);
    });

    test('open() removes files the index does not know', () async {
      await dir.create(recursive: true);
      await File('${dir.path}/orphan.kv').writeAsString('x');
      await File('${dir.path}/half-written.kv.tmp').writeAsString('x');
      final store = make();
      await store.open();
      expect(dir.listSync().whereType<File>(), isEmpty);
    });

    test('invalidateSession and clear', () async {
      host.sessionTokens[s.id] = 5;
      final store = make();
      await store.save(host, s, _key('a'), ['t']);
      await store.save(host, s, _key('a', ctx: 8192), ['t']);
      await store.save(host, s, _key('b'), ['t']);
      await store.invalidateSession('a');
      expect(store.entries.map((e) => e.key.sessionId), ['b']);
      await store.clear();
      expect(store.entries, isEmpty);
      expect(PrefixCacheStore.defaultBudgetBytes, 1024 * 1024 * 1024);
    });
  });
}
