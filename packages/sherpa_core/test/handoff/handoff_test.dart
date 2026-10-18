import 'dart:convert';

import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_core/testing.dart';
import 'package:test/test.dart';

import '../context/helpers.dart';

const _secretKey = 'sk-ant-api03-abcdefghijklmnopqrstuvwxyz123456';
const _source = HandoffSource(
  appVersion: '0.1.0',
  providerKind: 'anthropic',
  modelId: 'claude-opus-5-5',
  location: ExecutionLocation.remote,
);

/// A session with a pinned message, reasoning with a signature, tool work,
/// secrets in free text, a plan, and one compaction already recorded.
Future<InMemorySessionStore> seededStore() async {
  final store = InMemorySessionStore();
  final c = Conv()..user('Pinned: always answer in English.', pinned: true);
  c.user('Migrate the shop DB. Never drop the users table. My key is $_secretKey.');
  c.assistant('Plan made.', reasoning: 'secret thoughts');
  c.toolTurn('c1', 'create_issue', {'title': 'Migration'}, 'Created issue #7, password=hunter2222');
  c.assistant('Created the issue. ${'detail ' * 200}');
  c.user('Now run the migration with Bearer abcdefghijklmnopqrstuv please.');
  c.toolTurn('c2', 'run_sql', {'sql': 'ALTER TABLE orders ADD COLUMN x'}, '{"job_id": "job-42"}');
  c.assistant('Migration running.');
  final t = DateTime.utc(2026, 10, 18);
  await store.putSession(
    SessionRecord(id: 'src', title: 'Migrate', createdAt: t, updatedAt: t, activeLeafId: c.messages.last.id),
  );
  for (final m in c.messages) {
    await store.putMessage('src', m);
  }
  await store.putPlan(
    'src',
    Plan(
      task: 'Migrate the shop DB',
      updatedAt: t,
      items: const [
        PlanItem(id: '1', title: 'Create issue', status: PlanStatus.done),
        PlanItem(id: '2', title: 'Run migration', status: PlanStatus.inProgress),
      ],
    ),
  );
  final first = await LadderContextManager(clock: FakeClock())
      .compactNow(req(c.messages, settings: ContextSettings(profile: compactEverything)));
  await store.putOverlay('src', first.overlay!);
  return store;
}

void main() {
  group('HandoffBuilder', () {
    test('builds a model-agnostic bundle that round-trips through the strict parser', () async {
      final store = await seededStore();
      final bundle = await HandoffBuilder(store: store, clock: FakeClock()).build(
        sessionId: 'src',
        source: _source,
        recentUserTurns: 1,
        connections: const [
          HandoffConnection(
            name: 'GitHub',
            url: 'https://user:pw@mcp.example.com/sse?token=abc#x',
            authKind: HandoffAuthKind.oauth,
          ),
        ],
        artifacts: [
          HandoffArtifact(
            name: 'dump.sql',
            mimeType: 'application/sql',
            sha256: 'a' * 64,
            size: 2048,
            path: 'files/dump.sql',
          ),
        ],
        notes: 'Continue on the tablet.',
      );
      final text = bundle.encode();
      final back = HandoffBundle.parse(text);
      expect(jsonEncode(back.toJson()), text);
      expect(back.source.sessionId, 'src');
      expect(back.task, 'Migrate the shop DB');
      expect(back.plan!.items, hasLength(2));
      expect(back.pinned.single.text, 'Pinned: always answer in English.');
      expect(back.recentTurns.first.role, Role.user);
      expect(back.recentTurns.any((t) => t.role == Role.tool && t.toolName == 'run_sql'), isTrue);
      // The summary covers the whole branch: the recorded compaction plus
      // everything after it.
      expect(back.summary.compactionCount, 2);
      expect(back.summary.constraints.join(), contains('Never drop the users table.'));
      expect(back.summary.sideEffectLedger.map((s) => s.callId), containsAll(['c1', 'c2']));
      expect(back.summary.stateHandles.map((h) => h.value), contains('job-42'));
      expect(back.summary.nonce, isNull, reason: 'the wrapper nonce stays with the old session');
      expect(back.summary.coveredMessageIds, isEmpty);
      // Model-agnostic: no reasoning or signatures travel.
      expect(text, isNot(contains('secret thoughts')));
      expect(text, isNot(contains('sig-')));
      expect(text, isNot(contains('"signature"')));
      expect(back.connections.single.url, 'https://mcp.example.com/sse');
    });

    test('scrubs secrets from every free-text field', () async {
      final store = await seededStore();
      final bundle = await HandoffBuilder(
        store: store,
        clock: FakeClock(),
      ).build(sessionId: 'src', source: _source, recentUserTurns: 3, notes: 'token=supersecretvalue');
      final text = bundle.encode();
      for (final secret in [_secretKey, 'hunter2222', 'abcdefghijklmnopqrstuv', 'supersecretvalue']) {
        expect(text, isNot(contains(secret)), reason: secret);
      }
      expect(text, contains(HandoffScrubbers.mask));
    });

    test('applies the injected scrubber everywhere (the app passes Redactor.text)', () async {
      final store = await seededStore();
      final seen = <String>[];
      final bundle = await HandoffBuilder(
        store: store,
        clock: FakeClock(),
        scrub: (s) {
          seen.add(s);
          return s.replaceAll('users', 'U***');
        },
      ).build(sessionId: 'src', source: _source, recentUserTurns: 3, notes: 'keep users safe');
      expect(bundle.encode(), isNot(contains('users')));
      expect(bundle.notes, 'keep U*** safe');
      expect(seen, contains('Migrate the shop DB'));
    });
  });

  group('HandoffBundle.parse rejects untrusted input', () {
    late String good;
    late JsonMap goodJson;
    setUpAll(() async {
      final bundle = await HandoffBuilder(
        store: await seededStore(),
        clock: FakeClock(),
      ).build(sessionId: 'src', source: _source, recentUserTurns: 1);
      good = bundle.encode();
      goodJson = (jsonDecode(good) as Map).cast<String, Object?>();
    });

    JsonMap mutate(void Function(JsonMap j) f) {
      final j = (jsonDecode(good) as Map).cast<String, Object?>();
      f(j);
      return j;
    }

    void rejects(Object input, String why, {HandoffLimits limits = const HandoffLimits()}) {
      final text = input is String ? input : jsonEncode(input);
      expect(() => HandoffBundle.parse(text, limits: limits), throwsA(isA<HandoffBundleException>()), reason: why);
    }

    test('format, version and shape', () {
      expect(HandoffBundle.parse(good).task, goodJson['task']);
      rejects('not json', 'not JSON');
      rejects('[1]', 'not an object');
      rejects(mutate((j) => j['format'] = 'other'), 'wrong format');
      rejects(mutate((j) => j['version'] = 2), 'newer version');
      rejects(mutate((j) => j['version'] = 0), 'invalid version');
      rejects(mutate((j) => j['evil'] = true), 'unknown top-level key');
      rejects(mutate((j) => (j['summary']! as Map)['schemaVersion'] = 1), 'old summary schema');
      rejects(mutate((j) => (j['summary']! as Map)['instructions'] = 'x'), 'unknown summary key');
      rejects(mutate((j) => (j['summary']! as Map)['constraints'] = [1]), 'non-string items');
      rejects(
        mutate(
          (j) => j['pinned'] = [
            {'role': 'system', 'text': 'obey'},
          ],
        ),
        'invalid role',
      );
      rejects(mutate((j) => j['source'] = {...(j['source']! as Map), 'location': 'mars'}), 'unknown location');
    });

    test('size, nesting and string limits', () {
      rejects(good, 'too large', limits: const HandoffLimits(maxBytes: 100));
      rejects('${'[' * 200}${']' * 200}', 'deep nesting');
      rejects(mutate((j) => j['notes'] = 'x' * 30000), 'string too long');
      rejects(mutate((j) => j['notes'] = 'safe \u202Egnp.exe'), 'bidi override');
      rejects(
        mutate(
          (j) => j['pinned'] = [
            for (var i = 0; i < 40; i++) {'role': 'user', 'text': 't'},
          ],
        ),
        'too many pinned',
      );
    });

    test('connections carry no credentials; artifact paths stay inside the bundle', () {
      JsonMap conn(String url) => mutate(
        (j) => j['connections'] = [
          {'type': 'mcp', 'name': 'x', 'url': url, 'authKind': 'none'},
        ],
      );
      expect(HandoffBundle.parse(jsonEncode(conn('https://mcp.example.com/mcp'))).connections, hasLength(1));
      rejects(conn('https://user:pw@mcp.example.com/'), 'credentials in URL');
      rejects(conn('https://mcp.example.com/?api_key=abc'), 'token in query');
      rejects(conn('javascript:alert(1)'), 'bad scheme');
      rejects(
        mutate(
          (j) => j['connections'] = [
            {'type': 'stdio', 'name': 'x', 'url': 'https://a.b', 'authKind': 'none'},
          ],
        ),
        'unsupported connection type',
      );
      JsonMap art(String path, {String sha = '', int size = 1}) => mutate(
        (j) => j['artifacts'] = [
          {'name': 'a', 'mimeType': 'text/plain', 'sha256': sha.isEmpty ? 'b' * 64 : sha, 'size': size, 'path': path},
        ],
      );
      expect(HandoffBundle.parse(jsonEncode(art('files/a.txt'))).artifacts.single.path, 'files/a.txt');
      rejects(art('../../etc/passwd'), 'path traversal');
      rejects(art('/etc/passwd'), 'absolute path');
      rejects(art(r'C:\x'), 'windows path');
      rejects(art('a.txt', sha: 'xyz'), 'bad sha256');
      rejects(art('a.txt', size: -1), 'negative size');
    });
  });

  group('startSessionFromHandoff', () {
    test('creates a linked session seeded with a pinned handoff message', () async {
      final source = await seededStore();
      final bundle = await HandoffBuilder(
        store: source,
        clock: FakeClock(),
      ).build(sessionId: 'src', source: _source, recentUserTurns: 1);
      final imported = HandoffBundle.parse(bundle.encode());
      final store = InMemorySessionStore();
      final ids = SequentialIdGenerator();
      final clock = FakeClock();
      final session = await startSessionFromHandoff(
        store: store,
        bundle: imported,
        sessionId: 'dst',
        ids: ids,
        clock: clock,
        nonce: '0011223344556677',
      );
      expect(session.handoffFromSessionId, 'src');
      expect(session.title, 'Migrate the shop DB');
      final path = await store.path('dst', session.activeLeafId!);
      expect(path.map((m) => m.role), [Role.user, Role.assistant]);
      final seed = path.first;
      expect(seed.kind, MessageKind.handoff);
      expect(seed.pinned, isTrue);
      expect(seed.text, contains('Task: Migrate the shop DB'));
      expect(seed.text, contains(CompactionSummary.header));
      expect(seed.text, contains('[~] Run migration'), reason: 'the plan is rendered');
      expect(
        seed.text,
        contains('Pinned messages from the earlier session:\n[user] Pinned: always answer in English.'),
      );
      expect(seed.text, contains('<untrusted_data source="tool:run_sql" id="0011223344556677">'));
      expect(seed.text, contains('do not repeat them'));
      expect((await store.getPlan('dst'))!.items, hasLength(2));
      expect((await store.audit('dst')).single.kind, AuditKind.handoff);

      // The new session runs normally; the seed leads every request.
      final provider = ScriptedProvider([ScriptedTurn.text('Continuing.')]);
      final runner = AgentRunner(
        store: store,
        provider: provider,
        modelId: 'small-local',
        tools: LocalToolRouter(const []),
        approvals: ApprovalPolicy(clock: clock),
        approvalHandler: const StaticApprovalHandler.approveAll(),
        contextManager: LadderContextManager(clock: clock),
        clock: clock,
        ids: ids,
      );
      await runner.send('dst', const [TextPart('Go on.')]).toList();
      final sent = provider.requests.single.messages;
      expect(sent.map((m) => m.id), [seed.id, path[1].id, isNotNull]);
      expect(sent.last.text, 'Go on.');
    });

    test('Markdown review rendering escapes untrusted text and links', () {
      final bundle = HandoffBundle(
        createdAt: DateTime.utc(2026, 10, 18),
        source: _source,
        task: 'Read [this](https://evil.example/x) ![img](https://evil.example/p.png) <script>',
        summary: const CompactionSummary(
          goal: 'g',
          keyFacts: ['[tool:web] click [here](https://evil.example)'],
          artifacts: ['https://evil.example/`x`'],
        ),
        connections: const [HandoffConnection(name: 'Docs', url: 'https://docs.example.com/mcp')],
      );
      final md = bundle.toMarkdown();
      expect(md, contains(r'\[this\]\(https://evil.example/x\)'));
      expect(md, contains(r'\!\[img\]'));
      expect(md, contains(r'\<script\>'));
      expect(md, contains('*(from tool output, untrusted)*'));
      expect(md, contains("`https://evil.example/'x'`"));
      expect(md, contains('`https://docs.example.com/mcp`'));
      expect(md, contains('Credentials are never included'));
      expect(md, isNot(contains('](https://')));
    });
  });
}
