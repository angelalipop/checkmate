import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;
import 'package:xml/xml.dart';

/// What was read out of an uploaded curriculum file, ready for the server.
class ParsedCurriculumFile {
  ParsedCurriculumFile({
    required this.rows,
    required this.electives,
    required this.problems,
    required this.skippedOjt,
    this.programCode,
    this.curriculumCode,
  });

  /// Term subjects: {year_level, term, code?, name, units?, is_elective_slot?}
  final List<Map<String, dynamic>> rows;

  /// LIST OF ELECTIVES: {code?, name, units?, group_name?}
  final List<Map<String, dynamic>> electives;

  /// Human-readable problems (subject outside a year/semester, no name...).
  final List<String> problems;

  /// OJT / practicum / summer rows that were left out on purpose.
  final int skippedOjt;

  /// Program and curriculum found inside the file or in its file name,
  /// e.g. BSIT and 2601. Null when the file does not say.
  final String? programCode;
  final String? curriculumCode;

  ParsedCurriculumFile withNames({String? program, String? curriculum}) {
    return ParsedCurriculumFile(
      rows: rows,
      electives: electives,
      problems: problems,
      skippedOjt: skippedOjt,
      programCode: programCode ?? program,
      curriculumCode: curriculumCode ?? curriculum,
    );
  }
}

/// Reads a curriculum from:
///   * an Excel (.xlsx) file laid out like the Sample Guide
///     (named Program_Curriculum, e.g. BSIT_2601.xlsx),
///   * the STI Program Guide PDF (e.g. STI_College_BSAIS_Program.pdf),
///   * or a CSV / Excel table with Year Level and Semester columns.
class CurriculumFileParser {
  static const String fileNameHelp =
      'Name the file Program_Curriculum, for example BSIT_2601.xlsx';

  static ParsedCurriculumFile parse(
    Uint8List bytes,
    String fileName, {
    bool shs = false,
  }) {
    final lower = fileName.toLowerCase();
    final named = _fromFileName(fileName);

    final ParsedCurriculumFile result;
    if (lower.endsWith('.pdf')) {
      result = shs ? _parseShsPdf(bytes) : _parsePdf(bytes);
    } else if (lower.endsWith('.xlsx')) {
      result = _parseGrid(_readXlsx(bytes));
    } else if (lower.endsWith('.csv')) {
      result = _parseGrid(_readCsv(utf8.decode(bytes, allowMalformed: true)));
    } else {
      throw const FormatException(
        'Unsupported file type. Choose an Excel (.xlsx) or PDF file.',
      );
    }
    return result.withNames(
      program: named.program,
      curriculum: named.curriculum,
    );
  }

  /// BSIT_2601.xlsx -> (BSIT, 2601).  STI_College_BSAIS_Program.pdf -> (BSAIS, null)
  static ({String? program, String? curriculum}) _fromFileName(String name) {
    final base = name.split(RegExp(r'[\\/]')).last;
    final noExt = base.replaceFirst(RegExp(r'\.[A-Za-z0-9]+$'), '');

    final sti = RegExp(
      r'^STI_College_([A-Za-z0-9]+)_Program',
      caseSensitive: false,
    ).firstMatch(noExt);
    if (sti != null) return (program: sti.group(1), curriculum: null);

    final m = RegExp(r'^([A-Za-z0-9]+)[_-](\d{4})$').firstMatch(noExt);
    if (m != null) return (program: m.group(1), curriculum: m.group(2));

    return (program: null, curriculum: null);
  }
}

class _Builder {
  int? year;
  int? term;
  bool skip = false; // summer / OJT term
  bool inElectives = false;
  bool gradeMode = false; // Senior High School layout (Grade 11 / Grade 12)
  String? group;

  final rows = <Map<String, dynamic>>[];
  final electives = <Map<String, dynamic>>[];
  final problems = <String>[];
  int skippedOjt = 0;

  static final RegExp _yearRe = RegExp(
    r'\b(first|second|third|fourth|1st|2nd|3rd|4th)\s+year\b',
    caseSensitive: false,
  );
  static final RegExp _gradeRe = RegExp(
    r'\bgrade\s*(11|12)\b',
    caseSensitive: false,
  );
  static final RegExp _termAfterYear = RegExp(
    r'\b(first|second|1st|2nd|summer)\b',
    caseSensitive: false,
  );
  static final RegExp _termRe = RegExp(
    r'\b(first|second|1st|2nd)\s+(semester|sem|term)\b|\bsummer\b',
    caseSensitive: false,
  );
  static final RegExp _electivesRe = RegExp(
    r'list\s+of\s+electives',
    caseSensitive: false,
  );
  static final RegExp _ojtLike = RegExp(
    r'^OJTC|practicum|internship|on[- ]the[- ]job|\bOJT\b|work immersion',
    caseSensitive: false,
  );

  static int _ordinal(String w) {
    switch (w.toLowerCase()) {
      case 'first':
      case '1st':
        return 1;
      case 'second':
      case '2nd':
        return 2;
      case 'third':
      case '3rd':
        return 3;
      default:
        return 4;
    }
  }

  void _setTerm(String word) {
    if (word.toLowerCase() == 'summer') {
      skip = true;
      term = null;
    } else {
      skip = false;
      term = _ordinal(word);
    }
  }

  /// Handles a "1st Year", "1st Semester", "FIRST YEAR - SECOND TERM" or
  /// "LIST OF ELECTIVES" heading. Returns true when the text was a heading.
  bool heading(String text, {int maxLength = 80}) {
    final t = text.trim();
    if (t.isEmpty || t.length > maxLength) return false;

    if (_electivesRe.hasMatch(t)) {
      inElectives = true;
      skip = false;
      year = null;
      term = null;
      group = null;
      return true;
    }

    final y = _yearRe.firstMatch(t);
    final g = _gradeRe.firstMatch(t);
    if (y != null || g != null) {
      inElectives = false;
      group = null;
      skip = false;
      term = null;
      if (y != null) {
        year = _ordinal(y.group(1)!);
        final rest = t.substring(y.end);
        final tm = _termAfterYear.firstMatch(rest);
        if (tm != null) _setTerm(tm.group(1)!);
      } else {
        gradeMode = true;
        year = g!.group(1) == '11' ? 1 : 2;
        final rest = t.substring(g.end);
        final tm = _termAfterYear.firstMatch(rest);
        if (tm != null) _setTerm(tm.group(1)!);
      }
      return true;
    }

    final tm = _termRe.firstMatch(t);
    if (tm != null) {
      inElectives = false;
      group = null;
      final word = tm.group(1) ?? 'summer';
      _setTerm(word);
      return true;
    }
    return false;
  }

  void addSubject({
    String? code,
    required String name,
    String? units,
    String? category,
    String? hours,
    required String where,
  }) {
    final n = name.trim();
    final c = (code ?? '').trim();
    if (n.isEmpty) {
      problems.add('$where: course name is missing.');
      return;
    }
    if (_ojtLike.hasMatch('$c $n')) {
      skippedOjt++;
      return;
    }

    final u = (units ?? '').trim();

    if (inElectives) {
      electives.add({
        'name': n,
        if (c.isNotEmpty) 'code': c,
        if (u.isNotEmpty) 'units': u,
        if (group != null && group!.isNotEmpty) 'group_name': group,
      });
      return;
    }

    if (skip) {
      skippedOjt++;
      return;
    }

    if (year == null || term == null) {
      problems.add(
        '$where: "$n" is not under a year level and semester heading.',
      );
      return;
    }

    final h = (hours ?? '').trim();
    if (gradeMode) {
      if (category == null) {
        problems.add('$where: "$n" needs Core, Applied or Specialized.');
        return;
      }
      if (h.isEmpty) {
        problems.add('$where: "$n" needs its required hours.');
        return;
      }
    }

    rows.add({
      'year_level': year,
      'term': term,
      'name': n,
      if (c.isNotEmpty) 'code': c,
      if (u.isNotEmpty) 'units': u,
      'category': ?category,
      if (h.isNotEmpty) 'hours': h,
      if (RegExp(r'\belective\b', caseSensitive: false).hasMatch(n))
        'is_elective_slot': true,
    });
  }
}

// =============================================================
// Excel / CSV
// =============================================================

ParsedCurriculumFile _parseGrid(List<List<String>> grid) {
  final flat = _flatColumns(grid);
  if (flat != null) return _parseFlat(grid, flat.$1, flat.$2);
  return _parseOutline(grid);
}

String _n(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

final RegExp _codeCell = RegExp(r'^[A-Za-z]{2,6}\s?-?\d{3,5}[A-Za-z]?$');
final RegExp _numberCell = RegExp(r'^\d+(\.\d+)?$');

/// The Sample Guide layout: a block per year level and semester, then the
/// LIST OF ELECTIVES with a classification name above each group.
ParsedCurriculumFile _parseOutline(List<List<String>> grid) {
  final b = _Builder();
  String? programCode;
  String? curriculumCode;

  String? after(List<String> cells, int from) {
    for (var i = from + 1; i < cells.length; i++) {
      if (cells[i].isNotEmpty) return cells[i];
    }
    return null;
  }

  for (var r = 0; r < grid.length; r++) {
    final cells = grid[r].map((c) => c.trim()).toList();
    final firstIdx = cells.indexWhere((c) => c.isNotEmpty);
    if (firstIdx < 0) continue;

    final first = cells[firstIdx];
    final firstNorm = _n(first);
    final where = 'Row ${r + 1}';
    final filled = cells.where((c) => c.isNotEmpty).length;

    if (firstNorm == 'program' || firstNorm == 'program code') {
      programCode = after(cells, firstIdx)?.toUpperCase();
      continue;
    }
    if (firstNorm == 'curriculum' ||
        firstNorm == 'curriculum code' ||
        firstNorm == 'curriculum version') {
      final digits = RegExp(r'\d{4}').firstMatch(after(cells, firstIdx) ?? '');
      curriculumCode = digits?.group(0);
      continue;
    }
    if (firstNorm == 'total' ||
        firstNorm == 'course code' ||
        firstNorm == 'code' ||
        firstNorm == 'subject code' ||
        firstNorm == 'course name' ||
        firstNorm == 'subject name' ||
        firstNorm == 'subject') {
      continue;
    }

    // course code + course name (+ units)
    if (_codeCell.hasMatch(first)) {
      String? name;
      String? units;
      var seenName = false;
      for (var i = firstIdx + 1; i < cells.length; i++) {
        if (cells[i].isEmpty) continue;
        if (!seenName) {
          name = cells[i];
          seenName = true;
        } else if (_numberCell.hasMatch(cells[i])) {
          units = cells[i];
          break;
        }
      }
      b.addSubject(code: first, name: name ?? '', units: units, where: where);
      continue;
    }

    // year / semester / list of electives headings
    final joined = cells.where((c) => c.isNotEmpty).join(' ');
    if (joined.length <= 45 && b.heading(joined, maxLength: 45)) continue;

    // Senior High School: Course Name | Core/Applied/Specialized | Hours
    // (or one cell such as "Oral Communication (Core - 80 hrs)")
    if (b.gradeMode && b.year != null && b.term != null && !b.inElectives) {
      var name = first;
      String? category;
      String? hours;
      final inline = RegExp(
        r'^(.*?)\s*\(\s*(core|applied|specialized)\s*[-\u2013\u2014]\s*(\d+)\s*(?:hrs?|hours)?\s*\)\s*$',
        caseSensitive: false,
      ).firstMatch(first);
      if (inline != null) {
        name = inline.group(1)!.trim();
        category = inline.group(2)!.toLowerCase();
        hours = inline.group(3);
      }
      for (var i = firstIdx + 1; i < cells.length; i++) {
        final c = cells[i];
        if (c.isEmpty) continue;
        final lc = c.toLowerCase();
        if (lc.startsWith('core')) {
          category = 'core';
        } else if (lc.startsWith('applied')) {
          category = 'applied';
        } else if (lc.startsWith('special')) {
          category = 'specialized';
        } else if (_numberCell.hasMatch(c)) {
          hours = c;
        }
      }
      b.addSubject(name: name, category: category, hours: hours, where: where);
      continue;
    }

    if (b.inElectives) {
      // a single entry in the first column is a classification name
      if (filled == 1 && firstIdx == 0) {
        b.group = first;
        continue;
      }
      // blank course code: the name sits in a later column
      if (firstIdx >= 1) {
        b.addSubject(
          name: first,
          units: _firstNumber(cells, firstIdx),
          where: where,
        );
      }
      continue;
    }

    // blank course code (for example an elective slot that has no code yet)
    if (firstIdx >= 1 && b.year != null) {
      b.addSubject(
        name: first,
        units: _firstNumber(cells, firstIdx),
        where: where,
      );
    }
  }

  return ParsedCurriculumFile(
    rows: b.rows,
    electives: b.electives,
    problems: b.problems,
    skippedOjt: b.skippedOjt,
    programCode: programCode,
    curriculumCode: curriculumCode,
  );
}

String? _firstNumber(List<String> cells, int from) {
  for (var i = from + 1; i < cells.length; i++) {
    if (_numberCell.hasMatch(cells[i])) return cells[i];
  }
  return null;
}

// ----- flat table: Year Level | Semester | Course Code | Course Name -----

(int, Map<String, int>)? _flatColumns(List<List<String>> grid) {
  for (var r = 0; r < grid.length && r < 15; r++) {
    final found = <String, int>{};
    for (var c = 0; c < grid[r].length; c++) {
      final h = _n(grid[r][c]);
      if (h.isEmpty) continue;
      if (h == 'year level' ||
          h == 'year' ||
          h == 'grade' ||
          h == 'grade level') {
        found['year'] = c;
      } else if (h == 'semester' || h == 'term' || h == 'sem') {
        found['term'] = c;
      } else if (h == 'course code' || h == 'code' || h == 'subject code') {
        found['code'] = c;
      } else if (h == 'course name' ||
          h == 'subject' ||
          h == 'subject name' ||
          h == 'descriptive title' ||
          h == 'course title' ||
          h == 'name') {
        found['name'] = c;
      } else if (h == 'units') {
        found['units'] = c;
      }
    }
    if (found.containsKey('year') &&
        found.containsKey('term') &&
        found.containsKey('name')) {
      return (r, found);
    }
  }
  return null;
}

ParsedCurriculumFile _parseFlat(
  List<List<String>> grid,
  int headerRow,
  Map<String, int> cols,
) {
  final b = _Builder();

  String cell(List<String> row, String key) {
    final i = cols[key];
    if (i == null || i >= row.length) return '';
    return row[i].trim();
  }

  int? ordinal(String raw, int max) {
    final s = raw.toLowerCase().trim();
    if (s.isEmpty) return null;
    const words = {'first': 1, 'second': 2, 'third': 3, 'fourth': 4};
    for (final e in words.entries) {
      if (s.contains(e.key)) return e.value <= max ? e.value : null;
    }
    final m = RegExp(r'\d+').firstMatch(s);
    if (m == null) return null;
    final v = int.parse(m.group(0)!);
    return v >= 1 && v <= max ? v : null;
  }

  for (var r = headerRow + 1; r < grid.length; r++) {
    final row = grid[r];
    if (row.every((c) => c.trim().isEmpty)) continue;
    final code = cell(row, 'code');
    final name = cell(row, 'name');
    if (code.isEmpty && name.isEmpty) continue;

    final yearRaw = cell(row, 'year');
    final termRaw = cell(row, 'term');
    final grade = RegExp(
      r'grade\s*(11|12)',
      caseSensitive: false,
    ).firstMatch(yearRaw);
    final year = grade != null
        ? (grade.group(1) == '11' ? 1 : 2)
        : ordinal(yearRaw, 4);
    final term = ordinal(termRaw, 2);

    if (year == null) {
      b.problems.add('Row ${r + 1}: year level "$yearRaw" is not recognised.');
      continue;
    }
    if (term == null) {
      b.problems.add('Row ${r + 1}: semester "$termRaw" is not recognised.');
      continue;
    }
    b.year = year;
    b.term = term;
    b.skip = false;
    b.inElectives = false;
    b.addSubject(
      code: code,
      name: name,
      units: cell(row, 'units'),
      where: 'Row ${r + 1}',
    );
  }

  return ParsedCurriculumFile(
    rows: b.rows,
    electives: b.electives,
    problems: b.problems,
    skippedOjt: b.skippedOjt,
  );
}

// ----- CSV -----

List<List<String>> _readCsv(String text) {
  final rows = <List<String>>[];
  var row = <String>[];
  final cell = StringBuffer();
  var quoted = false;

  void endCell() {
    row.add(cell.toString());
    cell.clear();
  }

  void endRow() {
    endCell();
    rows.add(row);
    row = <String>[];
  }

  final src = text.startsWith('\uFEFF') ? text.substring(1) : text;
  for (var i = 0; i < src.length; i++) {
    final ch = src[i];
    if (quoted) {
      if (ch == '"') {
        if (i + 1 < src.length && src[i + 1] == '"') {
          cell.write('"');
          i++;
        } else {
          quoted = false;
        }
      } else {
        cell.write(ch);
      }
    } else if (ch == '"') {
      quoted = true;
    } else if (ch == ',') {
      endCell();
    } else if (ch == '\n') {
      endRow();
    } else if (ch != '\r') {
      cell.write(ch);
    }
  }
  if (cell.isNotEmpty || row.isNotEmpty) endRow();
  return rows;
}

// ----- XLSX -----

List<List<String>> _readXlsx(Uint8List bytes) {
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes);
  } catch (_) {
    throw const FormatException('Not an Excel workbook.');
  }

  ArchiveFile? find(String name) {
    for (final f in archive.files) {
      if (f.name == name) return f;
    }
    return null;
  }

  String textOf(ArchiveFile f) =>
      utf8.decode(f.content as List<int>, allowMalformed: true);

  final shared = <String>[];
  final ss = find('xl/sharedStrings.xml');
  if (ss != null) {
    final doc = XmlDocument.parse(textOf(ss));
    for (final si in doc.findAllElements('si')) {
      shared.add(si.findAllElements('t').map((t) => t.innerText).join());
    }
  }

  ArchiveFile? sheet = find('xl/worksheets/sheet1.xml');
  if (sheet == null) {
    for (final f in archive.files) {
      if (f.name.startsWith('xl/worksheets/sheet') && f.name.endsWith('.xml')) {
        sheet = f;
        break;
      }
    }
  }
  if (sheet == null) {
    throw const FormatException('The workbook has no sheets.');
  }

  int colIndex(String ref) {
    var n = 0;
    for (final u in ref.codeUnits) {
      if (u >= 65 && u <= 90) {
        n = n * 26 + (u - 64);
      } else if (u >= 97 && u <= 122) {
        n = n * 26 + (u - 96);
      } else {
        break;
      }
    }
    return n - 1;
  }

  final doc = XmlDocument.parse(textOf(sheet));
  final rows = <List<String>>[];

  for (final rowEl in doc.findAllElements('row')) {
    final rowNumber = int.tryParse(rowEl.getAttribute('r') ?? '');
    if (rowNumber != null) {
      while (rows.length < rowNumber - 1) {
        rows.add(<String>[]);
      }
    }
    final cells = <String>[];
    for (final c in rowEl.findElements('c')) {
      final ref = c.getAttribute('r') ?? '';
      final idx = ref.isEmpty ? cells.length : colIndex(ref);
      while (cells.length < idx) {
        cells.add('');
      }
      final type = c.getAttribute('t');
      String value;
      if (type == 's') {
        final i = int.tryParse(c.getElement('v')?.innerText ?? '');
        value = i != null && i >= 0 && i < shared.length ? shared[i] : '';
      } else if (type == 'inlineStr') {
        value = c.findAllElements('t').map((t) => t.innerText).join();
      } else {
        value = c.getElement('v')?.innerText ?? '';
        final d = double.tryParse(value);
        if (d != null && d == d.roundToDouble()) value = d.toInt().toString();
      }
      if (idx < cells.length) {
        cells[idx] = value;
      } else {
        cells.add(value);
      }
    }
    rows.add(cells);
  }
  return rows;
}

// =============================================================
// STI Program Guide PDF
// =============================================================

class _Word {
  _Word(this.text, this.x0, this.x1, this.y);
  final String text;
  final double x0;
  final double x1;
  final double y; // vertical centre, points from the top of the page
}

class _Line {
  _Line(this.y, this.words);
  double y;
  final List<_Word> words;
}

class _Frag {
  _Frag(this.y, this.x, this.text);
  final double y;
  final double x;
  final String text;
}

class _PdfRow {
  _PdfRow({
    required this.y,
    required this.page,
    required this.code,
    required this.units,
    required this.group,
  });
  final double y;
  final int page;
  final String? code;
  final String? units;
  final String? group;
  final List<_Frag> frags = [];
}

class _Cont {
  _Cont(this.y, this.page, this.text);
  final double y;
  final int page;
  final String text;
}

class _Block {
  _Block({
    required this.year,
    required this.term,
    required this.skip,
    required this.electives,
  });
  final int? year;
  final int? term;
  final bool skip;
  final bool electives;
  final rows = <_PdfRow>[];
  final conts = <_Cont>[];
}

final RegExp _pdfCode = RegExp(r'^[A-Z]{4}\d{4}$');
final RegExp _digits12 = RegExp(r'^\d{1,2}$');
const Set<String> _headerWords = {
  'COURSE',
  'CODE',
  'PRE-',
  'PRE',
  'REQUISITE(S)',
  'PREREQUISITE(S)',
  'PRE-REQUISITE(S)',
  'UNITS',
};

double _median(List<double> v) {
  final s = [...v]..sort();
  final m = s.length ~/ 2;
  return s.length.isOdd ? s[m] : (s[m - 1] + s[m]) / 2;
}

List<_Line> _clusterLines(List<_Word> words) {
  final sorted = [...words]
    ..sort((a, b) {
      final c = a.y.compareTo(b.y);
      return c != 0 ? c : a.x0.compareTo(b.x0);
    });
  final lines = <_Line>[];
  for (final w in sorted) {
    if (lines.isNotEmpty && (lines.last.y - w.y).abs() <= 3.2) {
      final l = lines.last;
      l.words.add(w);
      l.y = l.words.map((x) => x.y).reduce((a, b) => a + b) / l.words.length;
    } else {
      lines.add(_Line(w.y, [w]));
    }
  }
  for (final l in lines) {
    l.words.sort((a, b) => a.x0.compareTo(b.x0));
  }
  return lines;
}

String _joinFragments(List<_Frag> frags) {
  final sorted = [...frags]..sort((a, b) => a.y.compareTo(b.y));
  final out = <String>[];
  var i = 0;
  while (i < sorted.length) {
    final group = <_Frag>[sorted[i]];
    var j = i + 1;
    while (j < sorted.length && sorted[j].y - sorted[i].y <= 5) {
      group.add(sorted[j]);
      j++;
    }
    group.sort((a, b) => a.x.compareTo(b.x));
    out.addAll(group.map((f) => f.text));
    i = j;
  }
  return out.join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();
}

ParsedCurriculumFile _parsePdf(Uint8List bytes) {
  final sf.PdfDocument doc;
  try {
    doc = sf.PdfDocument(inputBytes: bytes);
  } catch (_) {
    throw const FormatException('Could not open the PDF file.');
  }

  final pages = <int, List<_Word>>{};
  try {
    final extractor = sf.PdfTextExtractor(doc);
    for (final line in extractor.extractTextLines()) {
      for (final w in line.wordCollection) {
        final t = w.text.trim();
        if (t.isEmpty) continue;
        final box = w.bounds;
        pages
            .putIfAbsent(line.pageIndex, () => [])
            .add(_Word(t, box.left, box.right, box.top + box.height / 2));
      }
    }
  } catch (_) {
    throw const FormatException('Could not read the text in the PDF file.');
  } finally {
    doc.dispose();
  }

  if (pages.isEmpty) {
    throw const FormatException(
      'The PDF has no readable text. Use the Program Guide PDF from the STI website, or the Excel sample guide.',
    );
  }

  final b = _Builder();
  String? programCode;
  String? curriculumCode;
  double? unitsX;
  _Block? block;

  void flush() {
    final blk = block;
    if (blk == null) return;
    for (final c in blk.conts) {
      _PdfRow? best;
      var bestDist = 1e9;
      for (final r in blk.rows) {
        if (r.page != c.page) continue;
        final d = (r.y - c.y).abs();
        if (d < bestDist) {
          bestDist = d;
          best = r;
        }
      }
      if (best != null && bestDist <= 15) {
        best.frags.add(_Frag(c.y, 0, c.text));
      }
    }
    // restore the block's own context, then hand each row to the builder
    b.year = blk.year;
    b.term = blk.term;
    b.skip = blk.skip;
    b.inElectives = blk.electives;
    for (final r in blk.rows) {
      b.group = r.group;
      b.addSubject(
        code: r.code,
        name: _joinFragments(r.frags),
        units: r.units,
        where: 'Page ${r.page + 1}',
      );
    }
    block = null;
  }

  _Block snapshot() => _Block(
    year: b.year,
    term: b.term,
    skip: b.skip,
    electives: b.inElectives,
  );

  final pageNumbers = pages.keys.toList()..sort();
  for (final pageIndex in pageNumbers) {
    final lines = _clusterLines(pages[pageIndex]!);

    final unitXs = <double>[
      for (final l in lines)
        for (final w in l.words)
          if (w.text == 'UNITS') w.x0,
    ];
    if (unitXs.isNotEmpty) {
      unitXs.sort();
      unitsX = unitXs.first;
    }

    // where the course-name column starts, from the lines that have a code
    final nameXs = <double>[];
    if (unitsX != null) {
      for (final l in lines) {
        final ws = l.words;
        if (ws.length > 1 &&
            _pdfCode.hasMatch(ws[0].text) &&
            ws[0].x0 < unitsX - 120) {
          nameXs.add(ws[1].x0);
        }
      }
    }
    final nameX = nameXs.isEmpty ? null : _median(nameXs);

    for (final l in lines) {
      final ws = l.words;
      final text = ws.map((w) => w.text).join(' ');

      if (curriculumCode == null) {
        final mv = RegExp(r'\b([A-Za-z]{2,8})-(\d\d)-(\d\d)\b')
            .firstMatch(text);
        if (mv != null) {
          programCode ??= mv.group(1)!.toUpperCase();
          curriculumCode = '${mv.group(2)}${mv.group(3)}';
        }
      }

      // year + term heading, or LIST OF ELECTIVES
      final isElectivesHeading = RegExp(
        r'list\s+of\s+electives',
        caseSensitive: false,
      ).hasMatch(text);
      final isTermHeading = RegExp(
        r'(FIRST|SECOND|THIRD|FOURTH)\s+YEAR\s*-?\s*(FIRST|SECOND|SUMMER)',
        caseSensitive: false,
      ).hasMatch(text);
      if (isElectivesHeading || isTermHeading) {
        flush();
        b.heading(text, maxLength: 120);
        block = snapshot();
        continue;
      }

      if (block == null || unitsX == null) continue;
      if (ws.first.text == 'TOTAL') continue;
      if (!_pdfCode.hasMatch(ws.first.text) &&
          ws.any((w) => _headerWords.contains(w.text))) {
        continue;
      }

      final bound = unitsX - 12;
      final preBound = unitsX + 45;

      _Word? codeW;
      if (_pdfCode.hasMatch(ws.first.text) &&
          ws.first.x0 < bound &&
          (nameX == null || ws.first.x0 < nameX - 5)) {
        codeW = ws.first;
      }
      final nameWs = [
        for (final w in ws)
          if (w.x0 < bound && !identical(w, codeW)) w,
      ];
      final unitWs = [
        for (final w in ws)
          if (w.x0 >= bound && w.x0 < preBound && _digits12.hasMatch(w.text)) w,
      ];

      final looksLikeRow =
          codeW != null ||
          (unitWs.isNotEmpty &&
              nameWs.isNotEmpty &&
              nameX != null &&
              nameWs.first.x0 >= nameX - 5);

      if (looksLikeRow) {
        final row = _PdfRow(
          y: l.y,
          page: pageIndex,
          code: codeW?.text,
          units: unitWs.isEmpty ? null : unitWs.first.text,
          group: b.group,
        );
        if (nameWs.isNotEmpty) {
          row.frags.add(
            _Frag(l.y, nameWs.first.x0, nameWs.map((w) => w.text).join(' ')),
          );
        }
        block!.rows.add(row);
        continue;
      }

      // no code and no units: a wrapped name, a classification, or page noise
      if (nameWs.isEmpty) continue;
      final x0 = nameWs.first.x0;
      if (nameX == null || x0 < nameX - 5) continue;
      final txt = nameWs.map((w) => w.text).join(' ');

      if (block!.electives && x0 > nameX + 20) {
        b.group = txt; // centred classification such as "Graphics Technology"
        continue;
      }
      block!.conts.add(_Cont(l.y, pageIndex, txt));
    }
  }
  flush();

  return ParsedCurriculumFile(
    rows: b.rows,
    electives: b.electives,
    problems: b.problems,
    skippedOjt: b.skippedOjt,
    programCode: programCode,
    curriculumCode: curriculumCode,
  );
}

// SHS PDF parser — separate from College
ParsedCurriculumFile _parseShsPdf(Uint8List bytes) {
  final sf.PdfDocument document;
  try {
    document = sf.PdfDocument(inputBytes: bytes);
  } catch (_) {
    throw const FormatException('Could not open the SHS PDF file.');
  }

  final lines = <String>[];
  try {
    final extractor = sf.PdfTextExtractor(document);
    for (final line in extractor.extractTextLines()) {
      final words = [...line.wordCollection]
        ..sort((a, b) => a.bounds.left.compareTo(b.bounds.left));
      final value = words
          .map((w) => w.text.trim())
          .where((w) => w.isNotEmpty)
          .join(' ')
          .trim();
      if (value.isNotEmpty) lines.add(value);
    }
  } finally {
    document.dispose();
  }

  if (lines.isEmpty) {
    throw const FormatException(
      'No readable text in the SHS PDF. Scanned PDFs require OCR.',
    );
  }

  final rows = <Map<String, dynamic>>[];
  final problems = <String>[];

  final heading = RegExp(
    r'GRADE\s*(11|12)\s*[-–—]?\s*(FIRST|SECOND|1ST|2ND)\s*TERM',
    caseSensitive: false,
  );
  final categoryHeading = RegExp(
    r'^(CORE|APPLIED|SPECIALIZED)\s*SUBJECTS\s*:?$',
    caseSensitive: false,
  );
  final subjectHours = RegExp(r'^(.+?)\s+(\d{1,3})$');
  final total = RegExp(r'^TOTAL\s*(\d{1,4})?$', caseSensitive: false);

  int? year;
  int? term;
  String? category;
  String? pending;
  int? expectedTotal;
  int actualTotal = 0;
  int termRows = 0;
  final found = <String>{};

  void finishTerm() {
    if (year == null || term == null) return;

    if (termRows == 0) {
      problems.add('Grade ${year + 10}, Term $term: no subjects found.');
    }

    if (expectedTotal != null && actualTotal != expectedTotal) {
      problems.add(
        'Grade ${year + 10}, Term $term: '
        'expected $expectedTotal hours, extracted $actualTotal.',
      );
    }

    if (pending != null) {
      problems.add(
        'Grade ${year + 10}, Term $term: '
        'incomplete subject "$pending".',
      );
      pending = null;
    }
  }

  for (final raw in lines) {
    final text = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    final h = heading.firstMatch(text);

    if (h != null) {
      finishTerm();

      year = h.group(1) == '11' ? 1 : 2;
      term = {
        'FIRST': 1,
        '1ST': 1,
        'SECOND': 2,
        '2ND': 2,
      }[h.group(2)!.toUpperCase()];

      category = null;
      expectedTotal = null;
      actualTotal = 0;
      termRows = 0;
      found.add('$year-$term');
      continue;
    }

    if (year == null || term == null) continue;

    final cat = categoryHeading.firstMatch(text);
    if (cat != null) {
      category = cat.group(1)!.toLowerCase();
      continue;
    }

    final t = total.firstMatch(text);
    if (t != null) {
      expectedTotal = int.tryParse(t.group(1) ?? '');
      continue;
    }

    if (RegExp(
      r'^REQUIRED DURATION|^GRADE\s*\d+|^STI\b',
      caseSensitive: false,
    ).hasMatch(text)) {
      continue;
    }

    if (category == null) continue;

    final match = subjectHours.firstMatch(text);

    if (match != null) {
      final name = [
        if (pending != null) pending!,
        match.group(1)!,
      ].join(' ').trim();

      pending = null;
      final hours = int.parse(match.group(2)!);

      if (hours <= 0) {
        problems.add('Invalid duration for "$name".');
        continue;
      }

      rows.add({
        'year_level': year,
        'term': term,
        'name': name,
        'category': category,
        'hours': hours.toString(),
      });

      actualTotal += hours;
      termRows++;
    } else if (!RegExp(
      r'^TOTAL\b|^SUBJECTS\b',
      caseSensitive: false,
    ).hasMatch(text)) {
      pending = [if (pending != null) pending!, text].join(' ');
    }
  }

  finishTerm();

  for (final key in ['1-1', '1-2', '2-1', '2-2']) {
    if (!found.contains(key)) {
      problems.add(
        'Missing Grade ${key.startsWith('1') ? 11 : 12}, '
        'Term ${key.endsWith('1') ? 1 : 2}.',
      );
    }
  }

  return ParsedCurriculumFile(
    rows: rows,
    electives: [],
    problems: problems,
    skippedOjt: 0,
  );
}
