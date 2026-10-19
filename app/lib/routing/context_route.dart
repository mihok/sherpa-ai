import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../design/widgets/state_views.dart';

/// Builds a per-chat context screen for a session id.
typedef ContextScreenBuilder = Widget Function(String sessionId);

/// The context inspector and the handoff review belong to a chat: they
/// drive its `ChatController` (Compact now, undo, the model picker). Like
/// the chat screen itself, they reach the router only through this seam, so
/// the router (and every shell test) never compiles the chat feature.
///
/// Bootstrap overrides it with `contextScreens` from
/// lib/routing/chat_screen_binding.dart; widget tests override it directly.
@immutable
final class ContextScreens {
  const ContextScreens({this.inspector = ContextUnavailable.new, this.handoff = ContextUnavailable.new});

  /// `/chat/:id/context`.
  final ContextScreenBuilder inspector;

  /// `/chat/:id/handoff`.
  final ContextScreenBuilder handoff;
}

final contextScreensProvider = Provider<ContextScreens>((ref) => const ContextScreens());

/// Shown only if the context screens were not bound (a wiring bug).
class ContextUnavailable extends StatelessWidget {
  const ContextUnavailable(this.sessionId, {super.key});

  final String sessionId;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Context')),
        body: const ErrorState(
          title: 'Context tools are not available in this build',
          message: 'The context inspector was not connected to the app shell.',
        ),
      );
}

enum ContextScreen { inspector, handoff }

/// A context route's content, resolved through [contextScreensProvider].
class ContextScreenView extends ConsumerWidget {
  const ContextScreenView({super.key, required this.sessionId, required this.screen});

  final String sessionId;
  final ContextScreen screen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final screens = ref.watch(contextScreensProvider);
    final build = switch (screen) {
      ContextScreen.inspector => screens.inspector,
      ContextScreen.handoff => screens.handoff,
    };
    return KeyedSubtree(key: ValueKey('${screen.name}:$sessionId'), child: build(sessionId));
  }
}
