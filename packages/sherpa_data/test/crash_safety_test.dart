import 'dart:async';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:sherpa_data/sherpa_data.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';
import 'support/harnesses.dart';

const int messageCount = 120;

/// The "app process": opens the database, fires interleaved concurrent
/// writes the way the agent loop does (drafts rewritten while later messages
/// arrive, audit and checkpoints in between), reports when every future has
/// completed, then hangs without ever closing the database, until the test
/// kills it.
Future<void> _writer((SendPort, String, String) args) async {
  final (done, path, key) = args;
  final db = await openSherpaDatabase(path: path, key: key, background: false);
  final store = DriftSessionStore(db);
  await store.putSession(session('s1'));

  final writes = <Future<void>>[];
  for (var i = 0; i < messageCount; i++) {
    writes.add(store.putMessage('s1', msg('m$i', parent: i == 0 ? null : 'm${i - 1}', t: i, text: 'draft $i')));
    if (i > 0) {
      final j = i - 1;
      writes.add(store.putMessage('s1', msg('m$j', parent: j == 0 ? null : 'm${j - 1}', t: j, text: 'final $j')));
    }
    writes.add(store.appendAudit(auditEntry('s1', 'a$i', i)));
    writes.add(store.putCheckpoint(sampleCheckpoint('s1', runId: 'run_$i')));
  }
  final last = messageCount - 1;
  writes.add(store.putMessage('s1', msg('m$last', parent: 'm${last - 1}', t: last, text: 'final $last')));
  await Future.wait(writes);

  done.send(true);
  await Completer<void>().future; // never closes `db`
}

void main() {
  test('every write whose future completed survives the writer dying without close', () async {
    final dir = await tempDir();
    addTearDown(() => dir.delete(recursive: true));
    final path = p.join(dir.path, 'sherpa.db');
    final key = generateDatabaseKey();

    final done = ReceivePort();
    final isolate = await Isolate.spawn(_writer, (done.sendPort, path, key));
    await done.first.timeout(const Duration(seconds: 60));

    // While the writer is still alive and has not closed anything, a
    // completely independent connection already sees every write: the
    // futures completed only after SQLite committed.
    final raw = sqlite3.open(path);
    raw.execute("PRAGMA key = 'raw:$key';");
    final finals = raw.select("SELECT count(*) AS n FROM messages WHERE json LIKE '%\"final %'").single['n'];
    expect(finals, messageCount);
    expect(raw.select('SELECT count(*) AS n FROM audit').single['n'], messageCount);
    raw.close();

    // Simulate process death: no close(), no WAL checkpoint. (A native
    // finalizer may still release the handle at some later GC; the check
    // above ran before that could happen.)
    isolate.kill(priority: Isolate.immediate);

    final db = await openSherpaDatabase(path: path, key: key);
    final store = DriftSessionStore(db);
    final path0 = await store.path('s1', 'm${messageCount - 1}');
    expect([for (final m in path0) m.text], [for (var i = 0; i < messageCount; i++) 'final $i']);
    expect(await store.audit('s1'), hasLength(messageCount));
    expect((await store.getCheckpoint('s1'))?.runId, 'run_${messageCount - 1}');
    await db.close();
  });
}
