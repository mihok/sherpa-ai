import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../../../design/tokens.dart';
import '../../apps/mcp_app_message_view.dart';
import '../state/chat_controller.dart';
import 'tool_call_card.dart';

/// The MCP App view of one tool call, under its tool card.
///
/// Shown when the call's result names a `ui://` view
/// ([ToolExecutionView.appResult]). It sits outside the card's collapsible
/// details (and outside a collapsed "Ran 3 tools" group): the view is part
/// of the answer, not a detail. The view's host chrome says which server
/// the content is from; whenever the view can't be shown, the tool's text
/// result is shown instead, in the same frame as the card's own result.
class ToolAppView extends ConsumerWidget {
  const ToolAppView({super.key, required this.sessionId, required this.call});

  final String sessionId;

  /// The call whose result may carry the view (its arguments go to the
  /// view as `ui/notifications/tool-input`).
  final ToolCall call;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final result = ref.watch(chatControllerProvider(sessionId).select((s) => s.tools[call.id]?.appResult));
    if (result == null) return const SizedBox.shrink();
    final tokens = SherpaTokens.of(context);
    return Padding(
      padding: EdgeInsets.only(top: tokens.space.sm),
      child: Semantics(
        container: true,
        explicitChildNodes: true,
        child: McpAppMessageView(
          key: ValueKey('mcp-app-${result.callId}'),
          sessionId: sessionId,
          result: result,
          toolArguments: call.arguments,
          fallback: ToolResultFallback(result: result),
        ),
      ),
    );
  }
}

/// An MCP Apps view stored in a message ([UiResourcePart]).
class UiResourceView extends StatelessWidget {
  const UiResourceView({super.key, required this.sessionId, required this.part});

  final String sessionId;
  final UiResourcePart part;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    explicitChildNodes: true,
    child: McpAppMessageView(
      key: ValueKey('mcp-ui-${part.callId ?? part.resourceUri}'),
      sessionId: sessionId,
      resource: part,
    ),
  );
}
