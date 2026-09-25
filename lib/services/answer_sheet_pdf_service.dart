import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:qr/qr.dart';

class AnswerSheetPdfService {
  /*
    --------------------------------------------------------------------------
    CHECKMATE DYNAMIC ANSWER SHEET
    --------------------------------------------------------------------------

    Main goals:

    1. Use as little paper as reasonably possible.
    2. Keep OMR bubbles at a fixed physical size.
    3. Allow MC and True/False to use multiple columns.
    4. Keep Identification as wider OCR writing boxes.
    5. Dynamically create additional A5 sheets only when necessary.
    6. Put two A5 sheets on one A4 landscape page.
    7. Dynamically center OMR blocks when possible.
    8. Give every sheet a unique QR/sheet identifier.
    9. Provide four fixed registration markers for scanning.

    --------------------------------------------------------------------------
  */

  // --------------------------------------------------------------------------
  // A5-STYLE SHEET DIMENSIONS
  // --------------------------------------------------------------------------

  /*
    A5 portrait:
    148 mm x 210 mm

    The answer sheet is placed inside an A4 landscape page.
  */

  static const double _sheetWidth = 397;
  static const double _sheetHeight = 559;

  static const double _sheetPadding = 10;

  // --------------------------------------------------------------------------
  // REGISTRATION MARKERS
  // --------------------------------------------------------------------------

  /*
    These four markers are used by the scanner to determine:

    - sheet location
    - orientation
    - rotation
    - perspective distortion
    - sheet boundaries

    Keep these dimensions fixed.
  */

  static const double _registrationMarkerSize = 10;

  // Distance of the marker from the outside edge of the sheet.
  static const double _registrationMarkerInset = 2;

  // --------------------------------------------------------------------------
  // OMR SETTINGS
  // --------------------------------------------------------------------------

  /*
    Keep these dimensions stable.

    Scanner accuracy is more important than squeezing every possible
    question into a tiny space.
  */

  static const double _bubbleSize = 11;

  static const double _answerOptionWidth = 23;

  static const double _questionNumberWidth = 17;

  static const double _omrRowHeight = 17;

  // --------------------------------------------------------------------------
  // IDENTIFICATION SETTINGS
  // --------------------------------------------------------------------------

  static const double _identificationBoxHeight = 18;

  static const double _identificationRowSpacing = 3;

  // --------------------------------------------------------------------------
  // SPACING
  // --------------------------------------------------------------------------

  static const double _sectionTitleHeight = 18;

  static const double _sectionSpacing = 5;

  // --------------------------------------------------------------------------
  // MAIN PDF GENERATOR
  // --------------------------------------------------------------------------

  static Future<Uint8List> generate({
    required Map<String, dynamic> exam,
    required List<Map<String, dynamic>> sections,
    required Map<int, List<Map<String, dynamic>>> questions,
  }) async {
    final pdf = pw.Document();

    /*
      Only keep sections that actually contain questions.
    */
    final activeSections = <Map<String, dynamic>>[];

    for (final section in sections) {
      final sectionId = int.tryParse(section['id']?.toString() ?? '');

      if (sectionId == null) {
        continue;
      }

      final sectionQuestions = questions[sectionId] ?? [];

      if (sectionQuestions.isEmpty) {
        continue;
      }

      activeSections.add(section);
    }

    /*
      Build the actual A5 sheet layouts.

      Each layout contains the section IDs that belong
      to that particular sheet.
    */
    final sheetLayouts = _buildSheetLayouts(
      sections: activeSections,
      questions: questions,
    );

    /*
      If there are no questions, still generate one sheet.
    */
    if (sheetLayouts.isEmpty) {
      sheetLayouts.add([]);
    }

    /*
      Two A5 sheets per A4 landscape page.
    */
    for (int index = 0; index < sheetLayouts.length; index += 2) {
      final leftLayout = sheetLayouts[index];

      final rightLayout = index + 1 < sheetLayouts.length
          ? sheetLayouts[index + 1]
          : null;

      pdf.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4.landscape,
          margin: const pw.EdgeInsets.all(18),
          build: (context) {
            return pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Expanded(
                  child: _buildAnswerSheet(
                    exam: exam,
                    sections: activeSections,
                    questions: questions,
                    layout: leftLayout,
                    sheetNumber: index + 1,
                  ),
                ),

                pw.SizedBox(width: 12),

                pw.Expanded(
                  child: rightLayout == null
                      ? pw.SizedBox()
                      : _buildAnswerSheet(
                          exam: exam,
                          sections: activeSections,
                          questions: questions,
                          layout: rightLayout,
                          sheetNumber: index + 2,
                        ),
                ),
              ],
            );
          },
        ),
      );
    }

    return pdf.save();
  }

  // --------------------------------------------------------------------------
  // DYNAMIC SHEET PAGINATION
  // --------------------------------------------------------------------------

  static List<List<int>> _buildSheetLayouts({
    required List<Map<String, dynamic>> sections,
    required Map<int, List<Map<String, dynamic>>> questions,
  }) {
    final layouts = <List<int>>[];

    var currentSheet = <int>[];

    /*
      Space already consumed by:

      - header
      - QR
      - student information
      - top spacing
    */
    double usedHeight = _headerAndStudentInfoHeight();

    for (final section in sections) {
      final sectionId = int.tryParse(section['id']?.toString() ?? '');

      if (sectionId == null) {
        continue;
      }

      final type = _normalizeType(section['question_type']);

      final sectionQuestions = questions[sectionId] ?? [];

      if (sectionQuestions.isEmpty) {
        continue;
      }

      final sectionHeight = _calculateSectionHeight(
        type: type,
        questionCount: sectionQuestions.length,
      );

      /*
        If the section does not fit on the current sheet,
        start a new sheet.

        We keep whole sections together whenever possible.
      */
      if (currentSheet.isNotEmpty &&
          usedHeight + sectionHeight > _usableSheetHeight()) {
        layouts.add(currentSheet);

        currentSheet = [];

        usedHeight = _headerAndStudentInfoHeight();
      }

      currentSheet.add(sectionId);

      usedHeight += sectionHeight;
    }

    if (currentSheet.isNotEmpty) {
      layouts.add(currentSheet);
    }

    return layouts;
  }

  // --------------------------------------------------------------------------
  // SHEET SPACE CALCULATION
  // --------------------------------------------------------------------------

  static double _headerAndStudentInfoHeight() {
    /*
      Approximate space consumed by:

      Header
      Student information
      Spacing
    */

    return 97;
  }

  static double _usableSheetHeight() {
    /*
      Leave room for the four registration markers.

      The markers are positioned independently using Stack,
      so they do not consume normal Column layout space.
    */

    return _sheetHeight - (_sheetPadding * 2) - 18;
  }

  // --------------------------------------------------------------------------
  // SECTION HEIGHT CALCULATION
  // --------------------------------------------------------------------------

  static double _calculateSectionHeight({
    required String type,
    required int questionCount,
  }) {
    if (type == 'multiple_choice' || type == 'true_false') {
      final columns = _calculateOmrColumns(questionCount);

      final rows = (questionCount / columns).ceil();

      return _sectionTitleHeight + (rows * _omrRowHeight) + _sectionSpacing;
    }

    if (type == 'identification') {
      return _sectionTitleHeight +
          (questionCount *
              (_identificationBoxHeight + _identificationRowSpacing)) +
          _sectionSpacing;
    }

    /*
      Unknown section type.
    */
    return 30;
  }

  // --------------------------------------------------------------------------
  // OMR COLUMN CALCULATION
  // --------------------------------------------------------------------------

  static int _calculateOmrColumns(int questionCount) {
    /*
      1-9 questions:
      1 column

      10+ questions:
      2 columns
    */

    if (questionCount >= 10) {
      return 2;
    }

    return 1;
  }

  // --------------------------------------------------------------------------
  // TYPE NORMALIZATION
  // --------------------------------------------------------------------------

  static String _normalizeType(dynamic value) {
    return (value?.toString() ?? '').trim().toLowerCase();
  }

  // --------------------------------------------------------------------------
  // ANSWER SHEET
  // --------------------------------------------------------------------------

  static pw.Widget _buildAnswerSheet({
    required Map<String, dynamic> exam,
    required List<Map<String, dynamic>> sections,
    required Map<int, List<Map<String, dynamic>>> questions,
    required List<int> layout,
    required int sheetNumber,
  }) {
    final examId = exam['id']?.toString() ?? '';

    /*
      Main answer-sheet content.

      Registration markers are NOT part of this Column.
      They are positioned independently using Stack.
    */
    final content = pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        _buildHeader(exam: exam, examId: examId, sheetNumber: sheetNumber),

        pw.SizedBox(height: 6),

        _buildStudentInformation(),

        pw.SizedBox(height: 7),

        /*
          Render only the sections assigned
          to this particular sheet.
        */
        ...sections
            .where((section) {
              final sectionId = int.tryParse(section['id']?.toString() ?? '');

              return sectionId != null && layout.contains(sectionId);
            })
            .map((section) {
              final sectionId = int.tryParse(section['id']?.toString() ?? '');

              if (sectionId == null) {
                return pw.SizedBox();
              }

              final type = _normalizeType(section['question_type']);

              final sectionQuestions = questions[sectionId] ?? [];

              return _buildSection(
                section: section,
                type: type,
                questions: sectionQuestions,
              );
            }),

        /*
          Empty space is used here instead of forcing
          content to the very bottom.
        */
        pw.Spacer(),
      ],
    );

    /*
      Stack allows us to position all four registration
      markers at fixed coordinates.
    */
    return pw.Container(
      width: _sheetWidth,
      height: _sheetHeight,
      decoration: pw.BoxDecoration(border: pw.Border.all(width: 1)),
      child: pw.Stack(
        children: [
          /*
            Main answer-sheet content.
          */
          pw.Positioned(
            left: _sheetPadding,
            right: _sheetPadding,
            top: _sheetPadding,
            bottom: _sheetPadding,
            child: content,
          ),

          /*
            TOP-LEFT
          */
          pw.Positioned(
            left: _registrationMarkerInset,
            top: _registrationMarkerInset,
            child: _buildRegistrationMarker(),
          ),

          /*
            TOP-RIGHT
          */
          pw.Positioned(
            right: _registrationMarkerInset,
            top: _registrationMarkerInset,
            child: _buildRegistrationMarker(),
          ),

          /*
            BOTTOM-LEFT
          */
          pw.Positioned(
            left: _registrationMarkerInset,
            bottom: _registrationMarkerInset,
            child: _buildRegistrationMarker(),
          ),

          /*
            BOTTOM-RIGHT
          */
          pw.Positioned(
            right: _registrationMarkerInset,
            bottom: _registrationMarkerInset,
            child: _buildRegistrationMarker(),
          ),
        ],
      ),
    );
  }

  // --------------------------------------------------------------------------
  // HEADER
  // --------------------------------------------------------------------------

  static pw.Widget _buildHeader({
    required Map<String, dynamic> exam,
    required String examId,
    required int sheetNumber,
  }) {
    final sheetId = 'CHECKMATE-EXAM-$examId-SHEET-$sheetNumber';

    return pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Expanded(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(
                'CHECKMATE',
                style: pw.TextStyle(
                  fontSize: 12,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),

              pw.SizedBox(height: 2),

              pw.Text(
                exam['title']?.toString() ?? 'Exam',
                style: pw.TextStyle(
                  fontSize: 8,
                  fontWeight: pw.FontWeight.bold,
                ),
                maxLines: 2,
              ),

              pw.SizedBox(height: 2),

              pw.Text(
                'Exam ID: $examId',
                style: const pw.TextStyle(fontSize: 6),
              ),

              pw.SizedBox(height: 2),

              pw.Text(
                'Sheet $sheetNumber',
                style: pw.TextStyle(
                  fontSize: 6,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),

              pw.SizedBox(height: 2),

              pw.Text(sheetId, style: const pw.TextStyle(fontSize: 4.5)),
            ],
          ),
        ),

        _buildQrCode(sheetId),
      ],
    );
  }

  // --------------------------------------------------------------------------
  // STUDENT INFORMATION
  // --------------------------------------------------------------------------

  static pw.Widget _buildStudentInformation() {
    return pw.Column(
      children: [
        pw.Row(
          children: [
            pw.Expanded(child: _buildLineField('Student Name')),

            pw.SizedBox(width: 6),

            pw.Expanded(child: _buildLineField('Student Number')),
          ],
        ),

        pw.SizedBox(height: 5),

        _buildLineField('Section'),
      ],
    );
  }

  static pw.Widget _buildLineField(String label) {
    return pw.Container(
      height: 16,
      padding: const pw.EdgeInsets.symmetric(horizontal: 4),
      decoration: pw.BoxDecoration(border: pw.Border.all(width: 0.8)),
      child: pw.Row(
        children: [
          pw.Text(
            '$label: ',
            style: pw.TextStyle(fontSize: 6, fontWeight: pw.FontWeight.bold),
          ),

          pw.Expanded(
            child: pw.Container(
              decoration: const pw.BoxDecoration(
                border: pw.Border(bottom: pw.BorderSide(width: 0.5)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // --------------------------------------------------------------------------
  // SECTION
  // --------------------------------------------------------------------------

  static pw.Widget _buildSection({
    required Map<String, dynamic> section,
    required String type,
    required List<Map<String, dynamic>> questions,
  }) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Container(
          width: double.infinity,
          height: _sectionTitleHeight,
          alignment: pw.Alignment.centerLeft,
          padding: const pw.EdgeInsets.symmetric(horizontal: 5),
          decoration: pw.BoxDecoration(border: pw.Border.all(width: 0.8)),
          child: pw.Text(
            section['name']?.toString().toUpperCase() ?? 'SECTION',
            style: pw.TextStyle(fontSize: 6.5, fontWeight: pw.FontWeight.bold),
          ),
        ),

        pw.SizedBox(height: 3),

        if (type == 'multiple_choice') _buildMultipleChoice(questions),

        if (type == 'true_false') _buildTrueFalse(questions),

        if (type == 'identification') _buildIdentification(questions),

        pw.SizedBox(height: _sectionSpacing),
      ],
    );
  }

  // --------------------------------------------------------------------------
  // MULTIPLE CHOICE
  // --------------------------------------------------------------------------

  static pw.Widget _buildMultipleChoice(List<Map<String, dynamic>> questions) {
    return _buildOmrGrid(
      questions: questions,
      labels: const ['A', 'B', 'C', 'D'],
    );
  }

  // --------------------------------------------------------------------------
  // TRUE / FALSE
  // --------------------------------------------------------------------------

  static pw.Widget _buildTrueFalse(List<Map<String, dynamic>> questions) {
    return _buildOmrGrid(questions: questions, labels: const ['T', 'F']);
  }

  // --------------------------------------------------------------------------
  // DYNAMIC OMR GRID
  // --------------------------------------------------------------------------

  static pw.Widget _buildOmrGrid({
    required List<Map<String, dynamic>> questions,
    required List<String> labels,
  }) {
    final columns = _calculateOmrColumns(questions.length);

    final rows = <List<Map<String, dynamic>>>[];

    /*
      Distribute questions vertically.

      Example with 10 questions and 2 columns:

      Column 1:
      1
      2
      3
      4
      5

      Column 2:
      6
      7
      8
      9
      10
    */

    final questionsPerColumn = (questions.length / columns).ceil();

    for (int columnIndex = 0; columnIndex < columns; columnIndex++) {
      final start = columnIndex * questionsPerColumn;

      if (start >= questions.length) {
        break;
      }

      final end = (start + questionsPerColumn).clamp(0, questions.length);

      rows.add(questions.sublist(start, end));
    }

    /*
      Calculate the width of the entire OMR block.

      This allows us to center the block when
      there is unused horizontal space.
    */

    final columnWidth =
        _questionNumberWidth + (labels.length * _answerOptionWidth);

    final totalBlockWidth = columnWidth * rows.length;

    return pw.Center(
      child: pw.SizedBox(
        width: totalBlockWidth,
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.center,
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: rows.map((columnQuestions) {
            return pw.SizedBox(
              width: columnWidth,
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: columnQuestions
                    .map(
                      (question) =>
                          _buildOmrRow(question: question, labels: labels),
                    )
                    .toList(),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  // --------------------------------------------------------------------------
  // OMR ROW
  // --------------------------------------------------------------------------

  static pw.Widget _buildOmrRow({
    required Map<String, dynamic> question,
    required List<String> labels,
  }) {
    final number = question['question_number']?.toString() ?? '';

    return pw.SizedBox(
      height: _omrRowHeight,
      child: pw.Row(
        children: [
          pw.SizedBox(
            width: _questionNumberWidth,
            child: pw.Text(
              '$number.',
              style: const pw.TextStyle(fontSize: 6.5),
            ),
          ),

          ...labels.map((label) => _buildOmrBubble(label)),
        ],
      ),
    );
  }

  // --------------------------------------------------------------------------
  // OMR BUBBLE
  // --------------------------------------------------------------------------

  static pw.Widget _buildOmrBubble(String label) {
    /*
      IMPORTANT FOR OMR SCANNING

      Every answer option owns a fixed 23-unit-wide cell.

      The 11 x 11 bubble is EXPLICITLY centered horizontally inside that cell.
      This makes the PDF generator and OMRProcessor use the same deterministic
      bubble-center formula:

        option cell start + (_answerOptionWidth / 2)

      Do not remove this alignment unless the scanner geometry is changed too.
    */
    return pw.SizedBox(
      width: _answerOptionWidth,
      child: pw.Align(
        alignment: pw.Alignment.topCenter,
        child: pw.Column(
          mainAxisSize: pw.MainAxisSize.min,
          crossAxisAlignment: pw.CrossAxisAlignment.center,
          children: [
            pw.Container(
              width: _bubbleSize,
              height: _bubbleSize,
              decoration: pw.BoxDecoration(
                shape: pw.BoxShape.circle,
                border: pw.Border.all(width: 1),
              ),
            ),

            pw.SizedBox(height: 0.5),

            pw.Text(label, style: const pw.TextStyle(fontSize: 5)),
          ],
        ),
      ),
    );
  }

  // --------------------------------------------------------------------------
  // IDENTIFICATION
  // --------------------------------------------------------------------------

  static pw.Widget _buildIdentification(List<Map<String, dynamic>> questions) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: questions.map((question) {
        final number = question['question_number']?.toString() ?? '';

        return pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: _identificationRowSpacing),
          child: pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.center,
            children: [
              pw.SizedBox(
                width: _questionNumberWidth,
                child: pw.Text(
                  '$number.',
                  style: const pw.TextStyle(fontSize: 6.5),
                ),
              ),

              pw.Expanded(
                child: pw.Container(
                  height: _identificationBoxHeight,
                  decoration: pw.BoxDecoration(
                    border: pw.Border.all(width: 0.8),
                  ),
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  // --------------------------------------------------------------------------
  // QR CODE
  // --------------------------------------------------------------------------

  static pw.Widget _buildQrCode(String data) {
    final qrCode = QrCode(4, QrErrorCorrectLevel.M);

    qrCode.addData(data);

    final qrImage = QrImage(qrCode);

    final moduleCount = qrImage.moduleCount;

    return pw.Container(
      width: 45,
      height: 45,
      padding: const pw.EdgeInsets.all(3),
      decoration: pw.BoxDecoration(border: pw.Border.all(width: 0.8)),
      child: pw.CustomPaint(
        size: const PdfPoint(39, 39),
        painter: (PdfGraphics canvas, PdfPoint size) {
          final cellSize = size.x / moduleCount;

          for (int row = 0; row < moduleCount; row++) {
            for (int col = 0; col < moduleCount; col++) {
              if (qrImage.isDark(row, col)) {
                canvas
                  ..setColor(PdfColors.black)
                  ..drawRect(
                    col * cellSize,
                    size.y - ((row + 1) * cellSize),
                    cellSize,
                    cellSize,
                  )
                  ..fillPath();
              }
            }
          }
        },
      ),
    );
  }

  // --------------------------------------------------------------------------
  // REGISTRATION MARKERS
  // --------------------------------------------------------------------------

  /*
    Four fixed black square markers.

    These are intentionally positioned at the four corners
    of the answer sheet using pw.Stack.

    The scanner will eventually detect these four markers
    and use their coordinates for perspective correction.
  */

  static pw.Widget _buildRegistrationMarker() {
    return pw.Container(
      width: _registrationMarkerSize,
      height: _registrationMarkerSize,
      decoration: pw.BoxDecoration(
        color: PdfColors.black,
        border: pw.Border.all(width: 1, color: PdfColors.black),
      ),
    );
  }
}
