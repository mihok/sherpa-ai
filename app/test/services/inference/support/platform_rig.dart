import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sherpa/services/downloads/downloads.dart';
import 'package:sherpa/services/inference/local_provider_registry.dart';
import 'package:sherpa/services/inference/platform_models.dart';
import 'package:sherpa/state/in_memory/in_memory_provider_registry.dart';
import 'package:sherpa_apple_ml/testing.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_hub/sherpa_hub.dart' show DevicePlatform, FileRole, ModelFormat;
import 'package:sherpa_litert/sherpa_litert.dart';
import 'package:sherpa_litert/testing.dart';

import '../../../support/harness.dart' show FakeEndpoint, FakeModelProvider;
import 'local_rig.dart';

/// mlx-community/Qwen3-0.6B-4bit's config.json, trimmed to what MLX's
/// directory check and the fit estimate read.
const Map<String, Object?> qwen3MlxConfig = {
  'model_type': 'qwen3',
  'num_hidden_layers': 28,
  'num_attention_heads': 16,
  'num_key_value_heads': 8,
  'head_dim': 128,
  'hidden_size': 1024,
  'max_position_embeddings': 40960,
  'quantization': {'group_size': 64, 'bits': 4},
};

/// The on-device stack over fakes: a [LocalRig] (llama.cpp over
/// FakeEngineHost), sherpa_apple_ml's and sherpa_litert's fake Pigeon
/// layers, a foreground the test flips, and the registry that reserves
/// every on-device id — for one [platform].
final class PlatformRig {
  PlatformRig._(this.local, this.apple, this.litert, this.foreground, this.platform, this.providers, this.registry);

  static Future<PlatformRig> create({
    DevicePlatform platform = DevicePlatform.ios,
    FakeAppleMlBackend? apple,
    FakeLiteRtBackend? litert,
    bool foreground = true,
  }) async {
    final local = await LocalRig.create();
    final a = apple ?? FakeAppleMlBackend();
    final l = litert ?? FakeLiteRtBackend();
    final fg = FakeForeground(foreground: foreground);
    final providers = PlatformModelProviders(
      library: local.library,
      layout: local.layout,
      config: PlatformModelsConfig(platform: platform, appleBackend: a, liteRtBackend: l),
      foreground: fg,
    );
    final inner = InMemoryProviderRegistry(
      secrets: InMemorySecretStore(),
      factory: (c, key) => FakeModelProvider(c, const FakeEndpoint(models: ['big']), key),
    );
    final registry = LocalProviderRegistry(inner, local.local, platform: providers);
    return PlatformRig._(local, a, l, fg, platform, providers, registry);
  }

  final LocalRig local;
  final FakeAppleMlBackend apple;
  final FakeLiteRtBackend litert;
  final FakeForeground foreground;
  final DevicePlatform platform;
  final PlatformModelProviders providers;
  final LocalProviderRegistry registry;

  ModelStorageLayout get layout => local.layout;

  /// Writes an MLX directory (config.json, tokenizer, chat template, one
  /// safetensors shard) into the library and records it.
  Future<LibraryModel> addMlx(String id, {String name = 'Qwen3 0.6B (MLX)', bool complete = true, int weightBytes = 4096}) async {
    final folder = 'mlx-community__$id@0123456789ab';
    final files = <String, List<int>>{
      'config.json': utf8.encode(jsonEncode(qwen3MlxConfig)),
      'tokenizer_config.json': utf8.encode(jsonEncode({'chat_template': '{% for m in messages %}{{ m.content }}{% endfor %}'})),
      if (complete) 'tokenizer.json': utf8.encode('{}'),
      'model.safetensors': List<int>.filled(weightBytes, 0),
    };
    final out = <LibraryFile>[];
    for (final e in files.entries) {
      final rel = '$folder/${e.key}';
      final f = File(layout.libraryPath(rel));
      await f.parent.create(recursive: true);
      await f.writeAsBytes(e.value);
      out.add(LibraryFile(
        path: rel,
        role: e.key.endsWith('.safetensors') ? FileRole.model : FileRole.config,
        sizeBytes: e.value.length,
        sha256: 'ab' * 32,
      ));
    }
    return local.add(LibraryModel(
      id: id,
      source: LibrarySource.hub,
      displayName: name,
      format: ModelFormat.mlx,
      files: out,
      loadPath: '$folder/model.safetensors',
      installedAt: DateTime.utc(2026, 10, 1),
      repo: 'mlx-community/$id',
      quant: '4bit',
    ));
  }

  /// Writes a `.litertlm` file into the library, records it, and teaches
  /// the fake engine its metadata ([info]; null = the file can't be read).
  Future<LibraryModel> addLiteRt(String id, {String name = 'Gemma 3 1B (LiteRT)', ModelInfoMsg? info, int bytes = 8192}) async {
    final rel = 'litert-community__$id@0123456789ab/$id.litertlm';
    final f = File(layout.libraryPath(rel));
    await f.parent.create(recursive: true);
    await f.writeAsBytes(List<int>.filled(bytes, 1));
    litert.models[layout.libraryPath(rel)] = info ?? FakeLiteRtBackend.modelInfo();
    return local.add(LibraryModel(
      id: id,
      source: LibrarySource.hub,
      displayName: name,
      format: ModelFormat.litert,
      files: [LibraryFile(path: rel, role: FileRole.model, sizeBytes: bytes, sha256: 'cd' * 32)],
      loadPath: rel,
      installedAt: DateTime.utc(2026, 10, 1),
      repo: 'litert-community/$id',
    ));
  }

  String absolute(LibraryModel m) => p.normalize(layout.libraryPath(m.loadPath));

  Future<void> dispose() async {
    await registry.dispose();
    await providers.dispose();
    await local.dispose();
    await apple.close();
    await litert.dispose();
    await foreground.dispose();
  }
}
