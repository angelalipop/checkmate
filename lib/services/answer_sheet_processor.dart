import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// A point representing a detected registration marker.
class RegistrationPoint {
  final double x;
  final double y;

  const RegistrationPoint({
    required this.x,
    required this.y,
  });

  @override
  String toString() {
    return '($x, $y)';
  }
}

/// Result of answer-sheet detection and correction.
class AnswerSheetProcessingResult {
  final Uint8List correctedImageBytes;
  final List<RegistrationPoint> markers;
  final int originalWidth;
  final int originalHeight;

  const AnswerSheetProcessingResult({
    required this.correctedImageBytes,
    required this.markers,
    required this.originalWidth,
    required this.originalHeight,
  });
}

/// Handles image processing for CheckMate answer sheets.
class AnswerSheetProcessor {
  AnswerSheetProcessor._();

  // ============================================================
  // OUTPUT CONFIGURATION
  // ============================================================

  static const double _a5AspectRatio = 148.0 / 210.0;

  static const int _outputHeight = 2129;
  static const int _outputWidth = 1500;

  // ============================================================
  // MARKER DETECTION CONFIGURATION
  // ============================================================

  static const int _darkThreshold = 70;

  static const double _minimumMarkerAreaRatio = 0.00001;
  static const double _maximumMarkerAreaRatio = 0.015;

  static const double _minimumAspectRatio = 0.55;
  static const double _maximumAspectRatio = 1.8;

  /// Only candidates inside these corner regions
  /// are considered for registration markers.
  static const double _cornerRegionRatio = 0.25;

  // ============================================================
  // PUBLIC API
  // ============================================================

  static Future<AnswerSheetProcessingResult>
      processAnswerSheet(Uint8List imageBytes) async {
    final img.Image? decoded =
        img.decodeImage(imageBytes);

    if (decoded == null) {
      throw const FormatException(
        'Unable to decode the answer sheet image.',
      );
    }

    // Normalize EXIF orientation.
    final img.Image image =
        img.bakeOrientation(decoded);

    // Detect markers.
    final List<RegistrationPoint> markers =
        _detectRegistrationMarkers(image);

    if (markers.length != 4) {
      throw StateError(
        'Could not detect all four registration markers. '
        'Detected ${markers.length} of 4.',
      );
    }

    // Order markers.
    final List<RegistrationPoint> ordered =
        _orderMarkers(markers);

    // Correct perspective.
    final img.Image corrected =
        _correctPerspective(
      image,
      ordered,
    );

    final Uint8List correctedBytes =
        Uint8List.fromList(
      img.encodePng(corrected),
    );

    return AnswerSheetProcessingResult(
      correctedImageBytes: correctedBytes,
      markers: ordered,
      originalWidth: image.width,
      originalHeight: image.height,
    );
  }

  // ============================================================
  // MARKER DETECTION
  // ============================================================

  static List<RegistrationPoint>
      _detectRegistrationMarkers(
    img.Image image,
  ) {
    final int width = image.width;
    final int height = image.height;

    const int sampleStep = 2;

    final int sampledWidth =
        (width / sampleStep).ceil();

    final int sampledHeight =
        (height / sampleStep).ceil();

    // IMPORTANT:
    //
    // Components are detected on the sampled image,
    // so the area thresholds must also be based
    // on the sampled image.
    final int sampledTotalPixels =
        sampledWidth * sampledHeight;

    final int minimumArea = math.max(
      4,
      (sampledTotalPixels *
              _minimumMarkerAreaRatio)
          .round(),
    );

    final int maximumArea =
        (sampledTotalPixels *
                _maximumMarkerAreaRatio)
            .round();

    final List<bool> darkPixels =
        List<bool>.filled(
      sampledTotalPixels,
      false,
    );

    // ----------------------------------------------------------
    // Create binary image.
    // ----------------------------------------------------------

    for (int y = 0;
        y < sampledHeight;
        y++) {
      final int sourceY =
          math.min(
        y * sampleStep,
        height - 1,
      );

      for (int x = 0;
          x < sampledWidth;
          x++) {
        final int sourceX =
            math.min(
          x * sampleStep,
          width - 1,
        );

        final img.Pixel pixel =
            image.getPixel(
          sourceX,
          sourceY,
        );

        final double luminance =
            0.299 * pixel.r.toDouble() +
                0.587 * pixel.g.toDouble() +
                0.114 * pixel.b.toDouble();

        darkPixels[
          y * sampledWidth + x
        ] = luminance <= _darkThreshold;
      }
    }

    // ----------------------------------------------------------
    // Find connected components.
    // ----------------------------------------------------------

    final List<_Component> components =
        <_Component>[];

    final List<bool> visited =
        List<bool>.filled(
      darkPixels.length,
      false,
    );

    for (int y = 0;
        y < sampledHeight;
        y++) {
      for (int x = 0;
          x < sampledWidth;
          x++) {
        final int index =
            y * sampledWidth + x;

        if (!darkPixels[index] ||
            visited[index]) {
          continue;
        }

        final _Component component =
            _floodFill(
          darkPixels,
          visited,
          sampledWidth,
          sampledHeight,
          x,
          y,
        );

        if (component.area < minimumArea ||
            component.area > maximumArea) {
          continue;
        }

        final double componentWidth =
            (component.maxX -
                    component.minX +
                    1)
                .toDouble();

        final double componentHeight =
            (component.maxY -
                    component.minY +
                    1)
                .toDouble();

        if (componentHeight <= 0.0) {
          continue;
        }

        final double aspectRatio =
            componentWidth /
                componentHeight;

        if (aspectRatio <
                _minimumAspectRatio ||
            aspectRatio >
                _maximumAspectRatio) {
          continue;
        }

        components.add(component);
      }
    }

    if (components.isEmpty) {
      return <RegistrationPoint>[];
    }

    // ----------------------------------------------------------
    // Convert to candidates.
    // ----------------------------------------------------------

    final List<_MarkerCandidate> candidates =
        components.map(
      (_Component component) {
        final double centerX =
            ((component.minX +
                        component.maxX) /
                    2.0) *
                sampleStep.toDouble();

        final double centerY =
            ((component.minY +
                        component.maxY) /
                    2.0) *
                sampleStep.toDouble();

        return _MarkerCandidate(
          point: RegistrationPoint(
            x: centerX,
            y: centerY,
          ),
          area: component.area,
          width:
              (component.maxX -
                      component.minX +
                      1) *
                  sampleStep.toDouble(),
          height:
              (component.maxY -
                      component.minY +
                      1) *
                  sampleStep.toDouble(),
        );
      },
    ).toList();

    // ----------------------------------------------------------
    // Select one marker from each corner region.
    // ----------------------------------------------------------

    final List<_MarkerCandidate> selected =
        _selectCornerCandidates(
      candidates,
      width.toDouble(),
      height.toDouble(),
    );

    return selected
        .map(
          (_MarkerCandidate candidate) =>
              candidate.point,
        )
        .toList();
  }

  // ============================================================
  // FLOOD FILL
  // ============================================================

  static _Component _floodFill(
    List<bool> pixels,
    List<bool> visited,
    int width,
    int height,
    int startX,
    int startY,
  ) {
    final List<_GridPoint> queue =
        <_GridPoint>[
      _GridPoint(
        startX,
        startY,
      ),
    ];

    visited[
      startY * width + startX
    ] = true;

    int minX = startX;
    int maxX = startX;
    int minY = startY;
    int maxY = startY;

    int area = 0;
    int queueIndex = 0;

    while (queueIndex < queue.length) {
      final _GridPoint current =
          queue[queueIndex++];

      final int x = current.x;
      final int y = current.y;

      area++;

      minX = math.min(
        minX,
        x,
      );

      maxX = math.max(
        maxX,
        x,
      );

      minY = math.min(
        minY,
        y,
      );

      maxY = math.max(
        maxY,
        y,
      );

      const List<List<int>> directions =
          <List<int>>[
        <int>[1, 0],
        <int>[-1, 0],
        <int>[0, 1],
        <int>[0, -1],
      ];

      for (final List<int> direction
          in directions) {
        final int nextX =
            x + direction[0];

        final int nextY =
            y + direction[1];

        if (nextX < 0 ||
            nextX >= width ||
            nextY < 0 ||
            nextY >= height) {
          continue;
        }

        final int nextIndex =
            nextY * width + nextX;

        if (!pixels[nextIndex] ||
            visited[nextIndex]) {
          continue;
        }

        visited[nextIndex] = true;

        queue.add(
          _GridPoint(
            nextX,
            nextY,
          ),
        );
      }
    }

    return _Component(
      area: area,
      minX: minX,
      maxX: maxX,
      minY: minY,
      maxY: maxY,
    );
  }

  // ============================================================
  // CORNER SELECTION
  // ============================================================

  static List<_MarkerCandidate>
      _selectCornerCandidates(
    List<_MarkerCandidate> candidates,
    double width,
    double height,
  ) {
    if (candidates.length < 4) {
      return <_MarkerCandidate>[];
    }

    final double cornerWidth =
        width * _cornerRegionRatio;

    final double cornerHeight =
        height * _cornerRegionRatio;

    final _MarkerCandidate? topLeft =
        _findBestCandidateInRegion(
      candidates,
      minX: 0.0,
      maxX: cornerWidth,
      minY: 0.0,
      maxY: cornerHeight,
    );

    final _MarkerCandidate? topRight =
        _findBestCandidateInRegion(
      candidates,
      minX: width - cornerWidth,
      maxX: width,
      minY: 0.0,
      maxY: cornerHeight,
      excluded: <_MarkerCandidate>[
        if (topLeft != null) topLeft,
      ],
    );

    final _MarkerCandidate? bottomLeft =
        _findBestCandidateInRegion(
      candidates,
      minX: 0.0,
      maxX: cornerWidth,
      minY: height - cornerHeight,
      maxY: height,
      excluded: <_MarkerCandidate>[
        if (topLeft != null) topLeft,
        if (topRight != null) topRight,
      ],
    );

    final _MarkerCandidate? bottomRight =
        _findBestCandidateInRegion(
      candidates,
      minX: width - cornerWidth,
      maxX: width,
      minY: height - cornerHeight,
      maxY: height,
      excluded: <_MarkerCandidate>[
        if (topLeft != null) topLeft,
        if (topRight != null) topRight,
        if (bottomLeft != null) bottomLeft,
      ],
    );

    if (topLeft == null ||
        topRight == null ||
        bottomLeft == null ||
        bottomRight == null) {
      return <_MarkerCandidate>[];
    }

    return <_MarkerCandidate>[
      topLeft,
      topRight,
      bottomRight,
      bottomLeft,
    ];
  }

  static _MarkerCandidate?
      _findBestCandidateInRegion(
    List<_MarkerCandidate> candidates, {
    required double minX,
    required double maxX,
    required double minY,
    required double maxY,
    List<_MarkerCandidate> excluded =
        const <_MarkerCandidate>[],
  }) {
    _MarkerCandidate? best;
    double bestScore = double.infinity;

    final double targetX =
        (minX + maxX) / 2.0;

    final double targetY =
        (minY + maxY) / 2.0;

    final double regionWidth =
        maxX - minX;

    final double regionHeight =
        maxY - minY;

    final double diagonal =
        math.sqrt(
      regionWidth * regionWidth +
          regionHeight * regionHeight,
    );

    for (final _MarkerCandidate candidate
        in candidates) {
      if (excluded.contains(candidate)) {
        continue;
      }

      final double x =
          candidate.point.x;

      final double y =
          candidate.point.y;

      // Candidate must actually be inside
      // this corner region.
      if (x < minX ||
          x > maxX ||
          y < minY ||
          y > maxY) {
        continue;
      }

      final double dx =
          x - targetX;

      final double dy =
          y - targetY;

      final double distance =
          math.sqrt(
        dx * dx + dy * dy,
      );

      final double normalizedDistance =
          diagonal > 0.0
              ? distance / diagonal
              : distance;

      // Prefer approximately square markers.
      final double shapePenalty =
          (candidate.width -
                      candidate.height)
                  .abs() /
              math.max(
                candidate.width,
                candidate.height,
              );

      final double score =
          normalizedDistance +
              shapePenalty * 0.35;

      if (score < bestScore) {
        bestScore = score;
        best = candidate;
      }
    }

    return best;
  }

  // ============================================================
  // MARKER ORDERING
  // ============================================================

  static List<RegistrationPoint>
      _orderMarkers(
    List<RegistrationPoint> points,
  ) {
    if (points.length != 4) {
      throw StateError(
        'Exactly four registration markers are required.',
      );
    }

    // Because candidates are now explicitly selected
    // from corner regions, we can safely determine
    // their final positions using X/Y.

    final List<RegistrationPoint> sorted =
        List<RegistrationPoint>.from(points)
          ..sort(
            (
              RegistrationPoint a,
              RegistrationPoint b,
            ) {
              return a.y.compareTo(
                b.y,
              );
            },
          );

    final List<RegistrationPoint> top =
        sorted.sublist(0, 2);

    final List<RegistrationPoint> bottom =
        sorted.sublist(2, 4);

    top.sort(
      (
        RegistrationPoint a,
        RegistrationPoint b,
      ) {
        return a.x.compareTo(
          b.x,
        );
      },
    );

    bottom.sort(
      (
        RegistrationPoint a,
        RegistrationPoint b,
      ) {
        return a.x.compareTo(
          b.x,
        );
      },
    );

    return <RegistrationPoint>[
      top[0],
      top[1],
      bottom[1],
      bottom[0],
    ];
  }

  // ============================================================
  // PERSPECTIVE CORRECTION
  // ============================================================

    static img.Image _correctPerspective(
    img.Image source,
    List<RegistrationPoint> markers,
  ) {
    final tl = markers[0];
    final tr = markers[1];
    final br = markers[2];
    final bl = markers[3];

    const outputWidth = 1500;
    const outputHeight = 2129;

    // The registration markers are NOT the actual page corners.
    // They are inset from the physical edges of the answer sheet.
    //
    // Expand the marker quadrilateral outward before rectification.
    // This keeps content such as the QR code inside the corrected page.

    final centerX = (tl.x + tr.x + br.x + bl.x) / 4;
    final centerY = (tl.y + tr.y + br.y + bl.y) / 4;

    // Increase these if content is still being clipped.
    const horizontalExpansion = 0.10;
    const verticalExpansion = 0.10;

    img.Point expandPoint(
      double x,
      double y,
      double horizontal,
      double vertical,
    ) {
      final dx = x - centerX;
      final dy = y - centerY;

      return img.Point(
        centerX + dx * (1 + horizontal),
        centerY + dy * (1 + vertical),
      );
    }

    final expandedTL = expandPoint(
      tl.x,
      tl.y,
      horizontalExpansion,
      verticalExpansion,
    );

    final expandedTR = expandPoint(
      tr.x,
      tr.y,
      horizontalExpansion,
      verticalExpansion,
    );

    final expandedBR = expandPoint(
      br.x,
      br.y,
      horizontalExpansion,
      verticalExpansion,
    );

    final expandedBL = expandPoint(
      bl.x,
      bl.y,
      horizontalExpansion,
      verticalExpansion,
    );

    final corrected = img.copyRectify(
      source,
      topLeft: expandedTL,
      topRight: expandedTR,
      bottomRight: expandedBR,
      bottomLeft: expandedBL,
    );

    return img.copyResize(
      corrected,
      width: outputWidth,
      height: outputHeight,
    );
  }

  // ============================================================
  // A5 ASPECT RATIO
  // ============================================================

  static double get a5AspectRatio {
    return _a5AspectRatio;
  }
}

// ============================================================
// INTERNAL HELPER CLASSES
// ============================================================

class _GridPoint {
  final int x;
  final int y;

  const _GridPoint(
    this.x,
    this.y,
  );
}

class _Component {
  final int area;
  final int minX;
  final int maxX;
  final int minY;
  final int maxY;

  const _Component({
    required this.area,
    required this.minX,
    required this.maxX,
    required this.minY,
    required this.maxY,
  });
}

class _MarkerCandidate {
  final RegistrationPoint point;
  final int area;
  final double width;
  final double height;

  const _MarkerCandidate({
    required this.point,
    required this.area,
    required this.width,
    required this.height,
  });
}