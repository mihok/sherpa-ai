import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Where model bytes live on disk.
///
/// ```
/// <app support>/models/
///   .partial/<record id>.part        in-flight downloads (resumable)
///   library/<repo__name@commit12>/…  verified files, one folder per pinned
///                                    commit so every shard of a split GGUF
///                                    sits next to its siblings (llama.cpp
///                                    finds `-0000N-of-0000M` by name, R08 §15.4)
///   library/imported/<id>/<file>     user-imported GGUF files
/// ```
///
/// Temp and library directories share one volume so "verified → installed"
/// is an atomic `rename`, never a copy that could leave a half-written
/// model visible to the engine.
///
/// The app support directory (not documents) keeps models out of the
/// Files app and out of user-visible storage. It is backed up by default, so
/// `bootstrap()` marks [root] `isExcludedFromBackup` on iOS and the Android
/// backup rules exclude `models/`.
final class ModelStorageLayout {
  ModelStorageLayout(this.root);

  /// `<app support>/models`.
  static Future<ModelStorageLayout> fromSupportDirectory() async {
    final support = await getApplicationSupportDirectory();
    return ModelStorageLayout(p.join(support.path, 'models'));
  }

  final String root;

  String get partialDir => p.join(root, '.partial');

  String get libraryDir => p.join(root, 'library');

  String get importedDir => p.join(libraryDir, 'imported');

  String partPath(String recordId) => p.join(partialDir, '$recordId.part');

  /// Absolute path of a library-relative path (`DownloadRecord.localPath`).
  String libraryPath(String relative) {
    final out = p.normalize(p.join(libraryDir, relative));
    // Repo paths come from the Hub; refuse anything that escapes the library.
    if (!p.isWithin(libraryDir, out)) throw ArgumentError.value(relative, 'relative', 'escapes the model library');
    return out;
  }

  String relativeToLibrary(String absolute) => p.relative(absolute, from: libraryDir);

  Future<void> ensure() async {
    await Directory(partialDir).create(recursive: true);
    await Directory(libraryDir).create(recursive: true);
  }
}
