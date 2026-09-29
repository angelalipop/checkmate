import 'dart:math' as math;
import 'dart:typed_data';

import 'package:opencv_dart/opencv_dart.dart' as cv;

import 'document_scanner_models.dart';

class DocumentScannerService {
  static const double _expectedPageRatio = 397.0 / 559.0;

  /// Do not accept tiny rectangles as documents.
  static const double _minimumPageAreaRatio = 0.10;

  /// Output used only for coarse document normalization.
  ///
  /// The existing registration-marker processor will still perform the
  /// final precision normalization to 1500 x 2129.
  static const int _outputWidth = 1000;
  static const int _outputHeight = 1408;

  static Future<DocumentScanResult> process(Uint8List imageBytes) async {
    final cv.Mat source = cv.imdecode(imageBytes, cv.IMREAD_COLOR);

    if (source.isEmpty) {
      source.dispose();

      throw Exception('OpenCV could not decode the answer sheet image.');
    }

    cv.Mat? gray;
    cv.Mat? blurred;
    cv.Mat? edges;
    cv.Mat? closed;
    cv.Mat? thresholded;
    cv.Mat? thresholdClosed;
    cv.Mat? kernel;

    try {
      // ---------------------------------------------------------------
      // 1. GRAYSCALE
      // ---------------------------------------------------------------

      gray = cv.cvtColor(source, cv.COLOR_BGR2GRAY);

      // ---------------------------------------------------------------
      // 2. REMOVE SMALL IMAGE NOISE
      // ---------------------------------------------------------------

      blurred = cv.gaussianBlur(gray, (7, 7), 0);

      // ---------------------------------------------------------------
      // 3. FIND STRONG EDGES
      // ---------------------------------------------------------------

      edges = cv.canny(blurred, 30, 100);

      // ---------------------------------------------------------------
      // 4. CONNECT SMALL GAPS IN PAPER EDGES
      // ---------------------------------------------------------------

      kernel = cv.getStructuringElement(cv.MORPH_RECT, (7, 7));

      closed = cv.morphologyEx(edges, cv.MORPH_CLOSE, kernel, iterations: 3);

      // ---------------------------------------------------------------
      // 5. FIND DOCUMENT CANDIDATES USING TWO COMPLEMENTARY PASSES
      // ---------------------------------------------------------------
      //
      // Pass A: Canny edges, which works well when the physical paper edge is
      // visible against the background.
      //
      // Pass B: adaptive thresholding, which is useful when the physical edge
      // is weak but the large printed CheckMate border is clearly visible.
      // The printed border is inset only slightly from the page edge, so it is
      // a valid coarse document quadrilateral. The registration-marker stage
      // still performs the final precise normalization afterwards.

      final _DocumentCandidate? edgeCandidate = _findBestDocumentCandidate(
        closed,
        imageWidth: source.cols,
        imageHeight: source.rows,
      );

      thresholded = cv.adaptiveThreshold(
        blurred,
        255,
        cv.ADAPTIVE_THRESH_GAUSSIAN_C,
        cv.THRESH_BINARY_INV,
        51,
        7,
      );

      thresholdClosed = cv.morphologyEx(
        thresholded,
        cv.MORPH_CLOSE,
        kernel,
        iterations: 2,
      );

      final _DocumentCandidate? thresholdCandidate = _findBestDocumentCandidate(
        thresholdClosed,
        imageWidth: source.cols,
        imageHeight: source.rows,
      );

      _DocumentCandidate? bestCandidate = edgeCandidate;

      if (thresholdCandidate != null &&
          (bestCandidate == null ||
              thresholdCandidate.score > bestCandidate.score)) {
        bestCandidate = thresholdCandidate;
      }

      if (bestCandidate == null) {
        throw Exception(
          'The answer sheet boundary could not be detected. '
          'Make sure the full sheet and all four corners are visible.',
        );
      }

      // -------------------------------------------------------------
      // 6. PERSPECTIVE-WARP THE PHYSICAL PAPER / PRINTED PAGE BORDER
      // -------------------------------------------------------------

      final List<_Point> corners = bestCandidate.corners;

      final srcPoints = cv.VecPoint2f.fromList(<cv.Point2f>[
        cv.Point2f(corners[0].x, corners[0].y),
        cv.Point2f(corners[1].x, corners[1].y),
        cv.Point2f(corners[2].x, corners[2].y),
        cv.Point2f(corners[3].x, corners[3].y),
      ]);

      final dstPoints = cv.VecPoint2f.fromList(<cv.Point2f>[
        cv.Point2f(0, 0),
        cv.Point2f(_outputWidth - 1, 0),
        cv.Point2f(_outputWidth - 1, _outputHeight - 1),
        cv.Point2f(0, _outputHeight - 1),
      ]);

      cv.Mat? transform;
      cv.Mat? warped;

      try {
        transform = cv.getPerspectiveTransform2f(srcPoints, dstPoints);

        warped = cv.warpPerspective(
          source,
          transform,
          (_outputWidth, _outputHeight),
          flags: cv.INTER_LINEAR,
          borderMode: cv.BORDER_CONSTANT,
          borderValue: cv.Scalar.all(255),
        );

        final (bool success, Uint8List encoded) = cv.imencode('.png', warped);

        if (!success) {
          throw Exception('OpenCV could not encode the corrected document.');
        }

        return DocumentScanResult(
          correctedImageBytes: encoded,
          corners: <DocumentCorner>[
            for (final point in corners) DocumentCorner(x: point.x, y: point.y),
          ],
          pageDetected: true,
          confidence: bestCandidate.score.clamp(0.0, 1.0),
        );
      } finally {
        warped?.dispose();
        transform?.dispose();
        srcPoints.dispose();
        dstPoints.dispose();
      }
    } finally {
      kernel?.dispose();
      thresholdClosed?.dispose();
      thresholded?.dispose();
      closed?.dispose();
      edges?.dispose();
      blurred?.dispose();
      gray?.dispose();
      source.dispose();
    }
  }

  static _DocumentCandidate? _findBestDocumentCandidate(
    cv.Mat contourImage, {
    required int imageWidth,
    required int imageHeight,
  }) {
    final (contours, hierarchy) = cv.findContours(
      contourImage,
      cv.RETR_LIST,
      cv.CHAIN_APPROX_SIMPLE,
    );

    try {
      final double imageArea = imageWidth.toDouble() * imageHeight.toDouble();

      _DocumentCandidate? bestCandidate;

      for (final contour in contours) {
        final double area = cv.contourArea(contour).abs();

        if (area < imageArea * _minimumPageAreaRatio) {
          continue;
        }

        final double perimeter = cv.arcLength(contour, true);
        if (perimeter <= 0) continue;

        for (final double epsilonRatio in <double>[
          0.010,
          0.015,
          0.020,
          0.025,
          0.030,
          0.040,
          0.050,
          0.060,
          0.075,
          0.090,
        ]) {
          final approx = cv.approxPolyDP(
            contour,
            epsilonRatio * perimeter,
            true,
          );

          try {
            if (approx.length != 4) continue;
            if (!cv.isContourConvex(approx)) continue;

            final points = <_Point>[
              for (final point in approx)
                _Point(point.x.toDouble(), point.y.toDouble()),
            ];

            final ordered = _orderCorners(points);

            if (!_isValidDocument(
              ordered,
              imageWidth: imageWidth,
              imageHeight: imageHeight,
            )) {
              continue;
            }

            final double candidateArea = _quadrilateralArea(ordered);
            final double areaScore = candidateArea / imageArea;
            final double ratioScore = _pageRatioScore(ordered);

            // Area dominates because the intended target is the outer paper or
            // the large printed page border, not an internal section box.
            final double score = (areaScore * 0.82) + (ratioScore * 0.18);

            final candidate = _DocumentCandidate(
              corners: ordered,
              score: score,
              areaRatio: areaScore,
            );

            if (bestCandidate == null ||
                candidate.score > bestCandidate.score) {
              bestCandidate = candidate;
            }
          } finally {
            approx.dispose();
          }
        }
      }

      return bestCandidate;
    } finally {
      contours.dispose();
      hierarchy.dispose();
    }
  }

  static bool _isValidDocument(
    List<_Point> corners, {
    required int imageWidth,
    required int imageHeight,
  }) {
    if (corners.length != 4) {
      return false;
    }

    final double top = _distance(corners[0], corners[1]);

    final double right = _distance(corners[1], corners[2]);

    final double bottom = _distance(corners[3], corners[2]);

    final double left = _distance(corners[0], corners[3]);

    if (top <= 0 || right <= 0 || bottom <= 0 || left <= 0) {
      return false;
    }

    final double averageWidth = (top + bottom) / 2.0;

    final double averageHeight = (left + right) / 2.0;

    // CheckMate answer sheets are portrait.
    if (averageHeight <= averageWidth) {
      return false;
    }

    final double ratio = averageWidth / averageHeight;

    // Generous because perspective distortion can be strong
    // before the document is rectified.
    if (ratio < 0.35 || ratio > 1.05) {
      return false;
    }

    final double imageDiagonal = math.sqrt(
      imageWidth * imageWidth + imageHeight * imageHeight,
    );

    // Reject tiny quadrilaterals.
    if (averageWidth < imageDiagonal * 0.14 ||
        averageHeight < imageDiagonal * 0.22) {
      return false;
    }

    return true;
  }

  static double _pageRatioScore(List<_Point> corners) {
    final double top = _distance(corners[0], corners[1]);

    final double bottom = _distance(corners[3], corners[2]);

    final double left = _distance(corners[0], corners[3]);

    final double right = _distance(corners[1], corners[2]);

    final double width = (top + bottom) / 2.0;

    final double height = (left + right) / 2.0;

    if (height <= 0) {
      return 0.0;
    }

    final double ratio = width / height;

    final double difference = (ratio - _expectedPageRatio).abs();

    return (1.0 - difference).clamp(0.0, 1.0);
  }

  static List<_Point> _orderCorners(List<_Point> points) {
    if (points.length != 4) {
      throw Exception('Document requires exactly four corners.');
    }

    _Point? topLeft;
    _Point? topRight;
    _Point? bottomRight;
    _Point? bottomLeft;

    double smallestSum = double.infinity;
    double largestSum = -double.infinity;

    double smallestDifference = double.infinity;
    double largestDifference = -double.infinity;

    for (final point in points) {
      final double sum = point.x + point.y;

      final double difference = point.y - point.x;

      if (sum < smallestSum) {
        smallestSum = sum;
        topLeft = point;
      }

      if (sum > largestSum) {
        largestSum = sum;
        bottomRight = point;
      }

      if (difference < smallestDifference) {
        smallestDifference = difference;
        topRight = point;
      }

      if (difference > largestDifference) {
        largestDifference = difference;
        bottomLeft = point;
      }
    }

    if (topLeft == null ||
        topRight == null ||
        bottomRight == null ||
        bottomLeft == null) {
      throw Exception('Unable to order document corners.');
    }

    return <_Point>[topLeft, topRight, bottomRight, bottomLeft];
  }

  static double _quadrilateralArea(List<_Point> points) {
    double total = 0.0;

    for (int i = 0; i < points.length; i++) {
      final _Point current = points[i];

      final _Point next = points[(i + 1) % points.length];

      total += current.x * next.y - next.x * current.y;
    }

    return total.abs() / 2.0;
  }

  static double _distance(_Point a, _Point b) {
    final double dx = b.x - a.x;
    final double dy = b.y - a.y;

    return math.sqrt(dx * dx + dy * dy);
  }
}

class _Point {
  final double x;
  final double y;

  const _Point(this.x, this.y);
}

class _DocumentCandidate {
  final List<_Point> corners;
  final double score;
  final double areaRatio;

  const _DocumentCandidate({
    required this.corners,
    required this.score,
    required this.areaRatio,
  });
}
