import 'dart:async';

import 'package:flutter_riverpod/misc.dart' show Override;

import '../../apps/state/apps_providers.dart';
import 'chat_controller.dart';

/// Connects MCP App views to their chat. Add to the root `ProviderScope`
/// (bootstrap) next to the MCP feature overrides:
///
/// * `ui/message`: a message the user confirmed in the view is sent in its
///   chat, attributed "Sent by" the app ([ChatController.sendAppMessage]).
///   The view gets its answer at once; the chat runs (or queues behind a
///   running reply) on its own.
/// * App-initiated tool calls are approved on the chat's own approval card
///   ([ChatController.approvalHandler]), labelled "Requested by an app".
///
/// Both read the chat's controller lazily, when a view asks: a view only
/// exists inside its chat's transcript, so the controller is alive then.
/// Nothing here is read while providers are built, so there is no cycle
/// between the apps and chat providers.
List<Override> chatMcpAppOverrides() => [
  mcpAppMessageSinkProvider.overrideWith(
    (ref) => (McpAppInsertedMessage m) {
      unawaited(ref.read(chatControllerProvider(m.sessionId).notifier).sendAppMessage(m.text, from: m.identity.label));
    },
  ),
  mcpAppApprovalHandlerProvider.overrideWith(
    (ref) =>
        (String sessionId) => ref.read(chatControllerProvider(sessionId).notifier).approvalHandler,
  ),
];
