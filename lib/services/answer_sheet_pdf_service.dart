import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:qr/qr.dart';

import 'answer_sheet_layout.dart';

class AnswerSheetPdfService {
  /*
    --------------------------------------------------------------------------
    CHECKMATE DYNAMIC ANSWER SHEET (TWO A5 SHEETS PER A4 LANDSCAPE PAGE)
    --------------------------------------------------------------------------

    Main goals:

    1. Use as little paper as reasonably possible.
    2. Keep OMR bubbles at a fixed physical size.
    3. Allow MC and True/False to use multiple columns.
    4. Keep Identification as wider OCR writing boxes.
    5. Dynamically create additional A5 sheets only when necessary.
    6. Put two independent A5 portrait sheets side by side on one A4 landscape
       page for printing, with a subtle vertical center cutting guide so the
       printed A4 page can be cut vertically into two separate A5 sheets.
    7. Automatically populate Student Name, Student Number, and Section for all
       assigned students of the assessment (across single or multiple sections).
    8. Give every student sheet a unique QR/sheet identifier.
    9. Preserve the exact 397 x 559 logical A5 coordinate system and four fixed
       corner registration markers so separated A5 sheets work seamlessly with
       the existing OMR and Azure OCR pipelines.

    --------------------------------------------------------------------------
  */

  // --------------------------------------------------------------------------
  // A5-STYLE SHEET DIMENSIONS
  // --------------------------------------------------------------------------

  static const double _sheetWidth = AnswerSheetLayout.sheetWidth;
  static const double _sheetHeight = AnswerSheetLayout.sheetHeight;

  static const double _sheetPadding = AnswerSheetLayout.sheetPadding;

  // --------------------------------------------------------------------------
  // REGISTRATION MARKERS
  // --------------------------------------------------------------------------

  static const double _registrationMarkerSize =
      AnswerSheetLayout.registrationMarkerSize;

  static const double _registrationMarkerInset =
      AnswerSheetLayout.registrationMarkerInset;

  // --------------------------------------------------------------------------
  // OMR SETTINGS
  // --------------------------------------------------------------------------

  static const double _bubbleSize = AnswerSheetLayout.bubbleSize;

  static const double _answerOptionWidth = AnswerSheetLayout.answerOptionWidth;

  static const double _questionNumberWidth =
      AnswerSheetLayout.questionNumberWidth;

  static const double _omrRowHeight = AnswerSheetLayout.omrRowHeight;

  // --------------------------------------------------------------------------
  // IDENTIFICATION SETTINGS
  // --------------------------------------------------------------------------

  static const double _identificationBoxHeight =
      AnswerSheetLayout.identificationBoxHeight;

  static const double _identificationRowSpacing =
      AnswerSheetLayout.identificationRowSpacing;

  // --------------------------------------------------------------------------
  // SPACING
  // --------------------------------------------------------------------------

  static const double _sectionTitleHeight =
      AnswerSheetLayout.sectionTitleHeight;

  static const double _sectionSpacing = AnswerSheetLayout.sectionSpacing;

  // --------------------------------------------------------------------------
  // MAIN PDF GENERATOR
  // --------------------------------------------------------------------------

  static Future<Uint8List> generate({
    required Map<String, dynamic> exam,
    required List<Map<String, dynamic>> sections,
    required Map<int, List<Map<String, dynamic>>> questions,
    List<Map<String, dynamic>>? students,
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
      Build the A5 section layout(s) needed for one student.
    */
    final sheetLayouts = _buildSheetLayouts(
      sections: activeSections,
      questions: questions,
    );

    /*
      If there are no questions yet, still generate one sheet template per student.
    */
    if (sheetLayouts.isEmpty) {
      sheetLayouts.add([]);
    }

    /*
      Resolve assigned students from the explicit [students] parameter or from
      `exam['students']` if embedded in the exam object.
    */
    final resolvedStudents = _resolveStudents(exam: exam, students: students);
    final defaultSection = _resolveDefaultSection(exam);

    /*
      Build the ordered list of individual A5 portrait sheets to print.
      - When students are assigned: each student receives their own A5 sheet(s)
        populated with their Student Name, Student Number, and Section, and a
        unique sequential sheetNumber / QR code.
      - Page 1: Student 1 on the left, Student 2 on the right.
      - Page 2: Student 3 on the left, Student 4 on the right.
      - Odd final student: positioned on the left, right side left blank.
    */
    final individualSheets = <_StudentSheetItem>[];
    var nextSheetNumber = 1;

    if (resolvedStudents.isEmpty) {
      for (final layout in sheetLayouts) {
        individualSheets.add(
          _StudentSheetItem(
            layout: layout,
            sheetNumber: nextSheetNumber++,
            studentName: '',
            studentNumber: '',
            sectionName: defaultSection,
          ),
        );
      }
    } else {
      for (final student in resolvedStudents) {
        final studentInfo = _extractStudentFields(
          student: student,
          fallbackSection: defaultSection,
        );

        for (final layout in sheetLayouts) {
          individualSheets.add(
            _StudentSheetItem(
              layout: layout,
              sheetNumber: nextSheetNumber++,
              studentName: studentInfo.fullName,
              studentNumber: studentInfo.studentNumber,
              sectionName: studentInfo.section,
              studentId: studentInfo.studentId,
            ),
          );
        }
      }
    }

    final a4Landscape = PdfPageFormat.a4.landscape;
    final halfPageWidth = a4Landscape.width / 2.0;
    final fullPageHeight = a4Landscape.height;

    /*
      Two A5 portrait sheets side by side horizontally on one A4 landscape page.
      Each A5 half of the A4 landscape sheet is 148.5 mm x 210 mm
      (420.945 pt x 595.28 pt), and centers the exact 397.0 x 559.0 pt
      answer sheet template without scaling.
    */
    for (int index = 0; index < individualSheets.length; index += 2) {
      final leftItem = individualSheets[index];
      final rightItem = index + 1 < individualSheets.length
          ? individualSheets[index + 1]
          : null;

      pdf.addPage(
        pw.Page(
          pageFormat: a4Landscape,
          margin: pw.EdgeInsets.zero,
          build: (context) {
            return pw.Stack(
              children: [
                pw.Row(
                  crossAxisAlignment: pw.CrossAxisAlignment.center,
                  children: [
                    pw.SizedBox(
                      width: halfPageWidth,
                      height: fullPageHeight,
                      child: pw.Center(
                        child: _buildAnswerSheet(
                          exam: exam,
                          sections: activeSections,
                          questions: questions,
                          item: leftItem,
                        ),
                      ),
                    ),
                    pw.SizedBox(
                      width: halfPageWidth,
                      height: fullPageHeight,
                      child: rightItem == null
                          ? pw.SizedBox()
                          : pw.Center(
                              child: _buildAnswerSheet(
                                exam: exam,
                                sections: activeSections,
                                questions: questions,
                                item: rightItem,
                              ),
                            ),
                    ),
                  ],
                ),
                // Vertical center cutting guide along the exact A4 center line
                // (x = 420.945 pt), ~12 pt outside both 397x559 A5 sheet borders
                // so it never touches borders, registration marks, QR codes,
                // or OMR bubbles.
                pw.Positioned(
                  left: halfPageWidth - 0.25,
                  top: 0,
                  bottom: 0,
                  child: _buildCenterCuttingGuide(fullPageHeight),
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
  // STUDENT INFORMATION EXTRACTION
  // --------------------------------------------------------------------------

  static List<Map<String, dynamic>> _resolveStudents({
    required Map<String, dynamic> exam,
    List<Map<String, dynamic>>? students,
  }) {
    final source = students ??
        (exam['students'] is List
            ? (exam['students'] as List)
                  .whereType<Map>()
                  .map((s) => Map<String, dynamic>.from(s))
                  .toList()
            : const <Map<String, dynamic>>[]);

    if (source.isEmpty) return const <Map<String, dynamic>>[];

    final copy = List<Map<String, dynamic>>.from(source);
    copy.sort((a, b) {
      final secA = _studentSection(a).toLowerCase();
      final secB = _studentSection(b).toLowerCase();
      final cmpSec = secA.compareTo(secB);
      if (cmpSec != 0) return cmpSec;

      final lastA = _cleanText(a['last_name']).toLowerCase();
      final lastB = _cleanText(b['last_name']).toLowerCase();
      final cmpLast = lastA.compareTo(lastB);
      if (cmpLast != 0) return cmpLast;

      final firstA = _cleanText(a['first_name']).toLowerCase();
      final firstB = _cleanText(b['first_name']).toLowerCase();
      final cmpFirst = firstA.compareTo(firstB);
      if (cmpFirst != 0) return cmpFirst;

      final numA = _cleanText(a['student_number']).toLowerCase();
      final numB = _cleanText(b['student_number']).toLowerCase();
      return numA.compareTo(numB);
    });

    return copy;
  }

  static String _resolveDefaultSection(Map<String, dynamic> exam) {
    final cls = exam['class'];
    if (cls is Map) {
      final s = _cleanText(cls['section']);
      if (s.isNotEmpty) return s;
    }
    return _cleanText(exam['section']);
  }

  static String _studentSection(Map<String, dynamic> student) {
    final direct = _cleanText(student['section']);
    if (direct.isNotEmpty) return direct;
    final cls = student['class'];
    if (cls is Map) {
      return _cleanText(cls['section']);
    }
    return '';
  }

  static String _cleanText(Object? raw) {
    final s = (raw?.toString() ?? '').trim();
    if (s.toLowerCase() == 'null') return '';
    return s;
  }

  static _ExtractedStudent _extractStudentFields({
    required Map<String, dynamic> student,
    required String fallbackSection,
  }) {
    final studentId = _cleanText(student['id']);
    final studentNumber = _cleanText(student['student_number']);
    final firstName = _cleanText(student['first_name']);
    final lastName = _cleanText(student['last_name']);
    final explicitFullName = _cleanText(
      student['full_name'] ?? student['student_name'] ?? student['name'],
    );

    String fullName;
    if (firstName.isNotEmpty && lastName.isNotEmpty) {
      fullName = '$lastName, $firstName';
    } else if (lastName.isNotEmpty) {
      fullName = lastName;
    } else if (firstName.isNotEmpty) {
      fullName = firstName;
    } else {
      fullName = explicitFullName;
    }

    var section = _studentSection(student);
    if (section.isEmpty) {
      section = fallbackSection;
    }

    return _ExtractedStudent(
      studentId: studentId,
      studentNumber: studentNumber,
      fullName: fullName,
      section: section,
    );
  }

  // --------------------------------------------------------------------------
  // CENTER CUTTING GUIDE
  // --------------------------------------------------------------------------

  static pw.Widget _buildCenterCuttingGuide(double pageHeight) {
    return pw.CustomPaint(
      size: PdfPoint(0.5, pageHeight),
      painter: (PdfGraphics canvas, PdfPoint size) {
        const dashLength = 4.0;
        const gapLength = 4.0;
        canvas
          ..setStrokeColor(PdfColors.grey500)
          ..setLineWidth(0.5);

        var y = 6.0;
        while (y < size.y - 6.0) {
          final nextY = (y + dashLength).clamp(0.0, size.y - 6.0);
          canvas
            ..moveTo(0.25, y)
            ..lineTo(0.25, nextY)
            ..strokePath();
          y += dashLength + gapLength;
        }
      },
    );
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
    return 97;
  }

  static double _usableSheetHeight() {
    return _sheetHeight - (_sheetPadding * 2) - 18;
  }

  // --------------------------------------------------------------------------
  // SECTION HEIGHT CALCULATION
  // --------------------------------------------------------------------------

  static double _calculateSectionHeight({
    required String type,
    required int questionCount,
  }) {
    return AnswerSheetLayout.calculateSectionHeight(
      type: type,
      questionCount: questionCount,
    );
  }

  // --------------------------------------------------------------------------
  // OMR COLUMN CALCULATION
  // --------------------------------------------------------------------------

  static int _calculateOmrColumns(int questionCount) {
    return AnswerSheetLayout.calculateOmrColumns(questionCount);
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
    required _StudentSheetItem item,
  }) {
    final examId = exam['id']?.toString() ?? '';

    /*
      Main answer-sheet content.

      Registration markers are NOT part of this Column.
      They are positioned independently using Stack.
      Header + student information + gaps consume exactly 95 logical units
      after sheetPadding (10), so the first section always begins at Y = 105.0.
    */
    final content = pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        _buildHeader(
          exam: exam,
          examId: examId,
          sheetNumber: item.sheetNumber,
        ),

        pw.SizedBox(height: 6),

        _buildStudentInformation(
          studentName: item.studentName,
          studentNumber: item.studentNumber,
          sectionName: item.sectionName,
        ),

        pw.SizedBox(height: 7),

        /*
          Render only the sections assigned
          to this particular sheet.
        */
        ...sections
            .where((section) {
              final sectionId = int.tryParse(section['id']?.toString() ?? '');

              return sectionId != null && item.layout.contains(sectionId);
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

        pw.Spacer(),
      ],
    );

    return pw.Container(
      width: _sheetWidth,
      height: _sheetHeight,
      decoration: pw.BoxDecoration(border: pw.Border.all(width: 1)),
      child: pw.Stack(
        children: [
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

    return pw.SizedBox(
      height: 45,
      child: pw.Row(
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
                  maxLines: 1,
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
      ),
    );
  }

  // --------------------------------------------------------------------------
  // STUDENT INFORMATION
  // --------------------------------------------------------------------------

  static pw.Widget _buildStudentInformation({
    required String studentName,
    required String studentNumber,
    required String sectionName,
  }) {
    return pw.Column(
      children: [
        pw.Row(
          children: [
            pw.Expanded(
              child: _buildLineField('Student Name', value: studentName),
            ),

            pw.SizedBox(width: 6),

            pw.Expanded(
              child: _buildLineField('Student Number', value: studentNumber),
            ),
          ],
        ),

        pw.SizedBox(height: 5),

        _buildLineField('Section', value: sectionName),
      ],
    );
  }

  static pw.Widget _buildLineField(String label, {String value = ''}) {
    final cleanValue = value.trim();
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
              height: 11,
              alignment: pw.Alignment.bottomLeft,
              padding: const pw.EdgeInsets.only(bottom: 1),
              decoration: const pw.BoxDecoration(
                border: pw.Border(bottom: pw.BorderSide(width: 0.5)),
              ),
              child: cleanValue.isEmpty
                  ? null
                  : pw.Text(
                      cleanValue,
                      style: const pw.TextStyle(fontSize: 6),
                      maxLines: 1,
                      overflow: pw.TextOverflow.clip,
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

        pw.SizedBox(height: AnswerSheetLayout.sectionTitleGap),

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

    final questionsPerColumn = (questions.length / columns).ceil();

    for (int columnIndex = 0; columnIndex < columns; columnIndex++) {
      final start = columnIndex * questionsPerColumn;

      if (start >= questions.length) {
        break;
      }

      final end = (start + questionsPerColumn).clamp(0, questions.length);

      rows.add(questions.sublist(start, end));
    }

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
    final qrCode = QrCode.fromData(
      data: data,
      errorCorrectLevel: QrErrorCorrectLevel.M,
    );

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

class _ExtractedStudent {
  const _ExtractedStudent({
    required this.studentId,
    required this.studentNumber,
    required this.fullName,
    required this.section,
  });

  final String studentId;
  final String studentNumber;
  final String fullName;
  final String section;
}

class _StudentSheetItem {
  const _StudentSheetItem({
    required this.layout,
    required this.sheetNumber,
    required this.studentName,
    required this.studentNumber,
    required this.sectionName,
    this.studentId = '',
  });

  final List<int> layout;
  final int sheetNumber;
  final String studentName;
  final String studentNumber;
  final String sectionName;
  final String studentId;
}
