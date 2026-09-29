import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

class RegistrationPoint {
  final double x;
  final double y;

  const RegistrationPoint({required this.x, required this.y});
}

class AnswerSheetProcessingResult {
  final Uint8List originalImageBytes;
  final Uint8List correctedImageBytes;
  final List<RegistrationPoint> markers;

  AnswerSheetProcessingResult({
    required this.originalImageBytes,
    required this.correctedImageBytes,
    required this.markers,
  });
}

class AnswerSheetProcessor {
  // ---------------------------------------------------------------------------
  // GENERATED SHEET GEOMETRY
  // ---------------------------------------------------------------------------

  static const double _pageWidth = 397.0;
  static const double _pageHeight = 559.0;

  /*
   * PDF registration markers:
   *
   * marker inset = 2
   * marker size  = 10
   *
   * marker center = 2 + 5 = 7
   *
   * TL = (7, 7)
   * TR = (390, 7)
   * BR = (390, 552)
   * BL = (7, 552)
   */
  static const double _markerCenterInset = 7.0;

  // Normalized image size used by the OMR processor.
  static const int _correctedWidth = 1500;
  static const int _correctedHeight = 2129;

  /*
   * A slightly relaxed threshold helps detect markers under uneven lighting
   * without making normal printed outlines too competitive.
   */
  static const double _darkThreshold = 125.0;

  // ---------------------------------------------------------------------------
  // PUBLIC PROCESSOR
  // ---------------------------------------------------------------------------

  static Future<AnswerSheetProcessingResult> processAnswerSheet(
    Uint8List imageBytes,
  ) async {
    final img.Image? decoded = img.decodeImage(imageBytes);

    if (decoded == null) {
      throw Exception('Unable to decode the selected image.');
    }

    // Respect EXIF / phone orientation.
    final img.Image image = img.bakeOrientation(decoded);

    final List<RegistrationPoint> markers = _detectRegistrationMarkers(image);

    if (markers.length != 4) {
      throw Exception(
        'Four registration markers could not be detected. '
        'Please make sure the entire answer sheet is visible.',
      );
    }

    final img.Image corrected = _correctPerspective(image, markers);

    final Uint8List correctedBytes = Uint8List.fromList(
      img.encodePng(corrected),
    );

    return AnswerSheetProcessingResult(
      originalImageBytes: imageBytes,
      correctedImageBytes: correctedBytes,
      markers: markers,
    );
  }

  // ---------------------------------------------------------------------------
  // MARKER DETECTION
  // ---------------------------------------------------------------------------

  static List<RegistrationPoint> _detectRegistrationMarkers(img.Image image) {
    final int width = image.width;
    final int height = image.height;

    /*
     * Search reasonably large corner regions.
     *
     * This allows perspective / rotation while still keeping most answer
     * bubbles away from the candidate search areas.
     */
    final List<_CornerRegion> regions = <_CornerRegion>[
      _CornerRegion(
        name: 'Top Left',
        minX: 0,
        maxX: width * 0.40,
        minY: 0,
        maxY: height * 0.40,
        cornerX: 0,
        cornerY: 0,
      ),
      _CornerRegion(
        name: 'Top Right',
        minX: width * 0.60,
        maxX: width.toDouble(),
        minY: 0,
        maxY: height * 0.40,
        cornerX: width.toDouble(),
        cornerY: 0,
      ),
      _CornerRegion(
        name: 'Bottom Right',
        minX: width * 0.60,
        maxX: width.toDouble(),
        minY: height * 0.60,
        maxY: height.toDouble(),
        cornerX: width.toDouble(),
        cornerY: height.toDouble(),
      ),
      _CornerRegion(
        name: 'Bottom Left',
        minX: 0,
        maxX: width * 0.40,
        minY: height * 0.60,
        maxY: height.toDouble(),
        cornerX: 0,
        cornerY: height.toDouble(),
      ),
    ];

    final List<List<_MarkerCandidate>> candidatesByCorner =
        <List<_MarkerCandidate>>[];

    for (final _CornerRegion region in regions) {
      final List<_MarkerCandidate> candidates = _findCandidates(image, region);

      if (candidates.isEmpty) {
        throw Exception(
          '${region.name} registration marker could not be detected.',
        );
      }

      candidatesByCorner.add(candidates);
    }

    /*
     * Do not choose each corner independently.
     *
     * Select the four markers as a SET so their sizes and page geometry can
     * also be compared.
     */
    final _MarkerSet? bestSet = _selectBestMarkerSet(image, candidatesByCorner);

    if (bestSet == null) {
      throw Exception(
        'The four registration markers could not be matched reliably. '
        'Please make sure the entire answer sheet is visible.',
      );
    }

    return <RegistrationPoint>[
      RegistrationPoint(x: bestSet.topLeft.centerX, y: bestSet.topLeft.centerY),
      RegistrationPoint(
        x: bestSet.topRight.centerX,
        y: bestSet.topRight.centerY,
      ),
      RegistrationPoint(
        x: bestSet.bottomRight.centerX,
        y: bestSet.bottomRight.centerY,
      ),
      RegistrationPoint(
        x: bestSet.bottomLeft.centerX,
        y: bestSet.bottomLeft.centerY,
      ),
    ];
  }

  static List<_MarkerCandidate> _findCandidates(
    img.Image image,
    _CornerRegion region,
  ) {
    final int minX = math.max(0, region.minX.floor());

    final int maxX = math.min(image.width - 1, region.maxX.ceil());

    final int minY = math.max(0, region.minY.floor());

    final int maxY = math.min(image.height - 1, region.maxY.ceil());

    final Set<int> visited = <int>{};

    final List<_MarkerCandidate> candidates = <_MarkerCandidate>[];

    for (int y = minY; y <= maxY; y++) {
      for (int x = minX; x <= maxX; x++) {
        final int key = y * image.width + x;

        if (visited.contains(key)) {
          continue;
        }

        if (!_isDark(image, x, y)) {
          continue;
        }

        final _Component component = _floodFill(
          image,
          x,
          y,
          minX,
          maxX,
          minY,
          maxY,
          visited,
        );

        /*
         * Ignore tiny image noise.
         */
        if (component.area < 20) {
          continue;
        }

        /*
         * Ignore extremely large connected regions.
         */
        if (component.area > 100000) {
          continue;
        }

        final double componentWidth = component.maxX - component.minX + 1.0;

        final double componentHeight = component.maxY - component.minY + 1.0;

        if (componentWidth < 3 || componentHeight < 3) {
          continue;
        }

        final double aspectRatio = componentWidth / componentHeight;

        /*
         * Registration markers are square, but photographed squares may be
         * distorted by perspective.
         */
        if (aspectRatio < 0.50 || aspectRatio > 2.00) {
          continue;
        }

        final double boundingArea = componentWidth * componentHeight;

        final double fillRatio = component.area / boundingArea;

        /*
         * Marker is filled black.
         *
         * 0.40 is deliberately tolerant of blur and lighting.
         */
        if (fillRatio < 0.40) {
          continue;
        }

        final double centerX = (component.minX + component.maxX) / 2.0;

        final double centerY = (component.minY + component.maxY) / 2.0;

        final double distanceToCorner = _distance(
          centerX,
          centerY,
          region.cornerX,
          region.cornerY,
        );

        candidates.add(
          _MarkerCandidate(
            centerX: centerX,
            centerY: centerY,
            area: component.area,
            width: componentWidth,
            height: componentHeight,
            fillRatio: fillRatio,
            distanceToCorner: distanceToCorner,
          ),
        );
      }
    }

    /*
     * Keep several possible markers.
     *
     * Final selection happens later using all four corners together.
     */
    candidates.sort((_MarkerCandidate a, _MarkerCandidate b) {
      return a.individualScore.compareTo(b.individualScore);
    });

    const int maxCandidates = 12;

    if (candidates.length > maxCandidates) {
      return candidates.take(maxCandidates).toList();
    }

    return candidates;
  }

  // ---------------------------------------------------------------------------
  // FOUR-MARKER SELECTION
  // ---------------------------------------------------------------------------

  static _MarkerSet? _selectBestMarkerSet(
    img.Image image,
    List<List<_MarkerCandidate>> candidates,
  ) {
    if (candidates.length != 4) {
      return null;
    }

    _MarkerSet? best;

    for (final _MarkerCandidate tl in candidates[0]) {
      for (final _MarkerCandidate tr in candidates[1]) {
        for (final _MarkerCandidate br in candidates[2]) {
          for (final _MarkerCandidate bl in candidates[3]) {
            final _MarkerSet set = _MarkerSet(
              topLeft: tl,
              topRight: tr,
              bottomRight: br,
              bottomLeft: bl,
            );

            if (!_isPlausibleMarkerSet(image, set)) {
              continue;
            }

            if (best == null || set.score < best.score) {
              best = set;
            }
          }
        }
      }
    }

    return best;
  }

  static bool _isPlausibleMarkerSet(img.Image image, _MarkerSet set) {
    // -----------------------------------------------------------------------
    // CORRECT CORNER ORDER
    // -----------------------------------------------------------------------

    if (set.topLeft.centerX >= set.topRight.centerX) {
      return false;
    }

    if (set.bottomLeft.centerX >= set.bottomRight.centerX) {
      return false;
    }

    if (set.topLeft.centerY >= set.bottomLeft.centerY) {
      return false;
    }

    if (set.topRight.centerY >= set.bottomRight.centerY) {
      return false;
    }

    // -----------------------------------------------------------------------
    // EDGE LENGTHS
    // -----------------------------------------------------------------------

    final double topWidth = _distance(
      set.topLeft.centerX,
      set.topLeft.centerY,
      set.topRight.centerX,
      set.topRight.centerY,
    );

    final double bottomWidth = _distance(
      set.bottomLeft.centerX,
      set.bottomLeft.centerY,
      set.bottomRight.centerX,
      set.bottomRight.centerY,
    );

    final double leftHeight = _distance(
      set.topLeft.centerX,
      set.topLeft.centerY,
      set.bottomLeft.centerX,
      set.bottomLeft.centerY,
    );

    final double rightHeight = _distance(
      set.topRight.centerX,
      set.topRight.centerY,
      set.bottomRight.centerX,
      set.bottomRight.centerY,
    );

    /*
     * The four markers should span a substantial portion of the photo.
     *
     * This prevents a small group of answer bubbles from being selected.
     */
    if (topWidth < image.width * 0.30) {
      return false;
    }

    if (bottomWidth < image.width * 0.30) {
      return false;
    }

    if (leftHeight < image.height * 0.30) {
      return false;
    }

    if (rightHeight < image.height * 0.30) {
      return false;
    }

    // -----------------------------------------------------------------------
    // PERSPECTIVE TOLERANCE
    // -----------------------------------------------------------------------

    final double horizontalRatio =
        math.max(topWidth, bottomWidth) / math.min(topWidth, bottomWidth);

    final double verticalRatio =
        math.max(leftHeight, rightHeight) / math.min(leftHeight, rightHeight);

    if (horizontalRatio > 2.25) {
      return false;
    }

    if (verticalRatio > 2.25) {
      return false;
    }

    // -----------------------------------------------------------------------
    // MARKER SIZE CONSISTENCY
    // -----------------------------------------------------------------------

    final List<double> sizes = <double>[
      set.topLeft.averageSize,
      set.topRight.averageSize,
      set.bottomRight.averageSize,
      set.bottomLeft.averageSize,
    ];

    final double smallest = sizes.reduce(math.min);

    final double largest = sizes.reduce(math.max);

    if (smallest <= 0) {
      return false;
    }

    /*
     * Fairly tolerant because perspective can make markers closer to the
     * camera appear larger.
     */
    if (largest / smallest > 2.5) {
      return false;
    }

    // -----------------------------------------------------------------------
    // QUADRILATERAL AREA
    // -----------------------------------------------------------------------

    final double pageArea = _quadrilateralArea(
      set.topLeft,
      set.topRight,
      set.bottomRight,
      set.bottomLeft,
    );

    final double imageArea = image.width.toDouble() * image.height.toDouble();

    /*
     * The selected markers should surround a meaningful portion of the image.
     */
    if (pageArea < imageArea * 0.15) {
      return false;
    }

    return true;
  }

  static double _quadrilateralArea(
    _MarkerCandidate tl,
    _MarkerCandidate tr,
    _MarkerCandidate br,
    _MarkerCandidate bl,
  ) {
    final List<_Point2D> points = <_Point2D>[
      _Point2D(tl.centerX, tl.centerY),
      _Point2D(tr.centerX, tr.centerY),
      _Point2D(br.centerX, br.centerY),
      _Point2D(bl.centerX, bl.centerY),
    ];

    double sum = 0.0;

    for (int i = 0; i < points.length; i++) {
      final _Point2D current = points[i];

      final _Point2D next = points[(i + 1) % points.length];

      sum += current.x * next.y - next.x * current.y;
    }

    return sum.abs() / 2.0;
  }

  // ---------------------------------------------------------------------------
  // DARK PIXEL CHECK
  // ---------------------------------------------------------------------------

  static bool _isDark(img.Image image, int x, int y) {
    final img.Pixel pixel = image.getPixel(x, y);

    final double luminance =
        (0.299 * pixel.r) + (0.587 * pixel.g) + (0.114 * pixel.b);

    return luminance < _darkThreshold;
  }

  // ---------------------------------------------------------------------------
  // FLOOD FILL
  // ---------------------------------------------------------------------------

  static _Component _floodFill(
    img.Image image,
    int startX,
    int startY,
    int minX,
    int maxX,
    int minY,
    int maxY,
    Set<int> visited,
  ) {
    final List<_PixelPoint> queue = <_PixelPoint>[_PixelPoint(startX, startY)];

    visited.add(startY * image.width + startX);

    int area = 0;

    int componentMinX = startX;
    int componentMaxX = startX;

    int componentMinY = startY;
    int componentMaxY = startY;

    int queueIndex = 0;

    const int maxComponentPixels = 200000;

    while (queueIndex < queue.length) {
      final _PixelPoint point = queue[queueIndex++];

      area++;

      componentMinX = math.min(componentMinX, point.x);

      componentMaxX = math.max(componentMaxX, point.x);

      componentMinY = math.min(componentMinY, point.y);

      componentMaxY = math.max(componentMaxY, point.y);

      if (area >= maxComponentPixels) {
        break;
      }

      final List<_PixelPoint> neighbors = <_PixelPoint>[
        _PixelPoint(point.x + 1, point.y),
        _PixelPoint(point.x - 1, point.y),
        _PixelPoint(point.x, point.y + 1),
        _PixelPoint(point.x, point.y - 1),
      ];

      for (final _PixelPoint neighbor in neighbors) {
        if (neighbor.x < minX ||
            neighbor.x > maxX ||
            neighbor.y < minY ||
            neighbor.y > maxY) {
          continue;
        }

        final int key = neighbor.y * image.width + neighbor.x;

        if (visited.contains(key)) {
          continue;
        }

        if (!_isDark(image, neighbor.x, neighbor.y)) {
          continue;
        }

        visited.add(key);
        queue.add(neighbor);
      }
    }

    return _Component(
      area: area,
      minX: componentMinX,
      maxX: componentMaxX,
      minY: componentMinY,
      maxY: componentMaxY,
    );
  }

  // ---------------------------------------------------------------------------
  // PERSPECTIVE CORRECTION
  // ---------------------------------------------------------------------------

  static img.Image _correctPerspective(
    img.Image image,
    List<RegistrationPoint> markers,
  ) {
    if (markers.length != 4) {
      throw Exception('Perspective correction requires exactly four markers.');
    }

    final RegistrationPoint topLeft = markers[0];
    final RegistrationPoint topRight = markers[1];
    final RegistrationPoint bottomRight = markers[2];
    final RegistrationPoint bottomLeft = markers[3];

    /*
     * The marker centers are known points in the generated 397 x 559 page:
     *
     * TL = (7, 7)
     * TR = (390, 7)
     * BR = (390, 552)
     * BL = (7, 552)
     *
     * Solve the projective transform from LOGICAL PAGE coordinates to the
     * photographed marker coordinates. Then use the inverse mapping for every
     * output pixel. This lets the same transform extrapolate from the marker
     * centers all the way to the true logical page edges (0..397, 0..559).
     *
     * Unlike the previous implementation, this does not rectify only the
     * marker-to-marker rectangle and paste it into white margins.
     */

    final List<_Point2D> logicalMarkerCenters = <_Point2D>[
      const _Point2D(_markerCenterInset, _markerCenterInset),
      const _Point2D(_pageWidth - _markerCenterInset, _markerCenterInset),
      const _Point2D(
        _pageWidth - _markerCenterInset,
        _pageHeight - _markerCenterInset,
      ),
      const _Point2D(_markerCenterInset, _pageHeight - _markerCenterInset),
    ];

    final List<_Point2D> photographedMarkerCenters = <_Point2D>[
      _Point2D(topLeft.x, topLeft.y),
      _Point2D(topRight.x, topRight.y),
      _Point2D(bottomRight.x, bottomRight.y),
      _Point2D(bottomLeft.x, bottomLeft.y),
    ];

    // Maps logical page coordinates -> photographed image coordinates.
    // That is exactly the direction needed for inverse-mapped raster sampling:
    // for each normalized output pixel, find the corresponding source pixel.
    final List<double> logicalToPhoto = _solveHomography(
      logicalMarkerCenters,
      photographedMarkerCenters,
    );

    final img.Image normalized = img.Image(
      width: _correctedWidth,
      height: _correctedHeight,
    );

    img.fill(normalized, color: img.ColorRgb8(255, 255, 255));

    final double outputScaleX = _pageWidth / _correctedWidth;
    final double outputScaleY = _pageHeight / _correctedHeight;

    for (int y = 0; y < _correctedHeight; y++) {
      final double logicalY = (y + 0.5) * outputScaleY;

      for (int x = 0; x < _correctedWidth; x++) {
        final double logicalX = (x + 0.5) * outputScaleX;

        final _Point2D sourcePoint = _applyHomography(
          logicalToPhoto,
          _Point2D(logicalX, logicalY),
        );

        final double sx = sourcePoint.x;
        final double sy = sourcePoint.y;

        if (sx < 0 ||
            sy < 0 ||
            sx >= image.width - 1 ||
            sy >= image.height - 1) {
          continue;
        }

        final int x0 = sx.floor();
        final int y0 = sy.floor();
        final int x1 = x0 + 1;
        final int y1 = y0 + 1;

        final double dx = sx - x0;
        final double dy = sy - y0;

        final img.Pixel p00 = image.getPixel(x0, y0);
        final img.Pixel p10 = image.getPixel(x1, y0);
        final img.Pixel p01 = image.getPixel(x0, y1);
        final img.Pixel p11 = image.getPixel(x1, y1);

        final int r = _bilinearChannel(
          p00.r.toDouble(),
          p10.r.toDouble(),
          p01.r.toDouble(),
          p11.r.toDouble(),
          dx,
          dy,
        );

        final int g = _bilinearChannel(
          p00.g.toDouble(),
          p10.g.toDouble(),
          p01.g.toDouble(),
          p11.g.toDouble(),
          dx,
          dy,
        );

        final int b = _bilinearChannel(
          p00.b.toDouble(),
          p10.b.toDouble(),
          p01.b.toDouble(),
          p11.b.toDouble(),
          dx,
          dy,
        );

        normalized.setPixelRgb(x, y, r, g, b);
      }
    }

    return normalized;
  }

  static int _bilinearChannel(
    double p00,
    double p10,
    double p01,
    double p11,
    double dx,
    double dy,
  ) {
    final double top = p00 + ((p10 - p00) * dx);
    final double bottom = p01 + ((p11 - p01) * dx);
    final double value = top + ((bottom - top) * dy);

    return value.round().clamp(0, 255).toInt();
  }

  // ---------------------------------------------------------------------------
  // HOMOGRAPHY
  // ---------------------------------------------------------------------------

  static List<double> _solveHomography(
    List<_Point2D> source,
    List<_Point2D> destination,
  ) {
    if (source.length != 4 || destination.length != 4) {
      throw Exception('Homography requires exactly four point pairs.');
    }

    final List<List<double>> matrix = List<List<double>>.generate(
      8,
      (_) => List<double>.filled(9, 0),
    );

    for (int i = 0; i < 4; i++) {
      final double x = source[i].x;
      final double y = source[i].y;

      final double u = destination[i].x;
      final double v = destination[i].y;

      final int row1 = i * 2;
      final int row2 = row1 + 1;

      matrix[row1][0] = x;
      matrix[row1][1] = y;
      matrix[row1][2] = 1;

      matrix[row1][3] = 0;
      matrix[row1][4] = 0;
      matrix[row1][5] = 0;

      matrix[row1][6] = -u * x;
      matrix[row1][7] = -u * y;
      matrix[row1][8] = u;

      matrix[row2][0] = 0;
      matrix[row2][1] = 0;
      matrix[row2][2] = 0;

      matrix[row2][3] = x;
      matrix[row2][4] = y;
      matrix[row2][5] = 1;

      matrix[row2][6] = -v * x;
      matrix[row2][7] = -v * y;
      matrix[row2][8] = v;
    }

    for (int column = 0; column < 8; column++) {
      int pivot = column;

      for (int row = column + 1; row < 8; row++) {
        if (matrix[row][column].abs() > matrix[pivot][column].abs()) {
          pivot = row;
        }
      }

      if (matrix[pivot][column].abs() < 1e-12) {
        throw Exception('Unable to calculate perspective transform.');
      }

      if (pivot != column) {
        final List<double> temp = matrix[column];

        matrix[column] = matrix[pivot];
        matrix[pivot] = temp;
      }

      final double divisor = matrix[column][column];

      for (int j = column; j < 9; j++) {
        matrix[column][j] /= divisor;
      }

      for (int row = 0; row < 8; row++) {
        if (row == column) {
          continue;
        }

        final double factor = matrix[row][column];

        if (factor.abs() < 1e-15) {
          continue;
        }

        for (int j = column; j < 9; j++) {
          matrix[row][j] -= factor * matrix[column][j];
        }
      }
    }

    return <double>[
      matrix[0][8],
      matrix[1][8],
      matrix[2][8],
      matrix[3][8],
      matrix[4][8],
      matrix[5][8],
      matrix[6][8],
      matrix[7][8],
      1.0,
    ];
  }

  static List<double> _invertHomography(List<double> h) {
    final double a = h[0];
    final double b = h[1];
    final double c = h[2];

    final double d = h[3];
    final double e = h[4];
    final double f = h[5];

    final double g = h[6];
    final double k = h[7];
    final double l = h[8];

    final double determinant =
        a * (e * l - f * k) - b * (d * l - f * g) + c * (d * k - e * g);

    if (determinant.abs() < 1e-12) {
      throw Exception('Perspective transform cannot be inverted.');
    }

    return <double>[
      (e * l - f * k) / determinant,
      (c * k - b * l) / determinant,
      (b * f - c * e) / determinant,

      (f * g - d * l) / determinant,
      (a * l - c * g) / determinant,
      (c * d - a * f) / determinant,

      (d * k - e * g) / determinant,
      (b * g - a * k) / determinant,
      (a * e - b * d) / determinant,
    ];
  }

  static _Point2D _applyHomography(List<double> h, _Point2D point) {
    final double denominator = h[6] * point.x + h[7] * point.y + h[8];

    if (denominator.abs() < 1e-12) {
      throw Exception('Invalid perspective transform.');
    }

    final double x = (h[0] * point.x + h[1] * point.y + h[2]) / denominator;

    final double y = (h[3] * point.x + h[4] * point.y + h[5]) / denominator;

    return _Point2D(x, y);
  }

  // ---------------------------------------------------------------------------
  // HELPERS
  // ---------------------------------------------------------------------------

  static double _distance(double x1, double y1, double x2, double y2) {
    final double dx = x2 - x1;
    final double dy = y2 - y1;

    return math.sqrt(dx * dx + dy * dy);
  }
}

// -----------------------------------------------------------------------------
// SUPPORT CLASSES
// -----------------------------------------------------------------------------

class _Point2D {
  final double x;
  final double y;

  const _Point2D(this.x, this.y);
}

class _PixelPoint {
  final int x;
  final int y;

  const _PixelPoint(this.x, this.y);
}

class _CornerRegion {
  final String name;

  final double minX;
  final double maxX;

  final double minY;
  final double maxY;

  final double cornerX;
  final double cornerY;

  const _CornerRegion({
    required this.name,
    required this.minX,
    required this.maxX,
    required this.minY,
    required this.maxY,
    required this.cornerX,
    required this.cornerY,
  });
}

class _MarkerCandidate {
  final double centerX;
  final double centerY;

  final int area;

  final double width;
  final double height;

  final double fillRatio;

  final double distanceToCorner;

  const _MarkerCandidate({
    required this.centerX,
    required this.centerY,
    required this.area,
    required this.width,
    required this.height,
    required this.fillRatio,
    required this.distanceToCorner,
  });

  double get averageSize => (width + height) / 2.0;

  double get individualScore {
    /*
     * Prefer:
     *
     * - objects near the appropriate image corner
     * - square objects
     * - strongly filled objects
     */
    final double squarePenalty = (width - height).abs() * 2.0;

    final double fillPenalty = (1.0 - fillRatio) * 80.0;

    return distanceToCorner + squarePenalty + fillPenalty;
  }
}

class _MarkerSet {
  final _MarkerCandidate topLeft;
  final _MarkerCandidate topRight;
  final _MarkerCandidate bottomRight;
  final _MarkerCandidate bottomLeft;

  const _MarkerSet({
    required this.topLeft,
    required this.topRight,
    required this.bottomRight,
    required this.bottomLeft,
  });

  double get score {
    final List<_MarkerCandidate> markers = <_MarkerCandidate>[
      topLeft,
      topRight,
      bottomRight,
      bottomLeft,
    ];

    double total = 0.0;

    // Individual candidate quality.
    for (final _MarkerCandidate marker in markers) {
      total += marker.individualScore;
    }

    // -----------------------------------------------------------------------
    // SIZE CONSISTENCY
    // -----------------------------------------------------------------------

    final double averageSize =
        markers.fold<double>(
          0.0,
          (double sum, _MarkerCandidate marker) => sum + marker.averageSize,
        ) /
        markers.length;

    if (averageSize > 0) {
      for (final _MarkerCandidate marker in markers) {
        final double relativeDifference =
            (marker.averageSize - averageSize).abs() / averageSize;

        total += relativeDifference * 300.0;
      }
    }

    // -----------------------------------------------------------------------
    // FILL CONSISTENCY
    // -----------------------------------------------------------------------

    final double averageFill =
        markers.fold<double>(
          0.0,
          (double sum, _MarkerCandidate marker) => sum + marker.fillRatio,
        ) /
        markers.length;

    for (final _MarkerCandidate marker in markers) {
      total += (marker.fillRatio - averageFill).abs() * 100.0;
    }

    return total;
  }
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
