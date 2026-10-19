import 'dart:async';
import 'dart:math';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa_platform/sherpa_platform.dart';
import 'package:sherpa_platform/testing.dart';

void main() {
  late FakePlatformBackend backend;
  setUp(() => backend = FakePlatformBackend());

  BackgroundRunGuard guard({String? prefix}) =>
      BackgroundRunGuard(backend: backend, iosContinuedTaskPrefix: prefix, random: Random(1));

  test('short lease: request shape and Android mode', () async {
    final lease = await guard().begin(title: 'Finishing reply', reason: 'Sherpa is writing');
    final r = backend.begun.single;
    expect(r.title, 'Finishing reply');
    expect(r.reason, 'Sherpa is writing');
    expect(r.long, isFalse);
    expect(r.iosContinuedTaskIdentifier, isNull);
    expect(r.id, hasLength(16));
    expect(lease.id, r.id);
    expect(lease.granted, isTrue);
    expect(lease.isActive, isTrue);
    expect(lease.mode, LeaseMode.androidShortService);
  });

  test('long lease asks for continued processing only with a prefix', () async {
    await guard().begin(title: 't', reason: 'r', long: true);
    expect(backend.begun.last.iosContinuedTaskIdentifier, isNull);
    final lease = await guard(prefix: 'io.github.mihok.sherpa.agentrun').begin(title: 't', reason: 'r', long: true);
    expect(backend.begun.last.iosContinuedTaskIdentifier, 'io.github.mihok.sherpa.agentrun.${lease.id}');
    expect(lease.mode, LeaseMode.androidSpecialUse);
  });

  test('refusal is a value, not an exception', () async {
    backend.onBeginLease = (r) => LeaseResult(
          id: r.id,
          mode: LeaseMode.none,
          granted: false,
          error: 'ForegroundServiceStartNotAllowedException',
          notificationsVisible: false,
        );
    final lease = await guard().begin(title: 't', reason: 'r');
    expect(lease.granted, isFalse);
    expect(lease.isActive, isFalse);
    expect(lease.error, contains('NotAllowed'));
    expect(backend.signalsListened, isFalse, reason: 'nothing to route');
    await lease.end();
    expect(backend.ended, isEmpty);
  });

  test('a throwing platform call becomes a refused lease', () async {
    backend.onBeginLease = (_) => throw StateError('channel-error');
    final lease = await guard().begin(title: 't', reason: 'r');
    expect(lease.granted, isFalse);
    expect(lease.error, contains('channel-error'));
  });

  test('OS expiry completes expired, deactivates and stops routing', () async {
    final g = guard();
    final a = await g.begin(title: 'a', reason: 'r');
    final b = await g.begin(title: 'b', reason: 'r', long: true);
    expect(backend.signalsListened, isTrue);
    backend.emit(SignalKind.leaseExpired, leaseId: a.id, detail: 'timeout');
    expect(await a.expired, 'timeout');
    expect(a.isActive, isFalse);
    expect(b.isActive, isTrue);
    await a.update(text: 'ignored');
    expect(backend.updates, isEmpty);
    await b.end();
    expect(backend.ended, [b.id]);
    expect(backend.signalsListened, isFalse);
  });

  test('an expiry that beats the begin reply still wins', () async {
    backend.onBeginLease = (r) {
      // Native side expired the lease while the reply was in flight.
      backend.emit(SignalKind.leaseExpired, leaseId: r.id, detail: 'expired early');
      return LeaseResult(id: r.id, mode: LeaseMode.iosBackgroundTask, granted: true, notificationsVisible: true);
    };
    final lease = await guard().begin(title: 't', reason: 'r');
    await pumpEventQueue();
    expect(lease.isActive, isFalse);
    expect(await lease.expired, 'expired early');
  });

  test('updates are throttled; the latest values win', () {
    fakeAsync((fa) {
      late BackgroundLease lease;
      unawaited(guard().begin(title: 't', reason: 'r').then((l) => lease = l));
      fa.flushMicrotasks();
      unawaited(lease.update(progress: 0.1, text: 'step 1'));
      unawaited(lease.update(progress: 0.2, text: 'step 2'));
      unawaited(lease.update(progress: 0.3, text: 'step 3'));
      fa.flushMicrotasks();
      expect(backend.updates.map((u) => u.text), ['step 1']);
      fa.elapse(const Duration(seconds: 1));
      expect(backend.updates.map((u) => u.text), ['step 1', 'step 3']);
      expect(backend.updates.last.progress, 0.3);
      fa.elapse(const Duration(seconds: 5));
      expect(backend.updates, hasLength(2), reason: 'nothing pending');
      unawaited(lease.update(progress: 7));
      fa.flushMicrotasks();
      expect(backend.updates.last.progress, 1.0, reason: 'clamped to 0..1');
      unawaited(lease.end());
      fa.flushMicrotasks();
    });
  });

  test('end() drops pending updates and is idempotent', () async {
    final lease = await guard().begin(title: 't', reason: 'r');
    await lease.update(text: 'one');
    await lease.update(text: 'two'); // pending behind the cooldown
    await lease.end();
    await lease.end();
    expect(backend.ended, [lease.id]);
    expect(backend.updates.map((u) => u.text), ['one']);
    expect(lease.isActive, isFalse);
  });

  test('notificationsPermitted passes through', () async {
    backend.notifications = false;
    expect(await guard().notificationsPermitted(), isFalse);
    final lease = await guard().begin(title: 't', reason: 'r');
    expect(lease.notificationsVisible, isFalse);
  });

  test('end() with final words sends them past the throttle, then ends', () async {
    final lease = await guard().begin(title: 't', reason: 'r');
    await lease.update(text: 'working');
    await lease.update(text: 'dropped'); // pending behind the cooldown
    await lease.end(progress: 1, text: 'Reply ready');
    expect(backend.updates.map((u) => u.text), ['working', 'Reply ready']);
    expect(backend.updates.last.progress, 1.0);
    expect(backend.ended, [lease.id]);
    await lease.end(text: 'again');
    expect(backend.updates, hasLength(2), reason: 'idempotent');
  });

  test('permission request and finished notices pass through, never throwing', () async {
    backend
      ..notifications = false
      ..grantOnRequest = true;
    final g = BackgroundRunGuard(backend: backend, androidFinishedChannelName: 'Finished replies');
    expect(await g.requestNotificationsPermission(), isTrue);
    expect(backend.permissionRequests, 1);
    expect(await g.notifyFinished(tag: 's1', title: 'Reply ready', text: 'Open Sherpa to read it.'), isTrue);
    expect(backend.notices.single.androidChannelName, 'Finished replies');
    expect(backend.notices.single.tag, 's1');
    await g.clearFinishedNotices();
    expect(backend.clearedNotices, 1);
    backend.finishedNoticesSupported = false;
    expect(await g.notifyFinished(tag: 's1', title: 't', text: 'x'), isFalse);
    final failing = BackgroundRunGuard(backend: _Throwing());
    expect(await failing.requestNotificationsPermission(), isFalse);
    expect(await failing.notifyFinished(tag: 't', title: 't', text: 't'), isFalse);
    await failing.clearFinishedNotices();
  });

  test('unsupported platforms refuse leases and post nothing', () async {
    const unsupported = UnsupportedPlatformBackend();
    expect(await unsupported.requestNotificationsPermission(), isFalse);
    expect(await unsupported.notifyRunFinished(FinishedNotice(tag: 't', title: 't', text: 't')), isFalse);
  });

  test('unsupported platforms refuse leases', () async {
    final lease = await BackgroundRunGuard(backend: const UnsupportedPlatformBackend()).begin(title: 't', reason: 'r');
    expect(lease.granted, isFalse);
    expect(lease.mode, LeaseMode.none);
  });
}

/// Every notification call fails (a missing plugin, a channel error).
final class _Throwing implements PlatformBackend {
  @override
  dynamic noSuchMethod(Invocation invocation) => Future<Never>.error(StateError('channel-error'));
}
