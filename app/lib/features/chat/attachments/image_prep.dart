import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import 'attachment_policy.dart';

/// A photo made ready to send: downscaled, upright, re-encoded as JPEG,
/// with every metadata block (EXIF: GPS location, camera, time) removed.
@immutable
final class PreparedImage {
  const PreparedImage({
    required this.bytes,
    required this.width,
    required this.height,
    required this.originalWidth,
    required this.originalHeight,
    required this.inputBytes,
    required this.removedMetadata,
  });

  final Uint8List bytes;
  final int width;
  final int height;

  /// As picked (after applying the EXIF orientation).
  final int originalWidth;
  final int originalHeight;
  final int inputBytes;

  /// The picked file carried EXIF data (possibly a location) that was dropped.
  final bool removedMetadata;

  String get mimeType => 'image/jpeg';

  bool get resized => width != originalWidth || height != originalHeight;

  /// "1568×1176 · 312 KB (from 4032×3024)": what the model receives.
  String get sizeNote =>
      ['$width×$height · ${formatBytes(bytes.length)}', if (resized) '(from $originalWidth×$originalHeight)'].join(' ');
}

/// Why a picked image can't be used; [message] is shown to the user.
final class ImagePrepException implements Exception {
  const ImagePrepException(this.message);

  final String message;

  @override
  String toString() => 'ImagePrepException: $message';
}

/// Prepares [input] off the UI isolate (decoding a 12 MP photo takes a
/// moment in Dart). Throws [ImagePrepException].
typedef ImagePreparer = Future<PreparedImage> Function(Uint8List input, {required int maxLongEdge});

Future<PreparedImage> prepareImageInBackground(Uint8List input, {required int maxLongEdge}) =>
    Isolate.run(() => prepareImage(input, maxLongEdge: maxLongEdge));

/// The pipeline itself (synchronous, pure Dart):
///
/// 1. Sniff the format and read the dimensions without decoding pixels;
///    refuse anything over [AttachmentPolicy.maxImageMegapixels].
/// 2. Decode the first frame. JPEGs decode at 1/2, 1/4 or 1/8 scale while
///    that stays at or above the target, which is several times faster.
/// 3. Apply the EXIF orientation to the pixels, then drop all EXIF.
/// 4. Flatten transparency onto white (JPEG has no alpha).
/// 5. Downscale so the long edge is at most [maxLongEdge] (area average).
/// 6. Encode JPEG (quality [quality], 4:2:0); lower the quality if the
///    result is still over [AttachmentPolicy.maxImageOutputBytes].
///
/// Re-encoding happens exactly once, here: the stored bytes are what every
/// later request sends, so a prefix-bound provider never sees an image
/// change (R10 §7.9).
PreparedImage prepareImage(Uint8List input, {required int maxLongEdge, int quality = 85}) {
  if (input.length > AttachmentPolicy.maxImageInputBytes) {
    throw ImagePrepException(
      'This image is ${formatBytes(input.length)}; the limit is '
      '${formatBytes(AttachmentPolicy.maxImageInputBytes)}.',
    );
  }
  final decoder = img.findDecoderForData(input);
  if (decoder == null) {
    throw const ImagePrepException('Sherpa can read JPEG, PNG, GIF, WebP and BMP images. Convert this one first.');
  }
  final info = decoder.startDecode(input);
  if (info == null || info.width <= 0 || info.height <= 0) {
    throw const ImagePrepException("This image couldn't be read. It may be damaged.");
  }
  final megapixels = info.width * info.height / 1e6;
  if (megapixels > AttachmentPolicy.maxImageMegapixels) {
    throw ImagePrepException(
      'This image is ${info.width}×${info.height} (${megapixels.round()} MP); the limit is '
      '${AttachmentPolicy.maxImageMegapixels} MP.',
    );
  }

  img.Image? decoded;
  if (decoder is img.JpegDecoder) {
    final longEdge = math.max(info.width, info.height);
    var scale = 1;
    while (scale < 8 && longEdge / (scale * 2) >= maxLongEdge) {
      scale *= 2;
    }
    decoded = img.JpegDecoder(scale: scale).decode(input);
  } else {
    decoded = decoder.decode(input, frame: 0);
  }
  if (decoded == null) throw const ImagePrepException("This image couldn't be read. It may be damaged.");

  final hadMetadata = !decoded.exif.isEmpty;
  // Pixels upright first, then no metadata at all (GPS, device, time).
  var image = img.bakeOrientation(decoded);
  image.exif = img.ExifData();
  image.textData = null;

  // The size as the user sees it (portrait photos swap width and height).
  final scaleBack = decoder is img.JpegDecoder ? _jpegScale(info, image) : 1;
  final originalWidth = (image.width * scaleBack).round();
  final originalHeight = (image.height * scaleBack).round();

  if (image.hasAlpha || image.hasPalette || image.numChannels != 3) {
    final flat = img.Image(width: image.width, height: image.height, iccp: image.iccProfile)
      ..clear(img.ColorRgb8(255, 255, 255));
    img.compositeImage(flat, image);
    image = flat;
  }

  final long = math.max(image.width, image.height);
  if (long > maxLongEdge) {
    image = img.copyResize(
      image,
      width: image.width >= image.height ? maxLongEdge : null,
      height: image.height > image.width ? maxLongEdge : null,
      interpolation: img.Interpolation.average,
    );
  }

  var q = quality;
  var bytes = img.encodeJpg(image, quality: q, chroma: img.JpegChroma.yuv420);
  while (bytes.length > AttachmentPolicy.maxImageOutputBytes && q > 40) {
    q -= 15;
    bytes = img.encodeJpg(image, quality: q, chroma: img.JpegChroma.yuv420);
  }
  return PreparedImage(
    bytes: bytes,
    width: image.width,
    height: image.height,
    originalWidth: originalWidth,
    originalHeight: originalHeight,
    inputBytes: input.length,
    removedMetadata: hadMetadata,
  );
}

/// How much smaller than the file the JPEG was decoded (1 when not scaled).
double _jpegScale(img.DecodeInfo info, img.Image decoded) {
  final fileLong = math.max(info.width, info.height);
  final decodedLong = math.max(decoded.width, decoded.height);
  return decodedLong == 0 ? 1 : fileLong / decodedLong;
}
