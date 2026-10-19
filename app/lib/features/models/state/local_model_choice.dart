import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart' show BuildContext;

import '../../../services/downloads/model_library.dart';
import '../../../state/services.dart';

export '../../../state/services.dart' show localProviderId;

/// The choice "Use in chat" emits for an installed model.
ModelChoice localModelChoice(LibraryModel m) => ModelChoice(providerId: localProviderId, modelId: m.id);

/// What "Use in chat" does with the choice. Receives a `BuildContext` so
/// it can navigate (e.g. create a session on the local provider and open
/// it).
typedef UseLocalModel = Future<void> Function(BuildContext context, ModelChoice choice);

/// **Integrator hook.** Null until the local inference provider is wired:
/// the library then shows "Use in chat" disabled with an explanation
/// instead of a button that does nothing.
final useLocalModelInChatProvider = Provider<UseLocalModel?>((ref) => null);
