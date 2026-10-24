import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa/bootstrap.dart' show noRetry;
import 'package:sherpa/features/diagnostics/app_error_ring.dart';
import 'package:sherpa_hub/sherpa_hub.dart';

final _broken = Provider<int>((ref) => throw StateError('/home/alice'), name: 'brokenProvider');

void main() {
  test('Hub failures carry their kind and status as the code, never the message', () {
    expect(AppErrorRing.codeOf(HubNetworkException('secret.host unreachable')), 'hub_network');
    expect(AppErrorRing.codeOf(HubGatedRepoException('x', repo: 'a/b', statusCode: 401)), 'hub_gated_401');
    expect(AppErrorRing.codeOf(HubRateLimitedException('x', statusCode: 429)), 'hub_rate_limited_429');
  });

  test('a caller can name the failed step; codes that are not code-shaped are dropped', () {
    final ring = AppErrorRing()
      ..record(StateError('x'), source: 'onboarding', code: 'download_manager')
      ..record(StateError('x'), code: 'has spaces /home/alice');
    expect(ring.records.first.code, 'download_manager');
    expect(ring.records.last.code, isNull);
  });

  test("a failed provider without a typed code is recorded under the provider's name", () {
    final ring = AppErrorRing();
    final c = ProviderContainer(observers: [AppErrorObserver(ring: ring)], retry: noRetry);
    addTearDown(c.dispose);
    expect(() => c.read(_broken), throwsA(anything));
    expect(ring.records.single.toJson(), allOf(containsPair('source', 'provider'), containsPair('code', 'brokenProvider')));
    expect(ring.records.single.type, 'StateError');
  });
}
