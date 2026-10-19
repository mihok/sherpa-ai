import 'dart:async';
import 'dart:convert';
import 'dart:io' show IOException;

import 'package:http/http.dart' as http;
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_net/sherpa_net.dart';

import 'error_mapping.dart';
import 'json_read.dart';
import 'stream_guard.dart';

/// Converts a transport-level failure into Sherpa's error model.
///
/// An abort is not a failure: it becomes [CancelledException], which
/// [guardModelStream] turns into `Finish(cancelled)`.
Exception mapTransportError(Object error, {String? providerId}) => switch (error) {
      ProviderException() || CancelledException() => error as Exception,
      http.RequestAbortedException() => const CancelledException('request aborted'),
      TimeoutException() => ProviderException(ProviderErrorKind.timeout, 'Request timed out',
          providerId: providerId, cause: error),
      http.ClientException(:final message) => ProviderException(
          ProviderErrorKind.network, Redactor.text('Network error: $message'),
          providerId: providerId, cause: error),
      IOException() => ProviderException(ProviderErrorKind.network, Redactor.text('Network error: $error'),
          providerId: providerId, cause: error),
      _ => ProviderException(ProviderErrorKind.unknown, Redactor.text('Unexpected error: $error'),
          providerId: providerId, cause: error),
    };

/// Fails [body] with a retryable [ProviderErrorKind.timeout] when it goes
/// quiet: no first chunk within [start] (defaults to [idle]), or no chunk
/// for [idle] after that.
///
/// When the countdown fires, [onTimeout] runs first (callers abort their
/// `AbortableRequest` there, so a half-open socket is torn down instead of
/// left dangling), then the body subscription is cancelled and the error is
/// delivered. The countdown is stopped while the consumer is paused
/// (backpressure is not silence) and whenever the stream ends, fails or is
/// cancelled, so no timer outlives the stream.
Stream<List<int>> withIdleTimeout(
  Stream<List<int>> body, {
  required Duration idle,
  Duration? start,
  required void Function() onTimeout,
  String? providerId,
}) {
  late final StreamController<List<int>> out;
  // Cancelled on timeout and in onCancel; dropped once the body is done.
  // ignore: cancel_subscriptions
  StreamSubscription<List<int>>? sub;
  Timer? timer;
  var started = false;
  var finished = false;

  void stop() {
    timer?.cancel();
    timer = null;
  }

  void fire(Duration waited) {
    timer = null;
    if (finished) return;
    finished = true;
    onTimeout();
    final s = sub;
    sub = null;
    s?.cancel().ignore();
    out.addError(ProviderException(
      ProviderErrorKind.timeout,
      started
          ? 'The server stopped sending data for ${_describe(waited)}; the connection was closed.'
          : 'The server did not start its response within ${_describe(waited)}; the connection was closed.',
      providerId: providerId,
    ));
    unawaited(out.close());
  }

  void arm() {
    stop();
    if (finished) return;
    final wait = started ? idle : (start ?? idle);
    timer = Timer(wait, () => fire(wait));
  }

  out = StreamController<List<int>>(
    onListen: () {
      sub = body.listen(
        (chunk) {
          if (finished) return;
          started = true;
          out.add(chunk);
          if (!out.isPaused) arm();
        },
        onError: (Object e, StackTrace st) {
          if (!finished) out.addError(e, st);
        },
        onDone: () {
          stop();
          if (finished) return;
          finished = true;
          unawaited(out.close());
        },
      );
      arm();
    },
    onPause: () {
      stop();
      sub?.pause();
    },
    onResume: () {
      sub?.resume();
      arm();
    },
    onCancel: () {
      stop();
      finished = true;
      final s = sub;
      sub = null;
      return s?.cancel();
    },
  );
  return out.stream;
}

String _describe(Duration d) =>
    d.inSeconds >= 120 && d.inSeconds % 60 == 0 ? '${d.inMinutes} min' : d.inMilliseconds >= 1000 ? '${d.inSeconds} s' : '${d.inMilliseconds} ms';

/// A response whose headers have arrived but whose body has not been read.
///
/// Keeping the body as a stream is what makes token streaming incremental
/// and lets a paused consumer stop reading the socket.
final class OpenedResponse {
  OpenedResponse._(this.statusCode, this.headers, this._body, this._providerId);

  final int statusCode;

  /// Lower-case header names (as `package:http` reports them).
  final Map<String, String> headers;
  final Stream<List<int>> _body;
  final String? _providerId;

  bool get ok => statusCode >= 200 && statusCode < 300;

  String get contentType => headers['content-type']?.toLowerCase() ?? '';

  bool get isEventStream => contentType.contains('text/event-stream');

  /// Decodes the body as Server-Sent Events. Comment lines (`:` keep-alives,
  /// `: OPENROUTER PROCESSING`) are dropped by [SseDecoder]; transport
  /// failures surface as [ProviderException] / [CancelledException].
  Stream<SseEvent> events() => _body
      .transform(const SseDecoder())
      .handleError((Object e) => throw mapTransportError(e, providerId: _providerId));

  /// Reads at most [maxBytes] of the body as UTF-8 (error bodies, small JSON
  /// documents). The rest is discarded so a hostile server cannot make
  /// Sherpa buffer an unbounded error page.
  Future<String> readText({int maxBytes = 1 << 20}) async {
    final bytes = <int>[];
    try {
      await for (final chunk in _body) {
        final room = maxBytes - bytes.length;
        if (chunk.length >= room) {
          bytes.addAll(chunk.take(room));
          break;
        }
        bytes.addAll(chunk);
      }
    } on Object catch (e) {
      final mapped = mapTransportError(e, providerId: _providerId);
      if (bytes.isEmpty || mapped is CancelledException) throw mapped;
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

}

/// A fully read small response (discovery, model lists).
final class FetchedResponse {
  const FetchedResponse(this.statusCode, this.headers, this.body);

  final int statusCode;
  final Map<String, String> headers;
  final String body;

  bool get ok => statusCode >= 200 && statusCode < 300;

  /// The body as a JSON object, or null.
  JsonMap? get json => tryDecodeObject(body);
}

/// Sends provider HTTP requests over an injected [http.Client] with abort
/// wiring, without buffering streamed bodies.
final class ProviderHttp {
  ProviderHttp({required http.Client client, this.providerId}) : _client = client;

  final http.Client _client;
  final String? providerId;

  /// Sends a request and returns as soon as the response headers arrive.
  ///
  /// [abort] tears the socket down at any point: before the request is
  /// sent, while waiting for headers, or mid-body. [headersTimeout] bounds
  /// only the wait for headers (a reasoning model may legitimately stream
  /// for minutes afterwards). [idleTimeout] bounds the silence between body
  /// chunks (and the wait for the first chunk, by [headersTimeout] when
  /// set): see [withIdleTimeout]; it aborts the request through [abort].
  /// Throws [ProviderException] for transport
  /// failures and [CancelledException] when aborted; HTTP error statuses
  /// are returned, not thrown, so callers can inspect the body (e.g. to
  /// retry without an optional parameter the server rejected).
  ///
  /// Redirects are not followed by default: model APIs do not redirect, and
  /// following one would carry the request (and its credential) to a host
  /// the URL policy never checked.
  Future<OpenedResponse> send({
    required String method,
    required Uri url,
    Map<String, String> headers = const {},
    String? body,
    AbortSignal? abort,
    Duration? headersTimeout,
    Duration? idleTimeout,
    bool followRedirects = false,
  }) async {
    final signal = abort ?? AbortSignal();
    if (signal.isAborted) throw const CancelledException('request aborted');
    final request = http.AbortableRequest(method, url, abortTrigger: signal.future)
      ..followRedirects = followRedirects
      ..headers.addAll(headers);
    if (body != null) request.bodyBytes = utf8.encode(body);
    try {
      var pending = _client.send(request);
      if (headersTimeout != null) {
        pending = pending.timeout(headersTimeout, onTimeout: () {
          signal.abort();
          throw TimeoutException('no response headers within $headersTimeout');
        });
      }
      final response = await pending;
      final body = idleTimeout == null
          ? response.stream
          : withIdleTimeout(
              response.stream,
              idle: idleTimeout,
              start: headersTimeout,
              onTimeout: signal.abort,
              providerId: providerId,
            );
      return OpenedResponse._(response.statusCode, response.headers, body, providerId);
    } on Object catch (e) {
      throw mapTransportError(e, providerId: providerId);
    }
  }

  /// Sends a request and reads the whole (bounded) body within [timeout].
  Future<FetchedResponse> fetch({
    required Uri url,
    String method = 'GET',
    Map<String, String> headers = const {},
    String? body,
    Duration timeout = const Duration(seconds: 10),
    int maxBytes = 8 << 20,
    AbortSignal? abort,
  }) async {
    final signal = AbortSignal();
    final timer = Timer(timeout, signal.abort);
    unawaited(abort?.future.then((_) => signal.abort()));
    try {
      final r = await send(
        method: method,
        url: url,
        headers: headers,
        body: body,
        abort: signal,
        headersTimeout: timeout,
      );
      final text = await r.readText(maxBytes: maxBytes);
      return FetchedResponse(r.statusCode, r.headers, text);
    } on CancelledException {
      if (abort?.isAborted ?? false) rethrow;
      throw ProviderException(ProviderErrorKind.timeout, 'Request to ${Redactor.uri(url)} timed out',
          providerId: providerId);
    } finally {
      timer.cancel();
    }
  }
}

/// Maps a non-2xx [OpenedResponse] to a [ProviderException], reading a
/// bounded slice of its body for the message.
Future<ProviderException> errorFromResponse(OpenedResponse r, {String? providerId, DateTime? now}) async {
  String body;
  try {
    body = await r.readText(maxBytes: 64 * 1024);
  } on Exception {
    body = '';
  }
  return mapHttpError(statusCode: r.statusCode, headers: r.headers, body: body, providerId: providerId, now: now);
}
