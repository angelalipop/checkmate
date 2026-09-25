import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

// ============================================================================
// PUBLIC RESULT MODELS
// ============================================================================

class OMRAnswer {
  final int questionNumber;
  final String answer;
  final double confidence;

  const OMRAnswer({
    required this.questionNumber,
    required this.answer,
    required this.confidence,
  });

  bool get isUnanswered => answer == 'Unanswered';
}

class OMRSectionResult {
  final String sectionName;
  final String sectionType;
  final int questionCount;
  final List<OMRAnswer> answers;

  const OMRSectionResult({
    required this.sectionName,
    required this.sectionType,
    required this.questionCount,
    required this.answers,
  });
}

class OMRProcessingResult {
  final List<OMRSectionResult> sections;
  final Uint8List? debugImageBytes;

  const OMRProcessingResult({required this.sections, this.debugImageBytes});

  int get detectedQuestions {
    return sections.fold(0, (total, section) => total + section.questionCount);
  }

  int get answeredQuestions {
    return sections.fold(0, (total, section) {
      return total +
          section.answers.where((answer) {
            return !answer.isUnanswered && answer.answer != 'OCR Pending';
          }).length;
    });
  }
}

// ============================================================================
// INTERNAL LAYOUT MODELS
// ============================================================================

class _ExpectedBubble {
  final double centerX;
  final double centerY;
  final String option;

  const _ExpectedBubble({
    required this.centerX,
    required this.centerY,
    required this.option,
  });
}

class _ExpectedQuestion {
  final int questionNumber;
  final List<_ExpectedBubble> bubbles;

  const _ExpectedQuestion({
    required this.questionNumber,
    required this.bubbles,
  });
}

class _ExpectedSection {
  final String name;
  final String type;
  final int questionCount;
  final List<_ExpectedQuestion> questions;

  const _ExpectedSection({
    required this.name,
    required this.type,
    required this.questionCount,
    required this.questions,
  });
}

class _BubbleMeasurement {
  final double darkness;
  final double darkPixelRatio;
  final double averageDarkness;

  // Locally normalized fill evidence.
  // These compare the bubble interior against nearby paper/background.
  final double localContrast;
  final double normalizedDarkPixelRatio;

  const _BubbleMeasurement({
    required this.darkness,
    required this.darkPixelRatio,
    required this.averageDarkness,
    this.localContrast = 0.0,
    this.normalizedDarkPixelRatio = 0.0,
  });
}

class _SectionRegistration {
  final double dx;
  final double dy;
  final double scaleX;
  final double scaleY;
  final double rotationRadians;
  final double pivotX;
  final double pivotY;

  const _SectionRegistration({
    required this.dx,
    required this.dy,
    required this.scaleX,
    required this.scaleY,
    required this.rotationRadians,
    required this.pivotX,
    required this.pivotY,
  });
}

class _RegistrationPivot {
  final double x;
  final double y;
  const _RegistrationPivot(this.x, this.y);
}

class _RegisteredPoint {
  final double x;
  final double y;
  const _RegisteredPoint(this.x, this.y);
}

// ============================================================================
// OMR PROCESSOR
// ============================================================================

class OMRProcessor {
  // ==========================================================================
  // ANSWER OPTIONS
  // ==========================================================================

  static const List<String> multipleChoiceOptions = <String>[
    'A',
    'B',
    'C',
    'D',
  ];

  static const List<String> trueFalseOptions = <String>['T', 'F'];

  // ==========================================================================
  // NORMALIZED IMAGE
  // ==========================================================================

  /*
   * These MUST match AnswerSheetProcessor.
   */
  static const int normalizedWidth = 1500;
  static const int normalizedHeight = 2129;

  /*
   * Original logical dimensions from AnswerSheetPdfService.
   */
  static const double sheetWidth = 397.0;
  static const double sheetHeight = 559.0;

  // ==========================================================================
  // PDF GEOMETRY
  // ==========================================================================

  static const double sheetPadding = 10.0;

  static const double bubbleSize = 11.0;

  static const double answerOptionWidth = 23.0;

  static const double questionNumberWidth = 17.0;

  static const int sectionRegistrationSearchRadius = 42;
  static const int sectionRegistrationStep = 2;
  static const int sectionRegistrationRefineRadius = 4;

  static const double omrRowHeight = 17.0;

  static const double sectionTitleHeight = 18.0;

  static const double sectionTitleBottomSpacing = 3.0;

  static const double sectionSpacing = 5.0;

  static const double identificationBoxHeight = 18.0;

  static const double identificationRowSpacing = 3.0;

  // ==========================================================================
  // HEADER GEOMETRY
  // ==========================================================================

  /*
   * AnswerSheetPdfService:
   *
   * sheet top padding = 10
   * header            = 45
   * gap               = 6
   * student row       = 16
   * gap               = 5
   * student row       = 16
   * gap               = 7
   *
   * First section title therefore begins at:
   *
   * 10 + 45 + 6 + 16 + 5 + 16 + 7 = 105
   */
  static const double headerHeight = 45.0;

  static const double headerBottomSpacing = 6.0;

  static const double studentRowHeight = 16.0;

  static const double studentRowSpacing = 5.0;

  static const double studentInfoBottomSpacing = 7.0;

  // ==========================================================================
  // OMR READING SETTINGS
  // ==========================================================================

  /*
   * We deliberately read only the INNER part of a bubble.
   *
   * The printed ring should remain mostly outside this sampling region.
   */
  static const double bubbleReadRadiusRatio = 0.20;

  /*
   * Pixels darker than this are considered strongly marked.
   */
  static const int darkPixelThreshold = 145;

  /*
   * Absolute minimum darkness needed before an option can be accepted.
   *
   * Blank bubble interiors should remain well below this.
   */
  static const double minimumBubbleDarkness = 0.30;

  /*
   * Require the winning bubble to contain a meaningful amount of genuinely
   * dark pixels.
   */
  static const double minimumDarkPixelRatio = 0.24;

  /*
   * Filled interiors must also be dark on average. This rejects isolated
   * outline/shadow pixels that can otherwise trigger an empty bubble.
   */
  static const double minimumAverageDarkness = 0.28;

  /*
   * Difference between darkest and second-darkest option.
   *
   * This is one of the strongest protections against blank-sheet false
   * positives.
   */
  static const double minimumDifference = 0.075;

  /*
   * If two bubbles are very close, do not guess.
   */
  static const double ambiguousDifference = 0.045;

  /*
   * Per-bubble alignment search is disabled.
   *
   * The complete section is aligned first. Individual bubbles must not wander
   * toward their printed outlines, because that can turn blank bubbles into
   * false answers.
   *
   * IMPORTANT:
   * This search is intentionally tiny. It is NOT a circle detector.
   */
  static const int localBubbleSearchRadius = 0;

  // Small local center refinement based on the printed circular ring.
  // This does NOT search for the darkest answer mark.
  static const int bubbleCenterRefineRadius = 5;

  // --------------------------------------------------------------------------
  // LOCAL BACKGROUND-NORMALIZED FILL DETECTION
  // --------------------------------------------------------------------------
  //
  // A blank printed bubble can still look dark because of:
  //   - the printed outline,
  //   - uneven lighting,
  //   - perspective interpolation,
  //   - shadows.
  //
  // Therefore an answer is accepted only when the INNER bubble region is
  // substantially darker than nearby paper around that same bubble.
  static const double minimumLocalContrast = 0.105;
  static const double minimumNormalizedDarkPixelRatio = 0.30;
  static const double minimumNormalizedDifference = 0.055;

  // Background is sampled outside the printed bubble ring.
  static const double backgroundInnerRadiusRatio = 0.72;
  static const double backgroundOuterRadiusRatio = 0.95;

  // ==========================================================================
  // MAIN PROCESS
  // ==========================================================================

  static Future<OMRProcessingResult> process(
    Uint8List imageBytes, {
    required List<Map<String, dynamic>> sections,
  }) async {
    final img.Image? decoded = img.decodeImage(imageBytes);

    if (decoded == null) {
      throw Exception('Unable to decode the corrected answer sheet image.');
    }

    /*
     * The perspective processor should already output 1500 x 2129.
     *
     * Resize anyway so the OMR coordinate system is always deterministic.
     */
    final img.Image image = img.copyResize(
      decoded,
      width: normalizedWidth,
      height: normalizedHeight,
      interpolation: img.Interpolation.linear,
    );

    final List<_ExpectedSection> expectedSections = _buildExpectedLayout(
      sections: sections,
    );

    final List<OMRSectionResult> results = <OMRSectionResult>[];

    for (final _ExpectedSection section in expectedSections) {
      // ----------------------------------------------------------------------
      // IDENTIFICATION
      // ----------------------------------------------------------------------

      if (section.type == 'identification') {
        results.add(
          OMRSectionResult(
            sectionName: section.name,
            sectionType: section.type,
            questionCount: section.questionCount,
            answers: List<OMRAnswer>.generate(section.questionCount, (
              int index,
            ) {
              return OMRAnswer(
                questionNumber: index + 1,
                answer: 'OCR Pending',
                confidence: 0,
              );
            }),
          ),
        );

        continue;
      }

      // ----------------------------------------------------------------------
      // SUPPORTED OMR TYPES
      // ----------------------------------------------------------------------

      if (section.type != 'multiple_choice' && section.type != 'true_false') {
        continue;
      }

      final _SectionRegistration registration = _registerSection(
        image: image,
        section: section,
      );

      final List<OMRAnswer> answers = <OMRAnswer>[];

      for (final _ExpectedQuestion question in section.questions) {
        answers.add(
          _readQuestion(
            image: image,
            question: question,
            registration: registration,
          ),
        );
      }

      results.add(
        OMRSectionResult(
          sectionName: section.name,
          sectionType: section.type,
          questionCount: section.questionCount,
          answers: answers,
        ),
      );
    }

    final Uint8List debugImageBytes = _buildDebugOverlay(
      image: image,
      expectedSections: expectedSections,
    );

    return OMRProcessingResult(
      sections: results,
      debugImageBytes: debugImageBytes,
    );
  }

  // ==========================================================================
  // DEBUG OVERLAY
  // ==========================================================================

  static Uint8List _buildDebugOverlay({
    required img.Image image,
    required List<_ExpectedSection> expectedSections,
  }) {
    final img.Image debug = img.Image.from(image);

    for (final _ExpectedSection section in expectedSections) {
      if (section.type != 'multiple_choice' && section.type != 'true_false') {
        continue;
      }

      final _SectionRegistration registration = _registerSection(
        image: image,
        section: section,
      );

      final img.Color expectedColor = img.ColorRgb8(255, 180, 0);
      final img.Color calibratedColor = section.type == 'multiple_choice'
          ? img.ColorRgb8(255, 0, 0)
          : img.ColorRgb8(0, 120, 255);

      for (final _ExpectedQuestion question in section.questions) {
        for (final _ExpectedBubble bubble in question.bubbles) {
          final int expectedX = _scaledX(bubble.centerX).round();
          final int expectedY = _scaledY(bubble.centerY).round();
          final _RegisteredPoint registeredPoint = _transformBubbleCenter(
            bubble: bubble,
            registration: registration,
          );
          final _RegisteredPoint refinedPoint = _refineBubbleCenterFromRing(
            image: image,
            expectedX: registeredPoint.x,
            expectedY: registeredPoint.y,
          );
          final int calibratedX = refinedPoint.x.round();
          final int calibratedY = refinedPoint.y.round();

          img.drawLine(
            debug,
            x1: expectedX - 3,
            y1: expectedY,
            x2: expectedX + 3,
            y2: expectedY,
            color: expectedColor,
          );
          img.drawLine(
            debug,
            x1: expectedX,
            y1: expectedY - 3,
            x2: expectedX,
            y2: expectedY + 3,
            color: expectedColor,
          );

          final int sampleRadius =
              (expectedNormalizedBubbleSize * bubbleReadRadiusRatio).round();
          img.drawCircle(
            debug,
            x: calibratedX,
            y: calibratedY,
            radius: math.max(3, sampleRadius),
            color: calibratedColor,
          );
          img.drawLine(
            debug,
            x1: calibratedX - 7,
            y1: calibratedY,
            x2: calibratedX + 7,
            y2: calibratedY,
            color: calibratedColor,
          );
          img.drawLine(
            debug,
            x1: calibratedX,
            y1: calibratedY - 7,
            x2: calibratedX,
            y2: calibratedY + 7,
            color: calibratedColor,
          );
        }
      }
    }

    return Uint8List.fromList(img.encodePng(debug));
  }

  // ==========================================================================
  // BUILD EXPECTED PDF LAYOUT
  // ==========================================================================

  static List<_ExpectedSection> _buildExpectedLayout({
    required List<Map<String, dynamic>> sections,
  }) {
    final List<_ExpectedSection> result = <_ExpectedSection>[];

    // ------------------------------------------------------------------------
    // TOP OF CONTENT
    // ------------------------------------------------------------------------

    double currentY = sheetPadding;

    currentY += headerHeight;

    currentY += headerBottomSpacing;

    currentY += studentRowHeight;

    currentY += studentRowSpacing;

    currentY += studentRowHeight;

    currentY += studentInfoBottomSpacing;

    // ------------------------------------------------------------------------
    // SECTIONS
    // ------------------------------------------------------------------------

    for (final Map<String, dynamic> section in sections) {
      final String name =
          section['name']?.toString() ??
          section['title']?.toString() ??
          section['section_name']?.toString() ??
          'Section';

      final String type = _normalizeType(
        section['question_type'] ?? section['type'],
      );

      final int questionCount = _getQuestionCount(section);

      if (questionCount <= 0) {
        continue;
      }

      // ----------------------------------------------------------------------
      // IDENTIFICATION
      // ----------------------------------------------------------------------

      if (type == 'identification') {
        result.add(
          _ExpectedSection(
            name: name,
            type: type,
            questionCount: questionCount,
            questions: const <_ExpectedQuestion>[],
          ),
        );

        currentY += sectionTitleHeight;

        currentY += sectionTitleBottomSpacing;

        currentY +=
            questionCount *
            (identificationBoxHeight + identificationRowSpacing);

        currentY += sectionSpacing;

        continue;
      }

      // ----------------------------------------------------------------------
      // OMR SECTION
      // ----------------------------------------------------------------------

      if (type != 'multiple_choice' && type != 'true_false') {
        continue;
      }

      final List<String> options = type == 'multiple_choice'
          ? multipleChoiceOptions
          : trueFalseOptions;

      /*
       * The title begins at currentY.
       *
       * The OMR grid begins after:
       *
       * title height = 18
       * spacing      = 3
       */
      final double gridStartY =
          currentY + sectionTitleHeight + sectionTitleBottomSpacing;

      final int columns = _calculateOmrColumns(questionCount);

      final int questionsPerColumn = (questionCount / columns).ceil();

      /*
       * Each OMR column:
       *
       * question number = 17
       * each answer cell = 23
       */
      final double columnWidth =
          questionNumberWidth + (options.length * answerOptionWidth);

      final double totalBlockWidth = columnWidth * columns;

      final double contentWidth = sheetWidth - (sheetPadding * 2);

      /*
       * AnswerSheetPdfService centers the complete OMR block.
       */
      final double blockStartX =
          sheetPadding + ((contentWidth - totalBlockWidth) / 2.0);

      final List<_ExpectedQuestion> questions = <_ExpectedQuestion>[];

      // ----------------------------------------------------------------------
      // COLUMNS
      // ----------------------------------------------------------------------

      for (int columnIndex = 0; columnIndex < columns; columnIndex++) {
        final int start = columnIndex * questionsPerColumn;

        if (start >= questionCount) {
          break;
        }

        final int end = math.min(start + questionsPerColumn, questionCount);

        final double columnStartX = blockStartX + (columnIndex * columnWidth);

        // --------------------------------------------------------------------
        // QUESTIONS IN THIS COLUMN
        // --------------------------------------------------------------------

        for (int questionIndex = start; questionIndex < end; questionIndex++) {
          final int rowIndex = questionIndex - start;

          final double rowTopY = gridStartY + (rowIndex * omrRowHeight);

          final List<_ExpectedBubble> bubbles = <_ExpectedBubble>[];

          // ------------------------------------------------------------------
          // ANSWER OPTIONS
          // ------------------------------------------------------------------

          for (
            int optionIndex = 0;
            optionIndex < options.length;
            optionIndex++
          ) {
            final double centerX =
                columnStartX +
                questionNumberWidth +
                (optionIndex * answerOptionWidth) +
                (answerOptionWidth / 2.0);

            /*
             * Vertically, the bubble is at the top of the 17-unit row.
             *
             * Therefore bubbleSize / 2 remains correct for Y.
             */
            final double centerY = rowTopY + (bubbleSize / 2.0);

            bubbles.add(
              _ExpectedBubble(
                centerX: centerX,
                centerY: centerY,
                option: options[optionIndex],
              ),
            );
          }

          questions.add(
            _ExpectedQuestion(
              questionNumber: questionIndex + 1,
              bubbles: bubbles,
            ),
          );
        }
      }

      /*
       * The PDF lays questions by column.
       *
       * Sort them back into normal numerical order for the result.
       */
      questions.sort((_ExpectedQuestion a, _ExpectedQuestion b) {
        return a.questionNumber.compareTo(b.questionNumber);
      });

      result.add(
        _ExpectedSection(
          name: name,
          type: type,
          questionCount: questionCount,
          questions: questions,
        ),
      );

      // ----------------------------------------------------------------------
      // ADVANCE Y TO NEXT SECTION
      // ----------------------------------------------------------------------

      final int rows = (questionCount / columns).ceil();

      currentY += sectionTitleHeight;

      currentY += sectionTitleBottomSpacing;

      currentY += rows * omrRowHeight;

      currentY += sectionSpacing;
    }

    return result;
  }

  // ==========================================================================
  // READ ONE QUESTION
  // ==========================================================================

  // ==========================================================================
  // SECTION-LEVEL OMR REGISTRATION
  // ==========================================================================

  static _SectionRegistration _registerSection({
    required img.Image image,
    required _ExpectedSection section,
  }) {
    /*
     * Robust section registration.
     *
     * A single dx/dy translation was not enough when teachers photographed
     * the same sheet from different angles. This version aligns each OMR
     * section with a small affine-like transform:
     *
     *   - translation X/Y
     *   - independent X/Y scale
     *   - small rotation
     *
     * The transform is fitted from the PRINTED BUBBLE RINGS, so it works on
     * both blank and answered sheets and does not depend on which answers are
     * filled.
     */

    final _RegistrationPivot pivot = _sectionPivot(section);

    _SectionRegistration best = _SectionRegistration(
      dx: 0,
      dy: 0,
      scaleX: 1,
      scaleY: 1,
      rotationRadians: 0,
      pivotX: pivot.x,
      pivotY: pivot.y,
    );

    double bestScore = double.negativeInfinity;

    // ------------------------------------------------------------
    // 1. Coarse translation search.
    // ------------------------------------------------------------
    for (
      int dy = -sectionRegistrationSearchRadius;
      dy <= sectionRegistrationSearchRadius;
      dy += sectionRegistrationStep
    ) {
      for (
        int dx = -sectionRegistrationSearchRadius;
        dx <= sectionRegistrationSearchRadius;
        dx += sectionRegistrationStep
      ) {
        final _SectionRegistration candidate = _SectionRegistration(
          dx: dx.toDouble(),
          dy: dy.toDouble(),
          scaleX: 1,
          scaleY: 1,
          rotationRadians: 0,
          pivotX: pivot.x,
          pivotY: pivot.y,
        );

        final double score = _sectionTransformScore(
          image: image,
          section: section,
          registration: candidate,
        );

        if (score > bestScore) {
          bestScore = score;
          best = candidate;
        }
      }
    }

    // ------------------------------------------------------------
    // 2. Fit X/Y scale.
    //    ±3% is intentionally small: enough for residual perspective
    //    differences without allowing the grid to jump to unrelated lines.
    // ------------------------------------------------------------
    for (double sx = 0.97; sx <= 1.0301; sx += 0.005) {
      for (double sy = 0.97; sy <= 1.0301; sy += 0.005) {
        final _SectionRegistration candidate = _SectionRegistration(
          dx: best.dx,
          dy: best.dy,
          scaleX: sx,
          scaleY: sy,
          rotationRadians: best.rotationRadians,
          pivotX: pivot.x,
          pivotY: pivot.y,
        );

        final double score = _sectionTransformScore(
          image: image,
          section: section,
          registration: candidate,
        );

        if (score > bestScore) {
          bestScore = score;
          best = candidate;
        }
      }
    }

    // ------------------------------------------------------------
    // 3. Fit small residual rotation.
    // ------------------------------------------------------------
    for (double degrees = -2.0; degrees <= 2.001; degrees += 0.25) {
      final double radians = degrees * math.pi / 180.0;

      final _SectionRegistration candidate = _SectionRegistration(
        dx: best.dx,
        dy: best.dy,
        scaleX: best.scaleX,
        scaleY: best.scaleY,
        rotationRadians: radians,
        pivotX: pivot.x,
        pivotY: pivot.y,
      );

      final double score = _sectionTransformScore(
        image: image,
        section: section,
        registration: candidate,
      );

      if (score > bestScore) {
        bestScore = score;
        best = candidate;
      }
    }

    // ------------------------------------------------------------
    // 4. Refine translation after scale/rotation were fitted.
    // ------------------------------------------------------------
    final int baseDx = best.dx.round();
    final int baseDy = best.dy.round();

    for (int dy = baseDy - 10; dy <= baseDy + 10; dy++) {
      for (int dx = baseDx - 10; dx <= baseDx + 10; dx++) {
        final _SectionRegistration candidate = _SectionRegistration(
          dx: dx.toDouble(),
          dy: dy.toDouble(),
          scaleX: best.scaleX,
          scaleY: best.scaleY,
          rotationRadians: best.rotationRadians,
          pivotX: pivot.x,
          pivotY: pivot.y,
        );

        final double score = _sectionTransformScore(
          image: image,
          section: section,
          registration: candidate,
        );

        if (score > bestScore) {
          bestScore = score;
          best = candidate;
        }
      }
    }

    return best;
  }

  static _RegistrationPivot _sectionPivot(_ExpectedSection section) {
    double totalX = 0;
    double totalY = 0;
    int count = 0;

    for (final _ExpectedQuestion question in section.questions) {
      for (final _ExpectedBubble bubble in question.bubbles) {
        totalX += _scaledX(bubble.centerX);
        totalY += _scaledY(bubble.centerY);
        count++;
      }
    }

    if (count == 0) {
      return const _RegistrationPivot(0, 0);
    }

    return _RegistrationPivot(totalX / count, totalY / count);
  }

  static _RegisteredPoint _transformBubbleCenter({
    required _ExpectedBubble bubble,
    required _SectionRegistration registration,
  }) {
    final double originalX = _scaledX(bubble.centerX);
    final double originalY = _scaledY(bubble.centerY);

    double x = (originalX - registration.pivotX) * registration.scaleX;
    double y = (originalY - registration.pivotY) * registration.scaleY;

    final double cosA = math.cos(registration.rotationRadians);
    final double sinA = math.sin(registration.rotationRadians);

    final double rotatedX = (x * cosA) - (y * sinA);
    final double rotatedY = (x * sinA) + (y * cosA);

    return _RegisteredPoint(
      registration.pivotX + rotatedX + registration.dx,
      registration.pivotY + rotatedY + registration.dy,
    );
  }

  static double _sectionTransformScore({
    required img.Image image,
    required _ExpectedSection section,
    required _SectionRegistration registration,
  }) {
    /*
     * Score ONLY bubble-like circular outlines.
     *
     * The previous registration score mainly rewarded darkness on a theoretical
     * ring. Printed question numbers can also contain dark pixels at some of
     * those locations, which allowed the whole MCQ grid to drift toward the
     * numbering column.
     *
     * This score is deliberately shape-aware:
     *   1. many angles around the expected circumference must be dark;
     *   2. opposite sides of the circle should both exist;
     *   3. the immediate outside of the bubble should be lighter than the ring;
     *   4. the transform is kept conservative with translation/scale/rotation
     *      penalties.
     *
     * A filled bubble still scores well because its printed circular boundary
     * remains present. We do NOT require the bubble interior to be white.
     */
    double total = 0.0;
    int count = 0;

    final double averageScale =
        (registration.scaleX + registration.scaleY) / 2.0;
    final double bubbleRadius =
        (expectedNormalizedBubbleSize / 2.0) * averageScale;

    for (final _ExpectedQuestion question in section.questions) {
      for (final _ExpectedBubble bubble in question.bubbles) {
        final _RegisteredPoint point = _transformBubbleCenter(
          bubble: bubble,
          registration: registration,
        );

        total += _circularBubbleOutlineScore(
          image: image,
          centerX: point.x,
          centerY: point.y,
          bubbleRadius: bubbleRadius,
        );
        count++;
      }
    }

    if (count == 0) {
      return double.negativeInfinity;
    }

    final double translationPenalty =
        math.sqrt(
          (registration.dx * registration.dx) +
              (registration.dy * registration.dy),
        ) /
        sectionRegistrationSearchRadius;

    final double scalePenalty =
        (registration.scaleX - 1).abs() + (registration.scaleY - 1).abs();

    final double rotationPenalty =
        registration.rotationRadians.abs() / (2.0 * math.pi / 180.0);

    return (total / count) -
        (translationPenalty * 0.018) -
        (scalePenalty * 0.12) -
        (rotationPenalty * 0.012);
  }

  static double _circularBubbleOutlineScore({
    required img.Image image,
    required double centerX,
    required double centerY,
    required double bubbleRadius,
  }) {
    const int samples = 32;

    // The PDF stroke is normally slightly inside the mathematical outer radius
    // after rasterisation/perspective correction.
    final double ringRadius = bubbleRadius * 0.82;
    final double outerRadius = bubbleRadius * 1.22;

    double ringDarknessSum = 0.0;
    double outerDarknessSum = 0.0;
    int valid = 0;
    int darkRingSamples = 0;
    int oppositeDarkPairs = 0;
    int validPairs = 0;

    final List<double> ringValues = List<double>.filled(samples, 0.0);
    final List<bool> ringValid = List<bool>.filled(samples, false);

    for (int i = 0; i < samples; i++) {
      final double angle = (2.0 * math.pi * i) / samples;

      final int ringX = (centerX + math.cos(angle) * ringRadius).round();
      final int ringY = (centerY + math.sin(angle) * ringRadius).round();
      final int outerX = (centerX + math.cos(angle) * outerRadius).round();
      final int outerY = (centerY + math.sin(angle) * outerRadius).round();

      if (ringX < 0 ||
          ringX >= image.width ||
          ringY < 0 ||
          ringY >= image.height ||
          outerX < 0 ||
          outerX >= image.width ||
          outerY < 0 ||
          outerY >= image.height) {
        continue;
      }

      final double ringDark =
          (255.0 - _pixelBrightness(image, ringX, ringY)) / 255.0;
      final double outerDark =
          (255.0 - _pixelBrightness(image, outerX, outerY)) / 255.0;

      ringValues[i] = ringDark;
      ringValid[i] = true;
      ringDarknessSum += ringDark;
      outerDarknessSum += outerDark;

      // A real printed bubble should have a substantial number of dark samples
      // distributed around its circumference.
      if (ringDark >= 0.28) {
        darkRingSamples++;
      }

      valid++;
    }

    if (valid < samples ~/ 2) {
      return 0.0;
    }

    for (int i = 0; i < samples ~/ 2; i++) {
      final int opposite = i + (samples ~/ 2);
      if (!ringValid[i] || !ringValid[opposite]) continue;

      validPairs++;
      if (ringValues[i] >= 0.22 && ringValues[opposite] >= 0.22) {
        oppositeDarkPairs++;
      }
    }

    final double ringMean = ringDarknessSum / valid;
    final double outerMean = outerDarknessSum / valid;
    final double angularCoverage = darkRingSamples / valid;
    final double oppositeCoverage = validPairs == 0
        ? 0.0
        : oppositeDarkPairs / validPairs;

    // Text strokes may be dark, but normally do not create a complete circular
    // boundary with a lighter band immediately outside it.
    final double ringVsOutside = (ringMean - outerMean).clamp(-1.0, 1.0);

    return (ringMean * 0.28) +
        (angularCoverage * 0.34) +
        (oppositeCoverage * 0.28) +
        (math.max(0.0, ringVsOutside) * 0.10);
  }

  // ==========================================================================
  // READ ONE QUESTION
  // ==========================================================================

  static OMRAnswer _readQuestion({
    required img.Image image,
    required _ExpectedQuestion question,
    required _SectionRegistration registration,
  }) {
    if (question.bubbles.isEmpty) {
      return OMRAnswer(
        questionNumber: question.questionNumber,
        answer: 'Unanswered',
        confidence: 0,
      );
    }

    final List<_BubbleMeasurement> measurements = <_BubbleMeasurement>[];

    for (final _ExpectedBubble bubble in question.bubbles) {
      final _RegisteredPoint registeredCenter = _transformBubbleCenter(
        bubble: bubble,
        registration: registration,
      );

      final _RegisteredPoint refinedCenter = _refineBubbleCenterFromRing(
        image: image,
        expectedX: registeredCenter.x,
        expectedY: registeredCenter.y,
      );

      measurements.add(
        _measureBubbleDarkness(
          image: image,
          centerX: refinedCenter.x,
          centerY: refinedCenter.y,
        ),
      );
    }

    // Rank by LOCALLY NORMALIZED fill evidence rather than raw darkness.
    int winnerIndex = 0;

    for (int i = 1; i < measurements.length; i++) {
      if (_fillScore(measurements[i]) > _fillScore(measurements[winnerIndex])) {
        winnerIndex = i;
      }
    }

    int secondIndex = winnerIndex == 0 ? 1 : 0;

    for (int i = 0; i < measurements.length; i++) {
      if (i == winnerIndex) continue;

      if (_fillScore(measurements[i]) > _fillScore(measurements[secondIndex]) ||
          secondIndex == winnerIndex) {
        secondIndex = i;
      }
    }

    final _BubbleMeasurement winner = measurements[winnerIndex];
    final _BubbleMeasurement second = measurements[secondIndex];

    final double winnerScore = _fillScore(winner);
    final double secondScore = _fillScore(second);
    final double normalizedDifference = winnerScore - secondScore;

    // ------------------------------------------------------------------------
    // BLANK-SHEET PROTECTION
    // ------------------------------------------------------------------------
    //
    // All three checks must pass:
    //   1. interior is darker than local paper/background;
    //   2. enough interior pixels are genuinely darker than local background;
    //   3. the winner clearly beats the competing option(s).
    //
    // This is intentionally independent from the printed ring darkness.
    if (winner.localContrast < minimumLocalContrast ||
        winner.normalizedDarkPixelRatio < minimumNormalizedDarkPixelRatio ||
        normalizedDifference < minimumNormalizedDifference) {
      return OMRAnswer(
        questionNumber: question.questionNumber,
        answer: 'Unanswered',
        confidence: 0,
      );
    }

    // Keep conservative absolute safeguards as a second line of defense.
    if (winner.darkness < minimumBubbleDarkness ||
        winner.darkPixelRatio < minimumDarkPixelRatio ||
        winner.averageDarkness < minimumAverageDarkness) {
      return OMRAnswer(
        questionNumber: question.questionNumber,
        answer: 'Unanswered',
        confidence: 0,
      );
    }

    final String selectedAnswer = question.bubbles[winnerIndex].option;

    final double contrastConfidence =
        ((winner.localContrast - minimumLocalContrast) / 0.30).clamp(0.0, 1.0);

    final double separationConfidence =
        ((normalizedDifference - minimumNormalizedDifference) / 0.25)
            .clamp(0.0, 1.0);

    final double pixelConfidence =
        ((winner.normalizedDarkPixelRatio - minimumNormalizedDarkPixelRatio) /
                0.55)
            .clamp(0.0, 1.0);

    final double confidence =
        ((contrastConfidence * 0.40) +
                (separationConfidence * 0.40) +
                (pixelConfidence * 0.20))
            .clamp(0.0, 1.0);

    return OMRAnswer(
      questionNumber: question.questionNumber,
      answer: selectedAnswer,
      confidence: confidence,
    );
  }

  static double _fillScore(_BubbleMeasurement measurement) {
    // Local contrast is the primary signal. The normalized dark-pixel ratio
    // provides extra evidence that the darkness covers the bubble interior
    // instead of coming from a thin edge/shadow.
    return (measurement.localContrast * 0.72) +
        (measurement.normalizedDarkPixelRatio * 0.28);
  }

  // ==========================================================================
  // LOCAL BUBBLE-CENTER REFINEMENT
  // ==========================================================================

  static _RegisteredPoint _refineBubbleCenterFromRing({
    required img.Image image,
    required double expectedX,
    required double expectedY,
  }) {
    /*
     * Find the center of the printed bubble outline using opposite-side
     * symmetry. This is deliberately different from searching for darkness:
     * a filled mark must not pull the sampling center toward itself.
     *
     * The section registration already puts us close to the bubble. We only
     * search a few pixels to compensate for residual local distortion.
     */
    final double bubbleRadius = expectedNormalizedBubbleSize / 2.0;

    // The printed stroke may land slightly inside/outside the theoretical
    // radius after camera resampling, so score two nearby rings.
    final List<double> radii = <double>[
      bubbleRadius * 0.78,
      bubbleRadius * 0.92,
    ];

    double bestX = expectedX;
    double bestY = expectedY;
    double bestScore = double.negativeInfinity;

    for (
      int dy = -bubbleCenterRefineRadius;
      dy <= bubbleCenterRefineRadius;
      dy++
    ) {
      for (
        int dx = -bubbleCenterRefineRadius;
        dx <= bubbleCenterRefineRadius;
        dx++
      ) {
        final double cx = expectedX + dx;
        final double cy = expectedY + dy;

        double ringStrength = 0.0;
        double symmetry = 0.0;
        int pairs = 0;

        for (final double radius in radii) {
          const int directions = 16;

          for (int i = 0; i < directions ~/ 2; i++) {
            final double angle = (2.0 * math.pi * i) / directions;

            final int x1 = (cx + math.cos(angle) * radius).round();
            final int y1 = (cy + math.sin(angle) * radius).round();
            final int x2 = (cx - math.cos(angle) * radius).round();
            final int y2 = (cy - math.sin(angle) * radius).round();

            if (x1 < 0 ||
                x1 >= image.width ||
                y1 < 0 ||
                y1 >= image.height ||
                x2 < 0 ||
                x2 >= image.width ||
                y2 < 0 ||
                y2 >= image.height) {
              continue;
            }

            final double d1 = (255.0 - _pixelBrightness(image, x1, y1)) / 255.0;
            final double d2 = (255.0 - _pixelBrightness(image, x2, y2)) / 255.0;

            ringStrength += (d1 + d2) / 2.0;
            symmetry += 1.0 - (d1 - d2).abs();
            pairs++;
          }
        }

        if (pairs == 0) continue;

        ringStrength /= pairs;
        symmetry /= pairs;

        final double distance = math.sqrt(
          (dx * dx).toDouble() + (dy * dy).toDouble(),
        );

        // Strong opposite ring pixels are rewarded. A modest distance penalty
        // prevents jumping to text, a neighbouring bubble, or a filled mark.
        final double score =
            (ringStrength * 0.72) +
            (symmetry * 0.28) -
            ((distance / bubbleCenterRefineRadius) * 0.04);

        if (score > bestScore) {
          bestScore = score;
          bestX = cx;
          bestY = cy;
        }
      }
    }

    return _RegisteredPoint(bestX, bestY);
  }

  // ==========================================================================
  // SMALL ALIGNMENT SEARCH
  // ==========================================================================

  static _BubbleMeasurement _measureBubbleWithAlignmentSearch({
    required img.Image image,
    required double centerX,
    required double centerY,
    required int searchRadius,
  }) {
    /*
     * Search locally around the expected bubble center.
     *
     * We apply a distance penalty so an empty bubble cannot easily drift
     * toward its printed outline just because the outline is darker.
     */
    _BubbleMeasurement? bestMeasurement;
    double bestAdjustedScore = -1.0;

    const double maximumDistancePenalty = 0.08;

    for (int offsetY = -searchRadius; offsetY <= searchRadius; offsetY++) {
      for (int offsetX = -searchRadius; offsetX <= searchRadius; offsetX++) {
        final double distance = math.sqrt(
          (offsetX * offsetX) + (offsetY * offsetY),
        );

        if (distance > searchRadius) {
          continue;
        }

        final _BubbleMeasurement measurement = _measureBubbleDarkness(
          image: image,
          centerX: centerX + offsetX,
          centerY: centerY + offsetY,
        );

        final double normalizedDistance = searchRadius == 0
            ? 0.0
            : distance / searchRadius;

        final double adjustedScore =
            measurement.darkness -
            (normalizedDistance * maximumDistancePenalty);

        if (bestMeasurement == null || adjustedScore > bestAdjustedScore) {
          bestMeasurement = measurement;
          bestAdjustedScore = adjustedScore;
        }
      }
    }

    return bestMeasurement ??
        const _BubbleMeasurement(
          darkness: 0,
          darkPixelRatio: 0,
          averageDarkness: 0,
          localContrast: 0,
          normalizedDarkPixelRatio: 0,
        );
  }

  // ==========================================================================
  // BUBBLE DARKNESS
  // ==========================================================================

  static _BubbleMeasurement _measureBubbleDarkness({
    required img.Image image,
    required double centerX,
    required double centerY,
  }) {
    /*
     * Measure TWO regions:
     *
     * 1. INNER CIRCLE
     *    The part a student actually fills.
     *
     * 2. LOCAL BACKGROUND ANNULUS
     *    Paper just outside the printed bubble.
     *
     * A blank bubble may be globally dark because of lighting, but its interior
     * should still be close to its own local paper brightness. A real mark makes
     * the interior significantly darker than that nearby paper.
     */
    final double bubbleRadius = expectedNormalizedBubbleSize / 2.0;
    final double innerRadius =
        expectedNormalizedBubbleSize * bubbleReadRadiusRatio;

    final double backgroundInnerRadius =
        bubbleRadius * backgroundInnerRadiusRatio;
    final double backgroundOuterRadius =
        bubbleRadius * backgroundOuterRadiusRatio;

    final int minX =
        math.max(0, (centerX - backgroundOuterRadius).floor());
    final int maxX =
        math.min(image.width - 1, (centerX + backgroundOuterRadius).ceil());
    final int minY =
        math.max(0, (centerY - backgroundOuterRadius).floor());
    final int maxY =
        math.min(image.height - 1, (centerY + backgroundOuterRadius).ceil());

    final List<int> interiorBrightness = <int>[];
    final List<int> backgroundBrightness = <int>[];

    for (int y = minY; y <= maxY; y++) {
      for (int x = minX; x <= maxX; x++) {
        final double dx = x - centerX;
        final double dy = y - centerY;
        final double distanceSquared = (dx * dx) + (dy * dy);

        if (distanceSquared <= innerRadius * innerRadius) {
          interiorBrightness.add(_pixelBrightness(image, x, y));
          continue;
        }

        if (distanceSquared >=
                backgroundInnerRadius * backgroundInnerRadius &&
            distanceSquared <=
                backgroundOuterRadius * backgroundOuterRadius) {
          backgroundBrightness.add(_pixelBrightness(image, x, y));
        }
      }
    }

    if (interiorBrightness.isEmpty || backgroundBrightness.isEmpty) {
      return const _BubbleMeasurement(
        darkness: 0,
        darkPixelRatio: 0,
        averageDarkness: 0,
        localContrast: 0,
        normalizedDarkPixelRatio: 0,
      );
    }

    // Robust local paper estimate: use the brighter half of nearby pixels.
    // This deliberately reduces contamination from the printed ring, text,
    // and isolated dark edges.
    backgroundBrightness.sort();
    final int brighterHalfStart = backgroundBrightness.length ~/ 2;

    double backgroundSum = 0.0;
    int backgroundCount = 0;

    for (int i = brighterHalfStart; i < backgroundBrightness.length; i++) {
      backgroundSum += backgroundBrightness[i];
      backgroundCount++;
    }

    final double localBackgroundBrightness =
        backgroundCount == 0 ? 255.0 : backgroundSum / backgroundCount;

    int absoluteDarkPixels = 0;
    int locallyDarkPixels = 0;
    double darknessSum = 0.0;
    double contrastSum = 0.0;

    // A pixel must be meaningfully darker than its local paper before it counts
    // as part of a student's mark.
    const double localDarkPixelDelta = 34.0;

    for (final int brightness in interiorBrightness) {
      final double pixelDarkness =
          ((255.0 - brightness) / 255.0).clamp(0.0, 1.0);

      darknessSum += pixelDarkness;

      if (brightness < darkPixelThreshold) {
        absoluteDarkPixels++;
      }

      final double localDelta = localBackgroundBrightness - brightness;

      if (localDelta >= localDarkPixelDelta) {
        locallyDarkPixels++;
      }

      contrastSum += math.max(0.0, localDelta) / 255.0;
    }

    final int totalPixels = interiorBrightness.length;

    final double darkPixelRatio = absoluteDarkPixels / totalPixels;
    final double averageDarkness = darknessSum / totalPixels;

    // Average positive darkness relative to nearby paper.
    final double localContrast = contrastSum / totalPixels;

    // How much of the interior is materially darker than nearby paper.
    final double normalizedDarkPixelRatio = locallyDarkPixels / totalPixels;

    final double combinedDarkness =
        (darkPixelRatio * 0.70) + (averageDarkness * 0.30);

    return _BubbleMeasurement(
      darkness: combinedDarkness,
      darkPixelRatio: darkPixelRatio,
      averageDarkness: averageDarkness,
      localContrast: localContrast,
      normalizedDarkPixelRatio: normalizedDarkPixelRatio,
    );
  }

  // ==========================================================================
  // COORDINATE SCALING
  // ==========================================================================

  static const double expectedNormalizedBubbleSize =
      bubbleSize * (normalizedWidth / sheetWidth);

  static double _scaledX(double sheetX) {
    return sheetX * (normalizedWidth / sheetWidth);
  }

  static double _scaledY(double sheetY) {
    return sheetY * (normalizedHeight / sheetHeight);
  }

  // ==========================================================================
  // COLUMN COUNT
  // ==========================================================================

  static int _calculateOmrColumns(int questionCount) {
    /*
     * Must remain identical to AnswerSheetPdfService.
     */
    if (questionCount >= 10) {
      return 2;
    }

    return 1;
  }

  // ==========================================================================
  // QUESTION COUNT
  // ==========================================================================

  static int _getQuestionCount(Map<String, dynamic> section) {
    final dynamic directCount = section['question_count'];

    if (directCount != null) {
      final int? parsed = int.tryParse(directCount.toString());

      if (parsed != null && parsed > 0) {
        return parsed;
      }
    }

    final dynamic questions = section['questions'];

    if (questions is List) {
      return questions.length;
    }

    return 0;
  }

  // ==========================================================================
  // TYPE NORMALIZATION
  // ==========================================================================

  static String _normalizeType(dynamic value) {
    final String type = (value?.toString() ?? '')
        .trim()
        .toLowerCase()
        .replaceAll('-', '_')
        .replaceAll(' ', '_');

    if (type == 'mc' || type == 'multiplechoice' || type == 'multiple_choice') {
      return 'multiple_choice';
    }

    if (type == 'tf' || type == 'truefalse' || type == 'true_false') {
      return 'true_false';
    }

    if (type == 'identification' || type == 'identify') {
      return 'identification';
    }

    return type;
  }

  // ==========================================================================
  // PIXEL BRIGHTNESS
  // ==========================================================================

  static int _pixelBrightness(img.Image image, int x, int y) {
    final img.Pixel pixel = image.getPixel(x, y);

    final double brightness =
        (pixel.r * 0.299) + (pixel.g * 0.587) + (pixel.b * 0.114);

    return brightness.round();
  }
}