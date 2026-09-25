import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

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

  const OMRProcessingResult({
    required this.sections,
  });

  int get detectedQuestions {
    return sections.fold(
      0,
      (total, section) => total + section.questionCount,
    );
  }

  int get answeredQuestions {
    return sections.fold(
      0,
      (total, section) {
        return total +
            section.answers
                .where((answer) => !answer.isUnanswered)
                .length;
      },
    );
  }
}

class _BubbleCandidate {
  final double x;
  final double y;
  final double width;
  final double height;

  const _BubbleCandidate({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  double get centerX => x + width / 2;

  double get centerY => y + height / 2;
}

class _BubbleReading {
  final _BubbleCandidate bubble;
  final double insideDarkness;

  const _BubbleReading({
    required this.bubble,
    required this.insideDarkness,
  });
}

class _QuestionRow {
  final List<_BubbleReading> bubbles;

  _QuestionRow({
    required this.bubbles,
  });

  double get centerY {
    if (bubbles.isEmpty) {
      return 0;
    }

    return bubbles
            .map(
              (bubble) => bubble.bubble.centerY,
            )
            .reduce(
              (a, b) => a + b,
            ) /
        bubbles.length;
  }
}

class OMRProcessor {
  static const List<String> multipleChoiceOptions = [
    'A',
    'B',
    'C',
    'D',
  ];

  static const List<String> trueFalseOptions = [
    'T',
    'F',
  ];

  static const int normalizedWidth = 1500;
  static const int normalizedHeight = 2129;

  // ---------------------------------------------------------------------------
  // DETECTION SETTINGS
  // ---------------------------------------------------------------------------

  /*
   * Your PDF generator uses approximately:
   *
   *     bubble size = 11
   *     normalized sheet width = 1500
   *     PDF sheet width = 397
   *
   * Therefore:
   *
   *     11 / 397 * 1500 ≈ 42 pixels
   *
   * We search for bubbles around that size.
   */
  static const double expectedBubbleSize = 42.0;

  static const double minimumBubbleSize = 27.0;
  static const double maximumBubbleSize = 55.0;

  /*
   * Empty bubble interiors should be mostly white.
   *
   * A real filled answer should have significantly
   * more dark pixels in its center.
   */
  static const int interiorDarkThreshold = 135;

  static const double minimumMarkedDarkness = 0.28;

  /*
   * Selected answer should be sufficiently darker
   * than the next darkest option.
   */
  static const double minimumDifference = 0.08;

  /*
   * Circular outline detection threshold.
   */
  static const double minimumCircleScore = 0.42;

  /*
   * How far apart two bubble centers can be before
   * being treated as different bubbles.
   */
  static const double duplicateDistance = 15.0;

  /*
   * Row spacing in the normalized image is approximately
   * 17 / 397 * 1500 ≈ 64 pixels.
   */
  static const double rowTolerance = 18.0;

  // ===========================================================================
  // PROCESS
  // ===========================================================================

  static Future<OMRProcessingResult> process(
    Uint8List imageBytes, {
    required List<Map<String, dynamic>> sections,
  }) async {
    final img.Image? decoded =
        img.decodeImage(imageBytes);

    if (decoded == null) {
      throw Exception(
        'Unable to decode the corrected answer sheet image.',
      );
    }

    final img.Image image =
        img.copyResize(
      decoded,
      width: normalizedWidth,
      height: normalizedHeight,
    );

    /*
     * Detect all circular bubble locations.
     */
    final List<_BubbleCandidate> candidates =
        _detectBubbleCandidates(image);

    /*
     * Convert detected bubbles into physical rows.
     */
    final List<_QuestionRow> allRows =
        _groupAllRows(
      image: image,
      candidates: candidates,
    );

    /*
     * Sort rows from top to bottom.
     */
    allRows.sort(
      (a, b) => a.centerY.compareTo(
        b.centerY,
      ),
    );

    final List<OMRSectionResult> results = [];

    /*
     * IMPORTANT:
     *
     * We now consume rows sequentially.
     *
     * Example:
     *
     * Multiple Choice 15 questions
     * True/False       2 questions
     *
     * MC consumes its 15 rows first.
     * TF starts AFTER those rows.
     *
     * This prevents the TF section from accidentally
     * reusing MC rows.
     */
    int rowCursor = 0;

    for (final section in sections) {
      final String name =
          section['name']?.toString() ??
              section['title']?.toString() ??
              section['section_name']?.toString() ??
              'Section';

      final String type =
          _normalizeType(
        section['question_type'] ??
            section['type'],
      );

      final int questionCount =
          _getQuestionCount(section);

      if (questionCount <= 0) {
        continue;
      }

      // -----------------------------------------------------------------------
      // IDENTIFICATION
      // -----------------------------------------------------------------------

      if (type == 'identification') {
        final List<OMRAnswer> answers =
            List.generate(
          questionCount,
          (index) => OMRAnswer(
            questionNumber: index + 1,
            answer: 'OCR Pending',
            confidence: 0,
          ),
        );

        results.add(
          OMRSectionResult(
            sectionName: name,
            sectionType: type,
            questionCount: questionCount,
            answers: answers,
          ),
        );

        /*
         * Identification has no bubbles.
         *
         * Do not consume OMR rows.
         */
        continue;
      }

      // -----------------------------------------------------------------------
      // MULTIPLE CHOICE / TRUE FALSE
      // -----------------------------------------------------------------------

      List<String> options;

      if (type == 'multiple_choice') {
        options = multipleChoiceOptions;
      } else if (type == 'true_false') {
        options = trueFalseOptions;
      } else {
        continue;
      }

      /*
       * Take only rows belonging to this section.
       */
      final List<_QuestionRow> sectionRows = [];

      while (rowCursor <
              allRows.length &&
          sectionRows.length <
              questionCount) {
        final _QuestionRow row =
            allRows[rowCursor++];

        /*
         * Only accept a row if it has exactly
         * the expected number of choices.
         *
         * MC = 4
         * TF = 2
         */
        if (row.bubbles.length ==
            options.length) {
          sectionRows.add(row);
        }
      }

      final List<OMRAnswer> answers =
          _processRows(
        image: image,
        rows: sectionRows,
        questionCount: questionCount,
        options: options,
      );

      results.add(
        OMRSectionResult(
          sectionName: name,
          sectionType: type,
          questionCount: questionCount,
          answers: answers,
        ),
      );
    }

    return OMRProcessingResult(
      sections: results,
    );
  }

  // ===========================================================================
  // QUESTION COUNT
  // ===========================================================================

  static int _getQuestionCount(
    Map<String, dynamic> section,
  ) {
    final dynamic directCount =
        section['question_count'];

    if (directCount != null) {
      return int.tryParse(
            directCount.toString(),
          ) ??
          0;
    }

    final dynamic questions =
        section['questions'];

    if (questions is List) {
      return questions.length;
    }

    return 0;
  }

  // ===========================================================================
  // TYPE
  // ===========================================================================

  static String _normalizeType(
    dynamic value,
  ) {
    final String type =
        (value?.toString() ?? '')
            .trim()
            .toLowerCase()
            .replaceAll('-', '_')
            .replaceAll(' ', '_');

    if (type == 'mc' ||
        type == 'multiplechoice' ||
        type == 'multiple_choice') {
      return 'multiple_choice';
    }

    if (type == 'tf' ||
        type == 'truefalse' ||
        type == 'true_false') {
      return 'true_false';
    }

    if (type == 'identification' ||
        type == 'identify') {
      return 'identification';
    }

    return type;
  }

  // ===========================================================================
  // PROCESS ROWS
  // ===========================================================================

  static List<OMRAnswer> _processRows({
    required img.Image image,
    required List<_QuestionRow> rows,
    required int questionCount,
    required List<String> options,
  }) {
    final List<OMRAnswer> answers = [];

    for (int i = 0;
        i < questionCount;
        i++) {
      if (i >= rows.length) {
        answers.add(
          OMRAnswer(
            questionNumber: i + 1,
            answer: 'Unanswered',
            confidence: 0,
          ),
        );

        continue;
      }

      final List<_BubbleReading> bubbles =
          List<_BubbleReading>.from(
        rows[i].bubbles,
      );

      if (bubbles.length !=
          options.length) {
        answers.add(
          OMRAnswer(
            questionNumber: i + 1,
            answer: 'Unanswered',
            confidence: 0,
          ),
        );

        continue;
      }

      /*
       * Bubble order is left → right.
       */
      bubbles.sort(
        (a, b) =>
            a.bubble.centerX.compareTo(
          b.bubble.centerX,
        ),
      );

      /*
       * Find darkest interior.
       */
      final List<_BubbleReading>
          byDarkness =
          List<_BubbleReading>.from(
        bubbles,
      );

      byDarkness.sort(
        (a, b) =>
            b.insideDarkness.compareTo(
          a.insideDarkness,
        ),
      );

      final _BubbleReading darkest =
          byDarkness.first;

      final double secondDarkest =
          byDarkness.length > 1
              ? byDarkness[1]
                  .insideDarkness
              : 0;

      final double difference =
          darkest.insideDarkness -
              secondDarkest;

      // -----------------------------------------------------------------------
      // EMPTY
      // -----------------------------------------------------------------------

      if (darkest.insideDarkness <
          minimumMarkedDarkness) {
        answers.add(
          OMRAnswer(
            questionNumber: i + 1,
            answer: 'Unanswered',
            confidence: 0,
          ),
        );

        continue;
      }

      // -----------------------------------------------------------------------
      // AMBIGUOUS
      // -----------------------------------------------------------------------

      if (difference <
          minimumDifference) {
        answers.add(
          OMRAnswer(
            questionNumber: i + 1,
            answer: 'Unanswered',
            confidence: 0,
          ),
        );

        continue;
      }

      final int selectedIndex =
          bubbles.indexOf(
        darkest,
      );

      if (selectedIndex < 0 ||
          selectedIndex >=
              options.length) {
        answers.add(
          OMRAnswer(
            questionNumber: i + 1,
            answer: 'Unanswered',
            confidence: 0,
          ),
        );

        continue;
      }

      final double confidence =
          ((difference -
                      minimumDifference) *
                  6)
              .clamp(
                0.0,
                1.0,
              );

      answers.add(
        OMRAnswer(
          questionNumber: i + 1,
          answer:
              options[selectedIndex],
          confidence: confidence,
        ),
      );
    }

    return answers;
  }

  // ===========================================================================
  // DETECT BUBBLE CANDIDATES
  // ===========================================================================

  static List<_BubbleCandidate>
      _detectBubbleCandidates(
    img.Image image,
  ) {
    final List<_BubbleCandidate>
        candidates = [];

    /*
     * Search the answer area only.
     *
     * Header/QR/registration area is excluded.
     */
    final int startY =
        (normalizedHeight * 0.20)
            .round();

    final int endY =
        (normalizedHeight * 0.96)
            .round();

    final int startX =
        (normalizedWidth * 0.04)
            .round();

    final int endX =
        (normalizedWidth * 0.96)
            .round();

    /*
     * Bubble centers are approximately 42px apart
     * in size, so sampling every 4 pixels gives
     * sufficient coverage without checking every pixel.
     */
    const int scanStep = 4;

    for (int y = startY;
        y < endY;
        y += scanStep) {
      for (int x = startX;
          x < endX;
          x += scanStep) {
        final double circleScore =
            _circleScoreAt(
          image,
          x.toDouble(),
          y.toDouble(),
        );

        if (circleScore <
            minimumCircleScore) {
          continue;
        }

        /*
         * Estimate the actual bubble bounds.
         */
        final _BubbleCandidate candidate =
            _BubbleCandidate(
          x: x -
              expectedBubbleSize / 2,
          y: y -
              expectedBubbleSize / 2,
          width:
              expectedBubbleSize,
          height:
              expectedBubbleSize,
        );

        candidates.add(
          candidate,
        );
      }
    }

    return _removeDuplicates(
      candidates,
    );
  }

  // ===========================================================================
  // CIRCLE SCORE
  // ===========================================================================

  static double _circleScoreAt(
    img.Image image,
    double centerX,
    double centerY,
  ) {
    /*
     * The bubble outline is approximately
     * 42px in diameter.
     *
     * Sample around the outer ring.
     */
    final double radius =
        expectedBubbleSize * 0.40;

    /*
     * Also sample slightly inside/outside
     * the theoretical ring.
     *
     * This makes the detector more tolerant
     * of resizing and camera distortion.
     */
    const int sampleCount = 24;

    int darkSamples = 0;
    int validSamples = 0;

    for (int i = 0;
        i < sampleCount;
        i++) {
      final double angle =
          (2 * math.pi * i) /
              sampleCount;

      for (final double radiusMultiplier
          in [
        0.88,
        1.00,
        1.12,
      ]) {
        final double radiusSample =
            radius *
                radiusMultiplier;

        final int x =
            (centerX +
                    math.cos(angle) *
                        radiusSample)
                .round();

        final int y =
            (centerY +
                    math.sin(angle) *
                        radiusSample)
                .round();

        if (x < 0 ||
            x >= image.width ||
            y < 0 ||
            y >= image.height) {
          continue;
        }

        validSamples++;

        final int brightness =
            _pixelBrightness(
          image,
          x,
          y,
        );

        if (brightness <
            175) {
          darkSamples++;
        }
      }
    }

    if (validSamples == 0) {
      return 0;
    }

    return darkSamples /
        validSamples;
  }

  // ===========================================================================
  // REMOVE DUPLICATES
  // ===========================================================================

  static List<_BubbleCandidate>
      _removeDuplicates(
    List<_BubbleCandidate>
        candidates,
  ) {
    final List<_BubbleCandidate>
        result = [];

    /*
     * Sort top-to-bottom first.
     */
    final List<_BubbleCandidate>
        sorted =
        List<_BubbleCandidate>.from(
      candidates,
    );

    sorted.sort(
      (a, b) =>
          a.centerY.compareTo(
        b.centerY,
      ),
    );

    for (final _BubbleCandidate
        candidate in sorted) {
      bool duplicate = false;

      for (final _BubbleCandidate
          existing in result) {
        final double dx =
            candidate.centerX -
                existing.centerX;

        final double dy =
            candidate.centerY -
                existing.centerY;

        final double distance =
            math.sqrt(
          dx * dx +
              dy * dy,
        );

        if (distance <
            duplicateDistance) {
          duplicate = true;
          break;
        }
      }

      if (!duplicate) {
        result.add(
          candidate,
        );
      }
    }

    return result;
  }

  // ===========================================================================
  // GROUP ALL ROWS
  // ===========================================================================

  static List<_QuestionRow>
      _groupAllRows({
    required img.Image image,
    required List<_BubbleCandidate>
        candidates,
  }) {
    if (candidates.isEmpty) {
      return [];
    }

    /*
     * Separate left and right physical columns.
     */
    final List<_BubbleCandidate>
        left = [];

    final List<_BubbleCandidate>
        right = [];

    const double pageCenterX =
        normalizedWidth / 2;

    for (final _BubbleCandidate
        candidate in candidates) {
      if (candidate.centerX <
          pageCenterX) {
        left.add(
          candidate,
        );
      } else {
        right.add(
          candidate,
        );
      }
    }

    final List<_QuestionRow>
        leftRows =
        _groupColumnRows(
      image: image,
      candidates: left,
    );

    final List<_QuestionRow>
        rightRows =
        _groupColumnRows(
      image: image,
      candidates: right,
    );

    /*
     * IMPORTANT:
     *
     * We do NOT simply return all left rows
     * followed by all right rows here.
     *
     * We need the physical reading order:
     *
     * Left column first, then right column,
     * according to the PDF generator.
     *
     * For a 15-item section:
     *
     * Left:  Q1-Q8
     * Right: Q9-Q15
     *
     * Therefore returning leftRows + rightRows
     * is correct for the generated sheet.
     */
    return [
      ...leftRows,
      ...rightRows,
    ];
  }

  // ===========================================================================
  // GROUP ONE COLUMN
  // ===========================================================================

  static List<_QuestionRow>
      _groupColumnRows({
    required img.Image image,
    required List<_BubbleCandidate>
        candidates,
  }) {
    if (candidates.isEmpty) {
      return [];
    }

    final List<_BubbleCandidate>
        sorted =
        List<_BubbleCandidate>.from(
      candidates,
    );

    sorted.sort(
      (a, b) =>
          a.centerY.compareTo(
        b.centerY,
      ),
    );

    final List<_QuestionRow>
        rows = [];

    for (final _BubbleCandidate
        candidate in sorted) {
      _QuestionRow? closestRow;

      double closestDistance =
          double.infinity;

      for (final _QuestionRow row
          in rows) {
        final double distance =
            (candidate.centerY -
                    row.centerY)
                .abs();

        if (distance <=
                rowTolerance &&
            distance <
                closestDistance) {
          closestDistance =
              distance;

          closestRow = row;
        }
      }

      if (closestRow ==
          null) {
        rows.add(
          _QuestionRow(
            bubbles: [
              _readBubble(
                image,
                candidate,
              ),
            ],
          ),
        );
      } else {
        /*
         * A row cannot contain more than
         * four choices.
         *
         * This also prevents accidental
         * merging with neighboring elements.
         */
        if (closestRow
                .bubbles
                .length <
            4) {
          closestRow.bubbles.add(
            _readBubble(
              image,
              candidate,
            ),
          );
        }
      }
    }

    /*
     * Sort bubbles left-to-right.
     */
    for (final _QuestionRow row
        in rows) {
      row.bubbles.sort(
        (a, b) =>
            a.bubble.centerX
                .compareTo(
          b.bubble.centerX,
        ),
      );
    }

    /*
     * Sort rows top-to-bottom.
     */
    rows.sort(
      (a, b) =>
          a.centerY.compareTo(
        b.centerY,
      ),
    );

    return rows;
  }

  // ===========================================================================
  // READ BUBBLE INTERIOR
  // ===========================================================================

  static _BubbleReading _readBubble(
    img.Image image,
    _BubbleCandidate bubble,
  ) {
    final double centerX =
        bubble.centerX;

    final double centerY =
        bubble.centerY;

    /*
     * Only inspect the middle of the bubble.
     *
     * The printed circular outline is excluded.
     */
    final double radius =
        math.min(
              bubble.width,
              bubble.height,
            ) *
            0.25;

    final int minX =
        math.max(
          0,
          (centerX - radius)
              .floor(),
        );

    final int maxX =
        math.min(
          image.width - 1,
          (centerX + radius)
              .ceil(),
        );

    final int minY =
        math.max(
          0,
          (centerY - radius)
              .floor(),
        );

    final int maxY =
        math.min(
          image.height - 1,
          (centerY + radius)
              .ceil(),
        );

    int darkPixels = 0;
    int totalPixels = 0;

    for (int y = minY;
        y <= maxY;
        y++) {
      for (int x = minX;
          x <= maxX;
          x++) {
        final double dx =
            x - centerX;

        final double dy =
            y - centerY;

        final double distance =
            math.sqrt(
          dx * dx +
              dy * dy,
        );

        if (distance >
            radius) {
          continue;
        }

        totalPixels++;

        final int brightness =
            _pixelBrightness(
          image,
          x,
          y,
        );

        if (brightness <
            interiorDarkThreshold) {
          darkPixels++;
        }
      }
    }

    final double darkness =
        totalPixels == 0
            ? 0
            : darkPixels /
                totalPixels;

    return _BubbleReading(
      bubble: bubble,
      insideDarkness: darkness,
    );
  }

  // ===========================================================================
  // PIXEL BRIGHTNESS
  // ===========================================================================

  static int _pixelBrightness(
    img.Image image,
    int x,
    int y,
  ) {
    final img.Pixel pixel =
        image.getPixel(
      x,
      y,
    );

    final double brightness =
        (pixel.r * 0.299) +
            (pixel.g * 0.587) +
            (pixel.b * 0.114);

    return brightness.round();
  }
}