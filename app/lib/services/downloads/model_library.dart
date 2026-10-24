import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show immutable;
import 'package:path/path.dart' as p;
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_data/sherpa_data.dart' show DocumentCollections;
import 'package:sherpa_hub/sherpa_hub.dart';

import 'file_hasher.dart';
import 'local_model_file.dart';
import 'record_store.dart';
import 'storage_layout.dart';

enum LibrarySource { hub, imported }

/// Why an installed model can't be loaded right now (found by the launch
/// integrity check).
enum LibraryIssue {
  none,

  /// A file was deleted (by the OS, a cleaner app, or a restore from backup).
  missingFiles,

  /// A file has a different size than when it was verified.
  sizeMismatch,

  /// The optional re-hash found different bytes.
  hashMismatch;

  String get message => switch (this) {
        none => '',
        missingFiles => 'Some files are missing. Delete the model and download it again.',
        sizeMismatch => 'A file changed size since it was verified. Delete the model and download it again.',
        hashMismatch => 'A file no longer matches its SHA-256. Delete the model and download it again.',
      };
}

/// One file of an installed model.
@immutable
final class LibraryFile {
  const LibraryFile({required this.path, required this.role, required this.sizeBytes, this.sha256, this.repoPath});

  factory LibraryFile.fromJson(JsonMap j) => LibraryFile(
        path: j.req<String>('path'),
        role: FileRole.values.asNameMap()[j.opt<String>('role')] ?? FileRole.model,
        sizeBytes: j.req<num>('sizeBytes').toInt(),
        sha256: j.opt<String>('sha256'),
        repoPath: j.opt<String>('repoPath'),
      );

  /// Relative to the library root.
  final String path;
  final FileRole role;
  final int sizeBytes;

  /// Verified SHA-256 (the Hub's `lfs.oid`, or computed on import).
  final String? sha256;

  /// Path inside the Hub repo, for downloaded files.
  final String? repoPath;

  JsonMap toJson() => compact({
        'path': path,
        'role': role.name,
        'sizeBytes': sizeBytes,
        'sha256': sha256,
        'repoPath': repoPath,
      });
}

/// An installed, verified local model (`DocumentCollections.modelLibrary`).
@immutable
final class LibraryModel {
  const LibraryModel({
    required this.id,
    required this.source,
    required this.displayName,
    required this.format,
    required this.files,
    required this.loadPath,
    required this.installedAt,
    this.repo,
    this.revision,
    this.variantId,
    this.quant,
    this.mmprojPath,
    this.draftPath,
    this.contextLength,
    this.defaultContextLength,
    this.architecture,
    this.parameterCount,
    this.license,
    this.toolUse = false,
    this.reasoning = false,
    this.lastUsedAt,
    this.issue = LibraryIssue.none,
  });

  factory LibraryModel.fromJson(JsonMap j) => LibraryModel(
        id: j.req<String>('id'),
        source: LibrarySource.values.asNameMap()[j.opt<String>('source')] ?? LibrarySource.hub,
        displayName: j.req<String>('displayName'),
        format: ModelFormat.values.asNameMap()[j.opt<String>('format')] ?? ModelFormat.gguf,
        files: [
          for (final f in j.opt<List<Object?>>('files') ?? const <Object?>[])
            if (f is Map) LibraryFile.fromJson(f.cast<String, Object?>()),
        ],
        loadPath: j.req<String>('loadPath'),
        installedAt: DateTime.parse(j.req<String>('installedAt')),
        repo: j.opt<String>('repo'),
        revision: j.opt<String>('revision'),
        variantId: j.opt<String>('variantId'),
        quant: j.opt<String>('quant'),
        mmprojPath: j.opt<String>('mmprojPath'),
        draftPath: j.opt<String>('draftPath'),
        contextLength: j.optInt('contextLength'),
        defaultContextLength: (j.opt<JsonMap>('defaults'))?.optInt('contextLength'),
        architecture: j.opt<String>('architecture'),
        parameterCount: j.optInt('parameterCount'),
        license: j.opt<String>('license'),
        toolUse: j.opt<bool>('toolUse') ?? false,
        reasoning: j.opt<bool>('reasoning') ?? false,
        lastUsedAt: j.optDate('lastUsedAt'),
        issue: LibraryIssue.values.asNameMap()[j.opt<String>('issue')] ?? LibraryIssue.none,
      );

  final String id;
  final LibrarySource source;
  final String displayName;
  final ModelFormat format;
  final List<LibraryFile> files;

  /// Library-relative path the engine opens (shard 1 of a split GGUF).
  final String loadPath;
  final DateTime installedAt;

  /// Hub repo and the commit it was pinned to.
  final String? repo;
  final String? revision;
  final String? variantId;
  final String? quant;

  /// Vision/audio projector paired at download time (R08 §13.2 rules).
  final String? mmprojPath;
  final String? draftPath;

  /// Trained context (`<arch>.context_length`).
  final int? contextLength;

  /// Context the engine should open with by default: the largest that Fit
  /// on this device when it was installed.
  final int? defaultContextLength;
  final String? architecture;
  final int? parameterCount;
  final String? license;

  /// From the file's own chat template (quantizers patch templates, so the
  /// file is authoritative, R08 §10).
  final bool toolUse;
  final bool reasoning;
  final DateTime? lastUsedAt;
  final LibraryIssue issue;

  int get sizeBytes => files.fold(0, (a, f) => a + f.sizeBytes);

  bool get hasVision => mmprojPath != null;

  bool get usable => issue == LibraryIssue.none;

  /// Engine defaults. Kept as a map so the local provider can add keys
  /// without a schema change.
  JsonMap get defaultParams => compact({
        'contextLength': defaultContextLength,
        // R04 §21 phone defaults, as assumed by the fit estimate.
        'typeK': 'q8_0',
        'typeV': 'q8_0',
        'flashAttention': true,
      });

  LibraryModel copyWith({DateTime? lastUsedAt, LibraryIssue? issue}) => LibraryModel(
        id: id,
        source: source,
        displayName: displayName,
        format: format,
        files: files,
        loadPath: loadPath,
        installedAt: installedAt,
        repo: repo,
        revision: revision,
        variantId: variantId,
        quant: quant,
        mmprojPath: mmprojPath,
        draftPath: draftPath,
        contextLength: contextLength,
        defaultContextLength: defaultContextLength,
        architecture: architecture,
        parameterCount: parameterCount,
        license: license,
        toolUse: toolUse,
        reasoning: reasoning,
        lastUsedAt: lastUsedAt ?? this.lastUsedAt,
        issue: issue ?? this.issue,
      );

  JsonMap toJson() => compact({
        'id': id,
        'source': source.name,
        'displayName': displayName,
        'format': format.name,
        'files': [for (final f in files) f.toJson()],
        'loadPath': loadPath,
        'installedAt': installedAt.toUtc().toIso8601String(),
        'repo': repo,
        'revision': revision,
        'variantId': variantId,
        'quant': quant,
        'mmprojPath': mmprojPath,
        'draftPath': draftPath,
        'contextLength': contextLength,
        'defaults': defaultParams,
        'architecture': architecture,
        'parameterCount': parameterCount,
        'license': license,
        'toolUse': toolUse,
        'reasoning': reasoning,
        'lastUsedAt': lastUsedAt?.toUtc().toIso8601String(),
        'issue': issue == LibraryIssue.none ? null : issue.name,
      });
}

/// Result of importing a file the user picked.
sealed class ImportOutcome {
  const ImportOutcome();
}

final class Imported extends ImportOutcome {
  const Imported(this.model, {this.warnings = const []});

  final LibraryModel model;
  final List<String> warnings;
}

final class AlreadyImported extends ImportOutcome {
  const AlreadyImported(this.model);

  final LibraryModel model;
}

final class ImportRefused extends ImportOutcome {
  const ImportRefused(this.reason);

  final String reason;
}

/// GGUF metadata read from a local file.
@immutable
final class LocalGgufInfo {
  const LocalGgufInfo({required this.header, required this.fileSize});

  final GgufHeader header;
  final int fileSize;

  GgufMetadata get metadata => header.metadata;
}

/// Reads a local GGUF header like `HfHubClient.readGgufHeader` reads a
/// remote one: 2 MB first, more only if the KV section (or the tensor table,
/// for the exact parameter count) is longer — big-vocab models need ~8 MB,
/// R08 §5.6 — never past [maxBytes]. Throws [GgufFormatException] for files
/// llama.cpp would refuse.
Future<LocalGgufInfo> readLocalGgufHeader(String path, {int maxBytes = 32 << 20}) async {
  final raf = await File(path).open();
  try {
    final size = await raf.length();
    final header = await parseGgufIncrementally((n) async {
      await raf.setPosition(0);
      return raf.read(math.min(n, size));
    }, fileSize: size, maxBytes: maxBytes);
    return LocalGgufInfo(header: header, fileSize: size);
  } finally {
    await raf.close();
  }
}

/// Parses a GGUF header from a growing prefix: [read] returns the first `n`
/// bytes (or the whole file when shorter).
Future<GgufHeader> parseGgufIncrementally(
  Future<Uint8List> Function(int bytes) read, {
  int? fileSize,
  int initialBytes = 2 << 20,
  int maxBytes = 32 << 20,
}) async {
  var head = await read(initialBytes);
  while (true) {
    final r = GgufReader.parse(head, fileSize: fileSize);
    final int need;
    switch (r) {
      case GgufHeader():
        final t = r.tensorInfoRequiredBytes;
        if (r.hasTensorInfo || t == null || t > maxBytes || head.length >= t) return r;
        need = t;
      case GgufNeedMoreBytes(:final requiredBytes):
        if (requiredBytes > maxBytes) {
          throw GgufFormatException('GGUF metadata needs $requiredBytes bytes (limit $maxBytes)');
        }
        need = requiredBytes;
    }
    final have = head.length;
    if (fileSize != null && have >= fileSize) throw const GgufFormatException('the file ends inside its metadata');
    head = await read(math.min(maxBytes, math.max(need, have * 2)));
    if (head.length <= have) throw const GgufFormatException('the file ends inside its metadata');
  }
}

/// Installed local models: records in `DocumentCollections.modelLibrary`,
/// bytes under [ModelStorageLayout.libraryDir].
final class ModelLibrary {
  ModelLibrary({
    required ModelRecordStore store,
    required this.layout,
    FileHasher hasher = const IsolateFileHasher(),
    Clock clock = const SystemClock(),
    IdGenerator? ids,
  })  : _store = store,
        _hasher = hasher,
        _clock = clock,
        _ids = ids ?? RandomIdGenerator();

  static const String collection = DocumentCollections.modelLibrary;

  final ModelRecordStore _store;
  final ModelStorageLayout layout;
  final FileHasher _hasher;
  final Clock _clock;
  final IdGenerator _ids;

  final Map<String, LibraryModel> _models = {};
  final StreamController<List<LibraryModel>> _changes = StreamController.broadcast();
  Future<void>? _loading;
  bool _loaded = false;

  /// Newest first.
  List<LibraryModel> get models =>
      _models.values.toList()..sort((a, b) => b.installedAt.compareTo(a.installedAt));

  Stream<List<LibraryModel>> get changes => _changes.stream;

  LibraryModel? byId(String id) => _models[id];

  /// The installed copy of a Hub variant at a commit, if any.
  LibraryModel? find({required String repo, required String revision, required String variantId}) {
    for (final m in _models.values) {
      if (m.repo == repo && m.revision == revision && m.variantId == variantId) return m;
    }
    return null;
  }

  /// Bytes the library's files take (as verified).
  int get diskUsageBytes => _models.values.fold(0, (a, m) => a + m.sizeBytes);

  Future<void> load() {
    if (_loaded) return Future<void>.value();
    // A failed load is not cached: the next call (the download manager's
    // retried start-up) reads the store again.
    return _loading ??= _load().catchError((Object e, StackTrace s) {
      _loading = null;
      Error.throwWithStackTrace(e, s);
    });
  }

  bool get isLoaded => _loaded;

  Future<void> _load() async {
    for (final doc in await _store.list(collection)) {
      try {
        final m = LibraryModel.fromJson(doc);
        _models[m.id] = m;
      } on Object {
        // A record from a newer app version or a corrupt row: skip it rather
        // than hide the whole library.
      }
    }
    _loaded = true;
    _emit();
  }

  Future<LibraryModel> add(LibraryModel model) async {
    await _store.put(collection, model.id, model.toJson());
    _models[model.id] = model;
    _emit();
    return model;
  }

  Future<void> markUsed(String id) async {
    final m = _models[id];
    if (m == null) return;
    await add(m.copyWith(lastUsedAt: _clock.now()));
  }

  /// Removes the record first (so a crash mid-delete never leaves a record
  /// pointing at half-deleted files), then the files, then empty folders.
  Future<void> delete(String id) async {
    final m = _models.remove(id);
    if (m == null) return;
    await _store.delete(collection, id);
    _emit();
    final dirs = <String>{};
    for (final f in m.files) {
      final abs = layout.libraryPath(f.path);
      dirs.add(p.dirname(abs));
      try {
        final file = File(abs);
        if (file.existsSync()) await file.delete();
      } on FileSystemException {
        // Best effort; the integrity check reports leftovers' absence anyway.
      }
    }
    for (final d in dirs) {
      await _removeEmptyUpTo(d);
    }
  }

  Future<void> _removeEmptyUpTo(String dir) async {
    var d = dir;
    while (p.isWithin(layout.libraryDir, d)) {
      final dd = Directory(d);
      if (!dd.existsSync() || dd.listSync().isNotEmpty) return;
      await dd.delete();
      d = p.dirname(d);
    }
  }

  /// Launch check: every file still there with its verified size; with
  /// [rehash], also its SHA-256 (slow: reads every byte). Returns the models
  /// whose status changed.
  Future<List<LibraryModel>> verifyIntegrity({bool rehash = false}) async {
    final changed = <LibraryModel>[];
    for (final m in _models.values.toList()) {
      var issue = LibraryIssue.none;
      for (final f in m.files) {
        final file = File(layout.libraryPath(f.path));
        if (!file.existsSync()) {
          issue = LibraryIssue.missingFiles;
          break;
        }
        if (await file.length() != f.sizeBytes) {
          issue = LibraryIssue.sizeMismatch;
          break;
        }
        if (rehash && f.sha256 != null && await _hasher.sha256(file.path) != f.sha256) {
          issue = LibraryIssue.hashMismatch;
          break;
        }
      }
      if (issue != m.issue) {
        final next = m.copyWith(issue: issue);
        await _store.put(collection, m.id, next.toJson());
        _models[m.id] = next;
        changed.add(next);
      }
    }
    if (changed.isNotEmpty) _emit();
    return changed;
  }

  /// Copies a user-picked GGUF into the library.
  ///
  /// Refuses, with a reason: pickle-family files (`.bin/.pt/.pth/.ckpt…`,
  /// R08 §11 — they run code on load), anything that is not GGUF by its
  /// magic bytes, big-endian or removed-quant GGUFs llama.cpp can't load,
  /// and files that don't fit in free storage. The header is read before
  /// copying so a wrong file costs no space; the SHA-256 is computed on a
  /// background isolate after the copy and dedupes re-imports.
  Future<ImportOutcome> importFile(
    LocalModelFile source, {
    int? freeStorageBytes,
    DeviceProfile? device,
  }) async {
    await load();
    final name = source.name;
    final ext = FileSafety.extensionOf(name);
    if (FileSafety.pickleExtensions.contains(ext)) {
      return ImportRefused('$name uses a pickle-based format ($ext). Those can run code when loaded, '
          'so Sherpa never opens them. Look for a GGUF version of this model.');
    }
    if (ext != '.gguf') {
      return ImportRefused('Only GGUF model files can be added. "$name" is ${ext.isEmpty ? 'not a .gguf file' : 'a $ext file'}.');
    }

    // Validate from the first bytes before spending storage.
    var head = await readHead(source, 2 << 20);
    switch (sniffWeightFormat(head)) {
      case SniffedFormat.pickle || SniffedFormat.zipArchive:
        return ImportRefused('$name is a Python pickle renamed to .gguf. It could run code, so it was not added.');
      case SniffedFormat.ggufBigEndian:
        return ImportRefused('$name is a big-endian GGUF. Phones are little-endian and cannot load it.');
      case SniffedFormat.legacyGgml:
        return ImportRefused('$name is a legacy GGML file. Current llama.cpp cannot load it.');
      case SniffedFormat.gguf:
        break;
      case SniffedFormat.safetensors || SniffedFormat.unknown:
        return ImportRefused('$name is not a GGUF file (its first bytes are not "GGUF").');
    }
    final length = source.length;
    final GgufHeader header;
    try {
      header = await parseGgufIncrementally(
        (n) async => n <= head.length ? head : head = await readHead(source, n),
        fileSize: length,
      );
    } on GgufFormatException catch (e) {
      return ImportRefused('$name is not a loadable GGUF: ${e.message}.');
    }
    final meta = header.metadata;
    final type = meta.fileTypeInfo;
    if (type != null && type.isRemoved) {
      return ImportRefused('${type.id} was removed from GGUF; llama.cpp cannot load "$name". '
          'Use a Q4_0 or Q4_K_M file of the same model instead.');
    }

    final warnings = <String>[];
    if (length != null) {
      final check = assessStorage(downloadBytes: length, freeBytes: freeStorageBytes);
      if (check.verdict == StorageVerdict.insufficient) return ImportRefused('Not enough space: ${check.message}');
      if (check.verdict == StorageVerdict.tight) warnings.add(check.message);
    }

    await layout.ensure();
    final id = _ids.next('local');
    final tmp = layout.partPath('import_$id');
    final tmpFile = File(tmp);
    try {
      final srcPath = source.path;
      if (srcPath != null) {
        await File(srcPath).copy(tmp);
      } else {
        final sink = tmpFile.openWrite();
        try {
          await sink.addStream(source.openRead());
        } finally {
          await sink.close();
        }
      }
      final size = await tmpFile.length();
      if (length != null && size != length) {
        await tmpFile.delete();
        return ImportRefused('Copying $name stopped early ($size of $length bytes). Try again.');
      }
      final sha = await _hasher.sha256(tmp);
      for (final m in _models.values) {
        if (m.files.any((f) => f.sha256 == sha)) {
          await tmpFile.delete();
          return AlreadyImported(m);
        }
      }
      final safeName = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
      final rel = p.join('imported', id, safeName);
      final dest = layout.libraryPath(rel);
      await Directory(p.dirname(dest)).create(recursive: true);
      await tmpFile.rename(dest);

      final parsed = parseModelName('local/${p.basenameWithoutExtension(name)}', fileName: name);
      final arch = ModelArchitecture.fromGguf(meta, parameterCount: header.parameterCount);
      int? defaultCtx;
      if (device != null && arch != null) {
        final fit = assessFit(
          device,
          ModelFootprintInput(architecture: arch, weightBytes: size, quant: type),
        );
        defaultCtx = fit.recommendedMaxContext;
        if (fit.verdict == FitVerdict.wontFit) {
          warnings.add("This model won't fit in this device's memory: "
              '${fit.reasons.firstWhere((r) => r.severity == FitSeverity.blocking, orElse: () => fit.reasons.first).message}');
        } else if (fit.verdict == FitVerdict.tight) {
          warnings.add('Memory is tight for this model; other apps may be closed while it runs.');
        }
      }
      final model = LibraryModel(
        id: id,
        source: LibrarySource.imported,
        displayName: _displayName(meta, parsed),
        format: ModelFormat.gguf,
        files: [LibraryFile(path: rel, role: FileRole.model, sizeBytes: size, sha256: sha)],
        loadPath: rel,
        installedAt: _clock.now(),
        quant: type?.id ?? parsed.quant?.value.label,
        contextLength: meta.contextLength,
        defaultContextLength: defaultCtx,
        architecture: meta.architecture,
        parameterCount: header.parameterCount,
        license: meta.license,
        toolUse: meta.chatTemplateMentionsTools,
        reasoning: meta.chatTemplateMentionsReasoning,
      );
      await add(model);
      return Imported(model, warnings: warnings);
    } on FileSystemException catch (e) {
      if (tmpFile.existsSync()) await tmpFile.delete();
      return ImportRefused('Could not copy $name: ${e.osError?.message ?? e.message}.');
    }
  }

  static String _displayName(GgufMetadata meta, ParsedModelName parsed) {
    final n = meta.name?.trim();
    if (n != null && n.isNotEmpty) return n;
    return parsed.displayName;
  }

  void _emit() {
    if (!_changes.isClosed) _changes.add(models);
  }

  Future<void> dispose() => _changes.close();
}
