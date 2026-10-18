import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_data/sherpa_data.dart';

import 'session_store_contract.dart';

/// The reference store from sherpa_core.
final class InMemoryHarness implements StoreHarness {
  @override
  final SessionStore store = InMemorySessionStore();

  @override
  bool get persistent => false;

  @override
  Future<void> reopen() async {}

  @override
  Future<void> dispose() async {}
}

/// [DriftSessionStore] on an unencrypted in-memory database.
final class DriftMemoryHarness implements StoreHarness {
  DriftMemoryHarness() : db = SherpaDatabase.inMemory() {
    store = DriftSessionStore(db);
  }

  final SherpaDatabase db;

  @override
  late final SessionStore store;

  @override
  bool get persistent => false;

  @override
  Future<void> reopen() async {}

  @override
  Future<void> dispose() => db.close();
}

/// [DriftSessionStore] on an encrypted file in a temp directory, opened the
/// production way (background isolate, sqlite3mc, raw key).
final class DriftFileHarness implements StoreHarness {
  DriftFileHarness._(this.dir, this.path, this.key, this.background, this.db)
      : store = DriftSessionStore(db);

  static Future<DriftFileHarness> open({bool background = true}) async {
    final dir = await Directory.systemTemp.createTemp('sherpa_data_test_');
    final path = p.join(dir.path, 'sherpa.db');
    final key = generateDatabaseKey();
    final db = await openSherpaDatabase(path: path, key: key, background: background);
    return DriftFileHarness._(dir, path, key, background, db);
  }

  final Directory dir;
  final String path;
  final String key;
  final bool background;
  SherpaDatabase db;

  @override
  SessionStore store;

  @override
  bool get persistent => true;

  @override
  Future<void> reopen() async {
    await db.close();
    db = await openSherpaDatabase(path: path, key: key, background: background);
    store = DriftSessionStore(db);
  }

  @override
  Future<void> dispose() async {
    await db.close();
    await dir.delete(recursive: true);
  }
}

/// A temp directory removed after the test.
Future<Directory> tempDir() => Directory.systemTemp.createTemp('sherpa_data_test_');
