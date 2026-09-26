import 'dart:typed_data';

class OpenCVTestService {
  /// The native OpenCV threshold preview is diagnostic only.
  /// Web OMR is performed by the Dart Frog backend, so Chrome skips this
  /// preview instead of importing dart:ffi-based OpenCV code.
  static Future<Uint8List?> adaptiveThreshold(Uint8List imageBytes) async {
    return null;
  }
}
