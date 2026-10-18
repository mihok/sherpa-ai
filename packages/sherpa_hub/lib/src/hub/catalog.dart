import 'package:meta/meta.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../download/download_plan.dart';
import '../fit/device_fit.dart';
import '../gguf/gguf_metadata.dart';
import '../naming/model_name.dart';
import '../naming/name_types.dart';
import 'hub_client.dart';
import 'hub_models.dart';

/// A browser card.
@immutable
final class CatalogEntry {
  const CatalogEntry({
    required this.id,
    required this.name,
    this.downloads,
    this.likes,
    this.lastModified,
    this.gating = HubGating.none,
    this.tags = const [],
    this.pipelineTag,
    this.toolUseHint = false,
    this.summary,
  });

  final String id;
  final ParsedModelName name;
  final int? downloads;
  final int? likes;
  final DateTime? lastModified;
  final HubGating gating;
  final List<String> tags;
  final String? pipelineTag;

  /// Heuristic only (template of an arbitrary repo file, author tags).
  final bool toolUseHint;
  final HubModelSummary? summary;

  /// Hidden by the default content filter (PLAN §7 Q7).
  bool get isUncensored => name.isUncensored;
}

@immutable
final class CatalogFile {
  const CatalogFile({required this.file, required this.name});

  final HubRepoFile file;
  final ParsedModelName name;
}

/// A detail screen: one pinned commit, its variants and gate/licence info.
@immutable
final class CatalogModelDetails {
  const CatalogModelDetails({
    required this.id,
    required this.commit,
    required this.name,
    required this.variants,
    required this.files,
    this.gating = HubGating.none,
    this.license,
    this.cardData,
    this.security,
    this.parameterCount,
    this.toolUseHint = false,
    this.reasoningHint = false,
    this.executionLocation = ExecutionLocation.onDevice,
    this.info,
  });

  final String id;

  /// Commit sha every download of this screen is pinned to.
  final String commit;
  final ParsedModelName name;
  final List<RepoVariant> variants;
  final List<CatalogFile> files;
  final HubGating gating;
  final String? license;
  final HubCardData? cardData;
  final HubRepoSecurity? security;

  /// `safetensors.total` when present (logical count, R08 §0.6).
  final int? parameterCount;
  final bool toolUseHint;
  final bool reasoningHint;

  /// Models from a catalog run locally once downloaded.
  final ExecutionLocation executionLocation;
  final HubModelInfo? info;

  RepoVariant? get defaultVariant => defaultVariantOf(variants);
}

/// Indirection so the getter above reads naturally.
RepoVariant? defaultVariantOf(List<RepoVariant> variants) => defaultVariant(variants);

/// Where models come from: the Hub, a local folder, a LAN peer, or a
/// fixture (PLAN §2 core interfaces table).
abstract interface class ModelCatalog {
  /// Stable source id (`huggingface`, `folder:…`, `lan:…`).
  String get id;

  Future<HubPage<CatalogEntry>> search(ModelSearchQuery query, {String? cursor});

  /// Details at [revision] (default: the main branch), pinned to its commit.
  Future<CatalogModelDetails> details(String modelId, {String? revision});

  /// Full listing with per-file hashes and scan status.
  Future<List<CatalogFile>> files(String modelId, {required String revision});
}

/// [ModelCatalog] over the Hugging Face Hub.
final class HfHubCatalog implements ModelCatalog {
  HfHubCatalog(this.client);

  final HfHubClient client;

  @override
  String get id => 'huggingface';

  @override
  Future<HubPage<CatalogEntry>> search(ModelSearchQuery query, {String? cursor}) async {
    final page = await client.searchModels(query, cursor: cursor);
    return HubPage(
      [
        for (final m in page.items)
          CatalogEntry(
            id: m.id,
            name: parseModelName(m.id),
            downloads: m.downloads,
            likes: m.likes,
            lastModified: m.lastModified,
            gating: m.gating,
            tags: m.tags,
            pipelineTag: m.pipelineTag,
            toolUseHint: _toolHint(m.tags, m.gguf?.chatTemplate),
            summary: m,
          ),
      ],
      nextCursor: page.nextCursor,
    );
  }

  @override
  Future<CatalogModelDetails> details(String modelId, {String? revision}) async {
    final info = await client.modelInfo(modelId, revision: revision);
    final commit = info.sha;
    if (commit == null) {
      throw StateError('the Hub returned no commit sha for $modelId');
    }
    final variants = groupVariants(modelId, info.files, repoSecurity: info.security);
    final template = info.config?.chatTemplate ?? info.gguf?.chatTemplate;
    return CatalogModelDetails(
      id: info.id.isEmpty ? modelId : info.id,
      commit: commit,
      name: parseModelName(modelId),
      variants: variants,
      files: [for (final f in info.files) CatalogFile(file: f, name: parseModelName(modelId, fileName: f.path))],
      gating: info.gating,
      license: info.cardData?.license,
      cardData: info.cardData,
      security: info.security,
      parameterCount: info.safetensors?.total,
      toolUseHint: _toolHint(info.tags, template),
      reasoningHint: template != null && ChatTemplateSignals.mentionsReasoning(template),
      info: info,
    );
  }

  @override
  Future<List<CatalogFile>> files(String modelId, {required String revision}) async {
    final list = await client.listFiles(modelId, revision: revision);
    return [
      for (final f in list)
        if (!f.isDirectory) CatalogFile(file: f, name: parseModelName(modelId, fileName: f.path)),
    ];
  }

  static bool _toolHint(List<String> tags, String? template) =>
      tags.contains('tool-use') ||
      tags.contains('function-calling') ||
      (template != null && ChatTemplateSignals.mentionsTools(template));
}

/// Capabilities of a downloaded local model, from its own GGUF header
/// (quantizers patch templates, so the file's template is authoritative)
/// and the fit decision.
ModelCapabilities localModelCapabilities({
  required GgufMetadata metadata,
  required int contextLength,
  QuantLabel? quant,
  bool hasProjector = false,
  FitResult? fit,
  int? parameterCount,
}) =>
    ModelCapabilities(
      contextLength: contextLength,
      // llama.cpp builds a lazy grammar from templates that render tools
      // (R04 §12); otherwise Sherpa's prompted JSON envelope is used.
      toolCallFormat: metadata.chatTemplateMentionsTools ? ToolCallFormat.jsonGrammar : ToolCallFormat.prompted,
      parallelToolCalls: false,
      vision: hasProjector,
      reasoning: metadata.chatTemplateMentionsReasoning ? ReasoningSupport.optional : ReasoningSupport.none,
      quantization: quant?.label ?? metadata.fileTypeInfo?.id,
      parameterCount: parameterCount,
      ramEstimateBytes: fit?.demandBytes,
      tokenizerFamily: metadata.tokenizerPre ?? metadata.tokenizerModel,
      supportsPromptCache: true,
      // KV prefix reuse wants an append-only history (sherpa_core HistoryPolicy).
      historyPolicy: HistoryPolicy.appendOnly,
    );
