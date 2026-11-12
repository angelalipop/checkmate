import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:archive/archive.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:xml/xml.dart';

import 'question_paper_pdf_service.dart';

/// Configuration for a single section in the CheckMate Word questionnaire template.
class QuestionnaireTemplateSectionConfig {
  const QuestionnaireTemplateSectionConfig({
    required this.questionType,
    required this.itemCount,
    this.pointsPerItem = 1.0,
  });

  final String questionType;
  final int itemCount;
  final double pointsPerItem;

  double get totalPoints => itemCount * pointsPerItem;

  QuestionnaireTemplateSectionConfig copyWith({
    String? questionType,
    int? itemCount,
    double? pointsPerItem,
  }) {
    return QuestionnaireTemplateSectionConfig(
      questionType: questionType ?? this.questionType,
      itemCount: itemCount ?? this.itemCount,
      pointsPerItem: pointsPerItem ?? this.pointsPerItem,
    );
  }
}

/// Resolved template section with its Roman-numeral Part number, optional
/// lettered subpart (when a question type repeats), display heading, separate
/// point-instruction line, and continuous item range.
class ResolvedTemplateSection {
  const ResolvedTemplateSection({
    required this.sectionOrder,
    required this.partNumber,
    required this.partRoman,
    required this.subpartLetter,
    required this.questionType,
    required this.heading,
    required this.instructionLine,
    required this.pointsInstructionLine,
    required this.itemCount,
    required this.pointsPerItem,
    required this.startItem,
    required this.endItem,
  });

  final int sectionOrder;
  final int partNumber;
  final String partRoman;
  final String? subpartLetter;
  final String questionType;
  final String heading;
  final String instructionLine;
  final String pointsInstructionLine;
  final int itemCount;
  final double pointsPerItem;
  final int startItem;
  final int endItem;

  double get totalPoints => itemCount * pointsPerItem;

  String get itemRangeLabel =>
      itemCount <= 0 ? '0 items' : '$startItem\u2013$endItem';
}

/// Built-in preset definition for the Upload Questionnaire template setup UI.
class QuestionnaireTemplatePreset {
  const QuestionnaireTemplatePreset({
    required this.id,
    required this.label,
    required this.sections,
  });

  final String id;
  final String label;
  final List<QuestionnaireTemplateSectionConfig> sections;
}

/// Validation or discrepancy issue surfaced during questionnaire import review.
class QuestionPaperImportIssue {
  const QuestionPaperImportIssue({
    required this.kind,
    required this.message,
    this.sectionIndex,
    this.questionNumber,
    this.isBlocking = false,
  });

  /// Issue category:
  /// - `'unreadable_page'`
  /// - `'unresolved_classification'`
  /// - `'ambiguous_section'`
  /// - `'duplicate_number'`
  /// - `'missing_number'`
  /// - `'leftover_placeholder'`
  /// - `'incomplete_choices'`
  /// - `'mismatched_count'`
  /// - `'template_mismatch'`
  final String kind;
  final String message;
  final int? sectionIndex;
  final int? questionNumber;
  final bool isBlocking;
}

class ImportedExamQuestion {
  const ImportedExamQuestion({
    required this.questionNumber,
    required this.questionText,
    required this.questionType,
    required this.points,
    this.choices = const <String>[],
    this.correctAnswer,
    this.sourceQuestionNumber,
    this.hasLeftoverPlaceholder = false,
    this.missingChoiceLetters = const <String>[],
    this.classificationAmbiguous = false,
  });

  final int questionNumber;
  final int? sourceQuestionNumber;
  final String questionText;
  final String questionType;
  final double points;
  final List<String> choices;
  final String? correctAnswer;
  final bool hasLeftoverPlaceholder;
  final List<String> missingChoiceLetters;
  final bool classificationAmbiguous;

  bool get hasIssues =>
      hasLeftoverPlaceholder ||
      missingChoiceLetters.isNotEmpty ||
      classificationAmbiguous ||
      questionText.trim().isEmpty;

  ImportedExamQuestion copyWith({
    int? questionNumber,
    int? sourceQuestionNumber,
    String? questionText,
    String? questionType,
    double? points,
    List<String>? choices,
    String? correctAnswer,
    bool? hasLeftoverPlaceholder,
    List<String>? missingChoiceLetters,
    bool? classificationAmbiguous,
  }) {
    return ImportedExamQuestion(
      questionNumber: questionNumber ?? this.questionNumber,
      sourceQuestionNumber: sourceQuestionNumber ?? this.sourceQuestionNumber,
      questionText: questionText ?? this.questionText,
      questionType: questionType ?? this.questionType,
      points: points ?? this.points,
      choices: choices ?? this.choices,
      correctAnswer: correctAnswer ?? this.correctAnswer,
      hasLeftoverPlaceholder:
          hasLeftoverPlaceholder ?? this.hasLeftoverPlaceholder,
      missingChoiceLetters: missingChoiceLetters ?? this.missingChoiceLetters,
      classificationAmbiguous:
          classificationAmbiguous ?? this.classificationAmbiguous,
    );
  }
}

class ImportedExamSection {
  const ImportedExamSection({
    required this.name,
    required this.questionType,
    required this.defaultPoints,
    required this.questions,
    this.partNumber,
    this.subpartLetter,
    this.expectedItemCount,
    this.hasAmbiguousMetadata = false,
  });

  final String name;
  final String questionType;
  final double defaultPoints;
  final List<ImportedExamQuestion> questions;
  final int? partNumber;
  final String? subpartLetter;
  final int? expectedItemCount;
  final bool hasAmbiguousMetadata;

  int get startQuestionNumber =>
      questions.isEmpty ? 0 : questions.first.questionNumber;

  int get endQuestionNumber =>
      questions.isEmpty ? 0 : questions.last.questionNumber;

  String get itemRangeLabel => questions.isEmpty
      ? '0 items'
      : '${questions.first.questionNumber}\u2013${questions.last.questionNumber}';

  double get totalPoints => questions.fold<double>(
    0.0,
    (sum, q) => sum + (q.points > 0 ? q.points : defaultPoints),
  );

  ImportedExamSection copyWith({
    String? name,
    String? questionType,
    double? defaultPoints,
    List<ImportedExamQuestion>? questions,
    int? partNumber,
    String? subpartLetter,
    int? expectedItemCount,
    bool? hasAmbiguousMetadata,
  }) {
    return ImportedExamSection(
      name: name ?? this.name,
      questionType: questionType ?? this.questionType,
      defaultPoints: defaultPoints ?? this.defaultPoints,
      questions: questions ?? this.questions,
      partNumber: partNumber ?? this.partNumber,
      subpartLetter: subpartLetter ?? this.subpartLetter,
      expectedItemCount: expectedItemCount ?? this.expectedItemCount,
      hasAmbiguousMetadata: hasAmbiguousMetadata ?? this.hasAmbiguousMetadata,
    );
  }
}

class ImportedQuestionPaper {
  const ImportedQuestionPaper({
    required this.fileName,
    required this.sections,
    this.detectedAssessmentType,
    this.detectedSubjectName,
    this.detectedQuizTitle,
    this.detectedExamDay,
    this.detectedExamDate,
    this.detectedStartTime,
    this.detectedEndTime,
    this.detectedReferenceNo,
    this.detectedInstructions,
    this.unreadablePages = const <int>[],
    this.issues = const <QuestionPaperImportIssue>[],
  });

  final String fileName;
  final List<ImportedExamSection> sections;
  final String? detectedAssessmentType;
  final String? detectedSubjectName;
  final String? detectedQuizTitle;
  final String? detectedExamDay;
  final String? detectedExamDate;
  final String? detectedStartTime;
  final String? detectedEndTime;
  final String? detectedReferenceNo;
  final String? detectedInstructions;
  final List<int> unreadablePages;
  final List<QuestionPaperImportIssue> issues;

  int get totalQuestions =>
      sections.fold<int>(0, (sum, s) => sum + s.questions.length);

  double get totalPoints =>
      sections.fold<double>(0.0, (sum, s) => sum + s.totalPoints);

  bool get hasExplicitAssessmentType =>
      detectedAssessmentType != null &&
      detectedAssessmentType!.trim().isNotEmpty;

  bool get isAssessmentTypeAmbiguous => !hasExplicitAssessmentType;

  bool get hasBlockingIssues => issues.any((i) => i.isBlocking);

  Map<String, double> get pointsSubtotalByType {
    final map = <String, double>{};
    for (final s in sections) {
      final t = QuestionPaperImportService.normalizeQuestionType(
        s.questionType,
      );
      map[t] = (map[t] ?? 0.0) + s.totalPoints;
    }
    return map;
  }

  Map<String, int> get itemCountSubtotalByType {
    final map = <String, int>{};
    for (final s in sections) {
      final t = QuestionPaperImportService.normalizeQuestionType(
        s.questionType,
      );
      map[t] = (map[t] ?? 0) + s.questions.length;
    }
    return map;
  }

  /// Rebuilds the paper after teacher edits in the Import Review modal,
  /// re-applying canonical Roman-numeral Part & lettered subpart headings,
  /// continuous question numbering, and validation checks.
  ImportedQuestionPaper rebuildWithUpdatedSections(
    List<ImportedExamSection> updatedSections, {
    List<QuestionnaireTemplateSectionConfig>? expectedTemplate,
  }) {
    return QuestionPaperImportService.finalizeImportedPaper(
      fileName: fileName,
      rawSections: updatedSections,
      detectedAssessmentType: detectedAssessmentType,
      detectedSubjectName: detectedSubjectName,
      detectedQuizTitle: detectedQuizTitle,
      detectedExamDay: detectedExamDay,
      detectedExamDate: detectedExamDate,
      detectedStartTime: detectedStartTime,
      detectedEndTime: detectedEndTime,
      detectedReferenceNo: detectedReferenceNo,
      detectedInstructions: detectedInstructions,
      unreadablePages: unreadablePages,
      expectedTemplate: expectedTemplate,
    );
  }
}

/// Parses an uploaded Questionnaire in multiple file formats (`.pdf`, `.docx`,
/// `.doc`, `.xlsx`, `.csv`, `.tsv`, `.txt`, `.rtf`, `.odt`, `.md`, `.html`)
/// into structured sections, questions, choices, header metadata, and
/// teacher-review validation diagnostics.
class QuestionPaperImportService {
  QuestionPaperImportService._();

  static const List<String> supportedExtensions = <String>[
    'pdf',
    'docx',
    'doc',
    'xlsx',
    'csv',
    'tsv',
    'txt',
    'rtf',
    'odt',
    'md',
    'html',
    'htm',
  ];

  static const List<QuestionnaireTemplatePreset> templatePresets =
      <QuestionnaireTemplatePreset>[
        QuestionnaireTemplatePreset(
          id: 'default',
          label: 'Default \u00B7 35 Multiple Choice',
          sections: <QuestionnaireTemplateSectionConfig>[
            QuestionnaireTemplateSectionConfig(
              questionType: 'multiple_choice',
              itemCount: 35,
              pointsPerItem: 1,
            ),
          ],
        ),
        QuestionnaireTemplatePreset(
          id: 'mixed',
          label: 'Mixed \u00B7 20 MC / 10 T\u2013F / 5 ID',
          sections: <QuestionnaireTemplateSectionConfig>[
            QuestionnaireTemplateSectionConfig(
              questionType: 'multiple_choice',
              itemCount: 20,
              pointsPerItem: 1,
            ),
            QuestionnaireTemplateSectionConfig(
              questionType: 'true_false',
              itemCount: 10,
              pointsPerItem: 1,
            ),
            QuestionnaireTemplateSectionConfig(
              questionType: 'identification',
              itemCount: 5,
              pointsPerItem: 1,
            ),
          ],
        ),
        QuestionnaireTemplatePreset(
          id: 'uploaded-exam',
          label: 'Uploaded STI Midterm \u00B7 35 MC \u00D7 2 pts',
          sections: <QuestionnaireTemplateSectionConfig>[
            QuestionnaireTemplateSectionConfig(
              questionType: 'multiple_choice',
              itemCount: 35,
              pointsPerItem: 2,
            ),
          ],
        ),
        QuestionnaireTemplatePreset(
          id: 'sti',
          label: 'STI example \u00B7 Two Multiple Choice sections',
          sections: <QuestionnaireTemplateSectionConfig>[
            QuestionnaireTemplateSectionConfig(
              questionType: 'multiple_choice',
              itemCount: 15,
              pointsPerItem: 2,
            ),
            QuestionnaireTemplateSectionConfig(
              questionType: 'multiple_choice',
              itemCount: 20,
              pointsPerItem: 3,
            ),
          ],
        ),
        QuestionnaireTemplatePreset(
          id: 'sti-mixed',
          label: 'Mixed STI \u00B7 15 MC (2 pts) / 20 MC (3 pts) / 5 ID / 5 T\u2013F',
          sections: <QuestionnaireTemplateSectionConfig>[
            QuestionnaireTemplateSectionConfig(
              questionType: 'multiple_choice',
              itemCount: 15,
              pointsPerItem: 2,
            ),
            QuestionnaireTemplateSectionConfig(
              questionType: 'multiple_choice',
              itemCount: 20,
              pointsPerItem: 3,
            ),
            QuestionnaireTemplateSectionConfig(
              questionType: 'identification',
              itemCount: 5,
              pointsPerItem: 1,
            ),
            QuestionnaireTemplateSectionConfig(
              questionType: 'true_false',
              itemCount: 5,
              pointsPerItem: 1,
            ),
          ],
        ),
        QuestionnaireTemplatePreset(
          id: 'mc-50',
          label: '50 Multiple Choice \u00B7 50 MC \u00D7 1 pt',
          sections: <QuestionnaireTemplateSectionConfig>[
            QuestionnaireTemplateSectionConfig(
              questionType: 'multiple_choice',
              itemCount: 50,
              pointsPerItem: 1,
            ),
          ],
        ),
      ];

  static String normalizeQuestionType(String? rawType) {
    final lower = (rawType ?? '').trim().toLowerCase();
    if (lower.contains('multiple') ||
        lower == 'mc' ||
        lower == 'mcq' ||
        lower == 'multiple_choice') {
      return 'multiple_choice';
    }
    if (lower.contains('true') ||
        lower.contains('false') ||
        lower == 'tf' ||
        lower == 't/f' ||
        lower == 'true_false') {
      return 'true_false';
    }
    if (lower.contains('ident') ||
        lower.contains('fill') ||
        lower == 'id' ||
        lower == 'identification') {
      return 'identification';
    }
    return 'multiple_choice';
  }

  static String labelForType(String qType) {
    switch (normalizeQuestionType(qType)) {
      case 'multiple_choice':
        return 'Multiple Choice';
      case 'true_false':
        return 'True or False';
      case 'identification':
        return 'Identification';
      default:
        return 'Multiple Choice';
    }
  }

  static String instructionForType(String qType) {
    switch (normalizeQuestionType(qType)) {
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

  static String formatPoints(num value) {
    final d = value.toDouble();
    if (d == d.roundToDouble()) {
      return d.toInt().toString();
    }
    return d
        .toStringAsFixed(2)
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
  }

  static String subpartLetterFromIndex(int index) {
    var n = index + 1;
    var label = '';
    while (n > 0) {
      label = String.fromCharCode(65 + ((n - 1) % 26)) + label;
      n = (n - 1) ~/ 26;
    }
    return label.isEmpty ? 'A' : label;
  }

  static String romanNumeral(int n) {
    const numerals = <String>[
      'I',
      'II',
      'III',
      'IV',
      'V',
      'VI',
      'VII',
      'VIII',
      'IX',
      'X',
      'XI',
      'XII',
      'XIII',
      'XIV',
      'XV',
      'XVI',
      'XVII',
      'XVIII',
      'XIX',
      'XX',
    ];
    if (n >= 1 && n <= numerals.length) return numerals[n - 1];
    return '$n';
  }

  static int? parseRomanNumeral(String raw) {
    final clean = raw.trim().toUpperCase();
    final direct = int.tryParse(clean);
    if (direct != null && direct > 0) return direct;
    const numerals = <String>[
      'I',
      'II',
      'III',
      'IV',
      'V',
      'VI',
      'VII',
      'VIII',
      'IX',
      'X',
      'XI',
      'XII',
      'XIII',
      'XIV',
      'XV',
      'XVI',
      'XVII',
      'XVIII',
      'XIX',
      'XX',
    ];
    final idx = numerals.indexOf(clean);
    return idx >= 0 ? idx + 1 : null;
  }

  /// Formats a CheckMate Part heading:
  /// - When a question type appears once (`subpartLetter == null`):
  ///   `Part I. Multiple Choice`, `Part II. Identification`, `Part III. True or False`
  /// - When a question type repeats (`subpartLetter != null`):
  ///   `Part I. Multiple Choice - A. 2 pts each`, `Part I. Multiple Choice - B. 3 pts each`
  static String formatPartHeading({
    required int partNumber,
    required String questionType,
    String? subpartLetter,
    num pointsPerItem = 1,
  }) {
    final roman = romanNumeral(partNumber);
    final label = labelForType(questionType);
    final cleanSub = subpartLetter?.trim() ?? '';
    if (cleanSub.isEmpty) {
      return 'Part $roman. $label';
    }
    final ptsStr = formatPoints(pointsPerItem);
    return 'Part $roman. $label - $cleanSub. $ptsStr pts each';
  }

  /// Formats an automatic section name based on 1-based [sectionOrder] and
  /// [questionType], e.g. `"Part I. Multiple Choice"` or
  /// `"Part I. Multiple Choice - A. 2 pts each"`.
  static String autoSectionName(
    int sectionOrder,
    String questionType, {
    String? subpartLetter,
    num? points,
  }) {
    return formatPartHeading(
      partNumber: sectionOrder,
      questionType: questionType,
      subpartLetter: subpartLetter,
      pointsPerItem: points ?? 1,
    );
  }

  /// Resolves an ordered list of [QuestionnaireTemplateSectionConfig] items
  /// into [ResolvedTemplateSection] objects with:
  /// - One Roman-numeral Part number per distinct question type in order of first appearance.
  /// - Lettered subparts (`A`, `B`, ...) when a question type repeats, preserving relative order.
  /// - Plain `Part <Roman>. <Type>` heading when a question type appears once, with
  ///   its point value recorded on `pointsInstructionLine`.
  /// - Continuous item numbering (`startItem..endItem`) across all sections.
  static List<ResolvedTemplateSection> resolveTemplateSections(
    List<QuestionnaireTemplateSectionConfig> configs,
  ) {
    if (configs.isEmpty) return const <ResolvedTemplateSection>[];

    final typeCounts = <String, int>{};
    final partByType = <String, int>{};
    for (final cfg in configs) {
      final t = normalizeQuestionType(cfg.questionType);
      typeCounts[t] = (typeCounts[t] ?? 0) + 1;
      if (!partByType.containsKey(t)) {
        partByType[t] = partByType.length + 1;
      }
    }

    final seenByType = <String, int>{};
    final resolved = <ResolvedTemplateSection>[];
    var nextItem = 1;

    for (var i = 0; i < configs.length; i++) {
      final cfg = configs[i];
      final t = normalizeQuestionType(cfg.questionType);
      final count = math.max(0, cfg.itemCount);
      final pts = cfg.pointsPerItem > 0 ? cfg.pointsPerItem : 1.0;
      final partNum = partByType[t] ?? (i + 1);
      final roman = romanNumeral(partNum);
      final occIdx = seenByType[t] ?? 0;
      seenByType[t] = occIdx + 1;

      final isRepeated = (typeCounts[t] ?? 1) > 1;
      final subpart = isRepeated ? subpartLetterFromIndex(occIdx) : null;
      final heading = formatPartHeading(
        partNumber: partNum,
        questionType: t,
        subpartLetter: subpart,
        pointsPerItem: pts,
      );
      final instruction = instructionForType(t);
      final start = count > 0 ? nextItem : nextItem;
      final end = count > 0 ? (nextItem + count - 1) : nextItem;
      if (count > 0) {
        nextItem = end + 1;
      }

      final secLetter = subpart ?? subpartLetterFromIndex(i);
      final itemWord = count == 1 ? 'item' : 'items';
      final ptsStr = formatPoints(pts);
      final ptWord = pts == 1 ? 'point' : 'points';
      final pointsLine =
          '$secLetter.  ($count $itemWord x $ptsStr $ptWord - $ptsStr pts each)';

      resolved.add(
        ResolvedTemplateSection(
          sectionOrder: i + 1,
          partNumber: partNum,
          partRoman: roman,
          subpartLetter: subpart,
          questionType: t,
          heading: heading,
          instructionLine: instruction,
          pointsInstructionLine: pointsLine,
          itemCount: count,
          pointsPerItem: pts,
          startItem: start,
          endItem: end,
        ),
      );
    }

    return resolved;
  }

  /// Computes canonical CheckMate section headings (`Part I. Multiple Choice - A. 2 pts each`,
  /// `Part II. Identification`, etc.) for a list of section maps.
  static List<String> computeSectionHeadingsForMaps(
    List<Map<String, dynamic>> sections,
  ) {
    if (sections.isEmpty) return const <String>[];
    final configs = sections.map((s) {
      final qType = normalizeQuestionType(
        s['question_type']?.toString() ?? s['type']?.toString(),
      );
      final pts =
          double.tryParse(s['default_points']?.toString() ?? '') ?? 1.0;
      return QuestionnaireTemplateSectionConfig(
        questionType: qType,
        itemCount: 1,
        pointsPerItem: pts > 0 ? pts : 1.0,
      );
    }).toList();
    return resolveTemplateSections(configs).map((r) => r.heading).toList();
  }

  static ImportedQuestionPaper parseBytes({
    required Uint8List bytes,
    required String fileName,
    List<QuestionnaireTemplateSectionConfig>? expectedTemplate,
  }) {
    final lowerName = fileName.trim().toLowerCase();
    final isZipHeader =
        bytes.length >= 4 && bytes[0] == 0x50 && bytes[1] == 0x4B;
    final isPdfHeader =
        bytes.length >= 4 &&
        bytes[0] == 0x25 && // %
        bytes[1] == 0x50 && // P
        bytes[2] == 0x44 && // D
        bytes[3] == 0x46; // F

    if (lowerName.endsWith('.xlsx')) {
      final rows = _extractRowsFromXlsx(bytes);
      final tabular = _tryParseTabularRows(
        rows: rows,
        fileName: fileName,
        expectedTemplate: expectedTemplate,
      );
      if (tabular != null && tabular.totalQuestions > 0) return tabular;
      final lines = rows
          .map((r) => r.where((c) => c.trim().isNotEmpty).join(' '))
          .where((l) => l.trim().isNotEmpty)
          .toList();
      return _parseExtractedLines(
        lines: lines,
        fileName: fileName,
        expectedTemplate: expectedTemplate,
      );
    }

    if (lowerName.endsWith('.csv') || lowerName.endsWith('.tsv')) {
      final isTsv = lowerName.endsWith('.tsv');
      final rows = _extractRowsFromDelimitedText(
        bytes,
        delimiter: isTsv ? '\t' : ',',
      );
      final tabular = _tryParseTabularRows(
        rows: rows,
        fileName: fileName,
        expectedTemplate: expectedTemplate,
      );
      if (tabular != null && tabular.totalQuestions > 0) return tabular;
      final lines = _extractLinesFromPlainText(bytes);
      return _parseExtractedLines(
        lines: lines,
        fileName: fileName,
        expectedTemplate: expectedTemplate,
      );
    }

    List<String> lines;
    var unreadablePages = const <int>[];
    if (lowerName.endsWith('.pdf') || isPdfHeader) {
      final pdfResult = _extractLinesFromPdfWithDiagnostics(bytes);
      lines = pdfResult.lines;
      unreadablePages = pdfResult.unreadablePages;
    } else if (lowerName.endsWith('.docx')) {
      lines = _extractLinesFromDocx(bytes);
    } else if (lowerName.endsWith('.odt')) {
      lines = _extractLinesFromOdt(bytes);
    } else if (isZipHeader) {
      lines = _extractLinesFromZipArchive(bytes, fileName: fileName);
    } else if (lowerName.endsWith('.rtf')) {
      lines = _extractLinesFromRtf(bytes);
    } else if (lowerName.endsWith('.html') || lowerName.endsWith('.htm')) {
      lines = _extractLinesFromHtml(bytes);
    } else if (lowerName.endsWith('.doc')) {
      lines = _extractLinesFromLegacyDoc(bytes);
    } else {
      lines = _extractLinesFromPlainText(bytes);
    }

    return _parseExtractedLines(
      lines: lines,
      fileName: fileName,
      unreadablePages: unreadablePages,
      expectedTemplate: expectedTemplate,
    );
  }

  // ===========================================================================
  // PDF TEXT EXTRACTION (TWO-COLUMN & SINGLE-COLUMN AWARE)
  // ===========================================================================

  static _PdfExtractionResult _extractLinesFromPdfWithDiagnostics(
    Uint8List bytes,
  ) {
    final document = PdfDocument(inputBytes: bytes);
    try {
      final extractor = PdfTextExtractor(document);
      final allLines = <String>[];
      final unreadablePages = <int>[];

      for (var pageIdx = 0; pageIdx < document.pages.count; pageIdx++) {
        final page = document.pages[pageIdx];
        final pageWidth = page.size.width;
        final pageHeight = page.size.height;
        final textLines = extractor.extractTextLines(
          startPageIndex: pageIdx,
          endPageIndex: pageIdx,
        );

        if (textLines.isEmpty) {
          final fallback = extractor.extractText(
            startPageIndex: pageIdx,
            endPageIndex: pageIdx,
          );
          final pageFallbackLines = <String>[];
          for (final raw in fallback.split(RegExp(r'\r?\n'))) {
            final clean = raw.trim();
            if (clean.isNotEmpty) pageFallbackLines.add(clean);
          }
          if (pageFallbackLines.isEmpty) {
            unreadablePages.add(pageIdx + 1);
          } else {
            allLines.addAll(pageFallbackLines);
          }
          continue;
        }

        double bodyStartY = 0;
        for (final tl in textLines) {
          final t = tl.text.trim();
          // Only look in the top 30% of the page for the student info / header divider
          if (tl.bounds.top <= pageHeight * 0.30 &&
              (t.contains('Name:') ||
                  t.contains('Section:') ||
                  RegExp(r'^_{10,}$').hasMatch(t))) {
            if (tl.bounds.bottom > bodyStartY) {
              bodyStartY = tl.bounds.bottom;
            }
          }
        }

        final headerItems = <TextLine>[];
        final bodyItems = <TextLine>[];
        final footerThresholdY = pageHeight * 0.945;

        for (final tl in textLines) {
          final trimmed = tl.text.trim();
          if (trimmed.isEmpty) continue;
          // Ignore repeating page footers at very bottom of page
          if (tl.bounds.top >= footerThresholdY &&
              RegExp(
                r'^(?:page\s+\d+(?:\s+of\s+\d+)?|\d+\s*/\s*\d+)$',
                caseSensitive: false,
              ).hasMatch(trimmed)) {
            continue;
          }
          if (bodyStartY > 0 && tl.bounds.top <= bodyStartY + 2) {
            headerItems.add(tl);
          } else {
            bodyItems.add(tl);
          }
        }

        // Only emit page header lines on Page 1 so repeating headers on Page 2+
        // never split a wrapped question stem or Option D across page breaks.
        if (pageIdx == 0 && headerItems.isNotEmpty) {
          headerItems.sort((a, b) {
            final dy = a.bounds.top - b.bounds.top;
            if (dy.abs() > 3) return dy.compareTo(0);
            return a.bounds.left.compareTo(b.bounds.left);
          });
          for (final h in headerItems) {
            for (final l in h.text.split(RegExp(r'\r?\n'))) {
              final clean = l.trim();
              if (clean.isNotEmpty) allLines.add(clean);
            }
          }
        }

        if (bodyItems.isEmpty) {
          if (headerItems.isEmpty) {
            unreadablePages.add(pageIdx + 1);
          }
          continue;
        }

        // Split any TextLine whose words span across the two-column center gutter
        final colSplitX = pageWidth * 0.48;
        final leftSegments = <_PositionedTextSegment>[];
        final rightSegments = <_PositionedTextSegment>[];
        final allSegments = <_PositionedTextSegment>[];
        var wideUnbrokenLines = 0;

        for (final b in bodyItems) {
          final words = b.wordCollection;
          var splitAcrossColumns = false;

          if (words.length >= 2 &&
              b.bounds.left < colSplitX &&
              b.bounds.right > pageWidth * 0.54) {
            final leftWords = <TextWord>[];
            final rightWords = <TextWord>[];
            for (final w in words) {
              if (w.bounds.left < colSplitX) {
                leftWords.add(w);
              } else {
                rightWords.add(w);
              }
            }
            if (leftWords.isNotEmpty && rightWords.isNotEmpty) {
              final leftRightEdge = leftWords
                  .map((w) => w.bounds.right)
                  .reduce(math.max);
              final rightLeftEdge = rightWords
                  .map((w) => w.bounds.left)
                  .reduce(math.min);
              final gutterGap = rightLeftEdge - leftRightEdge;
              final rightText = rightWords.map((w) => w.text).join(' ').trim();
              if (gutterGap >= 8.0 ||
                  RegExp(
                    r'^(?:\d{1,3}|[A-Da-d]|Part\s+[IVX\d]+)[\.\)]\s*',
                  ).hasMatch(rightText)) {
                splitAcrossColumns = true;
                final lSeg = _segmentFromWords(leftWords);
                final rSeg = _segmentFromWords(rightWords);
                if (lSeg != null) {
                  leftSegments.add(lSeg);
                  allSegments.add(lSeg);
                }
                if (rSeg != null) {
                  rightSegments.add(rSeg);
                  allSegments.add(rSeg);
                }
              }
            }
          }

          if (!splitAcrossColumns) {
            final seg = _PositionedTextSegment(
              text: b.text.trim(),
              bounds: b.bounds,
            );
            allSegments.add(seg);
            if (b.bounds.left < colSplitX &&
                b.bounds.right > pageWidth * 0.62 &&
                b.bounds.width > pageWidth * 0.52) {
              wideUnbrokenLines++;
            }
            if (b.bounds.left < colSplitX) {
              leftSegments.add(seg);
            } else {
              rightSegments.add(seg);
            }
          }
        }

        if (rightSegments.length >= 2 &&
            wideUnbrokenLines <= bodyItems.length ~/ 3) {
          allLines.addAll(
            _mergeAndSortSegments(
              leftSegments,
              maxHorizontalGap: pageWidth * 0.18,
            ),
          );
          allLines.addAll(
            _mergeAndSortSegments(
              rightSegments,
              maxHorizontalGap: pageWidth * 0.18,
            ),
          );
        } else {
          allLines.addAll(
            _mergeAndSortSegments(
              allSegments,
              maxHorizontalGap: pageWidth * 0.25,
            ),
          );
        }
      }

      return _PdfExtractionResult(
        lines: allLines,
        unreadablePages: unreadablePages,
      );
    } finally {
      document.dispose();
    }
  }

  static _PositionedTextSegment? _segmentFromWords(List<TextWord> words) {
    if (words.isEmpty) return null;
    final sb = StringBuffer();
    double left = words.first.bounds.left;
    double top = words.first.bounds.top;
    double right = words.first.bounds.right;
    double bottom = words.first.bounds.bottom;
    Rect? prev;

    for (final w in words) {
      final wt = w.text;
      if (wt.isEmpty) continue;
      if (prev != null && (w.bounds.left - prev.right) > 1.2) {
        if (!sb.toString().endsWith(' ') && !wt.startsWith(' ')) {
          sb.write(' ');
        }
      }
      sb.write(wt);
      left = math.min(left, w.bounds.left);
      top = math.min(top, w.bounds.top);
      right = math.max(right, w.bounds.right);
      bottom = math.max(bottom, w.bounds.bottom);
      prev = w.bounds;
    }

    final clean = sb.toString().trim();
    if (clean.isEmpty) return null;
    return _PositionedTextSegment(
      text: clean,
      bounds: Rect.fromLTRB(left, top, right, bottom),
    );
  }

  static List<String> _mergeAndSortSegments(
    List<_PositionedTextSegment> items, {
    double maxHorizontalGap = 72.0,
  }) {
    if (items.isEmpty) return const <String>[];
    final sorted = List<_PositionedTextSegment>.from(items)
      ..sort((a, b) {
        final dy = a.bounds.top - b.bounds.top;
        if (dy.abs() > 3.5) return dy.compareTo(0);
        return a.bounds.left.compareTo(b.bounds.left);
      });

    final out = <String>[];
    Rect? prevBounds;
    final currentLineBuffer = StringBuffer();

    void flushBuffer() {
      if (currentLineBuffer.isEmpty) return;
      for (final sub in currentLineBuffer.toString().split(RegExp(r'\r?\n'))) {
        final clean = sub.trim();
        if (clean.isNotEmpty) out.add(clean);
      }
      currentLineBuffer.clear();
    }

    for (final item in sorted) {
      final t = item.text.trim();
      if (t.isEmpty) continue;
      final sameRow =
          prevBounds != null && (item.bounds.top - prevBounds.top).abs() <= 3.5;
      final horizontalGap = prevBounds == null
          ? 0.0
          : (item.bounds.left - prevBounds.right);
      final startsNewNumberedQuestion = RegExp(r'^\d{1,3}[\.\)]\s+').hasMatch(t);
      final startsNewOption =
          RegExp(r'^\*?\(?[A-Da-d][\.\)]\s+').hasMatch(t) &&
          horizontalGap > 4.0;
      final startsNewPartHeader = RegExp(
        r'^Part\s+[IVX\d]+[\.\:\-\s]',
        caseSensitive: false,
      ).hasMatch(t);

      if (sameRow &&
          horizontalGap <= maxHorizontalGap &&
          !startsNewNumberedQuestion &&
          !startsNewOption &&
          !startsNewPartHeader) {
        currentLineBuffer.write(' $t');
        prevBounds = Rect.fromLTRB(
          prevBounds.left,
          math.min(prevBounds.top, item.bounds.top),
          math.max(prevBounds.right, item.bounds.right),
          math.max(prevBounds.bottom, item.bounds.bottom),
        );
      } else {
        flushBuffer();
        currentLineBuffer.write(t);
        prevBounds = item.bounds;
      }
    }
    flushBuffer();
    return out;
  }

  // ===========================================================================
  // WORD (.DOCX), ODT, XLSX & ZIP ARCHIVE EXTRACTION
  // ===========================================================================

  static List<String> _extractLinesFromZipArchive(
    Uint8List bytes, {
    required String fileName,
  }) {
    final archive = ZipDecoder().decodeBytes(bytes);
    if (archive.findFile('word/document.xml') != null) {
      return _extractLinesFromDocx(bytes);
    }
    if (archive.findFile('content.xml') != null) {
      return _extractLinesFromOdt(bytes);
    }
    if (archive.findFile('xl/workbook.xml') != null) {
      final rows = _extractRowsFromXlsx(bytes);
      return rows
          .map((r) => r.where((c) => c.trim().isNotEmpty).join(' '))
          .where((l) => l.trim().isNotEmpty)
          .toList();
    }
    throw Exception('Unsupported archive format for "$fileName".');
  }

  static List<String> _extractLinesFromDocx(Uint8List bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final docFile = archive.findFile('word/document.xml');
    if (docFile == null) {
      throw Exception(
        'Invalid Word document (.docx): word/document.xml missing.',
      );
    }

    final xmlContent = utf8.decode(
      docFile.content as List<int>,
      allowMalformed: true,
    );
    final doc = XmlDocument.parse(xmlContent);
    final lines = <String>[];

    for (final p in doc.findAllElements('w:p')) {
      final sb = StringBuffer();
      for (final node in p.descendants.whereType<XmlElement>()) {
        if (node.name.qualified == 'w:t') {
          sb.write(node.innerText);
        } else if (node.name.qualified == 'w:br' ||
            node.name.qualified == 'w:cr') {
          sb.write('\n');
        } else if (node.name.qualified == 'w:tab') {
          sb.write('  ');
        }
      }
      final paragraphText = sb.toString().trim();
      if (paragraphText.isNotEmpty) {
        for (final sub in paragraphText.split(RegExp(r'\r?\n'))) {
          final clean = sub.trim();
          if (clean.isNotEmpty) lines.add(clean);
        }
      }
    }
    return lines;
  }

  static List<String> _extractLinesFromOdt(Uint8List bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final contentFile = archive.findFile('content.xml');
    if (contentFile == null) {
      throw Exception('Invalid OpenDocument (.odt): content.xml missing.');
    }

    final xmlContent = utf8.decode(
      contentFile.content as List<int>,
      allowMalformed: true,
    );
    final doc = XmlDocument.parse(xmlContent);
    final lines = <String>[];

    for (final p in doc.findAllElements('text:p')) {
      final text = p.innerText.trim();
      if (text.isNotEmpty) {
        for (final sub in text.split(RegExp(r'\r?\n'))) {
          final clean = sub.trim();
          if (clean.isNotEmpty) lines.add(clean);
        }
      }
    }
    return lines;
  }

  static List<List<String>> _extractRowsFromXlsx(Uint8List bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final sharedStrings = <String>[];

    final sharedFile = archive.findFile('xl/sharedStrings.xml');
    if (sharedFile != null) {
      final sharedXml = utf8.decode(
        sharedFile.content as List<int>,
        allowMalformed: true,
      );
      final doc = XmlDocument.parse(sharedXml);
      for (final si in doc.findAllElements('si')) {
        final buf = StringBuffer();
        for (final t in si.findAllElements('t')) {
          buf.write(t.innerText);
        }
        sharedStrings.add(buf.toString());
      }
    }

    final sheetFiles = archive.files
        .where(
          (f) =>
              f.isFile &&
              f.name.startsWith('xl/worksheets/sheet') &&
              f.name.endsWith('.xml'),
        )
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));

    final rows = <List<String>>[];
    for (final sheetFile in sheetFiles) {
      final sheetXml = utf8.decode(
        sheetFile.content as List<int>,
        allowMalformed: true,
      );
      final doc = XmlDocument.parse(sheetXml);
      for (final rowEl in doc.findAllElements('row')) {
        final rowCells = <String>[];
        for (final cEl in rowEl.findElements('c')) {
          final cellType = cEl.getAttribute('t') ?? '';
          String value = '';
          if (cellType == 'inlineStr') {
            value = cEl
                .findAllElements('t')
                .map((e) => e.innerText)
                .join();
          } else {
            final vEl = cEl.findElements('v').firstOrNull;
            final rawVal = vEl?.innerText.trim() ?? '';
            if (cellType == 's') {
              final idx = int.tryParse(rawVal);
              if (idx != null && idx >= 0 && idx < sharedStrings.length) {
                value = sharedStrings[idx];
              }
            } else {
              value = rawVal;
            }
          }
          rowCells.add(value.trim());
        }
        if (rowCells.any((c) => c.isNotEmpty)) {
          rows.add(rowCells);
        }
      }
    }
    return rows;
  }

  // ===========================================================================
  // CSV / TSV, RTF, HTML, LEGACY .DOC & PLAIN TEXT EXTRACTION
  // ===========================================================================

  static String _decodeTextBytes(Uint8List bytes) {
    if (bytes.length >= 2) {
      if (bytes[0] == 0xFF && bytes[1] == 0xFE) {
        final codeUnits = <int>[];
        for (var i = 2; i + 1 < bytes.length; i += 2) {
          codeUnits.add(bytes[i] | (bytes[i + 1] << 8));
        }
        return String.fromCharCodes(codeUnits);
      }
      if (bytes[0] == 0xFE && bytes[1] == 0xFF) {
        final codeUnits = <int>[];
        for (var i = 2; i + 1 < bytes.length; i += 2) {
          codeUnits.add((bytes[i] << 8) | bytes[i + 1]);
        }
        return String.fromCharCodes(codeUnits);
      }
    }
    try {
      return utf8.decode(bytes);
    } catch (_) {
      return latin1.decode(bytes);
    }
  }

  static List<String> _extractLinesFromPlainText(Uint8List bytes) {
    final content = _decodeTextBytes(bytes);
    return content
        .split(RegExp(r'\r?\n'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
  }

  static List<String> _extractLinesFromRtf(Uint8List bytes) {
    var text = _decodeTextBytes(bytes);
    text = text
        .replaceAll(RegExp(r'\\(par|line|row)\b\s*'), '\n')
        .replaceAll(RegExp(r'\\tab\b\s*'), '  ')
        .replaceAllMapped(RegExp(r"\\'([0-9a-fA-F]{2})"), (m) {
          final code = int.tryParse(m.group(1)!, radix: 16);
          return code != null ? String.fromCharCode(code) : '';
        })
        .replaceAllMapped(RegExp(r'\\u(-?\d+)\??'), (m) {
          var code = int.tryParse(m.group(1)!) ?? 0;
          if (code < 0) code += 65536;
          return code > 0 ? String.fromCharCode(code) : '';
        })
        .replaceAll(
          RegExp(
            r'\{\\(?:fonttbl|colortbl|stylesheet|info|pict|\*\\[a-z]+)[^}]*\}',
          ),
          '',
        )
        .replaceAll(RegExp(r'\\[a-zA-Z]+-?\d*\s?'), '')
        .replaceAll(RegExp(r'[{}]'), '');
    return text
        .split(RegExp(r'\r?\n'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
  }

  static List<String> _extractLinesFromHtml(Uint8List bytes) {
    var html = _decodeTextBytes(bytes);
    html = html
        .replaceAll(
          RegExp(r'<(script|style)[^>]*>[\s\S]*?</\1>', caseSensitive: false),
          '',
        )
        .replaceAll(
          RegExp(
            r'</?(p|div|br|li|tr|h[1-6]|section|article|header|footer)[^>]*>',
            caseSensitive: false,
          ),
          '\n',
        )
        .replaceAll(RegExp(r'</?(td|th)[^>]*>', caseSensitive: false), '  ')
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'");
    return html
        .split(RegExp(r'\r?\n'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
  }

  static List<String> _extractLinesFromLegacyDoc(Uint8List bytes) {
    final asText = _decodeTextBytes(bytes);
    if (asText.trimLeft().startsWith(r'{\rtf')) {
      return _extractLinesFromRtf(bytes);
    }
    if (asText.contains('<html') || asText.contains('<w:document')) {
      return _extractLinesFromHtml(bytes);
    }

    final buffer = StringBuffer();
    for (var i = 0; i < bytes.length; i++) {
      final b = bytes[i];
      if (b == 0x0D || b == 0x0A) {
        buffer.write('\n');
      } else if (b >= 32 && b <= 126) {
        buffer.writeCharCode(b);
      }
    }
    return buffer
        .toString()
        .split(RegExp(r'\r?\n'))
        .map((l) => l.trim())
        .where(
          (l) =>
              l.length >= 3 &&
              RegExp(r'[A-Za-z]{2,}').hasMatch(l) &&
              !l.contains('Microsoft Word') &&
              !l.contains('Normal.dotm') &&
              !l.contains('SummaryInformation'),
        )
        .toList();
  }

  static List<List<String>> _extractRowsFromDelimitedText(
    Uint8List bytes, {
    required String delimiter,
  }) {
    final content = _decodeTextBytes(bytes);
    final rows = <List<String>>[];
    for (final rawLine in content.split(RegExp(r'\r?\n'))) {
      if (rawLine.trim().isEmpty) continue;
      rows.add(_parseDelimitedLine(rawLine, delimiter));
    }
    return rows;
  }

  static List<String> _parseDelimitedLine(String line, String delimiter) {
    final cells = <String>[];
    final current = StringBuffer();
    var inQuotes = false;

    for (var i = 0; i < line.length; i++) {
      final ch = line[i];
      if (ch == '"') {
        if (inQuotes && i + 1 < line.length && line[i + 1] == '"') {
          current.write('"');
          i++;
        } else {
          inQuotes = !inQuotes;
        }
      } else if (!inQuotes && ch == delimiter) {
        cells.add(current.toString().trim());
        current.clear();
      } else {
        current.write(ch);
      }
    }
    cells.add(current.toString().trim());
    return cells;
  }

  /// Parses structured spreadsheet tables (CSV / TSV / XLSX) when columns like
  /// `Question`, `Type`, `Choice A..D`, `Answer`, `Points`, `Section` are present.
  static ImportedQuestionPaper? _tryParseTabularRows({
    required List<List<String>> rows,
    required String fileName,
    List<QuestionnaireTemplateSectionConfig>? expectedTemplate,
  }) {
    if (rows.length < 2) return null;

    int headerRowIdx = -1;
    int colQuestion = -1;
    int colType = -1;
    int colSection = -1;
    int colChoiceA = -1;
    int colChoiceB = -1;
    int colChoiceC = -1;
    int colChoiceD = -1;
    int colAnswer = -1;
    int colPoints = -1;

    for (var r = 0; r < rows.length && r < 10; r++) {
      final row = rows[r];
      if (row.length < 2) continue;
      for (var c = 0; c < row.length; c++) {
        final h = row[c].trim().toLowerCase();
        if (h == 'question' ||
            h == 'question text' ||
            h == 'question_text' ||
            h == 'item' ||
            h == 'stem' ||
            h == 'prompt') {
          colQuestion = c;
        } else if (h == 'type' ||
            h == 'question type' ||
            h == 'question_type' ||
            h == 'test type' ||
            h == 'exam type') {
          colType = c;
        } else if (h == 'section' || h == 'part' || h == 'subpart') {
          colSection = c;
        } else if (h == 'a' ||
            h == 'choice a' ||
            h == 'option a' ||
            h == 'choice_a' ||
            h == 'option_a') {
          colChoiceA = c;
        } else if (h == 'b' ||
            h == 'choice b' ||
            h == 'option b' ||
            h == 'choice_b' ||
            h == 'option_b') {
          colChoiceB = c;
        } else if (h == 'c' ||
            h == 'choice c' ||
            h == 'option c' ||
            h == 'choice_c' ||
            h == 'option_c') {
          colChoiceC = c;
        } else if (h == 'd' ||
            h == 'choice d' ||
            h == 'option d' ||
            h == 'choice_d' ||
            h == 'option_d') {
          colChoiceD = c;
        } else if (h == 'answer' ||
            h == 'correct answer' ||
            h == 'correct_answer' ||
            h == 'answer key' ||
            h == 'key') {
          colAnswer = c;
        } else if (h == 'points' || h == 'point' || h == 'pts' || h == 'score') {
          colPoints = c;
        }
      }
      if (colQuestion >= 0) {
        headerRowIdx = r;
        break;
      }
    }

    if (headerRowIdx < 0 || colQuestion < 0) return null;

    final sectionBuilders = <_SectionBuilder>[];
    _SectionBuilder? activeSec;

    for (var r = headerRowIdx + 1; r < rows.length; r++) {
      final row = rows[r];
      String cell(int idx) =>
          (idx >= 0 && idx < row.length) ? row[idx].trim() : '';

      final qText = _stripLeadingQuestionNumber(cell(colQuestion));
      if (qText.isEmpty) continue;

      final rawType = cell(colType).toLowerCase();
      final rawSecLabel = cell(colSection);
      final choiceA = cell(colChoiceA);
      final choiceB = cell(colChoiceB);
      final choiceC = cell(colChoiceC);
      final choiceD = cell(colChoiceD);
      final rawAnswer = cell(colAnswer);
      final pts = double.tryParse(cell(colPoints)) ?? 1.0;

      final choices = <String>[choiceA, choiceB, choiceC, choiceD];
      final nonEmptyChoices = choices.where((c) => c.isNotEmpty).length;

      String qType;
      if (rawType.contains('multiple') || rawType == 'mc' || rawType == 'mcq') {
        qType = 'multiple_choice';
      } else if (rawType.contains('true') ||
          rawType.contains('false') ||
          rawType == 'tf' ||
          rawType == 't/f') {
        qType = 'true_false';
      } else if (rawType.contains('ident') || rawType.contains('fill')) {
        qType = 'identification';
      } else if (nonEmptyChoices >= 2) {
        qType = 'multiple_choice';
      } else if (_isTrueOrFalseAnswer(rawAnswer)) {
        qType = 'true_false';
      } else {
        qType = 'identification';
      }

      final cleanPts = pts > 0 ? pts : 1.0;
      if (activeSec == null ||
          activeSec.questionType != qType ||
          (rawSecLabel.isNotEmpty && activeSec.rawHeading != rawSecLabel) ||
          (activeSec.defaultPoints - cleanPts).abs() > 0.0001) {
        activeSec = _SectionBuilder(
          rawHeading: rawSecLabel.isEmpty ? null : rawSecLabel,
          questionType: qType,
          defaultPoints: cleanPts,
          hasExplicitHeading: rawSecLabel.isNotEmpty,
          hasExplicitPoints: cell(colPoints).isNotEmpty,
        );
        sectionBuilders.add(activeSec);
      }

      final normalizedAnswer = _normalizeAnswerForType(
        rawAnswer,
        qType,
        choices: choices,
      );

      activeSec.questions.add(
        _buildValidatedQuestion(
          questionNumber: activeSec.questions.length + 1,
          sourceQuestionNumber: activeSec.questions.length + 1,
          questionText: qText,
          questionType: qType,
          points: cleanPts,
          choices: qType == 'multiple_choice' ? choices : const <String>[],
          correctAnswer: normalizedAnswer,
          classificationAmbiguous: false,
        ),
      );
    }

    final rawSections = sectionBuilders
        .where((b) => b.questions.isNotEmpty)
        .map((b) => b.toSection())
        .toList();
    if (rawSections.isEmpty) return null;

    return finalizeImportedPaper(
      fileName: fileName,
      rawSections: rawSections,
      detectedInstructions: QuestionPaperPdfService.defaultInstructionsText,
      expectedTemplate: expectedTemplate,
    );
  }

  // ===========================================================================
  // STRUCTURED QUESTION, SECTION, CHOICE & METADATA PARSER
  // ===========================================================================

  static ImportedQuestionPaper _parseExtractedLines({
    required List<String> lines,
    required String fileName,
    List<int> unreadablePages = const <int>[],
    List<QuestionnaireTemplateSectionConfig>? expectedTemplate,
  }) {
    String? detectedType;
    String? detectedSubject;
    String? detectedQuizTitle;
    String? detectedDay;
    String? detectedDate;
    String? detectedStart;
    String? detectedEnd;
    String? detectedRef;
    final noticeLines = <String>[];

    // 1. Inspect header lines (before the first question or section header)
    final headerScanLimit = lines.length < 30 ? lines.length : 30;
    for (var i = 0; i < headerScanLimit; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;
      final lower = line.toLowerCase();

      if (RegExp(r'^_{5,}$').hasMatch(line) ||
          lower.startsWith('name:') ||
          lower.startsWith('section:') ||
          lower.startsWith('date:') ||
          lower.startsWith('notice:') ||
          lower.startsWith('part ') ||
          RegExp(r'^\d{1,3}[\.\)]\s+').hasMatch(line)) {
        break;
      }

      if (lower == 'questionnaire template' ||
          lower == 'checkmate questionnaire template') {
        continue;
      }

      if (RegExp(r'^page\s+\d+$', caseSensitive: false).hasMatch(line)) {
        continue;
      }
      final refWithPage = RegExp(
        r'^(.+?)\s*page\s+\d+$',
        caseSensitive: false,
      ).firstMatch(line);
      if (refWithPage != null) {
        final candidateRef = refWithPage.group(1)!.trim();
        if (candidateRef.isNotEmpty && detectedRef == null) {
          detectedRef = candidateRef;
        }
        continue;
      }
      if (detectedRef == null &&
          RegExp(r'^\d{5,}\s*[\u2013\u2014\-]\s*[A-Za-z0-9]+').hasMatch(line)) {
        detectedRef = line;
        continue;
      }

      final dayMatch = RegExp(
        r'^day\s*(\d+)\s*[:\u2013\u2014\-]\s*(.+)$',
        caseSensitive: false,
      ).firstMatch(line);
      if (dayMatch != null) {
        detectedDay ??= dayMatch.group(1)!.trim();
        detectedDate ??= dayMatch.group(2)!.trim();
        continue;
      }

      if (RegExp(r'\b\d{1,2}:\d{2}\b').hasMatch(line) &&
          RegExp(r'\b(am|pm)\b', caseSensitive: false).hasMatch(line)) {
        final tParts = line.split(RegExp(r'\s*[\u2013\u2014\-]\s*'));
        if (tParts.length >= 2) {
          detectedStart ??= tParts.first.trim().toUpperCase();
          detectedEnd ??= tParts.sublist(1).join(' - ').trim().toUpperCase();
        }
        continue;
      }

      final explicitAssessment = _detectExplicitAssessmentTypeFromHeader(line);
      if (explicitAssessment != null) {
        detectedType ??= explicitAssessment;
        if (['quiz', 'short_quiz', 'long_quiz', 'performance_task', 'laboratory']
            .contains(explicitAssessment)) {
          detectedQuizTitle ??= line;
        }
        continue;
      }

      if (RegExp(
            r'\b(1st|2nd|3rd)\s+term\b',
            caseSensitive: false,
          ).hasMatch(line) ||
          RegExp(r'\bSY\s*\d{4}', caseSensitive: false).hasMatch(line)) {
        continue;
      }

      if (!lower.startsWith('part ') &&
          !lower.startsWith('section ') &&
          !lower.startsWith('test ') &&
          !lower.startsWith('read and analyze') &&
          !lower.startsWith('direction')) {
        detectedSubject ??= line;
      }
    }

    // 2. Helper to identify repeating page header / boilerplate lines so Page 2+
    // headers never pollute option D or question stems.
    bool isRepeatingHeaderOrBoilerplate(String line) {
      final clean = line.trim();
      if (clean.isEmpty) return true;
      final lower = clean.toLowerCase();

      if (lower == 'questionnaire template' ||
          lower == 'checkmate questionnaire template') {
        return true;
      }
      if (RegExp(r'^_{5,}$').hasMatch(clean)) return true;
      if (RegExp(
        r'^(name|section|date)\s*:\s*_*',
        caseSensitive: false,
      ).hasMatch(clean)) {
        return true;
      }
      if (clean.contains('Name:___') ||
          clean.contains('Section:___') ||
          clean.contains('Date:___') ||
          (clean.contains('Name:') && clean.contains('Section:'))) {
        return true;
      }
      if (RegExp(
        r'^page\s+\d+(?:\s+of\s+\d+)?$',
        caseSensitive: false,
      ).hasMatch(clean)) {
        return true;
      }
      if (RegExp(r'^.+\s+page\s+\d+$', caseSensitive: false).hasMatch(clean) &&
          (RegExp(r'\d{5,}').hasMatch(clean) || clean.startsWith('CM-'))) {
        return true;
      }
      if (detectedSubject != null &&
          clean.toLowerCase() == detectedSubject.toLowerCase()) {
        return true;
      }
      if (detectedRef != null &&
          clean.toLowerCase() == detectedRef.toLowerCase()) {
        return true;
      }
      if (detectedQuizTitle != null &&
          clean.toLowerCase() == detectedQuizTitle.toLowerCase()) {
        return true;
      }
      if (RegExp(
        r'^day\s*\d+\s*[:\u2013\u2014\-]',
        caseSensitive: false,
      ).hasMatch(clean)) {
        return true;
      }
      if (RegExp(
        r'^\d{1,2}:\d{2}\s*(am|pm)\s*[\u2013\u2014\-]',
        caseSensitive: false,
      ).hasMatch(clean)) {
        return true;
      }
      if (RegExp(
        r'^(1st|2nd|3rd)\s+term\s*,\s*sy\s*\d{4}',
        caseSensitive: false,
      ).hasMatch(clean)) {
        return true;
      }
      if (const {
        'preliminary examination',
        'midterm examination',
        'pre-final examination',
        'prefinal examination',
        'final examination',
      }.contains(lower)) {
        return true;
      }
      if (RegExp(r'^\d{5,}\s*[\u2013\u2014\-]\s*[A-Za-z0-9]+$').hasMatch(clean)) {
        return true;
      }
      return false;
    }

    // 3. Parse Notice, Ordered Sections, Questions, Choices, and Point Values
    final sectionBuilders = <_SectionBuilder>[];
    _SectionBuilder? currentSection;
    _QuestionBuilder? currentQuestion;
    String? currentChoiceLetter;
    bool inNotice = false;

    _SectionBuilder ensureSection({
      String? inferredType,
      double? defaultPoints,
    }) {
      if (currentSection != null) {
        if (inferredType != null && currentSection!.questionType == null) {
          currentSection!.questionType = inferredType;
        }
        if (defaultPoints != null && !currentSection!.hasExplicitPoints) {
          currentSection!.defaultPoints = defaultPoints;
        }
        return currentSection!;
      }
      final created = _SectionBuilder(
        questionType: inferredType,
        defaultPoints: defaultPoints ?? 1.0,
      );
      sectionBuilders.add(created);
      currentSection = created;
      return created;
    }

    void flushQuestion() {
      final q = currentQuestion;
      if (q == null) return;
      currentQuestion = null;
      currentChoiceLetter = null;

      final resolvedTypeResult = _resolveQuestionTypeWithDiagnostics(q);
      final qType = resolvedTypeResult.questionType;
      final normalizedChoices = <String>[];
      if (qType == 'multiple_choice') {
        for (final letter in const ['A', 'B', 'C', 'D']) {
          normalizedChoices.add((q.choices[letter] ?? '').trim());
        }
      }

      final cleanStem = _stripLeadingQuestionNumber(q.stem.toString().trim());
      if (cleanStem.isEmpty && normalizedChoices.every((c) => c.isEmpty)) {
        return;
      }

      final normalizedAnswer = _normalizeAnswerForType(
        q.correctAnswer,
        qType,
        choices: normalizedChoices,
      );

      // If currentSection has no explicit heading and already contains questions
      // of a different type, start a new section for the new type.
      if (currentSection != null &&
          !currentSection!.hasExplicitHeading &&
          currentSection!.questions.isNotEmpty &&
          currentSection!.questionType != null &&
          currentSection!.questionType != qType) {
        currentSection = _SectionBuilder(
          questionType: qType,
          defaultPoints: q.points > 0 ? q.points : 1.0,
        );
        sectionBuilders.add(currentSection!);
      }

      final sec = ensureSection(
        inferredType: qType,
        defaultPoints: q.points > 0 ? q.points : 1.0,
      );
      final effectivePts = q.points > 0
          ? q.points
          : (sec.defaultPoints > 0 ? sec.defaultPoints : 1.0);

      sec.questions.add(
        _buildValidatedQuestion(
          questionNumber: q.number,
          sourceQuestionNumber: q.number,
          questionText: cleanStem,
          questionType: qType,
          points: effectivePts,
          choices: normalizedChoices,
          correctAnswer: normalizedAnswer,
          classificationAmbiguous: resolvedTypeResult.isAmbiguous,
        ),
      );
    }

    final questionStartRe = RegExp(r'^(\d{1,3})[\.\)]\s*(.*)$');
    final choiceStartRe = RegExp(r'^(\*)?(?:\()?([A-Da-d])[\.\)]\s*(.*)$');
    final answerLineRe = RegExp(
      r'^(?:correct\s+)?(?:answer|ans|key)\s*(\(\s*(?:true\s*(?:\/|or)\s*false|t\s*(?:\/|or)\s*f)\s*\))?\s*[:\-]\s*(.*)$',
      caseSensitive: false,
    );

    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      final lower = line.toLowerCase();

      if (isRepeatingHeaderOrBoilerplate(line)) {
        continue;
      }

      // Notice block before questions start
      if (currentQuestion == null &&
          (currentSection == null || currentSection!.questions.isEmpty)) {
        if (lower == 'notice:' || lower.startsWith('notice:')) {
          inNotice = true;
          noticeLines.add(line);
          continue;
        }
        if (inNotice &&
            RegExp(r'^[\u2022\u2023\u25E6\u2043\u2219\-\*]').hasMatch(line)) {
          noticeLines.add(line);
          continue;
        }
      }

      // Check if line is a Part / Section / Subpart heading or points instruction line
      final parsedHeader = _tryParseSectionHeaderOrPointsLine(
        line,
        hasActiveQuestion: currentQuestion != null,
        activeQuestionHasFourChoices:
            currentQuestion != null &&
            const ['A', 'B', 'C', 'D'].every(
              (l) => (currentQuestion!.choices[l] ?? '').trim().isNotEmpty,
            ),
      );
      if (parsedHeader != null) {
        flushQuestion();
        inNotice = false;

        if (parsedHeader.isInstructionOrPointsLineOnly) {
          // If the current section already has questions and a new direction line
          // ("Read and analyze...") appears, start a new section only if it's a
          // full direction line; if it's a points line right before questions,
          // attach to a new section.
          if (currentSection != null && currentSection!.questions.isNotEmpty) {
            currentSection = _SectionBuilder(
              questionType: parsedHeader.questionType,
              defaultPoints: parsedHeader.pointsPerItem ?? 1.0,
              expectedItemCount: parsedHeader.expectedItemCount,
              subpartLetter: parsedHeader.subpartLetter,
              hasExplicitHeading: parsedHeader.subpartLetter != null,
              hasExplicitPoints: parsedHeader.pointsPerItem != null,
              hasAmbiguousMetadata: parsedHeader.hasAmbiguousMetadata,
            );
            sectionBuilders.add(currentSection!);
          } else {
            final sec = ensureSection(
              inferredType: parsedHeader.questionType,
              defaultPoints: parsedHeader.pointsPerItem,
            );
            if (parsedHeader.questionType != null) {
              sec.questionType = parsedHeader.questionType;
            }
            if (parsedHeader.pointsPerItem != null &&
                parsedHeader.pointsPerItem! > 0) {
              sec.defaultPoints = parsedHeader.pointsPerItem!;
              sec.hasExplicitPoints = true;
            }
            if (parsedHeader.expectedItemCount != null) {
              sec.expectedItemCount = parsedHeader.expectedItemCount;
            }
            if (parsedHeader.subpartLetter != null &&
                sec.subpartLetter == null) {
              sec.subpartLetter = parsedHeader.subpartLetter;
            }
            if (parsedHeader.hasAmbiguousMetadata) {
              sec.hasAmbiguousMetadata = true;
            }
          }
        } else {
          // Explicit Part / Section heading (e.g. "Part I. Multiple Choice - A. 2 pts each"
          // or "Part II. Identification" or "B. (20 items x 3 points)")
          if (currentSection != null &&
              currentSection!.questions.isEmpty &&
              !currentSection!.hasExplicitHeading) {
            currentSection!
              ..rawHeading = parsedHeader.rawHeading
              ..partNumber = parsedHeader.partNumber
              ..subpartLetter = parsedHeader.subpartLetter
              ..questionType =
                  parsedHeader.questionType ?? currentSection!.questionType
              ..hasExplicitHeading = true
              ..hasAmbiguousMetadata =
                  currentSection!.hasAmbiguousMetadata ||
                  parsedHeader.hasAmbiguousMetadata;
            if (parsedHeader.pointsPerItem != null &&
                parsedHeader.pointsPerItem! > 0) {
              currentSection!.defaultPoints = parsedHeader.pointsPerItem!;
              currentSection!.hasExplicitPoints = true;
            }
            if (parsedHeader.expectedItemCount != null) {
              currentSection!.expectedItemCount =
                  parsedHeader.expectedItemCount;
            }
          } else {
            currentSection = _SectionBuilder(
              rawHeading: parsedHeader.rawHeading,
              partNumber: parsedHeader.partNumber,
              subpartLetter: parsedHeader.subpartLetter,
              questionType: parsedHeader.questionType,
              defaultPoints: parsedHeader.pointsPerItem ?? 1.0,
              expectedItemCount: parsedHeader.expectedItemCount,
              hasExplicitHeading: true,
              hasExplicitPoints: parsedHeader.pointsPerItem != null,
              hasAmbiguousMetadata: parsedHeader.hasAmbiguousMetadata,
            );
            sectionBuilders.add(currentSection!);
          }
        }
        continue;
      }

      // Check Embedded Answer Line: e.g. "Answer: B", "Answer (T or F): ______",
      // "Answer (True / False): ____________"
      final ansMatch = answerLineRe.firstMatch(line);
      if (ansMatch != null) {
        final hasTfMarker = ansMatch.group(1) != null;
        final rawAns = (ansMatch.group(2) ?? '').trim();
        if (currentQuestion != null) {
          if (hasTfMarker) {
            currentQuestion!.hasTrueFalsePrompt = true;
          } else {
            currentQuestion!.hasIdentificationPrompt = true;
          }
          if (!RegExp(r'^[_\-\.\s]+$').hasMatch(rawAns)) {
            final cleanAns = rawAns.replaceAll(RegExp(r'^_+|_+$'), '').trim();
            if (cleanAns.isNotEmpty && !_isPlaceholderText(cleanAns)) {
              currentQuestion!.correctAnswer = cleanAns;
            }
          }
        }
        continue;
      }

      // Check Option Line: "A.  Application Layer" (only when inside a question)
      final choiceMatch = choiceStartRe.firstMatch(line);
      if (choiceMatch != null && currentQuestion != null) {
        final isStarred = choiceMatch.group(1) == '*';
        final letter = choiceMatch.group(2)!.toUpperCase();
        var choiceText = choiceMatch.group(3)!.trim();

        final inlineChoices = _splitInlineChoices('$letter. $choiceText');
        if (inlineChoices.length > 1) {
          for (final entry in inlineChoices.entries) {
            var val = entry.value;
            if (val.endsWith('*')) {
              val = val.substring(0, val.length - 1).trim();
              currentQuestion!.correctAnswer ??= entry.key;
            }
            currentQuestion!.choices[entry.key] = val;
            currentChoiceLetter = entry.key;
          }
        } else {
          if (choiceText.endsWith('*')) {
            choiceText = choiceText.substring(0, choiceText.length - 1).trim();
            currentQuestion!.correctAnswer ??= letter;
          }
          if (isStarred) {
            currentQuestion!.correctAnswer ??= letter;
          }
          currentQuestion!.choices[letter] = choiceText;
          currentChoiceLetter = letter;
        }
        continue;
      }

      // Check Question Start Line: "1.   It consists of..."
      final qMatch = questionStartRe.firstMatch(line);
      if (qMatch != null) {
        flushQuestion();
        inNotice = false;
        final qNum = int.tryParse(qMatch.group(1)!) ?? 1;
        var qStem = qMatch.group(2)!.trim();

        String? inlineAnswer;
        final bracketAnsMatch = RegExp(
          r'[\[\(]\s*(?:answer|ans|key)\s*:\s*([^\]\)]+)[\]\)]\s*$',
          caseSensitive: false,
        ).firstMatch(qStem);
        if (bracketAnsMatch != null) {
          final candidate = bracketAnsMatch.group(1)!.trim();
          if (!_isPlaceholderText(candidate)) {
            inlineAnswer = candidate;
          }
          qStem = qStem.substring(0, bracketAnsMatch.start).trim();
        }

        final sec = ensureSection();
        currentQuestion = _QuestionBuilder(
          number: qNum,
          stem: StringBuffer(qStem),
          inferredType: sec.questionType,
          points: sec.defaultPoints > 0 ? sec.defaultPoints : 1.0,
        )..correctAnswer = inlineAnswer;
        continue;
      }

      // Continuation of current choice or current question stem
      if (currentQuestion != null) {
        if (currentChoiceLetter != null) {
          final prev = currentQuestion!.choices[currentChoiceLetter!] ?? '';
          currentQuestion!.choices[currentChoiceLetter!] = prev.isEmpty
              ? line
              : '$prev $line';
        } else {
          if (currentQuestion!.stem.isNotEmpty) {
            currentQuestion!.stem.write(' ');
          }
          currentQuestion!.stem.write(line);
        }
      }
    }

    flushQuestion();

    final nonEmptySections = sectionBuilders
        .where((b) => b.questions.isNotEmpty)
        .map((b) => b.toSection())
        .toList();

    final instructionsText = noticeLines.isNotEmpty
        ? noticeLines.join('\n')
        : QuestionPaperPdfService.defaultInstructionsText;

    return finalizeImportedPaper(
      fileName: fileName,
      rawSections: nonEmptySections,
      detectedAssessmentType: detectedType,
      detectedSubjectName: detectedSubject,
      detectedQuizTitle: detectedQuizTitle,
      detectedExamDay: detectedDay,
      detectedExamDate: detectedDate,
      detectedStartTime: detectedStart,
      detectedEndTime: detectedEnd,
      detectedReferenceNo: detectedRef,
      detectedInstructions: instructionsText,
      unreadablePages: unreadablePages,
      expectedTemplate: expectedTemplate,
    );
  }

  /// Finalizes parsed or edited sections:
  /// 1. Assigns CheckMate Roman-numeral Part numbers (one Part per question type
  ///    in order of first appearance) and lettered subparts (`A`, `B`, ...) when
  ///    a question type repeats.
  /// 2. Numbers all questions continuously `1..N` in section order while keeping
  ///    each question's section-specific point value.
  /// 3. Computes all validation issues (unreadable pages, unresolved classifications,
  ///    duplicate/missing numbers, leftover placeholders, incomplete A–D choices,
  ///    mismatched counts, and template discrepancies).
  static ImportedQuestionPaper finalizeImportedPaper({
    required String fileName,
    required List<ImportedExamSection> rawSections,
    String? detectedAssessmentType,
    String? detectedSubjectName,
    String? detectedQuizTitle,
    String? detectedExamDay,
    String? detectedExamDate,
    String? detectedStartTime,
    String? detectedEndTime,
    String? detectedReferenceNo,
    String? detectedInstructions,
    List<int> unreadablePages = const <int>[],
    List<QuestionnaireTemplateSectionConfig>? expectedTemplate,
  }) {
    final issues = <QuestionPaperImportIssue>[];

    for (final pageNum in unreadablePages) {
      issues.add(
        QuestionPaperImportIssue(
          kind: 'unreadable_page',
          message:
              'Page $pageNum has no selectable text and could not be read.',
          isBlocking: rawSections.isEmpty,
        ),
      );
    }

    if (rawSections.isEmpty) {
      return ImportedQuestionPaper(
        fileName: fileName,
        sections: const <ImportedExamSection>[],
        detectedAssessmentType: detectedAssessmentType,
        detectedSubjectName: detectedSubjectName,
        detectedQuizTitle: detectedQuizTitle,
        detectedExamDay: detectedExamDay,
        detectedExamDate: detectedExamDate,
        detectedStartTime: detectedStartTime,
        detectedEndTime: detectedEndTime,
        detectedReferenceNo: detectedReferenceNo,
        detectedInstructions: detectedInstructions,
        unreadablePages: unreadablePages,
        issues: issues,
      );
    }

    // Compute Part numbers (1 per distinct question type in order of first appearance)
    // and subpart letters (A, B, ... when a question type repeats).
    final typeCounts = <String, int>{};
    final partByType = <String, int>{};
    for (final s in rawSections) {
      final t = normalizeQuestionType(s.questionType);
      typeCounts[t] = (typeCounts[t] ?? 0) + 1;
      if (!partByType.containsKey(t)) {
        partByType[t] = partByType.length + 1;
      }
    }

    final seenByType = <String, int>{};
    final finalizedSections = <ImportedExamSection>[];
    var globalCursor = 1;

    for (var sIdx = 0; sIdx < rawSections.length; sIdx++) {
      final sec = rawSections[sIdx];
      final qType = normalizeQuestionType(sec.questionType);
      final partNum = partByType[qType] ?? (sIdx + 1);
      final occIdx = seenByType[qType] ?? 0;
      seenByType[qType] = occIdx + 1;

      final isRepeated = (typeCounts[qType] ?? 1) > 1;
      final subpart = isRepeated
          ? (sec.subpartLetter?.trim().isNotEmpty == true
                ? sec.subpartLetter!.trim().toUpperCase()
                : subpartLetterFromIndex(occIdx))
          : null;

      final defaultPts = sec.defaultPoints > 0 ? sec.defaultPoints : 1.0;
      final canonicalName = formatPartHeading(
        partNumber: partNum,
        questionType: qType,
        subpartLetter: subpart,
        pointsPerItem: defaultPts,
      );

      if (sec.hasAmbiguousMetadata) {
        issues.add(
          QuestionPaperImportIssue(
            kind: 'ambiguous_section',
            sectionIndex: sIdx,
            message:
                '$canonicalName had ambiguous or incomplete section metadata. Verify its question type and points per item.',
            isBlocking: true,
          ),
        );
      }

      // Check source question numbering within this section for duplicates or gaps
      final sectionStartGlobal = globalCursor;
      final sourceNums = sec.questions
          .map((q) => q.sourceQuestionNumber ?? q.questionNumber)
          .toList();

      if (sourceNums.isNotEmpty) {
        final seenNums = <int>{};
        final duplicates = <int>{};
        for (final n in sourceNums) {
          if (!seenNums.add(n)) {
            duplicates.add(n);
          }
        }
        if (duplicates.isNotEmpty) {
          final dupList = duplicates.toList()..sort();
          issues.add(
            QuestionPaperImportIssue(
              kind: 'duplicate_number',
              sectionIndex: sIdx,
              message:
                  '$canonicalName has duplicate item number(s): ${dupList.join(", ")}.',
              isBlocking: true,
            ),
          );
        }

        // Check for missing numbers in sequence (either 1..K or sectionStartGlobal..sectionEndGlobal)
        final firstSource = sourceNums.first;
        final expectedBase =
            (firstSource == sectionStartGlobal || firstSource > 1)
            ? firstSource
            : 1;
        final expectedEnd = expectedBase + sourceNums.length - 1;
        final missingNums = <int>[];
        for (var expected = expectedBase; expected <= expectedEnd; expected++) {
          if (!seenNums.contains(expected)) {
            missingNums.add(expected);
          }
        }
        if (missingNums.isNotEmpty) {
          issues.add(
            QuestionPaperImportIssue(
              kind: 'missing_number',
              sectionIndex: sIdx,
              message:
                  '$canonicalName is missing item number(s) in sequence: ${missingNums.join(", ")}.',
              isBlocking: true,
            ),
          );
        }
      }

      if (sec.expectedItemCount != null &&
          sec.expectedItemCount! > 0 &&
          sec.expectedItemCount != sec.questions.length) {
        issues.add(
          QuestionPaperImportIssue(
            kind: 'mismatched_count',
            sectionIndex: sIdx,
            message:
                '$canonicalName header states ${sec.expectedItemCount} items, but ${sec.questions.length} ${sec.questions.length == 1 ? "item was" : "items were"} found.',
            isBlocking: true,
          ),
        );
      }

      final updatedQuestions = <ImportedExamQuestion>[];
      for (var qIdx = 0; qIdx < sec.questions.length; qIdx++) {
        final rawQ = sec.questions[qIdx];
        final continuousNum = globalCursor++;
        final itemPts = rawQ.points > 0 ? rawQ.points : defaultPts;

        final validatedQ = _buildValidatedQuestion(
          questionNumber: continuousNum,
          sourceQuestionNumber:
              rawQ.sourceQuestionNumber ?? rawQ.questionNumber,
          questionText: rawQ.questionText,
          questionType: qType,
          points: itemPts,
          choices: qType == 'multiple_choice'
              ? rawQ.choices
              : const <String>[],
          correctAnswer: rawQ.correctAnswer,
          classificationAmbiguous: rawQ.classificationAmbiguous,
        );

        if (validatedQ.classificationAmbiguous) {
          issues.add(
            QuestionPaperImportIssue(
              kind: 'unresolved_classification',
              sectionIndex: sIdx,
              questionNumber: continuousNum,
              message:
                  'Item $continuousNum in $canonicalName has an unresolved question type classification.',
              isBlocking: true,
            ),
          );
        }
        if (validatedQ.hasLeftoverPlaceholder) {
          issues.add(
            QuestionPaperImportIssue(
              kind: 'leftover_placeholder',
              sectionIndex: sIdx,
              questionNumber: continuousNum,
              message:
                  'Item $continuousNum in $canonicalName still contains template placeholder text or blank prompt.',
              isBlocking: true,
            ),
          );
        }
        if (validatedQ.missingChoiceLetters.isNotEmpty) {
          issues.add(
            QuestionPaperImportIssue(
              kind: 'incomplete_choices',
              sectionIndex: sIdx,
              questionNumber: continuousNum,
              message:
                  'Item $continuousNum in $canonicalName is missing choice(s): ${validatedQ.missingChoiceLetters.join(", ")}.',
              isBlocking: true,
            ),
          );
        }

        updatedQuestions.add(validatedQ);
      }

      finalizedSections.add(
        ImportedExamSection(
          name: canonicalName,
          questionType: qType,
          defaultPoints: defaultPts,
          questions: updatedQuestions,
          partNumber: partNum,
          subpartLetter: subpart,
          expectedItemCount: sec.expectedItemCount,
          hasAmbiguousMetadata: sec.hasAmbiguousMetadata,
        ),
      );
    }

    // Compare against expected template if one was selected in the current session
    if (expectedTemplate != null && expectedTemplate.isNotEmpty) {
      final resolvedExpected = resolveTemplateSections(expectedTemplate);
      if (resolvedExpected.length != finalizedSections.length) {
        issues.add(
          QuestionPaperImportIssue(
            kind: 'template_mismatch',
            message:
                'Selected template has ${resolvedExpected.length} ${resolvedExpected.length == 1 ? "section" : "sections"}, '
                'but the uploaded file has ${finalizedSections.length} ${finalizedSections.length == 1 ? "section" : "sections"}.',
            isBlocking: false,
          ),
        );
      }
      final compareCount = math.min(
        resolvedExpected.length,
        finalizedSections.length,
      );
      for (var i = 0; i < compareCount; i++) {
        final exp = resolvedExpected[i];
        final det = finalizedSections[i];
        if (exp.questionType != det.questionType) {
          issues.add(
            QuestionPaperImportIssue(
              kind: 'template_mismatch',
              sectionIndex: i,
              message:
                  'Section ${i + 1}: template expected ${labelForType(exp.questionType)} (${exp.heading}), '
                  'but detected ${labelForType(det.questionType)} (${det.name}).',
              isBlocking: false,
            ),
          );
        }
        if (exp.itemCount != det.questions.length) {
          issues.add(
            QuestionPaperImportIssue(
              kind: 'template_mismatch',
              sectionIndex: i,
              message:
                  '${det.name}: template expected ${exp.itemCount} items, '
                  'but uploaded file has ${det.questions.length} items.',
              isBlocking: false,
            ),
          );
        }
        if ((exp.pointsPerItem - det.defaultPoints).abs() > 0.0001) {
          issues.add(
            QuestionPaperImportIssue(
              kind: 'template_mismatch',
              sectionIndex: i,
              message:
                  '${det.name}: template expected ${formatPoints(exp.pointsPerItem)} pts/item, '
                  'but uploaded file has ${formatPoints(det.defaultPoints)} pts/item.',
              isBlocking: false,
            ),
          );
        }
      }
    }

    return ImportedQuestionPaper(
      fileName: fileName,
      sections: finalizedSections,
      detectedAssessmentType: detectedAssessmentType,
      detectedSubjectName: detectedSubjectName,
      detectedQuizTitle: detectedQuizTitle,
      detectedExamDay: detectedExamDay,
      detectedExamDate: detectedExamDate,
      detectedStartTime: detectedStartTime,
      detectedEndTime: detectedEndTime,
      detectedReferenceNo: detectedReferenceNo,
      detectedInstructions: detectedInstructions,
      unreadablePages: unreadablePages,
      issues: issues,
    );
  }

  static ImportedExamQuestion _buildValidatedQuestion({
    required int questionNumber,
    required int? sourceQuestionNumber,
    required String questionText,
    required String questionType,
    required double points,
    required List<String> choices,
    required String? correctAnswer,
    required bool classificationAmbiguous,
  }) {
    final cleanStem = questionText.trim();
    var hasPlaceholder = cleanStem.isEmpty || _isPlaceholderText(cleanStem);
    final missingLetters = <String>[];
    final normalizedChoices = <String>[];

    if (questionType == 'multiple_choice') {
      for (var i = 0; i < 4; i++) {
        final letter = String.fromCharCode(65 + i);
        final rawChoice = i < choices.length ? choices[i].trim() : '';
        normalizedChoices.add(rawChoice);
        if (rawChoice.isEmpty) {
          missingLetters.add(letter);
        } else if (_isPlaceholderText(rawChoice)) {
          hasPlaceholder = true;
          missingLetters.add(letter);
        }
      }
    }

    return ImportedExamQuestion(
      questionNumber: questionNumber,
      sourceQuestionNumber: sourceQuestionNumber,
      questionText: cleanStem,
      questionType: questionType,
      points: points > 0 ? points : 1.0,
      choices: normalizedChoices,
      correctAnswer: correctAnswer,
      hasLeftoverPlaceholder: hasPlaceholder,
      missingChoiceLetters: missingLetters,
      classificationAmbiguous: classificationAmbiguous,
    );
  }

  static bool _isPlaceholderText(String raw) {
    final clean = raw.trim();
    if (clean.isEmpty) return true;
    final lower = clean.toLowerCase();
    if (RegExp(
      r'\[\s*(?:write|enter|type)\s+(?:your\s+)?(?:question|statement|choice|option|prompt|answer).*\]',
      caseSensitive: false,
    ).hasMatch(clean)) {
      return true;
    }
    if (lower == '[write question here]' ||
        lower == '[write statement here]' ||
        lower == '[write choice here]' ||
        lower == '[write choice a here]' ||
        lower == '[write choice b here]' ||
        lower == '[write choice c here]' ||
        lower == '[write choice d here]') {
      return true;
    }
    if (RegExp(r'^[_\-\.\s\?]+$').hasMatch(clean)) {
      return true;
    }
    return false;
  }

  static String? _detectExplicitAssessmentTypeFromHeader(String line) {
    final clean = line.trim();
    final lower = clean.toLowerCase();
    if (lower.contains('preliminary examination') ||
        RegExp(r'\bprelim(?:s|inary)?\s+exam(?:ination)?\b').hasMatch(lower) ||
        lower == 'prelim' ||
        lower == 'prelims') {
      return 'prelim';
    }
    if (lower.contains('midterm examination') ||
        RegExp(r'\bmidterm\s+exam(?:ination)?\b').hasMatch(lower) ||
        lower == 'midterm' ||
        lower == 'midterms') {
      return 'midterm';
    }
    if (lower.contains('pre-final examination') ||
        lower.contains('prefinal examination') ||
        RegExp(r'\bpre[\-\s]?finals?\s+exam(?:ination)?\b').hasMatch(lower) ||
        lower == 'prefinals' ||
        lower == 'pre-finals' ||
        lower == 'prefinal') {
      return 'prefinal';
    }
    if (lower.contains('final examination') ||
        RegExp(r'\bfinals?\s+exam(?:ination)?\b').hasMatch(lower) ||
        lower == 'finals' ||
        lower == 'final') {
      return 'final';
    }
    if (lower.contains('long quiz')) {
      return 'long_quiz';
    }
    if (lower.contains('short quiz')) {
      return 'short_quiz';
    }
    if (lower.contains('quiz')) {
      return 'quiz';
    }
    if (lower.contains('performance task')) {
      return 'performance_task';
    }
    if (lower.contains('laboratory')) {
      return 'laboratory';
    }
    return null;
  }

  /// Parses visible Part headings, lettered subparts, STI section headers,
  /// and standalone point/instruction lines while distinguishing section
  /// headings starting with `A.` or `B.` from multiple-choice options.
  static _ParsedSectionHeader? _tryParseSectionHeaderOrPointsLine(
    String line, {
    required bool hasActiveQuestion,
    required bool activeQuestionHasFourChoices,
  }) {
    final clean = line.trim();
    final lower = clean.toLowerCase();

    // 1. Direction / Instruction line (e.g. "Read and analyze each item...")
    if (lower.startsWith('read and analyze') ||
        lower.startsWith('direction:') ||
        lower.startsWith('directions:') ||
        lower.startsWith('instruction:') ||
        lower.startsWith('instructions:')) {
      final detectedType = _detectTypeFromLine(lower);
      final pts = _extractPointsPerItem(clean);
      final count = _extractItemCount(clean);
      return _ParsedSectionHeader(
        rawHeading: clean,
        questionType: detectedType,
        pointsPerItem: pts,
        expectedItemCount: count,
        isInstructionOrPointsLineOnly: true,
      );
    }

    // 2. CheckMate Part Heading (with or without lettered subpart):
    //    e.g. "Part I. Multiple Choice - A. 2 pts each"
    //         "Part I. Multiple Choice - B. 3 pts each"
    //         "Part II. Identification"
    //         "Part III. True or False"
    final partRe = RegExp(
      r'^(?:Part|Section|Test)\s+([IVX\d]+)[\.\:\-\u00B7\s]+(.+)$',
      caseSensitive: false,
    );
    final partMatch = partRe.firstMatch(clean);
    if (partMatch != null) {
      final rawRoman = partMatch.group(1)!.trim();
      final partNum = parseRomanNumeral(rawRoman);
      final remainder = partMatch.group(2)!.trim();
      final detectedType = _detectTypeFromLine(remainder.toLowerCase());
      final pts = _extractPointsPerItem(remainder);
      final count = _extractItemCount(remainder);

      // Extract optional subpart letter after dash, e.g. "- A. 2 pts each" or "- B (3 pts)"
      String? subpart;
      final subpartMatch = RegExp(
        r'[\-\u2013\u2014\:]\s*([A-Z])(?:\b|[\.\)\:\s])',
      ).firstMatch(remainder);
      if (subpartMatch != null) {
        subpart = subpartMatch.group(1)!.toUpperCase();
      }

      final hasInvalidPointsSyntax =
          RegExp(r'\b(?:pts?|points?)\b', caseSensitive: false).hasMatch(
            remainder,
          ) &&
          pts == null;

      return _ParsedSectionHeader(
        rawHeading: clean,
        partNumber: partNum,
        subpartLetter: subpart,
        questionType: detectedType,
        pointsPerItem: pts,
        expectedItemCount: count,
        isInstructionOrPointsLineOnly: false,
        hasAmbiguousMetadata: detectedType == null || hasInvalidPointsSyntax,
      );
    }

    // 3. STI / Template Points & Item Count Header:
    //    e.g. "A.  (35 items x 2 points)"
    //         "B.  (20 items x 3 points - 3 pts each)"
    //         "Items 1-15 (15 items x 2 points - 2 pts each)"
    final stiPointsLineRe = RegExp(
      r'^(?:([A-Z])[\.\)]\s*)?\(?\s*(?:items?\s+\d+[\-\u2013\u2014]\d+\s*\(?|)(\d+)\s*items?\b(.*)$',
      caseSensitive: false,
    );
    final stiMatch = stiPointsLineRe.firstMatch(clean);
    if (stiMatch != null) {
      final letter = stiMatch.group(1)?.toUpperCase();
      final itemCount = int.tryParse(stiMatch.group(2) ?? '');
      final tail = stiMatch.group(3) ?? '';
      final pts = _extractPointsPerItem(tail) ?? _extractPointsPerItem(clean);
      final detectedType = _detectTypeFromLine(lower);

      return _ParsedSectionHeader(
        rawHeading: clean,
        subpartLetter: letter,
        questionType: detectedType,
        pointsPerItem: pts,
        expectedItemCount: itemCount,
        isInstructionOrPointsLineOnly: true,
      );
    }

    // 4. Standalone Points Instruction Line:
    //    e.g. "Points: 2 pts each", "2 points per item", "2 pts each"
    if (RegExp(
      r'^(?:points?(?:\s+per\s+item)?\s*[:\-]?\s*)?\d+(?:\.\d+)?\s*(?:pts?|points?)\s*(?:each|per\s+item)$',
      caseSensitive: false,
    ).hasMatch(clean)) {
      final pts = _extractPointsPerItem(clean);
      return _ParsedSectionHeader(
        rawHeading: clean,
        pointsPerItem: pts,
        isInstructionOrPointsLineOnly: true,
      );
    }

    // 5. Lettered Section Heading with Question Type:
    //    e.g. "A. Multiple Choice (2 pts each)"
    //         "B. Multiple Choice - 3 pts each"
    //         "C. Identification"
    //    Distinguished from an A-D choice option because:
    //    - Either no question is currently active, OR
    //    - The active question already has all four choices A-D, OR
    //    - The line explicitly names a question type AND includes points/items metadata.
    final letteredTypeHeaderRe = RegExp(
      r'^([A-Z])[\.\)]\s*(Multiple\s+Choice|True\s+or\s+False|Modified\s+True\s+or\s+False|Identification|Fill\s+in\s+the\s+Blanks?)(?:\s*[\-\u2013\u2014\(\:]\s*(.+))?$',
      caseSensitive: false,
    );
    final letteredMatch = letteredTypeHeaderRe.firstMatch(clean);
    if (letteredMatch != null) {
      final letter = letteredMatch.group(1)!.toUpperCase();
      final typePart = letteredMatch.group(2)!;
      final rest = letteredMatch.group(3) ?? '';
      final pts = _extractPointsPerItem(rest);
      final count = _extractItemCount(rest);
      final hasMeta = pts != null || count != null;

      if (!hasActiveQuestion ||
          activeQuestionHasFourChoices ||
          hasMeta ||
          !const ['A', 'B', 'C', 'D'].contains(letter)) {
        return _ParsedSectionHeader(
          rawHeading: clean,
          subpartLetter: letter,
          questionType: _detectTypeFromLine(typePart.toLowerCase()),
          pointsPerItem: pts,
          expectedItemCount: count,
          isInstructionOrPointsLineOnly: false,
        );
      }
    }

    // 6. Standalone Type Heading: e.g. "Multiple Choice (2 pts each)" or "Identification:"
    final standaloneTypeHeaderRe = RegExp(
      r'^(Multiple\s+Choice|True\s+or\s+False|Modified\s+True\s+or\s+False|Identification|Fill\s+in\s+the\s+Blanks?)(?:\s*[\-\u2013\u2014\(\:]\s*(.*))?$',
      caseSensitive: false,
    );
    final standaloneMatch = standaloneTypeHeaderRe.firstMatch(clean);
    if (standaloneMatch != null) {
      final typePart = standaloneMatch.group(1)!;
      final rest = standaloneMatch.group(2) ?? '';
      final pts = _extractPointsPerItem(rest);
      final count = _extractItemCount(rest);
      return _ParsedSectionHeader(
        rawHeading: clean,
        questionType: _detectTypeFromLine(typePart.toLowerCase()),
        pointsPerItem: pts,
        expectedItemCount: count,
        isInstructionOrPointsLineOnly: false,
      );
    }

    return null;
  }

  static double? _extractPointsPerItem(String text) {
    if (text.isEmpty) return null;
    // Match "x 2 points" / "× 2 pts"
    final multMatch = RegExp(
      r'[x\u00D7\*]\s*(\d+(?:\.\d+)?)\s*(?:pts?|points?)\b',
      caseSensitive: false,
    ).firstMatch(text);
    if (multMatch != null) {
      final v = double.tryParse(multMatch.group(1)!);
      if (v != null && v > 0) return v;
    }

    // Match "2 pts each" / "2 points per item" / "2 pt/item"
    final eachMatch = RegExp(
      r'(\d+(?:\.\d+)?)\s*(?:pts?|points?)\s*(?:each|/\s*item|per\s+item)?\b',
      caseSensitive: false,
    ).firstMatch(text);
    if (eachMatch != null) {
      final v = double.tryParse(eachMatch.group(1)!);
      if (v != null && v > 0) return v;
    }
    return null;
  }

  static int? _extractItemCount(String text) {
    if (text.isEmpty) return null;
    final m = RegExp(
      r'(\d+)\s*items?\b',
      caseSensitive: false,
    ).firstMatch(text);
    if (m != null) {
      final v = int.tryParse(m.group(1)!);
      if (v != null && v > 0) return v;
    }
    return null;
  }

  static String? _detectTypeFromLine(String lower) {
    if (lower.contains('choose the letter of the correct answer') ||
        lower.contains('choose the best answer') ||
        lower.contains('multiple choice') ||
        lower.contains('multiple-choice')) {
      return 'multiple_choice';
    }
    if (lower.contains('write true if') ||
        lower.contains('mark t for true') ||
        lower.contains('true or false') ||
        lower.contains('true / false') ||
        lower.contains('true/false') ||
        lower.contains('modified true or false')) {
      return 'true_false';
    }
    if (lower.contains('write the correct answer on the space') ||
        lower.contains('write your answer on the line') ||
        lower.contains('identification') ||
        lower.contains('fill in the blank')) {
      return 'identification';
    }
    return null;
  }

  static _ResolvedQuestionType _resolveQuestionTypeWithDiagnostics(
    _QuestionBuilder q,
  ) {
    final nonEmptyChoices = q.choices.values
        .map((v) => v.trim())
        .where((v) => v.isNotEmpty)
        .toList();

    // Check if choices are just A. True / B. False
    if (nonEmptyChoices.length == 2 && q.inferredType != 'multiple_choice') {
      final lowerSet = nonEmptyChoices.map((c) => c.toLowerCase()).toSet();
      if (lowerSet.contains('true') && lowerSet.contains('false')) {
        return const _ResolvedQuestionType('true_false', isAmbiguous: false);
      }
    }

    if (q.inferredType == 'multiple_choice' || q.choices.isNotEmpty) {
      return const _ResolvedQuestionType('multiple_choice', isAmbiguous: false);
    }

    if (q.hasTrueFalsePrompt || _isTrueOrFalseAnswer(q.correctAnswer)) {
      return const _ResolvedQuestionType('true_false', isAmbiguous: false);
    }

    final stemLower = q.stem.toString().trim().toLowerCase();
    if (stemLower.startsWith('(true or false)') ||
        stemLower.startsWith('[true or false]') ||
        stemLower.startsWith('(true/false)') ||
        stemLower.startsWith('[true/false]') ||
        stemLower.endsWith('(true or false)') ||
        stemLower.endsWith('(true/false)')) {
      return const _ResolvedQuestionType('true_false', isAmbiguous: false);
    }

    if (q.inferredType == 'true_false') {
      return const _ResolvedQuestionType('true_false', isAmbiguous: false);
    }

    if (q.inferredType == 'identification' || q.hasIdentificationPrompt) {
      return const _ResolvedQuestionType('identification', isAmbiguous: false);
    }

    // No explicit section type, no choices, and no T/F or ID answer prompt
    return const _ResolvedQuestionType('identification', isAmbiguous: true);
  }

  static bool _isTrueOrFalseAnswer(String? raw) {
    if (raw == null) return false;
    final clean = raw.trim().toLowerCase();
    return clean == 'true' || clean == 'false';
  }

  static String? _normalizeAnswerForType(
    String? rawAnswer,
    String qType, {
    List<String> choices = const <String>[],
  }) {
    if (rawAnswer == null) return null;
    final clean = rawAnswer.trim();
    if (clean.isEmpty ||
        RegExp(r'^_+$').hasMatch(clean) ||
        _isPlaceholderText(clean)) {
      return null;
    }

    if (qType == 'multiple_choice') {
      final upper = clean.toUpperCase();
      if (const ['A', 'B', 'C', 'D'].contains(upper)) {
        return upper;
      }
      final letterMatch = RegExp(r'^([A-Da-d])[\.\)]?$').firstMatch(clean);
      if (letterMatch != null) {
        return letterMatch.group(1)!.toUpperCase();
      }
      for (var i = 0; i < choices.length && i < 4; i++) {
        if (choices[i].trim().toLowerCase() == clean.toLowerCase()) {
          return String.fromCharCode(65 + i);
        }
      }
      return upper;
    }

    if (qType == 'true_false') {
      final lower = clean.toLowerCase();
      if (lower == 'true' || lower == 't') return 'True';
      if (lower == 'false' || lower == 'f') return 'False';
      return clean;
    }

    if (qType == 'identification') {
      return clean.toUpperCase();
    }

    return clean;
  }

  static String _stripLeadingQuestionNumber(String text) {
    var clean = text.trim();
    while (RegExp(r'^\d{1,3}[\.\)]\s+').hasMatch(clean)) {
      clean = clean.replaceFirst(RegExp(r'^\d{1,3}[\.\)]\s+'), '').trim();
    }
    return clean;
  }

  static Map<String, String> _splitInlineChoices(String line) {
    final matches = RegExp(
      r'(?:^|\s{2,})([A-Da-d])[\.\)]\s+',
    ).allMatches(line).toList();
    if (matches.length <= 1) return const <String, String>{};

    final result = <String, String>{};
    for (var i = 0; i < matches.length; i++) {
      final m = matches[i];
      final letter = m.group(1)!.toUpperCase();
      final start = m.end;
      final end = (i + 1 < matches.length) ? matches[i + 1].start : line.length;
      result[letter] = line.substring(start, end).trim();
    }
    return result;
  }
}

class _PdfExtractionResult {
  const _PdfExtractionResult({
    required this.lines,
    required this.unreadablePages,
  });

  final List<String> lines;
  final List<int> unreadablePages;
}

class _PositionedTextSegment {
  const _PositionedTextSegment({required this.text, required this.bounds});

  final String text;
  final Rect bounds;
}

class _ResolvedQuestionType {
  const _ResolvedQuestionType(this.questionType, {required this.isAmbiguous});

  final String questionType;
  final bool isAmbiguous;
}

class _ParsedSectionHeader {
  const _ParsedSectionHeader({
    required this.rawHeading,
    this.partNumber,
    this.subpartLetter,
    this.questionType,
    this.pointsPerItem,
    this.expectedItemCount,
    this.isInstructionOrPointsLineOnly = false,
    this.hasAmbiguousMetadata = false,
  });

  final String rawHeading;
  final int? partNumber;
  final String? subpartLetter;
  final String? questionType;
  final double? pointsPerItem;
  final int? expectedItemCount;
  final bool isInstructionOrPointsLineOnly;
  final bool hasAmbiguousMetadata;
}

class _SectionBuilder {
  _SectionBuilder({
    this.rawHeading,
    this.partNumber,
    this.subpartLetter,
    this.questionType,
    this.defaultPoints = 1.0,
    this.expectedItemCount,
    this.hasExplicitHeading = false,
    this.hasExplicitPoints = false,
    this.hasAmbiguousMetadata = false,
  });

  String? rawHeading;
  int? partNumber;
  String? subpartLetter;
  String? questionType;
  double defaultPoints;
  int? expectedItemCount;
  bool hasExplicitHeading;
  bool hasExplicitPoints;
  bool hasAmbiguousMetadata;
  final List<ImportedExamQuestion> questions = <ImportedExamQuestion>[];

  ImportedExamSection toSection() {
    final resolvedType =
        questionType ??
        (questions.isNotEmpty
            ? questions.first.questionType
            : 'multiple_choice');
    final pts = defaultPoints > 0 ? defaultPoints : 1.0;
    return ImportedExamSection(
      name: rawHeading ?? '',
      questionType: resolvedType,
      defaultPoints: pts,
      questions: List<ImportedExamQuestion>.from(questions),
      partNumber: partNumber,
      subpartLetter: subpartLetter,
      expectedItemCount: expectedItemCount,
      hasAmbiguousMetadata: hasAmbiguousMetadata,
    );
  }
}

class _QuestionBuilder {
  _QuestionBuilder({
    required this.number,
    required this.stem,
    required this.inferredType,
    required this.points,
  });

  final int number;
  final StringBuffer stem;
  final String? inferredType;
  final double points;
  final Map<String, String> choices = <String, String>{};
  String? correctAnswer;
  bool hasTrueFalsePrompt = false;
  bool hasIdentificationPrompt = false;
}
