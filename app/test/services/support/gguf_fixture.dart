import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// A small but real GGUF v3 file: a llama-shaped header that sherpa_hub's
/// reader, `ModelArchitecture.fromGguf` and the fit engine accept, padded
/// with deterministic pseudo-random bytes to [totalBytes].
Uint8List syntheticGguf({
  int totalBytes = 3 << 20,
  String name = 'Tiny Llama Test',
  int fileType = 15, // Q4_K_M
  int seed = 1,
  int contextLength = 8192,
  String? chatTemplate = '{% for m in messages %}{{ m.content }}{% endfor %}{% if tools %}{{ tools }}{% endif %}',
}) {
  final w = _W();
  final kv = <(String, int, void Function())>[
    ('general.architecture', 8, () => w.str('llama')),
    ('general.name', 8, () => w.str(name)),
    ('general.file_type', 4, () => w.u32(fileType)),
    ('llama.context_length', 4, () => w.u32(contextLength)),
    ('llama.block_count', 4, () => w.u32(16)),
    ('llama.embedding_length', 4, () => w.u32(2048)),
    ('llama.feed_forward_length', 4, () => w.u32(8192)),
    ('llama.attention.head_count', 4, () => w.u32(32)),
    ('llama.attention.head_count_kv', 4, () => w.u32(8)),
    ('llama.attention.key_length', 4, () => w.u32(64)),
    ('llama.vocab_size', 4, () => w.u32(32000)),
    if (chatTemplate != null) ('tokenizer.chat_template', 8, () => w.str(chatTemplate)),
  ];
  w.bytes.addAll(ascii.encode('GGUF'));
  w.u32(3);
  w.u64(0); // tensors
  w.u64(kv.length);
  for (final (key, type, write) in kv) {
    w.str(key);
    w.u32(type);
    write();
  }
  final header = w.bytes;
  final out = Uint8List(max(totalBytes, header.length));
  out.setAll(0, header);
  final r = Random(seed);
  for (var i = header.length; i < out.length; i++) {
    out[i] = r.nextInt(256);
  }
  return out;
}

String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

/// First [bytes] bytes of the real Qwen3-0.6B Q4_K_M GGUF in this
/// environment, or null when it isn't present.
Future<File?> realGgufHead(Directory into, {int bytes = 8 << 20}) async {
  final src = File('/opt/models/Qwen3-0.6B-Q4_K_M.gguf');
  if (!src.existsSync()) return null;
  final raf = await src.open();
  try {
    final head = await raf.read(bytes);
    final f = File('${into.path}/Qwen3-0.6B-Q4_K_M.gguf');
    await f.writeAsBytes(head, flush: true);
    return f;
  } finally {
    await raf.close();
  }
}

final class _W {
  final List<int> bytes = [];

  void u32(int v) => bytes.addAll((ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List());

  void u64(int v) => bytes.addAll((ByteData(8)..setUint64(0, v, Endian.little)).buffer.asUint8List());

  void str(String s) {
    final e = utf8.encode(s);
    u64(e.length);
    bytes.addAll(e);
  }
}
