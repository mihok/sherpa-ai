// The engine host, lifecycle manager and provider come from
// `package:sherpa_inference/engine.dart`, the Flutter-free entry library
// (the package's main library also exports the Android process host, which
// imports Flutter and so cannot load under `dart run`).
library;

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_inference/engine.dart';
import 'package:sherpa_providers/sherpa_providers.dart';

/// What `--model` names.
sealed class ModelSpec {
  const ModelSpec();

  /// `scripted`, `local:<path.gguf>` or `remote:<provider.json | inline JSON>`.
  static ModelSpec parse(String text) {
    final t = text.trim();
    if (t == 'scripted') return const ScriptedModelSpec();
    if (t.startsWith('local:')) {
      final path = t.substring('local:'.length);
      if (path.isEmpty) throw const FormatException('local: needs a GGUF path');
      return LocalModelSpecArg(path);
    }
    if (t.startsWith('remote:')) {
      final arg = t.substring('remote:'.length).trim();
      final json = arg.startsWith('{') ? arg : File(arg).readAsStringSync();
      return RemoteModelSpec((jsonDecode(json) as Map).cast<String, Object?>());
    }
    throw FormatException('unknown --model "$text" (use scripted, local:<gguf> or remote:<provider json>)');
  }

  /// Short label for reports and file names.
  String get label;

  /// `scripted`, `local` or `remote`: baseline file key.
  String get kind;

  bool get isScripted => this is ScriptedModelSpec;
}

final class ScriptedModelSpec extends ModelSpec {
  const ScriptedModelSpec();

  @override
  String get label => 'scripted';

  @override
  String get kind => 'scripted';
}

final class LocalModelSpecArg extends ModelSpec {
  const LocalModelSpecArg(this.path);

  final String path;

  @override
  String get label => 'local:${p.basename(path)}';

  @override
  String get kind => 'local';
}

/// A remote provider: a `ProviderConfig` JSON plus `model` (the model id)
/// and `apiKeyEnv` (the environment variable holding the key).
final class RemoteModelSpec extends ModelSpec {
  const RemoteModelSpec(this.json);

  final Map<String, Object?> json;

  @override
  String get label => 'remote:${json['id'] ?? 'provider'}/${json['model'] ?? json['defaultModelId'] ?? ''}';

  @override
  String get kind => 'remote';
}

/// A live model a suite can run sessions against.
abstract interface class ModelRuntime {
  ModelProvider get provider;
  String get modelId;

  /// Exact counter when the runtime has one (local engine), else null.
  TokenCounter? get counter;

  /// Wraps a context manager (the local engine warms its token cache).
  ContextManager wrap(ContextManager inner);

  /// Generation parameters suites should use (deterministic where possible).
  GenerationParams get params;

  Future<void> dispose();
}

/// The engine library: `$SHERPA_ENGINE_LIB`, else the default host build.
String? engineLibraryPath() {
  const fallback = '/opt/vendor-src/sherpa-engine-build/host-shared/libsherpa_engine.so';
  final env = Platform.environment['SHERPA_ENGINE_LIB'];
  if (env != null && env.isNotEmpty) return File(env).existsSync() ? env : null;
  return File(fallback).existsSync() ? fallback : null;
}

/// Qwen3-0.6B (or any GGUF) on the host engine through `LlamaCppProvider`,
/// the same provider the app uses on iOS and as the Android fallback.
final class LocalEngineRuntime implements ModelRuntime {
  LocalEngineRuntime._(this.host, this.lifecycle, this.llama, this.modelId, this._tmp, this.params);

  /// Loads [modelPath]. [threads] defaults to `$SHERPA_TEST_THREADS` or 2
  /// (the CPU is shared; ggml's spinning barriers degrade under contention).
  static Future<LocalEngineRuntime> open(
    String modelPath, {
    int? threads,
    int context = 4096,
    int maxOutputTokens = 256,
  }) async {
    final lib = engineLibraryPath();
    if (lib == null) throw StateError('no engine library: set SHERPA_ENGINE_LIB');
    if (!File(modelPath).existsSync()) throw StateError('no model at $modelPath');
    final n = threads ?? int.tryParse(Platform.environment['SHERPA_TEST_THREADS'] ?? '') ?? 2;
    final tmp = await Directory.systemTemp.createTemp('sherpa_evals_engine');
    final forensics = EngineForensics(Directory(p.join(tmp.path, 'forensics')));
    final host = FfiEngineHost(libraryPath: lib, crashBreadcrumbPath: forensics.engineBreadcrumbPath);
    final id = p.basenameWithoutExtension(modelPath).toLowerCase();
    final lifecycle = ModelLifecycleManager(
      host: host,
      forensics: forensics,
      prefixCache: PrefixCacheStore(directory: Directory(p.join(tmp.path, 'kv'))),
      minTokensToPersist: 1 << 30, // evals never persist KV prefixes
    )..register(LocalModelSpec(
        id: id,
        path: modelPath,
        displayName: p.basename(modelPath),
        preferredContext: context,
        minContext: 1024,
        sessionDefaults: SessionConfig(nThreads: n, nThreadsBatch: n, seed: 42),
      ));
    await lifecycle.start();
    final provider = LlamaCppProvider(lifecycle: lifecycle);
    await provider.capabilities(id); // load now, so the first case is not timed with the load
    return LocalEngineRuntime._(host, lifecycle, provider, id, tmp, GenerationParams(
      temperature: 0,
      seed: 42,
      maxOutputTokens: maxOutputTokens,
      reasoning: ReasoningEffort.off,
    ));
  }

  final FfiEngineHost host;
  final ModelLifecycleManager lifecycle;
  final LlamaCppProvider llama;
  final Directory _tmp;

  @override
  final String modelId;

  @override
  final GenerationParams params;

  @override
  ModelProvider get provider => llama;

  @override
  TokenCounter get counter => llama.tokenCounter(modelId);

  @override
  ContextManager wrap(ContextManager inner) => WarmingContextManager(inner);

  /// Tokens of [text] with or without special-token parsing (probe use).
  Future<List<int>> tokenize(String text, {required bool parseSpecial}) async {
    final loaded = lifecycle.loaded;
    if (loaded == null) throw StateError('model not loaded');
    return host.tokenize(loaded.model.ref, text, parseSpecial: parseSpecial);
  }

  /// Prompt tokens of an OpenAI-shaped chat request rendered through the
  /// model's template (the same path generation uses).
  Future<int> countChat(Map<String, Object?> request) async {
    final loaded = lifecycle.loaded;
    if (loaded == null) throw StateError('model not loaded');
    return host.countChatTokens(loaded.model.ref, jsonEncode(request));
  }

  @override
  Future<void> dispose() async {
    await lifecycle.dispose();
    await host.dispose();
    try {
      await _tmp.delete(recursive: true);
    } on Object {
      // best effort
    }
  }
}

/// A remote provider built from a `ProviderConfig` JSON.
final class RemoteRuntime implements ModelRuntime {
  RemoteRuntime(RemoteModelSpec spec)
      : _client = http.Client(),
        modelId = (spec.json['model'] ?? spec.json['defaultModelId'])! as String,
        params = const GenerationParams(temperature: 0, maxOutputTokens: 512) {
    final config = ProviderConfig.fromJson(spec.json);
    final keyEnv = spec.json['apiKeyEnv'] as String?;
    final key = keyEnv == null ? null : Platform.environment[keyEnv];
    provider = createProvider(config, apiKey: key, client: _client);
  }

  final http.Client _client;

  @override
  late final ModelProvider provider;

  @override
  final String modelId;

  @override
  final GenerationParams params;

  @override
  TokenCounter? get counter => null;

  @override
  ContextManager wrap(ContextManager inner) => inner;

  @override
  Future<void> dispose() async => _client.close();
}

/// Opens the runtime for a non-scripted [spec].
Future<ModelRuntime> openRuntime(ModelSpec spec, {int? context, int? threads}) => switch (spec) {
      LocalModelSpecArg(:final path) => LocalEngineRuntime.open(path, context: context ?? 4096, threads: threads),
      final RemoteModelSpec r => Future.value(RemoteRuntime(r)),
      ScriptedModelSpec() => throw StateError('scripted runs build their own providers'),
    };
