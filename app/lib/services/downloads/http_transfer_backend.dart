import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'transfer_backend.dart';

/// [TransferBackend] that runs in the app process over `package:http`.
///
/// It exists for URLs on huggingface.co itself ([TransferRequest.hubOrigin]):
/// small non-LFS files the Hub serves from `/api/resolve-cache` (MLX
/// `config.json`, `tokenizer_config.json`, …), which may need the user's
/// token for gated repos. The token is read from [token] at request time,
/// attached only when the URL is on [hubOrigin], and never stored anywhere
/// — unlike a background_downloader task, whose headers the plugin
/// serializes into SharedPreferences / WorkManager extras (Android) and
/// `taskDescription` / UserDefaults (iOS).
///
/// Trade-off: no OS background continuation. That is acceptable for these
/// files (kilobytes to a few MB); the multi-GB weights come from signed CDN
/// URLs that need no token and stay on the background backend.
///
/// Redirects are followed by hand (at most [maxRedirects]) so the token is
/// dropped the moment a redirect leaves the Hub's origin.
final class InProcessTransferBackend implements TransferBackend {
  InProcessTransferBackend({
    required http.Client client,
    required Future<String?> Function() token,
    Uri? hubOrigin,
    this.maxRedirects = 3,
  })  : _client = client,
        _token = token,
        hubOrigin = hubOrigin ?? Uri.parse('https://huggingface.co');

  final http.Client _client;
  final Future<String?> Function() _token;
  final Uri hubOrigin;
  final int maxRedirects;

  @override
  int get transientBytes => 0;

  @override
  Future<void> recover() async {}

  bool _isHub(Uri u) =>
      u.scheme == hubOrigin.scheme && u.host.toLowerCase() == hubOrigin.host.toLowerCase() && u.port == hubOrigin.port;

  @override
  TransferHandle start(TransferRequest request) => _HttpTransfer(this, request)..run();
}

final class _HttpTransfer implements TransferHandle {
  _HttpTransfer(this._b, this._r);

  final InProcessTransferBackend _b;
  final TransferRequest _r;
  final StreamController<TransferProgress> _progress = StreamController.broadcast();
  final Completer<TransferOutcome> _done = Completer();
  final Completer<void> _abort = Completer();
  bool _stopped = false;

  @override
  Stream<TransferProgress> get progress => _progress.stream;

  @override
  Future<TransferOutcome> get done => _done.future;

  @override
  Future<void> stop() async {
    _stopped = true;
    if (!_abort.isCompleted) _abort.complete();
  }

  void _finish(TransferOutcome o) {
    if (!_done.isCompleted) _done.complete(o);
    unawaited(_progress.close());
  }

  Future<void> run() async {
    try {
      var url = _r.url;
      http.StreamedResponse? resp;
      for (var hop = 0; hop <= _b.maxRedirects; hop++) {
        final req = http.AbortableRequest('GET', url, abortTrigger: _abort.future)
          ..followRedirects = false
          ..headers.addAll(_r.headers)
          ..headers['accept-encoding'] = 'identity';
        if (_r.offset > 0) req.headers['range'] = 'bytes=${_r.offset}-';
        if (_b._isHub(url)) {
          final t = await _b._token();
          if (t != null && t.isNotEmpty) req.headers['authorization'] = 'Bearer $t';
        }
        final r = await _b._client.send(req);
        if (const {301, 302, 303, 307, 308}.contains(r.statusCode) && r.headers['location'] != null) {
          await r.stream.drain<void>();
          url = url.resolve(r.headers['location']!);
          continue;
        }
        resp = r;
        break;
      }
      if (resp == null) return _finish(const TransferHttpError(310, message: 'too many redirects'));
      if (_stopped) {
        await resp.stream.drain<void>();
        return _finish(const TransferStopped());
      }
      final status = resp.statusCode;
      if (status != 200 && status != 206) {
        final body = await resp.stream.bytesToString().catchError((Object _) => '');
        return _finish(TransferHttpError(status, message: body.length > 200 ? body.substring(0, 200) : body));
      }
      // 206 must start where we asked; 200 means Range was ignored: rewrite
      // from byte 0 so the file stays a prefix of the remote one.
      var fromZero = status == 200;
      if (status == 206) {
        final m = RegExp(r'bytes\s+(\d+)-').firstMatch(resp.headers['content-range'] ?? '');
        if (m == null || int.parse(m.group(1)!) != _r.offset) {
          await resp.stream.drain<void>();
          return _finish(const TransferFailed('The server returned a different byte range than requested.'));
        }
      } else if (_r.offset == 0) {
        fromZero = false;
      }
      final part = File(_r.partPath);
      await part.parent.create(recursive: true);
      final raf = await part.open(mode: fromZero ? FileMode.write : FileMode.append);
      var have = fromZero ? 0 : _r.offset;
      try {
        await for (final chunk in resp.stream) {
          if (_stopped) break;
          await raf.writeFrom(chunk);
          have += chunk.length;
          if (!_progress.isClosed) _progress.add(TransferProgress(bytesOnDisk: have));
        }
        await raf.flush();
      } finally {
        await raf.close();
      }
      _finish(_stopped ? const TransferStopped() : TransferCompleted(etag: _unquote(resp.headers['etag'])));
    } on http.RequestAbortedException {
      _finish(const TransferStopped());
    } on http.ClientException catch (e) {
      _finish(_stopped ? const TransferStopped() : TransferNetworkError(e.message));
    } on IOException catch (e) {
      _finish(_stopped ? const TransferStopped() : TransferNetworkError('$e'));
    } on Object catch (e) {
      _finish(TransferFailed('Download failed: ${e.runtimeType}.'));
    }
  }

  static String? _unquote(String? v) {
    if (v == null) return null;
    var s = v.trim();
    if (s.startsWith('W/')) return null; // weak validators say nothing about bytes
    if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) s = s.substring(1, s.length - 1);
    return s;
  }
}
