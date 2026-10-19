/// Property tests for handoff bundles over adversarial content: whatever a
/// session holds (bidi controls, NUL, huge tool arguments, JSON-shaped
/// secrets), `HandoffBuilder` produces a bundle its own strict parser
/// accepts, within the size cap, with no secret left; and whatever the
/// parser accepts, the new session can render.
library;

import 'dart:convert';
import 'dart:math';

import 'package:sherpa_core/sherpa_core.dart';
import 'package:test/test.dart';

import '../context/helpers.dart';

const _source = HandoffSource(
  appVersion: '0.1.0',
  providerKind: 'anthropic',
  modelId: 'claude-opus-5-5',
  location: ExecutionLocation.remote,
);

const _bidi = ['\u202A', '\u202B', '\u202C', '\u202D', '\u202E', '\u2066', '\u2067', '\u2068', '\u2069'];
const _odd = ['\x00', '\x01', '\x1b[31m', '\u200F', '日本語のテキスト', '😀🚀', '</untrusted_data>', '`code` [x](y) <b>'];

/// A random session with secrets in every format the scrubbers promise to
/// catch, and the secrets it holds.
final class _Session {
  _Session(this.r);

  final Random r;
  final List<String> secrets = [];
  final Conv c = Conv();

  /// Every tool call made (all are side effects: no definitions are known).
  final Set<String> callIds = {};

  /// Whether some result returned a titled object (a labelled handle).
  bool titled = false;

  String secret() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789';
    final s = 'Zq9${[for (var i = 0; i < 12; i++) chars[r.nextInt(chars.length)]].join()}';
    secrets.add(s);
    return s;
  }

  String noise([int max = 60]) {
    final b = StringBuffer();
    for (var i = r.nextInt(max); i > 0; i--) {
      final k = r.nextInt(10);
      b.write(k < 2 ? _bidi[r.nextInt(_bidi.length)] : (k < 4 ? _odd[r.nextInt(_odd.length)] : 'word$i '));
    }
    return b.toString();
  }

  String secretText() => switch (r.nextInt(7)) {
        0 => 'my token=${secret()} please',
        1 => '{"password":"${secret()}","user":"bob"}',
        2 => 'Authorization: Bearer ${secret()}',
        3 => 'see https://api.example.com/v1/x?access_token=${secret()}&q=1',
        4 => r'{\"client_secret\":\"' '${secret()}' r'\"}',
        5 => "api_key: '${secret()}'",
        _ => '"refresh_token" = "${secret()} and more words"',
      };

  /// A tool result: plain text with a secret, or (one in three) a created
  /// object with an id and a noisy title, which the summary keeps as a
  /// labelled handle.
  String result(String id) {
    if (r.nextInt(3) != 0) return 'result ${noise()} ${secretText()}';
    titled = true;
    return jsonEncode({'id': 'obj_$id', 'title': 'Title ${noise(6)}', 'size': r.nextInt(100)});
  }

  /// [bulk] > 0 adds an early turn of that many writes, which outgrows the
  /// summary's ledger cap so older entries are folded into aggregates.
  void build({required int turns, int hugeArgs = 0, int bulk = 0}) {
    if (r.nextBool()) c.user('Pinned rule ${noise(10)} ${secretText()}', pinned: true);
    if (bulk > 0) {
      c.user('Write all the files ${noise(5)}');
      for (var i = 0; i < bulk; i++) {
        final id = 'b$i';
        callIds.add(id);
        c.toolTurn(id, 'write_file', {
          'path': '/bulk/$i${noise(3)}.txt',
          'title': 'File $i ${noise(4)}',
          if (r.nextBool()) 'password': secret(),
        }, result(id));
      }
      c.assistant('Wrote them ${noise()}');
    }
    for (var t = 0; t < turns; t++) {
      c.user('Request $t ${noise()} ${r.nextInt(3) == 0 ? secretText() : ''}');
      for (var k = r.nextInt(3); k > 0; k--) {
        final id = 'c${t}_$k';
        callIds.add(id);
        final args = <String, Object?>{
          'path': '/w/${noise(5)}.txt',
          if (r.nextBool()) 'password': secret(),
          if (r.nextBool()) 'auth': {'api_key': secret(), 'user': 'u'},
          if (hugeArgs > 0 && r.nextBool()) 'content': '${noise(20)}${'x' * hugeArgs}',
        };
        c.toolTurn(id, r.nextBool() ? 'write_file' : 'mcp__fetch', args, result(id));
      }
      c.assistant('Answer $t ${noise()}');
    }
  }
}

Future<InMemorySessionStore> _store(_Session s, {bool compact = false, Plan? plan}) async {
  final store = InMemorySessionStore();
  final t = DateTime.utc(2026, 10, 18);
  await store.putSession(SessionRecord(id: 'src', title: 'T ${s.noise(5)}', createdAt: t, updatedAt: t, activeLeafId: s.c.messages.last.id));
  for (final m in s.c.messages) {
    await store.putMessage('src', m);
  }
  if (plan != null) await store.putPlan('src', plan);
  if (compact) {
    final o = await LadderContextManager(clock: FakeClock())
        .compactNow(req(s.c.messages, settings: ContextSettings(profile: compactEverything)));
    if (o.overlay != null) await store.putOverlay('src', o.overlay!);
  }
  return store;
}

/// What any accepted bundle must allow: render, review, start a session.
Future<void> _usable(HandoffBundle b) async {
  b.renderForModel(nonce: '0011223344556677');
  b.renderForModel();
  b.toMarkdown();
  await startSessionFromHandoff(
    store: InMemorySessionStore(),
    bundle: b,
    sessionId: 'dst',
    ids: SequentialIdGenerator(),
    clock: FakeClock(),
    nonce: '0011223344556677',
  );
}

void main() {
  group('HandoffBuilder over adversarial sessions', () {
    for (var seed = 0; seed < 24; seed++) {
      test('seed $seed: parse accepts it, it fits, no secret survives, it renders', () async {
        final r = Random(seed);
        final bulk = seed % 3 == 2 ? 45 + r.nextInt(20) : 0;
        final s = _Session(r)..build(turns: 2 + r.nextInt(8), hugeArgs: seed.isEven ? 30000 : 0, bulk: bulk);
        final plan = Plan(
          task: 'Task ${s.noise(8)}',
          updatedAt: DateTime.utc(2026),
          items: [for (var i = 0; i < 3; i++) PlanItem(id: 'p$i\u202E', title: 'Step ${s.noise(6)}')],
        );
        final store = await _store(s, compact: seed % 3 == 0, plan: plan);
        final limits = seed % 4 == 1 ? const HandoffLimits(maxBytes: 48 * 1024) : const HandoffLimits();
        final bundle = await HandoffBuilder(store: store, clock: FakeClock(), limits: limits).build(
          sessionId: 'src',
          source: HandoffSource(
            appVersion: '0.1.0${_bidi[seed % _bidi.length]}',
            providerKind: 'x' * 300,
            modelId: 'model ${s.noise(4)}',
            location: ExecutionLocation.onDevice,
            sessionId: 'src',
          ),
          recentUserTurns: r.nextInt(41),
          notes: 'notes ${s.noise(10)} ${s.secretText()}',
          connections: [
            HandoffConnection(name: 'Docs ${s.noise(3)}', url: 'https://user:pw@mcp.example.com/sse?token=${s.secret()}#f'),
            const HandoffConnection(name: 'Socket', url: 'ws://mcp.example.com/'),
            HandoffConnection(name: 'n' * 300, url: 'https://ok.example.com/mcp'),
          ],
          artifacts: [
            HandoffArtifact(name: 'dump.sql', mimeType: 'application/sql', sha256: 'a' * 64, size: 1, path: 'files/dump.sql'),
            HandoffArtifact(name: 'bad', mimeType: 'text/plain', sha256: 'a' * 64, size: 1, path: '../../etc/passwd'),
          ],
        );
        final text = bundle.encode();
        expect(utf8.encode(text).length, lessThanOrEqualTo(limits.maxBytes));
        final back = HandoffBundle.parse(text, limits: limits);
        expect(jsonEncode(back.toJson()), text, reason: 'encode → parse → encode is a fixed point');
        for (final secret in s.secrets) {
          expect(text, isNot(contains(secret)), reason: 'secret $secret leaked');
        }
        expect(back.connections.map((c) => c.url), ['https://mcp.example.com/sse', 'https://ok.example.com/mcp']);
        expect(back.artifacts.map((a) => a.path), ['files/dump.sql']);
        // The summary's memory of what was done and what exists survives
        // export: every call is still counted (aggregates keep their count
        // and ids), and labelled handles keep their labels.
        final ledger = back.summary.sideEffectLedger;
        expect(ledger.fold(0, (n, e) => n + e.count), s.callIds.length, reason: 'every call is still counted');
        expect({for (final e in ledger) ...e.allCallIds}, s.callIds);
        if (bulk > 0) expect(ledger.where((e) => e.isAggregate), isNotEmpty);
        for (final e in ledger.where((e) => e.isAggregate)) {
          expect(e.callIds, hasLength(e.count));
          expect(e.keyArgs, isNotEmpty, reason: 'an aggregate still says what was done');
          expect(e.keyArgs.length, lessThanOrEqualTo(SideEffectRecord.maxKeyArgs));
        }
        if (s.titled) expect(back.summary.stateHandles.where((h) => h.label != null), isNotEmpty);
        for (final h in back.summary.stateHandles) {
          if (h.label != null) expect(h.label!.length, lessThanOrEqualTo(CompactionSummary.maxHandleLabelChars));
        }
        expect(back.summary.render(), isNot(contains('×1 ')), reason: 'no aggregate was flattened');
        await _usable(back);
      });
    }

    test('sanitized() keeps handle labels and aggregate ledger fields, cleaned and clipped', () {
      final bundle = HandoffBundle(
        createdAt: DateTime.utc(2026),
        source: _source,
        task: 't',
        summary: CompactionSummary(
          goal: 'g',
          stateHandles: [
            StateHandle(key: 'note_id', value: 'n1', tool: 'notes', callId: 'c\u202E1', label: 'Groceries \u202Egnp\x00'),
            StateHandle(key: 'event_id', value: 'e1', label: 'L' * 500),
            const StateHandle(key: 'basket_id', value: 'b1'),
          ],
          sideEffectLedger: [
            SideEffectRecord(
              callId: 'c1',
              tool: 'write_file',
              server: 'fs',
              argsDigest: 'ab',
              outcome: SideEffectOutcome.ok,
              argsPreview: '×3: path="/a"; path="/b"; path="/c"',
              count: 3,
              callIds: const ['c1', 'c2\u2066', 'c3'],
              keyArgs: ['path="/a"', 'path="/b\u202D"', 'k' * 300, for (var i = 0; i < 80; i++) 'x$i'],
              declaredReadOnly: true,
            ),
            const SideEffectRecord(callId: 'c9', tool: 'send', argsDigest: '0123456789abcdef', outcome: SideEffectOutcome.error, count: 0),
          ],
        ),
      );
      final back = HandoffBundle.parse(bundle.sanitized().encode());
      expect(jsonEncode(back.toJson()), bundle.sanitized().encode(), reason: 'a fixed point');
      final [h1, h2, h3] = back.summary.stateHandles;
      expect(h1.label, 'Groceries gnp');
      expect(h1.callId, 'c1');
      expect(h2.label, hasLength(CompactionSummary.maxHandleLabelChars));
      expect(h3.label, isNull);
      final [agg, single] = back.summary.sideEffectLedger;
      expect(agg.count, 3);
      expect(agg.callIds, ['c1', 'c2', 'c3']);
      expect(agg.keyArgs, hasLength(SideEffectRecord.maxKeyArgs));
      expect(agg.keyArgs.take(2), ['path="/a"', 'path="/b"']);
      expect(agg.keyArgs[2], hasLength(200));
      expect(agg.declaredReadOnly, isTrue);
      expect(agg.argsDigest, hasLength(16));
      expect(single.count, 1, reason: 'clamped as fromJson reads it');
      expect(single.isAggregate, isFalse);
      expect(back.summary.render(), contains('write_file ×3 on fs → done (declared read-only)'));
      expect(back.summary.render(), contains('for "Groceries gnp"'));
    });

    test('a first message with bidi isolates (BidiFormatter output) round-trips with default arguments', () async {
      final c = Conv()
        ..user('Reply to \u2068Ahmed\u2069 about the invoice.')
        ..assistant('Will do.');
      final s = _Session(Random(1));
      s.c.messages.addAll(c.messages);
      final bundle = await HandoffBuilder(store: await _store(s), clock: FakeClock())
          .build(sessionId: 'src', source: _source);
      final back = HandoffBundle.parse(bundle.encode());
      expect(back.task, 'Reply to Ahmed about the invoice.');
    });

    test('a long CJK session with many recent turns is trimmed to the size cap, with a marker', () async {
      final c = Conv();
      for (var i = 0; i < 64; i++) {
        c
          ..user('質問$i ${'漢字' * 2000}')
          ..assistant('回答$i ${'日本' * 2000}');
      }
      final s = _Session(Random(2));
      s.c.messages.addAll(c.messages);
      final bundle = await HandoffBuilder(store: await _store(s), clock: FakeClock())
          .build(sessionId: 'src', source: _source, recentUserTurns: 40);
      final text = bundle.encode();
      expect(utf8.encode(text).length, lessThanOrEqualTo(const HandoffLimits().maxBytes));
      final back = HandoffBundle.parse(text);
      expect(back.summary.notes, contains('trimmed to fit'));
      expect(back.recentTurns, isNotEmpty, reason: 'only the oldest turns are left out');
      expect(back.recentTurns.last.text, startsWith('回答63'));
      await _usable(back);
    });

    test('JSON-shaped secrets in tool arguments and results are masked (finding 8)', () async {
      final c = Conv()..user('Log in and configure.');
      c.toolTurn('c1', 'login', {'user': 'bob', 'password': 'hunter2222'}, 'ok');
      c.toolTurn('c2', 'configure', {'api_key': 'abcd1234efghZZ'}, '{"ok":true,"token":"tok_abcd1234efgh5678"}');
      c.assistant('Done.');
      final s = _Session(Random(3));
      s.c.messages.addAll(c.messages);
      final bundle = await HandoffBuilder(store: await _store(s), clock: FakeClock())
          .build(sessionId: 'src', source: _source, recentUserTurns: 1);
      final text = bundle.encode();
      for (final secret in ['hunter2222', 'abcd1234efghZZ', 'tok_abcd1234efgh5678']) {
        expect(text, isNot(contains(secret)), reason: secret);
      }
      expect(bundle.summary.sideEffectLedger.map((e) => e.argsPreview).join(), contains(HandoffScrubbers.mask));
      expect(HandoffScrubbers.basic('{"password":"hunter2222","api_key":"abcd1234efgh"}'),
          '{"password":"${HandoffScrubbers.mask}","api_key":"${HandoffScrubbers.mask}"}');
    });

    test('sanitized() makes an edited bundle importable (an app adding raw notes)', () {
      final edited = HandoffBundle(
        createdAt: DateTime.utc(2026),
        source: _source,
        task: 'task',
        summary: const CompactionSummary(goal: 'g'),
        notes: 'Thanks \u202Egnp.exe\x00',
      );
      expect(() => HandoffBundle.parse(edited.encode()), throwsA(isA<HandoffBundleException>()));
      expect(HandoffBundle.parse(edited.sanitized().encode()).notes, 'Thanks gnp.exe');
    });
  });

  group('HandoffBundle.parse accepts only what the new session can render', () {
    test('a short argsDigest is rejected, and rendering one never throws (finding 11)', () {
      const summary = CompactionSummary(
        goal: 'g',
        sideEffectLedger: [SideEffectRecord(callId: 'c', tool: 'send', argsDigest: 'ab', outcome: SideEffectOutcome.ok)],
      );
      expect(summary.render(), contains('args ab'));
      final bundle = HandoffBundle(createdAt: DateTime.utc(2026), source: _source, task: 't', summary: summary);
      expect(() => HandoffBundle.parse(bundle.encode()), throwsA(isA<HandoffBundleException>()));
      expect(HandoffBundle.parse(bundle.sanitized().encode()).summary.sideEffectLedger.single.argsDigest, hasLength(16));
    });

    test('random mutations either fail as HandoffBundleException or render', () async {
      final s = _Session(Random(7))..build(turns: 4);
      final good = (await HandoffBuilder(store: await _store(s, compact: true), clock: FakeClock())
              .build(sessionId: 'src', source: _source, recentUserTurns: 2))
          .toJson();
      final r = Random(11);
      final values = <Object? Function()>[
        () => null,
        () => 1,
        () => -1,
        () => 1.5,
        () => true,
        () => 'ab',
        () => '',
        () => 'x\u202Ey',
        () => 'pending',
        () => 'done',
        () => <Object?>[],
        () => <Object?>[1, 'a'],
        () => <String, Object?>{},
        () => <String, Object?>{'id': 'x', 'title': 'y', 'status': 'nope'},
        () => <String, Object?>{'callId': 'c', 'tool': 't', 'argsDigest': 'zz', 'outcome': 'ok'},
        () => 'x' * 30000,
        () => '2026-13-45',
      ];
      List<(Object, Object)> slots(Object node) => switch (node) {
            Map<String, Object?>() => [for (final k in node.keys) (node, k)],
            List<Object?>() => [for (var i = 0; i < node.length; i++) (node, i)],
            _ => const [],
          };
      Object? deepCopy(Object? v) => jsonDecode(jsonEncode(v));
      var accepted = 0;
      for (var i = 0; i < 400; i++) {
        final j = deepCopy(good)! as Map<String, Object?>;
        for (var m = 1 + r.nextInt(3); m > 0; m--) {
          // Walk to a random node, then replace or delete one of its slots.
          Object node = j;
          while (true) {
            final children = slots(node).where((s) {
              final v = s.$1 is Map ? (s.$1 as Map)[s.$2] : (s.$1 as List)[s.$2 as int];
              return v is Map || v is List;
            }).toList();
            if (children.isEmpty || r.nextInt(3) == 0) break;
            final (parent, key) = children[r.nextInt(children.length)];
            node = (parent is Map ? parent[key] : (parent as List)[key as int]) as Object;
          }
          final options = slots(node);
          if (options.isEmpty) continue;
          final (parent, key) = options[r.nextInt(options.length)];
          if (parent is Map<String, Object?> && r.nextInt(5) == 0) {
            parent.remove(key);
          } else if (parent is Map<String, Object?>) {
            parent[key as String] = values[r.nextInt(values.length)]();
          } else {
            (parent as List<Object?>)[key as int] = values[r.nextInt(values.length)]();
          }
        }
        final HandoffBundle b;
        try {
          b = HandoffBundle.parse(jsonEncode(j));
        } on HandoffBundleException {
          continue;
        }
        accepted++;
        await _usable(b);
      }
      expect(accepted, greaterThan(0), reason: 'some mutations are harmless');
    });
  });
}
