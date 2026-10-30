import 'dart:async';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../services/academic_api_service.dart';
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
    this.initialSection,
    this.initialClass,
  });

  /// Teachers can create classes under their signed-in account.
  /// Admins import into existing classes, preserving their assigned teachers.
  final bool isTeacher;

  /// Section names assigned to the logged-in teacher. When given, a file is
  /// rejected if any row belongs to a section outside this list.
  final List<String>? assignedSections;

  /// Section the import was opened from (an empty section's button), shown
  /// on the first step.
  final String? initialSection;

  /// That section's class, when it has exactly one: its subject, school year
  /// and semester are preselected in the review step.
  final Map<String, dynamic>? initialClass;

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

  // Common info
  List<Map<String, dynamic>> _subjects = [];
  Map<String, dynamic>? _selectedSubject;
  int? _subjectId;
  Timer? _subjectSearchTimer;
  int _subjectRequest = 0;
  String _subjectQuery = '';
  bool _loadingSubjects = true;
  static const _semesters = ['1st Semester', '2nd Semester'];
  String _schoolYear = AcademicOptions.currentSchoolYear();
  String _semester = _semesters.first;
  String? _lookupError;

  // Details read from the Excel file
  bool _matchingSubject = false;
  String? _subjectNotFound; // subject named in the file with no catalog match
  bool _semesterFromSubject = false;

  bool _checking = false;
  int _done = 0;
  int _total = 0;
  int _classCount = 0;
  ImportResult? _result;

  @override
  void initState() {
    super.initState();
    _applyInitialClass();
    _loadLookups();
  }

  void _applyInitialClass() {
    final c = widget.initialClass;
    if (c == null) return;

    // A class's subject id belongs to the teaching "subjects" table, not to
    // the Academic Management catalog the dropdown lists. Only the linked
    // catalog id may be used; otherwise the subject comes from the file.
    final subject = c['subject'];
    if (subject is Map) {
      final id = int.tryParse(subject['academic_subject_id']?.toString() ?? '');
      if (id != null) {
        _subjectId = id;
        _selectedSubject = {...Map<String, dynamic>.from(subject), 'id': id};
      }
    }

    final schoolYear = c['school_year']?.toString().trim() ?? '';
    if (schoolYear.isNotEmpty) _schoolYear = schoolYear;

    final semester = c['semester']?.toString().trim() ?? '';
    if (_semesters.contains(semester)) _semester = semester;
  }

  static String _sectionKey(String name) =>
      name.toUpperCase().replaceAll(RegExp(r'[\s-]+'), '');

  /// Sections in the file that are not assigned to the logged-in teacher.
  List<String> _unassignedSections(ParsedStudentFile parsed) {
    final allowed = widget.assignedSections;
    if (allowed == null) return const [];
    final ok = allowed.map(_sectionKey).toSet();
    return parsed.bySection.keys
        .where((name) => !ok.contains(_sectionKey(name)))
        .toList();
  }

  static String _normText(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  /// "1", "1st", "1st Semester", "First Semester" -> "1st Semester".
  /// Null when it is not 1st/2nd (e.g. Summer) or unknown.
  static String? _semesterLabel(Object? value) {
    final text = value?.toString().trim().toLowerCase() ?? '';
    if (text.startsWith('1') || text.startsWith('first')) return _semesters[0];
    if (text.startsWith('2') || text.startsWith('second')) return _semesters[1];
    return null;
  }

  /// Semester of a subject according to the Academic Management curricula.
  /// [section] (e.g. BSIT31A) narrows it to the right program and year level.
  /// Null when the curricula place the subject in more than one term.
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
          .where((p) => key.startsWith((p['program'] ?? '').toString().toUpperCase()))
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
    // Older servers may send a plain semester field.
    return _semesterLabel(subject['semester'] ?? subject['term']);
  }

  /// Section named in the file (top cell, or its first row).
  static String? _sectionOf(ParsedStudentFile p) =>
      p.fileSection ?? (p.rows.isEmpty ? null : p.rows.first.section);

  /// Uses what the sheet says: finds its Subject in Academic Management,
  /// selects it, and sets the Semester from that subject.
  Future<void> _applyFileDetails(ParsedStudentFile parsed) async {
    final wanted = parsed.subject?.trim() ?? '';
    if (wanted.isEmpty) {
      if (mounted) {
        setState(() {
          _matchingSubject = false;
          _subjectNotFound = null;
        });
      }
      return;
    }

    setState(() {
      _matchingSubject = true;
      _subjectNotFound = null;
    });

    Map<String, dynamic>? match;
    try {
      final token = await AuthStorage.getToken();
      if (token == null || token.isEmpty) {
        throw Exception('Authentication token not found.');
      }

      // The label is "CODE - Name"; accept the name, the label or the code.
      final key = _normText(wanted);
      bool same(Map<String, dynamic> s) =>
          _normText(s['name']?.toString() ?? '') == key ||
          _normText(_catalogLabel(s)) == key ||
          _normText(s['code']?.toString() ?? '') == key;

      final results = await AcademicApi.searchCatalog(token, wanted);
      final found = results.where(same).toList();
      if (found.isNotEmpty) {
        // Prefer the subject this import was opened from, if it is one.
        match = found.firstWhere(
          (s) => _subjectIdOf(s) != null && _subjectIdOf(s) == _subjectId,
          orElse: () => found.first,
        );
      }
    } catch (_) {
      match = null;
    }

    if (!mounted) return;
    setState(() {
      _matchingSubject = false;
      final chosen = match;
      if (chosen == null) {
        _subjectNotFound = wanted;
        return;
      }
      final id = _subjectIdOf(chosen);
      _selectedSubject = chosen;
      _subjectId = id;
      _subjects = [
        ..._subjects.where((s) => _subjectIdOf(s) != id),
        chosen,
      ];
      final sem = _subjectSemester(chosen, section: _sectionOf(parsed));
      if (sem != null) {
        _semester = sem;
        _semesterFromSubject = true;
      }
    });
  }

  /// Lets a file say "BSIT3A" (program+year+section) for a class named
  /// "BSIT31A" (program+year+term+section). The term comes from the selected
  /// semester. Names that already match are left alone.
  ParsedStudentFile _resolveSections(ParsedStudentFile parsed) {
    final allowed = widget.assignedSections;
    if (allowed == null) return parsed;

    final byKey = {for (final a in allowed) _sectionKey(a): a};
    final term = _semester.startsWith('2') ? '2' : '1';
    final short = RegExp(r'^([A-Z]+)(\d)([A-Z]+)$'); // BSIT 3 A

    String resolve(String name) {
      final key = _sectionKey(name);
      if (byKey.containsKey(key)) return byKey[key]!;
      final m = short.firstMatch(key);
      if (m != null) {
        final full = '${m[1]}${m[2]}$term${m[3]}'; // BSIT + 3 + 1 + A
        if (byKey.containsKey(full)) return byKey[full]!;
      }
      return name; // unchanged, so it is reported as not assigned
    }

    return parsed.withRows([
      for (final r in parsed.rows)
        ImportRow(
          rowNumber: r.rowNumber,
          studentNumber: r.studentNumber,
          name: r.name,
          section: resolve(r.section),
          firstName: r.firstName,
          lastName: r.lastName,
          email: r.email,
        ),
    ]);
  }

  @override
  void dispose() {
    _subjectSearchTimer?.cancel();
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

  List<Map<String, dynamic>> get _subjectOptions {
    final byId = <int, Map<String, dynamic>>{};
    for (final subject in _subjects) {
      final id = _subjectIdOf(subject);
      if (id != null) byId[id] = subject;
    }
    // Keep the selected subject valid when a search returns other matches.
    final selected = _selectedSubject;
    if (selected != null && _subjectId != null) {
      byId.putIfAbsent(_subjectId!, () => selected);
    }
    return byId.values.toList()
      ..sort((a, b) => _catalogLabel(a).compareTo(_catalogLabel(b)));
  }

  void _searchSubjects(String query) {
    _subjectSearchTimer?.cancel();
    _subjectRequest++;
    setState(() {
      _subjectQuery = query.trim();
      _loadingSubjects = true;
      _lookupError = null;
    });
    _subjectSearchTimer = Timer(const Duration(milliseconds: 350), () {
      if (mounted) _loadLookups(_subjectQuery);
    });
  }

  Future<void> _loadLookups([String query = '']) async {
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
      final subjects = await AcademicApi.searchCatalog(token, query);
      if (!mounted || request != _subjectRequest) return;
      setState(() {
        _subjects = subjects;
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

      // Let the spinner paint before the (synchronous) parse.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final parsed = StudentImportService.parse(bytes, fileName);
      if (!mounted) return;
      setState(() {
        _parsed = parsed;
        _stage = _Stage.review;
        _subjectNotFound = null;
        _semesterFromSubject = false;
      });
      await _applyFileDetails(parsed);
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
    // Pre-filled when opened from a section's button; named Section + Subject.
    final section = widget.initialSection?.trim() ?? '';
    final subjectName = _selectedSubject?['name']?.toString().trim() ?? '';
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
        sections: widget.assignedSections ?? const [],
      );
      final file = XFile.fromData(
        Uint8List.fromList(bytes),
        name: fileName,
        mimeType: mime,
      );

      final isDesktop = defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.linux;

      if (kIsWeb) {
        // Triggers a normal browser download.
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
        // Phones/tablets: hand the file to the share sheet (Save to Files, etc.).
        await SharePlus.instance.share(
          ShareParams(
            files: [file],
            subject: 'CheckMate student import template',
          ),
        );
      }
    } catch (e) {
      _snack('Could not create the template: '
          '${e.toString().replaceFirst('Exception: ', '')}');
    }
  }

  // ---------- Step 2/3: confirm + import ----------

  Future<void> _startImport() async {
    if (_parsed == null) return;
    final parsed = _resolveSections(_parsed!);

    if (_subjectId == null) {
      _snack('Please select a subject.');
      return;
    }

    // Students can only be added to the teacher's own sections.
    final unassigned = _unassignedSections(parsed);
    if (unassigned.isNotEmpty) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: _dialogShape,
          title: const Text('Section not assigned to you'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'You can only import students into sections assigned to '
                'you. These sections in the file are not:',
              ),
              const SizedBox(height: 10),
              for (final name in unassigned.take(8))
                Text('• $name',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              if (unassigned.length > 8)
                Text('…and ${unassigned.length - 8} more'),
              const SizedBox(height: 10),
              const Text(
                'Correct the Section column in your file, then choose it '
                'again.',
                style: TextStyle(fontSize: 13, color: CmColors.slate),
              ),
            ],
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

    setState(() => _checking = true);

    try {
      final token = await AuthStorage.getToken();
      if (token == null || token.isEmpty) {
        throw Exception('Authentication token not found.');
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
      if (plan.sections.any((s) =>
          s.toAdd.isNotEmpty && s.existingClassId == null)) {
        final missing = plan.sections
            .where((s) => s.toAdd.isNotEmpty && s.existingClassId == null)
            .map((s) => s.section)
            .join(', ');
        _snack('No class found for $missing with this subject, '
            '$_schoolYear, $_semester. Check the Subject and Semester above, '
            'or ask an administrator to assign it to you.');
        return;
      }

      // Duplicates already in the system.
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
              'All students in this file already exist in the selected classes.',
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
        _classCount =
            plan.sections.where((s) => s.toAdd.isNotEmpty).length;
      });

      final result = await StudentImportService.execute(
        token: token,
        plan: plan,
        subjectId: _subjectId!,
        subject: _selectedSubject!,
        schoolYear: _schoolYear,
        semester: _semester,
        // Existing classes keep their teacher. For new teacher classes,
        // the backend uses the authenticated teacher.
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
        // Return to review so nothing the teacher entered is lost.
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
                  style: const TextStyle(
                    fontSize: 13,
                    color: CmColors.slate,
                  ),
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
                  'student${plan.studentsToAdd == 1 ? '' : 's'}'
                  '${plan.newClasses > 0 ? ' and create ${plan.newClasses} new '
                      'class${plan.newClasses == 1 ? '' : 'es'}' : ''}.',
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
                        const Icon(Icons.menu_book_outlined,
                            size: 18, color: CmColors.slate),
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
                                '${s.toAdd.length == 1 ? '' : 's'} • '
                                '${s.existingClassId == null ? 'new class' : 'existing class'}',
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
                    style: const TextStyle(
                      fontSize: 13,
                      color: CmColors.slate,
                    ),
                  ),
                ),
                if (skippedRows > 0) ...[
                  const SizedBox(height: 10),
                  Text(
                    '$skippedRows row${skippedRows == 1 ? '' : 's'} with '
                    'problems will be skipped.',
                    style:
                        const TextStyle(fontSize: 13, color: CmColors.amber),
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
    return 'Subject';
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
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
      _semesterFromSubject = false;
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
        if (_errorTitle != null) ...[
          _errorCard(),
          const SizedBox(height: 16),
        ],
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
                    child: const Icon(Icons.upload_file_outlined,
                        size: 28, color: CmColors.navy),
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
                  'Use the template: Section and Subject (full name) on top, '
                  'then one row per student.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: CmColors.slate),
                ),
                const SizedBox(height: 14),
                _formatPreview(),
                const SizedBox(height: 8),
                const Text(
                  'Student No. and Name are required; Email is optional. '
                  'Save the file as Section + Subject, e.g. '
                  'BSIT31A Professional Issues in IT.xlsx. '
                  'One file per subject.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: CmColors.slate, fontSize: 12),
                ),
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
    Widget cell(String t, {bool head = false, bool fill = false, int flex = 1}) =>
        Expanded(
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
          Row(children: [
            cell('Section', head: true),
            cell('BSIT31A', fill: true, flex: 3),
          ]),
          Row(children: [
            cell('Subject', head: true),
            cell('Professional Issues in IT', fill: true, flex: 3),
          ]),
          const SizedBox(height: 6),
          Row(children: [
            cell('Student No.', head: true),
            cell('Name', head: true),
            cell('Email', head: true),
          ]),
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
            Text(_errorMessage!,
                style: const TextStyle(color: Color(0xFF7F1D1D))),
          ],
          for (final c in _missingColumns)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 4),
              child: Text('• $c',
                  style: const TextStyle(
                    color: Color(0xFF7F1D1D),
                    fontWeight: FontWeight.w600,
                  )),
            ),
        ],
      ),
    );
  }

  // ----- Review -----

  Widget _buildReview() {
    final parsed = _parsed!;
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
                    const Icon(Icons.description_outlined,
                        color: CmColors.slate, size: 20),
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
                        const Icon(Icons.check_circle_outline,
                            color: _ok, size: 20),
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
          ? 'No subject found in the file. Select it below.'
          : 'No subject in the file. Using ${_catalogLabel(current)}.';
      icon = Icons.info_outline;
      color = CmColors.slate;
    } else if (_matchingSubject) {
      text = 'Subject: $fileSubject (checking Academic Management…)';
      icon = Icons.hourglass_empty;
      color = CmColors.slate;
    } else if (_subjectNotFound != null) {
      text = 'Subject "$fileSubject" was not found in Academic Management. '
          'Select the right one below.';
      icon = Icons.warning_amber_rounded;
      color = const Color(0xFF92400E);
    } else {
      final matched = _selectedSubject;
      text = 'Subject: ${matched == null ? fileSubject : _catalogLabel(matched)}';
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
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: CmColors.navy, width: 1.5),
        ),
      );

  Widget _commonInfoCard() {
    final years = <String>{
      ...AcademicOptions.schoolYears(),
      _schoolYear,
    }.toList()
      ..sort();

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
              'Students are added to each section’s subject class using these details.',
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
            TextField(
              enabled: !_busy,
              decoration: _dec('Search Academic Management subjects',
                  Icons.search).copyWith(
                hintText: 'Enter a course code or course name',
              ),
              onChanged: _searchSubjects,
            ),
            const SizedBox(height: 14),
            if (_loadingSubjects) ...[
              const LinearProgressIndicator(color: CmColors.navy),
              const SizedBox(height: 12),
            ],
            DropdownButtonFormField<int>(
              key: ValueKey('subject-$_subjectId'),
              initialValue: _subjectId,
              isExpanded: true,
              decoration: _dec('Subject', Icons.menu_book_outlined),
              hint: Text(_loadingSubjects
                  ? 'Loading subjects…'
                  : _subjects.isEmpty
                      ? 'No subjects found. Try searching by code or name.'
                      : 'Select subject'),
              items: _subjectOptions.map((subject) {
                return DropdownMenuItem<int>(
                  value: _subjectIdOf(subject)!,
                  child: Text(
                    _catalogLabel(subject),
                    overflow: TextOverflow.ellipsis,
                  ),
                );
              }).toList(),
              onChanged: _busy || _loadingSubjects || _lookupError != null
                  ? null
                  : (value) => setState(() {
                        _selectedSubject = value == null
                            ? null
                            : _subjectOptions.firstWhere(
                                (subject) => _subjectIdOf(subject) == value);
                        _subjectId = value;
                        _subjectNotFound = null;
                        final sem = _selectedSubject == null || _parsed == null
                            ? null
                            : _subjectSemester(
                                _selectedSubject!,
                                section: _sectionOf(_parsed!),
                              );
                        if (sem != null) _semester = sem;
                        _semesterFromSubject = sem != null;
                      }),
            ),
            if (_lookupError != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _busy || _loadingSubjects
                      ? null
                      : () => _loadLookups(_subjectQuery),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry loading subjects'),
                ),
              ),
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              initialValue: _schoolYear,
              decoration: _dec('School Year', Icons.calendar_today_outlined),
              items: years
                  .map((y) => DropdownMenuItem<String>(value: y, child: Text(y)))
                  .toList(),
              onChanged: _busy
                  ? null
                  : (v) => setState(() => _schoolYear = v ?? _schoolYear),
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              key: ValueKey('semester-$_semester'),
              initialValue: _semester,
              decoration: _dec('Semester', Icons.calendar_month_outlined)
                  .copyWith(
                helperText: _semesterFromSubject
                    ? 'Set from this subject in Academic Management'
                    : null,
              ),
              items: _semesters
                  .map((s) => DropdownMenuItem<String>(value: s, child: Text(s)))
                  .toList(),
              onChanged: _busy
                  ? null
                  : (v) => setState(() {
                        _semester = v ?? _semester;
                        _semesterFromSubject = false;
                      }),
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
                  child: const Text('Cancel',
                      style: TextStyle(fontWeight: FontWeight.w700)),
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
                      : const Text('Import Students',
                          style: TextStyle(fontWeight: FontWeight.w700)),
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
                                  fontSize: 13, color: Color(0xFF7F1D1D)),
                            ),
                          ),
                        if (failed.length > 10)
                          Text('…and ${failed.length - 10} more',
                              style: const TextStyle(
                                  fontSize: 13, color: Color(0xFF7F1D1D))),
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
                    child: const Text('Back to Students',
                        style: TextStyle(fontWeight: FontWeight.w700)),
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
                    fontWeight:
                        i == current ? FontWeight.w700 : FontWeight.w500,
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
