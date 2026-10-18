import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:sherpa_core/sherpa_core.dart';

import '../common/endpoint_policy.dart';
import '../common/http_runner.dart';
import '../common/json_read.dart';
import '../config.dart';

/// Profiles recognised from the host name alone (R10 §5 step 1).
ServerProfile? profileForKnownHost(Uri baseUrl) {
  final host = baseUrl.host.toLowerCase();
  bool isOrUnder(String domain) => host == domain || host.endsWith('.$domain');
  if (host == 'api.openai.com') return ServerProfile.openAi;
  if (isOrUnder('openrouter.ai')) return ServerProfile.openRouter;
  if (host == 'router.huggingface.co') return ServerProfile.huggingFaceRouter;
  if (host == 'api.deepseek.com') return ServerProfile.deepSeek;
  if (host == 'ollama.com') return ServerProfile.ollama;
  return null;
}

/// Identifies the server behind an OpenAI-compatible [baseUrl].
///
/// Known hosts are recognised without traffic. Otherwise the R10 §5 probes
/// run in parallel, each bounded by [timeout], and the result is decided by
/// priority rather than by whichever answers first, because the signals
/// overlap: llama.cpp's `/v1/models` carries an Ollama-shaped `models` key,
/// and Ollama and vLLM both have a `version` endpoint (on different paths).
///
/// Never throws; anything inconclusive is [ServerProfile.generic]. The
/// caller is responsible for having validated [baseUrl] against its URL
/// policy; probes never follow redirects.
Future<ServerProfile> detectServerProfile(
  Uri baseUrl,
  http.Client client, {
  Map<String, String> headers = const {},
  Duration timeout = const Duration(milliseconds: 2500),
}) async {
  final known = profileForKnownHost(baseUrl);
  if (known != null) return known;
  try {
    final net = ProviderHttp(client: client);
    final root = serverRoot(baseUrl);
    Future<FetchedResponse?> probe(Uri url) async {
      try {
        return await net.fetch(url: url, headers: {'accept': 'application/json', ...headers}, timeout: timeout,
            maxBytes: 4 << 20);
      } on Exception {
        return null;
      }
    }

    final results = await Future.wait([
      probe(joinPath(root, '/api/version')),
      probe(joinPath(root, '/props')),
      probe(joinPath(root, '/api/v1/models')),
      probe(joinPath(root, '/api/v0/models')),
      probe(joinPath(baseUrl, '/models')),
    ]);
    return classifyProbes(
      apiVersion: results[0],
      props: results[1],
      lmStudioV1: results[2],
      lmStudioV0: results[3],
      models: results[4],
    );
  } on Object {
    return ServerProfile.generic;
  }
}

/// Decides a profile from probe responses (null = no answer). Exposed for
/// tests and for callers that already hold some of these documents.
ServerProfile classifyProbes({
  FetchedResponse? apiVersion,
  FetchedResponse? props,
  FetchedResponse? lmStudioV1,
  FetchedResponse? lmStudioV0,
  FetchedResponse? models,
}) {
  JsonMap? okJson(FetchedResponse? r) => r != null && r.ok ? r.json : null;

  final modelEntries = okJson(models)?.maps('data') ?? const <JsonMap>[];
  final ownedBy = {for (final m in modelEntries) m.str('owned_by')?.toLowerCase()};

  final propsJson = okJson(props);
  if ((propsJson != null && propsJson.child('default_generation_settings') != null) || ownedBy.contains('llamacpp')) {
    return ServerProfile.llamaCpp;
  }
  if (ownedBy.contains('vllm') || modelEntries.any((m) => m['max_model_len'] != null)) {
    return ServerProfile.vllm;
  }
  // LM Studio >= 0.4: `{"models":[{"key":..}]}`; an empty list still counts
  // because nothing else serves `/api/v1/models` with that shape.
  final v1Json = okJson(lmStudioV1);
  final v1 = v1Json?.maps('models') ?? const <JsonMap>[];
  if (v1Json?.items('models') != null && (v1.isEmpty || v1.first.str('key') != null)) {
    return ServerProfile.lmStudio;
  }
  final v0 = okJson(lmStudioV0)?.maps('data') ?? const <JsonMap>[];
  if (v0.isNotEmpty && v0.first['max_context_length'] != null && v0.first['state'] != null) {
    return ServerProfile.lmStudio;
  }
  if (okJson(apiVersion)?.str('version') != null) return ServerProfile.ollama;
  if (models != null && models.headers.containsKey('openai-version')) return ServerProfile.openAi;
  return ServerProfile.generic;
}
