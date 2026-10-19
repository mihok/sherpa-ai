import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_platform/sherpa_platform.dart' show BackupExclusion;

import '../../../state/sessions.dart' show SessionDeletedHook;
import '../../context/data/data_erase.dart' show DataEraseHook;

/// Where attached photos and PDFs live: one folder per chat under the app's
/// support directory, so the database only holds a `file://` reference
/// (core's `MediaPart` contract) and a chat's messages stay small.
///
/// The bytes are written once and never rewritten: every request in the
/// chat sends exactly the same image (prefix-bound providers reject a
/// re-encoded one).
///
/// iOS can move the app's container on update, which changes absolute
/// paths; [read] therefore falls back to the same file name under the
/// current root.
///
/// Privacy: the files are protected by the OS's file encryption (iOS Data
/// Protection, Android file-based encryption), not by the database's own
/// cipher, and like the database they are kept out of backups (iOS: the
/// folder is flagged on creation; Android: `attachments` is excluded in
/// the backup and data-extraction rules). Deleting a chat deletes its
/// folder ([chatSessionDeletedHooksProvider]); "Delete all data" deletes
/// them all ([chatAttachmentsEraseHook]).
final class ChatAttachmentStore {
  ChatAttachmentStore({required Future<Directory> Function() root, Future<void> Function(Directory root)? onCreateRoot})
    : _root = root,
      _onCreateRoot = onCreateRoot;

  /// Under the app support directory, excluded from iCloud backup.
  factory ChatAttachmentStore.appSupport() => ChatAttachmentStore(
    root: () async => Directory(p.join((await getApplicationSupportDirectory()).path, folderName)),
    onCreateRoot: (dir) async {
      if (!Platform.isIOS) return;
      try {
        await BackupExclusion.exclude(dir.path, includeSqliteSidecars: false);
      } on Object catch (e) {
        debugPrint('attachments: backup exclusion failed (${e.runtimeType})');
      }
    },
  );

  static const String folderName = 'attachments';

  final Future<Directory> Function() _root;
  final Future<void> Function(Directory root)? _onCreateRoot;
  Directory? _resolved;
  bool _rootReady = false;

  Future<Directory> get root async => _resolved ??= await _root();

  /// Writes [bytes] as [fileName] in [sessionId]'s folder and returns its
  /// `file://` URI. [id] keeps names unique.
  Future<Uri> save({
    required String sessionId,
    required String id,
    required String fileName,
    required Uint8List bytes,
  }) async {
    final base = await root;
    if (!_rootReady) {
      // The backup flag must be set on an existing directory; it covers
      // everything inside.
      await base.create(recursive: true);
      await _onCreateRoot?.call(base);
      _rootReady = true;
    }
    final dir = Directory(p.join(base.path, _safe(sessionId)));
    await dir.create(recursive: true);
    final file = File(p.join(dir.path, '${_safe(id)}-${_safe(fileName)}'));
    await file.writeAsBytes(bytes, flush: true);
    return file.uri;
  }

  /// The bytes behind [uri], or null when the file is gone (or [uri] is not
  /// one of ours: nothing outside the attachments folder is ever read).
  Future<Uint8List?> read(Uri uri) async {
    final file = await fileFor(uri);
    if (file == null) return null;
    try {
      return await file.readAsBytes();
    } on FileSystemException {
      return null;
    }
  }

  /// The local file for [uri] when it exists inside the attachments folder.
  Future<File?> fileFor(Uri uri) async {
    if (uri.scheme != 'file') return null;
    final base = (await root).path;
    final direct = File.fromUri(uri);
    if (p.isWithin(base, direct.path) && direct.existsSync()) return direct;
    // Moved container: the same chat folder and file name under today's root.
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.length < 2) return null;
    final moved = File(p.join(base, segments[segments.length - 2], segments.last));
    return p.isWithin(base, moved.path) && moved.existsSync() ? moved : null;
  }

  /// Deletes [sessionId]'s attachments (chat deleted).
  Future<void> deleteSession(String sessionId) async {
    final dir = Directory(p.join((await root).path, _safe(sessionId)));
    if (dir.existsSync()) await dir.delete(recursive: true);
  }

  /// Deletes every attachment ("Delete all data").
  Future<void> eraseAll() async {
    final dir = await root;
    if (dir.existsSync()) await dir.delete(recursive: true);
    _rootReady = false;
  }

  static String _safe(String s) {
    final cleaned = s.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final trimmed = cleaned.length > 80 ? cleaned.substring(cleaned.length - 80) : cleaned;
    return trimmed.isEmpty || trimmed.startsWith('.') ? '_$trimmed' : trimmed;
  }
}

/// The store chats save attachments to. Tests override it with a temp dir.
final chatAttachmentStoreProvider = Provider<ChatAttachmentStore>((ref) => ChatAttachmentStore.appSupport());

/// A deleted chat's attachments go with it. The app adds these to
/// `sessionDeletedHooksProvider` next to MCP's hooks (that provider has one
/// override, composed where MCP overrides it).
final chatSessionDeletedHooksProvider = Provider<List<SessionDeletedHook>>(
  (ref) => [(id) => ref.read(chatAttachmentStoreProvider).deleteSession(id)],
);

/// "Delete all data": every attachment (for `dataEraseHooksProvider`).
DataEraseHook chatAttachmentsEraseHook(Ref ref) => () => ref.read(chatAttachmentStoreProvider).eraseAll();
