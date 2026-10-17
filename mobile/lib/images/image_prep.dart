import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../api/models.dart';

/// Thrown when a picture cannot be made small and clean enough. The message key is a string in
/// strings.dart (never a technical text).
class ImagePrepError implements Exception {
  const ImagePrepError(this.messageKey);
  final String messageKey;
}

/// Agent limits (agent/images.py): at most 1.5 MB per picture.
const int maxUploadBytes = 1500000;

/// True when the JPEG holds only the JFIF header (APP0) and no EXIF / XMP / comment / other
/// application data. The agent refuses pictures that fail this, so the phone checks too.
bool jpegMetadataFree(Uint8List b) {
  if (b.length < 4 || b[0] != 0xFF || b[1] != 0xD8) return false;
  var pos = 2;
  while (pos + 4 <= b.length) {
    if (b[pos] != 0xFF) return false;
    final marker = b[pos + 1];
    if (marker == 0xFF) {
      pos++;
      continue;
    }
    if (marker == 0xD9) return true;
    if ((marker >= 0xD0 && marker <= 0xD7) || marker == 0x01 || marker == 0x00) {
      pos += 2;
      continue;
    }
    final len = (b[pos + 2] << 8) | b[pos + 3];
    if (len < 2 || pos + 2 + len > b.length) return false;
    if ((marker >= 0xE1 && marker <= 0xEF) || marker == 0xFE) return false;
    if (marker == 0xDA) return true; // pixel data follows; nothing after it is metadata
    pos += 2 + len;
  }
  return true;
}

/// Decodes any picture the phone gives us, applies its rotation, shrinks it (never enlarges),
/// and re-encodes it as a fresh JPEG copied pixel by pixel: nothing of the original file
/// (EXIF, GPS, camera name, thumbnails, comments) survives. [maxSide] is the longest edge.
///
/// Tries smaller sizes until the result is under [maxUploadBytes]; otherwise it gives up.
TaskImage prepareImage(Uint8List raw, {int maxSide = 1280, int limit = maxUploadBytes}) {
  img.Image? decoded;
  try {
    decoded = img.decodeImage(raw);
  } catch (_) {
    decoded = null;
  }
  if (decoded == null) throw const ImagePrepError('image_failed');
  final upright = img.bakeOrientation(decoded);
  final steps = <(int, int)>[(maxSide, 80), ((maxSide * 0.8).round(), 65), ((maxSide * 0.6).round(), 50)];
  for (final (side, quality) in steps) {
    final longest = upright.width > upright.height ? upright.width : upright.height;
    final scale = longest > side ? side / longest : 1.0;
    final w = (upright.width * scale).round().clamp(8, 4096);
    final h = (upright.height * scale).round().clamp(8, 4096);
    final resized = scale < 1.0
        ? img.copyResize(upright, width: w, height: h, interpolation: img.Interpolation.average)
        : upright;
    // a brand-new image: only pixels are copied, no metadata object is carried over
    final clean = img.Image(width: resized.width, height: resized.height, numChannels: 3);
    img.compositeImage(clean, resized);
    final bytes = Uint8List.fromList(img.encodeJpg(clean, quality: quality));
    if (!jpegMetadataFree(bytes)) throw const ImagePrepError('image_failed');
    if (bytes.length <= limit) {
      return TaskImage(
        mediaType: 'image/jpeg',
        bytes: bytes,
        width: clean.width,
        height: clean.height,
      );
    }
  }
  throw const ImagePrepError('image_too_big');
}
