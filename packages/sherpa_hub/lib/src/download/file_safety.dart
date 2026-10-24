import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../hub/hub_models.dart';

/// What the first bytes of a file say it is.
enum SniffedFormat { gguf, ggufBigEndian, safetensors, pickle, zipArchive, legacyGgml, unknown }

/// Identifies a weight file from its first ~16 bytes, so a `.bin` can be
/// proven to be safetensors/GGUF instead of a pickle (R08 §11: pickle
/// opcodes `GLOBAL`/`STACK_GLOBAL`/`REDUCE` run code on load).
SniffedFormat sniffWeightFormat(Uint8List head) {
  if (head.length >= 4 && head[0] == 0x47 && head[1] == 0x47 && head[2] == 0x55 && head[3] == 0x46) {
    if (head.length >= 8) {
      final le = head[4] | head[5] << 8 | head[6] << 16 | head[7] << 24;
      if (le == 2 || le == 3) return SniffedFormat.gguf;
      final be = head[7] | head[6] << 8 | head[5] << 16 | head[4] << 24;
      if (be >= 1 && be <= 3) return SniffedFormat.ggufBigEndian;
    }
    return SniffedFormat.unknown;
  }
  if (head.length >= 4 && head[0] == 0x50 && head[1] == 0x4b && head[2] == 0x03 && head[3] == 0x04) {
    // torch.save's zip container holds data.pkl.
    return SniffedFormat.zipArchive;
  }
  if (head.length >= 2 && head[0] == 0x80 && head[1] >= 2 && head[1] <= 5) return SniffedFormat.pickle;
  if (head.length >= 4) {
    final magic = String.fromCharCodes(head.sublist(0, 4));
    // `ggml` / `ggmf` / `ggjt` magics are written as little-endian uint32s.
    if (magic == 'lmgg' || magic == 'fmgg' || magic == 'tjgg') return SniffedFormat.legacyGgml;
  }
  if (head.length >= 10) {
    // safetensors: u64 LE header length, then a JSON object.
    var len = 0;
    for (var i = 7; i >= 0; i--) {
      len = len * 256 + head[i];
    }
    if (len > 1 && len < (100 << 20) && head[8] == 0x7b && (head[9] == 0x22 || head[9] == 0x7d)) {
      return SniffedFormat.safetensors;
    }
  }
  return SniffedFormat.unknown;
}

@immutable
final class SafetyDecision {
  const SafetyDecision({required this.allowed, this.reason, this.warnings = const [], this.byExtension = false});

  final bool allowed;
  final String? reason;
  final List<String> warnings;

  /// Refused for a pickle family's extension (`.bin`, `.npz`…) that no
  /// bytes read proved to be safetensors or GGUF; nothing else was found
  /// wrong with the file.
  final bool byExtension;
}

/// Download gate: an extension allowlist first, Hub scanner verdicts second
/// (R08 §15.8: "block pickles outright; additionally block any file with
/// securityFileStatus.status in {unsafe, suspicious}"). The scanners are a
/// secondary signal, never a reason to allow a pickle.
abstract final class FileSafety {
  /// R08 §15.8 allowlist (+ byte-split `.gguf.partNofM`).
  static const Set<String> allowedExtensions = {
    '.gguf', '.safetensors', '.json', '.jinja', '.txt', '.model', '.litertlm', '.task', '.tflite', '.onnx',
    '.onnx_data',
  };

  /// Pickle-based formats (R08 §11). `.npz/.npy` may embed pickles too.
  static const Set<String> pickleExtensions = {
    '.bin', '.pt', '.pth', '.pkl', '.pickle', '.ckpt', '.joblib', '.npz', '.npy', '.dat',
  };

  static String extensionOf(String path) {
    final name = path.split('/').last.toLowerCase();
    if (RegExp(r'\.gguf\.part\d+of\d+$').hasMatch(name)) return '.gguf';
    final dot = name.lastIndexOf('.');
    return dot < 0 ? '' : name.substring(dot);
  }

  static SafetyDecision check(HubRepoFile file, {HubRepoSecurity? repoSecurity, Uint8List? head}) {
    final ext = extensionOf(file.path);
    final warnings = <String>[];
    final sniffed = head == null ? null : sniffWeightFormat(head);
    if (sniffed == SniffedFormat.pickle || sniffed == SniffedFormat.zipArchive) {
      return SafetyDecision(allowed: false, reason: '${file.path} is a Python pickle; it can run code when loaded');
    }
    if (sniffed == SniffedFormat.ggufBigEndian) {
      return SafetyDecision(allowed: false, reason: '${file.path} is a big-endian GGUF; phones cannot load it');
    }
    if (pickleExtensions.contains(ext)) {
      final proven = sniffed == SniffedFormat.safetensors || sniffed == SniffedFormat.gguf;
      if (!proven) {
        return SafetyDecision(
            allowed: false,
            byExtension: true,
            reason: sniffed == SniffedFormat.legacyGgml
                ? '${file.path} is a legacy GGML file; current llama.cpp cannot load it'
                : '${file.path} uses a pickle-based format ($ext); Sherpa never downloads those');
      }
      warnings.add('${file.path} has a $ext name but contains ${sniffed!.name}');
    } else if (!allowedExtensions.contains(ext)) {
      return SafetyDecision(allowed: false, reason: '${file.path}: "$ext" files are not on the download allowlist');
    }
    final s = file.security;
    if (s != null && s.blocks) {
      return SafetyDecision(allowed: false, reason: 'The Hub flags ${file.path} as ${s.status.name}');
    }
    final repoLevel = repoSecurity?.filesWithIssues[file.path];
    if (repoLevel != null && repoLevel.blocks) {
      return SafetyDecision(allowed: false, reason: 'The Hub flags ${file.path} as ${repoLevel.name}');
    }
    if (repoLevel == HubScanStatus.caution || s?.status == HubScanStatus.caution) {
      warnings.add('The Hub marks ${file.path} "caution"');
    }
    return SafetyDecision(allowed: true, warnings: warnings);
  }
}
