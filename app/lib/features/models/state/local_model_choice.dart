import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart' show BuildContext;

import '../../../services/downloads/model_library.dart';
import '../../../services/inference/on_device_ids.dart';
import '../../../state/services.dart';

export '../../../state/services.dart' show localProviderId;

/// The choice "Use in chat" and the picker emit for an installed model:
/// its format decides the provider — GGUF → llama.cpp ([localProviderId]),
/// MLX → `mlx`, LiteRT → `litert_lm` ([libraryProviderIdFor]). The model id
/// is the library id either way.
ModelChoice localModelChoice(LibraryModel m) =>
    ModelChoice(providerId: libraryProviderIdFor(m.format) ?? localProviderId, modelId: m.id);

/// What "Use in chat" does with the choice. Receives a `BuildContext` so
/// it can navigate (e.g. create a session on the local provider and open
/// it).
typedef UseLocalModel = Future<void> Function(BuildContext context, ModelChoice choice);

/// **Integrator hook.** Null until the local inference provider is wired:
/// the library then shows "Use in chat" disabled with an explanation
/// instead of a button that does nothing.
final useLocalModelInChatProvider = Provider<UseLocalModel?>((ref) => null);
