import 'dart:convert';
import 'dart:typed_data';

/// Writes little-endian GGUF v3 headers for tests.
final class GgufBuilder {
  GgufBuilder({this.version = 3});

  final int version;
  final List<(String, int, void Function(_W))> _kv = [];
  final List<(String, List<int>, int, int)> _tensors = [];

  void string(String key, String value) => _kv.add((key, 8, (w) => w.str(value)));
  void u32(String key, int value) => _kv.add((key, 4, (w) => w.u32(value)));
  void i32(String key, int value) => _kv.add((key, 5, (w) => w.i32(value)));
  void u64(String key, int value) => _kv.add((key, 10, (w) => w.u64(value)));
  void f32(String key, double value) => _kv.add((key, 6, (w) => w.f32(value)));
  void boolean(String key, {required bool value}) => _kv.add((key, 7, (w) => w.u8(value ? 1 : 0)));

  void u32Array(String key, List<int> values) => _kv.add((key, 9, (w) {
        w.u32(4);
        w.u64(values.length);
        values.forEach(w.u32);
      }));

  void boolArray(String key, List<bool> values) => _kv.add((key, 9, (w) {
        w.u32(7);
        w.u64(values.length);
        for (final v in values) {
          w.u8(v ? 1 : 0);
        }
      }));

  void f32Array(String key, int length) => _kv.add((key, 9, (w) {
        w.u32(6);
        w.u64(length);
        for (var i = 0; i < length; i++) {
          w.f32(i.toDouble());
        }
      }));

  void stringArray(String key, List<String> values) => _kv.add((key, 9, (w) {
        w.u32(8);
        w.u64(values.length);
        values.forEach(w.str);
      }));

  void tensor(String name, List<int> dims, int type, int offset) => _tensors.add((name, dims, type, offset));

  Uint8List build({bool bigEndianVersion = false, int? kvCountOverride}) {
    final w = _W();
    w.bytes.addAll(ascii.encode('GGUF'));
    if (bigEndianVersion) {
      w.bytes.addAll([0, 0, 0, version]);
    } else {
      w.u32(version);
    }
    w.u64(_tensors.length);
    w.u64(kvCountOverride ?? _kv.length);
    for (final (key, type, write) in _kv) {
      w.str(key);
      w.u32(type);
      write(w);
    }
    for (final (name, dims, type, offset) in _tensors) {
      w.str(name);
      w.u32(dims.length);
      dims.forEach(w.u64);
      w.u32(type);
      w.u64(offset);
    }
    return Uint8List.fromList(w.bytes);
  }
}

final class _W {
  final List<int> bytes = [];

  void u8(int v) => bytes.add(v & 0xff);

  void u32(int v) {
    final b = ByteData(4)..setUint32(0, v, Endian.little);
    bytes.addAll(b.buffer.asUint8List());
  }

  void i32(int v) {
    final b = ByteData(4)..setInt32(0, v, Endian.little);
    bytes.addAll(b.buffer.asUint8List());
  }

  void u64(int v) {
    final b = ByteData(8)..setUint64(0, v, Endian.little);
    bytes.addAll(b.buffer.asUint8List());
  }

  void f32(double v) {
    final b = ByteData(4)..setFloat32(0, v, Endian.little);
    bytes.addAll(b.buffer.asUint8List());
  }

  void str(String s) {
    final e = utf8.encode(s);
    u64(e.length);
    bytes.addAll(e);
  }
}
