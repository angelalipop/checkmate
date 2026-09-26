import 'dart:typed_data';

import 'package:opencv_dart/opencv_dart.dart' as cv;

class OpenCVTestService {
  /// Converts an image into an adaptive-thresholded black/white image.
  ///
  /// This is intentionally only a diagnostic step.
  /// It does NOT perform OMR yet.
  static Future<Uint8List?> adaptiveThreshold(Uint8List imageBytes) async {
    final cv.Mat source = cv.imdecode(imageBytes, cv.IMREAD_COLOR);

    if (source.isEmpty) {
      source.dispose();
      throw Exception('OpenCV could not decode the image.');
    }

    cv.Mat? gray;
    cv.Mat? blurred;
    cv.Mat? thresholded;

    try {
      gray = cv.cvtColor(source, cv.COLOR_BGR2GRAY);

      blurred = cv.gaussianBlur(gray, (5, 5), 0);

      thresholded = cv.adaptiveThreshold(
        blurred,
        255,
        cv.ADAPTIVE_THRESH_GAUSSIAN_C,
        cv.THRESH_BINARY_INV,
        31,
        10,
      );

      final (bool success, Uint8List encoded) = cv.imencode(
        '.png',
        thresholded,
      );

      if (!success) {
        throw Exception('OpenCV could not encode the thresholded image.');
      }

      return encoded;
    } finally {
      thresholded?.dispose();
      blurred?.dispose();
      gray?.dispose();
      source.dispose();
    }
  }
}
