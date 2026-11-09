import 'dart:async';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../services/academic_api_service.dart';
import '../services/api_service.dart';
import '../services/auth_storage.dart';
import '../services/student_import_service.dart';
import 'login_screen.dart' show CmColors;

enum _Stage { pick, reading, review, importing, done }

/// Muted green for success states (not neon).
const Color _ok = Color(0xFF2F8F72);

/// Step-by-step Excel import:
/// 1 Choose file -> 2 Review -> 3 Import -> 4 Done.
///
/// Returns `true` from Navigator.pop when data changed, so the caller
/// can refresh.
class ImportStudentsScreen extends StatefulWidget {
  const ImportStudentsScreen({
    super.key,
    this.isTeacher = false,
    this.assignedSections,
    this.populatedSections,
    this.initialSection,
    this.initialClass,
    this.sectionClasses,
  });

  /// Only administrators can create or assign classes and subjects.
  /// Students are imported strictly into existing classes assigned to the teacher.
  final bool isTeacher;

  /// Section names assigned to the logged-in teacher. When given, a file is
  /// rejected if any row belongs to a section outside this list.
  final List<String>? assignedSections;

  /// Optional list of section names that are fully populated.
  final List<String>? populatedSections;

  /// Section the import was opened from (an empty section's button), shown
  /// on the first step.
  final String? initialSection;

  /// That section's class, when it has one preselected: its subject, school year
  /// and semester are preselected in the first and review steps.
  final Map<String, dynamic>? initialClass;

  /// All classes assigned to the logged-in teacher for [initialSection].
  final List<Map<String, dynamic>>? sectionClasses;

  @override
  State<ImportStudentsScreen> createState() => _ImportStudentsScreenState();
}

class _ImportStudentsScreenState extends State<ImportStudentsScreen> {
  _Stage _stage = _Stage.pick;

  String? _fileName;
  ParsedStudentFile? _parsed;

  // File-level error
  String? _errorTitle;
  String? _errorMessage;
  List<String> _missingColumns = [];

  // Classes & subjects handled by the logged-in teacher for the selected section
  List<Map<String, dynamic>> _handledClasses = [];
  List<Map<String, dynamic>> _subjects = [];
  Map<String, dynamic>? _selectedSubject;
  int? _subjectId;
  int _subjectRequest = 0;
  bool _loadingSubjects = true;
  static const _semesters = ['1st Semester', '2nd Semester'];
  String _schoolYear = AcademicOptions.currentSchoolYear();
  String _semester = _semesters.first;
  String? _lookupError;

  // Details read from the Excel file
  bool _matchingSubject = false;
  String? _subjectNotFound;

  bool _checking = false;
  int _done = 0;
  int _total = 0;
  int _classCount = 0;
  ImportResult? _result;

  @override
  void initState() {
    super.initState();
    _initFromWidget();
    _loadLookups();
  }

  static int? _intOf(Object? value) =>
      int.tryParse(value?.toString().trim() ?? '');

  static String _textOf(Object? value) => value?.toString().trim() ?? '';

  static String _sectionKey(String name) =>
      name.toUpperCase().replaceAll(RegExp(r'[\s-]+'), '');

  static String _normText(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  /// "1", "1st", "1st Semester", "First Semester", "Semester 1" -> "1st Semester".
  static String? _semesterLabel(Object? value) {
    final text = value?.toString().trim().toLowerCase() ?? '';
    if (text.isEmpty) return null;
    if (text.startsWith('1') ||
        text.startsWith('first') ||
        text.contains('1st') ||
        text.endsWith(' 1')) {
      return _semesters[0];
    }
    if (text.startsWith('2') ||
        text.startsWith('second') ||
        text.contains('2nd') ||
        text.endsWith(' 2')) {
      return _semesters[1];
    }
    return null;
  }

  /// True when [a] and [b] refer to the same section (including short-form
  /// names like BSIT3B for BSIT31B in the matching semester).
  bool _isSameSection(String a, String b, {String? semester}) {
    final ka = _sectionKey(a);
    final kb = _sectionKey(b);
    if (ka.isEmpty || kb.isEmpty) return false;
    if (ka == kb) return true;

    final term = (semester ?? _semester).startsWith('2') ? '2' : '1';
    final short = RegExp(r'^([A-Z]+)(\d)([A-Z]+)$');
    final ma = short.firstMatch(ka);
    if (ma != null && '${ma[1]}${ma[2]}$term${ma[3]}' == kb) {
      return true;
    }
    final mb = short.firstMatch(kb);
    if (mb != null && '${mb[1]}${mb[2]}$term${mb[3]}' == ka) {
      return true;
    }
    return false;
  }

  /// Builds a normalized subject entry from a class's embedded `subject` map.
  Map<String, dynamic>? _subjectFromClass(Map<String, dynamic> c) {
    final raw = c['subject'];
    if (raw is! Map) return null;
    final sub = Map<String, dynamic>.from(raw);
    final acadId = _intOf(sub['academic_subject_id']);
    final legacyId = _intOf(sub['id'] ?? c['subject_id']);
    final effectiveId = acadId ?? legacyId;
    if (effectiveId == null) return null;
    return <String, dynamic>{
      ...sub,
      'id': effectiveId,
      'academic_subject_id': acadId,
      'legacy_subject_id': legacyId,
      'code': _textOf(sub['code']),
      'name': _textOf(sub['name']),
      if (sub['placements'] is List) 'placements': sub['placements'],
      'school_year': _textOf(c['school_year']),
      'semester': _textOf(c['semester']),
    };
  }

  void _initFromWidget() {
    final classes = <Map<String, dynamic>>[
      if (widget.sectionClasses != null) ...widget.sectionClasses!,
      if (widget.initialClass != null &&
          (widget.sectionClasses == null || widget.sectionClasses!.isEmpty))
        widget.initialClass!,
    ];
    _handledClasses = classes;

    final seedSubjects = <Map<String, dynamic>>[];
    final seenIds = <int>{};
    for (final c in classes) {
      final s = _subjectFromClass(c);
      if (s == null) continue;
      final id = _subjectIdOf(s);
      if (id != null && seenIds.add(id)) {
        seedSubjects.add(s);
      }
    }
    _subjects = seedSubjects;

    final c =
        widget.initialClass ?? (classes.isNotEmpty ? classes.first : null);
    if (c != null) {
      final schoolYear = _textOf(c['school_year']);
      if (schoolYear.isNotEmpty) _schoolYear = schoolYear;

      final semLabel = _semesterLabel(c['semester']);
      if (semLabel != null) _semester = semLabel;

      final sub = _subjectFromClass(c);
      if (sub != null) {
        _applySelectedSubject(sub);
      }
    }
  }

  void _applySelectedSubject(Map<String, dynamic> subject) {
    final id = _subjectIdOf(subject);
    _selectedSubject = subject;
    _subjectId = id;

    // Match the teacher's class for this section + subject to get school year
    // and fallback semester.
    final matchingClass = _findHandledClassForSubject(subject);
    if (matchingClass != null) {
      final sy = _textOf(matchingClass['school_year']);
      if (sy.isNotEmpty) _schoolYear = sy;
    } else {
      final sy = _textOf(subject['school_year']);
      if (sy.isNotEmpty) _schoolYear = sy;
    }

    // Semester comes from the subject's placement in 003_academic_module
    // (or the assigned class's semester when curriculum placements span both).
    final targetSec =
        widget.initialSection ?? _textOf(matchingClass?['section']);
    final semFromCatalog = _subjectSemester(subject, section: targetSec);
    final semFromClass = _semesterLabel(
      matchingClass?['semester'] ?? subject['semester'],
    );
    if (semFromCatalog != null) {
      _semester = semFromCatalog;
    } else if (semFromClass != null) {
      _semester = semFromClass;
    }
  }

  Map<String, dynamic>? _findHandledClassForSubject(
    Map<String, dynamic> subject,
  ) {
    for (final c in _handledClasses) {
      if (_subjectMatchesClass(subject, c)) return c;
    }
    return widget.initialClass;
  }

  static bool _subjectMatchesClass(
    Map<String, dynamic> subject,
    Map<String, dynamic> classItem,
  ) {
    final raw = classItem['subject'];
    if (raw is! Map) return false;
    final classAcadId = _intOf(raw['academic_subject_id']);
    final subAcadId = _intOf(subject['academic_subject_id'] ?? subject['id']);
    if (classAcadId != null && subAcadId != null && classAcadId == subAcadId) {
      return true;
    }

    final classLegacyId = _intOf(raw['id'] ?? classItem['subject_id']);
    final subLegacyId = _intOf(
      subject['legacy_subject_id'] ?? subject['subject_id'] ?? subject['id'],
    );
    if (classLegacyId != null &&
        subLegacyId != null &&
        classLegacyId == subLegacyId) {
      return true;
    }

    final cCode = _normText(_textOf(raw['code']));
    final sCode = _normText(_textOf(subject['code']));
    if (cCode.isNotEmpty && sCode.isNotEmpty && cCode == sCode) {
      return true;
    }

    final cName = _normText(_textOf(raw['name']));
    final sName = _normText(_textOf(subject['name']));
    return cName.isNotEmpty && cName == sName;
  }

  static bool _subjectsMatch(Map<String, dynamic> a, Map<String, dynamic> b) {
    final aAcad = _intOf(a['academic_subject_id'] ?? a['id']);
    final bAcad = _intOf(b['academic_subject_id'] ?? b['id']);
    if (aAcad != null && bAcad != null && aAcad == bAcad) return true;

    final aCode = _normText(_textOf(a['code']));
    final bCode = _normText(_textOf(b['code']));
    if (aCode.isNotEmpty && bCode.isNotEmpty && aCode == bCode) return true;

    final aName = _normText(_textOf(a['name']));
    final bName = _normText(_textOf(b['name']));
    return aName.isNotEmpty && aName == bName;
  }

  /// Checks whether [rawSubjectText] (from an Excel file) matches [subject].
  static bool _textMatchesSubject(
    String rawSubjectText,
    Map<String, dynamic> subject, {
    Map<String, dynamic>? classItem,
  }) {
    final key = _normText(rawSubjectText);
    if (key.isEmpty) return false;

    final name = _normText(_textOf(subject['name']));
    final code = _normText(_textOf(subject['code']));
    final label = _normText(_catalogLabel(subject));
    if (key == name || key == label || (code.isNotEmpty && key == code)) {
      return true;
    }

    if (classItem != null && classItem['subject'] is Map) {
      final cs = classItem['subject'] as Map;
      final cName = _normText(_textOf(cs['name']));
      final cCode = _normText(_textOf(cs['code']));
      if (key == cName || (cCode.isNotEmpty && key == cCode)) {
        return true;
      }
      if (cCode.isNotEmpty && cName.isNotEmpty && key == '$cCode$cName') {
        return true;
      }
    }
    return false;
  }

  /// Finds the teacher's handled subject matching [rawSubjectText], or null.
  Map<String, dynamic>? _findMatchingHandledSubject(String rawSubjectText) {
    for (final s in _subjectOptions) {
      final cls = _findHandledClassForSubject(s);
      if (_textMatchesSubject(rawSubjectText, s, classItem: cls)) {
        return s;
      }
    }
    return null;
  }

  /// Semester of a subject according to the Academic Management curricula.
  /// [section] (e.g. BSIT31A) narrows it to the right program and year level.
  static String? _subjectSemester(
    Map<String, dynamic> subject, {
    String? section,
  }) {
    final raw = subject['placements'];
    var places = raw is List
        ? raw.whereType<Map>().map((p) => Map<String, dynamic>.from(p)).toList()
        : <Map<String, dynamic>>[];

    if (places.isNotEmpty && section != null && section.trim().isNotEmpty) {
      final key = _sectionKey(section);
      final byProgram = places
          .where(
            (p) =>
                key.startsWith((p['program'] ?? '').toString().toUpperCase()),
          )
          .toList();
      if (byProgram.isNotEmpty) {
        places = byProgram;
        final longest = places
            .map((p) => (p['program'] ?? '').toString().length)
            .reduce((x, y) => x > y ? x : y);
        final rest = key.substring(longest);
        final year = rest.isEmpty ? null : int.tryParse(rest[0]);
        if (year != null) {
          final byYear = places
              .where((p) => int.tryParse('${p['year_level']}') == year)
              .toList();
          if (byYear.isNotEmpty) places = byYear;
        }
      }
    }

    final terms = <int>{
      for (final p in places)
        if (int.tryParse('${p['term']}') != null) int.parse('${p['term']}'),
    };
    if (terms.length == 1 && (terms.first == 1 || terms.first == 2)) {
      return _semesters[terms.first - 1];
    }
    return _semesterLabel(subject['semester'] ?? subject['term']);
  }

  /// Resolves short-form section names (e.g. "BSIT3B" -> "BSIT31B") when they
  /// belong to the teacher's allowed sections.
  ParsedStudentFile _resolveSections(ParsedStudentFile parsed) {
    final allowed = <String>{
      if (widget.initialSection != null &&
          widget.initialSection!.trim().isNotEmpty)
        widget.initialSection!.trim(),
      if (widget.assignedSections != null) ...widget.assignedSections!,
    }.toList();
    if (allowed.isEmpty) return parsed;

    final byKey = {for (final a in allowed) _sectionKey(a): a};
    final term = _semester.startsWith('2') ? '2' : '1';
    final short = RegExp(r'^([A-Z]+)(\d)([A-Z]+)$');

    String resolve(String name) {
      final key = _sectionKey(name);
      if (byKey.containsKey(key)) return byKey[key]!;
      final m = short.firstMatch(key);
      if (m != null) {
        final full = '${m[1]}${m[2]}$term${m[3]}';
        if (byKey.containsKey(full)) return byKey[full]!;
      }
      return name;
    }

    final resolvedFileSection = parsed.fileSection == null
        ? null
        : resolve(parsed.fileSection!);

    return ParsedStudentFile(
      [
        for (final r in parsed.rows)
          ImportRow(
            rowNumber: r.rowNumber,
            studentNumber: r.studentNumber,
            name: r.name,
            section: resolve(r.section),
            firstName: r.firstName,
            lastName: r.lastName,
            subject: r.subject,
            email: r.email,
          ),
      ],
      parsed.issues,
      subject: parsed.subject,
      fileSection: resolvedFileSection,
    );
  }

  @override
  void dispose() {
    _subjectRequest++;
    super.dispose();
  }

  static int? _subjectIdOf(Map<String, dynamic> subject) =>
      int.tryParse(subject['id']?.toString() ?? '');

  static String _catalogLabel(Map<String, dynamic> subject) {
    final code = subject['code']?.toString().trim() ?? '';
    final name = subject['name']?.toString().trim() ?? 'Unnamed Subject';
    return code.isEmpty ? name : '$code - $name';
  }

  /// Section shown in the Step 1 highlighted preview box.
  String get _previewSectionName {
    final sec = widget.initialSection?.trim() ?? '';
    if (sec.isNotEmpty) return sec;
    if (_handledClasses.isNotEmpty) {
      final fromClass = _textOf(_handledClasses.first['section']);
      if (fromClass.isNotEmpty) return fromClass;
    }
    return 'Section';
  }

  /// Full subject name shown in the Step 1 highlighted preview box.
  String get _previewSubjectName {
    final selectedName = _textOf(_selectedSubject?['name']);
    if (selectedName.isNotEmpty) return selectedName;
    if (_subjects.isNotEmpty) {
      final firstName = _textOf(_subjects.first['name']);
      if (firstName.isNotEmpty) return firstName;
    }
    final initialSub = widget.initialClass?['subject'];
    if (initialSub is Map) {
      final name = _textOf(initialSub['name']);
      if (name.isNotEmpty) return name;
    }
    return 'Subject';
  }

  List<Map<String, dynamic>> get _subjectOptions {
    final byId = <int, Map<String, dynamic>>{};
    for (final subject in _subjects) {
      final id = _subjectIdOf(subject);
      if (id != null) byId[id] = subject;
    }
    final selected = _selectedSubject;
    if (selected != null && _subjectId != null) {
      byId.putIfAbsent(_subjectId!, () => selected);
    }
    return byId.values.toList()
      ..sort((a, b) => _catalogLabel(a).compareTo(_catalogLabel(b)));
  }

  /// Loads the Academic Management (`003_academic_module`) subject records
  /// strictly for the subject(s) handled by the logged-in teacher in the
  /// selected section.
  Future<void> _loadLookups() async {
    final request = ++_subjectRequest;
    setState(() {
      _loadingSubjects = true;
      _lookupError = null;
    });
    try {
      final token = await AuthStorage.getToken();
      if (token == null || token.isEmpty) {
        throw Exception('Authentication token not found.');
      }

      var classes = _handledClasses;
      if (classes.isEmpty) {
        final allClasses = await ApiService.getClasses(token);
        if (widget.initialSection != null &&
            widget.initialSection!.trim().isNotEmpty) {
          classes = allClasses
              .where(
                (c) => _isSameSection(
                  _textOf(c['section']),
                  widget.initialSection!,
                  semester: _textOf(c['semester']),
                ),
              )
              .toList();
        } else {
          classes = allClasses;
        }
      }

      final resolvedSubjects = <Map<String, dynamic>>[];
      for (final c in classes) {
        final fallback = _subjectFromClass(c);
        if (fallback == null) continue;

        Map<String, dynamic>? matchedCatalog;
        final code = _textOf(fallback['code']);
        final name = _textOf(fallback['name']);
        final searchTerm = code.isNotEmpty ? code : name;

        if (searchTerm.isNotEmpty) {
          try {
            final results = await AcademicApi.searchCatalog(token, searchTerm);
            for (final candidate in results) {
              if (_subjectsMatch(candidate, fallback)) {
                matchedCatalog = {
                  ...fallback,
                  ...candidate,
                  'id': _intOf(candidate['id']) ?? fallback['id'],
                  'academic_subject_id':
                      _intOf(candidate['id']) ??
                      fallback['academic_subject_id'],
                  'legacy_subject_id': fallback['legacy_subject_id'],
                };
                break;
              }
            }
          } catch (_) {
            // Keep fallback subject from class when catalog search is unavailable.
          }
        }

        final chosen = matchedCatalog ?? fallback;
        final id = _subjectIdOf(chosen);
        if (id != null &&
            !resolvedSubjects.any((existing) => _subjectIdOf(existing) == id)) {
          resolvedSubjects.add(chosen);
        }
      }

      if (!mounted || request != _subjectRequest) return;
      setState(() {
        _handledClasses = classes;
        if (resolvedSubjects.isNotEmpty) {
          _subjects = resolvedSubjects;
          final current = _selectedSubject;
          Map<String, dynamic>? updatedSelection;
          if (current != null) {
            for (final s in resolvedSubjects) {
              if (_subjectsMatch(s, current)) {
                updatedSelection = s;
                break;
              }
            }
          }
          _applySelectedSubject(updatedSelection ?? resolvedSubjects.first);
        }
        _loadingSubjects = false;
      });
    } catch (e) {
      if (!mounted || request != _subjectRequest) return;
      setState(() {
        _loadingSubjects = false;
        _lookupError = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  // ---------- Step 1: choose + validate ----------

  Future<void> _pickFile() async {
    try {
      const xlsxType = XTypeGroup(
        label: 'Excel',
        extensions: ['xlsx'],
        mimeTypes: [
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        ],
        uniformTypeIdentifiers: ['org.openxmlformats.spreadsheetml.sheet'],
      );
      final file = await openFile(acceptedTypeGroups: [xlsxType]);
      if (file == null) return;

      final bytes = await file.readAsBytes();
      final fileName = file.name;

      setState(() {
        _stage = _Stage.reading;
        _fileName = fileName;
        _errorTitle = null;
        _errorMessage = null;
        _missingColumns = [];
      });

      // Let the spinner paint before parsing and validating.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Keep the original section names until the file's subject determines
      // which semester-specific section should be selected.
      final rawParsed = StudentImportService.parse(bytes, fileName);
      final targetSection = widget.initialSection?.trim() ?? '';

      // 1. Validate that the subject in the file matches the specific subject
      //    handled by the logged-in teacher for the selected section.
      final fileSubjects = <String>{
        if (rawParsed.subject != null && rawParsed.subject!.trim().isNotEmpty)
          rawParsed.subject!.trim(),
        for (final r in rawParsed.rows)
          if (r.subject != null && r.subject!.trim().isNotEmpty)
            r.subject!.trim(),
      };

      if (_subjectOptions.isEmpty && _loadingSubjects) {
        await _loadLookups();
      }

      final expectedNames = _subjectOptions
          .map((s) => _textOf(s['name']))
          .where((n) => n.isNotEmpty)
          .toList();
      final expectedDisplay = expectedNames.isEmpty
          ? _previewSubjectName
          : expectedNames.join(' / ');

      if (fileSubjects.isEmpty) {
        throw ImportFileException(
          'The uploaded file does not specify the subject for section '
          '${targetSection.isEmpty ? _previewSectionName : targetSection} '
          '($expectedDisplay).',
        );
      }

      Map<String, dynamic>? matchedHandledSubject;
      for (final subText in fileSubjects) {
        final match = _findMatchingHandledSubject(subText);
        if (match == null) {
          throw ImportFileException(
            'The student list in this file is for subject "$subText", which '
            'does not match the subject you handle for section '
            '${targetSection.isEmpty ? _previewSectionName : targetSection} '
            '($expectedDisplay).',
          );
        }
        if (matchedHandledSubject != null &&
            !_subjectsMatch(matchedHandledSubject, match)) {
          throw ImportFileException(
            'The uploaded file mixes multiple subjects '
            '(${fileSubjects.join(', ')}). Upload one file per subject.',
          );
        }
        matchedHandledSubject = match;
      }

      // Apply the matched subject before resolving short section names such
      // as BSIT3A, so the correct semester (BSIT31A or BSIT32A) is used.
      if (matchedHandledSubject != null) {
        _applySelectedSubject(matchedHandledSubject);
      }
      final parsed = _resolveSections(rawParsed);

      // 2. Validate that all rows and the file section match the selected section.
      if (targetSection.isNotEmpty) {
        final wrongSections = <String>{};
        if (parsed.fileSection != null &&
            parsed.fileSection!.trim().isNotEmpty &&
            !_isSameSection(parsed.fileSection!, targetSection)) {
          wrongSections.add(parsed.fileSection!.trim());
        }
        for (final r in parsed.rows) {
          if (!_isSameSection(r.section, targetSection)) {
            wrongSections.add(r.section);
          }
        }
        if (wrongSections.isNotEmpty) {
          throw ImportFileException(
            'The student list in this file belongs to section '
            '${wrongSections.join(', ')}, not the selected section '
            '$targetSection. Please upload the student list for '
            '$targetSection.',
          );
        }
      }

      // 3. Validate that the students in the file have NOT already been
      //    uploaded on a DIFFERENT section (same list of students on the SAME
      //    section for a DIFFERENT subject is allowed).
      final token = await AuthStorage.getToken();
      if (token == null || token.isEmpty) {
        throw Exception('Authentication token not found.');
      }

      final checkSection = targetSection.isNotEmpty
          ? targetSection
          : _previewSectionName;
      final otherSectionStudents = await ApiService.getStudents(
        token,
        excludeSection: checkSection,
      );

      final numberToOtherSections = <String, Set<String>>{};
      for (final s in otherSectionStudents) {
        final numKey = _textOf(s['student_number']).toLowerCase();
        final secName = _textOf(
          (s['class'] is Map ? (s['class'] as Map)['section'] : null) ??
              s['section'],
        );
        if (numKey.isEmpty || secName.isEmpty) continue;
        if (_isSameSection(secName, checkSection)) continue;
        numberToOtherSections
            .putIfAbsent(numKey, () => <String>{})
            .add(secName);
      }

      final conflictingSections = <String>{};
      var conflictingStudentCount = 0;
      for (final r in parsed.rows) {
        final numKey = r.studentNumber.trim().toLowerCase();
        final others = numberToOtherSections[numKey];
        if (others != null && others.isNotEmpty) {
          conflictingStudentCount++;
          conflictingSections.addAll(others);
        }
      }

      if (conflictingStudentCount > 0) {
        throw ImportFileException(
          'This student list has already been uploaded to a different section '
          '(${conflictingSections.join(', ')}). You cannot upload the same '
          'list of students to $checkSection.',
        );
      }

      if (!mounted) return;
      setState(() {
        // Preserve raw section names so changing the subject on the review
        // screen can resolve them again for the newly selected semester.
        _parsed = rawParsed;
        _matchingSubject = false;
        _subjectNotFound = null;
        _stage = _Stage.review;
      });
    } on ImportFileException catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.pick;
        _errorTitle = 'Unable to import students.';
        _errorMessage = e.missingColumns.isEmpty
            ? e.message
            : 'The following required '
                  '${e.missingColumns.length == 1 ? 'column is' : 'columns are'} '
                  'missing:';
        _missingColumns = e.missingColumns;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.pick;
        _errorTitle = 'Unable to import students.';
        _errorMessage = e.toString().replaceFirst('Exception: ', '');
        _missingColumns = [];
      });
    }
  }

  Future<void> _downloadTemplate() async {
    final section = _previewSectionName;
    final subjectName = _previewSubjectName;
    final fileName = StudentImportService.templateFileName(
      section: section,
      subject: subjectName,
    );
    const mime =
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';

    try {
      final bytes = StudentImportService.buildTemplate(
        section: section,
        subject: subjectName,
        sections: [section],
      );
      final file = XFile.fromData(
        Uint8List.fromList(bytes),
        name: fileName,
        mimeType: mime,
      );

      final isDesktop =
          defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.linux;

      if (kIsWeb) {
        await file.saveTo(fileName);
        _snack('Template downloaded.');
      } else if (isDesktop) {
        final location = await getSaveLocation(
          suggestedName: fileName,
          acceptedTypeGroups: const [
            XTypeGroup(label: 'Excel', extensions: ['xlsx']),
          ],
        );
        if (location == null) return;
        await file.saveTo(location.path);
        _snack('Template saved.');
      } else {
        await SharePlus.instance.share(
          ShareParams(
            files: [file],
            subject: 'CheckMate student import template',
          ),
        );
      }
    } catch (e) {
      _snack(
        'Could not create the template: '
        '${e.toString().replaceFirst('Exception: ', '')}',
      );
    }
  }

  // ---------- Step 2/3: confirm + import ----------

  Future<void> _startImport() async {
    if (_parsed == null) return;
    final parsed = _resolveSections(_parsed!);

    if (_subjectId == null || _selectedSubject == null) {
      _snack('Please select a subject.');
      return;
    }

    final targetSection = widget.initialSection?.trim() ?? '';
    if (targetSection.isNotEmpty) {
      final wrongSections = parsed.bySection.keys
          .where((sec) => !_isSameSection(sec, targetSection))
          .toList();
      if (wrongSections.isNotEmpty) {
        _snack(
          'The student list must belong to section $targetSection '
          '(found ${wrongSections.join(', ')}).',
        );
        return;
      }
    }

    setState(() => _checking = true);

    try {
      final token = await AuthStorage.getToken();
      if (token == null || token.isEmpty) {
        throw Exception('Authentication token not found.');
      }

      // Re-verify no student is enrolled in a different section before writing.
      final checkSection = targetSection.isNotEmpty
          ? targetSection
          : _previewSectionName;
      final otherSectionStudents = await ApiService.getStudents(
        token,
        excludeSection: checkSection,
      );
      final numberToOtherSections = <String, Set<String>>{};
      for (final s in otherSectionStudents) {
        final numKey = _textOf(s['student_number']).toLowerCase();
        final secName = _textOf(
          (s['class'] is Map ? (s['class'] as Map)['section'] : null) ??
              s['section'],
        );
        if (numKey.isEmpty || secName.isEmpty) continue;
        if (_isSameSection(secName, checkSection)) continue;
        numberToOtherSections
            .putIfAbsent(numKey, () => <String>{})
            .add(secName);
      }

      final conflictingSections = <String>{};
      for (final r in parsed.rows) {
        final others =
            numberToOtherSections[r.studentNumber.trim().toLowerCase()];
        if (others != null && others.isNotEmpty) {
          conflictingSections.addAll(others);
        }
      }

      if (conflictingSections.isNotEmpty) {
        if (!mounted) return;
        setState(() => _checking = false);
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            shape: _dialogShape,
            title: const Text('Students already in another section'),
            content: Text(
              'This student list has already been uploaded to section '
              '${conflictingSections.join(', ')}. You cannot upload the same '
              'list of students to $checkSection.',
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(ctx),
                style: FilledButton.styleFrom(backgroundColor: CmColors.navy),
                child: const Text('OK'),
              ),
            ],
          ),
        );
        return;
      }

      final plan = await StudentImportService.buildPlan(
        token: token,
        parsed: parsed,
        subject: _selectedSubject!,
        schoolYear: _schoolYear,
        semester: _semester,
      );

      if (!mounted) return;
      setState(() => _checking = false);

      // Only an administrator can create a class, so students can only be
      // imported into a class that already exists. Check every section
      // before writing any students.
      if (plan.sections.any(
        (s) => s.toAdd.isNotEmpty && s.existingClassId == null,
      )) {
        final missing = plan.sections
            .where((s) => s.toAdd.isNotEmpty && s.existingClassId == null)
            .map((s) => s.section)
            .join(', ');
        _snack(
          'No class found for $missing with this subject, '
          '$_schoolYear, $_semester. Ask an administrator to assign it to you.',
        );
        return;
      }

      // Duplicates already in the same class (same section + same subject).
      final dupes = plan.duplicates;
      if (dupes.isNotEmpty) {
        final skip = await _showDuplicatesDialog(dupes);
        if (skip != true) return;
      }
      if (!mounted) return;

      if (plan.nothingToDo) {
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            shape: _dialogShape,
            title: const Text('Nothing to import'),
            content: const Text(
              'All students in this file already exist in the selected class.',
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('OK'),
              ),
            ],
          ),
        );
        return;
      }

      final ok = await _showConfirmDialog(plan);
      if (ok != true || !mounted) return;

      setState(() {
        _stage = _Stage.importing;
        _done = 0;
        _total = plan.studentsToAdd;
        _classCount = plan.sections.where((s) => s.toAdd.isNotEmpty).length;
      });

      final result = await StudentImportService.execute(
        token: token,
        plan: plan,
        subjectId: _subjectId!,
        subject: _selectedSubject!,
        schoolYear: _schoolYear,
        semester: _semester,
        teacherId: null,
        onProgress: (done, total) {
          if (!mounted) return;
          setState(() {
            _done = done;
            _total = total;
          });
        },
      );

      if (!mounted) return;
      setState(() {
        _result = result;
        _stage = _Stage.done;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _checking = false;
        if (_stage == _Stage.importing) _stage = _Stage.review;
      });
      _snack(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  RoundedRectangleBorder get _dialogShape =>
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(20));

  Future<bool?> _showDuplicatesDialog(List<ImportRow> dupes) {
    final preview = dupes.take(5).toList();
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: _dialogShape,
        title: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: CmColors.amber),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '${dupes.length} student${dupes.length == 1 ? '' : 's'} '
                'already exist${dupes.length == 1 ? 's' : ''}.',
                style: const TextStyle(fontSize: 18),
              ),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'These students are already enrolled in the selected class. '
                'They will not be imported again.',
              ),
              const SizedBox(height: 12),
              for (final r in preview)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    '• ${r.name} (${r.studentNumber}) — ${r.section}',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              if (dupes.length > preview.length)
                Text(
                  '…and ${dupes.length - preview.length} more',
                  style: const TextStyle(fontSize: 13, color: CmColors.slate),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: CmColors.navy),
            child: const Text('Skip Existing'),
          ),
        ],
      ),
    );
  }

  Future<bool?> _showConfirmDialog(ImportPlan plan) {
    final subjectName = _subjectLabel(_subjectId);
    final skippedRows = _parsed?.issues.length ?? 0;

    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: _dialogShape,
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        title: const Text(
          'Confirm import',
          style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'This will add ${plan.studentsToAdd} '
                  'student${plan.studentsToAdd == 1 ? '' : 's'}.',
                  style: const TextStyle(color: CmColors.slate),
                ),
                const SizedBox(height: 12),
                for (final s in plan.sections.where((s) => s.toAdd.isNotEmpty))
                  Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: CmColors.line),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(
                          Icons.menu_book_outlined,
                          size: 18,
                          color: CmColors.slate,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '$subjectName — ${s.section}',
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: CmColors.navy,
                                ),
                              ),
                              Text(
                                '${s.toAdd.length} student'
                                '${s.toAdd.length == 1 ? '' : 's'}',
                                style: const TextStyle(
                                  fontSize: 13,
                                  color: CmColors.slate,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                Center(
                  child: Text(
                    '$_semester • $_schoolYear',
                    style: const TextStyle(fontSize: 13, color: CmColors.slate),
                  ),
                ),
                if (skippedRows > 0) ...[
                  const SizedBox(height: 10),
                  Text(
                    '$skippedRows row${skippedRows == 1 ? '' : 's'} with '
                    'problems will be skipped.',
                    style: const TextStyle(fontSize: 13, color: CmColors.amber),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            style: TextButton.styleFrom(foregroundColor: CmColors.navy),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: CmColors.navy,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
  }

  // ---------- Helpers ----------

  String _subjectLabel(int? id) {
    for (final subject in _subjectOptions) {
      if (_subjectIdOf(subject) == id) return _catalogLabel(subject);
    }
    if (_selectedSubject != null) return _catalogLabel(_selectedSubject!);
    return 'Subject';
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _reset() {
    setState(() {
      _stage = _Stage.pick;
      _parsed = null;
      _fileName = null;
      _errorTitle = null;
      _errorMessage = null;
      _missingColumns = [];
      _matchingSubject = false;
      _subjectNotFound = null;
    });
  }

  bool get _busy =>
      _stage == _Stage.reading || _stage == _Stage.importing || _checking;

  // ---------- Build ----------

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _stage != _Stage.importing,
      child: Scaffold(
        backgroundColor: CmColors.bg,
        appBar: AppBar(
          title: const Text('Import Students'),
          automaticallyImplyLeading: _stage != _Stage.importing,
        ),
        bottomNavigationBar: _stage == _Stage.review ? _buildReviewBar() : null,
        body: SafeArea(
          child: Column(
            children: [
              _StepIndicator(
                current: _stepIndex,
                onBack: _stage == _Stage.importing || _busy
                    ? null
                    : () {
                        if (_stage == _Stage.review) {
                          _reset();
                        } else {
                          Navigator.maybePop(context);
                        }
                      },
              ),
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 740),
                    child: _buildStage(),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  int get _stepIndex {
    switch (_stage) {
      case _Stage.pick:
      case _Stage.reading:
        return 0;
      case _Stage.review:
        return 1;
      case _Stage.importing:
        return 2;
      case _Stage.done:
        return 3;
    }
  }

  Widget _buildStage() {
    switch (_stage) {
      case _Stage.pick:
        return _buildPick();
      case _Stage.reading:
        return _centered(
          const CircularProgressIndicator(),
          'Reading and validating ${_fileName ?? 'file'}…',
        );
      case _Stage.review:
        return _buildReview();
      case _Stage.importing:
        return _buildImporting();
      case _Stage.done:
        return _buildDone();
    }
  }

  Widget _centered(Widget top, String text) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            top,
            const SizedBox(height: 16),
            Text(text, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }

  // ----- Pick -----

  Widget _buildPick() {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        if (_errorTitle != null) ...[_errorCard(), const SizedBox(height: 16)],
        if (widget.initialSection != null) ...[
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: CmColors.line),
            ),
            child: Row(
              children: [
                const Icon(Icons.class_outlined, color: CmColors.slate),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Adding students to ${widget.initialSection}. Each '
                    'student goes to the section in the file’s Section '
                    'column, which must be assigned to you.',
                    style: const TextStyle(color: CmColors.slate, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],
        Card(
          elevation: 1,
          shadowColor: const Color(0x1A000000),
          color: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: const BorderSide(color: CmColors.line),
          ),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 58,
                    height: 58,
                    decoration: BoxDecoration(
                      color: CmColors.bg,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Icon(
                      Icons.upload_file_outlined,
                      size: 28,
                      color: CmColors.navy,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Upload a student list',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Use your current student list (containing student number, '
                  'full name with surname first, section, and subject) saved '
                  'as an .xlsx file named "Section and Full Subject Name"—or '
                  'simply use the provided Excel template.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: CmColors.slate),
                ),
                const SizedBox(height: 14),
                _formatPreview(),
                const SizedBox(height: 20),
                SizedBox(
                  height: 52,
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _pickFile,
                    style: FilledButton.styleFrom(
                      backgroundColor: CmColors.navy,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: const Icon(Icons.folder_open_outlined),
                    label: const Text(
                      'Choose Excel File',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  height: 52,
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _downloadTemplate,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: CmColors.navy,
                      side: const BorderSide(color: CmColors.line),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: const Icon(Icons.download_outlined),
                    label: const Text(
                      'Download Excel Template',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _formatPreview() {
    Widget cell(
      String t, {
      bool head = false,
      bool fill = false,
      int flex = 1,
    }) => Expanded(
      flex: flex,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
        decoration: BoxDecoration(
          color: head
              ? CmColors.navy
              : fill
              ? const Color(0xFFFEF9C3)
              : Colors.white,
          border: Border.all(color: CmColors.line),
        ),
        child: Text(
          t,
          style: TextStyle(
            fontSize: 12,
            fontWeight: head ? FontWeight.w700 : FontWeight.w400,
            color: head ? Colors.white : CmColors.navy,
          ),
        ),
      ),
    );

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Column(
        children: [
          Row(
            children: [
              cell('Section', head: true),
              cell(_previewSectionName, fill: true, flex: 3),
            ],
          ),
          Row(
            children: [
              cell('Subject', head: true),
              cell(_previewSubjectName, fill: true, flex: 3),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              cell('Student No.', head: true),
              cell('Name', head: true),
              cell('Email', head: true),
            ],
          ),
        ],
      ),
    );
  }

  Widget _errorCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF2F2),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFECACA)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.error_outline, color: Color(0xFFDC2626)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _errorTitle ?? 'Unable to import students.',
                  style: const TextStyle(
                    color: Color(0xFFDC2626),
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                  ),
                ),
              ),
            ],
          ),
          if (_errorMessage != null) ...[
            const SizedBox(height: 8),
            Text(
              _errorMessage!,
              style: const TextStyle(color: Color(0xFF7F1D1D)),
            ),
          ],
          for (final c in _missingColumns)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 4),
              child: Text(
                '• $c',
                style: const TextStyle(
                  color: Color(0xFF7F1D1D),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ----- Review -----

  Widget _buildReview() {
    // Re-resolve from the original Excel data whenever the selected subject
    // (and therefore semester) changes on the review screen.
    final parsed = _resolveSections(_parsed!);
    final sections = parsed.bySection;
    final issues = parsed.issues;

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Card(
          elevation: 1,
          shadowColor: const Color(0x1A000000),
          color: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: const BorderSide(color: CmColors.line),
          ),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.description_outlined,
                      color: CmColors.slate,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _fileName ?? '',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: CmColors.slate),
                      ),
                    ),
                    TextButton(
                      onPressed: _busy ? null : _reset,
                      child: const Text('Change'),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '${parsed.rows.length} student'
                  '${parsed.rows.length == 1 ? '' : 's'} found',
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: CmColors.navy,
                  ),
                ),
                Text(
                  '${sections.length} section'
                  '${sections.length == 1 ? '' : 's'} detected',
                  style: const TextStyle(color: CmColors.slate),
                ),
                const SizedBox(height: 10),
                _fileSubjectRow(parsed.subject),
                const SizedBox(height: 14),
                const Divider(height: 1, color: CmColors.line),
                const SizedBox(height: 10),
                for (final e in sections.entries)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.check_circle_outline,
                          color: _ok,
                          size: 20,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            e.key,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 15,
                            ),
                          ),
                        ),
                        Text(
                          '${e.value.length} student'
                          '${e.value.length == 1 ? '' : 's'}',
                          style: const TextStyle(color: CmColors.slate),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (issues.isNotEmpty) ...[
          const SizedBox(height: 12),
          _issuesCard(issues),
        ],
        const SizedBox(height: 12),
        _commonInfoCard(),
      ],
    );
  }

  /// What the sheet says its subject is, and whether it was matched.
  Widget _fileSubjectRow(String? fileSubject) {
    final String text;
    final IconData icon;
    final Color color;
    if (fileSubject == null) {
      final current = _selectedSubject;
      text = current == null
          ? 'No subject found in the file.'
          : 'Subject: ${_catalogLabel(current)}';
      icon = Icons.check_circle_outline;
      color = _ok;
    } else if (_matchingSubject) {
      text = 'Subject: $fileSubject (checking Academic Management…)';
      icon = Icons.hourglass_empty;
      color = CmColors.slate;
    } else if (_subjectNotFound != null) {
      text = 'Subject "$fileSubject" was not found in Academic Management.';
      icon = Icons.warning_amber_rounded;
      color = const Color(0xFF92400E);
    } else {
      final matched = _selectedSubject;
      text =
          'Subject: ${matched == null ? fileSubject : _catalogLabel(matched)}';
      icon = Icons.check_circle_outline;
      color = _ok;
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 14,
              color: color == CmColors.slate ? CmColors.slate : CmColors.navy,
            ),
          ),
        ),
      ],
    );
  }

  Widget _issuesCard(List<ImportIssue> issues) {
    final shown = issues.take(8).toList();
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFBEB),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFDE68A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.warning_amber_rounded, color: CmColors.amber),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${issues.length} row${issues.length == 1 ? '' : 's'} '
                  'will be skipped',
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF92400E),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final i in shown)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                'Row ${i.rowNumber}: ${i.message}',
                style: const TextStyle(fontSize: 13, color: Color(0xFF78350F)),
              ),
            ),
          if (issues.length > shown.length)
            Text(
              '…and ${issues.length - shown.length} more',
              style: const TextStyle(fontSize: 13, color: Color(0xFF78350F)),
            ),
          const SizedBox(height: 6),
          const Text(
            'Fix these rows in Excel and re-upload, or continue to import '
            'only the valid rows.',
            style: TextStyle(fontSize: 12, color: Color(0xFF92400E)),
          ),
        ],
      ),
    );
  }

  InputDecoration _dec(String label, IconData icon) => InputDecoration(
    labelText: label,
    prefixIcon: Icon(icon, color: CmColors.slate),
    filled: true,
    fillColor: CmColors.bg,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: CmColors.line),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: CmColors.line),
    ),
    disabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: CmColors.line),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: CmColors.navy, width: 1.5),
    ),
  );

  Widget _readOnlyField({
    required String label,
    required IconData icon,
    required String value,
  }) {
    return InputDecorator(
      decoration: _dec(label, icon),
      child: Text(
        value,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 16, color: CmColors.navy),
      ),
    );
  }

  Widget _commonInfoCard() {
    final options = _subjectOptions;

    return Card(
      elevation: 1,
      shadowColor: const Color(0x1A000000),
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: CmColors.line),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Applies to all imported students',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            const Text(
              'Review these details. They will apply to all imported students.',
              style: TextStyle(color: CmColors.slate, fontSize: 13),
            ),
            const SizedBox(height: 16),
            if (_lookupError != null) ...[
              Text(
                _lookupError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              const SizedBox(height: 12),
            ],
            if (_loadingSubjects) ...[
              const LinearProgressIndicator(color: CmColors.navy),
              const SizedBox(height: 12),
            ],
            if (options.length <= 1 && _selectedSubject != null)
              _readOnlyField(
                label: 'Subject',
                icon: Icons.menu_book_outlined,
                value: _catalogLabel(_selectedSubject!),
              )
            else
              DropdownButtonFormField<int>(
                key: ValueKey('subject-$_subjectId'),
                initialValue: _subjectId,
                isExpanded: true,
                decoration: _dec('Subject', Icons.menu_book_outlined),
                hint: Text(
                  _loadingSubjects
                      ? 'Loading subjects…'
                      : options.isEmpty
                      ? 'No assigned subjects found.'
                      : 'Select subject',
                ),
                items: options.map((subject) {
                  return DropdownMenuItem<int>(
                    value: _subjectIdOf(subject)!,
                    child: Text(
                      _catalogLabel(subject),
                      overflow: TextOverflow.ellipsis,
                    ),
                  );
                }).toList(),
                onChanged:
                    _busy ||
                        _loadingSubjects ||
                        _lookupError != null ||
                        options.length <= 1
                    ? null
                    : (value) => setState(() {
                        if (value == null) return;
                        final chosen = options.firstWhere(
                          (subject) => _subjectIdOf(subject) == value,
                        );
                        _applySelectedSubject(chosen);
                      }),
              ),
            if (_lookupError != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _busy || _loadingSubjects ? null : _loadLookups,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry loading subjects'),
                ),
              ),
            const SizedBox(height: 14),
            _readOnlyField(
              label: 'School Year',
              icon: Icons.calendar_today_outlined,
              value: _schoolYear,
            ),
            const SizedBox(height: 14),
            _readOnlyField(
              label: 'Semester',
              icon: Icons.calendar_month_outlined,
              value: _semester,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReviewBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: CmColors.line)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Expanded(
              child: SizedBox(
                height: 52,
                child: OutlinedButton(
                  onPressed: _busy ? null : () => Navigator.pop(context),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: CmColors.navy,
                    side: const BorderSide(color: CmColors.line),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text(
                    'Cancel',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: SizedBox(
                height: 52,
                child: FilledButton(
                  onPressed: _busy ? null : _startImport,
                  style: FilledButton.styleFrom(
                    backgroundColor: CmColors.navy,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: _checking
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text(
                          'Import Students',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ----- Importing -----

  Widget _buildImporting() {
    final value = _total == 0 ? null : _done / _total;
    final percent = _total == 0 ? 0 : ((_done / _total) * 100).round();

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Card(
          elevation: 1,
          shadowColor: const Color(0x1A000000),
          color: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: const BorderSide(color: CmColors.line),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(32, 28, 32, 28),
            child: Column(
              children: [
                const Text(
                  'Importing students…',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: CmColors.navy,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Adding $_total student${_total == 1 ? '' : 's'} '
                  'to $_classCount class${_classCount == 1 ? '' : 'es'}.',
                  style: const TextStyle(color: CmColors.slate),
                ),
                const SizedBox(height: 22),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    value: value,
                    minHeight: 10,
                    color: _ok,
                    backgroundColor: CmColors.line,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '$percent%',
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    color: CmColors.navy,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Please keep this screen open.',
                  style: TextStyle(color: CmColors.slate, fontSize: 13),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ----- Done -----

  Widget _buildDone() {
    final r = _result!;
    final failed = r.failures;
    final allFailed = r.studentsAdded == 0;
    final accent = allFailed ? const Color(0xFFDC2626) : _ok;

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Card(
          elevation: 1,
          shadowColor: const Color(0x1A000000),
          color: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: const BorderSide(color: CmColors.line),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(32, 32, 32, 32),
            child: Column(
              children: [
                Container(
                  width: 70,
                  height: 70,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: accent.withValues(alpha: 0.14),
                  ),
                  child: Icon(
                    allFailed
                        ? Icons.error_outline
                        : Icons.check_circle_outline,
                    size: 36,
                    color: accent,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  allFailed
                      ? 'Import failed'
                      : failed.isEmpty
                      ? 'Import complete'
                      : 'Import finished with some errors',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: CmColors.navy,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '${r.studentsAdded} student${r.studentsAdded == 1 ? '' : 's'} '
                  'added across $_classCount class${_classCount == 1 ? '' : 'es'}.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: CmColors.slate),
                ),
                if (failed.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFEF2F2),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFFECACA)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${failed.length} student${failed.length == 1 ? '' : 's'} '
                          'could not be added:',
                          style: const TextStyle(
                            color: Color(0xFFDC2626),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 8),
                        for (final f in failed.take(10))
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Text(
                              'Row ${f.rowNumber}: ${f.message}',
                              style: const TextStyle(
                                fontSize: 13,
                                color: Color(0xFF7F1D1D),
                              ),
                            ),
                          ),
                        if (failed.length > 10)
                          Text(
                            '…and ${failed.length - 10} more',
                            style: const TextStyle(
                              fontSize: 13,
                              color: Color(0xFF7F1D1D),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                SizedBox(
                  height: 52,
                  child: FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    style: FilledButton.styleFrom(
                      backgroundColor: CmColors.navy,
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text(
                      'Back to Students',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ---------- Step indicator ----------

class _StepIndicator extends StatelessWidget {
  const _StepIndicator({required this.current, this.onBack});
  final int current;
  final VoidCallback? onBack;

  static const _labels = ['File', 'Review', 'Import', 'Done'];

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: CmColors.line)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1140),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Back',
                icon: const Icon(Icons.arrow_back, size: 20),
                color: CmColors.navy,
                onPressed: onBack,
              ),
              const SizedBox(width: 4),
              for (var i = 0; i < _labels.length; i++) ...[
                _dot(i),
                const SizedBox(width: 8),
                Text(
                  _labels[i],
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: i == current
                        ? FontWeight.w700
                        : FontWeight.w500,
                    color: i <= current ? CmColors.navy : CmColors.slate,
                  ),
                ),
                if (i < _labels.length - 1)
                  Expanded(
                    child: Container(
                      height: 1.5,
                      margin: const EdgeInsets.symmetric(horizontal: 10),
                      color: i < current ? CmColors.navy : CmColors.line,
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _dot(int i) {
    final done = i < current;
    final active = i == current;
    return Container(
      width: 30,
      height: 30,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: done || active ? CmColors.navy : Colors.white,
        border: Border.all(
          color: done || active ? CmColors.navy : CmColors.line,
          width: 1.5,
        ),
      ),
      child: done
          ? const Icon(Icons.check, size: 16, color: Colors.white)
          : Text(
              '${i + 1}',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: active ? Colors.white : CmColors.slate,
              ),
            ),
    );
  }
}
