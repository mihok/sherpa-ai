import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../design/tokens.dart';
import '../attachments/attachment_policy.dart';
import '../attachments/attachment_store.dart';
import '../attachments/composer_attachments.dart';
import '../state/transcript_model.dart';
import 'chat_style.dart';

/// Where the user wants to attach from.
enum AttachSource { photos, camera, files }

/// The attachments waiting in the composer: a chip each (thumbnail or file
/// icon, name, what will be sent, remove), and why they can't be sent when
/// the model changed since ([blockedReason]).
class ComposerAttachmentChips extends StatelessWidget {
  const ComposerAttachmentChips({super.key, required this.attachments, this.blockedReason});

  final ComposerAttachments attachments;
  final String? blockedReason;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final items = attachments.items;
    if (items.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(bottom: t.space.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Wrap(
            spacing: t.space.xs,
            runSpacing: t.space.xs,
            children: [
              for (final a in items)
                _AttachmentChip(
                  key: ValueKey('attachment:${a.id}'),
                  attachment: a,
                  onRemove: () => attachments.remove(a.id),
                ),
            ],
          ),
          if (blockedReason != null)
            Padding(
              padding: EdgeInsets.only(top: t.space.xs, left: t.space.sm),
              child: Semantics(
                liveRegion: true,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.block_rounded, size: ChatIconSize.small, color: t.semantic.warning),
                    SizedBox(width: t.space.xs),
                    Expanded(
                      child: Text(
                        '$blockedReason Remove it to send.',
                        style: theme.textTheme.labelMedium?.copyWith(color: t.semantic.warning),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _AttachmentChip extends StatelessWidget {
  const _AttachmentChip({super.key, required this.attachment, required this.onRemove});

  final ComposerAttachment attachment;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final a = attachment;
    final muted = theme.colorScheme.onSurfaceVariant;
    final Widget leading = switch (a) {
      ComposerAttachment(ready: false) => SizedBox.square(
        dimension: 36,
        child: Center(
          child: SizedBox.square(dimension: ChatIconSize.small, child: const CircularProgressIndicator(strokeWidth: 2)),
        ),
      ),
      ComposerAttachment(kind: AttachmentKind.image, :final bytes?) => ClipRRect(
        borderRadius: BorderRadius.circular(t.radius.sm),
        child: Image.memory(
          bytes,
          width: 36,
          height: 36,
          fit: BoxFit.cover,
          cacheWidth: 96,
          excludeFromSemantics: true,
        ),
      ),
      _ => SizedBox.square(
        dimension: 36,
        child: Icon(
          a.kind == AttachmentKind.pdf ? Icons.picture_as_pdf_outlined : Icons.description_outlined,
          color: muted,
        ),
      ),
    };
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: kChromeMaxTextScale,
      child: Semantics(
        container: true,
        label: a.semanticLabel,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 260),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainer,
              border: Border.all(color: theme.colorScheme.outlineVariant),
              borderRadius: BorderRadius.circular(t.radius.md),
            ),
            child: Padding(
              padding: EdgeInsetsDirectional.only(start: t.space.xs, top: t.space.xs, bottom: t.space.xs),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  leading,
                  SizedBox(width: t.space.sm),
                  Flexible(
                    child: ExcludeSemantics(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            a.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelMedium,
                          ),
                          Text(
                            a.note,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(color: muted),
                          ),
                        ],
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Remove ${a.name}',
                    visualDensity: VisualDensity.compact,
                    iconSize: ChatIconSize.small,
                    onPressed: onRemove,
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "Attach": Photos, Camera, Files, each with what it accepts or why it
/// can't be used with this model, the limits, and where files go.
class AttachSheet extends StatelessWidget {
  const AttachSheet({super.key, required this.policy, required this.destination});

  final AttachmentPolicy policy;

  /// "Sent to Anthropic with your message" / "Stays on this phone".
  final String destination;

  static Future<AttachSource?> show(
    BuildContext context, {
    required AttachmentPolicy policy,
    required String destination,
  }) => showModalBottomSheet<AttachSource>(
    context: context,
    showDragHandle: true,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (_) => AttachSheet(policy: policy, destination: destination),
  );

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final photoNote = policy.imagesAllowed
        ? 'Resized to ${policy.maxImageEdge} px on the long edge; location and camera data removed.'
        : policy.imageRefusal!;
    final fileNote = [
      'Text, Markdown, CSV, JSON and code up to ${formatBytes(AttachmentPolicy.maxTextBytes)}.',
      if (policy.pdfAllowed) 'PDFs up to ${formatBytes(AttachmentPolicy.maxPdfBytes)}.' else policy.pdfRefusal!,
    ].join(' ');
    Widget option(AttachSource source, IconData icon, String title, String subtitle, {required bool enabled}) =>
        ListTile(
          key: ValueKey('attach-${source.name}'),
          enabled: enabled,
          leading: Icon(icon),
          title: Text(title),
          subtitle: Text(subtitle),
          onTap: enabled ? () => Navigator.of(context).pop(source) : null,
        );
    return SingleChildScrollView(
      padding: EdgeInsets.only(bottom: t.space.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: t.space.xl),
            child: Semantics(headingLevel: 2, child: Text('Attach', style: theme.textTheme.titleLarge)),
          ),
          SizedBox(height: t.space.sm),
          option(AttachSource.photos, Icons.photo_library_outlined, 'Photos', photoNote, enabled: policy.imagesAllowed),
          option(AttachSource.camera, Icons.photo_camera_outlined, 'Camera', photoNote, enabled: policy.imagesAllowed),
          option(AttachSource.files, Icons.attach_file_rounded, 'Files', fileNote, enabled: true),
          Padding(
            padding: EdgeInsets.fromLTRB(t.space.xl, t.space.sm, t.space.xl, 0),
            child: Text(
              'Up to ${AttachmentPolicy.maxPerMessage} attachments per message, '
              '${formatBytes(AttachmentPolicy.maxTotalBytes)} in all. $destination',
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
          ),
        ],
      ),
    );
  }
}

/// A sent message's photos (thumbnails) and files (chips), right-aligned
/// under the bubble.
class MessageAttachmentsView extends StatelessWidget {
  const MessageAttachmentsView({super.key, required this.attachments});

  final List<MessageAttachment> attachments;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    return Wrap(
      alignment: WrapAlignment.end,
      spacing: t.space.xs,
      runSpacing: t.space.xs,
      children: [
        for (final (i, a) in attachments.indexed)
          a.isImage
              ? _Thumbnail(key: ValueKey('thumb:$i'), attachment: a)
              : _FileChip(key: ValueKey('file:$i'), attachment: a),
      ],
    );
  }
}

class _Thumbnail extends ConsumerStatefulWidget {
  const _Thumbnail({super.key, required this.attachment});

  final MessageAttachment attachment;

  @override
  ConsumerState<_Thumbnail> createState() => _ThumbnailState();
}

class _ThumbnailState extends ConsumerState<_Thumbnail> {
  static const double _size = 112;
  Future<File?>? _file;

  @override
  void initState() {
    super.initState();
    final uri = widget.attachment.uri;
    if (widget.attachment.data == null && uri != null) _file = ref.read(chatAttachmentStoreProvider).fileFor(uri);
  }

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final a = widget.attachment;
    Widget missing() => ColoredBox(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Center(child: Icon(Icons.broken_image_outlined, color: theme.colorScheme.onSurfaceVariant)),
    );
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final cache = (_size * dpr).round();
    final Widget image = a.data != null
        ? Image.memory(
            a.data!,
            fit: BoxFit.cover,
            cacheWidth: cache,
            excludeFromSemantics: true,
            errorBuilder: (_, _, _) => missing(),
          )
        : FutureBuilder<File?>(
            future: _file,
            builder: (context, snap) {
              final f = snap.data;
              if (f == null) return snap.connectionState == ConnectionState.done ? missing() : const SizedBox.expand();
              return Image.file(
                f,
                fit: BoxFit.cover,
                cacheWidth: cache,
                excludeFromSemantics: true,
                errorBuilder: (_, _, _) => missing(),
              );
            },
          );
    return Semantics(
      container: true,
      image: true,
      label: a.semanticLabel,
      child: Tooltip(
        message: [a.name, if (a.note.isNotEmpty) a.note].join(' · '),
        excludeFromSemantics: true,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(t.radius.md),
          child: SizedBox.square(dimension: _size, child: image),
        ),
      ),
    );
  }
}

class _FileChip extends StatelessWidget {
  const _FileChip({super.key, required this.attachment});

  final MessageAttachment attachment;

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final a = attachment;
    final muted = theme.colorScheme.onSurfaceVariant;
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: kChromeMaxTextScale,
      child: Semantics(
        container: true,
        label: a.semanticLabel,
        excludeSemantics: true,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainer,
            border: Border.all(color: theme.colorScheme.outlineVariant),
            borderRadius: BorderRadius.circular(t.radius.pill),
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: t.space.sm, vertical: t.space.xxs),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  a.kind == 'pdf' ? Icons.picture_as_pdf_outlined : Icons.description_outlined,
                  size: ChatIconSize.small,
                  color: muted,
                ),
                SizedBox(width: t.space.xs),
                Flexible(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: a.name,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        if (a.note.isNotEmpty)
                          TextSpan(
                            text: ' · ${a.note}',
                            style: TextStyle(color: muted),
                          ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
