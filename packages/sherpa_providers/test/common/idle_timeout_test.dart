import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_providers/sherpa_providers.dart';
import 'package:test/test.dart';

import '../support/helpers.dart';

/// Finding 15: a streaming response that goes silent (half-open socket)
/// must fail with a retryable timeout and close the request, not hang.
void main() {
  group('withIdleTimeout', () {
    test('fires after the idle gap, aborts first, and leaves no timer behind', () {
      fakeAsync((async) {
        final body = StreamController<List<int>>();
        var aborted = 0;
        final seen = <Object>[];
        var done = false;
        withIdleTimeout(
          body.stream,
          idle: const Duration(seconds: 90),
          start: const Duration(minutes: 10),
          onTimeout: () => aborted++,
        ).listen(seen.add, onError: seen.add, onDone: () => done = true);

        // Prefill: a long wait for the first chunk is fine.
        async.elapse(const Duration(minutes: 9));
        expect(seen, isEmpty);
        body.add([1]);
        async.elapse(const Duration(seconds: 89));
        body.add([2]);
        async.elapse(const Duration(seconds: 89));
        expect(seen, [
          [1],
          [2],
        ]);
        expect(aborted, 0);

        async.elapse(const Duration(seconds: 2));
        expect(aborted, 1);
        final error = seen.last;
        expect(error, isA<ProviderException>());
        expect((error as ProviderException).kind, ProviderErrorKind.timeout);
        expect(error.isRetryable, isTrue);
        async.flushMicrotasks();
        expect(done, isTrue);
        expect(async.pendingTimers, isEmpty);
        expect(body.hasListener, isFalse, reason: 'the body subscription is cancelled');
        unawaited(body.close());
      });
    });

    test('no first chunk within the start timeout fails too', () {
      fakeAsync((async) {
        final body = StreamController<List<int>>();
        Object? error;
        withIdleTimeout(body.stream, idle: const Duration(seconds: 90), start: const Duration(minutes: 10), onTimeout: () {})
            .listen(null, onError: (Object e) => error = e);
        async.elapse(const Duration(minutes: 10, seconds: 1));
        expect(error, isA<ProviderException>().having((e) => e.kind, 'kind', ProviderErrorKind.timeout));
        expect(async.pendingTimers, isEmpty);
        unawaited(body.close());
      });
    });

    test('a paused consumer is not silence; done and cancel stop the timer', () {
      fakeAsync((async) {
        final body = StreamController<List<int>>();
        Object? error;
        final sub = withIdleTimeout(body.stream, idle: const Duration(seconds: 90), onTimeout: () {})
            .listen(null, onError: (Object e) => error = e);
        sub.pause();
        async.elapse(const Duration(minutes: 30));
        expect(error, isNull);
        expect(async.pendingTimers, isEmpty);
        sub.resume();
        async.elapse(const Duration(seconds: 30));
        unawaited(sub.cancel());
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty);
        expect(error, isNull);

        final body2 = StreamController<List<int>>();
        withIdleTimeout(body2.stream, idle: const Duration(seconds: 90), onTimeout: () {}).listen(null);
        body2
          ..add([1])
          ..close();
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty);
        unawaited(body.close());
      });
    });
  });

  group('providers', () {
    /// A server that sends headers and one chunk, then goes silent without
    /// closing the connection. Records whether the request was aborted.
    (http.Client, Completer<void>) halfOpen(String firstChunk) {
      final aborted = Completer<void>();
      final client = MockClient.streaming((request, body) async {
        await body.drain<void>();
        if (request case http.Abortable(:final abortTrigger?)) {
          unawaited(abortTrigger.then((_) {
            if (!aborted.isCompleted) aborted.complete();
          }));
        }
        // Never closed on purpose: the connection is half-open.
        // ignore: close_sinks
        final out = StreamController<List<int>>()..add(utf8.encode(firstChunk));
        return http.StreamedResponse(out.stream, 200, headers: {'content-type': 'text/event-stream'});
      });
      return (client, aborted);
    }

    void expectTimesOut(ModelProvider provider, Completer<void> aborted, ModelRequest request) {
      fakeAsync((async) {
        final events = <ModelEvent>[];
        Object? error;
        var done = false;
        provider.stream(request).listen(events.add, onError: (Object e) => error = e, onDone: () => done = true);
        async.elapse(const Duration(seconds: 60));
        expect(error, isNull);
        expect(done, isFalse);
        async.elapse(const Duration(seconds: 31));
        async.flushMicrotasks();
        expect(error, isA<ProviderException>().having((e) => e.kind, 'kind', ProviderErrorKind.timeout));
        expect((error! as ProviderException).isRetryable, isTrue);
        expect(aborted.isCompleted, isTrue, reason: 'the AbortableRequest was closed');
        expect(done, isTrue);
        expect(async.pendingTimers, isEmpty, reason: 'no timer leaks');
      });
    }

    test('OpenAI Chat', () {
      final (client, aborted) = halfOpen('data: {"choices":[{"index":0,"delta":{"content":"Hel"}}]}\n\n');
      expectTimesOut(
        OpenAiChatProvider(config: testConfig(mockBase, profile: ServerProfile.openAi), client: client),
        aborted,
        weatherRequest(),
      );
    });

    test('OpenAI Responses', () {
      final (client, aborted) = halfOpen('event: response.created\ndata: {"type":"response.created"}\n\n');
      expectTimesOut(
        OpenAiResponsesProvider(config: testConfig(mockBase, flavor: ApiFlavor.openAiResponses), client: client),
        aborted,
        weatherRequest(model: 'gpt-6-astra'),
      );
    });

    test('Anthropic', () {
      final (client, aborted) = halfOpen('event: ping\ndata: {"type":"ping"}\n\n');
      final config = ProviderConfig(
        id: 'a',
        flavor: ApiFlavor.anthropic,
        displayName: 'Anthropic',
        baseUrl: Uri.parse('http://127.0.0.1:9'),
        allowLocalNetwork: true,
      );
      expectTimesOut(AnthropicProvider(config: config, apiKey: 'k', client: client), aborted, weatherRequest(model: 'claude-opus-5-5'));
    });

    test('the idle timeout is configurable and persisted', () {
      final config = testConfig(mockBase).copyWith(streamIdleTimeout: const Duration(seconds: 300));
      final back = ProviderConfig.fromJson(config.toJson());
      expect(back.streamIdleTimeout, const Duration(seconds: 300));
      expect(back.streamStartTimeout, ProviderConfig.defaultStreamStartTimeout);
      expect(testConfig(mockBase).toJson().containsKey('streamIdleTimeoutSeconds'), isFalse);
      expect(ProviderConfig.defaultStreamIdleTimeout, const Duration(seconds: 90));
    });
  });
}
