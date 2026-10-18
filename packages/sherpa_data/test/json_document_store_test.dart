import 'dart:async';

import 'package:path/path.dart' as p;
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_data/sherpa_data.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';
import 'support/harnesses.dart';

const providers = DocumentCollections.providerConfigs;
const prefs = DocumentCollections.preferences;

List<Object?> ids(List<JsonMap> docs) => [for (final d in docs) d['id']];

void main() {
  late SherpaDatabase db;
  late FakeClock clock;
  late JsonDocumentStore docs;

  setUp(() {
    db = SherpaDatabase.inMemory();
    clock = FakeClock(t0);
    docs = JsonDocumentStore(db, clock: clock);
  });
  tearDown(() => db.close());

  test('get of an unknown document is null', () async {
    expect(await docs.get(providers, 'nope'), isNull);
  });

  test('documents round-trip verbatim', () async {
    const doc = {
      'id': 'openai',
      'kind': 'openai_responses',
      'baseUrl': 'https://api.openai.com/v1',
      'quirks': ['no_stream_usage', 'reasoning_field'],
      'limits': {'contextTokens': 400000, 'temperature': 0.7, 'beta': null},
      'enabled': true,
      'label': 'Zürich ☃ 😀',
    };
    await docs.put(providers, 'openai', doc);
    final back = await docs.get(providers, 'openai');
    expect(canon(back), canon(doc));
  });

  test('put replaces, delete removes, deleting twice is fine', () async {
    await docs.put(prefs, 'app', {'theme': 'dark'});
    await docs.put(prefs, 'app', {'theme': 'light', 'onboarded': true});
    expect(await docs.get(prefs, 'app'), {'theme': 'light', 'onboarded': true});
    await docs.delete(prefs, 'app');
    await docs.delete(prefs, 'app');
    expect(await docs.get(prefs, 'app'), isNull);
  });

  test('collections are separate namespaces; list is ordered by id', () async {
    await docs.put(providers, 'b', {'id': 'b'});
    await docs.put(providers, 'a', {'id': 'a'});
    await docs.put(providers, 'c', {'id': 'c'});
    await docs.put(prefs, 'a', {'id': 'pref-a'});
    expect(ids(await docs.list(providers)), ['a', 'b', 'c']);
    expect(ids(await docs.list(prefs)), ['pref-a']);
    expect(await docs.list(DocumentCollections.downloads), isEmpty);
    expect((await docs.get(prefs, 'a'))?['id'], 'pref-a');
  });

  test('touching a document does not reorder the list', () async {
    await docs.put(providers, 'a', {'id': 'a'});
    await docs.put(providers, 'b', {'id': 'b'});
    clock.advance(const Duration(minutes: 1));
    await docs.put(providers, 'a', {'id': 'a', 'v': 2});
    expect(ids(await docs.list(providers)), ['a', 'b']);
  });

  test('updated_at comes from the injected clock', () async {
    clock.advance(const Duration(seconds: 5));
    await docs.put(prefs, 'app', {'x': 1});
    final row = await db.customSelect("SELECT updated_at FROM documents WHERE id = 'app'").getSingle();
    expect(row.read<int>('updated_at'), at(5).microsecondsSinceEpoch);
  });

  test('watch emits the current list, then after each change to that collection only', () async {
    final it = StreamIterator(docs.watch(providers));
    addTearDown(it.cancel);

    expect(await it.moveNext(), isTrue);
    expect(it.current, isEmpty);

    await docs.put(providers, 'a', {'id': 'a'});
    expect(await it.moveNext(), isTrue);
    expect(ids(it.current), ['a']);

    // Writes elsewhere, and a rewrite with identical content, are
    // filtered out: the next emission is the next real change.
    await docs.put(prefs, 'app', {'theme': 'dark'});
    await docs.put(providers, 'a', {'id': 'a'});
    await docs.put(providers, 'b', {'id': 'b'});
    expect(await it.moveNext(), isTrue);
    expect(ids(it.current), ['a', 'b']);

    await docs.put(providers, 'a', {'id': 'a', 'v': 2});
    expect(await it.moveNext(), isTrue);
    expect(it.current.first, {'id': 'a', 'v': 2});

    await docs.delete(providers, 'b');
    expect(await it.moveNext(), isTrue);
    expect(ids(it.current), ['a']);
  });

  test('empty collection or id is rejected', () async {
    await expectLater(docs.put('', 'a', const {}), throwsArgumentError);
    await expectLater(docs.put(prefs, '', const {}), throwsArgumentError);
  });

  test('collection names are distinct', () {
    const all = [
      DocumentCollections.providerConfigs,
      DocumentCollections.preferences,
      DocumentCollections.modelLibrary,
      DocumentCollections.mcpServers,
      DocumentCollections.downloads,
    ];
    expect(all.toSet(), hasLength(all.length));
    expect(all.every((c) => c.isNotEmpty), isTrue);
  });

  test('documents persist in the encrypted file and are independent of sessions', () async {
    final dir = await tempDir();
    addTearDown(() => dir.delete(recursive: true));
    final path = p.join(dir.path, 'sherpa.db');
    final key = generateDatabaseKey();

    var fileDb = await openSherpaDatabase(path: path, key: key);
    await JsonDocumentStore(fileDb).put(DocumentCollections.mcpServers, 'gh', {'id': 'gh', 'url': 'https://x'});
    final sessions = DriftSessionStore(fileDb);
    await sessions.putSession(session('gh'));
    await sessions.deleteSession('gh');
    await fileDb.close();

    fileDb = await openSherpaDatabase(path: path, key: key);
    expect(await JsonDocumentStore(fileDb).get(DocumentCollections.mcpServers, 'gh'), {'id': 'gh', 'url': 'https://x'});
    await fileDb.close();
  });
}
