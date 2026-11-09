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

/// Parses an uploaded Questionnaire in multiple file formats (`.pdf`, `.docx`,
/// `.doc`, `.xlsx`, `.csv`, `.tsv`, `.txt`, `.rtf`, `.odt`, `.md`, `.html`)
/// into structured sections, questions, choices, and header metadata, and
/// automatically organizes all uploaded questions according to their respective
/// test types (`multiple_choice`, `true_false`, `identification`).
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

  /// Formats an automatic section name based on 1-based [sectionOrder] and
  /// [questionType], e.g. `"Part I: Multiple Choice"`, `"Part II: True or False"`.
  static String autoSectionName(int sectionOrder, String questionType) {
    return 'Part ${romanNumeral(sectionOrder)}: ${labelForType(questionType)}';
  }

  static String labelForType(String qType) {
    switch (qType.trim().toLowerCase()) {
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

  static ImportedQuestionPaper parseBytes({
    required Uint8List bytes,
    required String fileName,
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
      final tabular = _tryParseTabularRows(rows: rows, fileName: fileName);
      if (tabular != null && tabular.totalQuestions > 0) return tabular;
      final lines = rows
          .map((r) => r.where((c) => c.trim().isNotEmpty).join(' '))
          .where((l) => l.trim().isNotEmpty)
          .toList();
      return _parseExtractedLines(lines: lines, fileName: fileName);
    }

    if (lowerName.endsWith('.csv') || lowerName.endsWith('.tsv')) {
      final isTsv = lowerName.endsWith('.tsv');
      final rows = _extractRowsFromDelimitedText(
        bytes,
        delimiter: isTsv ? '\t' : ',',
      );
      final tabular = _tryParseTabularRows(rows: rows, fileName: fileName);
      if (tabular != null && tabular.totalQuestions > 0) return tabular;
      final lines = _extractLinesFromPlainText(bytes);
      return _parseExtractedLines(lines: lines, fileName: fileName);
    }

    List<String> lines;
    if (lowerName.endsWith('.pdf') || isPdfHeader) {
      lines = _extractLinesFromPdf(bytes);
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

        // Check if body items use a two-column layout (STI Questionnaire).
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
          allLines.addAll(
            _mergeAndSortColumnLines(leftCol, maxHorizontalGap: pageWidth * 0.18),
          );
          allLines.addAll(
            _mergeAndSortColumnLines(rightCol, maxHorizontalGap: pageWidth * 0.18),
          );
        } else {
          allLines.addAll(
            _mergeAndSortColumnLines(
              bodyItems,
              maxHorizontalGap: pageWidth * 0.18,
            ),
          );
        }
      }

      return allLines;
    } finally {
      document.dispose();
    }
  }

  static List<String> _mergeAndSortColumnLines(
    List<TextLine> items, {
    double maxHorizontalGap = 72.0,
  }) {
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
      final sameRow =
          prevBounds != null && (item.bounds.top - prevBounds.top).abs() <= 3.5;
      final horizontalGap = prevBounds == null
          ? 0.0
          : (item.bounds.left - prevBounds.right);
      final startsNewNumberedQuestion = RegExp(r'^\d{1,3}[\.\)]\s+').hasMatch(t);

      // Do not merge across a wide column gap or when a new numbered question starts.
      if (sameRow &&
          horizontalGap <= maxHorizontalGap &&
          !startsNewNumberedQuestion) {
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
          RegExp(r'\{\\(?:fonttbl|colortbl|stylesheet|info|pict|\*\\[a-z]+)[^}]*\}'),
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

    // Extract printable ASCII / UTF-16 text runs from binary OLE .doc files
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
  /// `Question`, `Type`, `Choice A..D`, `Answer`, `Points` are present.
  static ImportedQuestionPaper? _tryParseTabularRows({
    required List<List<String>> rows,
    required String fileName,
  }) {
    if (rows.length < 2) return null;

    int headerRowIdx = -1;
    int colQuestion = -1;
    int colType = -1;
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

    final parsedQuestions = <ImportedExamQuestion>[];
    for (var r = headerRowIdx + 1; r < rows.length; r++) {
      final row = rows[r];
      String cell(int idx) =>
          (idx >= 0 && idx < row.length) ? row[idx].trim() : '';

      final qText = _stripLeadingQuestionNumber(cell(colQuestion));
      if (qText.isEmpty) continue;

      final rawType = cell(colType).toLowerCase();
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

      final normalizedAnswer = _normalizeAnswerForType(
        rawAnswer,
        qType,
        choices: choices,
      );

      parsedQuestions.add(
        ImportedExamQuestion(
          questionNumber: parsedQuestions.length + 1,
          questionText: qText,
          questionType: qType,
          points: pts > 0 ? pts : 1.0,
          choices: qType == 'multiple_choice' ? choices : const <String>[],
          correctAnswer: normalizedAnswer,
        ),
      );
    }

    if (parsedQuestions.isEmpty) return null;

    final organizedSections = _organizeQuestionsByTestType(parsedQuestions);
    final totalQ = parsedQuestions.length;
    final detectedType = totalQ >= 35
        ? 'prelim'
        : (totalQ >= 15 ? 'long_quiz' : 'quiz');

    return ImportedQuestionPaper(
      fileName: fileName,
      sections: organizedSections,
      detectedAssessmentType: detectedType,
      detectedInstructions: QuestionPaperPdfService.defaultInstructionsText,
    );
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
          lower.startsWith('notice:') ||
          RegExp(r'^\d{1,3}[\.\)]\s+').hasMatch(line)) {
        break;
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

    // 3. Parse Notice, Questions, Choices, and Inferred Test Types
    final allParsedQuestions = <ImportedExamQuestion>[];
    _QuestionBuilder? currentQuestion;
    String? currentChoiceLetter;
    String? activeSectionType;
    double activeDefaultPoints = 1.0;
    bool inNotice = false;

    void flushQuestion() {
      final q = currentQuestion;
      if (q == null) return;
      currentQuestion = null;
      currentChoiceLetter = null;

      final qType = _resolveQuestionType(q);
      final normalizedChoices = <String>[];
      if (qType == 'multiple_choice') {
        for (final letter in const ['A', 'B', 'C', 'D']) {
          normalizedChoices.add((q.choices[letter] ?? '').trim());
        }
      }

      final cleanStem = _stripLeadingQuestionNumber(q.stem.toString().trim());
      if (cleanStem.isEmpty) return;

      final normalizedAnswer = _normalizeAnswerForType(
        q.correctAnswer,
        qType,
        choices: normalizedChoices,
      );

      allParsedQuestions.add(
        ImportedExamQuestion(
          questionNumber: q.number,
          questionText: cleanStem,
          questionType: qType,
          points: q.points > 0 ? q.points : 1.0,
          choices: normalizedChoices,
          correctAnswer: normalizedAnswer,
        ),
      );
    }

    final stiSectionHeaderRe = RegExp(
      r'^([A-Z]|Part\s+[IVX\d]+)[\.\)]\s*\((\d+)\s*items?\s*(?:[x\u00D7\*]\s*(\d+(?:\.\d+)?)\s*points?)?.*\)',
      caseSensitive: false,
    );
    final genericSectionHeaderRe = RegExp(
      r'^(?:Part|Section|Test)\s+([IVX\d]+|[A-Z])[\.\:\-\u00B7\s]+(.+)$',
      caseSensitive: false,
    );
    final standaloneTypeHeaderRe = RegExp(
      r'^(multiple\s+choice|true\s+or\s+false|modified\s+true\s+or\s+false|identification|fill\s+in\s+the\s+blanks?)(?:\s*\((.+)\))?\s*:?$',
      caseSensitive: false,
    );
    final questionStartRe = RegExp(r'^(\d{1,3})[\.\)]\s*(.+)$');
    final choiceStartRe = RegExp(r'^(\*)?(?:\()?([A-Da-d])[\.\)]\s+(.+)$');
    final answerLineRe = RegExp(
      r'^(?:correct\s+)?(?:answer|ans|key)\s*(\(\s*true\s*\/\s*false\s*\))?\s*[:\-]\s*(.*)$',
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
      if (currentQuestion == null && allParsedQuestions.isEmpty) {
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

      // Detect question-type instructions / headings
      final detectedHeaderType = _detectTypeFromLine(lower);
      if (detectedHeaderType != null) {
        if (lower.startsWith('read and analyze') ||
            lower.startsWith('direction') ||
            lower.startsWith('instruction') ||
            standaloneTypeHeaderRe.hasMatch(line)) {
          flushQuestion();
          activeSectionType = detectedHeaderType;
          final ptsMatch = RegExp(
            r'(\d+(?:\.\d+)?)\s*(?:pts?|points?)',
            caseSensitive: false,
          ).firstMatch(line);
          if (ptsMatch != null) {
            activeDefaultPoints =
                double.tryParse(ptsMatch.group(1)!) ?? activeDefaultPoints;
          }
          inNotice = false;
          continue;
        }
      }

      // Check STI Section Header: e.g. "A.  (35 items x 2 points)"
      final stiSecMatch = stiSectionHeaderRe.firstMatch(line);
      if (stiSecMatch != null) {
        flushQuestion();
        final pts = double.tryParse(stiSecMatch.group(3) ?? '');
        if (pts != null && pts > 0) {
          activeDefaultPoints = pts;
        }
        if (detectedHeaderType != null) {
          activeSectionType = detectedHeaderType;
        }
        inNotice = false;
        continue;
      }

      // Check Generic Section Header: e.g. "Part II: True or False"
      final genSecMatch = genericSectionHeaderRe.firstMatch(line);
      if (genSecMatch != null) {
        flushQuestion();
        final secTitle = line;
        final ptsMatch = RegExp(
          r'(\d+(?:\.\d+)?)\s*(?:pts?|points?)\s*(?:each|/item)?',
          caseSensitive: false,
        ).firstMatch(secTitle);
        final pts = double.tryParse(ptsMatch?.group(1) ?? '');
        if (pts != null && pts > 0) {
          activeDefaultPoints = pts;
        }
        final secType = _detectTypeFromLine(secTitle.toLowerCase());
        if (secType != null) {
          activeSectionType = secType;
        }
        inNotice = false;
        continue;
      }

      // Check Embedded Answer Line: e.g. "Answer: B" or "Answer (True / False): _____"
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
          if (!RegExp(r'^_+$').hasMatch(rawAns)) {
            final cleanAns = rawAns.replaceAll(RegExp(r'^_+|_+$'), '').trim();
            if (cleanAns.isNotEmpty) {
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
        final qNum =
            int.tryParse(qMatch.group(1)!) ?? (allParsedQuestions.length + 1);
        var qStem = qMatch.group(2)!.trim();

        // Check for inline answer at end of question stem, e.g. "...? [Answer: CPU]"
        String? inlineAnswer;
        final bracketAnsMatch = RegExp(
          r'[\[\(]\s*(?:answer|ans|key)\s*:\s*([^\]\)]+)[\]\)]\s*$',
          caseSensitive: false,
        ).firstMatch(qStem);
        if (bracketAnsMatch != null) {
          inlineAnswer = bracketAnsMatch.group(1)!.trim();
          qStem = qStem.substring(0, bracketAnsMatch.start).trim();
        }

        currentQuestion = _QuestionBuilder(
          number: qNum,
          stem: StringBuffer(qStem),
          inferredType: activeSectionType,
          points: activeDefaultPoints,
        )..correctAnswer = inlineAnswer;
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

    // Organize all parsed questions by their respective test types and assign
    // sequential Part I, Part II, Part III section names.
    final finalSections = _organizeQuestionsByTestType(allParsedQuestions);

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

  /// Organizes all parsed questions into sections grouped by their respective
  /// test types (`multiple_choice`, `true_false`, `identification`) in order
  /// of appearance, preserving question sequence within each type and
  /// auto-naming sections as `"Part I: Multiple Choice"`, `"Part II: ..."`, etc.
  static List<ImportedExamSection> _organizeQuestionsByTestType(
    List<ImportedExamQuestion> questions,
  ) {
    if (questions.isEmpty) return const <ImportedExamSection>[];

    final typeOrder = <String>[];
    final grouped = <String, List<ImportedExamQuestion>>{};
    final pointsByType = <String, double>{};

    for (final q in questions) {
      final type = q.questionType;
      if (!grouped.containsKey(type)) {
        typeOrder.add(type);
        grouped[type] = <ImportedExamQuestion>[];
        pointsByType[type] = q.points > 0 ? q.points : 1.0;
      }
      grouped[type]!.add(q);
    }

    final sections = <ImportedExamSection>[];
    for (var i = 0; i < typeOrder.length; i++) {
      final type = typeOrder[i];
      final rawList = grouped[type]!;
      final defaultPts = pointsByType[type] ?? 1.0;

      // Renumber sequentially 1..N while maintaining exact relative order.
      final orderedQuestions = <ImportedExamQuestion>[];
      for (var idx = 0; idx < rawList.length; idx++) {
        final item = rawList[idx];
        orderedQuestions.add(
          ImportedExamQuestion(
            questionNumber: idx + 1,
            questionText: item.questionText,
            questionType: type,
            points: item.points > 0 ? item.points : defaultPts,
            choices: item.choices,
            correctAnswer: item.correctAnswer,
          ),
        );
      }

      sections.add(
        ImportedExamSection(
          name: autoSectionName(i + 1, type),
          questionType: type,
          defaultPoints: defaultPts,
          questions: orderedQuestions,
        ),
      );
    }

    return sections;
  }

  static String? _detectTypeFromLine(String lower) {
    if (lower.contains('choose the letter of the correct answer') ||
        lower.contains('multiple choice') ||
        lower.contains('multiple-choice')) {
      return 'multiple_choice';
    }
    if (lower.contains('write true if') ||
        lower.contains('true or false') ||
        lower.contains('true / false') ||
        lower.contains('true/false') ||
        lower.contains('modified true or false')) {
      return 'true_false';
    }
    if (lower.contains('write the correct answer on the space') ||
        lower.contains('identification') ||
        lower.contains('fill in the blank')) {
      return 'identification';
    }
    return null;
  }

  static String _resolveQuestionType(_QuestionBuilder q) {
    final nonEmptyChoices = q.choices.values
        .map((v) => v.trim())
        .where((v) => v.isNotEmpty)
        .toList();

    // Check if choices are just A. True / B. False
    if (nonEmptyChoices.length == 2) {
      final lowerSet = nonEmptyChoices.map((c) => c.toLowerCase()).toSet();
      if (lowerSet.contains('true') && lowerSet.contains('false')) {
        return 'true_false';
      }
    }

    if (nonEmptyChoices.length >= 2) {
      return 'multiple_choice';
    }

    if (q.hasTrueFalsePrompt || _isTrueOrFalseAnswer(q.correctAnswer)) {
      return 'true_false';
    }

    final stemLower = q.stem.toString().trim().toLowerCase();
    if (stemLower.startsWith('(true or false)') ||
        stemLower.startsWith('[true or false]') ||
        stemLower.startsWith('(true/false)') ||
        stemLower.startsWith('[true/false]') ||
        stemLower.endsWith('(true or false)') ||
        stemLower.endsWith('(true/false)')) {
      return 'true_false';
    }

    if (q.inferredType == 'true_false') {
      return 'true_false';
    }

    // Any question without 2+ multiple choice options that is not True/False
    // is an Identification question.
    return 'identification';
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
    if (clean.isEmpty || RegExp(r'^_+$').hasMatch(clean)) return null;

    if (qType == 'multiple_choice') {
      final upper = clean.toUpperCase();
      if (const ['A', 'B', 'C', 'D'].contains(upper)) {
        return upper;
      }
      final letterMatch = RegExp(r'^([A-Da-d])[\.\)]?$').firstMatch(clean);
      if (letterMatch != null) {
        return letterMatch.group(1)!.toUpperCase();
      }
      // Match against option text if full choice text was given as the answer
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
    // Strip any accidental duplicate leading question number (e.g. "2. Which...")
    while (RegExp(r'^\d{1,3}[\.\)]\s+').hasMatch(clean)) {
      clean = clean.replaceFirst(RegExp(r'^\d{1,3}[\.\)]\s+'), '').trim();
    }
    return clean;
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
