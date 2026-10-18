import 'dart:io';
import 'dart:typed_data';
import 'package:sherpa_hub/sherpa_hub.dart';

void main() {
  final f = File('/opt/models/Qwen3-0.6B-Q4_K_M.gguf').openSync();
  var n = 1 << 20;
  GgufParseResult r;
  while (true) {
    f.setPositionSync(0);
    final bytes = Uint8List.fromList(f.readSync(n));
    r = GgufReader.parse(bytes, fileSize: f.lengthSync());
    if (r is GgufNeedMoreBytes) { print('need ${r.requiredBytes} have ${r.availableBytes}'); n = r.requiredBytes > n * 2 ? r.requiredBytes : n * 2; continue; }
    final h = r as GgufHeader;
    if (!h.hasTensorInfo) { print('tensors need ${h.tensorInfoRequiredBytes}'); n = h.tensorInfoRequiredBytes! + 1024; continue; }
    break;
  }
  final h = r as GgufHeader;
  final m = h.metadata;
  print('v${h.version} tensors=${h.tensorCount} kv=${h.kvCount} kvEnd=${h.kvEndOffset} tiEnd=${h.tensorInfoEndOffset} data=${h.dataOffset}');
  print('arch=${m.architecture} layers=${m.blockCount} kvh=${m.headCountKv} klen=${m.keyLength} ctx=${m.contextLength} vocab=${m.vocabSize} ftype=${m.fileTypeInfo} tools=${m.chatTemplateMentionsTools} reasoning=${m.chatTemplateMentionsReasoning}');
  print('params=${h.parameterCount} tensorBytes=${h.tensorDataBytes} types=${h.tensorTypeCounts} file-data=${f.lengthSync() - h.dataOffset!}');
  final a = ModelArchitecture.fromGguf(m, parameterCount: h.parameterCount)!;
  for (final t in [KvCacheType.f16, KvCacheType.q8_0, KvCacheType.q4_0]) {
    final kv = estimateKvCache(a, contextLength: 4096, typeK: t, typeV: t);
    print('$t ${kv.bytes} = ${kv.bytes / 1048576} MiB perTok=${kv.bytesPerFullCell}');
  }
  for (final ub in [512, 256, 128]) {
    print('compute ub$ub = ${estimateComputeBytes(a, nUbatch: ub, contextCells: 4096) / 1048576} MiB; outs512 ${estimateComputeBytes(a, nUbatch: ub, outputs: 512, contextCells: 4096) / 1048576}');
  }
}
