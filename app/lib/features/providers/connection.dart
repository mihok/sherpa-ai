import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_providers/sherpa_providers.dart';

import '../../state/services.dart';
import 'presets.dart';

/// Result of saving a provider and testing it.
final class ConnectionResult {
  const ConnectionResult({required this.config, required this.status, this.models = const []});

  final ProviderConfig config;
  final EndpointStatus status;

  /// Filled when [status] is ok.
  final List<ModelDescriptor> models;

  bool get ok => status == EndpointStatus.ok;
}

/// Saves [config] (adding it, or updating it when it already exists), then
/// probes it and, on success, lists its models.
///
/// The registry only probes saved providers, so testing a new provider means
/// saving it first; callers that let the user back out remove it again.
Future<ConnectionResult> saveAndProbe(
  ProviderRegistry registry,
  ProviderConfig config, {
  String? apiKey,
  bool clearApiKey = false,
}) async {
  final exists = registry.configs.any((c) => c.id == config.id);
  final saved = exists
      ? await registry.update(config, apiKey: apiKey, clearApiKey: clearApiKey)
      : await registry.add(config, apiKey: apiKey);
  final status = await registry.probe(saved.id);
  if (status != EndpointStatus.ok) return ConnectionResult(config: saved, status: status);
  try {
    final models = await registry.models(saved.id);
    return ConnectionResult(config: saved, status: status, models: models);
  } on Object {
    return ConnectionResult(config: saved, status: EndpointStatus.error);
  }
}

/// A readable, unique id: `openai`, `openai-2`, … (it also names the secret
/// key, `provider/<id>/api_key`, so it must never change once created).
String uniqueProviderId(String base, Iterable<String> existing) {
  final taken = existing.toSet();
  final slug = base.toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
  final root = slug.isEmpty ? 'provider' : slug;
  if (!taken.contains(root)) return root;
  for (var i = 2;; i++) {
    final candidate = '$root-$i';
    if (!taken.contains(candidate)) return candidate;
  }
}

/// What to tell the user about a probe result, with a next step.
({String title, String message}) explainStatus(EndpointStatus status, {required String host, ProviderPreset? preset}) =>
    switch (status) {
      EndpointStatus.ok => (title: 'Connected', message: 'Sherpa can talk to $host.'),
      EndpointStatus.unauthorized => (
          title: 'Key not accepted',
          message: '$host rejected the ${preset?.keyLabel.toLowerCase() ?? 'key'}. '
              'Check that you copied all of it and that it is still active.',
        ),
      EndpointStatus.unreachable => (
          title: "Couldn't reach $host",
          message: preset?.isLocalServer ?? false
              ? 'Make sure the server is running, listening on the network (not just localhost), '
                  'and that this phone is on the same Wi-Fi.'
              : 'Check your connection and the address, then try again.',
        ),
      EndpointStatus.error => (
          title: 'Unexpected answer from $host',
          message: 'The server responded, but not like the API Sherpa expected. '
              'Check the address (OpenAI-compatible servers usually end in /v1) and the API type.',
        ),
      EndpointStatus.unknown => (title: 'Not tested yet', message: 'Test the connection to see if it works.'),
    };
