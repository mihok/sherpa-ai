import 'dart:convert';

import 'package:file_picker/file_picker.dart' as fp;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:sherpa_core/sherpa_core.dart';

import '../state/transcript_model.dart' show kMessageAttachmentsKey;
import 'attachment_policy.dart';
import 'attachment_store.dart';
import 'image_prep.dart';

/// What an attachment is, which decides how it is sent:
/// * [image]: an [ImagePart] (downscaled JPEG, stored as a file);
/// * [text]: an [EmbeddedResourcePart] with the file's text and name;
/// * [pdf]: an [EmbeddedResourcePart] pointing at the stored PDF (with its
///   size and page count, which the token estimate uses), sent as a
///   document to models whose capabilities say `pdfInput`.
///
/// Text and PDFs count as untrusted content for the agent loop, like MCP
/// resources: a file can carry instructions its author hid in it.
enum AttachmentKind { image, text, pdf }

/// File extensions read as UTF-8 text.
const Set<String> kTextExtensions = {
  'txt', 'text', 'md', 'markdown', 'mdx', 'rst', 'adoc', 'org', 'tex', 'log', //
  'csv', 'tsv', 'json', 'jsonl', 'ndjson', 'yaml', 'yml', 'toml', 'ini', 'cfg', 'conf', 'env', 'xml', 'svg',
  'html', 'htm', 'css', 'scss', 'less', 'js', 'mjs', 'cjs', 'ts', 'tsx', 'jsx', 'vue', 'svelte',
  'dart', 'py', 'rb', 'go', 'rs', 'java', 'kt', 'kts', 'swift', 'm', 'mm', 'c', 'h', 'cc', 'cpp', 'hpp', 'cs',
  'php', 'pl', 'lua', 'r', 'scala', 'sh', 'bash', 'zsh', 'fish', 'ps1', 'sql', 'graphql', 'gql', 'proto',
  'gradle', 'cmake', 'make', 'mk', 'dockerfile', 'tf', 'hcl', 'ipynb', 'diff', 'patch',
};

const Set<String> kImageExtensions = {'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic', 'heif'};

enum AttachmentStatus { processing, ready }

/// One attachment in the composer, before it is sent.
@immutable
final class ComposerAttachment {
  const ComposerAttachment({
    required this.id,
    required this.kind,
    required this.name,
    required this.mimeType,
    required this.size,
    this.status = AttachmentStatus.ready,
    this.bytes,
    this.text,
    this.image,
  });

  final String id;
  final AttachmentKind kind;
  final String name;
  final String mimeType;

  /// Bytes that will be sent (after downscaling, for images).
  final int size;
  final AttachmentStatus status;

  /// Image (prepared JPEG) or PDF bytes.
  final Uint8List? bytes;

  /// A text file's content.
  final String? text;
  final PreparedImage? image;

  bool get ready => status == AttachmentStatus.ready;

  /// "1568×1176 · 312 KB (from 4032×3024)", "12 KB", "Preparing…".
  String get note => !ready ? 'Preparing…' : image?.sizeNote ?? formatBytes(size);

  /// Spoken description for the chip.
  String get semanticLabel => switch (kind) {
    AttachmentKind.image =>
      ready
          ? 'Photo $name, ${image!.width} by ${image!.height} pixels, ${formatBytes(size)}'
                '${image!.resized ? ', resized from ${image!.originalWidth} by ${image!.originalHeight}' : ''}'
                '${image!.removedMetadata ? ', location and camera data removed' : ''}'
          : 'Photo $name, preparing',
    AttachmentKind.text => 'Text file $name, ${formatBytes(size)}',
    AttachmentKind.pdf => 'PDF $name, ${formatBytes(size)}',
  };
}

/// A file the user picked. [bytes] is null when it was larger than the
/// picker was asked to read (only its [size] is known then).
@immutable
final class PickedAttachment {
  const PickedAttachment({required this.name, required this.size, this.bytes, this.mimeType});

  final String name;
  final int size;
  final Uint8List? bytes;
  final String? mimeType;
}

/// The platform pickers behind one fakeable seam.
abstract interface class ChatAttachmentPicker {
  /// The system photo picker (no library permission needed).
  Future<PickedAttachment?> pickPhoto();

  /// The camera app.
  Future<PickedAttachment?> takePhoto();

  /// The system file picker; reads at most [maxBytes].
  Future<PickedAttachment?> pickFile({required int maxBytes});
}

/// [ChatAttachmentPicker] over image_picker (photos, camera) and
/// file_picker (documents).
final class PlatformAttachmentPicker implements ChatAttachmentPicker {
  PlatformAttachmentPicker();

  final ImagePicker _images = ImagePicker();

  // Asking image_picker for at most 3200 px makes the platform decode and
  // re-encode big photos natively (fast, and HEIC becomes JPEG on Android
  // too). It copies EXIF, location included; Sherpa's own pass then
  // resizes to the model's limit and drops all metadata.
  static const double _pickerEdge = 3200;

  @override
  Future<PickedAttachment?> pickPhoto() => _pick(ImageSource.gallery);

  @override
  Future<PickedAttachment?> takePhoto() => _pick(ImageSource.camera);

  Future<PickedAttachment?> _pick(ImageSource source) async {
    final f = await _images.pickImage(
      source: source,
      maxWidth: _pickerEdge,
      maxHeight: _pickerEdge,
      requestFullMetadata: false,
    );
    if (f == null) return null;
    final size = await f.length();
    if (size > AttachmentPolicy.maxImageInputBytes) {
      return PickedAttachment(name: f.name, size: size, mimeType: f.mimeType);
    }
    final bytes = await f.readAsBytes();
    return PickedAttachment(name: f.name, size: bytes.length, bytes: bytes, mimeType: f.mimeType);
  }

  @override
  Future<PickedAttachment?> pickFile({required int maxBytes}) async {
    final f = await fp.FilePicker.pickFile(dialogTitle: 'Attach a file');
    if (f == null) return null;
    final size = f.lengthSync() ?? await f.length();
    if (size != null && size > maxBytes) return PickedAttachment(name: f.name, size: size);
    final bytes = await f.readAsBytes();
    if (bytes.length > maxBytes) return PickedAttachment(name: f.name, size: bytes.length);
    return PickedAttachment(name: f.name, size: bytes.length, bytes: bytes);
  }
}

final chatAttachmentPickerProvider = Provider<ChatAttachmentPicker>((ref) => PlatformAttachmentPicker());

/// Downscales and re-encodes photos (off the UI isolate by default).
final chatImagePreparerProvider = Provider<ImagePreparer>((ref) => prepareImageInBackground);

/// The attachments waiting in one chat's composer.
///
/// [add] validates against the chat's [AttachmentPolicy] and returns the
/// reason when a file is refused (shown to the user; nothing is attached
/// silently or dropped silently). Photos show a "Preparing…" chip while
/// they are downscaled.
final class ComposerAttachments extends ChangeNotifier {
  ComposerAttachments({required ImagePreparer prepare}) : _prepare = prepare;

  final ImagePreparer _prepare;
  final List<ComposerAttachment> _items = [];
  int _ids = 0;
  bool _disposed = false;

  List<ComposerAttachment> get items => List.unmodifiable(_items);
  bool get isEmpty => _items.isEmpty;
  bool get isNotEmpty => _items.isNotEmpty;

  /// A photo is still being prepared: sending waits for it.
  bool get busy => _items.any((a) => !a.ready);

  List<ComposerAttachment> get ready => [
    for (final a in _items)
      if (a.ready) a,
  ];

  int get _totalBytes => _items.fold(0, (n, a) => n + a.size);

  /// Why what is attached can't go to the model of [policy] (the model was
  /// switched after attaching), or null.
  String? blockedReason(AttachmentPolicy policy) {
    if (_items.any((a) => a.kind == AttachmentKind.image) && !policy.imagesAllowed) return policy.imageRefusal;
    if (_items.any((a) => a.kind == AttachmentKind.pdf) && !policy.pdfAllowed) return policy.pdfRefusal;
    return null;
  }

  /// The kind [picked] would be, from its extension and MIME type (null:
  /// not something Sherpa can send).
  static AttachmentKind? kindOf(PickedAttachment picked) {
    final ext = p.extension(picked.name).replaceFirst('.', '').toLowerCase();
    final mime = (picked.mimeType ?? '').toLowerCase();
    if (ext == 'pdf' || mime == 'application/pdf') return AttachmentKind.pdf;
    if (kImageExtensions.contains(ext) || mime.startsWith('image/')) return AttachmentKind.image;
    if (kTextExtensions.contains(ext) || mime.startsWith('text/') || mime == 'application/json') {
      return AttachmentKind.text;
    }
    // Extensionless files such as README or Makefile.
    if (ext.isEmpty &&
        const {'readme', 'makefile', 'dockerfile', 'license', 'notice'}.contains(picked.name.toLowerCase())) {
      return AttachmentKind.text;
    }
    return null;
  }

  /// Adds [picked]; returns why it was refused, or null once it is in.
  Future<String?> add(PickedAttachment picked, AttachmentPolicy policy) async {
    if (_items.length >= AttachmentPolicy.maxPerMessage) {
      return 'You can attach up to ${AttachmentPolicy.maxPerMessage} files to one message.';
    }
    final kind = kindOf(picked);
    final name = picked.name.trim().isEmpty ? 'file' : picked.name.trim();
    switch (kind) {
      case null:
        return "Sherpa can't send “$name”. Attach photos, PDFs or text files (such as .txt, .md, .csv, .json or code).";
      case AttachmentKind.image:
        if (!policy.imagesAllowed) return policy.imageRefusal;
        return _addImage(picked, name, policy);
      case AttachmentKind.pdf:
        if (!policy.pdfAllowed) return policy.pdfRefusal;
        final bytes = picked.bytes;
        if (bytes == null || picked.size > AttachmentPolicy.maxPdfBytes) {
          return '“$name” is ${formatBytes(picked.size)}; PDFs can be up to ${formatBytes(AttachmentPolicy.maxPdfBytes)}.';
        }
        if (bytes.length < 5 || ascii.decode(bytes.sublist(0, 5), allowInvalid: true) != '%PDF-') {
          return '“$name” is not a valid PDF.';
        }
        if (_totalBytes + bytes.length > AttachmentPolicy.maxTotalBytes) return _tooMuch();
        _put(
          ComposerAttachment(
            id: _nextId(),
            kind: AttachmentKind.pdf,
            name: name,
            mimeType: 'application/pdf',
            size: bytes.length,
            bytes: bytes,
          ),
        );
        return null;
      case AttachmentKind.text:
        final bytes = picked.bytes;
        if (bytes == null || picked.size > AttachmentPolicy.maxTextBytes) {
          return '“$name” is ${formatBytes(picked.size)}; text files can be up to '
              '${formatBytes(AttachmentPolicy.maxTextBytes)} (about 60,000 words).';
        }
        final text = _decodeText(bytes);
        if (text == null) return '“$name” is not plain text (UTF-8), so Sherpa can\'t read it.';
        if (_totalBytes + bytes.length > AttachmentPolicy.maxTotalBytes) return _tooMuch();
        _put(
          ComposerAttachment(
            id: _nextId(),
            kind: AttachmentKind.text,
            name: name,
            mimeType: _textMime(name),
            size: bytes.length,
            text: text,
          ),
        );
        return null;
    }
  }

  Future<String?> _addImage(PickedAttachment picked, String name, AttachmentPolicy policy) async {
    final input = picked.bytes;
    if (input == null || picked.size > AttachmentPolicy.maxImageInputBytes) {
      return '“$name” is ${formatBytes(picked.size)}; photos can be up to ${formatBytes(AttachmentPolicy.maxImageInputBytes)}.';
    }
    final id = _nextId();
    _put(
      ComposerAttachment(
        id: id,
        kind: AttachmentKind.image,
        name: name,
        mimeType: 'image/jpeg',
        size: 0,
        status: AttachmentStatus.processing,
      ),
    );
    try {
      final prepared = await _prepare(input, maxLongEdge: policy.maxImageEdge);
      if (_disposed) return null;
      final i = _items.indexWhere((a) => a.id == id);
      if (i < 0) return null; // removed while preparing
      if (_totalBytes + prepared.bytes.length > AttachmentPolicy.maxTotalBytes) {
        _items.removeAt(i);
        notifyListeners();
        return _tooMuch();
      }
      _items[i] = ComposerAttachment(
        id: id,
        kind: AttachmentKind.image,
        name: _jpegName(name),
        mimeType: prepared.mimeType,
        size: prepared.bytes.length,
        bytes: prepared.bytes,
        image: prepared,
      );
      notifyListeners();
      return null;
    } on ImagePrepException catch (e) {
      _drop(id);
      return '“$name”: ${e.message}';
    } on Object catch (e) {
      debugPrint('attachment $name: $e');
      _drop(id);
      return "“$name” couldn't be prepared. Try another photo.";
    }
  }

  void remove(String id) {
    _items.removeWhere((a) => a.id == id);
    notifyListeners();
  }

  /// Takes the ready attachments (after a send) and keeps nothing.
  List<ComposerAttachment> take() {
    final out = ready;
    _items.clear();
    notifyListeners();
    return out;
  }

  void clear() {
    if (_items.isEmpty) return;
    _items.clear();
    notifyListeners();
  }

  void _put(ComposerAttachment a) {
    _items.add(a);
    notifyListeners();
  }

  void _drop(String id) {
    if (_disposed) return;
    _items.removeWhere((a) => a.id == id);
    notifyListeners();
  }

  String _nextId() => 'att${++_ids}';

  static String _tooMuch() =>
      'Attachments to one message can add up to ${formatBytes(AttachmentPolicy.maxTotalBytes)}.';

  static String _jpegName(String name) {
    final base = p.basenameWithoutExtension(name);
    return '${base.isEmpty ? 'photo' : base}.jpg';
  }

  /// UTF-8 text (a BOM is dropped); null for binary data.
  static String? _decodeText(Uint8List bytes) {
    if (bytes.contains(0)) return null;
    try {
      final s = utf8.decode(bytes);
      return s.startsWith('﻿') ? s.substring(1) : s;
    } on FormatException {
      return null;
    }
  }

  static String _textMime(String name) => switch (p.extension(name).toLowerCase()) {
    '.md' || '.markdown' || '.mdx' => 'text/markdown',
    '.csv' => 'text/csv',
    '.tsv' => 'text/tab-separated-values',
    '.json' || '.jsonl' || '.ndjson' || '.ipynb' => 'application/json',
    '.html' || '.htm' => 'text/html',
    '.xml' || '.svg' => 'text/xml',
    '.yaml' || '.yml' => 'text/yaml',
    _ => 'text/plain',
  };

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Turns sent attachments into message parts, saving photos and PDFs with
/// [store]. Returns the parts plus the [kMessageAttachmentsKey] metadata.
Future<({List<ContentPart> parts, List<JsonMap> listed})> attachmentParts(
  List<ComposerAttachment> attachments, {
  required String sessionId,
  required ChatAttachmentStore store,
}) async {
  final parts = <ContentPart>[];
  final listed = <JsonMap>[];
  for (final a in attachments) {
    if (!a.ready) continue;
    switch (a.kind) {
      case AttachmentKind.image:
        final uri = await store.save(sessionId: sessionId, id: a.id, fileName: a.name, bytes: a.bytes!);
        parts.add(ImagePart(mimeType: a.mimeType, uri: uri));
        listed.add(_entry(a, uri.toString()));
      case AttachmentKind.pdf:
        final uri = await store.save(sessionId: sessionId, id: a.id, fileName: a.name, bytes: a.bytes!);
        parts.add(
          EmbeddedResourcePart(uri: uri.toString(), mimeType: a.mimeType, size: a.size, pages: pdfPageCount(a.bytes!)),
        );
        listed.add(_entry(a, uri.toString()));
      case AttachmentKind.text:
        // The name is what the model sees in "[resource …]".
        final uri = Uri(scheme: 'attachment', path: '${a.id}/${a.name}').toString();
        parts.add(EmbeddedResourcePart(uri: uri, mimeType: a.mimeType, text: a.text));
        listed.add(_entry(a, uri));
    }
  }
  return (parts: parts, listed: listed);
}

JsonMap _entry(ComposerAttachment a, String uri) => {
  'kind': a.kind.name,
  'name': a.name,
  'mimeType': a.mimeType,
  'bytes': a.size,
  'uri': uri,
  if (a.image != null) ...{
    'width': a.image!.width,
    'height': a.image!.height,
    'originalWidth': a.image!.originalWidth,
    'originalHeight': a.image!.originalHeight,
  },
};
