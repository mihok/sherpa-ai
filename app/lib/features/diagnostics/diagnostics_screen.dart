import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../design/motion.dart';
import '../../design/tokens.dart';
import '../../design/widgets/a11y.dart';
import '../../design/widgets/section_header.dart';
import '../../design/widgets/state_views.dart';
import '../models/widgets/format.dart' show formatBytes;
import '../settings/settings_page.dart';
import 'diagnostics_collector.dart';
import 'diagnostics_providers.dart';

/// Settings › About › Export diagnostics: the whole report, as it will be
/// shared, before anything leaves the phone. "Share" opens the share
/// sheet with the JSON file; "Copy summary" copies the readable text.
class DiagnosticsScreen extends ConsumerWidget {
  const DiagnosticsScreen({super.key});

  static const String title = 'Export diagnostics';

  /// What each top-level section of the file is called here.
  static const Map<String, String> sectionLabels = {
    'app': 'App',
    'os': 'Operating system',
    'device': 'Device',
    'lastExit': 'How the app last stopped',
    'engine': 'On-device engine',
    'localModels': 'On-device models',
    'providers': 'Model providers',
    'defaultModel': 'Default model',
    'mcpServers': 'Tool servers',
    'context': 'Context settings',
    'data': 'Chats and storage (counts only)',
    'errors': 'Recent errors (types and codes only)',
    'perfLab': 'Performance lab',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bundle = ref.watch(diagnosticsBundleProvider);
    final ready = bundle.value;
    return SettingsPage(
      title: title,
      bottom: _Actions(bundle: ready),
      children: switch (bundle) {
        AsyncData(:final value) => _content(context, value),
        AsyncError() => [
            SizedBox(
              height: 360,
              child: StateView(
                icon: Icons.error_outline,
                tone: StateTone.error,
                liveRegion: true,
                title: "Couldn't collect diagnostics",
                message: 'Nothing was shared.',
                primaryAction: FilledButton(
                  onPressed: () => ref.invalidate(diagnosticsBundleProvider),
                  child: const Text('Try again'),
                ),
              ),
            ),
          ],
        _ => [const _Collecting()],
      },
    );
  }

  List<Widget> _content(BuildContext context, DiagnosticsBundle b) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final mono = theme.textTheme.bodySmall?.copyWith(
      fontFamily: 'monospace',
      fontFamilyFallback: const ['Menlo', 'Roboto Mono'],
      height: 1.4,
    );
    return [
      Padding(
        padding: EdgeInsets.fromLTRB(t.space.lg, t.space.lg, t.space.lg, 0),
        child: Heading(
          level: 2,
          child: Text('This is everything that will be shared', style: theme.textTheme.titleMedium),
        ),
      ),
      SettingsPadding(
        child: Padding(
          padding: EdgeInsets.only(top: t.space.sm),
          child: Text(
            'A report to attach to a bug report. Nothing leaves your phone until you share it. '
            'It never contains your chats, prompts, tool data, API keys, sign-in tokens, full web addresses '
            'or file paths: servers appear by host name, chats only as counts.',
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      ),
      const SectionHeader('Summary'),
      SettingsPadding(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(t.radius.md),
          ),
          child: Padding(
            padding: EdgeInsets.all(t.space.md),
            child: SelectableText(b.summary, style: mono),
          ),
        ),
      ),
      SectionHeader(
        'Everything in the file',
        trailing: Text(formatBytes(b.bytes.length), style: theme.textTheme.labelMedium),
      ),
      for (final s in b.sections)
        ExpansionTile(
          expansionAnimationStyle: motionStyleOf(context),
          title: Text(sectionLabels[s.key] ?? s.key),
          subtitle: Text(_hint(s.value), maxLines: 1, overflow: TextOverflow.ellipsis),
          childrenPadding: EdgeInsets.fromLTRB(t.space.lg, 0, t.space.lg, t.space.md),
          expandedAlignment: AlignmentDirectional.centerStart,
          children: [
            SizedBox(
              width: double.infinity,
              child: SelectableText(const JsonEncoder.withIndent('  ').convert(s.value), style: mono),
            ),
          ],
        ),
      ListTile(
        title: const Text('File name'),
        subtitle: Text(b.fileName),
      ),
    ];
  }

  static String _hint(Object? v) => switch (v) {
        null => 'Nothing recorded',
        Map() when v['unavailable'] != null => 'Unavailable (${v['unavailable']})',
        Map(:final length) => length == 1 ? '1 field' : '$length fields',
        List(:final length) => length == 0 ? 'None' : (length == 1 ? '1 entry' : '$length entries'),
        _ => '$v',
      };
}

class _Collecting extends StatelessWidget {
  const _Collecting();

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    return Padding(
      padding: EdgeInsets.all(t.space.xl),
      child: Semantics(
        liveRegion: true,
        label: 'Collecting diagnostics',
        child: Column(
          children: [
            const CircularProgressIndicator(),
            SizedBox(height: t.space.lg),
            const ExcludeSemantics(child: Text('Collecting diagnostics…')),
          ],
        ),
      ),
    );
  }
}

class _Actions extends ConsumerWidget {
  const _Actions({required this.bundle});

  final DiagnosticsBundle? bundle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = SherpaTokens.of(context);
    final b = bundle;
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: b == null ? null : () => unawaited(_copy(context, ref, b)),
            icon: const Icon(Icons.copy_rounded),
            label: const Text('Copy summary'),
          ),
        ),
        SizedBox(width: t.space.md),
        Expanded(
          child: FilledButton.icon(
            onPressed: b == null ? null : () => unawaited(_share(context, ref, b)),
            icon: const Icon(Icons.ios_share_rounded),
            label: const Text('Share'),
          ),
        ),
      ],
    );
  }

  Future<void> _copy(BuildContext context, WidgetRef ref, DiagnosticsBundle b) async {
    try {
      await ref.read(diagnosticsShareProvider).copyText(b.summary);
      if (context.mounted) _toast(context, 'Summary copied.');
    } on Object {
      if (context.mounted) _toast(context, "Couldn't copy the summary.");
    }
  }

  Future<void> _share(BuildContext context, WidgetRef ref, DiagnosticsBundle b) async {
    try {
      await ref.read(diagnosticsShareProvider).shareFile(name: b.fileName, bytes: b.bytes, subject: 'Sherpa diagnostics');
    } on Object {
      if (context.mounted) _toast(context, "Couldn't open the share sheet. Nothing was shared.");
    }
  }

  void _toast(BuildContext context, String message) => ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}
