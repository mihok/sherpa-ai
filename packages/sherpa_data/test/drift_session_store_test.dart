import 'dart:async';

import 'package:drift/drift.dart' show Variable;
import 'package:sherpa_data/sherpa_data.dart';
import 'package:sqlite3/sqlite3.dart' show SqliteException;
import 'package:test/test.dart';

import 'support/fixtures.dart';
import 'support/harnesses.dart';

// Behaviour specific to the Drift store and its schema. What every
// SessionStore must do lives in support/session_store_contract.dart.

Future<Object?> pragma(SherpaDatabase db, String name) async =>
    (await db.customSelect('PRAGMA $name').getSingle()).data.values.single;

Future<String> queryPlan(SherpaDatabase db, String sql, List<String> args) async => [
      for (final r in await db
          .customSelect('EXPLAIN QUERY PLAN $sql', variables: [for (final a in args) Variable<String>(a)])
          .get())
        r.read<String>('detail'),
    ].join('\n');

void main() {
  late SherpaDatabase db;
  late DriftSessionStore store;

  setUp(() async {
    db = SherpaDatabase.inMemory();
    store = DriftSessionStore(db);
    await store.putSession(session('s1'));
  });
  tearDown(() => db.close());

  group('connection and schema', () {
    test('foreign keys on, FULL sync; WAL on files', () async {
      expect(await pragma(db, 'foreign_keys'), 1);
      expect(await pragma(db, 'synchronous'), 2);
      expect(await pragma(db, 'journal_mode'), 'memory');

      final file = await DriftFileHarness.open();
      addTearDown(file.dispose);
      expect(await pragma(file.db, 'journal_mode'), 'wal');
      expect(await pragma(file.db, 'foreign_keys'), 1);
    });

    test('every table is STRICT', () async {
      final rows = await db.customSelect("SELECT name, strict FROM pragma_table_list WHERE schema = 'main' "
          "AND name NOT LIKE 'sqlite_%'").get();
      expect({for (final r in rows) r.read<String>('name'): r.read<int>('strict')}, {
        'sessions': 1,
        'messages': 1,
        'overlays': 1,
        'plans': 1,
        'checkpoints': 1,
        'audit': 1,
        'documents': 1,
      });
      // STRICT means a wrongly typed value is an error, not a coercion.
      await store.putMessage('s1', msg('m1'));
      await expectLater(
        db.customStatement("UPDATE messages SET created_at = 'yesterday'"),
        throwsA(isA<SqliteException>()),
      );
    });

    test('hot queries are served by indexes', () async {
      expect(
        await queryPlan(db, 'SELECT * FROM messages WHERE session_id = ? AND parent_id = ? '
            'ORDER BY created_at, rowid', ['s1', 'p']),
        allOf(contains('messages_parent_idx'), isNot(contains('TEMP B-TREE'))),
      );
      expect(
        await queryPlan(db, 'SELECT * FROM messages WHERE session_id = ? ORDER BY created_at, rowid', ['s1']),
        allOf(contains('messages_session_created_idx'), isNot(contains('TEMP B-TREE'))),
      );
      expect(
        await queryPlan(db, 'SELECT * FROM audit WHERE session_id = ? ORDER BY at DESC, seq DESC LIMIT 5', ['s1']),
        allOf(contains('audit_session_at_idx'), isNot(contains('TEMP B-TREE'))),
      );
      expect(
        await queryPlan(db, 'SELECT * FROM overlays WHERE session_id = ? ORDER BY created_at, rowid', ['s1']),
        contains('overlays_session_created_idx'),
      );
    });
  });

  group('integrity', () {
    test('rows of an unknown session are rejected (foreign keys)', () async {
      await expectLater(store.putMessage('ghost', msg('m1')), throwsA(isA<SqliteException>()));
      await expectLater(store.putOverlay('ghost', sampleOverlays().first), throwsA(isA<SqliteException>()));
      await expectLater(store.putPlan('ghost', samplePlan()), throwsA(isA<SqliteException>()));
      await expectLater(store.putCheckpoint(sampleCheckpoint('ghost')), throwsA(isA<SqliteException>()));
      await expectLater(store.appendAudit(auditEntry('ghost', 'a1', 1)), throwsA(isA<SqliteException>()));
    });

    test('the audit trail cannot be rewritten', () async {
      await store.appendAudit(auditEntry('s1', 'a1', 1));
      await expectLater(
        db.customStatement("UPDATE audit SET summary = 'tampered'"),
        throwsA(isA<SqliteException>().having((e) => e.message, 'message', contains('append-only'))),
      );
      expect((await store.audit('s1')).single.summary, 'entry a1');
    });

    test('re-appending an audit entry id is a no-op', () async {
      await store.appendAudit(auditEntry('s1', 'a1', 1));
      await store.appendAudit(auditEntry('s1', 'a1', 2));
      await store.putSession(session('s2'));
      await store.appendAudit(auditEntry('s2', 'a1', 3));
      expect([for (final e in await store.audit('s1')) e.at], [at(1)]);
      expect(await store.audit('s2'), hasLength(1));
    });

    test('audit is ordered by time, ties by append order', () async {
      await store.appendAudit(auditEntry('s1', 'late', 9));
      await store.appendAudit(auditEntry('s1', 'tie-1', 5));
      await store.appendAudit(auditEntry('s1', 'tie-2', 5));
      await store.appendAudit(auditEntry('s1', 'early', 1));
      expect([for (final e in await store.audit('s1')) e.id], ['early', 'tie-1', 'tie-2', 'late']);
      expect([for (final e in await store.audit('s1', limit: 3)) e.id], ['tie-1', 'tie-2', 'late']);
    });
  });

  group('ordering', () {
    test('same-instant siblings keep insertion order, also after an upsert', () async {
      await store.putMessage('s1', msg('root'));
      for (final id in ['c', 'a', 'b']) {
        await store.putMessage('s1', msg(id, parent: 'root', t: 1));
      }
      await store.putMessage('s1', msg('c', parent: 'root', t: 1, text: 'rewritten'));
      expect([for (final m in await store.children('s1', 'root')) m.id], ['c', 'a', 'b']);
    });

    test('allMessages lists every branch chronologically', () async {
      await store.putMessages('s1', [
        msg('u2', t: 3),
        msg('a1', parent: 'u1', t: 1),
        msg('u1', t: 0),
        msg('a2', parent: 'u1', t: 2),
      ]);
      expect([for (final m in await store.allMessages('s1')) m.id], ['u1', 'a1', 'a2', 'u2']);
    });

    test('putMessages upserts in one transaction', () async {
      await store.putMessages('s1', [msg('m1'), msg('m2', parent: 'm1', t: 1)]);
      await store.putMessages('s1', [msg('m2', parent: 'm1', t: 1, text: 'v2')]);
      expect([for (final m in await store.path('s1', 'm2')) m.text], ['hello', 'v2']);
      await expectLater(store.putMessages('ghost', [msg('x')]), throwsA(anything));
      expect(await store.getMessage('ghost', 'x'), isNull);
    });
  });

  group('long transcripts', () {
    const n = 5000;

    setUp(() => store.putMessages('s1', [
          for (var i = 0; i < n; i++) msg('m$i', parent: i == 0 ? null : 'm${i - 1}', t: i),
        ]));

    test('path follows a $n-message chain in one query', () async {
      final path = await store.path('s1', 'm${n - 1}');
      expect(path, hasLength(n));
      expect(path.first.id, 'm0');
      expect(path.last.id, 'm${n - 1}');
    });

    test('a cycle deep in a long chain is still detected, in bounded time', () async {
      await store.putMessage('s1', msg('m0', parent: 'm${n - 1}'));
      await expectLater(store.path('s1', 'm${n ~/ 2}'), throwsStateError);
    });
  });

  test('watchSessions re-emits after changes', () async {
    final it = StreamIterator(store.watchSessions());
    addTearDown(it.cancel);
    expect(await it.moveNext(), isTrue);
    expect([for (final s in it.current) s.id], ['s1']);
    await store.putSession(session('s2', updated: 5));
    expect(await it.moveNext(), isTrue);
    expect([for (final s in it.current) s.id], ['s2', 's1']);
    await store.putSession(session('s2', updated: 5, archived: true));
    expect(await it.moveNext(), isTrue);
    expect([for (final s in it.current) s.id], ['s1']);
  });
}
