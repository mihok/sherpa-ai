import 'package:material_ui/material_ui.dart';

// Text styles for the context screens. They match the chat's (monospace for
// raw payloads) but live here so the import flow, which the router builds
// directly, never compiles the chat feature.

/// Readable column on tablets, same as the chat transcript.
const double kContextReadableWidth = 760;

/// Monospace for exact text: payloads, tool arguments, raw summaries.
TextStyle contextMonoStyle(BuildContext context, {Color? color}) {
  final base = Theme.of(context).textTheme.bodySmall!;
  return base.copyWith(
    fontFamily: 'monospace',
    fontFamilyFallback: const ['RobotoMono', 'Menlo', 'Courier New', 'Courier'],
    color: color ?? Theme.of(context).colorScheme.onSurface,
    height: 1.45,
  );
}
