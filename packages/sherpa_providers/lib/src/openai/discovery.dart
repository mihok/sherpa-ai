import 'dart:async';
import 'dart:convert';

import 'package:sherpa_core/sherpa_core.dart';

import '../common/endpoint_policy.dart';
import '../common/error_mapping.dart';
import '../common/http_runner.dart';
import '../common/json_read.dart';
import 'known_models.dart';
import 'quirks.dart';

/// Model ids whose tool calling OpenAI only offers over Responses (R10 §3.6).
bool chatToolsUnavailable(String modelId) {
  final id = modelId.toLowerCase();
  return id == 'gpt-6-astra' || id.startsWith('gpt-6-astra-') || id == 'gpt-6.1-sol' || id.startsWith('gpt-6.1-sol-');
}

final class _Cached {
  const _Cached(this.value, this.expires);
  final ModelCapabilities value;
  final DateTime expires;
}

/// Per-server model listing and context-length discovery (R10 §6).
///
/// Results are cached per model with a TTL: long for authoritative answers
/// (a server-reported window), short for fallbacks that will change once
/// the model is loaded (Ollama `/api/ps`, LM Studio `loaded_instances`) or
/// for failures, so a server that was briefly down is asked again soon.
/// [ProviderConfig.modelOverrides] always win and are never cached.
final class ModelDiscovery {
  ModelDiscovery({
    required ProviderHttp http,
    required Future<Uri> Function() baseUrl,
    required Map<String, String> Function() headers,
    required Clock clock,
    required this.providerId,
    this.overrides = const {},
    this.forChat = true,
  })  : _http = http,
        _baseUrl = baseUrl,
        _headers = headers,
        _clock = clock;

  static const Duration authoritativeTtl = Duration(minutes: 10);
  static const Duration provisionalTtl = Duration(seconds: 30);

  /// Ollama's documented default below 24 GiB VRAM; used when nothing more
  /// specific is known so an agent prompt is not planned against the
  /// model's much larger trained window.
  static const int ollamaFallbackContext = 4096;

  final ProviderHttp _http;
  final Future<Uri> Function() _baseUrl;
  final Map<String, String> Function() _headers;
  final Clock _clock;
  final String providerId;
  final Map<String, ModelCapabilities> overrides;

  /// Chat Completions (true) or Responses (false): changes tool support for
  /// OpenAI models that only call tools over Responses.
  final bool forChat;

  final Map<String, _Cached> _cache = {};
  Future<List<JsonMap>>? _remoteList;
  DateTime? _remoteListExpires;

  void _put(String id, ModelCapabilities caps, {required bool authoritative}) {
    _cache[id] = _Cached(caps, _clock.now().add(authoritative ? authoritativeTtl : provisionalTtl));
  }

  ModelCapabilities? _cached(String id) {
    final c = _cache[id];
    if (c == null) return null;
    if (_clock.now().isAfter(c.expires)) {
      _cache.remove(id);
      return null;
    }
    return c.value;
  }

  /// Forgets cached capabilities (e.g. after the user reloaded a model).
  void invalidate() {
    _cache.clear();
    _remoteList = null;
  }

  Future<FetchedResponse> _get(Uri url) => _http.fetch(url: url, headers: {'accept': 'application/json', ..._headers()});

  Future<JsonMap> _getJson(Uri url) async {
    final r = await _get(url);
    if (!r.ok) {
      throw mapHttpError(statusCode: r.statusCode, headers: r.headers, body: r.body, providerId: providerId,
          now: _clock.now());
    }
    final json = r.json;
    if (json == null) {
      throw ProviderException(ProviderErrorKind.invalidRequest, 'Expected a JSON object from ${url.path}',
          providerId: providerId);
    }
    return json;
  }

  Future<JsonMap?> _tryJson(Uri url, {String method = 'GET', String? body}) async {
    try {
      final r = await _http.fetch(
        url: url,
        method: method,
        body: body,
        headers: {'accept': 'application/json', if (body != null) 'content-type': 'application/json', ..._headers()},
      );
      return r.ok ? r.json : null;
    } on Exception {
      return null;
    }
  }

  /// `GET {base}/models`, shared (and cached) for list-based discovery.
  Future<List<JsonMap>> _models() {
    final expires = _remoteListExpires;
    if (_remoteList != null && expires != null && _clock.now().isBefore(expires)) return _remoteList!;
    _remoteListExpires = _clock.now().add(authoritativeTtl);
    final pending = () async {
      final json = await _getJson(joinPath(await _baseUrl(), '/models'));
      return json.maps('data');
    }();
    _remoteList = pending;
    pending.catchError((Object _) {
      if (identical(_remoteList, pending)) _remoteList = null;
      return const <JsonMap>[];
    }).ignore();
    return pending;
  }

  /// Lists the server's models with whatever capabilities the list itself
  /// carries; per-model probing (Ollama `/api/show`) is left to
  /// [capabilities] so listing stays one request.
  Future<List<ModelDescriptor>> listModels(ServerQuirks quirks) async {
    _remoteList = null;
    final entries = await _models();
    final lmStudio = quirks.contextDiscovery == ContextDiscovery.lmStudioModels ? await _lmStudioModels() : null;
    final out = <ModelDescriptor>[];
    for (final e in entries) {
      final id = e.text('id');
      if (id == null) continue;
      var caps = overrides[id] ?? _cached(id);
      if (caps == null) {
        final fromList = _fromListEntry(e, quirks) ?? _fromLmStudio(id, lmStudio);
        if (fromList != null) {
          caps = _pdfGate(id, fromList, quirks);
          _put(id, caps, authoritative: true);
        } else if (quirks.contextDiscovery == ContextDiscovery.llamaCppProps ||
            quirks.contextDiscovery == ContextDiscovery.staticTable) {
          caps = await capabilities(id, quirks);
        } else {
          caps = _toolGate(id, ModelCapabilities.unknown);
        }
        caps = _pdfGate(id, caps, quirks);
      }
      out.add(ModelDescriptor(
        id: id,
        providerId: providerId,
        displayName: e.text('name') ?? e.text('display_name') ?? id,
        capabilities: caps,
        description: e.text('description'),
      ));
    }
    return out;
  }

  /// Capabilities for [modelId]: overrides, then cache, then the server's
  /// own discovery method, then [ModelCapabilities.unknown].
  Future<ModelCapabilities> capabilities(String modelId, ServerQuirks quirks) async {
    final override = overrides[modelId];
    if (override != null) return override;
    final cached = _cached(modelId);
    if (cached != null) return cached;
    try {
      final (caps, authoritative) = await _discover(modelId, quirks);
      final gated = _pdfGate(modelId, _toolGate(modelId, caps), quirks);
      _put(modelId, gated, authoritative: authoritative);
      return gated;
    } on Exception {
      final fallback = _pdfGate(modelId, _toolGate(modelId, ModelCapabilities.unknown), quirks);
      _put(modelId, fallback, authoritative: false);
      return fallback;
    }
  }

  ModelCapabilities _toolGate(String modelId, ModelCapabilities caps) =>
      forChat && chatToolsUnavailable(modelId) ? caps.copyWith(toolCallFormat: ToolCallFormat.none) : caps;

  /// PDF input as the server allows it ([ServerQuirks.pdfInput]): never on
  /// servers without file parts, by family on OpenAI, from the listing
  /// (`input_modalities: file`) on OpenRouter.
  static ModelCapabilities _pdfGate(String modelId, ModelCapabilities caps, ServerQuirks quirks) {
    final pdf = switch (quirks.pdfInput) {
      PdfInputSupport.none => false,
      PdfInputSupport.openAiModels => openAiModelTakesPdf(modelId),
      PdfInputSupport.all => caps.pdfInput,
    };
    return pdf == caps.pdfInput ? caps : caps.copyWith(pdfInput: pdf);
  }

  Future<(ModelCapabilities, bool)> _discover(String id, ServerQuirks quirks) async {
    switch (quirks.contextDiscovery) {
      case ContextDiscovery.staticTable:
        final known = lookupKnownModel(id);
        return (known?.capabilities(forChat: forChat) ?? ModelCapabilities.unknown, true);
      case ContextDiscovery.llamaCppProps:
        return _llamaCpp(id);
      case ContextDiscovery.ollamaShow:
        return _ollama(id);
      case ContextDiscovery.lmStudioModels:
        return _lmStudio(id);
      case ContextDiscovery.vllmModels || ContextDiscovery.openRouterModels || ContextDiscovery.huggingFaceModels:
        final entries = await _models();
        final base = id.split(':').first;
        final entry = entries.where((e) => e.str('id') == id).firstOrNull ??
            entries.where((e) => e.str('id') == base).firstOrNull;
        final caps = entry == null ? null : _fromListEntry(entry, quirks, requestedId: id);
        return (caps ?? ModelCapabilities.unknown, caps != null);
      case ContextDiscovery.none:
        return (ModelCapabilities.unknown, true);
    }
  }

  /// Capabilities carried by a `/models` entry, where the server puts any.
  ModelCapabilities? _fromListEntry(JsonMap e, ServerQuirks quirks, {String? requestedId}) {
    switch (quirks.contextDiscovery) {
      case ContextDiscovery.vllmModels:
        final len = e.integer('max_model_len');
        return len == null || len <= 0 ? null : ModelCapabilities(contextLength: len);
      case ContextDiscovery.openRouterModels:
        return _openRouterEntry(e);
      case ContextDiscovery.huggingFaceModels:
        return _huggingFaceEntry(e, requestedId ?? e.str('id') ?? '');
      case ContextDiscovery.staticTable ||
            ContextDiscovery.llamaCppProps ||
            ContextDiscovery.ollamaShow ||
            ContextDiscovery.lmStudioModels ||
            ContextDiscovery.none:
        return null;
    }
  }

  static ModelCapabilities? _openRouterEntry(JsonMap e) {
    final top = e.child('top_provider');
    final ctx = e.integer('context_length') ?? top?.integer('context_length');
    if (ctx == null || ctx <= 0) return null;
    final params = {for (final p in e.items('supported_parameters') ?? const <Object?>[]) '$p'};
    final inputs = {for (final m in e.child('architecture')?.items('input_modalities') ?? const <Object?>[]) '$m'};
    final reasoning = e.child('reasoning');
    return ModelCapabilities(
      contextLength: ctx,
      maxOutputTokens: top?.integer('max_completion_tokens'),
      toolCallFormat: params.isEmpty || params.contains('tools') ? ToolCallFormat.native : ToolCallFormat.none,
      parallelToolCalls: params.isEmpty || params.contains('parallel_tool_calls') || params.contains('tools'),
      vision: inputs.contains('image'),
      pdfInput: inputs.contains('file'),
      reasoning: reasoning?.flag('mandatory') ?? false
          ? ReasoningSupport.always
          : (params.contains('reasoning') || reasoning != null ? ReasoningSupport.optional : ReasoningSupport.none),
      supportsPromptCache: true,
    );
  }

  /// HF router: the provider chosen by a `:<provider>` suffix, else the
  /// smallest window among live providers (any of them may serve the call).
  static ModelCapabilities? _huggingFaceEntry(JsonMap e, String requestedId) {
    final providers = e.maps('providers');
    final colon = requestedId.lastIndexOf(':');
    final suffix = colon < 0 ? null : requestedId.substring(colon + 1);
    final policy = const {'fastest', 'cheapest', 'preferred'};
    Iterable<JsonMap> pool = providers;
    if (suffix != null && !policy.contains(suffix)) {
      pool = providers.where((p) => p.str('provider') == suffix);
    } else {
      final live = providers.where((p) => (p.str('status') ?? 'live') == 'live');
      if (live.isNotEmpty) pool = live;
    }
    final windows = [for (final p in pool) if (p.integer('context_length') case final c? when c > 0) c];
    if (windows.isEmpty) return null;
    final tools = pool.any((p) => p.flag('supports_tools') ?? false);
    final inputs = {for (final m in e.child('architecture')?.items('input_modalities') ?? const <Object?>[]) '$m'};
    return ModelCapabilities(
      contextLength: windows.reduce((a, b) => a < b ? a : b),
      toolCallFormat: tools ? ToolCallFormat.native : ToolCallFormat.none,
      vision: inputs.contains('image'),
    );
  }

  Future<(ModelCapabilities, bool)> _llamaCpp(String id) async {
    final root = serverRoot(await _baseUrl());
    final propsUrl = joinPath(root, '/props');
    // Router mode serves per-model props; a single-model server ignores
    // the query, and an older one might not, hence the plain fallback.
    final props = await _tryJson(propsUrl.replace(queryParameters: {...propsUrl.queryParameters, 'model': id})) ??
        await _tryJson(propsUrl);
    final settings = props?.child('default_generation_settings');
    var ctx = settings?.integer('n_ctx') ?? props?.integer('n_ctx');
    if (ctx == null || ctx <= 0) {
      final entries = await _models();
      final entry = entries.where((e) => e.str('id') == id).firstOrNull ?? entries.firstOrNull;
      final meta = entry?.child('meta');
      ctx = meta?.integer('n_ctx') ?? meta?.integer('n_ctx_train');
    }
    if (ctx == null || ctx <= 0) return (ModelCapabilities.unknown, false);
    final templateCaps = props?.child('chat_template_caps');
    final nPredict = settings?.integer('n_predict') ?? settings?.child('params')?.integer('n_predict');
    return (
      ModelCapabilities(
        contextLength: ctx,
        maxOutputTokens: nPredict != null && nPredict > 0 ? nPredict : null,
        parallelToolCalls: templateCaps?.flag('supports_parallel_tool_calls') ?? true,
        vision: props?.child('modalities')?.flag('vision') ?? false,
        audioInput: props?.child('modalities')?.flag('audio') ?? false,
        supportsSystemRole: templateCaps?.flag('supports_system_role') ?? true,
        supportsPromptCache: true,
      ),
      true,
    );
  }

  Future<(ModelCapabilities, bool)> _ollama(String id) async {
    final base = await _baseUrl();
    final root = serverRoot(base);
    final show = await _tryJson(joinPath(root, '/api/show'), method: 'POST', body: jsonEncode({'model': id, 'name': id}));
    final ps = await _tryJson(joinPath(root, '/api/ps'));
    if (show == null && ps == null) return (ModelCapabilities.unknown, false);

    final info = show?.child('model_info') ?? const <String, Object?>{};
    final arch = info.str('general.architecture');
    int? trained = arch == null ? null : info.integer('$arch.context_length');
    if (trained == null) {
      for (final e in info.entries) {
        if (e.key.endsWith('.context_length') && e.value is num) trained = (e.value! as num).toInt();
      }
    }
    final numCtx = int.tryParse(
        RegExp(r'^\s*num_ctx\s+(\d+)', multiLine: true).firstMatch(show?.str('parameters') ?? '')?.group(1) ?? '');
    int? loaded;
    for (final m in ps?.maps('models') ?? const <JsonMap>[]) {
      if (_sameOllamaModel(m.str('name'), id) || _sameOllamaModel(m.str('model'), id)) {
        loaded = m.integer('context_length');
        break;
      }
    }
    // Cloud models default to their maximum (R10 §4.2).
    final cloud = base.host.toLowerCase() == 'ollama.com';
    final provisional = loaded == null && numCtx == null && !cloud;
    final ctx = loaded ??
        numCtx ??
        (cloud ? trained : null) ??
        (trained == null ? ollamaFallbackContext : (trained < ollamaFallbackContext ? trained : ollamaFallbackContext));
    final caps = {for (final c in show?.items('capabilities') ?? const <Object?>[]) '$c'};
    final hasCapList = show?.items('capabilities') != null;
    return (
      ModelCapabilities(
        contextLength: ctx,
        toolCallFormat: !hasCapList || caps.contains('tools') ? ToolCallFormat.native : ToolCallFormat.none,
        vision: caps.contains('vision'),
        reasoning: caps.contains('thinking') ? ReasoningSupport.optional : ReasoningSupport.none,
      ),
      !provisional,
    );
  }

  /// Ollama names default to the `latest` tag (`qwen3` == `qwen3:latest`).
  static bool _sameOllamaModel(String? a, String b) {
    if (a == null) return false;
    String norm(String s) => s.contains(':') ? s : '$s:latest';
    return norm(a) == norm(b);
  }

  Future<List<JsonMap>?> _lmStudioModels() async {
    final root = serverRoot(await _baseUrl());
    return (await _tryJson(joinPath(root, '/api/v1/models')))?.maps('models');
  }

  static ModelCapabilities? _fromLmStudio(String id, List<JsonMap>? models) {
    if (models == null) return null;
    for (final m in models) {
      final instances = m.maps('loaded_instances');
      if (m.str('key') != id && !instances.any((i) => i.str('id') == id)) continue;
      final loaded = instances.map((i) => i.child('config')?.integer('context_length')).nonNulls.firstOrNull;
      final ctx = loaded ?? m.integer('max_context_length');
      if (ctx == null || ctx <= 0) return null;
      final caps = m.child('capabilities');
      return ModelCapabilities(
        contextLength: ctx,
        toolCallFormat: caps?.flag('trained_for_tool_use') ?? true ? ToolCallFormat.native : ToolCallFormat.none,
        vision: caps?.flag('vision') ?? false,
        reasoning: caps?.child('reasoning') != null ? ReasoningSupport.optional : ReasoningSupport.none,
      );
    }
    return null;
  }

  Future<(ModelCapabilities, bool)> _lmStudio(String id) async {
    final v1 = await _lmStudioModels();
    final fromV1 = _fromLmStudio(id, v1);
    if (fromV1 != null) {
      final loaded = v1!.any((m) => m.maps('loaded_instances').isNotEmpty && (m.str('key') == id));
      return (fromV1, loaded);
    }
    final root = serverRoot(await _baseUrl());
    final v0 = (await _tryJson(joinPath(root, '/api/v0/models')))?.maps('data') ?? const <JsonMap>[];
    for (final m in v0) {
      if (m.str('id') != id) continue;
      final ctx = m.integer('loaded_context_length') ?? m.integer('max_context_length');
      if (ctx == null || ctx <= 0) break;
      return (
        ModelCapabilities(contextLength: ctx, vision: m.str('type') == 'vlm'),
        m.str('state') == 'loaded',
      );
    }
    return (ModelCapabilities.unknown, false);
  }
}
