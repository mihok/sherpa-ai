import 'dart:io';

import 'package:file_picker/file_picker.dart' as fp;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// A file the user picked: its bytes, or only its size when it was too
/// large to read (so the screen can say so without loading it).
@immutable
final class PickedFile {
  const PickedFile({required this.name, this.bytes, this.size});

  final String name;
  final Uint8List? bytes;
  final int? size;

  bool get tooLarge => bytes == null;
}

/// Share sheet, "Save to Files" and the file picker behind one fakeable
/// interface (tests never touch platform channels).
abstract interface class HandoffPlatform {
  /// Writes [bytes] to a private temp file and opens the share sheet.
  Future<void> shareFile({required String name, required Uint8List bytes, required String mimeType, String? subject});

  /// Asks where to save [bytes]; false if the user cancelled.
  Future<bool> saveFile({required String name, required Uint8List bytes, required String mimeType});

  /// Lets the user pick one file; null if cancelled. Files over [maxBytes]
  /// are reported by size and never read.
  Future<PickedFile?> pickFile({required int maxBytes});

  /// Deletes files [shareFile] left behind (plaintext exports).
  Future<void> clearShared();

  /// Whether a camera QR scanner can be offered on this platform.
  bool get canScan;
}

final handoffPlatformProvider = Provider<HandoffPlatform>((ref) => const DefaultHandoffPlatform());

final class DefaultHandoffPlatform implements HandoffPlatform {
  const DefaultHandoffPlatform();

  /// One private folder for outgoing files. It is cleared before every
  /// share (and by "Delete all data"): the receiving app may still be
  /// reading the previous file when the share sheet returns, so the file is
  /// not deleted right after sharing.
  static Future<Directory> _shareDir() async {
    final dir = Directory(p.join((await getTemporaryDirectory()).path, 'sherpa-share'));
    await dir.create(recursive: true);
    return dir;
  }

  @override
  Future<void> shareFile({
    required String name,
    required Uint8List bytes,
    required String mimeType,
    String? subject,
  }) async {
    await clearShared();
    final file = File(p.join((await _shareDir()).path, name));
    await file.writeAsBytes(bytes, flush: true);
    await SharePlus.instance.share(
      ShareParams(files: [XFile(file.path, mimeType: mimeType, name: name)], subject: subject, fileNameOverrides: [name]),
    );
  }

  @override
  Future<bool> saveFile({required String name, required Uint8List bytes, required String mimeType}) async {
    final uri = await fp.FilePicker.saveFile(fileName: name, bytes: bytes, mimeType: mimeType);
    return uri != null;
  }

  @override
  Future<PickedFile?> pickFile({required int maxBytes}) async {
    final f = await fp.FilePicker.pickFile();
    if (f == null) return null;
    final size = f.lengthSync() ?? await f.length();
    if (size != null && size > maxBytes) return PickedFile(name: f.name, size: size);
    final bytes = await f.readAsBytes();
    if (bytes.length > maxBytes) return PickedFile(name: f.name, size: bytes.length);
    return PickedFile(name: f.name, bytes: bytes, size: bytes.length);
  }

  @override
  Future<void> clearShared() async {
    final dir = await _shareDir();
    await for (final e in dir.list()) {
      try {
        await e.delete(recursive: true);
      } on FileSystemException {
        // In use by a share target; the next clear gets it.
      }
    }
  }

  @override
  bool get canScan => !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);
}
