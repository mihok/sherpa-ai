import 'dart:async';

import 'package:sherpa/features/chat/state/chat_dependencies.dart';
import 'package:sherpa/features/chat/state/frame_scheduler.dart';
import 'package:sherpa/state/services.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_providers/sherpa_providers.dart';

/// In-memory [ProviderRegistry] over prebuilt [ModelProvider]s.
final class FakeProviderRegistry implements ProviderRegistry {
  FakeProviderRegistry({
    List<ProviderConfig> configs = const [],
    Map<String, ModelProvider> providers = const {},
    Map<String, List<ModelDescriptor>> models = const {},
  })  : _configs = [...configs],
        _providers = {...providers},
        _models = {...models};

  final List<ProviderConfig> _configs;
  final Map<String, ModelProvider> _providers;
  final Map<String, List<ModelDescriptor>> _models;
  final StreamController<List<ProviderConfig>> _changes = StreamController.broadcast();

  /// Makes [models] fail for these provider ids.
  final Set<String> failingModelLists = {};
  int modelCalls = 0;

  void setProvider(String id, ModelProvider provider) => _providers[id] = provider;

  @override
  List<ProviderConfig> get configs => List.unmodifiable(_configs);

  @override
  Stream<List<ProviderConfig>> get changes => _changes.stream;

  @override
  Future<ProviderConfig> add(ProviderConfig config, {String? apiKey}) async {
    _configs.add(config);
    _changes.add(configs);
    return config;
  }

  @override
  Future<ProviderConfig> update(ProviderConfig config, {String? apiKey, bool clearApiKey = false}) async {
    final i = _configs.indexWhere((c) => c.id == config.id);
    if (i >= 0) _configs[i] = config;
    _changes.add(configs);
    return config;
  }

  @override
  Future<void> remove(String providerId) async {
    _configs.removeWhere((c) => c.id == providerId);
    _providers.remove(providerId);
    _changes.add(configs);
  }

  @override
  Future<bool> hasApiKey(String providerId) async => true;

  @override
  Future<ModelProvider> resolve(String providerId) async =>
      _providers[providerId] ?? (throw StateError('unknown provider $providerId'));

  @override
  Future<List<ModelDescriptor>> models(String providerId, {bool refresh = false}) async {
    modelCalls++;
    if (failingModelLists.contains(providerId)) {
      throw const ProviderException(ProviderErrorKind.network, 'offline');
    }
    return _models[providerId] ?? (await _providers[providerId]?.listModels()) ?? const [];
  }

  @override
  Future<EndpointStatus> probe(String providerId) async => EndpointStatus.ok;
}

final class FakePreferences implements PreferencesStore {
  FakePreferences({this.defaultModel});

  @override
  ModelChoice? defaultModel;

  final StreamController<void> _changes = StreamController.broadcast();

  @override
  Future<void> setDefaultModel(ModelChoice? choice) async {
    defaultModel = choice;
    _changes.add(null);
  }

  @override
  bool onboardingComplete = true;

  @override
  Future<void> setOnboardingComplete(bool value) async => onboardingComplete = value;

  @override
  Stream<void> get changes => _changes.stream;
}

/// Records clipboard, share and haptic calls instead of hitting platform
/// channels.
final class RecordingPlatformActions implements ChatPlatformActions {
  final List<String> copied = [];
  final List<String> shared = [];
  final List<ChatHaptic> haptics = [];

  @override
  Future<void> copyText(String text) async => copied.add(text);

  @override
  Future<void> shareText(String text, {String? subject}) async => shared.add(text);

  @override
  Future<void> haptic(ChatHaptic kind) async => haptics.add(kind);
}

/// Frames happen only when the test calls [tick].
final class ManualFrameScheduler implements FrameScheduler {
  final List<void Function()> _pending = [];
  int frames = 0;

  int get pendingCount => _pending.length;

  @override
  void scheduleFrameCallback(void Function() callback) => _pending.add(callback);

  void tick() {
    frames++;
    final due = List.of(_pending);
    _pending.clear();
    for (final cb in due) {
      cb();
    }
  }
}

/// Runs "frame" callbacks on the next microtask: for tests that only care
/// about final state.
final class MicrotaskFrameScheduler implements FrameScheduler {
  @override
  void scheduleFrameCallback(void Function() callback) => scheduleMicrotask(callback);
}

/// A provider the test drives event by event, to pause mid-stream.
final class ManualProvider implements ModelProvider {
  ManualProvider({
    this.capabilitiesValue = const ModelCapabilities(contextLength: 32768),
    ProviderInfo? info,
  }) : info = info ??
            ProviderInfo(
              id: 'manual',
              kind: ProviderKind.fake,
              displayName: 'Manual',
              location: ExecutionLocation.remote,
              baseUrl: Uri.parse('https://api.example.com/v1'),
            );

  @override
  final ProviderInfo info;
  final ModelCapabilities capabilitiesValue;
  final List<ModelRequest> requests = [];
  StreamController<ModelEvent>? _current;
  Completer<void> _started = Completer();
  bool cancelled = false;

  /// Completes when the agent opened the next stream.
  Future<void> get started => _started.future;

  bool get isStreaming => _current != null;

  @override
  Future<List<ModelDescriptor>> listModels() async => [
        ModelDescriptor(id: 'manual-model', providerId: info.id, displayName: 'Manual model', capabilities: capabilitiesValue),
      ];

  @override
  Future<ModelCapabilities> capabilities(String modelId) async => capabilitiesValue;

  @override
  Stream<ModelEvent> stream(ModelRequest request, {CancellationToken? cancel}) {
    requests.add(request);
    late final StreamController<ModelEvent> c;
    c = StreamController<ModelEvent>(onCancel: () => cancelled = true);
    _current = c;
    cancel?.whenCancelled.then((_) {
      if (c.isClosed) return;
      c.add(const Finish(FinishReason.cancelled));
      unawaited(c.close());
    });
    if (!_started.isCompleted) _started.complete();
    return c.stream;
  }

  void emit(ModelEvent e) => _current?.add(e);

  void emitAll(Iterable<ModelEvent> events) => events.forEach(emit);

  /// Ends the current stream normally (after a [Finish]).
  Future<void> finish([FinishReason reason = FinishReason.stop]) async {
    final c = _current;
    if (c == null) return;
    _current = null;
    _started = Completer();
    c.add(Finish(reason));
    await c.close();
  }

  Future<void> fail(Object error) async {
    final c = _current;
    if (c == null) return;
    _current = null;
    _started = Completer();
    c.addError(error);
    await c.close();
  }
}

/// Configurable in-process tool.
final class FakeTool implements LocalTool {
  FakeTool(
    this.name, {
    this.title,
    this.annotations = const ToolAnnotations(readOnlyHint: true, openWorldHint: false),
    this.onRun,
  });

  final String name;
  final String? title;
  final ToolAnnotations annotations;
  final Future<ToolResult> Function(Map<String, Object?> args, ToolExecutionContext ctx)? onRun;
  final List<Map<String, Object?>> calls = [];

  @override
  ToolDefinition get definition => ToolDefinition(
        name: name,
        title: title,
        description: 'test tool $name',
        inputSchema: const {'type': 'object'},
        annotations: annotations,
      );

  @override
  Future<ToolResult> run(Map<String, Object?> arguments, ToolExecutionContext context) async {
    calls.add(arguments);
    if (onRun != null) return onRun!(arguments, context);
    return ToolResult.text('$name ok');
  }
}

/// A tool that needs approval (not read-only, not destructive).
FakeTool writeTool(String name, {String? title}) => FakeTool(
      name,
      title: title,
      annotations: const ToolAnnotations(readOnlyHint: false, destructiveHint: false, openWorldHint: false),
    );

/// A tool the policy classifies as destructive.
FakeTool destructiveTool(String name, {String? title}) => FakeTool(
      name,
      title: title,
      annotations: const ToolAnnotations(readOnlyHint: false, destructiveHint: true),
    );
