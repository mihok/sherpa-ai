import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../design/widgets/state_views.dart';

/// Builds the chat screen for a session id.
typedef ChatScreenBuilder = Widget Function(String sessionId);

/// The single seam between the shell and the chat feature.
///
/// The router never imports `features/chat` directly: bootstrap overrides
/// this with `buildChatScreen` (lib/routing/chat_screen_binding.dart), and
/// widget tests override it with a fake. That keeps every shell test
/// independent of the chat feature's own dependencies.
final chatScreenBuilderProvider = Provider<ChatScreenBuilder>((ref) => ChatUnavailable.new);

/// Shown only if the chat feature was not bound (a wiring bug, not a state
/// users should normally see).
class ChatUnavailable extends StatelessWidget {
  const ChatUnavailable(this.sessionId, {super.key});

  final String sessionId;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Chat')),
        body: const ErrorState(
          title: 'Chat is not available in this build',
          message: 'The chat screen was not connected to the app shell.',
        ),
      );
}
