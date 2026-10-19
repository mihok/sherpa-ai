import 'dart:math' as math;

import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_hub/sherpa_hub.dart' show FileRole, ModelFormat;
import 'package:sherpa_inference/sherpa_inference.dart';

import '../../state/services.dart' show localProviderId;
import '../downloads/model_library.dart';
import '../downloads/storage_layout.dart';

/// Context a library model opens with when its record has no default
/// (imports without a device profile, older records).
const int kDefaultLocalContext = 8192;

/// POLICY: the largest context a library default may ask for. The record's
/// default is "the largest that fit when it was installed", which on a big
/// phone can be the full trained window (40K+ tokens of KV for a small
/// model); admission control would load it, but a footprint that large
/// is the first thing the OS kills in the background. Users who need more
/// can raise it once a per-model setting exists.
const int kMaxDefaultLocalContext = 32768;

/// Below this a model is not worth loading (admission refuses).
const int kMinLocalContext = 2048;

/// Whether the engine can open [m] at all: GGUF, files intact.
bool isRunnableLocally(LibraryModel m) => m.format == ModelFormat.gguf && m.usable;

/// The verified SHA-256 of the file the engine opens, as the lifecycle's
/// content identity (`sha256:<hex>`). Null when the record has none (the
/// engine then fingerprints the file itself).
String? localModelIdentity(LibraryModel m) {
  for (final f in m.files) {
    if (f.path == m.loadPath && f.sha256 != null) return 'sha256:${f.sha256}';
  }
  final shards = [for (final f in m.files) if (f.role == FileRole.model) f];
  final sha = shards.length == 1 ? shards.single.sha256 : null;
  return sha == null ? null : 'sha256:$sha';
}

/// The context [m] asks admission control for, at most [maxContext].
int preferredLocalContext(LibraryModel m, {int maxContext = kMaxDefaultLocalContext}) {
  var ctx = m.defaultContextLength ?? kDefaultLocalContext;
  final train = m.contextLength;
  if (train != null && train > 0) ctx = math.min(ctx, train);
  ctx = math.min(ctx, maxContext);
  final floor = math.min(math.min(kMinLocalContext, train ?? kMinLocalContext), maxContext);
  return math.max(ctx, floor);
}

/// The lifecycle registration for a library model: absolute paths, the
/// verified SHA-256 as identity, the paired vision projector and the
/// record's context default (at most [maxContext], e.g. a cap recorded
/// after the engine crashed with this model).
LocalModelSpec localModelSpec(
  LibraryModel m,
  ModelStorageLayout layout, {
  SessionConfig sessionDefaults = const SessionConfig(),
  int maxContext = kMaxDefaultLocalContext,
}) {
  final preferred = preferredLocalContext(m, maxContext: maxContext);
  return LocalModelSpec(
    id: m.id,
    path: layout.libraryPath(m.loadPath),
    displayName: m.displayName,
    identity: localModelIdentity(m),
    preferredContext: preferred,
    minContext: math.min(kMinLocalContext, preferred),
    trainContext: m.contextLength,
    toolCalling: m.toolUse,
    mmprojPath: m.mmprojPath == null ? null : layout.libraryPath(m.mmprojPath!),
    sessionDefaults: sessionDefaults,
  );
}

/// What the picker and the agent loop know about [m] before it loads.
/// [loaded] (the warm model's live capabilities) wins when it is [m].
ModelCapabilities localModelCapabilities(LibraryModel m, {LoadedModel? loaded, int maxContext = kMaxDefaultLocalContext}) {
  if (loaded != null && loaded.spec.id == m.id) return loaded.capabilities;
  return ModelCapabilities(
    contextLength: preferredLocalContext(m, maxContext: maxContext),
    toolCallFormat: m.toolUse ? ToolCallFormat.jsonGrammar : ToolCallFormat.none,
    parallelToolCalls: false,
    // A paired projector needs an engine built with mtmd; the engine says
    // so once the model is loaded (the branch above).
    vision: false,
    reasoning: m.reasoning ? ReasoningSupport.optional : ReasoningSupport.none,
    quantization: m.quant,
    parameterCount: m.parameterCount,
    supportsPromptCache: true,
    historyPolicy: HistoryPolicy.appendOnly,
  );
}

ModelDescriptor localModelDescriptor(LibraryModel m, {LoadedModel? loaded, int maxContext = kMaxDefaultLocalContext}) =>
    ModelDescriptor(
      id: m.id,
      providerId: localProviderId,
      displayName: m.displayName,
      capabilities: localModelCapabilities(m, loaded: loaded, maxContext: maxContext),
      description: m.repo,
    );
