import 'package:material_ui/material_ui.dart';

import '../features/chat/chat_screen.dart';

// The only file in the shell that imports the chat feature. Only
// bootstrap.dart imports this file, so shell tests (which override
// `chatScreenBuilderProvider` with a fake) never compile the chat code.

/// Binds the chat route to the chat feature.
Widget buildChatScreen(String sessionId) => ChatScreen(sessionId: sessionId);
