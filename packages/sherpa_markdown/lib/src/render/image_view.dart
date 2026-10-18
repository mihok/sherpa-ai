import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import '../parse/md_ast.dart';
import 'markdown_scope.dart';

/// Largest `data:` image rendered inline (decoded bytes).
const kMaxDataImageBytes = 2 * 1024 * 1024;

/// An image from model output.
///
/// Network images are **never** fetched automatically: an image URL in a
/// model reply can carry exfiltrated data in its query string (the
/// "markdown image injection" channel), and loading it also leaks the
/// user's IP and timing to whoever wrote the URL. The user sees a chip
/// naming the host and decides; only a tap starts the request. `data:`
/// URIs involve no network and render directly, size-capped. Every other
/// scheme (file:, content:, relative paths) is never loaded.
class MarkdownImage extends StatefulWidget {
  const MarkdownImage({super.key, required this.image, this.inline = false});

  final MdImage image;

  /// Inside a paragraph (shown as a compact chip).
  final bool inline;

  @override
  State<MarkdownImage> createState() => _MarkdownImageState();
}

class _MarkdownImageState extends State<MarkdownImage> {
  bool _load = false;
  Uint8List? _dataBytes;
  String? _decodedSrc;
  bool _dataTooLarge = false;

  @override
  void didUpdateWidget(MarkdownImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A different URL needs a fresh consent.
    if (oldWidget.image.src != widget.image.src) _load = false;
  }

  @override
  Widget build(BuildContext context) {
    final src = widget.image.src;
    final uri = src == null ? null : Uri.tryParse(src);
    if (uri == null) {
      return _Chip(
        icon: Icons.image_outlined,
        label: 'Image',
        detail: widget.image.alt,
      );
    }
    if (uri.scheme == 'data') return _dataImage(context, src!);
    final web =
        (uri.scheme == 'http' || uri.scheme == 'https') && uri.host.isNotEmpty;
    if (!web) {
      return _Chip(
        icon: Icons.hide_image_outlined,
        label: 'Image not loaded',
        detail: widget.image.alt,
      );
    }
    final label = 'Image from ${uri.host}';
    if (!_load) {
      return _Chip(
        icon: Icons.image_outlined,
        label: label,
        detail: widget.image.alt,
        hint: 'Tap to load',
        onTap: () => setState(() => _load = true),
      );
    }
    final theme = MarkdownScope.of(context).theme;
    return _Frame(
      maxHeight: theme.maxImageHeight,
      child: Image.network(
        src!,
        fit: BoxFit.contain,
        semanticLabel: widget.image.alt.isEmpty ? label : widget.image.alt,
        loadingBuilder: (context, child, progress) => progress == null
            ? child
            : _Chip(
                icon: Icons.downloading_outlined,
                label: label,
                hint: 'Loading…',
              ),
        errorBuilder: (context, error, stack) => _Chip(
          icon: Icons.broken_image_outlined,
          label: "Couldn't load image from ${uri.host}",
          detail: widget.image.alt,
          hint: 'Tap to retry',
          onTap: () => setState(() {
            _load = false;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) setState(() => _load = true);
            });
          }),
        ),
      ),
    );
  }

  Widget _dataImage(BuildContext context, String src) {
    if (_decodedSrc != src) {
      _decodedSrc = src;
      _dataBytes = null;
      _dataTooLarge = false;
      // Base64 inflates by 4/3; refuse before decoding anything huge.
      if (src.length > kMaxDataImageBytes * 4 ~/ 3 + 256) {
        _dataTooLarge = true;
      } else {
        final data = UriData.parse(src);
        final mime = data.mimeType.toLowerCase();
        // SVG would need a vector renderer and can embed external refs.
        if (mime.startsWith('image/') && !mime.contains('svg')) {
          try {
            final bytes = data.contentAsBytes();
            if (bytes.length > kMaxDataImageBytes) {
              _dataTooLarge = true;
            } else {
              _dataBytes = bytes;
            }
          } on FormatException {
            _dataBytes = null;
          }
        }
      }
    }
    final bytes = _dataBytes;
    if (bytes == null) {
      return _Chip(
        icon: Icons.hide_image_outlined,
        label: _dataTooLarge ? 'Image too large' : 'Unsupported image',
        detail: widget.image.alt,
      );
    }
    final theme = MarkdownScope.of(context).theme;
    return _Frame(
      maxHeight: theme.maxImageHeight,
      child: Image(
        // Cap decoded dimensions: a small PNG can still decode to a huge
        // bitmap.
        image: ResizeImage(
          MemoryImage(bytes),
          width: 2048,
          height: 2048,
          policy: ResizeImagePolicy.fit,
          allowUpscaling: false,
        ),
        fit: BoxFit.contain,
        semanticLabel: widget.image.alt.isEmpty ? 'Image' : widget.image.alt,
        errorBuilder: (context, error, stack) => _Chip(
          icon: Icons.broken_image_outlined,
          label: 'Unsupported image',
          detail: widget.image.alt,
        ),
      ),
    );
  }
}

class _Frame extends StatelessWidget {
  const _Frame({required this.maxHeight, required this.child});

  final double maxHeight;
  final Widget child;

  @override
  Widget build(BuildContext context) => Align(
    alignment: AlignmentDirectional.centerStart,
    child: ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: ClipRRect(borderRadius: BorderRadius.circular(8), child: child),
    ),
  );
}

/// Placeholder chip: icon, a label naming the source, optional alt text.
class _Chip extends StatelessWidget {
  const _Chip({
    required this.icon,
    required this.label,
    this.detail = '',
    this.hint,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final String detail;
  final String? hint;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = MarkdownScope.of(context).theme;
    final fg = theme.chipForeground;
    final small = theme.body.copyWith(
      color: fg,
      fontSize: theme.fontSize * 0.8,
      height: 1.2,
    );
    final semantics = [label, if (detail.isNotEmpty) detail].join(': ');
    return Align(
      alignment: AlignmentDirectional.centerStart,
      widthFactor: 1,
      child: Semantics(
        button: onTap != null,
        label: semantics,
        hint: hint,
        excludeSemantics: true,
        child: Material(
          color: theme.chipBackground,
          borderRadius: BorderRadius.circular(8),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: theme.fontSize * 1.1, color: fg),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          label,
                          style: small.copyWith(fontWeight: FontWeight.w600),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (detail.isNotEmpty || hint != null)
                          Text(
                            [if (detail.isNotEmpty) detail, ?hint].join(' · '),
                            style: small,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
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
