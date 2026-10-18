import 'package:material_ui/material_ui.dart';

import 'chat_route.dart';

// TODO(integrator): once lib/features/chat/chat_screen.dart exists, replace
// this file's body with:
//
//   import '../features/chat/chat_screen.dart';
//   Widget buildChatScreen(String sessionId) => ChatScreen(sessionId: sessionId);
//
// This is the only file in the shell that may import the chat feature; only
// bootstrap.dart imports it, so shell tests never depend on the chat code.

/// Binds the chat route to the chat feature.
Widget buildChatScreen(String sessionId) => ChatUnavailable(sessionId);
