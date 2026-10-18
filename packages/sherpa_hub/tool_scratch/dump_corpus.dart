import 'dart:io';
import 'package:sherpa_hub/sherpa_hub.dart';

void main() {
  final lines = File('test/fixtures/r08_corpus.md').readAsLinesSync();
  for (final line in lines) {
    final m = RegExp(r'^\| (\d+) \| ([^|]+) \| ([^|]+) \|').firstMatch(line);
    if (m == null) continue;
    final n = m.group(1)!;
    final repo = m.group(2)!.trim();
    final col = m.group(3)!.trim();
    String? file;
    String? branch;
    if (col == 'repo') {
    } else if (col.startsWith('branch')) {
      branch = RegExp(r'`([^`]+)`').firstMatch(col)!.group(1);
    } else {
      file = col;
    }
    final p = parseModelName(repo, fileName: file, revision: branch);
    final q = p.quant?.value;
    print('$n|${p.format.name}|fam=${p.family}|pre=${p.namePrefix}|base=${p.baseFamily}|teach=${p.teacher}|ver=${p.version?.raw}|build=${p.build}|size=${p.size}|tier=${p.tier}|act=${p.activeParams}|ctx=${p.contextHint}|var=${p.variants.map((v) => v.value.name).join(",")}|q=${q?.label}(${q?.scheme.name},${q?.ggufType?.id},b${q?.bits},g${q?.groupSize},bpw${q?.bpw},dyn${q?.dynamic},i${q?.imatrix},e${q?.embedOutputQ8},h${q?.headBits})|shard=${p.shard}|role=${p.role.value.name}${p.draftKind == null ? "" : "(${p.draftKind!.name})"}|dev=${p.deviceTarget}|qual=${p.qualifiers}|flags=${p.flags.map((f) => f.name).join(",")}|unrec=${p.unrecognized}');
  }
}
