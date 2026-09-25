import 'dart:math' as math;
import 'dart:typed_data';

import 'package:opencv_dart/opencv_dart.dart' as cv;

import 'answer_sheet_layout.dart';

class OpenCVBubbleMeasurement {
  final String label;
  final double fillRatio;

  const OpenCVBubbleMeasurement({required this.label, required this.fillRatio});
}

class OpenCVQuestionMeasurement {
  final int questionNumber;
  final List<OpenCVBubbleMeasurement> bubbles;

  const OpenCVQuestionMeasurement({
    required this.questionNumber,
    required this.bubbles,
  });
}

class OpenCVSectionMeasurement {
  final String sectionName;
  final String sectionType;
  final List<OpenCVQuestionMeasurement> questions;

  const OpenCVSectionMeasurement({
    required this.sectionName,
    required this.sectionType,
    required this.questions,
  });
}

class OpenCVOMRResult {
  final List<OpenCVSectionMeasurement> sections;
  final Uint8List? debugImageBytes;

  const OpenCVOMRResult({
    required this.sections,
    required this.debugImageBytes,
  });
}

class OpenCVOMRService {
  static const double _sheetWidth = AnswerSheetLayout.sheetWidth;
  static const double _sheetHeight = AnswerSheetLayout.sheetHeight;
  static const double _sheetPadding = AnswerSheetLayout.sheetPadding;
  static const double _bubbleSize = AnswerSheetLayout.bubbleSize;
  static const double _answerOptionWidth = AnswerSheetLayout.answerOptionWidth;
  static const double _questionNumberWidth =
      AnswerSheetLayout.questionNumberWidth;
  static const double _omrRowHeight = AnswerSheetLayout.omrRowHeight;
  static const double _identificationBoxHeight =
      AnswerSheetLayout.identificationBoxHeight;
  static const double _identificationRowSpacing =
      AnswerSheetLayout.identificationRowSpacing;
  static const double _sectionTitleHeight =
      AnswerSheetLayout.sectionTitleHeight;
  static const double _sectionSpacing = AnswerSheetLayout.sectionSpacing;

  // Content starts at sheet padding 10. The generator's header/student block
  // consumes 97 units before section content begins.
  static const double _firstSectionY = AnswerSheetLayout.firstSectionY;
  static const double _innerRadiusRatio = 0.30;
  // Bubble centers are detected from the printed circles themselves.
  // The template supplies only the expected neighborhood and question mapping.
  static const double _candidateMinDiameterRatio = 0.55;
  static const double _candidateMaxDiameterRatio = 1.55;
  static const double _candidateMinCircularity = 0.30;
  // Keep contour localization very close to the template coordinate.
  // A bubble must never jump to a neighboring row or option.
  static const double _candidateMaxDxLogical = 3.5;
  static const double _candidateMaxDyLogical = 3.5;

  // Section alignment uses ONLY the first real bubble row as an anchor.
  // This avoids the one-row ambiguity of matching the entire repeating grid.
  static const double _firstRowSearchUpLogical = 6.0;
  static const double _firstRowSearchDownLogical = 22.0;
  static const double _firstRowSearchStepLogical = 0.5;
  static const double _firstRowMatchRadiusLogical = 3.0;

  static OpenCVOMRResult process(
    Uint8List correctedImageBytes, {
    required List<Map<String, dynamic>> sections,
  }) {
    final cv.Mat source = cv.imdecode(correctedImageBytes, cv.IMREAD_COLOR);
    if (source.isEmpty) {
      source.dispose();
      throw Exception('OpenCV could not decode the corrected answer sheet.');
    }

    cv.Mat? gray;
    cv.Mat? blurred;
    cv.Mat? thresholded;
    cv.Mat? debug;

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
      debug = source.clone();

      final double scaleX = source.cols.toDouble() / _sheetWidth;
      final double scaleY = source.rows.toDouble() / _sheetHeight;

      // Detect printed bubble contours once for the whole corrected page.
      // This prevents the OMR reader from drifting onto section borders/text.
      final bubbleCandidates = _detectBubbleCandidates(
        thresholded,
        scaleX: scaleX,
        scaleY: scaleY,
      );

      final results = <OpenCVSectionMeasurement>[];
      double currentY = _firstSectionY;

      for (final section in sections) {
        final type = _normalizeType(
          section['question_type'] ?? section['type'],
        );
        final questions = _extractQuestions(section);
        if (questions.isEmpty) continue;

        final sectionName =
            section['display_name']?.toString() ??
            section['section_name']?.toString() ??
            section['name']?.toString() ??
            'Section';

        if (type == 'identification') {
          results.add(
            OpenCVSectionMeasurement(
              sectionName: sectionName,
              sectionType: type,
              questions: const [],
            ),
          );
          currentY +=
              _sectionTitleHeight +
              AnswerSheetLayout.sectionTitleGap +
              questions.length *
                  (_identificationBoxHeight + _identificationRowSpacing) +
              _sectionSpacing;
          continue;
        }

        if (type != 'multiple_choice' && type != 'true_false') {
          currentY += 30.0;
          continue;
        }

        final labels = type == 'multiple_choice'
            ? const ['A', 'B', 'C', 'D']
            : const ['T', 'F'];
        final columns = AnswerSheetLayout.calculateOmrColumns(questions.length);
        final questionsPerColumn = (questions.length / columns).ceil();
        final columnWidth =
            _questionNumberWidth + labels.length * _answerOptionWidth;
        final actualColumns = math.min(
          columns,
          (questions.length / questionsPerColumn).ceil(),
        );
        final totalBlockWidth = columnWidth * actualColumns;
        final contentWidth = _sheetWidth - (_sheetPadding * 2);
        final blockLeft =
            _sheetPadding + ((contentWidth - totalBlockWidth) / 2.0);

        // _buildSection: title 18 + explicit 3-unit gap before the OMR grid.
        final gridTop =
            currentY + _sectionTitleHeight + AnswerSheetLayout.sectionTitleGap;
        // Both MC and True/False start immediately below the section title
        // and its explicit 3-unit gap. Do not add an extra MC row here.
        final measurementGridTop = gridTop;

        // Anchor the section using only the first physical bubble row.
        // On a well-aligned photo this returns ~0. On photos where the
        // corrected bubble block sits lower, it can recover roughly one row
        // without accidentally mapping Q1 to Q2.
        final sectionDyLogical = _findFirstRowVerticalOffset(
          bubbleCandidates,
          labelsCount: labels.length,
          actualColumns: actualColumns,
          columnWidth: columnWidth,
          blockLeft: blockLeft,
          measurementGridTop: measurementGridTop,
          scaleX: scaleX,
          scaleY: scaleY,
        );

        final measuredQuestions = <OpenCVQuestionMeasurement>[];

        for (int i = 0; i < questions.length; i++) {
          final columnIndex = i ~/ questionsPerColumn;
          final rowIndex = i % questionsPerColumn;
          final question = questions[i];
          final questionNumber =
              int.tryParse(question['question_number']?.toString() ?? '') ??
              (i + 1);
          final columnLeft = blockLeft + columnIndex * columnWidth;
          final rowTop = measurementGridTop + rowIndex * _omrRowHeight;
          final bubbles = <OpenCVBubbleMeasurement>[];

          for (
            int optionIndex = 0;
            optionIndex < labels.length;
            optionIndex++
          ) {
            final logicalCenterX =
                columnLeft +
                _questionNumberWidth +
                optionIndex * _answerOptionWidth +
                (_answerOptionWidth / 2.0);
            final logicalCenterY =
                rowTop + (_bubbleSize / 2.0) + sectionDyLogical;
            final pixelCenterX = (logicalCenterX * scaleX).round();
            final pixelCenterY = (logicalCenterY * scaleY).round();
            final radiusX = (_bubbleSize / 2.0) * scaleX * _innerRadiusRatio;
            final radiusY = (_bubbleSize / 2.0) * scaleY * _innerRadiusRatio;

            final detected = _nearestBubbleCandidate(
              bubbleCandidates,
              expectedX: pixelCenterX,
              expectedY: pixelCenterY,
              scaleX: scaleX,
              scaleY: scaleY,
            );

            // Use the nearby printed contour only as a small positional
            // correction. Mark strength itself is measured from grayscale,
            // not from the threshold image. This prevents threshold failures
            // from turning clearly filled bubbles into 0.000.
            final measuredCenterX = detected?.centerX ?? pixelCenterX;
            final measuredCenterY = detected?.centerY ?? pixelCenterY;
            final fillRatio = _measureInnerGrayscaleDarkness(
              gray,
              centerX: measuredCenterX,
              centerY: measuredCenterY,
              radiusX: radiusX,
              radiusY: radiusY,
            );
            bubbles.add(
              OpenCVBubbleMeasurement(
                label: labels[optionIndex],
                fillRatio: fillRatio,
              ),
            );

            final debugRadius = math.max(
              3,
              math
                  .min(
                    (_bubbleSize / 2.0) * scaleX,
                    (_bubbleSize / 2.0) * scaleY,
                  )
                  .round(),
            );
            final cv.Point centerPoint = cv.Point(
              measuredCenterX,
              measuredCenterY,
            );

            cv.circle(
              debug,
              centerPoint,
              debugRadius,
              cv.Scalar(0, 0, 255, 0),
              thickness: 2,
            );

            cv.circle(
              debug,
              centerPoint,
              2,
              cv.Scalar(255, 0, 0, 0),
              thickness: -1,
            );
          }

          measuredQuestions.add(
            OpenCVQuestionMeasurement(
              questionNumber: questionNumber,
              bubbles: bubbles,
            ),
          );
        }

        results.add(
          OpenCVSectionMeasurement(
            sectionName: sectionName,
            sectionType: type,
            questions: measuredQuestions,
          ),
        );

        final rows = (questions.length / columns).ceil();
        // Mirrors _buildSection: title + 3 gap + rows + section spacing.
        currentY +=
            _sectionTitleHeight +
            AnswerSheetLayout.sectionTitleGap +
            rows * _omrRowHeight +
            _sectionSpacing;
      }

      final (bool success, Uint8List encoded) = cv.imencode('.png', debug);
      return OpenCVOMRResult(
        sections: results,
        debugImageBytes: success ? encoded : null,
      );
    } finally {
      debug?.dispose();
      thresholded?.dispose();
      blurred?.dispose();
      gray?.dispose();
      source.dispose();
    }
  }

  static double _findFirstRowVerticalOffset(
    List<_BubbleCandidate> candidates, {
    required int labelsCount,
    required int actualColumns,
    required double columnWidth,
    required double blockLeft,
    required double measurementGridTop,
    required double scaleX,
    required double scaleY,
  }) {
    if (candidates.isEmpty) return 0.0;

    final expectedXs = <double>[];

    for (int columnIndex = 0; columnIndex < actualColumns; columnIndex++) {
      final columnLeft = blockLeft + columnIndex * columnWidth;

      for (int optionIndex = 0; optionIndex < labelsCount; optionIndex++) {
        final logicalX =
            columnLeft +
            _questionNumberWidth +
            optionIndex * _answerOptionWidth +
            (_answerOptionWidth / 2.0);
        expectedXs.add(logicalX * scaleX);
      }
    }

    final baseY = (measurementGridTop + (_bubbleSize / 2.0)) * scaleY;
    final toleranceX = math
        .max(2.0, _firstRowMatchRadiusLogical * scaleX)
        .toDouble();
    final toleranceY = math
        .max(2.0, _firstRowMatchRadiusLogical * scaleY)
        .toDouble();

    int bestMatches = -1;
    double bestQuality = -1.0;
    double bestDy = 0.0;

    for (
      double dy = -_firstRowSearchUpLogical;
      dy <= _firstRowSearchDownLogical + 0.001;
      dy += _firstRowSearchStepLogical
    ) {
      final targetY = baseY + (dy * scaleY);
      int matches = 0;
      double quality = 0.0;

      for (final expectedX in expectedXs) {
        double bestDistance = double.infinity;

        for (final candidate in candidates) {
          final dx = (candidate.centerX - expectedX).abs();
          final py = (candidate.centerY - targetY).abs();

          if (dx > toleranceX || py > toleranceY) continue;

          final nx = dx / toleranceX;
          final ny = py / toleranceY;
          final distance = (nx * nx) + (ny * ny);

          if (distance < bestDistance) {
            bestDistance = distance;
          }
        }

        if (bestDistance.isFinite) {
          matches++;
          quality += 1.0 - math.min(0.85, bestDistance * 0.35).toDouble();
        }
      }

      final better =
          matches > bestMatches ||
          (matches == bestMatches && quality > bestQuality + 0.000001) ||
          (matches == bestMatches &&
              (quality - bestQuality).abs() <= 0.000001 &&
              dy.abs() < bestDy.abs());

      if (better) {
        bestMatches = matches;
        bestQuality = quality;
        bestDy = dy;
      }
    }

    // Require enough evidence from the physical first row. If contour
    // detection is weak, leave the template position unchanged.
    final requiredMatches = math
        .max(1, (expectedXs.length * 0.50).ceil())
        .toInt();

    if (bestMatches < requiredMatches) {
      return 0.0;
    }

    return bestDy;
  }

  static List<_BubbleCandidate> _detectBubbleCandidates(
    cv.Mat thresholded, {
    required double scaleX,
    required double scaleY,
  }) {
    final candidates = <_BubbleCandidate>[];
    final (contours, hierarchy) = cv.findContours(
      thresholded,
      cv.RETR_LIST,
      cv.CHAIN_APPROX_SIMPLE,
    );

    try {
      final expectedW = _bubbleSize * scaleX;
      final expectedH = _bubbleSize * scaleY;
      final minW = expectedW * _candidateMinDiameterRatio;
      final maxW = expectedW * _candidateMaxDiameterRatio;
      final minH = expectedH * _candidateMinDiameterRatio;
      final maxH = expectedH * _candidateMaxDiameterRatio;

      for (final contour in contours) {
        if (contour.length < 5) continue;

        final rect = cv.boundingRect(contour);
        final w = rect.width.toDouble();
        final h = rect.height.toDouble();

        if (w < minW || w > maxW || h < minH || h > maxH) continue;

        final aspect = w / math.max(1.0, h);
        if (aspect < 0.65 || aspect > 1.45) continue;

        final area = cv.contourArea(contour).abs();
        final perimeter = cv.arcLength(contour, true);
        if (area <= 0 || perimeter <= 0) continue;

        final circularity = (4.0 * math.pi * area) / (perimeter * perimeter);
        if (circularity < _candidateMinCircularity) continue;

        candidates.add(
          _BubbleCandidate(
            centerX: rect.x + (rect.width / 2.0).round(),
            centerY: rect.y + (rect.height / 2.0).round(),
            width: rect.width,
            height: rect.height,
            circularity: circularity,
          ),
        );
      }
    } finally {
      contours.dispose();
      hierarchy.dispose();
    }

    return candidates;
  }

  static _BubbleCandidate? _nearestBubbleCandidate(
    List<_BubbleCandidate> candidates, {
    required int expectedX,
    required int expectedY,
    required double scaleX,
    required double scaleY,
  }) {
    final maxDx = _candidateMaxDxLogical * scaleX;
    final maxDy = _candidateMaxDyLogical * scaleY;

    _BubbleCandidate? best;
    double bestScore = double.infinity;

    for (final candidate in candidates) {
      final dx = (candidate.centerX - expectedX).abs().toDouble();
      final dy = (candidate.centerY - expectedY).abs().toDouble();
      if (dx > maxDx || dy > maxDy) continue;

      // Position dominates the match. A small circularity bonus breaks ties.
      final nx = dx / math.max(1.0, maxDx);
      final ny = dy / math.max(1.0, maxDy);
      final score =
          (nx * nx) +
          (ny * ny) -
          (candidate.circularity.clamp(0.0, 1.0) * 0.05);

      if (score < bestScore) {
        bestScore = score;
        best = candidate;
      }
    }

    return best;
  }

  static double _measureInnerGrayscaleDarkness(
    cv.Mat gray, {
    required int centerX,
    required int centerY,
    required double radiusX,
    required double radiusY,
  }) {
    final left = math.max(0, (centerX - radiusX).floor());
    final right = math.min(gray.cols - 1, (centerX + radiusX).ceil());
    final top = math.max(0, (centerY - radiusY).floor());
    final bottom = math.min(gray.rows - 1, (centerY + radiusY).ceil());
    if (right <= left || bottom <= top) return 0.0;

    int total = 0;
    double graySum = 0.0;

    for (int y = top; y <= bottom; y++) {
      final ny = (y - centerY) / radiusY;
      for (int x = left; x <= right; x++) {
        final nx = (x - centerX) / radiusX;
        if ((nx * nx) + (ny * ny) > 1.0) continue;

        final int value = gray.at<int>(y, x);
        graySum += value.toDouble();
        total++;
      }
    }

    if (total == 0) return 0.0;

    // 0.0 = white interior, 1.0 = black interior.
    // Because only the inner ~30% radius is sampled, the printed outline is
    // intentionally excluded from the score.
    final averageGray = graySum / total;
    return (1.0 - (averageGray / 255.0)).clamp(0.0, 1.0);
  }

  static List<Map<String, dynamic>> _extractQuestions(
    Map<String, dynamic> section,
  ) {
    final raw = section['questions'];
    if (raw is! List) return <Map<String, dynamic>>[];
    return raw
        .whereType<Map>()
        .map((q) => Map<String, dynamic>.from(q))
        .toList();
  }

  static String _normalizeType(dynamic value) {
    final type = value?.toString().trim().toLowerCase() ?? '';
    switch (type) {
      case 'multiple_choice':
      case 'multiple choice':
      case 'mc':
      case 'mcq':
        return 'multiple_choice';
      case 'true_false':
      case 'true or false':
      case 'true/false':
      case 'true_false_question':
      case 'tf':
        return 'true_false';
      case 'identification':
      case 'identify':
      case 'id':
        return 'identification';
      default:
        return type;
    }
  }
}

class _BubbleCandidate {
  final int centerX;
  final int centerY;
  final int width;
  final int height;
  final double circularity;

  const _BubbleCandidate({
    required this.centerX,
    required this.centerY,
    required this.width,
    required this.height,
    required this.circularity,
  });
}
