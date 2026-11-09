import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'assessment_validator.dart';
import 'sti_logo_data.dart';

/// Shared layout model and generator for CheckMate STI College Questionnaires.
///
/// Supports two distinct STI College assessment layouts based on the uploaded
/// reference documents:
/// 1. Major Examinations (`prelim`, `midterm`, `prefinal`/`pre_finals`, `final`/`finals`)
///    following `Information Assurance and Security Exam.docx`.
/// 2. Quizzes (`quiz`, `short_quiz`, `long_quiz`, `other`)
///    following `Information Assurance and Security Quiz.docx`.
///
/// Both the on-screen preview / printable PDF ([generate]) and the Microsoft
/// Word document ([generateDocx]) are rendered from the exact same
/// [_QuestionPaperPlan] so pagination, column arrangement, headers, notices,
/// and questions are 100% consistent.
class QuestionPaperPdfService {
  QuestionPaperPdfService._();

  // Exact reference document page dimensions (8.50 in x 13.00 in) and margins
  // from Information Assurance and Security Exam.docx & Quiz.docx:
  // top = 0.65 in (46.8 pt), bottom = 0.50 in (36.0 pt),
  // left = 0.27 in (19.44 pt), right = 0.27 in (19.44 pt).
  static const PdfPageFormat pageFormat = PdfPageFormat(
    8.5 * PdfPageFormat.inch,
    13.0 * PdfPageFormat.inch,
  );

  static const double marginTop = 0.65 * PdfPageFormat.inch; // 46.8 pt
  static const double marginBottom = 0.50 * PdfPageFormat.inch; // 36.0 pt
  static const double marginLeft = 0.27 * PdfPageFormat.inch; // 19.44 pt
  static const double marginRight = 0.27 * PdfPageFormat.inch; // 19.44 pt

  static const List<String> defaultNoticeBullets = <String>[
    'Any form of cheating will result in a score of ZERO. (e.g. leaking of exam items and answers on social media, copying from other students, using prohibited resources/cheat sheets, etc.)',
    'Use BLACK pen only. Pencils and erasable pens are NOT ALLOWED.',
    'Changing of answers for Multiple Choice is NOT ALLOWED.',
    'CALCULATORS may be used for computation-based items.',
    'Mobile phone calculators and calculator sharing are strictly prohibited.',
  ];

  static const String defaultMultipleChoiceInstruction =
      'Read and analyze each item. Choose the letter of the CORRECT answer.';

  /// Default pre-filled text for the Instructions box in Edit Exam Details.
  static const String defaultInstructionsText =
      'Notice:\n'
      '\u2022 Any form of cheating will result in a score of ZERO. (e.g. leaking of exam items and answers on social media, copying from other students, using prohibited resources/cheat sheets, etc.)\n'
      '\u2022 Use BLACK pen only. Pencils and erasable pens are NOT ALLOWED.\n'
      '\u2022 Changing of answers for Multiple Choice is NOT ALLOWED.\n'
      '\u2022 CALCULATORS may be used for computation-based items.\n'
      '\u2022 Mobile phone calculators and calculator sharing are strictly prohibited.\n\n'
      'Read and analyze each item. Choose the letter of the CORRECT answer.';

  /// Normalizes Unicode punctuation (en-dash, em-dash, curly quotes, bullets,
  /// ellipses, non-breaking spaces, etc.) into standard Latin-1 / ASCII
  /// characters supported by built-in PDF Type1 fonts (`Times` and `Helvetica`)
  /// so preview and print never render boxed tofu characters (`☒`).
  static String _sanitizePdfText(String input) {
    if (input.isEmpty) return input;
    return input
        // Dashes & minus signs -> standard hyphen-minus
        .replaceAll(
          RegExp(r'[\u2010\u2011\u2012\u2013\u2014\u2015\u2212\uFE58\uFE63\uFF0D]'),
          '-',
        )
        // Bullets & middle dots in plain text -> hyphen or middot
        .replaceAll(RegExp(r'[\u2022\u2023\u25E6\u2043\u2219\u25AA\u25CF]'), '-')
        // Smart single quotes / primes -> straight apostrophe
        .replaceAll(RegExp(r'[\u2018\u2019\u201A\u201B\u2032\u02BC]'), "'")
        // Smart double quotes / double primes -> straight quote
        .replaceAll(RegExp(r'[\u201C\u201D\u201E\u201F\u2033]'), '"')
        // Ellipsis -> three dots
        .replaceAll('\u2026', '...')
        // Non-breaking and special spaces -> standard space
        .replaceAll(RegExp(r'[\u00A0\u2000-\u200A\u202F\u205F\u3000]'), ' ')
        // Zero-width characters -> remove
        .replaceAll(RegExp(r'[\u200B-\u200D\uFEFF]'), '');
  }

  /// Generates the assessment-specific Questionnaire PDF bytes used by both
  /// `PdfPreview` (in the Paper Preview modal/screen) and `Printing.layoutPdf`.
  static Future<Uint8List> generate({
    required Map<String, dynamic> exam,
    required List<Map<String, dynamic>> sections,
    required Map<int, List<Map<String, dynamic>>> questions,
  }) async {
    final plan = _buildLayoutPlan(
      exam: exam,
      sections: sections,
      questions: questions,
    );

    final pdf = pw.Document();
    final logoImage = pw.MemoryImage(StiLogoData.bytes);
    final timesFont = pw.Font.times();
    final timesBoldFont = pw.Font.timesBold();
    final arialFont = pw.Font.helvetica();
    final arialBoldFont = pw.Font.helveticaBold();

    for (var pageIdx = 0; pageIdx < plan.pages.length; pageIdx++) {
      final pageData = plan.pages[pageIdx];
      final pageNumber = pageIdx + 1;

      pdf.addPage(
        pw.Page(
          pageFormat: pageFormat,
          margin: const pw.EdgeInsets.only(
            top: marginTop,
            bottom: marginBottom,
            left: marginLeft,
            right: marginRight,
          ),
          build: (context) {
            return pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.stretch,
              children: [
                _buildPdfHeaderTable(
                  meta: plan.meta,
                  pageNumber: pageNumber,
                  logoImage: logoImage,
                  timesFont: timesFont,
                  timesBoldFont: timesBoldFont,
                  arialBoldFont: arialBoldFont,
                ),
                pw.SizedBox(height: 3),
                pw.Container(
                  width: double.infinity,
                  height: 0.8,
                  color: PdfColors.black,
                ),
                pw.SizedBox(height: 3),
                _buildPdfStudentInfoRow(arialBoldFont: arialBoldFont),
                pw.SizedBox(height: 6),
                pw.Expanded(
                  child: pw.Row(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Expanded(
                        child: pw.Padding(
                          padding: const pw.EdgeInsets.only(right: 8),
                          child: pw.Column(
                            crossAxisAlignment: pw.CrossAxisAlignment.start,
                            children: pageData.leftColumn
                                .map(
                                  (block) => _buildPdfBlock(
                                    block,
                                    arialFont: arialFont,
                                    arialBoldFont: arialBoldFont,
                                  ),
                                )
                                .toList(),
                          ),
                        ),
                      ),
                      pw.Expanded(
                        child: pw.Padding(
                          padding: const pw.EdgeInsets.only(left: 8),
                          child: pw.Column(
                            crossAxisAlignment: pw.CrossAxisAlignment.start,
                            children: pageData.rightColumn
                                .map(
                                  (block) => _buildPdfBlock(
                                    block,
                                    arialFont: arialFont,
                                    arialBoldFont: arialBoldFont,
                                  ),
                                )
                                .toList(),
                          ),
                        ),
                      ),
                    ],
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

  /// Generates a Microsoft Word (`.docx`) Questionnaire using the exact same
  /// assessment-specific [_QuestionPaperPlan] as [generate], preserving
  /// identical pages, columns, STI College logo, typography, and tables.
  static Future<Uint8List> generateDocx({
    required Map<String, dynamic> exam,
    required List<Map<String, dynamic>> sections,
    required Map<int, List<Map<String, dynamic>>> questions,
  }) async {
    final plan = _buildLayoutPlan(
      exam: exam,
      sections: sections,
      questions: questions,
    );

    final archive = Archive();

    void addUtf8File(String path, String content) {
      final bytes = utf8.encode(content);
      archive.addFile(ArchiveFile(path, bytes.length, bytes));
    }

    final logoBytes = StiLogoData.bytes;
    archive.addFile(
      ArchiveFile('word/media/image1.png', logoBytes.length, logoBytes),
    );

    addUtf8File('[Content_Types].xml', _docxContentTypesXml);
    addUtf8File('_rels/.rels', _docxRootRelsXml);
    addUtf8File('word/_rels/document.xml.rels', _docxDocumentRelsXml);
    addUtf8File('word/styles.xml', _docxStylesXml);
    addUtf8File('word/document.xml', _buildDocxDocumentXml(plan));

    final encoded = ZipEncoder().encode(archive);
    return Uint8List.fromList(encoded);
  }

  // ===========================================================================
  // METADATA EXTRACTION & SHARED PAGINATION PLANNER
  // ===========================================================================

  static _QuestionPaperPlan _buildLayoutPlan({
    required Map<String, dynamic> exam,
    required List<Map<String, dynamic>> sections,
    required Map<int, List<Map<String, dynamic>>> questions,
  }) {
    final meta = _extractMetadata(
      exam: exam,
      sections: sections,
      questions: questions,
    );

    // Sort sections by section_order, id
    final sortedSections = List<Map<String, dynamic>>.from(sections)
      ..sort((a, b) {
        final oa = int.tryParse(a['section_order']?.toString() ?? '') ?? 0;
        final ob = int.tryParse(b['section_order']?.toString() ?? '') ?? 0;
        if (oa != ob) return oa.compareTo(ob);
        final ida = int.tryParse(a['id']?.toString() ?? '') ?? 0;
        final idb = int.tryParse(b['id']?.toString() ?? '') ?? 0;
        return ida.compareTo(idb);
      });

    // Determine active sections & their questions
    final activeSections = <Map<String, dynamic>>[];
    for (final s in sortedSections) {
      final sid = int.tryParse(s['id']?.toString() ?? '');
      if (sid == null) continue;
      final qList = questions[sid] ?? const <Map<String, dynamic>>[];
      if (qList.isEmpty) continue;
      activeSections.add(s);
    }

    final firstSectionType = activeSections.isNotEmpty
        ? AssessmentValidator.normalizeQuestionType(
            activeSections.first['question_type']?.toString() ??
                activeSections.first['type']?.toString(),
          )
        : '';

    final blocks = <_PaperBlock>[];

    // 1. Notice & general examination instructions block at the start of Page 1 Col 1
    final parsedNotice = _parseNoticeAndInstructions(
      meta.customInstructions,
      stripDefaultMcInstruction: firstSectionType == 'multiple_choice',
    );
    blocks.add(
      _PaperBlock.notice(
        showNoticeHeading: parsedNotice.showNoticeHeading,
        bullets: parsedNotice.bullets,
        customInstructions: parsedNotice.extraText,
        estimatedHeight: _estimateNoticeHeight(
          parsedNotice.showNoticeHeading,
          parsedNotice.bullets,
          parsedNotice.extraText,
        ),
      ),
    );

    // 2. Active sections & their questions (strictly ordered by question_number)
    var globalQuestionNumber = 0;

    for (var sIdx = 0; sIdx < activeSections.length; sIdx++) {
      final section = activeSections[sIdx];
      final sid = int.parse(section['id'].toString());
      final qType = AssessmentValidator.normalizeQuestionType(
        section['question_type']?.toString() ?? section['type']?.toString(),
      );
      final rawSectionQuestions =
          questions[sid] ?? const <Map<String, dynamic>>[];
      final sectionQuestions =
          List<Map<String, dynamic>>.from(rawSectionQuestions)..sort((a, b) {
            final na = int.tryParse(a['question_number']?.toString() ?? '') ?? 0;
            final nb = int.tryParse(b['question_number']?.toString() ?? '') ?? 0;
            if (na != nb) return na.compareTo(nb);
            final ida = int.tryParse(a['id']?.toString() ?? '') ?? 0;
            final idb = int.tryParse(b['id']?.toString() ?? '') ?? 0;
            return ida.compareTo(idb);
          });

      final sectionLetter = String.fromCharCode(65 + (sIdx % 26));
      final instructionText = _instructionForQuestionType(
        qType,
        sectionName: section['name']?.toString(),
      );
      final pointsSummary = _buildSectionPointsHeader(
        sectionLetter: sectionLetter,
        section: section,
        questions: sectionQuestions,
      );

      final headerBlock = _PaperBlock.sectionHeader(
        instructionText: instructionText,
        pointsHeader: pointsSummary,
        estimatedHeight: _estimateSectionHeaderHeight(
          instructionText,
          pointsSummary,
        ),
      );
      blocks.add(headerBlock);

      for (var qIdx = 0; qIdx < sectionQuestions.length; qIdx++) {
        globalQuestionNumber++;
        final q = sectionQuestions[qIdx];
        final displayNumber = activeSections.length == 1
            ? (int.tryParse(q['question_number']?.toString() ?? '') ??
                  (qIdx + 1))
            : globalQuestionNumber;

        final qText = (q['question_text']?.toString() ?? '').trim();
        final rawChoices = q['choices'];
        final choices = <String>[];
        if (qType == 'multiple_choice' && rawChoices is List) {
          for (final c in rawChoices) {
            final cleanChoice = c?.toString().trim() ?? '';
            if (cleanChoice.isNotEmpty) {
              choices.add(cleanChoice);
            }
          }
        }

        blocks.add(
          _PaperBlock.question(
            questionNumber: displayNumber,
            questionText: qText,
            questionType: qType,
            choices: choices,
            isFirstInColumn: false,
            estimatedHeight: _estimateQuestionHeight(
              questionText: qText,
              questionType: qType,
              choices: choices,
            ),
          ),
        );
      }
    }

    // Available height per column on each 8.5 x 13.0 page:
    // Page height = 936 pt
    // Margins = 46.8 + 36.0 = 82.8 pt -> usable height = 853.2 pt
    // Header table + divider + Student Info row = ~98 pt
    // Remaining column height = ~742 pt
    const maxColumnHeight = 735.0;

    final pages = <_QuestionPaperPage>[];
    var currentLeft = <_PaperBlock>[];
    var currentRight = <_PaperBlock>[];
    var fillingLeft = true;
    var usedHeight = 0.0;

    void advanceColumn() {
      if (fillingLeft) {
        fillingLeft = false;
        usedHeight = 0.0;
      } else {
        pages.add(
          _QuestionPaperPage(
            leftColumn: currentLeft,
            rightColumn: currentRight,
          ),
        );
        currentLeft = <_PaperBlock>[];
        currentRight = <_PaperBlock>[];
        fillingLeft = true;
        usedHeight = 0.0;
      }
    }

    for (var i = 0; i < blocks.length; i++) {
      final block = blocks[i];
      var neededHeight = block.estimatedHeight;

      // Keep a section header together with the first question after it
      // whenever possible so the header is never orphaned at column bottom.
      if (block.kind == _BlockKind.sectionHeader && i + 1 < blocks.length) {
        neededHeight += blocks[i + 1].estimatedHeight;
      }

      final activeList = fillingLeft ? currentLeft : currentRight;
      if (activeList.isNotEmpty && usedHeight + neededHeight > maxColumnHeight) {
        advanceColumn();
      }

      final targetList = fillingLeft ? currentLeft : currentRight;
      final placedBlock = block.copyWith(isFirstInColumn: targetList.isEmpty);
      targetList.add(placedBlock);
      usedHeight += placedBlock.estimatedHeight;
    }

    if (currentLeft.isNotEmpty || currentRight.isNotEmpty) {
      pages.add(
        _QuestionPaperPage(
          leftColumn: currentLeft,
          rightColumn: currentRight,
        ),
      );
    }

    if (pages.isEmpty) {
      pages.add(
        const _QuestionPaperPage(
          leftColumn: <_PaperBlock>[],
          rightColumn: <_PaperBlock>[],
        ),
      );
    }

    return _QuestionPaperPlan(meta: meta, pages: pages);
  }

  static _ParsedNotice _parseNoticeAndInstructions(
    String rawInstructions, {
    required bool stripDefaultMcInstruction,
  }) {
    final trimmed = rawInstructions.trim();
    if (trimmed.isEmpty) {
      return const _ParsedNotice(
        showNoticeHeading: true,
        bullets: defaultNoticeBullets,
        extraText: '',
      );
    }

    final lines = trimmed.split(RegExp(r'\r?\n'));
    final hasNoticeHeader = lines.any(
      (l) => l.trim().toLowerCase() == 'notice:' ||
          l.trim().toLowerCase().startsWith('notice:'),
    );
    final hasBulletLine = lines.any(
      (l) => RegExp(r'^[\u2022\u2023\u25E6\u2043\u2219\-\*]\s*').hasMatch(
        l.trim(),
      ),
    );

    if (hasNoticeHeader || hasBulletLine) {
      final parsedBullets = <String>[];
      final extraLines = <String>[];

      for (final rawLine in lines) {
        final line = rawLine.trim();
        if (line.isEmpty) continue;
        final lower = line.toLowerCase();
        if (lower == 'notice:') continue;
        if (lower.startsWith('notice:')) {
          final after = line.substring('notice:'.length).trim();
          if (after.isNotEmpty) {
            final cleanAfter = after.replaceFirst(
              RegExp(r'^[\u2022\u2023\u25E6\u2043\u2219\-\*]\s*'),
              '',
            );
            parsedBullets.add(cleanAfter);
          }
          continue;
        }
        final bulletMatch = RegExp(
          r'^[\u2022\u2023\u25E6\u2043\u2219\-\*]\s*(.+)$',
        ).firstMatch(line);
        if (bulletMatch != null) {
          parsedBullets.add(bulletMatch.group(1)!.trim());
          continue;
        }
        if (stripDefaultMcInstruction &&
            lower == defaultMultipleChoiceInstruction.toLowerCase()) {
          continue;
        }
        extraLines.add(line);
      }

      return _ParsedNotice(
        showNoticeHeading: hasNoticeHeader || parsedBullets.isNotEmpty,
        bullets: parsedBullets,
        extraText: extraLines.join('\n'),
      );
    }

    // Teacher replaced the entire Instructions box with custom non-bullet text.
    final filteredExtra = lines
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .where(
          (l) =>
              !stripDefaultMcInstruction ||
              l.toLowerCase() != defaultMultipleChoiceInstruction.toLowerCase(),
        )
        .join('\n');

    return _ParsedNotice(
      showNoticeHeading: false,
      bullets: const <String>[],
      extraText: filteredExtra,
    );
  }

  static _QuestionPaperMetadata _extractMetadata({
    required Map<String, dynamic> exam,
    required List<Map<String, dynamic>> sections,
    required Map<int, List<Map<String, dynamic>>> questions,
  }) {
    String clean(Object? v) {
      final s = (v?.toString() ?? '').trim();
      if (s.toLowerCase() == 'null') return '';
      return s;
    }

    final rawTitle = clean(exam['title']);
    final rawDesc = clean(exam['description']);
    final rawType = clean(exam['assessment_type']);

    final normalizedType = AssessmentValidator.normalizeAssessmentType(
      rawType,
      title: rawTitle,
      description: rawDesc,
    );
    final isMajorExam = AssessmentValidator.isMajorExamination(
      normalizedType,
      title: rawTitle,
      description: rawDesc,
    );

    final cls = exam['class'] is Map
        ? Map<String, dynamic>.from(exam['class'] as Map)
        : <String, dynamic>{};
    final subj = cls['subject'] is Map
        ? Map<String, dynamic>.from(cls['subject'] as Map)
        : (exam['subject'] is Map
              ? Map<String, dynamic>.from(exam['subject'] as Map)
              : <String, dynamic>{});

    var subjectName = clean(subj['name']);
    if (subjectName.isEmpty) subjectName = clean(exam['subject_name']);
    if (subjectName.isEmpty) {
      subjectName = rawTitle.isNotEmpty ? rawTitle : 'Subject';
    }

    var subjectCode = clean(subj['code']);
    if (subjectCode.isEmpty) subjectCode = clean(exam['subject_code']);

    var sectionName = clean(cls['section']);
    if (sectionName.isEmpty) sectionName = clean(exam['section']);
    if (sectionName.isEmpty && exam['sections'] is List) {
      final secList = (exam['sections'] as List)
          .map(clean)
          .where((s) => s.isNotEmpty)
          .toList();
      if (secList.isNotEmpty) sectionName = secList.join(' / ');
    }

    var schoolYear = clean(exam['school_year']);
    if (schoolYear.isEmpty) schoolYear = clean(cls['school_year']);

    var semester = clean(exam['semester']);
    if (semester.isEmpty) semester = clean(cls['semester']);

    // Format term & school year line (e.g. "1st Term, SY 2026-2027")
    final formattedTerm = AssessmentValidator.formatSchoolTerm(semester);
    final formattedSy = AssessmentValidator.formatSchoolYear(schoolYear);
    final termAndSyLine = '$formattedTerm, $formattedSy';

    // Examination title or Quiz title
    final String assessmentTitle;
    if (isMajorExam) {
      assessmentTitle = AssessmentValidator.formalExaminationTitle(
        normalizedType,
        title: rawTitle,
        description: rawDesc,
      );
    } else {
      final quizNumber = clean(exam['quiz_number']);
      if (rawTitle.isNotEmpty) {
        if (quizNumber.isNotEmpty && !rawTitle.contains(quizNumber)) {
          assessmentTitle = '$rawTitle $quizNumber';
        } else {
          assessmentTitle = rawTitle;
        }
      } else {
        final baseLabel = AssessmentValidator.formalExaminationTitle(
          normalizedType,
        );
        assessmentTitle =
            quizNumber.isNotEmpty ? '$baseLabel $quizNumber' : baseLabel;
      }
    }

    // Extract Exam day, Exam date, Start/End time, and Reference no.
    final headerDetails = ExamHeaderDetails.fromExam(exam);
    final scheduleDateLine = headerDetails.scheduleDateLine;
    final scheduleTimeLine = headerDetails.scheduleTimeLine;

    // Right-hand header identifier (e.g. "1000014607 — IT2511" or CheckMate ID + Subject Code)
    final examId = clean(exam['id']);
    String rightCodeLine = '';
    if (isMajorExam) {
      if (headerDetails.referenceNo.isNotEmpty) {
        rightCodeLine = headerDetails.referenceNo;
      } else {
        final courseCodeParts = <String>[];
        if (examId.isNotEmpty) {
          courseCodeParts.add('CM-$examId');
        }
        if (subjectCode.isNotEmpty) {
          courseCodeParts.add(subjectCode);
        }
        rightCodeLine = courseCodeParts.join(' - ');
      }
    }

    final rawInstructions = clean(exam['instructions']);

    return _QuestionPaperMetadata(
      examId: examId,
      isMajorExam: isMajorExam,
      normalizedType: normalizedType,
      subjectName: subjectName,
      subjectCode: subjectCode,
      sectionName: sectionName,
      scheduleDateLine: scheduleDateLine,
      scheduleTimeLine: scheduleTimeLine,
      termAndSyLine: termAndSyLine,
      assessmentTitle: assessmentTitle,
      rightCodeLine: rightCodeLine,
      customInstructions: rawInstructions,
    );
  }

  static String _instructionForQuestionType(
    String qType, {
    String? sectionName,
  }) {
    switch (qType) {
      case 'multiple_choice':
        return 'Read and analyze each item. Choose the letter of the CORRECT answer.';
      case 'identification':
        return 'Read and analyze each item. Write the correct answer on the space provided.';
      case 'true_false':
        return 'Read and analyze each item. Write TRUE if the statement is correct, and FALSE if it is incorrect.';
      default:
        return 'Read and analyze each item carefully.';
    }
  }

  static String _buildSectionPointsHeader({
    required String sectionLetter,
    required Map<String, dynamic> section,
    required List<Map<String, dynamic>> questions,
  }) {
    final itemCount = questions.length;
    final itemWord = itemCount == 1 ? 'item' : 'items';

    final distinctPoints = <double>{};
    var totalSectionPoints = 0.0;
    for (final q in questions) {
      final p = double.tryParse(q['points']?.toString() ?? '') ??
          double.tryParse(section['default_points']?.toString() ?? '') ??
          1.0;
      distinctPoints.add(p);
      totalSectionPoints += p;
    }

    if (distinctPoints.length <= 1) {
      final pts = distinctPoints.isEmpty
          ? (double.tryParse(section['default_points']?.toString() ?? '') ?? 1.0)
          : distinctPoints.first;
      final ptsStr = _formatNumber(pts);
      final ptWord = pts == 1 ? 'point' : 'points';
      return '$sectionLetter.  ($itemCount $itemWord x $ptsStr $ptWord)';
    }

    final totalStr = _formatNumber(totalSectionPoints);
    return '$sectionLetter.  ($itemCount $itemWord, $totalStr points)';
  }

  static String _formatNumber(double value) {
    if (value == value.roundToDouble()) {
      return value.toInt().toString();
    }
    return value.toStringAsFixed(2);
  }

  // ===========================================================================
  // HEIGHT ESTIMATION FOR TWO-COLUMN PAGINATION
  // ===========================================================================

  static int _estimateWrappedLines(String text, int charsPerLine) {
    if (text.isEmpty) return 1;
    var lines = 0;
    for (final paragraph in text.split('\n')) {
      final len = paragraph.trim().length;
      lines += len == 0 ? 1 : (len / charsPerLine).ceil();
    }
    return math.max(1, lines);
  }

  static double _estimateNoticeHeight(
    bool showNoticeHeading,
    List<String> bullets,
    String customInstructions,
  ) {
    var lines = showNoticeHeading ? 1 : 0; // "Notice:"
    for (final b in bullets) {
      lines += _estimateWrappedLines(b, 48);
    }
    if (customInstructions.isNotEmpty) {
      lines += _estimateWrappedLines(customInstructions, 48) + 1;
    }
    if (lines == 0) return 0.0;
    return (lines * 12.2) + 8.0;
  }

  static double _estimateSectionHeaderHeight(
    String instructionText,
    String pointsHeader,
  ) {
    final instLines = _estimateWrappedLines(instructionText, 48);
    final hdrLines = _estimateWrappedLines(pointsHeader, 44);
    return (instLines * 12.2) + 7.0 + (hdrLines * 12.5) + 8.0;
  }

  static double _estimateQuestionHeight({
    required String questionText,
    required String questionType,
    required List<String> choices,
  }) {
    final qLines = _estimateWrappedLines(questionText, 44);
    var height = (qLines * 12.2) + 7.0;

    if (questionType == 'multiple_choice') {
      for (final c in choices) {
        final cLines = _estimateWrappedLines(c, 38);
        height += cLines * 11.8;
      }
      if (choices.isEmpty) {
        height += 4 * 11.8;
      }
    } else if (questionType == 'true_false' ||
        questionType == 'identification') {
      height += 13.0;
    }

    return height;
  }

  // ===========================================================================
  // PDF WIDGET BUILDERS
  // ===========================================================================

  static pw.Widget _buildPdfHeaderTable({
    required _QuestionPaperMetadata meta,
    required int pageNumber,
    required pw.ImageProvider logoImage,
    required pw.Font timesFont,
    required pw.Font timesBoldFont,
    required pw.Font arialBoldFont,
  }) {
    final centerChildren = <pw.Widget>[
      pw.Text(
        _sanitizePdfText(meta.subjectName),
        textAlign: pw.TextAlign.center,
        style: pw.TextStyle(
          font: timesBoldFont,
          fontSize: 12,
          fontWeight: pw.FontWeight.bold,
        ),
      ),
    ];

    if (meta.isMajorExam) {
      if (meta.scheduleDateLine.isNotEmpty) {
        centerChildren.add(
          pw.Text(
            _sanitizePdfText(meta.scheduleDateLine),
            textAlign: pw.TextAlign.center,
            style: pw.TextStyle(font: timesFont, fontSize: 10),
          ),
        );
      }
      if (meta.scheduleTimeLine.isNotEmpty) {
        centerChildren.add(
          pw.Text(
            _sanitizePdfText(meta.scheduleTimeLine),
            textAlign: pw.TextAlign.center,
            style: pw.TextStyle(font: timesFont, fontSize: 10),
          ),
        );
      }
      if (meta.scheduleDateLine.isNotEmpty ||
          meta.scheduleTimeLine.isNotEmpty) {
        centerChildren.add(pw.SizedBox(height: 6));
      } else {
        centerChildren.add(pw.SizedBox(height: 4));
      }
      if (meta.termAndSyLine.isNotEmpty) {
        centerChildren.add(
          pw.Text(
            _sanitizePdfText(meta.termAndSyLine),
            textAlign: pw.TextAlign.center,
            style: pw.TextStyle(
              font: timesBoldFont,
              fontSize: 12,
              fontWeight: pw.FontWeight.bold,
            ),
          ),
        );
      }
      centerChildren.add(
        pw.Text(
          _sanitizePdfText(meta.assessmentTitle),
          textAlign: pw.TextAlign.center,
          style: pw.TextStyle(
            font: timesBoldFont,
            fontSize: 12,
            fontWeight: pw.FontWeight.bold,
          ),
        ),
      );
    } else {
      centerChildren.add(pw.SizedBox(height: 10));
      centerChildren.add(
        pw.Text(
          _sanitizePdfText(meta.assessmentTitle),
          textAlign: pw.TextAlign.center,
          style: pw.TextStyle(
            font: timesBoldFont,
            fontSize: 12,
            fontWeight: pw.FontWeight.bold,
          ),
        ),
      );
    }

    // Column proportions matching reference Word table:
    // 2898 : 5940 : 2625 dxa
    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.center,
      children: [
        pw.Expanded(
          flex: 290,
          child: pw.Align(
            alignment: pw.Alignment.centerLeft,
            child: pw.Image(
              logoImage,
              width: 56,
              height: 31,
              fit: pw.BoxFit.contain,
            ),
          ),
        ),
        pw.Expanded(
          flex: 594,
          child: pw.Column(
            mainAxisSize: pw.MainAxisSize.min,
            crossAxisAlignment: pw.CrossAxisAlignment.center,
            children: centerChildren,
          ),
        ),
        pw.Expanded(
          flex: 262,
          child: pw.Column(
            mainAxisSize: pw.MainAxisSize.min,
            crossAxisAlignment: pw.CrossAxisAlignment.end,
            children: [
              if (meta.rightCodeLine.isNotEmpty)
                pw.Text(
                  _sanitizePdfText(meta.rightCodeLine),
                  textAlign: pw.TextAlign.right,
                  style: pw.TextStyle(
                    font: arialBoldFont,
                    fontSize: 10,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              pw.Text(
                'Page $pageNumber',
                textAlign: pw.TextAlign.right,
                style: pw.TextStyle(
                  font: arialBoldFont,
                  fontSize: 10,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  static pw.Widget _buildPdfStudentInfoRow({
    required pw.Font arialBoldFont,
  }) {
    final style = pw.TextStyle(
      font: arialBoldFont,
      fontSize: 10,
      fontWeight: pw.FontWeight.bold,
    );
    return pw.Row(
      children: [
        pw.Expanded(
          child: pw.Text('Name:_______________________________', style: style),
        ),
        pw.Expanded(
          child: pw.Text('Section:________________________', style: style),
        ),
        pw.Expanded(
          child: pw.Text('Date:_______________', style: style),
        ),
      ],
    );
  }

  static pw.Widget _buildPdfBlock(
    _PaperBlock block, {
    required pw.Font arialFont,
    required pw.Font arialBoldFont,
  }) {
    final regStyle = pw.TextStyle(font: arialFont, fontSize: 10, lineSpacing: 1);
    final boldStyle = pw.TextStyle(
      font: arialBoldFont,
      fontSize: 10,
      fontWeight: pw.FontWeight.bold,
      lineSpacing: 1,
    );

    switch (block.kind) {
      case _BlockKind.notice:
        if (!block.showNoticeHeading &&
            block.bullets.isEmpty &&
            block.customInstructions.isEmpty) {
          return pw.SizedBox.shrink();
        }
        return pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 6),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              if (block.showNoticeHeading) pw.Text('Notice:', style: boldStyle),
              ...block.bullets.map(
                (b) => pw.Row(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.SizedBox(
                      width: 10,
                      child: pw.Padding(
                        padding: const pw.EdgeInsets.only(top: 3.8, left: 1.5),
                        child: pw.Align(
                          alignment: pw.Alignment.topLeft,
                          child: pw.Container(
                            width: 3.2,
                            height: 3.2,
                            decoration: const pw.BoxDecoration(
                              color: PdfColors.black,
                              shape: pw.BoxShape.circle,
                            ),
                          ),
                        ),
                      ),
                    ),
                    pw.Expanded(
                      child: pw.Text(_sanitizePdfText(b), style: regStyle),
                    ),
                  ],
                ),
              ),
              if (block.customInstructions.isNotEmpty) ...[
                if (block.showNoticeHeading || block.bullets.isNotEmpty)
                  pw.SizedBox(height: 3),
                pw.Text(
                  _sanitizePdfText(block.customInstructions),
                  style: regStyle,
                ),
              ],
            ],
          ),
        );

      case _BlockKind.sectionHeader:
        return pw.Padding(
          padding: pw.EdgeInsets.only(
            top: block.isFirstInColumn ? 0 : 4,
            bottom: 8,
          ),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              if (block.instructionText.isNotEmpty) ...[
                pw.Text(
                  _sanitizePdfText(block.instructionText),
                  style: regStyle,
                ),
                pw.SizedBox(height: 7),
              ],
              pw.Text(
                _sanitizePdfText(block.pointsHeader),
                style: boldStyle,
              ),
            ],
          ),
        );

      case _BlockKind.question:
        return pw.Padding(
          padding: pw.EdgeInsets.only(
            top: block.isFirstInColumn ? 0 : 7,
          ),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              // Question stem with hanging indent (504 dxa = 25.2 pt)
              pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.SizedBox(
                    width: 25.2,
                    child: pw.Text('${block.questionNumber}.', style: regStyle),
                  ),
                  pw.Expanded(
                    child: pw.Text(
                      _sanitizePdfText(block.questionText),
                      style: regStyle,
                    ),
                  ),
                ],
              ),

              if (block.questionType == 'multiple_choice') ...[
                for (var i = 0; i < block.choices.length; i++)
                  pw.Padding(
                    padding: const pw.EdgeInsets.only(left: 27.35),
                    child: pw.Row(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.SizedBox(
                          width: 19.45,
                          child: pw.Text(
                            '${String.fromCharCode(65 + i)}.',
                            style: regStyle,
                          ),
                        ),
                        pw.Expanded(
                          child: pw.Text(
                            _sanitizePdfText(block.choices[i]),
                            style: regStyle,
                          ),
                        ),
                      ],
                    ),
                  ),
              ] else if (block.questionType == 'true_false') ...[
                pw.Padding(
                  padding: const pw.EdgeInsets.only(left: 25.2, top: 2),
                  child: pw.Text(
                    'Answer (True / False): ____________',
                    style: regStyle,
                  ),
                ),
              ] else if (block.questionType == 'identification') ...[
                pw.Padding(
                  padding: const pw.EdgeInsets.only(left: 25.2, top: 2),
                  child: pw.Text(
                    'Answer: ________________________',
                    style: regStyle,
                  ),
                ),
              ],
            ],
          ),
        );
    }
  }

  // ===========================================================================
  // MICROSOFT WORD (.DOCX) OPENXML BUILDER
  // ===========================================================================

  static String _xmlEscape(String input) {
    return input
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }

  static String _buildDocxDocumentXml(_QuestionPaperPlan plan) {
    final sb = StringBuffer();
    sb.write(
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<w:document '
      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
      'xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" '
      'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" '
      'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
      'xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">'
      '<w:body>',
    );

    for (var pageIdx = 0; pageIdx < plan.pages.length; pageIdx++) {
      final page = plan.pages[pageIdx];
      final pageNumber = pageIdx + 1;

      if (pageIdx > 0) {
        sb.write('<w:p><w:r><w:br w:type="page"/></w:r></w:p>');
      }

      // 1. Header Table (3 columns: 2898, 5940, 2625 dxa)
      sb.write(_buildDocxHeaderTableXml(plan.meta, pageNumber));

      // 2. Full-width horizontal divider paragraph
      sb.write(
        '<w:p>'
        '<w:pPr><w:rPr><w:sz w:val="14"/><w:szCs w:val="14"/></w:rPr></w:pPr>'
        '<w:r><w:rPr><w:sz w:val="14"/><w:szCs w:val="14"/></w:rPr>'
        '<w:t>${'_' * 146}</w:t></w:r>'
        '</w:p>',
      );

      // 3. Student Info Table (3 columns: 3821, 3821, 3821 dxa)
      sb.write(_buildDocxStudentInfoTableXml());

      // 4. Two-Column Content Table (2 columns: 5702, 5702 dxa)
      sb.write(_buildDocxContentTableXml(page));
    }

    // Page setup matching reference Word documents:
    // width = 12240 dxa (8.50 in), height = 18720 dxa (13.00 in)
    // margins: top = 936 dxa (0.65 in), bottom = 720 dxa (0.50 in),
    // left = 389 dxa (0.27 in), right = 389 dxa (0.27 in)
    sb.write(
      '<w:sectPr>'
      '<w:pgSz w:w="12240" w:h="18720"/>'
      '<w:pgMar w:top="936" w:right="389" w:bottom="720" w:left="389" '
      'w:header="720" w:footer="720" w:gutter="0"/>'
      '</w:sectPr>'
      '</w:body></w:document>',
    );

    return sb.toString();
  }

  static String _buildDocxHeaderTableXml(
    _QuestionPaperMetadata meta,
    int pageNumber,
  ) {
    final sb = StringBuffer();
    sb.write(
      '<w:tbl>'
      '<w:tblPr>'
      '<w:tblW w:w="0" w:type="auto"/>'
      '<w:tblLayout w:type="fixed"/>'
      '</w:tblPr>'
      '<w:tblGrid>'
      '<w:gridCol w:w="2898"/>'
      '<w:gridCol w:w="5940"/>'
      '<w:gridCol w:w="2625"/>'
      '</w:tblGrid>'
      '<w:tr>',
    );

    // Cell 0: STI College Logo (inline drawing extent cx="503895" cy="279400")
    sb.write(
      '<w:tc>'
      '<w:tcPr><w:tcW w:w="2898" w:type="dxa"/><w:vAlign w:val="center"/></w:tcPr>'
      '<w:p><w:r>'
      '<w:drawing>'
      '<wp:inline distT="0" distB="0" distL="0" distR="0">'
      '<wp:extent cx="503895" cy="279400"/>'
      '<wp:docPr id="$pageNumber" name="STI Logo $pageNumber"/>'
      '<wp:cNvGraphicFramePr>'
      '<a:graphicFrameLocks noChangeAspect="1"/>'
      '</wp:cNvGraphicFramePr>'
      '<a:graphic>'
      '<a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">'
      '<pic:pic>'
      '<pic:nvPicPr>'
      '<pic:cNvPr id="$pageNumber" name="image1.png"/>'
      '<pic:cNvPicPr/>'
      '</pic:nvPicPr>'
      '<pic:blipFill>'
      '<a:blip r:embed="rId2"/>'
      '<a:stretch><a:fillRect/></a:stretch>'
      '</pic:blipFill>'
      '<pic:spPr>'
      '<a:xfrm><a:off x="0" y="0"/><a:ext cx="503895" cy="279400"/></a:xfrm>'
      '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom>'
      '</pic:spPr>'
      '</pic:pic>'
      '</a:graphicData>'
      '</a:graphic>'
      '</wp:inline>'
      '</w:drawing>'
      '</w:r></w:p>'
      '</w:tc>',
    );

    // Cell 1: Center Subject & Assessment Information
    sb.write(
      '<w:tc>'
      '<w:tcPr><w:tcW w:w="5940" w:type="dxa"/><w:vAlign w:val="center"/></w:tcPr>',
    );

    // Subject Name (Times New Roman 12pt Bold)
    sb.write(
      '<w:p>'
      '<w:pPr><w:jc w:val="center"/></w:pPr>'
      '<w:r><w:rPr>'
      '<w:rFonts w:ascii="Times New Roman" w:hAnsi="Times New Roman" w:cs="Times New Roman"/>'
      '<w:b/><w:sz w:val="24"/><w:szCs w:val="24"/>'
      '</w:rPr><w:t>${_xmlEscape(meta.subjectName)}</w:t></w:r>'
      '</w:p>',
    );

    if (meta.isMajorExam) {
      if (meta.scheduleDateLine.isNotEmpty) {
        sb.write(
          '<w:p>'
          '<w:pPr><w:jc w:val="center"/></w:pPr>'
          '<w:r><w:rPr>'
          '<w:rFonts w:ascii="Times New Roman" w:hAnsi="Times New Roman" w:cs="Times New Roman"/>'
          '<w:sz w:val="20"/><w:szCs w:val="20"/>'
          '</w:rPr><w:t>${_xmlEscape(meta.scheduleDateLine)}</w:t></w:r>'
          '</w:p>',
        );
      }
      if (meta.scheduleTimeLine.isNotEmpty) {
        sb.write(
          '<w:p>'
          '<w:pPr><w:jc w:val="center"/></w:pPr>'
          '<w:r><w:rPr>'
          '<w:rFonts w:ascii="Times New Roman" w:hAnsi="Times New Roman" w:cs="Times New Roman"/>'
          '<w:sz w:val="20"/><w:szCs w:val="20"/>'
          '</w:rPr><w:t>${_xmlEscape(meta.scheduleTimeLine)}</w:t></w:r>'
          '</w:p>',
        );
      }
      sb.write('<w:p><w:pPr><w:jc w:val="center"/></w:pPr></w:p>');
      if (meta.termAndSyLine.isNotEmpty) {
        sb.write(
          '<w:p>'
          '<w:pPr><w:jc w:val="center"/></w:pPr>'
          '<w:r><w:rPr>'
          '<w:rFonts w:ascii="Times New Roman" w:hAnsi="Times New Roman" w:cs="Times New Roman"/>'
          '<w:b/><w:sz w:val="24"/><w:szCs w:val="24"/>'
          '</w:rPr>'
          '<w:t>${_xmlEscape(meta.termAndSyLine)}</w:t>'
          '<w:br/>'
          '<w:t>${_xmlEscape(meta.assessmentTitle)}</w:t>'
          '</w:r>'
          '</w:p>',
        );
      } else {
        sb.write(
          '<w:p>'
          '<w:pPr><w:jc w:val="center"/></w:pPr>'
          '<w:r><w:rPr>'
          '<w:rFonts w:ascii="Times New Roman" w:hAnsi="Times New Roman" w:cs="Times New Roman"/>'
          '<w:b/><w:sz w:val="24"/><w:szCs w:val="24"/>'
          '</w:rPr>'
          '<w:t>${_xmlEscape(meta.assessmentTitle)}</w:t>'
          '</w:r>'
          '</w:p>',
        );
      }
    } else {
      sb.write(
        '<w:p>'
        '<w:pPr><w:jc w:val="center"/></w:pPr>'
        '<w:r><w:rPr>'
        '<w:rFonts w:ascii="Times New Roman" w:hAnsi="Times New Roman" w:cs="Times New Roman"/>'
        '<w:b/><w:sz w:val="24"/><w:szCs w:val="24"/>'
        '</w:rPr>'
        '<w:br/>'
        '<w:t>${_xmlEscape(meta.assessmentTitle)}</w:t>'
        '</w:r>'
        '</w:p>',
      );
    }

    sb.write('</w:tc>');

    // Cell 2: Right Course/Exam Code + Page Number
    sb.write(
      '<w:tc>'
      '<w:tcPr><w:tcW w:w="2625" w:type="dxa"/><w:vAlign w:val="center"/></w:tcPr>'
      '<w:p>'
      '<w:pPr><w:jc w:val="right"/></w:pPr>'
      '<w:r><w:rPr><w:b/></w:rPr>',
    );
    if (meta.rightCodeLine.isNotEmpty) {
      sb.write(
        '<w:t>${_xmlEscape(meta.rightCodeLine)}</w:t>'
        '<w:br/>'
        '<w:t>Page $pageNumber</w:t>',
      );
    } else {
      sb.write('<w:br/><w:t>Page $pageNumber</w:t>');
    }
    sb.write('</w:r></w:p></w:tc></w:tr></w:tbl>');

    return sb.toString();
  }

  static String _buildDocxStudentInfoTableXml() {
    return '<w:tbl>'
        '<w:tblPr><w:tblW w:w="0" w:type="auto"/></w:tblPr>'
        '<w:tblGrid>'
        '<w:gridCol w:w="3821"/>'
        '<w:gridCol w:w="3821"/>'
        '<w:gridCol w:w="3821"/>'
        '</w:tblGrid>'
        '<w:tr>'
        '<w:tc>'
        '<w:tcPr><w:tcW w:w="3821" w:type="dxa"/></w:tcPr>'
        '<w:p><w:r><w:rPr><w:b/></w:rPr><w:t>Name:_______________________________</w:t></w:r></w:p>'
        '</w:tc>'
        '<w:tc>'
        '<w:tcPr><w:tcW w:w="3821" w:type="dxa"/></w:tcPr>'
        '<w:p><w:r><w:rPr><w:b/></w:rPr><w:t>Section:________________________</w:t></w:r></w:p>'
        '</w:tc>'
        '<w:tc>'
        '<w:tcPr><w:tcW w:w="3821" w:type="dxa"/></w:tcPr>'
        '<w:p><w:r><w:rPr><w:b/></w:rPr><w:t>Date:_______________</w:t></w:r></w:p>'
        '</w:tc>'
        '</w:tr>'
        '</w:tbl>';
  }

  static String _buildDocxContentTableXml(_QuestionPaperPage page) {
    final sb = StringBuffer();
    sb.write(
      '<w:tbl>'
      '<w:tblPr>'
      '<w:tblW w:w="0" w:type="auto"/>'
      '<w:tblLayout w:type="fixed"/>'
      '</w:tblPr>'
      '<w:tblGrid>'
      '<w:gridCol w:w="5702"/>'
      '<w:gridCol w:w="5702"/>'
      '</w:tblGrid>'
      '<w:tr>',
    );

    // Left Column
    sb.write('<w:tc><w:tcPr><w:tcW w:w="5702" w:type="dxa"/></w:tcPr>');
    if (page.leftColumn.isEmpty) {
      sb.write('<w:p/>');
    } else {
      for (final block in page.leftColumn) {
        sb.write(_buildDocxBlockXml(block));
      }
    }
    sb.write('</w:tc>');

    // Right Column
    sb.write('<w:tc><w:tcPr><w:tcW w:w="5702" w:type="dxa"/></w:tcPr>');
    if (page.rightColumn.isEmpty) {
      sb.write('<w:p/>');
    } else {
      for (final block in page.rightColumn) {
        sb.write(_buildDocxBlockXml(block));
      }
    }
    sb.write('</w:tc>');

    sb.write('</w:tr></w:tbl>');
    return sb.toString();
  }

  static String _buildDocxBlockXml(_PaperBlock block) {
    final sb = StringBuffer();

    switch (block.kind) {
      case _BlockKind.notice:
        if (block.showNoticeHeading) {
          sb.write(
            '<w:p><w:r><w:rPr><w:b/></w:rPr><w:t>Notice:</w:t></w:r></w:p>',
          );
        }
        for (final b in block.bullets) {
          sb.write(
            '<w:p>'
            '<w:pPr><w:ind w:left="202" w:hanging="202"/></w:pPr>'
            '<w:r><w:t xml:space="preserve">\u2022 ${_xmlEscape(b)}</w:t></w:r>'
            '</w:p>',
          );
        }
        if (block.customInstructions.isNotEmpty) {
          sb.write(
            '<w:p>'
            '<w:pPr><w:spacing w:before="80" w:after="80"/></w:pPr>'
            '<w:r><w:t>${_xmlEscape(block.customInstructions)}</w:t></w:r>'
            '</w:p>',
          );
        }
        break;

      case _BlockKind.sectionHeader:
        if (block.instructionText.isNotEmpty) {
          sb.write(
            '<w:p>'
            '<w:pPr><w:spacing w:after="140"/></w:pPr>'
            '<w:r><w:t>${_xmlEscape(block.instructionText)}</w:t></w:r>'
            '</w:p>',
          );
        }
        sb.write(
          '<w:p>'
          '<w:pPr><w:spacing w:after="160"/></w:pPr>'
          '<w:r><w:rPr><w:b/></w:rPr><w:t xml:space="preserve">${_xmlEscape(block.pointsHeader)}</w:t></w:r>'
          '</w:p>',
        );
        break;

      case _BlockKind.question:
        final spacingAttr = block.isFirstInColumn
            ? ''
            : '<w:spacing w:before="140"/>';
        sb.write(
          '<w:p>'
          '<w:pPr>$spacingAttr<w:ind w:left="504" w:hanging="504"/></w:pPr>'
          '<w:r><w:t xml:space="preserve">${block.questionNumber}.     ${_xmlEscape(block.questionText)}</w:t></w:r>'
          '</w:p>',
        );

        if (block.questionType == 'multiple_choice') {
          for (var i = 0; i < block.choices.length; i++) {
            final letter = String.fromCharCode(65 + i);
            sb.write(
              '<w:p>'
              '<w:pPr><w:ind w:left="936" w:hanging="389"/></w:pPr>'
              '<w:r><w:t xml:space="preserve">$letter.   ${_xmlEscape(block.choices[i])}</w:t></w:r>'
              '</w:p>',
            );
          }
        } else if (block.questionType == 'true_false') {
          sb.write(
            '<w:p>'
            '<w:pPr><w:ind w:left="504"/></w:pPr>'
            '<w:r><w:t>Answer (True / False): ____________</w:t></w:r>'
            '</w:p>',
          );
        } else if (block.questionType == 'identification') {
          sb.write(
            '<w:p>'
            '<w:pPr><w:ind w:left="504"/></w:pPr>'
            '<w:r><w:t>Answer: ________________________</w:t></w:r>'
            '</w:p>',
          );
        }
        break;
    }

    return sb.toString();
  }

  static const String _docxContentTypesXml =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
      '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
      '<Default Extension="xml" ContentType="application/xml"/>'
      '<Default Extension="png" ContentType="image/png"/>'
      '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
      '<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>'
      '</Types>';

  static const String _docxRootRelsXml =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
      '</Relationships>';

  static const String _docxDocumentRelsXml =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
      '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/image1.png"/>'
      '</Relationships>';

  static const String _docxStylesXml =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
      '<w:docDefaults>'
      '<w:rPrDefault>'
      '<w:rPr>'
      '<w:rFonts w:ascii="Arial" w:hAnsi="Arial" w:cs="Arial"/>'
      '<w:sz w:val="20"/>'
      '<w:szCs w:val="20"/>'
      '</w:rPr>'
      '</w:rPrDefault>'
      '<w:pPrDefault>'
      '<w:pPr>'
      '<w:spacing w:after="0" w:line="240" w:lineRule="auto"/>'
      '</w:pPr>'
      '</w:pPrDefault>'
      '</w:docDefaults>'
      '<w:style w:type="paragraph" w:default="1" w:styleId="Normal">'
      '<w:name w:val="Normal"/>'
      '<w:qFormat/>'
      '</w:style>'
      '</w:styles>';
}

// =============================================================================
// INTERNAL MODELS
// =============================================================================

class _ParsedNotice {
  const _ParsedNotice({
    required this.showNoticeHeading,
    required this.bullets,
    required this.extraText,
  });

  final bool showNoticeHeading;
  final List<String> bullets;
  final String extraText;
}

enum _BlockKind { notice, sectionHeader, question }

class _PaperBlock {
  const _PaperBlock({
    required this.kind,
    required this.estimatedHeight,
    this.showNoticeHeading = true,
    this.bullets = const <String>[],
    this.customInstructions = '',
    this.instructionText = '',
    this.pointsHeader = '',
    this.questionNumber = 0,
    this.questionText = '',
    this.questionType = '',
    this.choices = const <String>[],
    this.isFirstInColumn = false,
  });

  factory _PaperBlock.notice({
    required bool showNoticeHeading,
    required List<String> bullets,
    required String customInstructions,
    required double estimatedHeight,
  }) =>
      _PaperBlock(
        kind: _BlockKind.notice,
        showNoticeHeading: showNoticeHeading,
        bullets: bullets,
        customInstructions: customInstructions,
        estimatedHeight: estimatedHeight,
      );

  factory _PaperBlock.sectionHeader({
    required String instructionText,
    required String pointsHeader,
    required double estimatedHeight,
  }) =>
      _PaperBlock(
        kind: _BlockKind.sectionHeader,
        instructionText: instructionText,
        pointsHeader: pointsHeader,
        estimatedHeight: estimatedHeight,
      );

  factory _PaperBlock.question({
    required int questionNumber,
    required String questionText,
    required String questionType,
    required List<String> choices,
    required bool isFirstInColumn,
    required double estimatedHeight,
  }) =>
      _PaperBlock(
        kind: _BlockKind.question,
        questionNumber: questionNumber,
        questionText: questionText,
        questionType: questionType,
        choices: choices,
        isFirstInColumn: isFirstInColumn,
        estimatedHeight: estimatedHeight,
      );

  final _BlockKind kind;
  final double estimatedHeight;
  final bool showNoticeHeading;
  final List<String> bullets;
  final String customInstructions;
  final String instructionText;
  final String pointsHeader;
  final int questionNumber;
  final String questionText;
  final String questionType;
  final List<String> choices;
  final bool isFirstInColumn;

  _PaperBlock copyWith({bool? isFirstInColumn}) => _PaperBlock(
        kind: kind,
        estimatedHeight: estimatedHeight,
        showNoticeHeading: showNoticeHeading,
        bullets: bullets,
        customInstructions: customInstructions,
        instructionText: instructionText,
        pointsHeader: pointsHeader,
        questionNumber: questionNumber,
        questionText: questionText,
        questionType: questionType,
        choices: choices,
        isFirstInColumn: isFirstInColumn ?? this.isFirstInColumn,
      );
}

class _QuestionPaperPage {
  const _QuestionPaperPage({
    required this.leftColumn,
    required this.rightColumn,
  });

  final List<_PaperBlock> leftColumn;
  final List<_PaperBlock> rightColumn;
}

class _QuestionPaperMetadata {
  const _QuestionPaperMetadata({
    required this.examId,
    required this.isMajorExam,
    required this.normalizedType,
    required this.subjectName,
    required this.subjectCode,
    required this.sectionName,
    required this.scheduleDateLine,
    required this.scheduleTimeLine,
    required this.termAndSyLine,
    required this.assessmentTitle,
    required this.rightCodeLine,
    required this.customInstructions,
  });

  final String examId;
  final bool isMajorExam;
  final String normalizedType;
  final String subjectName;
  final String subjectCode;
  final String sectionName;
  final String scheduleDateLine;
  final String scheduleTimeLine;
  final String termAndSyLine;
  final String assessmentTitle;
  final String rightCodeLine;
  final String customInstructions;
}

class _QuestionPaperPlan {
  const _QuestionPaperPlan({
    required this.meta,
    required this.pages,
  });

  final _QuestionPaperMetadata meta;
  final List<_QuestionPaperPage> pages;
}
