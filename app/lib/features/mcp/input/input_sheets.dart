import 'package:material_ui/material_ui.dart';

import '../../../design/motion.dart';
import '../../../services/mcp/input/input_queue.dart';
import 'elicitation_sheet.dart';
import 'sampling_sheet.dart';
import 'url_elicitation_sheet.dart';

/// Shows the sheet for a pending request. Dismissing it (swipe, back)
/// leaves the request waiting; only its own buttons answer it.
Future<void> showMcpInputSheet(BuildContext context, McpPendingInput input, {bool useRootNavigator = true}) =>
    showModalBottomSheet<void>(
      context: context,
      sheetAnimationStyle: motionStyleOf(context),
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      useRootNavigator: useRootNavigator,
      builder: (_) => mcpInputSheetFor(input),
    );

/// The sheet body for [input].
Widget mcpInputSheetFor(McpPendingInput input) => switch (input) {
      PendingFormElicitation() => ElicitationFormSheet(key: ValueKey(input.id), pending: input),
      PendingUrlElicitation() => UrlElicitationSheet(key: ValueKey(input.id), pending: input),
      PendingSampling() => SamplingSheet(key: ValueKey(input.id), pending: input),
    };
