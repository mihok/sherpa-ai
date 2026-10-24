import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_net/sherpa_net.dart';

// The list/detail endpoints are not in the Hub's OpenAPI spec and their
// fields change without notice (R08 §16 risk 5), so every parser here is
// lenient: wrong types become null, unknown keys are ignored.

String? _str(Object? v) => v is String ? v : null;
int? _int(Object? v) => v is num ? v.toInt() : (v is String ? int.tryParse(v) : null);
double? _dbl(Object? v) => v is num ? v.toDouble() : null;
bool? _bool(Object? v) => v is bool ? v : null;
JsonMap? _map(Object? v) => v is Map ? v.cast<String, Object?>() : null;
List<Object?> _list(Object? v) => v is List ? v : const [];
DateTime? _date(Object? v) => v is String ? DateTime.tryParse(v) : null;
List<String> _strings(Object? v) => [for (final e in _list(v)) if (e is String) e];

/// `gated`: `false`, `"auto"` (instant approval after the form) or
/// `"manual"` (the author reviews; can take days). R08 §3.1.
enum HubGating {
  none,
  auto,
  manual;

  static HubGating parse(Object? v) => switch (v) {
        'auto' => auto,
        'manual' => manual,
        true => manual,
        _ => none,
      };

  bool get isGated => this != none;
}

/// Sort keys accepted by `GET /api/models` (R08 §0.2). Only [createdAt]
/// accepts ascending order; the others answer 400.
enum HubSort {
  trending('trendingScore'),
  downloads('downloads'),
  likes('likes'),
  likes30d('likes30d'),
  lastModified('lastModified'),
  createdAt('createdAt');

  const HubSort(this.apiValue);

  final String apiValue;
}

/// Library tags for `filter=` (`library=` is silently ignored, R08 §0.1).
enum HubFormatFilter {
  gguf('gguf'),
  mlx('mlx'),
  litert('litert-lm'),
  tflite('tflite'),
  onnx('onnx');

  const HubFormatFilter(this.tag);

  final String tag;
}

/// Publishers whose quantizations Sherpa pins in the browser (R08 §13.3).
abstract final class TrustedPublishers {
  static const List<String> gguf = ['ggml-org', 'unsloth', 'bartowski', 'lmstudio-community', 'mradermacher'];
  static const List<String> mlx = ['mlx-community', 'lmstudio-community'];
  static const List<String> litert = ['litert-community', 'google'];
}

/// A browse/search request.
@immutable
final class ModelSearchQuery {
  const ModelSearchQuery({
    this.text,
    this.format,
    this.pipelineTag,
    this.authors = const [],
    this.sort = HubSort.trending,
    this.ascending = false,
    this.limit = 30,
    this.tags = const [],
    this.gated,
    this.expand = defaultExpand,
    this.quantizedFrom,
  });

  /// Case-insensitive substring over `author/name`.
  final String? text;
  final HubFormatFilter? format;
  final String? pipelineTag;

  /// Only quantized versions of this repo (`filter=base_model:quantized:<id>`,
  /// the tag the Hub gives repos that name it as their quantization base):
  /// the GGUF copies of a Transformers model, say. The id is matched
  /// exactly, case included.
  final String? quantizedFrom;

  /// Exact namespaces. The API takes one `author`; several are fanned out
  /// into one request each and merged (see `HfHubClient.searchModels`).
  final List<String> authors;
  final HubSort sort;
  final bool ascending;

  /// Capped at 1000 by the server; 20–50 for UI pages (R08 §2.1).
  final int limit;

  /// Extra `filter=` tags, ANDed (`conversational`, `license:apache-2.0`).
  final List<String> tags;
  final bool? gated;

  /// `expand[]` fields. Using expand replaces the default field set, so it
  /// must name everything a card shows (R08 §2.4 recommended browse query).
  final List<String> expand;

  /// What a browser card needs. Not `siblings`: cards never use the file
  /// list (the detail page reads it with sizes), and it only made every
  /// page heavier. `gguf` stays: its chat template is where most repos say
  /// they render tools (24 of 30 on a live trending page, against 3 tagged
  /// `tool-use`/`function-calling`).
  static const List<String> defaultExpand = [
    'author', 'downloads', 'likes', 'lastModified', 'createdAt', 'trendingScore', 'gated', 'private', 'tags',
    'pipeline_tag', 'library_name', 'safetensors', 'gguf',
  ];

  ModelSearchQuery copyWith({List<String>? authors, int? limit}) => ModelSearchQuery(
        text: text,
        format: format,
        pipelineTag: pipelineTag,
        authors: authors ?? this.authors,
        sort: sort,
        ascending: ascending,
        limit: limit ?? this.limit,
        tags: tags,
        gated: gated,
        expand: expand,
        quantizedFrom: quantizedFrom,
      );

  /// Every `filter=` tag of the request, ANDed by the server.
  List<String> get filterTags => [
        if (format != null) format!.tag,
        if (quantizedFrom != null) 'base_model:quantized:$quantizedFrom',
        ...tags,
      ];
}

/// One page plus the opaque cursor for the next (null = last page).
@immutable
final class HubPage<T> {
  const HubPage(this.items, {this.nextCursor});

  final List<T> items;
  final String? nextCursor;

  bool get hasMore => nextCursor != null;
}

/// The repo-level `gguf` summary. It describes **one arbitrary file** of
/// the repo — sometimes an MTP draft (R08 §0.5) — so it is a hint for the
/// browser card only, never a size for device fit.
@immutable
final class HubGgufSummary {
  const HubGgufSummary({this.total, this.architecture, this.contextLength, this.chatTemplate, this.totalFileSize});

  static HubGgufSummary? parse(Object? v) {
    final m = _map(v);
    if (m == null) return null;
    return HubGgufSummary(
      total: _int(m['total']),
      architecture: _str(m['architecture']),
      contextLength: _int(m['context_length']),
      chatTemplate: _str(m['chat_template']),
      totalFileSize: _int(m['totalFileSize']),
    );
  }

  final int? total;
  final String? architecture;
  final int? contextLength;
  final String? chatTemplate;
  final int? totalFileSize;
}

/// `safetensors`: dtype → count and the **logical** total (good "model
/// size" truth even for packed GPTQ/MLX weights, R08 §0.6).
@immutable
final class HubSafetensorsInfo {
  const HubSafetensorsInfo({required this.parameters, this.total});

  static HubSafetensorsInfo? parse(Object? v) {
    final m = _map(v);
    if (m == null) return null;
    final p = _map(m['parameters']) ?? const {};
    return HubSafetensorsInfo(
      parameters: {for (final e in p.entries) if (_int(e.value) != null) e.key: _int(e.value)!},
      total: _int(m['total']),
    );
  }

  final Map<String, int> parameters;
  final int? total;
}

/// A search result card.
@immutable
final class HubModelSummary {
  const HubModelSummary({
    required this.id,
    this.internalId,
    this.author,
    this.downloads,
    this.likes,
    this.trendingScore,
    this.lastModified,
    this.createdAt,
    this.gating = HubGating.none,
    this.isPrivate = false,
    this.tags = const [],
    this.pipelineTag,
    this.libraryName,
    this.gguf,
    this.safetensors,
    this.siblings = const [],
  });

  factory HubModelSummary.fromJson(JsonMap j) => HubModelSummary(
        id: _str(j['id']) ?? _str(j['modelId']) ?? '',
        internalId: _str(j['_id']),
        author: _str(j['author']),
        downloads: _int(j['downloads']),
        likes: _int(j['likes']),
        trendingScore: _dbl(j['trendingScore']),
        lastModified: _date(j['lastModified']),
        createdAt: _date(j['createdAt']),
        gating: HubGating.parse(j['gated']),
        isPrivate: _bool(j['private']) ?? false,
        tags: _strings(j['tags']),
        pipelineTag: _str(j['pipeline_tag']),
        libraryName: _str(j['library_name']),
        gguf: HubGgufSummary.parse(j['gguf']),
        safetensors: HubSafetensorsInfo.parse(j['safetensors']),
        siblings: [for (final s in _list(j['siblings'])) if (_str(_map(s)?['rfilename']) != null) _str(_map(s)!['rfilename'])!],
      );

  final String id;

  /// Mongo `_id`: stable dedupe key across pages (cursors can repeat items
  /// when sort values change between pages, R08 §2.3).
  final String? internalId;
  final String? author;

  /// 30-day downloads.
  final int? downloads;
  final int? likes;
  final double? trendingScore;
  final DateTime? lastModified;
  final DateTime? createdAt;
  final HubGating gating;
  final bool isPrivate;
  final List<String> tags;
  final String? pipelineTag;
  final String? libraryName;
  final HubGgufSummary? gguf;
  final HubSafetensorsInfo? safetensors;

  /// File names only — list responses carry no sizes.
  final List<String> siblings;

  String get dedupeKey => internalId ?? id;

  /// The value the list was sorted by (for merging fanned-out pages).
  num sortValue(HubSort s) => switch (s) {
        HubSort.trending => trendingScore ?? 0,
        HubSort.downloads => downloads ?? 0,
        HubSort.likes || HubSort.likes30d => likes ?? 0,
        HubSort.lastModified => lastModified?.millisecondsSinceEpoch ?? 0,
        HubSort.createdAt => createdAt?.millisecondsSinceEpoch ?? 0,
      };

  /// What the Hub says about the repo's format that its name may not
  /// (`parseModelName`'s `repoHints`; see [hubFormatHints]).
  Set<String> get formatHints => hubFormatHints(libraryName: libraryName, pipelineTag: pipelineTag, tags: tags);
}

/// The name parser's format hints from what the Hub says about a whole repo
/// (`parseModelName`'s `repoHints`, `groupVariants`' `formatHints`): `mlx`
/// for an MLX conversion of a language model, which is often tagged `mlx`
/// (or has that `library_name`) without "mlx" in its name. An MLX speech,
/// image or embedding model gets none: Sherpa's MLX runtime loads language
/// models only, so its weights stay plain safetensors to Sherpa.
Set<String> hubFormatHints({String? libraryName, String? pipelineTag, List<String> tags = const []}) {
  final mlx = libraryName == 'mlx' || tags.contains('mlx');
  // No pipeline tag: trust only an `mlx` library (mflux image models are
  // tagged `mlx` too).
  final language = pipelineTag == null ? libraryName == 'mlx' : _languagePipelines.contains(pipelineTag);
  return mlx && language ? const {'mlx'} : const {};
}

/// Pipelines whose MLX conversions mlx-swift-lm's language-model factory
/// loads (a vision-language checkpoint loads as its text model).
const Set<String> _languagePipelines = {'text-generation', 'image-text-to-text'};

/// Hub scanner verdicts (R08 §11: `safe`, `unsafe`, `suspicious`,
/// `unscanned`; repo-level levels `unsafe`, `caution`).
enum HubScanStatus {
  safe,
  caution,
  suspicious,
  unsafe,
  unscanned,
  unknown;

  static HubScanStatus parse(Object? v) => switch (v) {
        'safe' => safe,
        'caution' => caution,
        'suspicious' => suspicious,
        'unsafe' => unsafe,
        'unscanned' => unscanned,
        _ => unknown,
      };

  /// R08 §15.8: block any file the Hub flags `unsafe` or `suspicious`.
  bool get blocks => this == unsafe || this == suspicious;
}

@immutable
final class HubPickleImport {
  const HubPickleImport({required this.module, required this.name, required this.safety});

  final String module;
  final String name;

  /// `innocuous`, `suspicious` or `dangerous`.
  final String safety;
}

/// Per-file `securityFileStatus` (tree / paths-info with `expand=true`).
@immutable
final class HubFileSecurity {
  const HubFileSecurity({required this.status, this.scanners = const {}, this.pickleImports = const [], this.messages = const []});

  static HubFileSecurity? parse(Object? v) {
    final m = _map(v);
    if (m == null) return null;
    final scanners = <String, HubScanStatus>{};
    final messages = <String>[];
    var imports = const <HubPickleImport>[];
    for (final e in m.entries) {
      final s = _map(e.value);
      if (s == null) continue;
      scanners[e.key] = HubScanStatus.parse(s['status']);
      final msg = _str(s['message']);
      if (msg != null) messages.add('${e.key}: $msg');
      if (e.key == 'pickleImportScan') {
        imports = [
          for (final i in _list(s['pickleImports']))
            if (_map(i) case final im?)
              HubPickleImport(
                  module: _str(im['module']) ?? '', name: _str(im['name']) ?? '', safety: _str(im['safety']) ?? 'unknown'),
        ];
      }
    }
    var status = HubScanStatus.parse(m['status']);
    // Trust the worst scanner even when the summary says otherwise.
    for (final s in scanners.values) {
      if (s.blocks && !status.blocks) status = s;
    }
    return HubFileSecurity(status: status, scanners: scanners, pickleImports: imports, messages: messages);
  }

  final HubScanStatus status;
  final Map<String, HubScanStatus> scanners;
  final List<HubPickleImport> pickleImports;
  final List<String> messages;

  bool get blocks => status.blocks || pickleImports.any((i) => i.safety == 'dangerous');

  JsonMap toJson() => {
        'status': status.name,
        for (final e in scanners.entries) e.key: {'status': e.value.name},
      };
}

@immutable
final class HubLastCommit {
  const HubLastCommit({required this.id, this.title, this.date});

  final String id;
  final String? title;
  final DateTime? date;
}

/// A file (or directory) in a repo, from `tree`, `paths-info` or
/// `?blobs=true` siblings.
@immutable
final class HubRepoFile {
  const HubRepoFile({
    required this.path,
    this.isDirectory = false,
    this.size,
    this.oid,
    this.lfsSha256,
    this.lfsSize,
    this.xetHash,
    this.lastCommit,
    this.security,
  });

  /// Tree / paths-info entry.
  factory HubRepoFile.fromTreeJson(JsonMap j) {
    final lfs = _map(j['lfs']);
    final commit = _map(j['lastCommit']);
    return HubRepoFile(
      path: _str(j['path']) ?? '',
      isDirectory: _str(j['type']) == 'directory',
      size: _int(j['size']),
      oid: _str(j['oid']),
      lfsSha256: _str(lfs?['oid']) ?? _str(lfs?['sha256']),
      lfsSize: _int(lfs?['size']),
      xetHash: _str(j['xetHash']),
      lastCommit: commit == null || _str(commit['id']) == null
          ? null
          : HubLastCommit(id: _str(commit['id'])!, title: _str(commit['title']), date: _date(commit['date'])),
      security: HubFileSecurity.parse(j['securityFileStatus']),
    );
  }

  /// `siblings[]` entry of `/api/models/{repo}?blobs=true`.
  factory HubRepoFile.fromSiblingJson(JsonMap j) {
    final lfs = _map(j['lfs']);
    return HubRepoFile(
      path: _str(j['rfilename']) ?? '',
      size: _int(j['size']),
      oid: _str(j['blobId']),
      lfsSha256: _str(lfs?['sha256']) ?? _str(lfs?['oid']),
      lfsSize: _int(lfs?['size']),
    );
  }

  /// Round-trips through [toJson] (tree shape).
  factory HubRepoFile.fromJson(JsonMap j) => HubRepoFile.fromTreeJson(j);

  final String path;
  final bool isDirectory;
  final int? size;

  /// Git blob sha1 (also the `X-Linked-ETag` of small non-LFS files).
  final String? oid;

  /// SHA-256 of the content (`lfs.oid`) — the integrity hash to verify.
  final String? lfsSha256;
  final int? lfsSize;

  /// Xet content hash = the CDN `ETag`; compare before resuming (R08 §5.5).
  final String? xetHash;
  final HubLastCommit? lastCommit;
  final HubFileSecurity? security;

  bool get isLfs => lfsSha256 != null;

  String get name => path.split('/').last;

  /// Merges security info from another listing of the same path.
  HubRepoFile withSecurity(HubFileSecurity? s) => HubRepoFile(
        path: path,
        isDirectory: isDirectory,
        size: size,
        oid: oid,
        lfsSha256: lfsSha256,
        lfsSize: lfsSize,
        xetHash: xetHash,
        lastCommit: lastCommit,
        security: s ?? security,
      );

  JsonMap toJson() => compact({
        'path': path,
        'type': isDirectory ? 'directory' : 'file',
        'size': size,
        'oid': oid,
        'lfs': lfsSha256 == null ? null : compact({'oid': lfsSha256, 'size': lfsSize}),
        'xetHash': xetHash,
        'securityFileStatus': security?.toJson(),
      });
}

/// `securityRepoStatus` / `/scan`.
@immutable
final class HubRepoSecurity {
  const HubRepoSecurity({required this.scansDone, this.filesWithIssues = const {}});

  static HubRepoSecurity? parse(Object? v) {
    final m = _map(v);
    if (m == null) return null;
    return HubRepoSecurity(
      scansDone: _bool(m['scansDone']) ?? false,
      filesWithIssues: {
        for (final f in _list(m['filesWithIssues']))
          if (_str(_map(f)?['path']) != null) _str(_map(f)!['path'])!: HubScanStatus.parse(_map(f)!['level']),
      },
    );
  }

  final bool scansDone;

  /// Path → level (`unsafe`, `caution`).
  final Map<String, HubScanStatus> filesWithIssues;
}

/// Model card fields Sherpa shows (license, gate prompt).
@immutable
final class HubCardData {
  const HubCardData({
    this.license,
    this.licenseName,
    this.licenseLink,
    this.baseModels = const [],
    this.quantizedBy,
    this.gatePrompt,
    this.gateFields = const {},
    this.gateButton,
    this.gateDescription,
  });

  static HubCardData? parse(Object? v) {
    final m = _map(v);
    if (m == null) return null;
    final base = m['base_model'];
    final fields = _map(m['extra_gated_fields']) ?? const {};
    return HubCardData(
      license: _str(m['license']),
      licenseName: _str(m['license_name']),
      licenseLink: _str(m['license_link']),
      baseModels: base is String ? [base] : _strings(base),
      quantizedBy: _str(m['quantized_by']),
      gatePrompt: _str(m['extra_gated_prompt']),
      gateFields: {
        for (final e in fields.entries) e.key: e.value is String ? e.value! as String : _str(_map(e.value)?['type']) ?? 'unknown',
      },
      gateButton: _str(m['extra_gated_button_content']),
      gateDescription: _str(m['extra_gated_description']),
    );
  }

  final String? license;
  final String? licenseName;
  final String? licenseLink;
  final List<String> baseModels;
  final String? quantizedBy;

  /// Markdown, can be 13 KB (R08 §7.3).
  final String? gatePrompt;

  /// Field label → type (`text`, `date_picker`, `country`, `checkbox`,
  /// `select`, `ip_location`).
  final Map<String, String> gateFields;
  final String? gateButton;
  final String? gateDescription;
}

/// Summarized `config` (no group size; that needs `config.json` itself).
@immutable
final class HubConfigSummary {
  const HubConfigSummary({this.modelType, this.architectures = const [], this.quantBits, this.quantMethod, this.chatTemplate});

  static HubConfigSummary? parse(Object? v) {
    final m = _map(v);
    if (m == null) return null;
    final q = _map(m['quantization_config']);
    final tok = _map(m['tokenizer_config']);
    final tpl = m['chat_template_jinja'] ?? tok?['chat_template'];
    return HubConfigSummary(
      modelType: _str(m['model_type']),
      architectures: _strings(m['architectures']),
      quantBits: _int(q?['bits']),
      quantMethod: _str(q?['quant_method']),
      chatTemplate: tpl is String ? tpl : null,
    );
  }

  final String? modelType;
  final List<String> architectures;
  final int? quantBits;
  final String? quantMethod;
  final String? chatTemplate;
}

/// `/api/models/{repo}[/revision/{rev}]?blobs=true&securityStatus=true`.
@immutable
final class HubModelInfo {
  const HubModelInfo({
    required this.id,
    this.internalId,
    this.sha,
    this.author,
    this.lastModified,
    this.createdAt,
    this.gating = HubGating.none,
    this.isPrivate = false,
    this.disabled = false,
    this.downloads,
    this.likes,
    this.tags = const [],
    this.pipelineTag,
    this.libraryName,
    this.cardData,
    this.config,
    this.gguf,
    this.safetensors,
    this.files = const [],
    this.security,
    this.usedStorage,
  });

  factory HubModelInfo.fromJson(JsonMap j) => HubModelInfo(
        id: _str(j['id']) ?? _str(j['modelId']) ?? '',
        internalId: _str(j['_id']),
        sha: _str(j['sha']),
        author: _str(j['author']),
        lastModified: _date(j['lastModified']),
        createdAt: _date(j['createdAt']),
        gating: HubGating.parse(j['gated']),
        isPrivate: _bool(j['private']) ?? false,
        disabled: _bool(j['disabled']) ?? false,
        downloads: _int(j['downloads']),
        likes: _int(j['likes']),
        tags: _strings(j['tags']),
        pipelineTag: _str(j['pipeline_tag']),
        libraryName: _str(j['library_name']),
        cardData: HubCardData.parse(j['cardData']),
        config: HubConfigSummary.parse(j['config']),
        gguf: HubGgufSummary.parse(j['gguf']),
        safetensors: HubSafetensorsInfo.parse(j['safetensors']),
        files: [for (final s in _list(j['siblings'])) if (_map(s) case final m?) HubRepoFile.fromSiblingJson(m)],
        security: HubRepoSecurity.parse(j['securityRepoStatus']),
        usedStorage: _int(j['usedStorage']),
      );

  final String id;
  final String? internalId;

  /// Commit of the resolved revision: pin every download to it.
  final String? sha;
  final String? author;
  final DateTime? lastModified;
  final DateTime? createdAt;
  final HubGating gating;
  final bool isPrivate;
  final bool disabled;
  final int? downloads;
  final int? likes;
  final List<String> tags;
  final String? pipelineTag;
  final String? libraryName;
  final HubCardData? cardData;
  final HubConfigSummary? config;
  final HubGgufSummary? gguf;
  final HubSafetensorsInfo? safetensors;

  /// Siblings with sizes and sha256 when fetched with `blobs=true`.
  final List<HubRepoFile> files;
  final HubRepoSecurity? security;

  /// All revisions — not a download size.
  final int? usedStorage;

  /// What the Hub says about the repo's format that its file names may
  /// not ([hubFormatHints]), for `groupVariants` and `parseModelName`.
  Set<String> get formatHints => hubFormatHints(libraryName: libraryName, pipelineTag: pipelineTag, tags: tags);

  /// The repo this one is a quantized copy of (its `base_model:quantized:`
  /// tag), when it is one.
  String? get quantizedFrom {
    for (final t in tags) {
      if (t.startsWith(_quantizedTag) && t.length > _quantizedTag.length) return t.substring(_quantizedTag.length);
    }
    return null;
  }

  /// The repo this one names as its base, whatever the relation: the plain
  /// `base_model:<id>` tag, else the first `base_model:<relation>:<id>`.
  /// The Hub writes these ids exactly, case included.
  String? get baseModel {
    String? related;
    for (final t in tags) {
      if (!t.startsWith(_baseTag) || t.length == _baseTag.length) continue;
      final rest = t.substring(_baseTag.length);
      final colon = rest.indexOf(':');
      if (colon < 0) return rest;
      if (colon < rest.length - 1) related ??= rest.substring(colon + 1);
    }
    return related;
  }

  static const String _quantizedTag = 'base_model:quantized:';
  static const String _baseTag = 'base_model:';
}

/// `GET /{repo}/resolve/{rev}/{path}` answered without following redirects.
@immutable
final class ResolvedDownload {
  const ResolvedDownload({
    required this.repo,
    required this.revision,
    required this.path,
    required this.url,
    required this.sendAuthorization,
    required this.statusCode,
    this.commit,
    this.size,
    this.linkedEtag,
    this.xetHash,
    this.expiresAt,
  });

  factory ResolvedDownload.fromJson(JsonMap j) => ResolvedDownload(
        repo: j.req<String>('repo'),
        revision: j.req<String>('revision'),
        path: j.req<String>('path'),
        url: Uri.parse(j.req<String>('url')),
        sendAuthorization: j.opt<bool>('sendAuthorization') ?? false,
        statusCode: j.optInt('statusCode') ?? 0,
        commit: j.opt<String>('commit'),
        size: j.optInt('size'),
        linkedEtag: j.opt<String>('linkedEtag'),
        xetHash: j.opt<String>('xetHash'),
        expiresAt: j.optDate('expiresAt'),
      );

  final String repo;
  final String revision;
  final String path;

  /// Where the bytes are: the signed CDN URL for LFS/Xet files (302), the
  /// relative `resolve-cache` URL made absolute for small files (307), or
  /// the resolve URL itself (200).
  final Uri url;

  /// True only when [url] is on the Hub's own origin. The token never goes
  /// to the CDN (R08 §5.5 step 2).
  final bool sendAuthorization;
  final int statusCode;

  /// `X-Repo-Commit`.
  final String? commit;

  /// `X-Linked-Size`: the real file size (the 302's `Content-Length` is the
  /// redirect body).
  final int? size;

  /// `X-Linked-ETag` without quotes: SHA-256 for LFS files, git blob sha1
  /// for small files.
  final String? linkedEtag;

  /// `X-Xet-Hash` (= CDN `ETag`). If-Range is ignored by the CDN, so
  /// resumes compare this instead (R08 §0.9).
  final String? xetHash;

  /// `Expires` of the CloudFront signature (+3600 s).
  final DateTime? expiresAt;

  bool get isCdnRedirect => !sendAuthorization;

  /// SHA-256 when [linkedEtag] has that shape.
  String? get sha256 => linkedEtag != null && RegExp(r'^[0-9a-f]{64}$').hasMatch(linkedEtag!) ? linkedEtag : null;

  bool isExpired(DateTime now, {Duration skew = const Duration(minutes: 2)}) =>
      expiresAt != null && !now.isBefore(expiresAt!.subtract(skew));

  /// The signed URL is a short-lived credential: persist it only in the
  /// encrypted store, never in logs.
  JsonMap toJson() => compact({
        'repo': repo,
        'revision': revision,
        'path': path,
        'url': url.toString(),
        'sendAuthorization': sendAuthorization,
        'statusCode': statusCode,
        'commit': commit,
        'size': size,
        'linkedEtag': linkedEtag,
        'xetHash': xetHash,
        'expiresAt': expiresAt?.toUtc().toIso8601String(),
      });

  @override
  String toString() => 'ResolvedDownload($repo@$revision/$path → ${Redactor.uri(url)}, size $size)';
}

/// `/api/whoami-v2`.
@immutable
final class HubWhoAmI {
  const HubWhoAmI({required this.name, this.fullName, this.orgs = const [], this.tokenRole, this.isPro});

  factory HubWhoAmI.fromJson(JsonMap j) {
    final auth = _map(j['auth']);
    final token = _map(auth?['accessToken']);
    return HubWhoAmI(
      name: _str(j['name']) ?? '',
      fullName: _str(j['fullname']),
      orgs: [for (final o in _list(j['orgs'])) if (_str(_map(o)?['name']) != null) _str(_map(o)!['name'])!],
      tokenRole: _str(token?['role']),
      isPro: _bool(j['isPro']),
    );
  }

  final String name;
  final String? fullName;
  final List<String> orgs;

  /// `read`, `write` or `fineGrained`.
  final String? tokenRole;
  final bool? isPro;
}

/// "Sign in with Hugging Face" endpoints from the live OIDC discovery
/// (R08 §8.1). Public client, Authorization Code + PKCE S256 only.
abstract final class HubOAuth {
  static final Uri issuer = Uri.parse('https://huggingface.co');
  static final Uri authorize = Uri.parse('https://huggingface.co/oauth/authorize');
  static final Uri token = Uri.parse('https://huggingface.co/oauth/token');
  static final Uri device = Uri.parse('https://huggingface.co/oauth/device');
  static final Uri userinfo = Uri.parse('https://huggingface.co/oauth/userinfo');
  static final Uri jwks = Uri.parse('https://huggingface.co/oauth/jwks');

  /// R08 §15.5: gated downloads + Inference Providers.
  static const List<String> recommendedScopes = ['openid', 'profile', 'gated-repos', 'inference-api'];

  /// The server rejects shorter PKCE verifiers (R08 §0.15).
  static const int minCodeVerifierLength = 43;
}
