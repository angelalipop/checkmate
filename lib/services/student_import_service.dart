import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import 'api_service.dart';

// =============================================================
// CheckMate — Student Excel import (client-side orchestration)
//
// Reuses the EXISTING ApiService methods (getClasses, getStudents,
// createClass, createStudent) so it works without backend changes.
// When a bulk endpoint exists later, replace only `execute()`.
// =============================================================

/// Shared School Year / Semester options used by Classes + Import.
class AcademicOptions {
  static const semesters = ['1st Semester', '2nd Semester', 'Summer'];

  /// Philippine school year starts around June.
  static String currentSchoolYear() {
    final now = DateTime.now();
    final start = now.month >= 6 ? now.year : now.year - 1;
    return '$start-${start + 1}';
  }

  static List<String> schoolYears() {
    final now = DateTime.now();
    final base = now.month >= 6 ? now.year : now.year - 1;
    return [
      for (var y = base - 1; y <= base + 2; y++) '$y-${y + 1}',
    ];
  }
}

// ---------- Minimal .xlsx reader/writer ----------
//
// Built on `archive` + `xml` (already pulled in by image/pdf) because the
// `excel` package pins archive ^3 and conflicts with image's archive ^4.
// Only what the student import needs: read the first non-empty sheet as
// text, and write a header-only template.

class XlsxIO {
  static String _colLetters(String ref) =>
      ref.replaceAll(RegExp(r'[^A-Za-z]'), '').toUpperCase();

  static int _colIndex(String ref) {
    var n = 0;
    for (final u in _colLetters(ref).codeUnits) {
      n = n * 26 + (u - 64);
    }
    return n - 1;
  }

  static String _attr(XmlElement e, String local) {
    for (final a in e.attributes) {
      if (a.name.local == local) return a.value;
    }
    return '';
  }

  static String _text(XmlElement e) => e.children
      .whereType<XmlElement>()
      .where((c) => c.name.local == 't')
      .map((c) => c.innerText)
      .join();

  /// Text of a shared-string <si> (plain or rich text, ignoring phonetics).
  static String _siText(XmlElement si) {
    final b = StringBuffer();
    for (final c in si.children.whereType<XmlElement>()) {
      if (c.name.local == 't') {
        b.write(c.innerText);
      } else if (c.name.local == 'r') {
        b.write(_text(c));
      }
    }
    return b.toString();
  }

  static String _numberText(String raw) {
    final d = double.tryParse(raw);
    if (d == null) return raw.trim();
    if (d == d.truncateToDouble() && d.abs() < 1e15) return d.toInt().toString();
    return raw.trim();
  }

  static String? _read(Map<String, ArchiveFile> files, String name) {
    final f = files[name];
    if (f == null) return null;
    return utf8.decode(f.readBytes() as List<int>, allowMalformed: true);
  }

  /// Returns the rows of the first sheet that has data. Row i of the result
  /// is spreadsheet row i + 1. Throws if the bytes are not a valid .xlsx.
  static List<List<String>> readRows(Uint8List bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final files = <String, ArchiveFile>{
      for (final e in archive)
        if (e.isFile) e.name.replaceAll('\\', '/'): e,
    };

    final workbookXml = _read(files, 'xl/workbook.xml');
    if (workbookXml == null) {
      throw const FormatException('Not an Excel workbook.');
    }

    // Shared strings
    final shared = <String>[];
    final ssXml = _read(files, 'xl/sharedStrings.xml');
    if (ssXml != null) {
      for (final si in XmlDocument.parse(ssXml).findAllElements('si')) {
        shared.add(_siText(si));
      }
    }

    // Sheet paths in workbook order
    final rels = <String, String>{};
    final relsXml = _read(files, 'xl/_rels/workbook.xml.rels');
    if (relsXml != null) {
      for (final r in XmlDocument.parse(relsXml).findAllElements('Relationship')) {
        var target = _attr(r, 'Target');
        if (target.startsWith('/')) {
          target = target.substring(1);
        } else {
          target = 'xl/$target';
        }
        rels[_attr(r, 'Id')] = target;
      }
    }

    final sheetPaths = <String>[];
    for (final sh in XmlDocument.parse(workbookXml).findAllElements('sheet')) {
      final path = rels[_attr(sh, 'id')];
      if (path != null && files.containsKey(path)) sheetPaths.add(path);
    }
    if (sheetPaths.isEmpty) {
      sheetPaths.addAll(
        files.keys.where((k) => RegExp(r'^xl/worksheets/[^/]+\.xml$').hasMatch(k)).toList()
          ..sort(),
      );
    }

    for (final path in sheetPaths) {
      final rows = _readSheet(_read(files, path)!, shared);
      if (rows.any((r) => r.any((c) => c.isNotEmpty))) return rows;
    }
    return <List<String>>[];
  }

  static List<List<String>> _readSheet(String xml, List<String> shared) {
    final rows = <List<String>>[];
    var nextRow = 0;

    for (final row in XmlDocument.parse(xml).findAllElements('row')) {
      final rAttr = int.tryParse(_attr(row, 'r'));
      final rowIndex = rAttr != null ? rAttr - 1 : nextRow;
      nextRow = rowIndex + 1;
      while (rows.length <= rowIndex) {
        rows.add(<String>[]);
      }
      final cells = rows[rowIndex];

      var nextCol = 0;
      for (final c in row.children.whereType<XmlElement>()) {
        if (c.name.local != 'c') continue;
        final ref = _attr(c, 'r');
        final col = ref.isEmpty ? nextCol : _colIndex(ref);
        nextCol = col + 1;

        final type = _attr(c, 't');
        String value = '';
        if (type == 'inlineStr') {
          for (final is_ in c.children.whereType<XmlElement>()) {
            if (is_.name.local == 'is') value = _siText(is_);
          }
        } else {
          XmlElement? v;
          for (final e in c.children.whereType<XmlElement>()) {
            if (e.name.local == 'v') v = e;
          }
          final raw = v?.innerText ?? '';
          if (type == 's') {
            final i = int.tryParse(raw);
            value = (i != null && i >= 0 && i < shared.length) ? shared[i] : '';
          } else if (type == 'str') {
            value = raw;
          } else if (type == 'b') {
            value = raw == '1' ? 'TRUE' : 'FALSE';
          } else if (type == 'e') {
            value = '';
          } else {
            value = raw.isEmpty ? '' : _numberText(raw);
          }
        }

        while (cells.length <= col) {
          cells.add('');
        }
        cells[col] = value.trim();
      }
    }
    return rows;
  }

  static String _esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  /// Builds a single-sheet workbook. [widths] are column widths in characters.
  static List<int> write({
    required String sheetName,
    required List<String> header,
    List<double> widths = const [],
  }) {
    const ns = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main';
    const relNs = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
    const pkgRel = 'http://schemas.openxmlformats.org/package/2006/relationships';

    final cols = StringBuffer();
    if (widths.isNotEmpty) {
      cols.write('<cols>');
      for (var i = 0; i < widths.length; i++) {
        cols.write('<col min="${i + 1}" max="${i + 1}" '
            'width="${widths[i]}" customWidth="1"/>');
      }
      cols.write('</cols>');
    }

    final cells = StringBuffer();
    for (var i = 0; i < header.length; i++) {
      final letter = String.fromCharCode(65 + i);
      cells.write('<c r="${letter}1" t="inlineStr"><is><t>'
          '${_esc(header[i])}</t></is></c>');
    }

    final parts = <String, String>{
      '[Content_Types].xml':
          '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
              '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
              '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
              '<Default Extension="xml" ContentType="application/xml"/>'
              '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
              '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
              '</Types>',
      '_rels/.rels':
          '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
              '<Relationships xmlns="$pkgRel">'
              '<Relationship Id="rId1" Type="$relNs/officeDocument" Target="xl/workbook.xml"/>'
              '</Relationships>',
      'xl/workbook.xml':
          '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
              '<workbook xmlns="$ns" xmlns:r="$relNs">'
              '<sheets><sheet name="${_esc(sheetName)}" sheetId="1" r:id="rId1"/></sheets>'
              '</workbook>',
      'xl/_rels/workbook.xml.rels':
          '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
              '<Relationships xmlns="$pkgRel">'
              '<Relationship Id="rId1" Type="$relNs/worksheet" Target="worksheets/sheet1.xml"/>'
              '</Relationships>',
      'xl/worksheets/sheet1.xml':
          '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
              '<worksheet xmlns="$ns">$cols'
              '<sheetData><row r="1">$cells</row></sheetData></worksheet>',
    };

    final archive = Archive();
    parts.forEach((name, content) {
      archive.addFile(ArchiveFile.bytes(name, utf8.encode(content)));
    });

    final dynamic encoded = ZipEncoder().encode(archive);
    if (encoded == null) {
      throw StateError('Could not create the Excel file.');
    }
    return List<int>.from(encoded as List<int>);
  }
}

// ---------- Parsing models ----------

class ImportRow {
  ImportRow({
    required this.rowNumber,
    required this.studentNumber,
    required this.name,
    required this.section,
    required this.firstName,
    required this.lastName,
    this.email,
  });

  final int rowNumber;
  final String studentNumber;
  final String name;
  final String section;
  final String firstName;
  final String lastName;

  /// Optional — can be added later from the student's info.
  final String? email;
}

class ImportIssue {
  const ImportIssue(this.rowNumber, this.message);
  final int rowNumber;
  final String message;
}

class ImportFileException implements Exception {
  ImportFileException(this.message, {this.missingColumns = const []});
  final String message;
  final List<String> missingColumns;

  @override
  String toString() => message;
}

class ParsedStudentFile {
  ParsedStudentFile(this.rows, this.issues);

  final List<ImportRow> rows; // valid rows only
  final List<ImportIssue> issues; // rows that will be skipped

  Map<String, List<ImportRow>> get bySection {
    final map = <String, List<ImportRow>>{};
    for (final r in rows) {
      map.putIfAbsent(r.section, () => []).add(r);
    }
    return map;
  }
}

// ---------- Plan / result models ----------

class ImportPlanSection {
  ImportPlanSection({
    required this.section,
    required this.existingClassId,
    required this.toAdd,
    required this.duplicates,
  });

  final String section;
  final int? existingClassId; // null => class will be created
  final List<ImportRow> toAdd;
  final List<ImportRow> duplicates;
}

class ImportPlan {
  ImportPlan(this.sections);
  final List<ImportPlanSection> sections;

  int get newClasses => sections.where((s) => s.existingClassId == null).length;
  int get studentsToAdd => sections.fold(0, (n, s) => n + s.toAdd.length);
  List<ImportRow> get duplicates =>
      [for (final s in sections) ...s.duplicates];

  /// Plan where duplicates are dropped (they're already excluded from toAdd).
  bool get nothingToDo => studentsToAdd == 0;
}

class ImportResult {
  ImportResult({
    required this.studentsAdded,
    required this.classesCreated,
    required this.failures,
  });

  final int studentsAdded;
  final int classesCreated;
  final List<ImportIssue> failures;
}

class StudentImportService {
  // ---------- Parsing ----------

  static const _numberAliases = {
    'studentno', 'studentnumber', 'studentid', 'studno', 'idno', 'idnumber',
  };
  static const _nameAliases = {'name', 'studentname', 'fullname'};
  static const _sectionAliases = {
    'section', 'class', 'classsection', 'sectionclass',
  };
  static const _emailAliases = {
    'email', 'emailaddress', 'studentemail', 'emailadd',
  };

  static String _norm(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  /// Throws [ImportFileException] for file-level problems
  /// (wrong type, unreadable, missing columns, no data).
  static ParsedStudentFile parse(Uint8List bytes, String fileName) {
    if (!fileName.toLowerCase().endsWith('.xlsx')) {
      throw ImportFileException(
        'Unsupported file type. Please choose an Excel (.xlsx) file.',
      );
    }

    final List<List<String>> rows;
    try {
      rows = XlsxIO.readRows(bytes);
    } catch (_) {
      throw ImportFileException(
        'The file could not be read. Make sure it is a valid .xlsx file '
        'and is not password-protected.',
      );
    }
    if (rows.isEmpty) {
      throw ImportFileException('The spreadsheet is empty.');
    }

    // Header = first row that has any non-empty cell.
    var headerIndex = -1;
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].any((c) => c.isNotEmpty)) {
        headerIndex = i;
        break;
      }
    }
    if (headerIndex == -1) {
      throw ImportFileException('The spreadsheet is empty.');
    }

    int numCol = -1, nameCol = -1, secCol = -1, emailCol = -1;
    final header = rows[headerIndex];
    for (var c = 0; c < header.length; c++) {
      final h = _norm(header[c]);
      if (numCol == -1 && _numberAliases.contains(h)) numCol = c;
      if (nameCol == -1 && _nameAliases.contains(h)) nameCol = c;
      if (secCol == -1 && _sectionAliases.contains(h)) secCol = c;
      if (emailCol == -1 && _emailAliases.contains(h)) emailCol = c;
    }

    final missing = <String>[
      if (numCol == -1) 'Student No.',
      if (nameCol == -1) 'Name',
      if (secCol == -1) 'Section',
    ];
    if (missing.isNotEmpty) {
      throw ImportFileException(
        'Unable to import students.',
        missingColumns: missing,
      );
    }

    String at(List<String> row, int col) =>
        col < row.length ? row[col] : '';

    final valid = <ImportRow>[];
    final issues = <ImportIssue>[];
    final seen = <String, int>{}; // normalized student no. -> first row

    for (var i = headerIndex + 1; i < rows.length; i++) {
      final row = rows[i];
      final excelRow = i + 1;

      final number = at(row, numCol);
      final name = at(row, nameCol).replaceAll(RegExp(r'\s+'), ' ').trim();
      final section = at(row, secCol);
      final email = emailCol == -1 ? '' : at(row, emailCol);

      // Fully blank row: ignore silently (not a record).
      if (number.isEmpty && name.isEmpty && section.isEmpty && email.isEmpty) {
        continue;
      }

      final problems = <String>[];
      if (number.isEmpty) problems.add('Student No. is empty');
      if (name.isEmpty) problems.add('Name is empty');
      if (section.isEmpty) problems.add('Section is empty');
      // Email is optional, but if it is filled in it must be a real address.
      if (email.isNotEmpty && !StudentValidation.isValidEmail(email)) {
        problems.add('Email "$email" is not valid');
      }

      ({String first, String last})? split;
      if (name.isNotEmpty) {
        split = splitName(name);
        if (split == null) {
          problems.add('Name must include a first and last name');
        }
      }

      if (problems.isEmpty) {
        final key = number.toLowerCase();
        final firstSeen = seen[key];
        if (firstSeen != null) {
          problems.add(
            'Duplicate Student No. "$number" (first used in row $firstSeen)',
          );
        } else {
          seen[key] = excelRow;
        }
      }

      if (problems.isNotEmpty) {
        issues.add(ImportIssue(excelRow, problems.join('; ')));
        continue;
      }

      valid.add(ImportRow(
        rowNumber: excelRow,
        studentNumber: number,
        name: name,
        section: section,
        firstName: split!.first,
        lastName: split.last,
        email: email.isEmpty ? null : email,
      ));
    }

    if (valid.isEmpty && issues.isEmpty) {
      throw ImportFileException(
        'No student rows were found below the header row.',
      );
    }
    if (valid.isEmpty) {
      throw ImportFileException(
        'None of the rows in this file can be imported. '
        'Please fix the problems and try again.',
      );
    }

    return ParsedStudentFile(valid, issues);
  }

  static const _surnameParticles = {
    'de', 'del', 'dela', 'delos', 'de la', 'la', 'san', 'santa', 'santo',
    'van', 'von', 'da', 'di', 'mac', 'bin', 'al',
  };

  /// "Last, First"  or  "First Middle Last" (keeps particles like
  /// "Dela Cruz" / "De Leon" together as the surname).
  /// Returns null if a first+last name cannot be determined.
  static ({String first, String last})? splitName(String full) {
    final clean = full.replaceAll(RegExp(r'\s+'), ' ').trim();

    if (clean.contains(',')) {
      final i = clean.indexOf(',');
      final last = clean.substring(0, i).trim();
      final first = clean.substring(i + 1).trim();
      if (last.isEmpty || first.isEmpty) return null;
      return (first: first, last: last);
    }

    final tokens = clean.split(' ');
    if (tokens.length < 2) return null;

    var lastStart = tokens.length - 1;
    while (lastStart > 1 &&
        _surnameParticles.contains(tokens[lastStart - 1].toLowerCase())) {
      lastStart--;
    }
    return (
      first: tokens.sublist(0, lastStart).join(' '),
      last: tokens.sublist(lastStart).join(' '),
    );
  }

  // ---------- Template ----------

  static List<int> buildTemplate() => XlsxIO.write(
        sheetName: 'Students',
        header: const ['Student No.', 'Name', 'Section', 'Email'],
        widths: const [18, 30, 16, 32],
      );

  // ---------- Matching helpers ----------

  static String _n(Object? v) => (v?.toString() ?? '').trim().toLowerCase();

  static int? _id(Object? v) => int.tryParse(v?.toString() ?? '');

  static int? _classSubjectId(Map<String, dynamic> c) {
    final s = c['subject'];
    if (s is Map && s['id'] != null) return _id(s['id']);
    return _id(c['subject_id']);
  }

  static Map<String, dynamic>? _findClass(
    List<Map<String, dynamic>> classes, {
    required int subjectId,
    required String section,
    required String schoolYear,
    required String semester,
  }) {
    for (final c in classes) {
      if (_classSubjectId(c) == subjectId &&
          _n(c['section']) == _n(section) &&
          _n(c['school_year']) == _n(schoolYear) &&
          _n(c['semester']) == _n(semester)) {
        return c;
      }
    }
    return null;
  }

  // ---------- Plan ----------

  /// Works out which classes already exist and which students are
  /// duplicates (same Student No. already enrolled in that class).
  static Future<ImportPlan> buildPlan({
    required String token,
    required ParsedStudentFile parsed,
    required int subjectId,
    required String schoolYear,
    required String semester,
  }) async {
    final classes = await ApiService.getClasses(token);
    final sections = <ImportPlanSection>[];

    for (final entry in parsed.bySection.entries) {
      final match = _findClass(
        classes,
        subjectId: subjectId,
        section: entry.key,
        schoolYear: schoolYear,
        semester: semester,
      );
      final classId = match == null ? null : _id(match['id']);

      final existingNumbers = <String>{};
      if (classId != null) {
        final existing = await ApiService.getStudents(token, classId: classId);
        for (final s in existing) {
          existingNumbers.add(_n(s['student_number']));
        }
      }

      final toAdd = <ImportRow>[];
      final dupes = <ImportRow>[];
      for (final r in entry.value) {
        (existingNumbers.contains(_n(r.studentNumber)) ? dupes : toAdd).add(r);
      }

      sections.add(ImportPlanSection(
        section: entry.key,
        existingClassId: classId,
        toAdd: toAdd,
        duplicates: dupes,
      ));
    }
    return ImportPlan(sections);
  }

  // ---------- Execute ----------

  /// [teacherId] must be null for a logged-in teacher (backend assigns the
  /// authenticated teacher). Admins pass the selected teacher.
  static Future<ImportResult> execute({
    required String token,
    required ImportPlan plan,
    required int subjectId,
    required String schoolYear,
    required String semester,
    int? teacherId,
    void Function(int done, int total)? onProgress,
  }) async {
    final total = plan.studentsToAdd;
    var done = 0;
    var added = 0;
    var classesCreated = 0;
    final failures = <ImportIssue>[];

    for (final s in plan.sections) {
      if (s.toAdd.isEmpty) continue;

      var classId = s.existingClassId;

      if (classId == null) {
        try {
          await ApiService.createClass(
            token: token,
            subjectId: subjectId,
            teacherId: teacherId,
            section: s.section,
            schoolYear: schoolYear,
            semester: semester,
          );
          classesCreated++;

          // Re-read instead of assuming createClass's return shape.
          final classes = await ApiService.getClasses(token);
          final created = _findClass(
            classes,
            subjectId: subjectId,
            section: s.section,
            schoolYear: schoolYear,
            semester: semester,
          );
          classId = created == null ? null : _id(created['id']);
        } catch (e) {
          classId = null;
          final msg = e.toString().replaceFirst('Exception: ', '');
          for (final r in s.toAdd) {
            failures.add(ImportIssue(
              r.rowNumber,
              'Could not create class ${s.section}: $msg',
            ));
            done++;
          }
          onProgress?.call(done, total);
          continue;
        }

        if (classId == null) {
          for (final r in s.toAdd) {
            failures.add(ImportIssue(
              r.rowNumber,
              'Class ${s.section} was created but could not be found.',
            ));
            done++;
          }
          onProgress?.call(done, total);
          continue;
        }
      }

      // Small concurrent batches: fast enough for 50+ students without
      // hammering the API.
      const batch = 5;
      for (var i = 0; i < s.toAdd.length; i += batch) {
        final chunk = s.toAdd.skip(i).take(batch).toList();
        await Future.wait(chunk.map((r) async {
          try {
            await ApiService.createStudent(
              token: token,
              classId: classId!,
              studentNumber: r.studentNumber,
              firstName: r.firstName,
              lastName: r.lastName,
              email: r.email,
            );
            added++;
          } catch (e) {
            failures.add(ImportIssue(
              r.rowNumber,
              '${r.name}: ${e.toString().replaceFirst('Exception: ', '')}',
            ));
          } finally {
            done++;
            onProgress?.call(done, total);
          }
        }));
      }
    }

    failures.sort((a, b) => a.rowNumber.compareTo(b.rowNumber));
    return ImportResult(
      studentsAdded: added,
      classesCreated: classesCreated,
      failures: failures,
    );
  }
}

// =============================================================
// Input validation (manual add + email)
// =============================================================

class StudentValidation {
  static final _emailRe = RegExp(
    r'^[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(\.[A-Za-z0-9\-]+)*\.[A-Za-z]{2,}$',
  );

  static bool isValidEmail(String v) => _emailRe.hasMatch(v.trim());

  /// Returns an error message, or null when the email is acceptable.
  static String? email(String raw, {bool required = false}) {
    final v = raw.trim();
    if (v.isEmpty) return required ? 'Email is required.' : null;
    return isValidEmail(v) ? null : 'Enter a valid email address.';
  }

  /// Digits only, 6–15 long, not one repeated digit.
  static String? studentNumber(String raw) {
    final v = raw.trim();
    if (v.isEmpty) return 'Student number is required.';
    if (!RegExp(r'^\d+$').hasMatch(v)) return 'Use numbers only.';
    if (v.length < 6 || v.length > 15) {
      return 'Student number must be 6 to 15 digits.';
    }
    if (RegExp(r'^(\d)\1+$').hasMatch(v)) {
      return 'Enter a valid student number.';
    }
    return null;
  }

  static final _keyboardRuns = _buildKeyboardRuns();

  static Set<String> _buildKeyboardRuns() {
    final runs = <String>{};
    for (final row in const ['qwertyuiop', 'asdfghjkl', 'zxcvbnm']) {
      for (var i = 0; i + 5 <= row.length; i++) {
        runs.add(row.substring(i, i + 5));
      }
    }
    return runs;
  }

  /// Rejects empty values, symbols/numbers, and random-looking text
  /// (no vowels, long consonant runs, repeated characters, keyboard mashing).
  static String? name(
    String raw, {
    required String label,
    bool required = true,
  }) {
    final v = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (v.isEmpty) return required ? '$label is required.' : null;

    if (!RegExp(r"^[\p{L}][\p{L} .'’\-]*$", unicode: true).hasMatch(v)) {
      return 'Use letters only.';
    }

    final invalid = 'Enter a valid ${label.toLowerCase()}.';
    var totalLetters = 0;

    for (final token in v.split(RegExp(r"[ \-]"))) {
      final letters = token
          .replaceAll(RegExp(r"[^\p{L}]", unicode: true), '')
          .toLowerCase();
      if (letters.isEmpty) continue;
      totalLetters += letters.length;
      if (letters.length < 3) continue; // e.g. "Ng", "De", "Jo"

      if (!RegExp(r'[aeiouy]').hasMatch(letters)) return invalid;
      if (RegExp(r'(.)\1\1').hasMatch(letters)) return invalid;
      if (RegExp(r'[^aeiouy]{6,}').hasMatch(letters)) return invalid;
      if (letters.length >= 5 && letters.split('').toSet().length <= 2) {
        return invalid;
      }
      if (letters.length >= 6 && RegExp(r'^(.{2,3})\1+$').hasMatch(letters)) {
        return invalid;
      }
      for (var i = 0; i + 5 <= letters.length; i++) {
        if (_keyboardRuns.contains(letters.substring(i, i + 5))) {
          return invalid;
        }
      }
    }

    if (totalLetters < 2) return invalid;
    return null;
  }
}
