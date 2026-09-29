import 'dart:typed_data';

class DocumentCorner {
  final double x;
  final double y;

  const DocumentCorner({required this.x, required this.y});

  factory DocumentCorner.fromJson(Map<String, dynamic> json) {
    return DocumentCorner(
      x: (json['x'] as num).toDouble(),
      y: (json['y'] as num).toDouble(),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{'x': x, 'y': y};
  }
}

class DocumentScanResult {
  final Uint8List correctedImageBytes;

  /// Always ordered:
  /// top-left, top-right, bottom-right, bottom-left.
  final List<DocumentCorner> corners;

  final bool pageDetected;
  final double confidence;

  const DocumentScanResult({
    required this.correctedImageBytes,
    required this.corners,
    required this.pageDetected,
    required this.confidence,
  });
}
