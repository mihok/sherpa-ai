import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// FNV-1a 64-bit as 16 hex chars: deterministic across runs (unlike
/// `Object.hash`), cheap, and good enough to tell "same message" from
/// "different message" for the conversation cache. Not a security hash.
String fingerprint(Object? value) => fingerprintBytes(utf8.encode(_canonical(value)));

String fingerprintBytes(List<int> bytes) {
  // 64-bit arithmetic on two 32-bit halves keeps the result identical on
  // the VM and on the web (where ints are doubles).
  var hi = 0xcbf29ce4;
  var lo = 0x84222325;
  for (final b in bytes) {
    lo ^= b & 0xff;
    // (hi:lo) * 0x100000001b3 = (hi:lo) * 0x1b3 + (lo << 40)
    final loMul = lo * 0x1b3;
    final carry = (loMul / 0x100000000).floor();
    final newLo = loMul & 0xffffffff;
    final newHi = (hi * 0x1b3 + carry + ((lo << 8) & 0xffffffff)) & 0xffffffff;
    hi = newHi;
    lo = newLo;
  }
  return hi.toRadixString(16).padLeft(8, '0') + lo.toRadixString(16).padLeft(8, '0');
}

String _canonical(Object? v) {
  if (v is Uint8List) return 'bytes:${v.length}:${fingerprintBytes(v)}';
  if (v is Map) {
    final keys = v.keys.map((k) => '$k').toList()..sort();
    return '{${keys.map((k) => '${jsonEncode(k)}:${_canonical(v[k])}').join(',')}}';
  }
  if (v is Iterable) return '[${v.map(_canonical).join(',')}]';
  return jsonEncode(v);
}

final Random _random = Random.secure();

/// A fresh tool-call id (`call_` + 16 base-36 chars). LiteRT-LM and the
/// prompted format have no ids of their own; Sherpa pairs results by id.
String newToolCallId() {
  const alphabet = '0123456789abcdefghijklmnopqrstuvwxyz';
  final b = StringBuffer('call_');
  for (var i = 0; i < 16; i++) {
    b.write(alphabet[_random.nextInt(alphabet.length)]);
  }
  return b.toString();
}
