import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../../../design/tokens.dart';
import '../../../design/widgets/a11y.dart';
import '../../../routing/routes.dart';
import '../../../state/app_providers.dart';
import '../../../state/providers.dart';
import '../../../state/services.dart';
import '../../../state/ui_preferences.dart';
import '../state/format.dart';
import '../widgets/context_style.dart';
import 'handoff_codec.dart';
import 'handoff_platform.dart';
import 'handoff_qr.dart';
import 'handoff_review.dart';
import 'handoff_service.dart';

/// Opens the camera scanner and returns the scanned payload. A seam so
/// widget tests can stand in for the camera.
typedef HandoffScanner = Future<String?> Function(BuildContext context);

final handoffScannerProvider = Provider<HandoffScanner>((ref) => HandoffScanPage.open);

/// "Import handoff" (`/handoff/import`): pick a file, paste text or scan a
/// code; validate it as untrusted input; review it; then resume it as a new
/// chat.
///
/// Nothing is written until "Resume": a bundle that fails validation, or one
/// the user decides against after reading, leaves no trace.
class HandoffImportScreen extends ConsumerStatefulWidget {
  const HandoffImportScreen({super.key});

  @override
  ConsumerState<HandoffImportScreen> createState() => _HandoffImportScreenState();
}

class _HandoffImportScreenState extends ConsumerState<HandoffImportScreen> {
  final TextEditingController _paste = TextEditingController();
  bool _pasting = false;
  bool _busy = false;
  String? _error;
  HandoffBundle? _bundle;

  static const HandoffLimits _limits = HandoffLimits();

  @override
  void dispose() {
    _paste.dispose();
    super.dispose();
  }

  void _accept(HandoffBundle Function() parse) {
    try {
      final b = parse();
      ref.read(hapticsProvider).selection();
      setState(() {
        _bundle = b;
        _error = null;
      });
    } on HandoffBundleException catch (e) {
      ref.read(hapticsProvider).error();
      setState(() => _error = HandoffCodec.explain(e));
    }
  }

  Future<void> _pickFile() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final f = await ref.read(handoffPlatformProvider).pickFile(maxBytes: _limits.maxBytes);
      if (f == null || !mounted) return;
      if (f.tooLarge) {
        setState(() => _error = 'It is too large to be a handoff (${formatBytes(f.size ?? 0)}; a handoff is at most '
            '${formatBytes(_limits.maxBytes)}). Nothing was imported.');
        return;
      }
      _accept(() => HandoffCodec.parseBytes(f.bytes!, limits: _limits));
    } on Object {
      if (mounted) setState(() => _error = "Couldn't read that file. Try another one, or paste its text.");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _scan() async {
    final raw = await ref.read(handoffScannerProvider)(context);
    if (raw == null || !mounted) return;
    _accept(() => HandoffCodec.parseText(raw, limits: _limits));
  }

  void _checkPaste() => _accept(() => HandoffCodec.parseText(_paste.text, limits: _limits));

  Future<void> _resume(HandoffBundle bundle, ModelChoice? model) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final session = await ref.read(handoffServiceProvider).start(bundle, model: model);
      ref.read(hapticsProvider).success();
      if (mounted) GoRouter.maybeOf(context)?.go(Routes.chat(session.id));
    } on Object {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)
          ?..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text("Couldn't create the chat. Try again.")));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bundle = _bundle;
    return Scaffold(
      appBar: AppBar(
        title: Heading(level: 1, child: Text(bundle == null ? 'Import handoff' : 'Review handoff')),
        leading: bundle == null
            ? null
            : BackButton(onPressed: () => setState(() => _bundle = null)),
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: kContextReadableWidth),
          child: bundle == null ? _chooser(context) : _review(context, bundle),
        ),
      ),
    );
  }

  Widget _chooser(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final canScan = ref.watch(handoffPlatformProvider).canScan;
    return ListView(
      padding: EdgeInsets.fromLTRB(t.space.lg, t.space.md, t.space.lg, t.space.xxxl),
      children: [
        Text(
          'Continue a task from a handoff made in Sherpa, on this or another device. You will see everything it '
          'contains before anything is added.',
          style: theme.textTheme.bodyMedium,
        ),
        if (_error != null) ...[
          SizedBox(height: t.space.md),
          _ImportError(message: _error!, onDismiss: () => setState(() => _error = null)),
        ],
        SizedBox(height: t.space.md),
        Card(
          margin: EdgeInsets.zero,
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.file_open_outlined),
                title: const Text('Choose a file'),
                subtitle: const Text('A .sherpa-handoff.json file you shared or saved'),
                enabled: !_busy,
                onTap: () => unawaited(_pickFile()),
              ),
              ListTile(
                leading: const Icon(Icons.content_paste_rounded),
                title: const Text('Paste text'),
                subtitle: const Text('The file\'s contents, or a copied QR code'),
                enabled: !_busy,
                onTap: () => setState(() => _pasting = !_pasting),
              ),
              if (canScan)
                ListTile(
                  leading: const Icon(Icons.qr_code_scanner_rounded),
                  title: const Text('Scan a QR code'),
                  subtitle: const Text('Shown by "Show QR code" on the other phone'),
                  enabled: !_busy,
                  onTap: () => unawaited(_scan()),
                ),
            ],
          ),
        ),
        if (_pasting) ...[
          SizedBox(height: t.space.lg),
          TextField(
            controller: _paste,
            minLines: 4,
            maxLines: 10,
            style: contextMonoStyle(context),
            decoration: const InputDecoration(
              labelText: 'Handoff text',
              hintText: '{"format": "sherpa.handoff", …}',
              alignLabelWithHint: true,
            ),
          ),
          SizedBox(height: t.space.sm),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: FilledButton.tonal(onPressed: _checkPaste, child: const Text('Check')),
          ),
        ],
        if (_busy) ...[SizedBox(height: t.space.lg), const LinearProgressIndicator(semanticsLabel: 'Reading the handoff')],
      ],
    );
  }

  Widget _review(BuildContext context, HandoffBundle bundle) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    // The stream's first value can lag a frame; the store answers now.
    final model = ref.watch(defaultModelProvider).value ?? ref.read(preferencesProvider).defaultModel;
    return ListView(
      padding: EdgeInsets.fromLTRB(t.space.lg, t.space.md, t.space.lg, t.space.xxxl + MediaQuery.paddingOf(context).bottom),
      children: [
        const UntrustedImportNotice(),
        SizedBox(height: t.space.md),
        HandoffFactsCard(bundle: bundle, title: 'What will be added'),
        SizedBox(height: t.space.md),
        Text(
          'Resuming creates a new chat whose first message is this handoff (pinned, so it is never summarized '
          'away). ${model == null ? 'The chat will ask which model to use.' : 'It continues with ${model.modelId}; '
              'you can switch models in the chat.'}',
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        SizedBox(height: t.space.md),
        Wrap(
          spacing: t.space.sm,
          runSpacing: t.space.sm,
          alignment: WrapAlignment.end,
          children: [
            TextButton(onPressed: _busy ? null : () => setState(() => _bundle = null), child: const Text('Cancel')),
            FilledButton.icon(
              onPressed: _busy ? null : () => unawaited(_resume(bundle, model)),
              icon: const Icon(Icons.play_arrow_rounded),
              label: const Text('Resume'),
            ),
          ],
        ),
        if (bundle.connections.isNotEmpty) ...[
          SizedBox(height: t.space.lg),
          ConnectionsManifest(connections: bundle.connections),
        ],
        SizedBox(height: t.space.lg),
        Heading(level: 2, child: Text('What it contains', style: theme.textTheme.titleMedium)),
        SizedBox(height: t.space.sm),
        HandoffMarkdownView(bundle: bundle),
      ],
    );
  }
}

class _ImportError extends StatelessWidget {
  const _ImportError({required this.message, required this.onDismiss});

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      liveRegion: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(t.radius.md),
        ),
        child: Padding(
          padding: EdgeInsetsDirectional.fromSTEB(t.space.lg, t.space.md, t.space.xs, t.space.md),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.error_outline_rounded, color: theme.colorScheme.onErrorContainer),
              SizedBox(width: t.space.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "This handoff can't be used",
                      style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.onErrorContainer),
                    ),
                    SizedBox(height: t.space.xxs),
                    Text(
                      message,
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onErrorContainer),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Dismiss',
                onPressed: onDismiss,
                icon: Icon(Icons.close_rounded, color: theme.colorScheme.onErrorContainer),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
