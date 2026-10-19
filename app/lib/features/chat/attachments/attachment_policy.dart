import 'package:flutter/foundation.dart';
import 'package:sherpa_core/sherpa_core.dart';

/// What a chat's current model accepts as attachments, and the limits
/// Sherpa applies before anything is sent.
///
/// Limits come from docs/research/10 (R10) per API:
/// * Anthropic: images ≤ 8000 px and 10 MB base64 each, 32 MB per request;
///   Sherpa downscales to a 1568 px long edge (the size every Claude model
///   takes natively; 4.7+ goes to 2576 px but costs ~2.7× the tokens) and
///   sends PDFs as `document` blocks (R10 §7.2).
/// * OpenAI (Chat and Responses): `detail: high` fits images into a
///   2048 px square anyway, so larger uploads only cost bandwidth. PDFs are
///   not mapped by Sherpa's OpenAI adapters yet, so they are refused.
/// * Servers on the local network and on-device models: 1024 px, which
///   keeps image tokens (and memory on the phone) small.
///
/// Every limit is shown to the user in [summary] and in the refusal copy,
/// so nothing is dropped silently.
@immutable
final class AttachmentPolicy {
  const AttachmentPolicy({
    required this.modelName,
    required this.imagesAllowed,
    required this.maxImageEdge,
    required this.pdfAllowed,
    this.imageRefusal,
    this.pdfRefusal,
  });

  /// The chat's model. [vision] decides images; the provider kind decides
  /// PDFs and the image size.
  factory AttachmentPolicy.forModel({
    required String modelName,
    required ProviderInfo provider,
    required ModelCapabilities capabilities,
  }) {
    final edge = switch (provider.kind) {
      ProviderKind.anthropic || ProviderKind.fake => anthropicImageEdge,
      ProviderKind.openAiCompatible => provider.location == ExecutionLocation.remote ? openAiImageEdge : localImageEdge,
      ProviderKind.localLlamaCpp ||
      ProviderKind.localMlx ||
      ProviderKind.localLiteRt ||
      ProviderKind.localSystem => localImageEdge,
    };
    final pdf = provider.kind == ProviderKind.anthropic;
    return AttachmentPolicy(
      modelName: modelName,
      imagesAllowed: capabilities.vision,
      maxImageEdge: edge,
      pdfAllowed: pdf,
      imageRefusal: capabilities.vision
          ? null
          : "$modelName can't see images. Switch to a model with vision to attach photos.",
      pdfRefusal: pdf
          ? null
          : "$modelName's provider can't take PDFs in Sherpa yet (only Anthropic models can). "
                'Attach the text as a .txt or .md file instead.',
    );
  }

  /// Before the model is known: only text files.
  static const AttachmentPolicy textOnly = AttachmentPolicy(
    modelName: 'This model',
    imagesAllowed: false,
    maxImageEdge: localImageEdge,
    pdfAllowed: false,
    imageRefusal: 'Choose a model first to attach photos.',
    pdfRefusal: 'Choose a model first to attach PDFs.',
  );

  static const int anthropicImageEdge = 1568;
  static const int openAiImageEdge = 2048;
  static const int localImageEdge = 1024;

  /// Attachments per message.
  static const int maxPerMessage = 6;

  /// A photo as picked, before it is downscaled.
  static const int maxImageInputBytes = 40 * 1024 * 1024;

  /// Decoding a larger image would need too much memory on a phone.
  static const int maxImageMegapixels = 64;

  /// After downscaling (JPEG); far below every API's per-image cap.
  static const int maxImageOutputBytes = 4 * 1024 * 1024;

  /// About 60k tokens of text.
  static const int maxTextBytes = 256 * 1024;

  /// Base64 makes it ~13.3 MB, well inside Anthropic's 32 MB request cap.
  static const int maxPdfBytes = 10 * 1024 * 1024;

  /// Everything attached to one message, before encoding.
  static const int maxTotalBytes = 24 * 1024 * 1024;

  final String modelName;
  final bool imagesAllowed;

  /// Long edge images are downscaled to, in pixels.
  final int maxImageEdge;
  final bool pdfAllowed;

  /// Why images can't be attached (null when they can).
  final String? imageRefusal;

  /// Why PDFs can't be attached (null when they can).
  final String? pdfRefusal;

  /// One line for the attach sheet: what is accepted and how big.
  String get summary => [
    if (imagesAllowed) 'Photos are resized to $maxImageEdge px and their location data is removed',
    'text files up to ${formatBytes(maxTextBytes)}',
    if (pdfAllowed) 'PDFs up to ${formatBytes(maxPdfBytes)}',
    'up to $maxPerMessage per message',
  ].join(' · ');

  @override
  bool operator ==(Object other) =>
      other is AttachmentPolicy &&
      other.modelName == modelName &&
      other.imagesAllowed == imagesAllowed &&
      other.maxImageEdge == maxImageEdge &&
      other.pdfAllowed == pdfAllowed &&
      other.imageRefusal == imageRefusal &&
      other.pdfRefusal == pdfRefusal;

  @override
  int get hashCode => Object.hash(modelName, imagesAllowed, maxImageEdge, pdfAllowed, imageRefusal, pdfRefusal);
}

/// "312 KB", "4.2 MB".
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
  final mb = bytes / (1024 * 1024);
  return '${mb >= 10 || mb == mb.roundToDouble() ? mb.round() : mb.toStringAsFixed(1)} MB';
}
