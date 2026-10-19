import 'package:material_ui/material_ui.dart';

import '../features/chat/chat_screen.dart';
import '../features/context/handoff/handoff_screen.dart';
import '../features/context/inspector_screen.dart';
import 'context_route.dart';

// The only file in the shell that imports the chat feature. Only
// bootstrap.dart imports this file, so shell tests (which override
// `chatScreenBuilderProvider` with a fake) never compile the chat code.

/// Binds the chat route to the chat feature.
Widget buildChatScreen(String sessionId) => ChatScreen(sessionId: sessionId);

/// Binds the chat's context routes (`/chat/:id/context`, `/chat/:id/handoff`)
/// to the context feature, which drives the chat's controller. Bootstrap
/// overrides `contextScreensProvider` with it, next to [buildChatScreen].
const ContextScreens contextScreens = ContextScreens(inspector: _inspector, handoff: _handoff);

Widget _inspector(String sessionId) => ContextInspectorScreen(sessionId: sessionId);

Widget _handoff(String sessionId) => HandoffScreen(sessionId: sessionId);
