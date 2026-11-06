import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:archive/archive.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:xml/xml.dart';

import 'question_paper_pdf_service.dart';

class ImportedExamQuestion {
  const ImportedExamQuestion({
    required this.questionNumber,
    required this.questionText,
    required this.questionType,
    required this.points,
    this.choices = const <String>[],
    this.correctAnswer,
  });

  final int questionNumber;
  final String questionText;
  final String questionType;
  final double points;
  final List<String> choices;
  final String? correctAnswer;
}

class ImportedExamSection {
  const ImportedExamSection({
    required this.name,
    required this.questionType,
    required this.defaultPoints,
    required this.questions,
  });

  final String name;
  final String questionType;
  final double defaultPoints;
  final List<ImportedExamQuestion> questions;
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

  int get totalQuestions =>
      sections.fold<int>(0, (sum, s) => sum + s.questions.length);
}

/// Parses an uploaded Question Paper (`.pdf` or `.docx`) into structured
/// sections, questions, choices, and header metadata for the Exam Builder.
class QuestionPaperImportService {
  QuestionPaperImportService._();

  static ImportedQuestionPaper parseBytes({
    required Uint8List bytes,
    required String fileName,
  }) {
    final lowerName = fileName.trim().toLowerCase();
    final isZipHeader =
        bytes.length >= 4 && bytes[0] == 0x50 && bytes[1] == 0x4B;

    List<String> lines;
    if (lowerName.endsWith('.docx') || isZipHeader) {
      lines = _extractLinesFromDocx(bytes);
    } else {
      lines = _extractLinesFromPdf(bytes);
    }

    return _parseExtractedLines(lines: lines, fileName: fileName);
  }

  // ===========================================================================
  // PDF TEXT EXTRACTION (TWO-COLUMN & SINGLE-COLUMN AWARE)
  // ===========================================================================

  static List<String> _extractLinesFromPdf(Uint8List bytes) {
    final document = PdfDocument(inputBytes: bytes);
    try {
      final extractor = PdfTextExtractor(document);
      final allLines = <String>[];

      for (var pageIdx = 0; pageIdx < document.pages.count; pageIdx++) {
        final page = document.pages[pageIdx];
        final pageWidth = page.size.width;
        final textLines = extractor.extractTextLines(
          startPageIndex: pageIdx,
          endPageIndex: pageIdx,
        );

        if (textLines.isEmpty) {
          final fallback = extractor.extractText(
            startPageIndex: pageIdx,
            endPageIndex: pageIdx,
          );
          for (final raw in fallback.split(RegExp(r'\r?\n'))) {
            final clean = raw.trim();
            if (clean.isNotEmpty) allLines.add(clean);
          }
          continue;
        }

        // Determine where the Student Info row ("Name:___ Section:___ Date:___")
        // or horizontal divider sits on the page. Everything above it is header;
        // everything below it may be arranged in two columns.
        double bodyStartY = 0;
        for (final tl in textLines) {
          final t = tl.text.trim();
          if (t.contains('Name:') ||
              t.contains('Section:') ||
              RegExp(r'^_{10,}$').hasMatch(t)) {
            if (tl.bounds.bottom > bodyStartY) {
              bodyStartY = tl.bounds.bottom;
            }
          }
        }
        if (bodyStartY == 0) {
          // Fallback: top 12% of page is header area if no Name:/Section: line.
          bodyStartY = page.size.height * 0.11;
        }

        final headerItems = <TextLine>[];
        final bodyItems = <TextLine>[];
        for (final tl in textLines) {
          if (tl.text.trim().isEmpty) continue;
          if (tl.bounds.top <= bodyStartY + 2) {
            headerItems.add(tl);
          } else {
            bodyItems.add(tl);
          }
        }

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

        // Check if body items use a two-column layout (STI Question Paper).
        final colSplitX = pageWidth * 0.48;
        final leftCol = <TextLine>[];
        final rightCol = <TextLine>[];
        var wideBodyLines = 0;

        for (final b in bodyItems) {
          if (b.bounds.left < colSplitX &&
              b.bounds.right > pageWidth * 0.62 &&
              b.bounds.width > pageWidth * 0.52) {
            wideBodyLines++;
          }
          if (b.bounds.left < colSplitX) {
            leftCol.add(b);
          } else {
            rightCol.add(b);
          }
        }

        if (rightCol.length >= 2 && wideBodyLines <= bodyItems.length ~/ 3) {
          allLines.addAll(_mergeAndSortColumnLines(leftCol));
          allLines.addAll(_mergeAndSortColumnLines(rightCol));
        } else {
          allLines.addAll(_mergeAndSortColumnLines(bodyItems));
        }
      }

      return allLines;
    } finally {
      document.dispose();
    }
  }

  static List<String> _mergeAndSortColumnLines(List<TextLine> items) {
    if (items.isEmpty) return const <String>[];
    final sorted = List<TextLine>.from(items)
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
      if (prevBounds != null && (item.bounds.top - prevBounds.top).abs() <= 3.5) {
        currentLineBuffer.write(' $t');
        prevBounds = Rect.fromLTRB(
          prevBounds.left,
          prevBounds.top,
          item.bounds.right,
          item.bounds.bottom,
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
  // WORD (.DOCX) TEXT EXTRACTION
  // ===========================================================================

  static List<String> _extractLinesFromDocx(Uint8List bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final docFile = archive.findFile('word/document.xml');
    if (docFile == null) {
      throw Exception('Invalid Word document (.docx): word/document.xml missing.');
    }

    final xmlContent = utf8.decode(docFile.content as List<int>, allowMalformed: true);
    final doc = XmlDocument.parse(xmlContent);
    final lines = <String>[];

    for (final p in doc.findAllElements('w:p')) {
      final sb = StringBuffer();
      for (final node in p.descendants.whereType<XmlElement>()) {
        if (node.name.qualified == 'w:t') {
          sb.write(node.innerText);
        } else if (node.name.qualified == 'w:br') {
          sb.write('\n');
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

  // ===========================================================================
  // STRUCTURED QUESTION, CHOICE & METADATA PARSER
  // ===========================================================================

  static ImportedQuestionPaper _parseExtractedLines({
    required List<String> lines,
    required String fileName,
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
    final headerScanLimit = lines.length < 25 ? lines.length : 25;
    for (var i = 0; i < headerScanLimit; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;
      final lower = line.toLowerCase();

      if (RegExp(r'^_{5,}$').hasMatch(line) ||
          lower.startsWith('name:') ||
          lower.startsWith('section:') ||
          lower.startsWith('date:') ||
          lower.startsWith('notice:')) {
        break;
      }

      // Page number / Reference number line (e.g. "1000014607 — IT2511", "Page 1")
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

      // Day & Date line (e.g. "Day 1: October 6, 2026" or "Day 1 – April 4, 2026")
      final dayMatch = RegExp(
        r'^day\s*(\d+)\s*[:\u2013\u2014\-]\s*(.+)$',
        caseSensitive: false,
      ).firstMatch(line);
      if (dayMatch != null) {
        detectedDay ??= dayMatch.group(1)!.trim();
        detectedDate ??= dayMatch.group(2)!.trim();
        continue;
      }

      // Time range line (e.g. "8:00 am – 9:15 am")
      if (RegExp(r'\b\d{1,2}:\d{2}\b').hasMatch(line) &&
          RegExp(r'\b(am|pm)\b', caseSensitive: false).hasMatch(line)) {
        final tParts = line.split(RegExp(r'\s*[\u2013\u2014\-]\s*'));
        if (tParts.length >= 2) {
          detectedStart ??= tParts.first.trim().toUpperCase();
          detectedEnd ??= tParts.sublist(1).join(' - ').trim().toUpperCase();
        }
        continue;
      }

      // Term / SY / Examination title
      if (lower.contains('preliminary examination') || lower == 'prelim') {
        detectedType ??= 'prelim';
        continue;
      }
      if (lower.contains('midterm examination') || lower == 'midterm') {
        detectedType ??= 'midterm';
        continue;
      }
      if (lower.contains('pre-final examination') ||
          lower.contains('prefinal examination') ||
          lower == 'prefinals' ||
          lower == 'pre-finals') {
        detectedType ??= 'prefinal';
        continue;
      }
      if (lower.contains('final examination') || lower == 'finals') {
        detectedType ??= 'final';
        continue;
      }
      if (lower.contains('long quiz')) {
        detectedType ??= 'long_quiz';
        detectedQuizTitle ??= line;
        continue;
      }
      if (lower.contains('short quiz')) {
        detectedType ??= 'short_quiz';
        detectedQuizTitle ??= line;
        continue;
      }
      if (lower.contains('quiz')) {
        detectedType ??= 'quiz';
        detectedQuizTitle ??= line;
        continue;
      }
      if (RegExp(r'\b(1st|2nd|3rd)\s+term\b', caseSensitive: false)
              .hasMatch(line) ||
          RegExp(r'\bSY\s*\d{4}', caseSensitive: false).hasMatch(line)) {
        continue;
      }

      // First non-pattern line in header is the Subject Name
      detectedSubject ??= line;
    }

    // 2. Helper to identify repeating page header / boilerplate lines so Page 2+
    // headers never pollute option D of the last question on Page 1.
    bool isRepeatingHeaderOrBoilerplate(String line) {
      final clean = line.trim();
      if (clean.isEmpty) return true;
      final lower = clean.toLowerCase();

      if (RegExp(r'^_{5,}$').hasMatch(clean)) return true;
      if (RegExp(
        r'^(name|section|date)\s*:\s*_*',
        caseSensitive: false,
      ).hasMatch(clean)) {
        return true;
      }
      if (clean.contains('Name:___') ||
          clean.contains('Section:___') ||
          clean.contains('Date:___')) {
        return true;
      }
      if (RegExp(r'^page\s+\d+$', caseSensitive: false).hasMatch(clean)) {
        return true;
      }
      if (RegExp(r'^.+\s+page\s+\d+$', caseSensitive: false).hasMatch(clean) &&
          RegExp(r'\d{5,}').hasMatch(clean)) {
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
      if (RegExp(r'^\d{1,2}:\d{2}\s*(am|pm)\s*[\u2013\u2014\-]',
              caseSensitive: false)
          .hasMatch(clean)) {
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
        'final examination',
      }.contains(lower)) {
        return true;
      }
      if (RegExp(r'^\d{5,}\s*[\u2013\u2014\-]\s*[A-Za-z0-9]+$').hasMatch(clean)) {
        return true;
      }
      return false;
    }

    // 3. Parse Notice, Sections, Questions, and Choices
    final sectionBuilders = <_SectionBuilder>[];
    _SectionBuilder? currentSection;
    _QuestionBuilder? currentQuestion;
    String? currentChoiceLetter;
    String pendingQuestionType = 'multiple_choice';
    bool inNotice = false;

    void flushQuestion() {
      final q = currentQuestion;
      if (q == null) return;
      currentQuestion = null;
      currentChoiceLetter = null;

      final qType = q.choices.length >= 2
          ? 'multiple_choice'
          : q.inferredType;

      currentSection ??= _SectionBuilder(
        name: 'Part I · ${_labelForType(qType)}',
        questionType: qType,
        defaultPoints: q.points,
      );
      if (currentSection!.questions.isEmpty) {
        currentSection!.questionType = qType;
      } else if (currentSection!.questionType != qType) {
        // Start a new section if question type changed mid-paper without an explicit header
        sectionBuilders.add(currentSection!);
        currentSection = _SectionBuilder(
          name:
              'Part ${_roman(sectionBuilders.length + 1)} · ${_labelForType(qType)}',
          questionType: qType,
          defaultPoints: q.points,
        );
      }

      final normalizedChoices = <String>[];
      if (qType == 'multiple_choice') {
        for (final letter in const ['A', 'B', 'C', 'D']) {
          normalizedChoices.add((q.choices[letter] ?? '').trim());
        }
      }

      currentSection!.questions.add(
        ImportedExamQuestion(
          questionNumber: currentSection!.questions.length + 1,
          questionText: q.stem.toString().trim(),
          questionType: qType,
          points: currentSection!.defaultPoints,
          choices: normalizedChoices,
          correctAnswer: q.correctAnswer,
        ),
      );
    }

    // Regex patterns
    // Section header like "A.  (35 items x 2 points)" or "Part I. Multiple Choice (2 points each)"
    final stiSectionHeaderRe = RegExp(
      r'^([A-Z]|Part\s+[IVX\d]+)[\.\)]\s*\((\d+)\s*items?\s*(?:[x\u00D7\*]\s*(\d+(?:\.\d+)?)\s*points?)?.*\)',
      caseSensitive: false,
    );
    final genericSectionHeaderRe = RegExp(
      r'^(?:Part|Section|Test)\s+([IVX\d]+|[A-Z])[\.\:\-\s]+(.+)$',
      caseSensitive: false,
    );
    // Question stem like "1.   It consists of..." or "1) It consists of..."
    final questionStartRe = RegExp(r'^(\d{1,3})[\.\)]\s+(.+)$');
    // Option line like "A.   Application Layer" or "*A. Application Layer"
    final choiceStartRe = RegExp(r'^(\*)?([A-Da-d])[\.\)]\s+(.+)$');
    // Embedded answer line like "Answer: B" or "Correct Answer: TRUE"
    final answerLineRe = RegExp(
      r'^(?:correct\s+)?answer\s*(?:\(true\s*\/\s*false\))?\s*:\s*(.+)$',
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
          sectionBuilders.isEmpty &&
          currentSection == null) {
        if (lower == 'notice:' || lower.startsWith('notice:')) {
          inNotice = true;
          noticeLines.add(line);
          continue;
        }
        if (inNotice && RegExp(r'^[\u2022\-\*]').hasMatch(line)) {
          noticeLines.add(line);
          continue;
        }
      }

      // Check for section-level instruction lines
      if (lower.contains('choose the letter of the correct answer') ||
          lower.contains('multiple choice')) {
        pendingQuestionType = 'multiple_choice';
        if (inNotice) {
          noticeLines.add(line);
          inNotice = false;
        }
        if (lower.startsWith('read and analyze') ||
            lower.startsWith('direction') ||
            lower.startsWith('instruction')) {
          continue;
        }
      } else if (lower.contains('write true if') ||
          lower.contains('true or false') ||
          lower.contains('modified true or false')) {
        pendingQuestionType = 'true_false';
        inNotice = false;
        if (lower.startsWith('read and analyze') ||
            lower.startsWith('direction') ||
            lower.startsWith('instruction')) {
          continue;
        }
      } else if (lower.contains('write the correct answer on the space') ||
          lower.contains('identification') ||
          lower.contains('fill in the blank')) {
        pendingQuestionType = 'identification';
        inNotice = false;
        if (lower.startsWith('read and analyze') ||
            lower.startsWith('direction') ||
            lower.startsWith('instruction')) {
          continue;
        }
      }

      // Check STI Section Header: e.g. "A.  (35 items x 2 points)"
      final stiSecMatch = stiSectionHeaderRe.firstMatch(line);
      if (stiSecMatch != null) {
        flushQuestion();
        if (currentSection != null && currentSection!.questions.isNotEmpty) {
          sectionBuilders.add(currentSection!);
        }
        final secLetter = stiSecMatch.group(1)!.trim();
        final pts = double.tryParse(stiSecMatch.group(3) ?? '') ?? 1.0;
        currentSection = _SectionBuilder(
          name: 'Section $secLetter · ${_labelForType(pendingQuestionType)}',
          questionType: pendingQuestionType,
          defaultPoints: pts,
        );
        inNotice = false;
        continue;
      }

      // Check Generic Section Header: e.g. "Part II: True or False"
      final genSecMatch = genericSectionHeaderRe.firstMatch(line);
      if (genSecMatch != null && currentQuestion == null) {
        flushQuestion();
        if (currentSection != null && currentSection!.questions.isNotEmpty) {
          sectionBuilders.add(currentSection!);
        }
        final secTitle = line;
        final ptsMatch = RegExp(
          r'(\d+(?:\.\d+)?)\s*(?:pts?|points?)\s*(?:each|/item)?',
          caseSensitive: false,
        ).firstMatch(secTitle);
        final pts = double.tryParse(ptsMatch?.group(1) ?? '') ?? 1.0;
        currentSection = _SectionBuilder(
          name: secTitle,
          questionType: pendingQuestionType,
          defaultPoints: pts,
        );
        inNotice = false;
        continue;
      }

      // Check Embedded Answer Line: e.g. "Answer: B" or "Answer: _____"
      final ansMatch = answerLineRe.firstMatch(line);
      if (ansMatch != null) {
        final rawAns = ansMatch.group(1)!.trim();
        // Ignore blank underline placeholders like "____________"
        if (!RegExp(r'^_+$').hasMatch(rawAns) && currentQuestion != null) {
          final cleanAns = rawAns.replaceAll(RegExp(r'^_+|_+$'), '').trim();
          if (cleanAns.isNotEmpty) {
            currentQuestion!.correctAnswer = cleanAns;
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

        // Handle inline multiple choices on a single line, e.g. "A. Opt1   B. Opt2"
        final inlineChoices = _splitInlineChoices('$letter. $choiceText');
        if (inlineChoices.length > 1) {
          for (final entry in inlineChoices.entries) {
            currentQuestion!.choices[entry.key] = entry.value;
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
        final qStem = qMatch.group(2)!.trim();
        currentQuestion = _QuestionBuilder(
          number: qNum,
          stem: StringBuffer(qStem),
          inferredType: currentSection?.questionType ?? pendingQuestionType,
          points: currentSection?.defaultPoints ?? 1.0,
        );
        continue;
      }

      // Continuation of current choice or current question stem
      if (currentQuestion != null) {
        if (currentChoiceLetter != null) {
          final prev = currentQuestion!.choices[currentChoiceLetter!] ?? '';
          currentQuestion!.choices[currentChoiceLetter!] =
              prev.isEmpty ? line : '$prev $line';
        } else {
          currentQuestion!.stem.write(' $line');
        }
      }
    }

    flushQuestion();
    if (currentSection != null && currentSection!.questions.isNotEmpty) {
      sectionBuilders.add(currentSection!);
    }

    final finalSections = sectionBuilders
        .map(
          (b) => ImportedExamSection(
            name: b.name,
            questionType: b.questionType,
            defaultPoints: b.defaultPoints,
            questions: b.questions,
          ),
        )
        .toList();

    // Infer assessment type from total question count if not explicitly in header
    if (detectedType == null) {
      final totalQ = finalSections.fold<int>(
        0,
        (s, sec) => s + sec.questions.length,
      );
      if (totalQ >= 35) {
        detectedType = 'prelim';
      } else if (totalQ >= 15) {
        detectedType = 'long_quiz';
      } else {
        detectedType = 'quiz';
      }
    }

    final instructionsText = noticeLines.isNotEmpty
        ? noticeLines.join('\n')
        : QuestionPaperPdfService.defaultInstructionsText;

    return ImportedQuestionPaper(
      fileName: fileName,
      sections: finalSections,
      detectedAssessmentType: detectedType,
      detectedSubjectName: detectedSubject,
      detectedQuizTitle: detectedQuizTitle,
      detectedExamDay: detectedDay,
      detectedExamDate: detectedDate,
      detectedStartTime: detectedStart,
      detectedEndTime: detectedEnd,
      detectedReferenceNo: detectedRef,
      detectedInstructions: instructionsText,
    );
  }

  static Map<String, String> _splitInlineChoices(String line) {
    final matches = RegExp(r'(?:^|\s{2,})([A-Da-d])[\.\)]\s+')
        .allMatches(line)
        .toList();
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

  static String _labelForType(String qType) {
    switch (qType) {
      case 'multiple_choice':
        return 'Multiple Choice';
      case 'true_false':
        return 'True or False';
      case 'identification':
        return 'Identification';
      default:
        return 'Questions';
    }
  }

  static String _roman(int n) {
    const numerals = ['I', 'II', 'III', 'IV', 'V', 'VI', 'VII', 'VIII', 'IX', 'X'];
    if (n >= 1 && n <= numerals.length) return numerals[n - 1];
    return '$n';
  }
}

class _SectionBuilder {
  _SectionBuilder({
    required this.name,
    required this.questionType,
    required this.defaultPoints,
  });

  String name;
  String questionType;
  double defaultPoints;
  final List<ImportedExamQuestion> questions = <ImportedExamQuestion>[];
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
  final String inferredType;
  final double points;
  final Map<String, String> choices = <String, String>{};
  String? correctAnswer;
}
