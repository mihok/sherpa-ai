import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../../../design/tokens.dart';
import '../../../design/widgets/a11y.dart';
import '../../../design/widgets/state_views.dart';
import '../../../routing/routes.dart';
import '../../../state/services.dart';
import '../../../state/ui_preferences.dart';
import '../../chat/model_picker_sheet.dart';
import '../../chat/state/chat_controller.dart';
import '../state/format.dart';
import '../widgets/context_style.dart';
import 'handoff_codec.dart';
import 'handoff_platform.dart';
import 'handoff_qr.dart';
import 'handoff_review.dart';
import 'handoff_service.dart';

/// "Hand off…" (`/chat/:id/handoff`): builds a handoff bundle of this chat,
/// shows exactly what it contains, and offers the ways to continue: a new
/// chat here (same or another model), the share sheet, Files, or a QR code.
///
/// Why a review step before anything leaves: a bundle carries the task,
/// a summary and recent messages. Secrets are scrubbed automatically, but
/// personal details are not, and only the user can judge those.
class HandoffScreen extends ConsumerStatefulWidget {
  const HandoffScreen({super.key, required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<HandoffScreen> createState() => _HandoffScreenState();
}

class _HandoffScreenState extends ConsumerState<HandoffScreen> {
  late Future<HandoffBundle> _built = _build();
  final TextEditingController _notes = TextEditingController();
  bool _busy = false;

  ModelChoice? get _model => ref.read(chatControllerProvider(widget.sessionId)).model?.choice;

  Future<HandoffBundle> _build() => ref.read(handoffServiceProvider).build(sessionId: widget.sessionId, model: _model);

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  /// The reviewed bundle with the user's note, scrubbed like the rest and
  /// sanitized so the receiving side's strict parser accepts it (a typed
  /// bidi control, for one, would otherwise make the file unimportable).
  HandoffBundle _withNotes(HandoffBundle b) {
    final note = _notes.text.trim();
    if (note.isEmpty) return b;
    return HandoffBundle(
      createdAt: b.createdAt,
      source: b.source,
      task: b.task,
      summary: b.summary,
      plan: b.plan,
      pinned: b.pinned,
      recentTurns: b.recentTurns,
      connections: b.connections,
      artifacts: b.artifacts,
      notes: scrubSecrets(note),
    ).sanitized();
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _guard(Future<void> Function() body, String failure) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await body();
    } on Object {
      _toast(failure);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _startHere(HandoffBundle bundle, {required bool pickModel}) => _guard(() async {
        var model = _model;
        if (pickModel) {
          model = await ModelPickerSheet.show(context, current: model);
          if (model == null || !mounted) return;
        }
        final session = await ref.read(handoffServiceProvider).start(
              _withNotes(bundle),
              model: model,
              fromSessionId: widget.sessionId,
            );
        ref.read(hapticsProvider).success();
        if (mounted) GoRouter.maybeOf(context)?.go(Routes.chat(session.id));
      }, "Couldn't start the new chat. Try again.");

  Future<void> _share(HandoffBundle bundle) => _guard(() async {
        final b = _withNotes(bundle);
        await ref.read(handoffPlatformProvider).shareFile(
              name: HandoffCodec.fileName(b),
              bytes: HandoffCodec.fileBytes(b),
              mimeType: 'application/json',
              subject: 'Sherpa handoff: ${previewLine(b.task, max: 60)}',
            );
      }, "Couldn't open the share sheet.");

  Future<void> _save(HandoffBundle bundle) => _guard(() async {
        final b = _withNotes(bundle);
        final saved = await ref.read(handoffPlatformProvider).saveFile(
              name: HandoffCodec.fileName(b),
              bytes: HandoffCodec.fileBytes(b),
              mimeType: 'application/json',
            );
        if (saved) _toast('Saved ${HandoffCodec.fileName(b)}');
      }, "Couldn't save the file.");

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Heading(level: 1, child: const Text('Hand off'))),
      body: FutureBuilder<HandoffBundle>(
        future: _built,
        builder: (context, snap) {
          if (snap.hasError) {
            return ErrorState(
              title: "Couldn't prepare the handoff",
              message: snap.error is StateError
                  ? (snap.error! as StateError).message
                  : 'Reading this chat failed. Nothing was shared.',
              onRetry: () => setState(() => _built = _build()),
            );
          }
          final bundle = snap.data;
          if (bundle == null) return const LoadingState(label: 'Preparing the handoff…');
          return _Review(
            bundle: bundle,
            notes: _notes,
            busy: _busy,
            modelName: ref.watch(chatControllerProvider(widget.sessionId).select((s) => s.model?.modelName)),
            onStartHere: () => unawaited(_startHere(bundle, pickModel: false)),
            onStartWithModel: () => unawaited(_startHere(bundle, pickModel: true)),
            onShare: () => unawaited(_share(bundle)),
            onSave: () => unawaited(_save(bundle)),
            onQr: (payload) => unawaited(showHandoffQr(context, payload)),
            withNotes: _withNotes,
          );
        },
      ),
    );
  }
}

class _Review extends StatefulWidget {
  const _Review({
    required this.bundle,
    required this.notes,
    required this.busy,
    required this.modelName,
    required this.onStartHere,
    required this.onStartWithModel,
    required this.onShare,
    required this.onSave,
    required this.onQr,
    required this.withNotes,
  });

  final HandoffBundle bundle;
  final TextEditingController notes;
  final bool busy;
  final String? modelName;
  final VoidCallback onStartHere;
  final VoidCallback onStartWithModel;
  final VoidCallback onShare;
  final VoidCallback onSave;
  final void Function(String payload) onQr;
  final HandoffBundle Function(HandoffBundle) withNotes;

  @override
  State<_Review> createState() => _ReviewState();
}

class _ReviewState extends State<_Review> {
  @override
  void initState() {
    super.initState();
    widget.notes.addListener(_changed);
  }

  @override
  void dispose() {
    widget.notes.removeListener(_changed);
    super.dispose();
  }

  void _changed() => setState(() {});

  // The QR payload is a gzip of the whole bundle: recompute it only when
  // the bundle or the note changed, not on every rebuild.
  HandoffBundle? _source;
  String? _note;
  late HandoffBundle _bundle;
  late String _payload;

  void _refresh() {
    if (identical(_source, widget.bundle) && _note == widget.notes.text) return;
    _source = widget.bundle;
    _note = widget.notes.text;
    _bundle = widget.withNotes(widget.bundle);
    _payload = HandoffCodec.qrPayload(_bundle);
  }

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    _refresh();
    final bundle = _bundle;
    final payload = _payload;
    final fits = HandoffCodec.fitsQr(payload);
    final enabled = !widget.busy;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: kContextReadableWidth),
        child: ListView(
          padding: EdgeInsets.fromLTRB(t.space.lg, t.space.md, t.space.lg, t.space.xxxl + MediaQuery.paddingOf(context).bottom),
          children: [
            Text(
              'A handoff carries this chat\'s task, a summary and your latest messages into a new chat, here or '
              'on another device, with any model. Check what it contains before you share it.',
              style: theme.textTheme.bodyMedium,
            ),
            SizedBox(height: t.space.md),
            HandoffFactsCard(bundle: bundle, title: 'What will be sent', qrPayload: payload),
            SizedBox(height: t.space.md),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.shield_outlined, size: 20, color: theme.colorScheme.onSurfaceVariant),
                SizedBox(width: t.space.sm),
                Expanded(
                  child: Text(
                    'API keys and tokens are removed automatically. Personal details in your messages are not, so '
                    'share it only with people and devices you trust.',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
            SizedBox(height: t.space.lg),
            Heading(level: 2, child: Text('Continue', style: theme.textTheme.titleMedium)),
            SizedBox(height: t.space.xs),
            Card(
              margin: EdgeInsets.zero,
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.add_comment_outlined),
                    title: const Text('Start a new chat here'),
                    subtitle: Text(widget.modelName == null
                        ? 'The new chat will ask which model to use'
                        : 'With ${widget.modelName}'),
                    enabled: enabled,
                    onTap: widget.onStartHere,
                  ),
                  ListTile(
                    leading: const Icon(Icons.swap_horiz_rounded),
                    title: const Text('Start with another model…'),
                    subtitle: const Text('A bigger window, or one on this device'),
                    enabled: enabled,
                    onTap: widget.onStartWithModel,
                  ),
                  ListTile(
                    leading: const Icon(Icons.ios_share_rounded),
                    title: const Text('Share'),
                    subtitle: const Text('Send the file to another device or app'),
                    enabled: enabled,
                    onTap: widget.onShare,
                  ),
                  ListTile(
                    leading: const Icon(Icons.save_alt_rounded),
                    title: const Text('Save to Files'),
                    subtitle: Text(HandoffCodec.fileName(bundle), maxLines: 1, overflow: TextOverflow.ellipsis),
                    enabled: enabled,
                    onTap: widget.onSave,
                  ),
                  ListTile(
                    leading: const Icon(Icons.qr_code_2_rounded),
                    title: const Text('Show QR code'),
                    subtitle: Text(
                      fits
                          ? 'For a phone nearby (${formatBytes(HandoffCodec.qrBytes(payload))} of '
                              '${formatBytes(HandoffCodec.qrCapacityBytes)})'
                          : 'Too large for a QR code: ${formatBytes(HandoffCodec.qrBytes(payload))} compressed, and '
                              'a code holds ${formatBytes(HandoffCodec.qrCapacityBytes)}. Share the file instead.',
                    ),
                    enabled: enabled && fits,
                    onTap: () => widget.onQr(payload),
                  ),
                ],
              ),
            ),
            SizedBox(height: t.space.lg),
            TextField(
              controller: widget.notes,
              minLines: 1,
              maxLines: 4,
              maxLength: 2000,
              decoration: const InputDecoration(
                labelText: 'Note for the next chat (optional)',
                helperText: 'Added to the handoff as your own words.',
              ),
            ),
            SizedBox(height: t.space.lg),
            Heading(level: 2, child: Text('What it contains', style: theme.textTheme.titleMedium)),
            SizedBox(height: t.space.sm),
            HandoffMarkdownView(bundle: bundle),
          ],
        ),
      ),
    );
  }
}
