import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_litert/sherpa_litert.dart';
import 'package:sherpa_litert/testing.dart';

import 'support.dart';

void main() {
  final mapper = LiteRtRequestMapper(
    providerId: 'litert_lm',
    spec: const LiteRtModelSpec(id: 'gemma', path: '/m/g.litertlm'),
    info: LiteRtModelInfo.fromMsg(FakeLiteRtBackend.modelInfo()),
  );
  MappedLiteRtTurn turn(List<Message> messages, {String? system = 'You are Sherpa.'}) =>
      mapper.map(request(messages, system: system));
  String replyKey(String text) => LiteRtRequestMapper.keyOf(mapper.assistantMessage(text, const [], prompted: false)!);

  final u1 = user('Hi');
  final a1 = assistant('Hello!');
  final u2 = user('How are you?');

  test('first request builds; an appended turn reuses; the committed prefix is history + tail + reply', () {
    final cache = ConversationCache();
    final t1 = turn([u1]);
    final p1 = cache.plan(sessionKey: 's', modelId: 'gemma', turn: t1);
    expect(p1, isA<RebuildConversation>().having((p) => p.reason, 'reason', RebuildReason.fresh));
    cache.opened(sessionKey: 's', conversationId: p1.conversationId, modelId: 'gemma', turn: t1);
    cache.commit(sessionKey: 's', turn: t1, replyKey: replyKey('Hello!'));
    expect(cache.committedKeys('s'), hasLength(2));

    final t2 = turn([u1, a1, u2]);
    final p2 = cache.plan(sessionKey: 's', modelId: 'gemma', turn: t2);
    expect(p2, isA<ReuseConversation>());
    expect(p2.conversationId, p1.conversationId);
  });

  ConversationCache warm() {
    final cache = ConversationCache();
    final t1 = turn([u1]);
    final p = cache.plan(sessionKey: 's', modelId: 'gemma', turn: t1);
    cache.opened(sessionKey: 's', conversationId: p.conversationId, modelId: 'gemma', turn: t1);
    cache.commit(sessionKey: 's', turn: t1, replyKey: replyKey('Hello!'));
    return cache;
  }

  RebuildReason? reasonFor(ConversationCache cache, MappedLiteRtTurn t, {String modelId = 'gemma'}) {
    final p = cache.plan(sessionKey: 's', modelId: modelId, turn: t);
    return p is RebuildConversation ? p.reason : null;
  }

  test('an edited earlier message (branch) rebuilds', () {
    expect(reasonFor(warm(), turn([user('Hi there'), a1, u2])), RebuildReason.historyDiverged);
  });

  test('a retry of the last reply (same prefix, reply dropped) rebuilds', () {
    expect(reasonFor(warm(), turn([u1])), RebuildReason.historyDiverged);
  });

  test('a reply stored differently from how it streamed rebuilds', () {
    expect(reasonFor(warm(), turn([u1, assistant('Hello! (edited)'), u2])), RebuildReason.historyDiverged);
  });

  test('a changed system prompt or tool list rebuilds (fixed at creation)', () {
    expect(reasonFor(warm(), turn([u1, a1, u2], system: 'Other')), RebuildReason.configChanged);
    final withTools = mapper.map(request([u1, a1, u2], tools: [weatherTool]));
    expect(reasonFor(warm(), withTools), RebuildReason.configChanged);
  });

  test('another model rebuilds', () {
    expect(reasonFor(warm(), turn([u1, a1, u2]), modelId: 'qwen'), RebuildReason.modelChanged);
  });

  test('an interrupted turn (cancel/pause/error) rebuilds; so does a continue nudge', () {
    final cache = warm()..invalidate('s');
    expect(reasonFor(cache, turn([u1, a1, u2])), RebuildReason.interrupted);

    final c2 = warm();
    final cont = turn([u1, a1, u2, assistant('I am', finishReason: 'pause')]);
    c2.commit(sessionKey: 's', turn: cont, replyKey: replyKey(' fine.'));
    expect(reasonFor(c2, turn([u1, a1, u2, assistant('I am fine.'), user('Great')])), RebuildReason.interrupted);
  });

  test('maxLive bounds open conversations (LRU eviction)', () {
    final cache = ConversationCache(maxLive: 2);
    String open(String session) {
      final t = turn([user('x $session')]);
      final p = cache.plan(sessionKey: session, modelId: 'gemma', turn: t) as RebuildConversation;
      cache.opened(sessionKey: session, conversationId: p.conversationId, modelId: 'gemma', turn: t);
      return p.conversationId;
    }

    final a = open('a');
    open('b');
    final t = turn([user('x c')]);
    final p = cache.plan(sessionKey: 'c', modelId: 'gemma', turn: t) as RebuildConversation;
    expect(p.close, [a]);
    expect(cache.liveSessions, ['b']);
  });

  test('with one live conversation, switching chats evicts the other', () {
    final cache = warm();
    final p = cache.plan(sessionKey: 'other', modelId: 'gemma', turn: turn([user('yo')])) as RebuildConversation;
    expect(p.close, hasLength(1));
    expect(p.reason, RebuildReason.fresh);
  });

  test('clear (engine released) forgets everything', () {
    final cache = warm()..clear();
    expect(reasonFor(cache, turn([u1, a1, u2])), RebuildReason.fresh);
  });
}
