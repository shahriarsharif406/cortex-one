import 'dart:typed_data';

import 'package:image_picker/image_picker.dart' as picker;

/// Where pictures come from: the gallery or the camera. Tests plug in a fake.
abstract class PictureSource {
  Future<Uint8List?> pickGallery();
  Future<Uint8List?> pickCamera();
}

class DevicePictureSource implements PictureSource {
  DevicePictureSource([picker.ImagePicker? p]) : _p = p ?? picker.ImagePicker();

  final picker.ImagePicker _p;

  // The picker already limits the size to spare memory; the app shrinks and cleans it again.
  Future<Uint8List?> _pick(picker.ImageSource source) async {
    try {
      final f = await _p.pickImage(
        source: source,
        maxWidth: 2400,
        maxHeight: 2400,
        imageQuality: 92,
        requestFullMetadata: false,
      );
      return f == null ? null : await f.readAsBytes();
    } catch (_) {
      return null; // permission refused or no camera: nothing is attached
    }
  }

  @override
  Future<Uint8List?> pickGallery() => _pick(picker.ImageSource.gallery);

  @override
  Future<Uint8List?> pickCamera() => _pick(picker.ImageSource.camera);
}
