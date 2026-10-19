import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../design/motion.dart';
import '../../../design/widgets/a11y.dart';
import '../../../routing/routes.dart';
import '../../../state/ui_preferences.dart';
import '../handoff/handoff_platform.dart';
import '../state/format.dart';
import 'data_erase.dart';
import 'data_export.dart';

// The privacy dashboard's data actions: what the user sees around
// [DataExporter] and [DataEraser].

/// "Export my data": explains what the file contains (all chats, readable
/// by anyone who gets it; never keys), builds it, opens the share sheet.
Future<void> exportAllData(BuildContext context, WidgetRef ref) async {
  final go = await showDialog<bool>(
    context: context,
    animationStyle: motionStyleOf(context),
    builder: (dialog) => AlertDialog(
      title: const Heading(child: Text('Export your data?')),
      content: const SingleChildScrollView(
        child: Text(
          'Sherpa makes one JSON file with every chat (all branches), its summaries and plans, the activity log, '
          'and your provider settings.\n\n'
          'API keys, tokens and passwords are never included. The file itself is not encrypted, so keep it '
          'somewhere private.',
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(dialog, true), child: const Text('Export')),
      ],
    ),
  );
  if (go != true || !context.mounted) return;
  final exporter = ref.read(dataExporterProvider);
  final platform = ref.read(handoffPlatformProvider);
  try {
    final bytes = await _withProgress(context, 'Preparing your export…', exporter.archiveBytes);
    if (!context.mounted) return;
    await platform.shareFile(
      name: exporter.fileName(),
      bytes: bytes,
      mimeType: 'application/json',
      subject: 'Sherpa data export',
    );
    if (context.mounted) _toast(context, 'Export ready (${formatBytes(bytes.length)}).');
  } on Object {
    if (context.mounted) _toast(context, "Couldn't create the export. Nothing was shared.");
  }
}

/// "Delete all data": two confirmations (what goes, then are you sure),
/// then the erase, then onboarding. The first dialog offers an export.
Future<void> deleteAllData(BuildContext context, WidgetRef ref) async {
  final scheme = Theme.of(context).colorScheme;
  final first = await showDialog<_First>(
    context: context,
    animationStyle: motionStyleOf(context),
    builder: (dialog) => AlertDialog(
      icon: Icon(Icons.delete_forever_outlined, color: scheme.error),
      title: const Heading(child: Text('Delete all data?')),
      content: const SingleChildScrollView(
        child: Text(
          'This removes from this phone:\n'
          '• every chat, with its history, summaries and plans\n'
          '• every model provider and its API key\n'
          '• other saved sign-ins and keys\n'
          '• your preferences\n\n'
          "It can't be undone. Sherpa then starts over with setup.",
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialog, _First.cancel), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(dialog, _First.export), child: const Text('Export first')),
        TextButton(
          onPressed: () => Navigator.pop(dialog, _First.next),
          style: TextButton.styleFrom(foregroundColor: scheme.error),
          child: const Text('Continue'),
        ),
      ],
    ),
  );
  if (!context.mounted) return;
  if (first == _First.export) return exportAllData(context, ref);
  if (first != _First.next) return;
  final sure = await showDialog<bool>(
    context: context,
    animationStyle: motionStyleOf(context),
    builder: (dialog) => AlertDialog(
      title: const Heading(child: Text('Are you sure?')),
      content: const Text('Everything listed will be deleted now. There is no copy to restore from.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('Keep my data')),
        FilledButton(
          onPressed: () => Navigator.pop(dialog, true),
          style: FilledButton.styleFrom(backgroundColor: scheme.error, foregroundColor: scheme.onError),
          child: const Text('Delete everything'),
        ),
      ],
    ),
  );
  if (sure != true || !context.mounted) return;
  final eraser = ref.read(dataEraserProvider);
  final haptics = ref.read(hapticsProvider);
  final router = GoRouter.maybeOf(context);
  try {
    await _withProgress(context, 'Deleting…', eraser.eraseAll);
    haptics.success();
    router?.go(Routes.onboarding);
  } on Object {
    if (context.mounted) {
      _toast(context, "Some data couldn't be deleted. Try again; what was already deleted stays deleted.");
    }
  }
}

enum _First { cancel, export, next }

/// Runs [work] behind a modal, non-dismissible progress dialog.
Future<T> _withProgress<T>(BuildContext context, String label, Future<T> Function() work) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  unawaited(showDialog<void>(
    context: context,
    animationStyle: motionStyleOf(context),
    barrierDismissible: false,
    useRootNavigator: true,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Semantics(
          liveRegion: true,
          label: label,
          child: Row(
            children: [
              const CircularProgressIndicator(),
              const SizedBox(width: 24),
              Expanded(child: ExcludeSemantics(child: Text(label))),
            ],
          ),
        ),
      ),
    ),
  ));
  try {
    return await work();
  } finally {
    navigator.pop();
  }
}

void _toast(BuildContext context, String message) => ScaffoldMessenger.maybeOf(context)
  ?..hideCurrentSnackBar()
  ..showSnackBar(SnackBar(content: Text(message)));
