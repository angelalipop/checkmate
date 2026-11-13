import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:qr/qr.dart';

import 'answer_sheet_layout.dart';
import 'question_paper_import_service.dart';

class AnswerSheetPdfService {
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

  static const double _omrHeaderHeight = AnswerSheetLayout.omrHeaderHeight;
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
      Sort sections by section_order and id so the answer sheet always matches
      the questionnaire section order.
    */
    final sortedSections = List<Map<String, dynamic>>.from(sections)
      ..sort((a, b) {
        final oa = int.tryParse(a['section_order']?.toString() ?? '') ?? 0;
        final ob = int.tryParse(b['section_order']?.toString() ?? '') ?? 0;
        if (oa != ob) return oa.compareTo(ob);
        final ida = int.tryParse(a['id']?.toString() ?? '') ?? 0;
        final idb = int.tryParse(b['id']?.toString() ?? '') ?? 0;
        return ida.compareTo(idb);
      });

    /*
      Only keep sections that actually contain questions, and normalize section
      headings and continuous question numbers across sections so the Answer
      Sheet and Questionnaire always match.
    */
    final rawActiveSections = <Map<String, dynamic>>[];
    for (final section in sortedSections) {
      final sectionId = int.tryParse(section['id']?.toString() ?? '');
      if (sectionId == null) continue;
      final sectionQuestions = questions[sectionId] ?? [];
      if (sectionQuestions.isEmpty) continue;
      rawActiveSections.add(section);
    }

    final canonicalHeadings =
        QuestionPaperImportService.computeSectionHeadingsForMaps(
          rawActiveSections,
        );

    final activeSections = <Map<String, dynamic>>[];
    final normalizedQuestions = <int, List<Map<String, dynamic>>>{};
    var globalQuestionNumber = 0;

    for (var sIdx = 0; sIdx < rawActiveSections.length; sIdx++) {
      final section = Map<String, dynamic>.from(rawActiveSections[sIdx]);
      final sectionId = int.parse(section['id'].toString());
      final rawName = (section['name']?.toString() ?? '').trim();
      if (sIdx < canonicalHeadings.length &&
          (rawName.isEmpty ||
              RegExp(
                r'^Part\s+[IVX\d]+[\.\:\-\s]',
                caseSensitive: false,
              ).hasMatch(rawName))) {
        section['name'] = canonicalHeadings[sIdx];
      }
      activeSections.add(section);

      final rawQList = questions[sectionId] ?? const <Map<String, dynamic>>[];
      final sortedQs = List<Map<String, dynamic>>.from(rawQList)
        ..sort((a, b) {
          final na = int.tryParse(a['question_number']?.toString() ?? '') ?? 0;
          final nb = int.tryParse(b['question_number']?.toString() ?? '') ?? 0;
          if (na != nb) return na.compareTo(nb);
          final ida = int.tryParse(a['id']?.toString() ?? '') ?? 0;
          final idb = int.tryParse(b['id']?.toString() ?? '') ?? 0;
          return ida.compareTo(idb);
        });

      final numberedQs = <Map<String, dynamic>>[];
      for (final q in sortedQs) {
        globalQuestionNumber++;
        final copy = Map<String, dynamic>.from(q);
        copy['question_number'] = globalQuestionNumber;
        numberedQs.add(copy);
      }
      normalizedQuestions[sectionId] = numberedQs;
    }

    /*
      Build the A5 section layout(s) needed for one student.
    */
    final sheetLayouts = _buildSheetLayouts(
      sections: activeSections,
      questions: normalizedQuestions,
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

    final pages = <List<_StudentSheetItem?>>[];
    var nextSheetNumber = 1;

    if (resolvedStudents.isEmpty) {
      final templates = <_StudentSheetItem>[];

      for (final layout in sheetLayouts) {
        templates.add(
          _StudentSheetItem(
            layout: layout,
            sheetNumber: nextSheetNumber++,
            studentName: '',
            studentNumber: '',
            sectionName: defaultSection,
          ),
        );
      }

      for (int i = 0; i < templates.length; i += 2) {
        pages.add([
          templates[i],
          i + 1 < templates.length ? templates[i + 1] : null,
        ]);
      }
    } else if (sheetLayouts.length == 1) {
      final studentsSheets = <_StudentSheetItem>[];

      for (final student in resolvedStudents) {
        final info = _extractStudentFields(
          student: student,
          fallbackSection: defaultSection,
        );

        studentsSheets.add(
          _StudentSheetItem(
            layout: sheetLayouts.first,
            sheetNumber: nextSheetNumber++,
            studentName: info.fullName,
            studentNumber: info.studentNumber,
            sectionName: info.section,
            studentId: info.studentId,
          ),
        );
      }

      for (int i = 0; i < studentsSheets.length; i += 2) {
        pages.add([
          studentsSheets[i],
          i + 1 < studentsSheets.length ? studentsSheets[i + 1] : null,
        ]);
      }
    } else {
      for (final student in resolvedStudents) {
        final info = _extractStudentFields(
          student: student,
          fallbackSection: defaultSection,
        );

        final studentSheets = <_StudentSheetItem>[];

        for (final layout in sheetLayouts) {
          studentSheets.add(
            _StudentSheetItem(
              layout: layout,
              sheetNumber: nextSheetNumber++,
              studentName: info.fullName,
              studentNumber: info.studentNumber,
              sectionName: info.section,
              studentId: info.studentId,
            ),
          );
        }

        for (int i = 0; i < studentSheets.length; i += 2) {
          pages.add([
            studentSheets[i],
            i + 1 < studentSheets.length ? studentSheets[i + 1] : null,
          ]);
        }
      }
    }

    final a4Landscape = PdfPageFormat.a4.landscape;
    final halfPageWidth = a4Landscape.width / 2.0;
    final fullPageHeight = a4Landscape.height;

    for (final pageItems in pages) {
      final leftItem = pageItems[0];
      final rightItem = pageItems[1];

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
                          questions: normalizedQuestions,
                          item: leftItem!,
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
                                questions: normalizedQuestions,
                                item: rightItem,
                              ),
                            ),
                    ),
                  ],
                ),
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
    final source =
        students ??
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
      studentNumber: studentNumber.toUpperCase(),
      fullName: fullName.toUpperCase(),
      section: section.toUpperCase(),
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
    return AnswerSheetLayout.firstSectionY;
  }

  static double _usableSheetHeight() {
    return AnswerSheetLayout.sheetHeight - AnswerSheetLayout.sheetPadding - 18;
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

    final content = pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        _buildHeader(exam: exam, examId: examId, sheetNumber: item.sheetNumber),

        pw.SizedBox(height: 3),

        _buildStudentInformation(
          studentName: item.studentName,
          studentNumber: item.studentNumber,
          sectionName: item.sectionName,
        ),

        pw.SizedBox(height: 4),

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

          pw.Positioned(
            left: _registrationMarkerInset,
            top: _registrationMarkerInset,
            child: _buildRegistrationMarker(),
          ),

          pw.Positioned(
            right: _registrationMarkerInset,
            top: _registrationMarkerInset,
            child: _buildRegistrationMarker(),
          ),

          pw.Positioned(
            left: _registrationMarkerInset,
            bottom: _registrationMarkerInset,
            child: _buildRegistrationMarker(),
          ),

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

    final classes = exam['header_classes'] is List
        ? (exam['header_classes'] as List).whereType<Map>().toList()
        : <Map>[];

    final subjects = exam['header_subjects'] is List
        ? (exam['header_subjects'] as List).whereType<Map>().toList()
        : <Map>[];

    final subjectNames = subjects
        .map((subject) => subject['name']?.toString().trim() ?? '')
        .where((name) => name.isNotEmpty)
        .toSet()
        .join(', ');
    final sections = classes
        .map((classItem) => classItem['section']?.toString().trim() ?? '')
        .where((section) => section.isNotEmpty)
        .toSet()
        .join(', ');

    final schoolYears = classes
        .map((classItem) => classItem['school_year']?.toString().trim() ?? '')
        .where((year) => year.isNotEmpty)
        .toSet()
        .join(', ');
    final semesters = classes
        .map((classItem) => classItem['semester']?.toString().trim() ?? '')
        .where((semester) => semester.isNotEmpty)
        .toSet()
        .join(', ');
    return pw.SizedBox(
      height: 55,
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
                if (subjectNames.isNotEmpty)
                  pw.Text(
                    'Subject: $subjectNames',
                    style: const pw.TextStyle(fontSize: 6),
                    maxLines: 1,
                  ),
                if (schoolYears.isNotEmpty)
                  pw.Text(
                    'School Year: $schoolYears',
                    style: const pw.TextStyle(fontSize: 6),
                    maxLines: 1,
                  ),
                if (semesters.isNotEmpty)
                  pw.Text(
                    'Semester: $semesters',
                    style: const pw.TextStyle(fontSize: 6),
                    maxLines: 1,
                  ),
                pw.Text(
                  'Exam ID: $examId  |  Sheet $sheetNumber',
                  style: const pw.TextStyle(fontSize: 6),
                ),
                //pw.Text(sheetId, style: const pw.TextStyle(fontSize: 4.5)),
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
        _buildLineField('STUDENT NAME', value: studentName),

        pw.SizedBox(height: 3),

        pw.Row(
          children: [
            pw.Expanded(
              child: _buildLineField('STUDENT NUMBER', value: studentNumber),
            ),

            pw.SizedBox(width: 6),

            pw.Expanded(child: _buildLineField('SECTION', value: sectionName)),
          ],
        ),
      ],
    );
  }

  static pw.Widget _buildLineField(String label, {String value = ''}) {
    final cleanValue = value.trim().toUpperCase();
    return pw.Container(
      height: 20,
      padding: const pw.EdgeInsets.symmetric(horizontal: 4),
      decoration: pw.BoxDecoration(border: pw.Border.all(width: 0.8)),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: [
          pw.Text(
            '$label: ',
            style: pw.TextStyle(fontSize: 7, fontWeight: pw.FontWeight.bold),
          ),

          pw.Expanded(
            child: pw.Container(
              height: 15,
              alignment: pw.Alignment.bottomLeft,
              padding: const pw.EdgeInsets.only(bottom: 1),
              decoration: const pw.BoxDecoration(
                border: pw.Border(bottom: pw.BorderSide(width: 0.5)),
              ),
              child: cleanValue.isEmpty
                  ? null
                  : pw.Text(
                      cleanValue,
                      style: pw.TextStyle(
                        fontSize: 10,
                        fontWeight: pw.FontWeight.bold,
                      ),
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
            section['name']?.toString() ?? 'Section',
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
                children: [
                  pw.SizedBox(
                    height: _omrHeaderHeight,
                    child: pw.Row(
                      children: [
                        pw.SizedBox(width: _questionNumberWidth),
                        ...labels.map(
                          (label) => pw.SizedBox(
                            width: _answerOptionWidth,
                            child: pw.Center(
                              child: pw.Text(
                                label,
                                style: pw.TextStyle(
                                  fontSize: 6,
                                  fontWeight: pw.FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  ...columnQuestions.map(
                    (question) =>
                        _buildOmrRow(question: question, labels: labels),
                  ),
                ],
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
    return pw.SizedBox(
      width: _answerOptionWidth,
      child: pw.Align(
        alignment: pw.Alignment.topCenter,
        child: pw.Container(
          width: _bubbleSize,
          height: _bubbleSize,
          decoration: pw.BoxDecoration(
            shape: pw.BoxShape.circle,
            border: pw.Border.all(width: 1),
          ),
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
      padding: const pw.EdgeInsets.all(2.2),
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
