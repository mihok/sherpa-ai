import 'dart:async';

import 'package:sherpa/services/mcp/input/url_opener.dart';
import 'package:sherpa/state/services.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_mcp/sherpa_mcp.dart';
import 'package:sherpa_providers/sherpa_providers.dart';

/// A model provider that answers every request with [reply] (as deltas)
/// and records what it was asked.
final class ScriptedModelProvider implements ModelProvider {
  ScriptedModelProvider({
    this.id = 'scripted',
    this.reply = 'Paris.',
    this.location = ExecutionLocation.remote,
    this.error,
    this.finish = FinishReason.stop,
  });

  final String id;
  String reply;
  final ExecutionLocation location;
  ProviderException? error;
  FinishReason finish;
  final List<ModelRequest> requests = [];

  @override
  ProviderInfo get info => ProviderInfo(id: id, kind: ProviderKind.fake, displayName: 'Scripted', location: location);

  @override
  Future<List<ModelDescriptor>> listModels() async => [
        ModelDescriptor(id: 'm1', providerId: id, displayName: 'Model One', capabilities: ModelCapabilities.unknown),
      ];

  @override
  Future<ModelCapabilities> capabilities(String modelId) async => ModelCapabilities.unknown;

  @override
  Stream<ModelEvent> stream(ModelRequest request, {CancellationToken? cancel}) async* {
    requests.add(request);
    final e = error;
    if (e != null) throw e;
    for (final (i, w) in reply.split(' ').indexed) {
      if (cancel?.isCancelled ?? false) {
        yield const Finish(FinishReason.cancelled);
        return;
      }
      yield TextDelta(i == 0 ? w : ' $w');
    }
    yield UsageUpdate(Usage(inputTokens: 10, outputTokens: reply.split(' ').length));
    yield Finish(finish);
  }
}

/// A registry over fixed providers (no configs, no secrets).
final class FakeProviderRegistry implements ProviderRegistry {
  FakeProviderRegistry(this.providers);

  final Map<String, ModelProvider> providers;
  final List<String> resolved = [];

  @override
  List<ProviderConfig> get configs => const [];

  @override
  Stream<List<ProviderConfig>> get changes => const Stream.empty();

  @override
  Future<ProviderConfig> add(ProviderConfig config, {String? apiKey}) => throw UnimplementedError();

  @override
  Future<ProviderConfig> update(ProviderConfig config, {String? apiKey, bool clearApiKey = false}) =>
      throw UnimplementedError();

  @override
  Future<void> remove(String providerId) async {}

  @override
  Future<bool> hasApiKey(String providerId) async => false;

  @override
  Future<ModelProvider> resolve(String providerId) async {
    resolved.add(providerId);
    final p = providers[providerId];
    if (p == null) throw StateError('unknown provider $providerId');
    return p;
  }

  @override
  Future<List<ModelDescriptor>> models(String providerId, {bool refresh = false}) async =>
      providers[providerId]?.listModels() ?? const [];

  @override
  Future<EndpointStatus> probe(String providerId) async => EndpointStatus.ok;
}

/// Records what would have been opened.
final class RecordingUrlOpener implements McpUrlOpener {
  RecordingUrlOpener({this.succeed = true});

  bool succeed;
  final List<(Uri, McpUrlTarget)> opened = [];

  @override
  Future<bool> open(Uri url, {McpUrlTarget target = McpUrlTarget.inAppBrowser}) async {
    opened.add((url, target));
    return succeed;
  }
}

McpInputContext inputContext({
  String serverId = 'srv',
  String serverName = 'Example tools',
  String? sessionId = 'chat-1',
  String? toolName = 'srv__ask',
  CancellationToken? cancel,
}) =>
    McpInputContext(
      serverId: serverId,
      serverName: serverName,
      era: McpEra.modern,
      cancel: cancel ?? CancellationToken(),
      originMethod: 'tools/call',
      originName: 'ask',
      origin: sessionId == null && toolName == null ? null : McpCallOrigin(sessionId: sessionId, toolName: toolName),
    );

McpElicitRequest formRequest(Map<String, Object?> properties, {List<String> required = const [], String message = 'Tell me'}) =>
    McpElicitRequest.fromJson({
      'mode': 'form',
      'message': message,
      'requestedSchema': {'type': 'object', 'properties': properties, 'required': required},
    });

McpSamplingRequest samplingRequest({
  String text = 'What is the capital of France?',
  int maxTokens = 100,
  String? includeContext,
  List<Map<String, Object?>> tools = const [],
  String? systemPrompt,
}) =>
    McpSamplingRequest.fromJson({
      'messages': [
        {
          'role': 'user',
          'content': {'type': 'text', 'text': text},
        },
      ],
      'maxTokens': maxTokens,
      'includeContext': ?includeContext,
      if (tools.isNotEmpty) 'tools': tools,
      'systemPrompt': ?systemPrompt,
      'modelPreferences': {
        'hints': [
          {'name': 'claude'},
        ],
        'speedPriority': 0.9,
      },
    });

/// Lets microtasks and zero timers run.
Future<void> pump([int rounds = 20]) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

const ModelChoice defaultChoice = ModelChoice(providerId: 'scripted', modelId: 'm1');
