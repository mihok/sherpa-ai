import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;

/// A model file the user picked from their own storage.
///
/// Android pickers hand out `content://` URIs with no file path, so the
/// importer must work from a byte stream; when a real path exists the
/// faster path-based copy is used.
abstract interface class LocalModelFile {
  /// Display name including the extension (`Qwen3-0.6B-Q4_K_M.gguf`).
  String get name;

  /// Size in bytes when known without IO.
  int? get length;

  /// Local path, when the file is on disk.
  String? get path;

  /// The whole file as a stream.
  Stream<List<int>> openRead();
}

/// A file on local disk.
final class PathModelFile implements LocalModelFile {
  PathModelFile(this.file);

  final File file;

  @override
  String get name => p.basename(file.path);

  @override
  int? get length => file.existsSync() ? file.lengthSync() : null;

  @override
  String? get path => file.path;

  @override
  Stream<List<int>> openRead() => file.openRead();
}

/// A file returned by `file_picker` 13.
final class PickedModelFile implements LocalModelFile {
  PickedModelFile(this.picked);

  final PlatformFile picked;

  @override
  String get name => picked.name;

  @override
  int? get length => picked.lengthSync();

  @override
  String? get path => picked.path;

  @override
  Stream<List<int>> openRead() => picked.readAsByteStream();
}

/// Opens the system picker for one file. Any type is allowed: Android has
/// no MIME type for `.gguf`, so an extension filter would hide every model;
/// the importer validates the content instead.
Future<LocalModelFile?> pickModelFile() async {
  final f = await FilePicker.pickFile(dialogTitle: 'Choose a GGUF model file');
  return f == null ? null : PickedModelFile(f);
}

/// The first [bytes] bytes of [file] (fewer if the file is shorter).
Future<Uint8List> readHead(LocalModelFile file, int bytes) async {
  final path = file.path;
  if (path != null) {
    final raf = await File(path).open();
    try {
      final len = await raf.length();
      return await raf.read(math.min(bytes, len));
    } finally {
      await raf.close();
    }
  }
  final out = BytesBuilder(copy: false);
  final done = Completer<void>();
  late StreamSubscription<List<int>> sub;
  sub = file.openRead().listen(
    (chunk) {
      final room = bytes - out.length;
      out.add(chunk.length > room ? chunk.sublist(0, room) : chunk);
      if (out.length >= bytes && !done.isCompleted) {
        done.complete();
        unawaited(sub.cancel());
      }
    },
    onError: (Object e, StackTrace s) {
      if (!done.isCompleted) done.completeError(e, s);
    },
    onDone: () {
      if (!done.isCompleted) done.complete();
    },
    cancelOnError: true,
  );
  await done.future;
  return out.toBytes();
}
