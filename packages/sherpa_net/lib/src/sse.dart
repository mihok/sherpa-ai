import 'dart:async';
import 'dart:convert';

import 'package:meta/meta.dart';

/// One Server-Sent Event, per the WHATWG HTML "event stream" grammar.
@immutable
final class SseEvent {
  const SseEvent({required this.data, this.event = 'message', this.id, this.retry});

  final String data;

  /// Event type; `message` when the stream sent no `event:` field.
  final String event;

  /// Last event id in effect when this event was dispatched.
  final String? id;

  /// Reconnection time requested by the server, if this event carried one.
  final Duration? retry;

  @override
  String toString() => 'SseEvent($event, id=$id, ${data.length} chars)';
}

/// Decodes a byte stream of `text/event-stream` into [SseEvent]s.
///
/// Implements the spec's edge cases that ad-hoc `split('\n')` parsers get
/// wrong: CR, LF and CRLF line endings (including a CRLF split across
/// chunks), a leading BOM, comment lines, `data:` with and without the
/// single optional space, multi-line data joined by `\n`, ids containing
/// NUL being ignored, non-numeric `retry` being ignored, and an
/// unterminated final event being discarded.
final class SseDecoder extends StreamTransformerBase<List<int>, SseEvent> {
  const SseDecoder();

  @override
  Stream<SseEvent> bind(Stream<List<int>> stream) => Stream.eventTransformed(
        stream.transform(const Utf8Decoder(allowMalformed: true)),
        _SseSink.new,
      );
}

/// Same as [SseDecoder] for already-decoded text chunks (tests, fixtures).
final class SseTextDecoder extends StreamTransformerBase<String, SseEvent> {
  const SseTextDecoder();

  @override
  Stream<SseEvent> bind(Stream<String> stream) => Stream.eventTransformed(stream, _SseSink.new);
}

final class _SseSink implements EventSink<String> {
  _SseSink(this._out);

  final EventSink<SseEvent> _out;
  final StringBuffer _line = StringBuffer();
  final StringBuffer _data = StringBuffer();
  bool _hasData = false;
  String _event = '';
  String? _lastId;
  Duration? _retry;
  bool _first = true;
  bool _pendingCr = false;

  @override
  void add(String chunk) {
    var start = 0;
    if (_first && chunk.isNotEmpty) {
      _first = false;
      if (chunk.codeUnitAt(0) == 0xFEFF) start = 1;
    }
    for (var i = start; i < chunk.length; i++) {
      final c = chunk.codeUnitAt(i);
      if (_pendingCr) {
        _pendingCr = false;
        if (c == 0x0A) continue; // second half of CRLF
      }
      if (c == 0x0D) {
        _pendingCr = true;
        _endLine();
      } else if (c == 0x0A) {
        _endLine();
      } else {
        _line.writeCharCode(c);
      }
    }
  }

  void _endLine() {
    final line = _line.toString();
    _line.clear();
    if (line.isEmpty) {
      _dispatch();
      return;
    }
    if (line.codeUnitAt(0) == 0x3A) return; // ':' comment / keep-alive
    final colon = line.indexOf(':');
    final String field;
    var value = '';
    if (colon < 0) {
      field = line;
    } else {
      field = line.substring(0, colon);
      value = line.substring(colon + 1);
      if (value.isNotEmpty && value.codeUnitAt(0) == 0x20) value = value.substring(1);
    }
    switch (field) {
      case 'data':
        if (_hasData) _data.write('\n');
        _data.write(value);
        _hasData = true;
      case 'event':
        _event = value;
      case 'id':
        if (!value.contains('\u0000')) _lastId = value;
      case 'retry':
        final ms = int.tryParse(value);
        if (ms != null && ms >= 0 && RegExp(r'^\d+$').hasMatch(value)) {
          _retry = Duration(milliseconds: ms);
        }
    }
  }

  void _dispatch() {
    final retry = _retry;
    _retry = null;
    if (!_hasData) {
      _event = '';
      if (retry != null) _out.add(SseEvent(data: '', event: '', id: _lastId, retry: retry));
      return;
    }
    _out.add(SseEvent(
      data: _data.toString(),
      event: _event.isEmpty ? 'message' : _event,
      id: _lastId,
      retry: retry,
    ));
    _data.clear();
    _hasData = false;
    _event = '';
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) => _out.addError(error, stackTrace);

  @override
  void close() {
    // Per spec an event without its terminating blank line is discarded.
    _out.close();
  }
}

/// Encodes events for test servers and in-process transports.
String encodeSse(SseEvent e) {
  final b = StringBuffer();
  if (e.event != 'message' && e.event.isNotEmpty) b.write('event: ${e.event}\n');
  if (e.id != null) b.write('id: ${e.id}\n');
  if (e.retry != null) b.write('retry: ${e.retry!.inMilliseconds}\n');
  for (final line in e.data.split('\n')) {
    b.write('data: $line\n');
  }
  b.write('\n');
  return b.toString();
}
