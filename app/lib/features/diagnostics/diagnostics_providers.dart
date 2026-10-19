import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_core/sherpa_core.dart' show InMemorySessionStore;

import '../../bootstrap.dart' show databaseFileName;
import '../../state/observable_session_store.dart';
import '../../state/providers.dart';
import '../context/handoff/handoff_platform.dart';
import 'diagnostics_collector.dart';

/// Size in bytes of the app's database (and its WAL), or null when there is
/// none (in-memory storage) or it can't be read.
typedef DatabaseSizeReader = Future<int?> Function();

/// Stats `<app support>/sherpa.db` and its `-wal`/`-shm` files; null for
/// the in-memory store (`bootstrap(inMemory: true)`, tests).
final diagnosticsDatabaseSizeProvider = Provider<DatabaseSizeReader>((ref) {
  final store = ref.watch(sessionStoreProvider);
  final inner = store is ObservableSessionStore ? store.inner : store;
  if (inner is InMemorySessionStore) return () async => null;
  return () async {
    final dir = await getApplicationSupportDirectory();
    var total = 0;
    var found = false;
    for (final suffix in const ['', '-wal', '-shm']) {
      final f = File(p.join(dir.path, '$databaseFileName$suffix'));
      if (await f.exists()) {
        total += await f.length();
        found = true;
      }
    }
    return found ? total : null;
  };
});

/// Directories whose paths are masked by value in every bundle, next to
/// the user's home and the generic data-directory patterns: the app's own
/// support, documents and temp directories.
final diagnosticsPrivatePathsProvider = Provider<Future<List<String>> Function()>((ref) => () async {
      final out = <String>[];
      for (final dir in [getApplicationSupportDirectory, getApplicationDocumentsDirectory, getTemporaryDirectory]) {
        try {
          out.add((await dir()).path);
        } on Object {
          // Not on this platform (tests, desktop without the plugin).
        }
      }
      return out;
    });

/// Where a finished bundle goes: the share sheet and the clipboard.
abstract interface class DiagnosticsShare {
  /// Opens the share sheet with the JSON file.
  Future<void> shareFile({required String name, required Uint8List bytes, required String subject});

  Future<void> copyText(String text);
}

/// The share sheet through [HandoffPlatform] (a private temp file that
/// "Delete all data" clears), the clipboard through [Clipboard].
final class PlatformDiagnosticsShare implements DiagnosticsShare {
  const PlatformDiagnosticsShare(this._platform);

  final HandoffPlatform _platform;

  @override
  Future<void> shareFile({required String name, required Uint8List bytes, required String subject}) =>
      _platform.shareFile(name: name, bytes: bytes, mimeType: 'application/json', subject: subject);

  @override
  Future<void> copyText(String text) => Clipboard.setData(ClipboardData(text: text));
}

final diagnosticsShareProvider = Provider<DiagnosticsShare>(
  (ref) => PlatformDiagnosticsShare(ref.watch(handoffPlatformProvider)),
);

/// The bundle for the preview, collected when the screen opens (invalidate
/// to collect again).
final diagnosticsBundleProvider = FutureProvider.autoDispose<DiagnosticsBundle>(
  (ref) => DiagnosticsCollector(ref.read).collect(),
);
