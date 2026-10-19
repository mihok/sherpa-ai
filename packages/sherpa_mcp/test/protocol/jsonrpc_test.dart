import 'package:sherpa_mcp/sherpa_mcp.dart';
import 'package:test/test.dart';

void main() {
  group('JsonRpcId', () {
    test('string and integer ids; integral doubles normalize to int', () {
      expect(JsonRpcId.tryParse('a'), const JsonRpcId.string('a'));
      expect(JsonRpcId.tryParse(1), const JsonRpcId.int(1));
      expect(JsonRpcId.tryParse(1.0), const JsonRpcId.int(1));
      expect(JsonRpcId.tryParse(1.0)!.value, isA<int>());
      expect(JsonRpcId.tryParse(null), isNull);
      expect(JsonRpcId.tryParse(true), isNull);
      expect(JsonRpcId.tryParse(const <Object?>[]), isNull);
      expect(const JsonRpcId.string('1') == const JsonRpcId.int(1), isFalse);
    });
  });

  group('decode', () {
    test('request, notification, result and error', () {
      expect(JsonRpcMessage.decode('{"jsonrpc":"2.0","id":7,"method":"ping"}'), isA<JsonRpcRequest>());
      expect(JsonRpcMessage.decode('{"jsonrpc":"2.0","method":"notifications/x"}'), isA<JsonRpcNotification>());
      final r = JsonRpcMessage.decode('{"jsonrpc":"2.0","id":"a","result":{"ok":true}}') as JsonRpcResult;
      expect(r.id, const JsonRpcId.string('a'));
      expect(r.result, {'ok': true});
      final e = JsonRpcMessage.decode('{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"x","data":[1]}}')
          as JsonRpcErrorResponse;
      expect(e.id, isNull);
      expect(e.error.code, -32700);
      expect(e.error.data, [1]);
    });

    test('rejects null request ids, non-object params/results and wrong version', () {
      for (final bad in [
        '{"jsonrpc":"2.0","id":null,"method":"x"}',
        '{"jsonrpc":"2.0","id":1,"method":"x","params":[1]}',
        '{"jsonrpc":"2.0","id":1,"result":5}',
        '{"jsonrpc":"1.0","id":1,"result":{}}',
        '{"jsonrpc":"2.0","id":1,"result":{},"error":{"code":1,"message":""}}',
        '{"jsonrpc":"2.0","id":1,"error":{"code":"x","message":""}}',
        '[1',
      ]) {
        expect(() => JsonRpcMessage.decode(bad), throwsA(isA<JsonRpcFormatException>()), reason: bad);
      }
    });

    test('batches only when explicitly allowed (2025-03-26 peers)', () {
      const batch = '[{"jsonrpc":"2.0","method":"a"},{"jsonrpc":"2.0","id":1,"result":{}}]';
      expect(() => JsonRpcMessage.decodeBody(batch), throwsA(isA<JsonRpcFormatException>()));
      expect(JsonRpcMessage.decodeBody(batch, allowBatch: true), hasLength(2));
    });
  });

  test('encode never emits raw newlines (stdio framing)', () {
    final m = JsonRpcRequest(const JsonRpcId.int(1), 'x', {'text': 'a\nb'});
    expect(m.encode(), isNot(contains('\n')));
    expect(JsonRpcMessage.decode(m.encode()).toJson(), m.toJson());
  });
}
