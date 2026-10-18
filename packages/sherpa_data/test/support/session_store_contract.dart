import 'dart:typed_data';

import 'package:sherpa_core/sherpa_core.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

/// One store under test plus the means to restart it.
abstract interface class StoreHarness {
  SessionStore get store;

  /// Whether data outlives [reopen] (false for volatile stores).
  bool get persistent;

  /// Closes the store and opens it again on the same storage. [store]
  /// returns the new instance afterwards.
  Future<void> reopen();

  Future<void> dispose();
}

/// The behaviour every [SessionStore] must share. Runs unchanged against
/// the reference `InMemorySessionStore` and every Drift configuration, so
/// the two cannot drift apart.
void sessionStoreContract(String name, Future<StoreHarness> Function() create) {
  group('$name honours the SessionStore contract:', () {
    late StoreHarness h;
    SessionStore store() => h.store;

    setUp(() async => h = await create());
    tearDown(() => h.dispose());

    /// Reopens persistent stores, so every read below is also checked
    /// against what actually reached storage.
    Future<void> maybeReopen() async {
      if (h.persistent) await h.reopen();
    }

    group('sessions', () {
      test('round-trip every field at full precision', () async {
        final s = SessionRecord(
          id: 's1',
          title: 'Trip planning ✈',
          createdAt: DateTime.utc(2026, 1, 2, 3, 4, 5, 6, 7),
          updatedAt: DateTime.utc(2026, 1, 2, 3, 4, 5, 6, 8),
          providerId: 'anthropic',
          modelId: 'claude-x',
          activeLeafId: 'm9',
          systemPrompt: '',
          handoffFromSessionId: 's0',
          archived: true,
          settings: const {
            'tools': ['search', 'plan'],
            'params': {'temperature': 0.2, 'maxTokens': 512},
            'none': null,
          },
        );
        expect(await store().putSession(s), same(s));
        await maybeReopen();
        final back = await store().getSession('s1');
        expect(canon(back!.toJson()), canon(s.toJson()));
        expect(back.createdAt.isUtc, isTrue);
        expect(back.updatedAt, s.updatedAt);
      });

      test('local-time timestamps come back as the same instant in UTC', () async {
        final local = DateTime(2026, 5, 6, 7, 8, 9, 10, 11);
        await store().putSession(SessionRecord(id: 's', title: 't', createdAt: local, updatedAt: local));
        final back = (await store().getSession('s'))!;
        expect(back.createdAt.isUtc, isTrue);
        expect(back.createdAt.isAtSameMomentAs(local), isTrue);
      });

      test('getSession of an unknown id is null', () async {
        expect(await store().getSession('nope'), isNull);
      });

      test('putSession updates in place and keeps the transcript', () async {
        await store().putSession(session('s1'));
        await store().putMessage('s1', msg('m1'));
        await store().putOverlay('s1', sampleOverlays().first);
        await store().putSession(session('s1', title: 'Renamed', updated: 9).copyWith(activeLeafId: 'm1'));
        await maybeReopen();
        final back = (await store().getSession('s1'))!;
        expect(back.title, 'Renamed');
        expect(back.activeLeafId, 'm1');
        expect((await store().getMessage('s1', 'm1'))?.text, 'hello');
        expect(await store().overlays('s1'), hasLength(1));
      });

      test('a field cleared by the update is cleared in storage', () async {
        await store().putSession(SessionRecord(
          id: 's1',
          title: 't',
          createdAt: at(0),
          updatedAt: at(0),
          providerId: 'p',
          settings: const {'a': 1},
        ));
        await store().putSession(SessionRecord(id: 's1', title: 't', createdAt: at(0), updatedAt: at(1)));
        final back = (await store().getSession('s1'))!;
        expect(back.providerId, isNull);
        expect(back.settings, isEmpty);
      });

      test('list newest-updated first and hide archived by default', () async {
        await store().putSession(session('old', updated: 1));
        await store().putSession(session('newest', updated: 3));
        await store().putSession(session('mid', updated: 2));
        await store().putSession(session('archived', updated: 4, archived: true));
        await maybeReopen();
        expect([for (final s in await store().listSessions()) s.id], ['newest', 'mid', 'old']);
        expect(
          [for (final s in await store().listSessions(includeArchived: true)) s.id],
          ['archived', 'newest', 'mid', 'old'],
        );
      });

      test('an empty store lists nothing', () async {
        expect(await store().listSessions(includeArchived: true), isEmpty);
      });
    });

    group('messages', () {
      setUp(() => store().putSession(session('s1')));

      test('getMessage returns what was put, and null for unknown ids', () async {
        await store().putMessage('s1', msg('m1', text: 'hi'));
        expect((await store().getMessage('s1', 'm1'))?.text, 'hi');
        expect(await store().getMessage('s1', 'm2'), isNull);
        expect(await store().getMessage('other', 'm1'), isNull);
      });

      test('putMessage upserts: a streaming draft is rewritten in place', () async {
        await store().putMessage('s1', msg('m1'));
        for (var i = 1; i <= 5; i++) {
          await store().putMessage('s1', msg('m2', parent: 'm1', t: 1, text: 'draft' * i, role: Role.assistant));
        }
        await store().putMessage('s1', msg('m2', parent: 'm1', t: 1, text: 'final', role: Role.assistant));
        await maybeReopen();
        expect((await store().getMessage('s1', 'm2'))?.text, 'final');
        expect(await store().children('s1', 'm1'), hasLength(1));
      });

      test('ids are scoped to their session', () async {
        await store().putSession(session('s2'));
        await store().putMessage('s1', msg('m1', text: 'one'));
        await store().putMessage('s2', msg('m1', text: 'two'));
        expect((await store().getMessage('s1', 'm1'))?.text, 'one');
        expect((await store().getMessage('s2', 'm1'))?.text, 'two');
        expect(await store().children('s1', null), hasLength(1));
      });

      test('path walks root → leaf along parent links', () async {
        await store().putMessage('s1', msg('a', t: 0));
        await store().putMessage('s1', msg('b', parent: 'a', t: 1, role: Role.assistant));
        await store().putMessage('s1', msg('c', parent: 'b', t: 2));
        await store().putMessage('s1', msg('d', parent: 'c', t: 3, role: Role.assistant));
        await maybeReopen();
        expect([for (final m in await store().path('s1', 'd')) m.id], ['a', 'b', 'c', 'd']);
        expect([for (final m in await store().path('s1', 'b')) m.id], ['a', 'b']);
        expect([for (final m in await store().path('s1', 'a')) m.id], ['a']);
      });

      test('path of an unknown leaf is empty', () async {
        expect(await store().path('s1', 'ghost'), isEmpty);
      });

      test('path stops at a missing ancestor', () async {
        await store().putMessage('s1', msg('b', parent: 'missing', t: 1));
        await store().putMessage('s1', msg('c', parent: 'b', t: 2));
        expect([for (final m in await store().path('s1', 'c')) m.id], ['b', 'c']);
      });

      test('path refuses a cycle instead of looping forever', () async {
        await store().putMessage('s1', msg('x', parent: 'y'));
        await store().putMessage('s1', msg('y', parent: 'x', t: 1));
        await store().putMessage('s1', msg('self', parent: 'self', t: 2));
        await expectLater(store().path('s1', 'x'), throwsStateError);
        await expectLater(store().path('s1', 'self'), throwsStateError);
      });

      test('branches: siblings share a parent, each leaf has its own path', () async {
        await store().putMessage('s1', msg('u1', t: 0));
        await store().putMessage('s1', msg('a1', parent: 'u1', t: 1, role: Role.assistant));
        // Retry → sibling reply; edit → sibling user message under the root.
        await store().putMessage('s1', msg('a2', parent: 'u1', t: 2, role: Role.assistant));
        await store().putMessage('s1', msg('u2', t: 3, text: 'edited'));
        await store().putMessage('s1', msg('a3', parent: 'u2', t: 4, role: Role.assistant));
        await maybeReopen();
        expect([for (final m in await store().children('s1', null)) m.id], ['u1', 'u2']);
        expect([for (final m in await store().children('s1', 'u1')) m.id], ['a1', 'a2']);
        expect(await store().children('s1', 'a1'), isEmpty);
        expect([for (final m in await store().path('s1', 'a2')) m.id], ['u1', 'a2']);
        expect([for (final m in await store().path('s1', 'a3')) m.id], ['u2', 'a3']);
      });

      test('children are ordered by createdAt, not by insertion', () async {
        await store().putMessage('s1', msg('root'));
        await store().putMessage('s1', msg('late', parent: 'root', t: 30));
        await store().putMessage('s1', msg('early', parent: 'root', t: 10));
        await store().putMessage('s1', msg('middle', parent: 'root', t: 20));
        expect([for (final m in await store().children('s1', 'root')) m.id], ['early', 'middle', 'late']);
      });

      test('re-parenting by upsert moves the message to its new parent', () async {
        await store().putMessage('s1', msg('p1'));
        await store().putMessage('s1', msg('p2', t: 1));
        await store().putMessage('s1', msg('c', parent: 'p1', t: 2));
        await store().putMessage('s1', msg('c', parent: 'p2', t: 2));
        expect(await store().children('s1', 'p1'), isEmpty);
        expect([for (final m in await store().children('s1', 'p2')) m.id], ['c']);
        expect([for (final m in await store().path('s1', 'c')) m.id], ['p2', 'c']);
      });

      test('every content part type round-trips losslessly on every read path', () async {
        await store().putMessage('s1', msg('root'));
        final rich = richMessage('rich', parent: 'root');
        await store().putMessage('s1', rich);
        await maybeReopen();
        final expected = canon(rich.toJson());
        expect(canon((await store().getMessage('s1', 'rich'))!.toJson()), expected);
        expect(canon((await store().path('s1', 'rich')).last.toJson()), expected);
        expect(canon((await store().children('s1', 'root')).single.toJson()), expected);

        final back = (await store().getMessage('s1', 'rich'))!;
        expect((back.content[1] as ImagePart).data, [0, 1, 2, 254, 255]);
        expect(back.content.last, isA<UnknownPart>());
        expect(back.toolCalls.single.arguments['filters'], {
          'lang': ['en', 'de'],
          'max': 10,
        });
        expect(back.createdAt, rich.createdAt);
        expect(back.kind, MessageKind.summary);
        expect(back.pinned, isTrue);
      });

      test('large messages round-trip (4 MiB text, 1.5 MiB inline image)', () async {
        final text = '0123456789abcdef' * (1 << 18);
        final image = Uint8List.fromList(List.generate(3 << 19, (i) => i % 256));
        final big = Message(
          id: 'big',
          role: Role.tool,
          createdAt: at(1),
          content: [
            ToolResultPart(callId: 'c', toolName: 'dump', content: [TextPart(text)]),
            ImagePart(mimeType: 'image/png', data: image),
          ],
        );
        await store().putMessage('s1', big);
        await maybeReopen();
        final back = (await store().getMessage('s1', 'big'))!;
        expect((back.content.first as ToolResultPart).text, text);
        expect((back.content.last as ImagePart).data, image);
        expect((await store().path('s1', 'big')).single.toolResults.single.text.length, text.length);
      });

      test('interleaved concurrent writes all persist, last write wins', () async {
        final writes = <Future<void>>[];
        const n = 60;
        for (var i = 0; i < n; i++) {
          final parent = i == 0 ? null : 'm${i - 1}';
          writes.add(store().putMessage('s1', msg('m$i', parent: parent, t: i, text: 'draft $i')));
          if (i > 0) {
            final j = i - 1;
            writes.add(store().putMessage('s1', msg('m$j', parent: j == 0 ? null : 'm${j - 1}', t: j, text: 'final $j')));
          }
          writes.add(store().appendAudit(auditEntry('s1', 'a$i', i)));
        }
        writes.add(store().putMessage('s1', msg('m${n - 1}', parent: 'm${n - 2}', t: n - 1, text: 'final ${n - 1}')));
        writes.add(store().putCheckpoint(sampleCheckpoint('s1')));
        await Future.wait(writes);
        await maybeReopen();
        final path = await store().path('s1', 'm${n - 1}');
        expect([for (final m in path) m.text], [for (var i = 0; i < n; i++) 'final $i']);
        expect(await store().audit('s1'), hasLength(n));
        expect(await store().getCheckpoint('s1'), isNotNull);
      });
    });

    group('overlays', () {
      setUp(() => store().putSession(session('s1')));

      test('listed by createdAt and round-trip every overlay type', () async {
        final all = sampleOverlays();
        for (final o in all) {
          await store().putOverlay('s1', o);
        }
        await maybeReopen();
        final back = await store().overlays('s1');
        expect([for (final o in back) o.id], ['o-trunc', 'o-compact', 'o-elide']);
        final byId = {for (final o in all) o.id: canon(o.toJson())};
        for (final o in back) {
          expect(canon(o.toJson()), byId[o.id]);
        }
        expect(back[1], isA<CompactedRange>());
      });

      test('put upserts by id; remove deletes; removing an unknown id is a no-op', () async {
        final [elide, trunc, _] = sampleOverlays();
        await store().putOverlay('s1', elide);
        await store().putOverlay('s1', trunc);
        await store().putOverlay(
          's1',
          ToolOutputElided(
            id: elide.id,
            createdAt: elide.createdAt,
            reason: 'updated',
            tokensSaved: 1,
            messageId: 'm1',
            callId: 'call_1',
            stub: '[gone]',
          ),
        );
        var list = await store().overlays('s1');
        expect(list, hasLength(2));
        expect(list.firstWhere((o) => o.id == elide.id).reason, 'updated');

        await store().removeOverlay('s1', trunc.id);
        await store().removeOverlay('s1', 'never-existed');
        await maybeReopen();
        list = await store().overlays('s1');
        expect([for (final o in list) o.id], [elide.id]);
      });

      test('are scoped to their session', () async {
        await store().putSession(session('s2'));
        await store().putOverlay('s1', sampleOverlays().first);
        expect(await store().overlays('s2'), isEmpty);
        await store().removeOverlay('s2', sampleOverlays().first.id);
        expect(await store().overlays('s1'), hasLength(1));
      });
    });

    group('plan and checkpoint', () {
      setUp(() => store().putSession(session('s1')));

      test('plan: absent, stored, replaced', () async {
        expect(await store().getPlan('s1'), isNull);
        await store().putPlan('s1', samplePlan());
        expect(canon((await store().getPlan('s1'))!.toJson()), canon(samplePlan().toJson()));
        final next = samplePlan(task: 'ship v2', updated: 5);
        await store().putPlan('s1', next);
        await maybeReopen();
        expect(canon((await store().getPlan('s1'))!.toJson()), canon(next.toJson()));
      });

      test('checkpoint: absent, stored, replaced (one per session)', () async {
        await store().putSession(session('s2'));
        expect(await store().getCheckpoint('s1'), isNull);
        final first = sampleCheckpoint('s1');
        await store().putCheckpoint(first);
        expect(canon((await store().getCheckpoint('s1'))!.toJson()), canon(first.toJson()));

        final second = sampleCheckpoint('s1', runId: 'run_2', phase: RunPhase.failed);
        await store().putCheckpoint(second);
        await store().putCheckpoint(sampleCheckpoint('s2', runId: 'other'));
        await maybeReopen();
        final back = (await store().getCheckpoint('s1'))!;
        expect(canon(back.toJson()), canon(second.toJson()));
        expect(back.pendingCalls.map((p) => p.status), [PendingCallStatus.running, PendingCallStatus.approved]);
        expect((await store().getCheckpoint('s2'))!.runId, 'other');
      });
    });

    group('audit', () {
      setUp(() async {
        await store().putSession(session('s1'));
        await store().putSession(session('s2'));
        for (var i = 1; i <= 5; i++) {
          await store().appendAudit(auditEntry('s1', 'a$i', i, kind: AuditKind.values[i]));
        }
        await store().appendAudit(auditEntry('s2', 'x1', 1));
      });

      test('returns the whole trail in chronological order', () async {
        await maybeReopen();
        final all = await store().audit('s1');
        expect([for (final e in all) e.id], ['a1', 'a2', 'a3', 'a4', 'a5']);
        expect(canon(all.first.toJson()), canon(auditEntry('s1', 'a1', 1, kind: AuditKind.values[1]).toJson()));
      });

      test('limit returns the newest N, oldest first', () async {
        expect([for (final e in await store().audit('s1', limit: 2)) e.id], ['a4', 'a5']);
        expect([for (final e in await store().audit('s1', limit: 1)) e.id], ['a5']);
        expect(await store().audit('s1', limit: 0), isEmpty);
        expect(await store().audit('s1', limit: 99), hasLength(5));
        await expectLater(store().audit('s1', limit: -1), throwsRangeError);
      });

      test('is scoped to its session', () async {
        expect([for (final e in await store().audit('s2')) e.id], ['x1']);
        expect(await store().audit('unknown'), isEmpty);
      });
    });

    group('deleteSession', () {
      test('removes the session and everything it owns, and nothing else', () async {
        for (final id in ['s1', 's2']) {
          await store().putSession(session(id));
          await store().putMessage(id, msg('m1'));
          await store().putMessage(id, msg('m2', parent: 'm1', t: 1));
          await store().putOverlay(id, sampleOverlays().first);
          await store().putPlan(id, samplePlan());
          await store().putCheckpoint(sampleCheckpoint(id));
          await store().appendAudit(auditEntry(id, 'a1', 1));
        }
        await store().deleteSession('s1');
        await maybeReopen();

        expect(await store().getSession('s1'), isNull);
        expect(await store().getMessage('s1', 'm1'), isNull);
        expect(await store().path('s1', 'm2'), isEmpty);
        expect(await store().children('s1', null), isEmpty);
        expect(await store().overlays('s1'), isEmpty);
        expect(await store().getPlan('s1'), isNull);
        expect(await store().getCheckpoint('s1'), isNull);
        expect(await store().audit('s1'), isEmpty);

        expect(await store().getSession('s2'), isNotNull);
        expect(await store().path('s2', 'm2'), hasLength(2));
        expect(await store().overlays('s2'), hasLength(1));
        expect(await store().getPlan('s2'), isNotNull);
        expect(await store().getCheckpoint('s2'), isNotNull);
        expect(await store().audit('s2'), hasLength(1));
        expect([for (final s in await store().listSessions()) s.id], ['s2']);
      });

      test('of an unknown id is a no-op', () async {
        await store().putSession(session('s1'));
        await store().deleteSession('ghost');
        expect(await store().listSessions(), hasLength(1));
      });

      test('then re-creating the id starts empty', () async {
        await store().putSession(session('s1'));
        await store().putMessage('s1', msg('m1'));
        await store().deleteSession('s1');
        await store().putSession(session('s1'));
        expect(await store().children('s1', null), isEmpty);
      });
    });
  });
}
