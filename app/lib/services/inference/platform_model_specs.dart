import 'package:sherpa_apple_ml/sherpa_apple_ml.dart' show MlxModelSpec;
import 'package:sherpa_litert/sherpa_litert.dart' show LiteRtModelSpec;

import '../downloads/model_library.dart';
import '../downloads/storage_layout.dart';
import 'local_model_specs.dart' show kMaxDefaultLocalContext, preferredLocalContext;
import 'on_device_ids.dart';

/// Whether [m] can be registered with the on-device provider [providerId]:
/// its format routes there ([libraryProviderIdFor]) and its files are
/// intact. Whether the engine can run it on this device is
/// `PlatformModelProviders.modelAvailability`.
bool isLibraryModelFor(LibraryModel m, String providerId) => m.usable && libraryProviderIdFor(m.format) == providerId;

/// The MLX registration of an MLX library model (sherpa_apple_ml README
/// "Wiring"): the directory (the library's `loadPath` is a file in it), the
/// record's context default (admission may shrink it to what fits), and
/// tools offered (the model's own chat template decides whether it can use
/// them).
MlxModelSpec mlxModelSpec(LibraryModel m, ModelStorageLayout layout, {int maxContext = kMaxDefaultLocalContext}) =>
    MlxModelSpec(
      id: m.id,
      directory: layout.libraryPath(m.loadPath),
      displayName: m.displayName,
      preferredContext: preferredLocalContext(m, maxContext: maxContext),
      toolCalling: true,
    );

/// The LiteRT-LM registration of a `.litertlm` library model (sherpa_litert
/// README "Dart API"): the absolute file path and the record's context
/// default (null = min(the file's maximum, 8192)). Vision stays off until it
/// is checked on devices.
LiteRtModelSpec liteRtModelSpec(LibraryModel m, ModelStorageLayout layout, {int maxContext = kMaxDefaultLocalContext}) =>
    LiteRtModelSpec(
      id: m.id,
      path: layout.libraryPath(m.loadPath),
      displayName: m.displayName,
      contextLength: m.defaultContextLength == null ? null : preferredLocalContext(m, maxContext: maxContext),
      vision: false,
      parameterCount: m.parameterCount,
    );
