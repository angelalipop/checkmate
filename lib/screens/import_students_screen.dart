import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../services/api_service.dart';
import '../services/auth_storage.dart';
import '../services/student_import_service.dart';
import 'login_screen.dart' show CmColors;

enum _Stage { pick, reading, review, importing, done }

/// Step-by-step Excel import:
/// 1 Choose file -> 2 Review -> 3 Import -> 4 Done.
///
/// Returns `true` from Navigator.pop when data changed, so the caller
/// can refresh.
class ImportStudentsScreen extends StatefulWidget {
  const ImportStudentsScreen({super.key, this.isTeacher = false});

  /// Teacher: class is auto-assigned to the logged-in teacher (no Teacher
  /// field). Admin: must pick the teacher who owns the created classes.
  final bool isTeacher;

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
  List<Map<String, dynamic>> _teachers = [];
  int? _subjectId;
  int? _teacherId;
  String _schoolYear = AcademicOptions.currentSchoolYear();
  String _semester = AcademicOptions.semesters.first;
  String? _lookupError;

  bool _checking = false;
  int _done = 0;
  int _total = 0;
  ImportResult? _result;

  @override
  void initState() {
    super.initState();
    _loadLookups();
  }

  Future<void> _loadLookups() async {
    try {
      final token = await AuthStorage.getToken();
      if (token == null || token.isEmpty) {
        throw Exception('Authentication token not found.');
      }
      final subjects = await ApiService.getSubjects(token);
      final teachers =
          widget.isTeacher ? <Map<String, dynamic>>[] : await ApiService.getTeachers(token);
      if (!mounted) return;
      setState(() {
        _subjects = subjects;
        _teachers = teachers;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
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
    try {
      final bytes = StudentImportService.buildTemplate();
      await SharePlus.instance.share(
        ShareParams(
          files: [
            XFile.fromData(
              Uint8List.fromList(bytes),
              name: 'CheckMate_Student_Template.xlsx',
              mimeType:
                  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
            ),
          ],
          subject: 'CheckMate student import template',
        ),
      );
    } catch (e) {
      _snack('Could not create the template: '
          '${e.toString().replaceFirst('Exception: ', '')}');
    }
  }

  // ---------- Step 2/3: confirm + import ----------

  Future<void> _startImport() async {
    final parsed = _parsed;
    if (parsed == null) return;

    if (_subjectId == null) {
      _snack('Please select a subject.');
      return;
    }
    if (!widget.isTeacher && _teacherId == null) {
      _snack('Please select a teacher.');
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
        subjectId: _subjectId!,
        schoolYear: _schoolYear,
        semester: _semester,
      );

      if (!mounted) return;
      setState(() => _checking = false);

      // Duplicates already in the system.
      final dupes = plan.duplicates;
      if (dupes.isNotEmpty) {
        final skip = await _showDuplicatesDialog(dupes);
        if (skip != true) return;
      }

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
      });

      final result = await StudentImportService.execute(
        token: token,
        plan: plan,
        subjectId: _subjectId!,
        schoolYear: _schoolYear,
        semester: _semester,
        teacherId: widget.isTeacher ? null : _teacherId,
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
        title: const Text('Confirm import', style: TextStyle(fontSize: 18)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'This will add ${plan.studentsToAdd} '
                'student${plan.studentsToAdd == 1 ? '' : 's'}'
                '${plan.newClasses > 0 ? ' and create ${plan.newClasses} new '
                    'class${plan.newClasses == 1 ? '' : 'es'}' : ''}.',
              ),
              const SizedBox(height: 12),
              for (final s in plan.sections.where((s) => s.toAdd.isNotEmpty))
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.class_outlined,
                          size: 18, color: CmColors.slate),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '$subjectName — ${s.section}\n'
                          '${s.toAdd.length} student'
                          '${s.toAdd.length == 1 ? '' : 's'} • '
                          '${s.existingClassId == null ? 'new class' : 'existing class'}',
                          style: const TextStyle(fontSize: 13, height: 1.35),
                        ),
                      ),
                    ],
                  ),
                ),
              Text(
                '$_semester • $_schoolYear',
                style: const TextStyle(fontSize: 13, color: CmColors.slate),
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
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: CmColors.navy),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
  }

  // ---------- Helpers ----------

  String _subjectLabel(int? id) {
    for (final s in _subjects) {
      if (int.tryParse(s['id'].toString()) == id) {
        final name = s['name']?.toString() ?? 'Subject';
        final code = s['code']?.toString() ?? '';
        return code.isEmpty ? name : '$code - $name';
      }
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
              _StepIndicator(current: _stepIndex),
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
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
        Card(
          elevation: 0,
          color: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: CmColors.line),
          ),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.upload_file_outlined,
                    size: 48, color: CmColors.navy),
                const SizedBox(height: 12),
                const Text(
                  'Upload a student list',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Choose an Excel (.xlsx) file with these columns:',
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
    Widget cell(String t, {bool head = false}) => Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
            decoration: BoxDecoration(
              color: head ? CmColors.navy : Colors.white,
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
            cell('Student No.', head: true),
            cell('Name', head: true),
            cell('Section', head: true),
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
          elevation: 0,
          color: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
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
                const SizedBox(height: 14),
                const Divider(height: 1, color: CmColors.line),
                const SizedBox(height: 10),
                for (final e in sections.entries)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        const Icon(Icons.check_circle,
                            color: CmColors.green, size: 20),
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
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
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
              'A class is created for each section using these details.',
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
            DropdownButtonFormField<int>(
              initialValue: _subjectId,
              isExpanded: true,
              decoration: _dec('Subject', Icons.menu_book_outlined),
              items: _subjects.map((s) {
                final id = int.parse(s['id'].toString());
                final name = s['name']?.toString() ?? 'Unnamed Subject';
                final code = s['code']?.toString() ?? '';
                return DropdownMenuItem<int>(
                  value: id,
                  child: Text(
                    code.isEmpty ? name : '$code - $name',
                    overflow: TextOverflow.ellipsis,
                  ),
                );
              }).toList(),
              onChanged: _busy ? null : (v) => setState(() => _subjectId = v),
            ),
            if (!widget.isTeacher) ...[
              const SizedBox(height: 14),
              DropdownButtonFormField<int>(
                initialValue: _teacherId,
                isExpanded: true,
                decoration: _dec('Teacher', Icons.person_outline),
                items: _teachers.map((t) {
                  final id = int.parse(t['id'].toString());
                  return DropdownMenuItem<int>(
                    value: id,
                    child: Text(
                      t['name']?.toString() ?? 'Unnamed Teacher',
                      overflow: TextOverflow.ellipsis,
                    ),
                  );
                }).toList(),
                onChanged:
                    _busy ? null : (v) => setState(() => _teacherId = v),
              ),
            ],
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
              initialValue: _semester,
              decoration: _dec('Semester', Icons.calendar_month_outlined),
              items: AcademicOptions.semesters
                  .map((s) => DropdownMenuItem<String>(value: s, child: Text(s)))
                  .toList(),
              onChanged: _busy
                  ? null
                  : (v) => setState(() => _semester = v ?? _semester),
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
              flex: 2,
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
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Importing students…',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 20),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: value,
                minHeight: 10,
                color: CmColors.navy,
                backgroundColor: CmColors.line,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '$_done of $_total',
              style: const TextStyle(color: CmColors.slate),
            ),
            const SizedBox(height: 8),
            const Text(
              'Please keep this screen open.',
              style: TextStyle(color: CmColors.slate, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }

  // ----- Done -----

  Widget _buildDone() {
    final r = _result!;
    final failed = r.failures;
    final allFailed = r.studentsAdded == 0;

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 16),
        Icon(
          allFailed ? Icons.error_outline : Icons.check_circle,
          size: 72,
          color: allFailed ? const Color(0xFFDC2626) : CmColors.green,
        ),
        const SizedBox(height: 16),
        Text(
          allFailed
              ? 'Import failed.'
              : failed.isEmpty
                  ? 'Students imported successfully.'
                  : 'Import finished with some errors.',
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: CmColors.navy,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          '${r.studentsAdded} student${r.studentsAdded == 1 ? '' : 's'} added',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 16),
        ),
        Text(
          '${r.classesCreated} class${r.classesCreated == 1 ? '' : 'es'} created',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 16),
        ),
        if (failed.isNotEmpty) ...[
          const SizedBox(height: 20),
          Container(
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
        const SizedBox(height: 28),
        SizedBox(
          height: 52,
          child: FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: CmColors.navy,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text('Done',
                style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        ),
      ],
    );
  }
}

// ---------- Step indicator ----------

class _StepIndicator extends StatelessWidget {
  const _StepIndicator({required this.current});
  final int current;

  static const _labels = ['File', 'Review', 'Import', 'Done'];

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Row(
        children: [
          for (var i = 0; i < _labels.length; i++) ...[
            _dot(i),
            const SizedBox(width: 6),
            Text(
              _labels[i],
              style: TextStyle(
                fontSize: 12,
                fontWeight: i == current ? FontWeight.w700 : FontWeight.w500,
                color: i <= current ? CmColors.navy : CmColors.slate,
              ),
            ),
            if (i < _labels.length - 1)
              Expanded(
                child: Container(
                  height: 1.5,
                  margin: const EdgeInsets.symmetric(horizontal: 8),
                  color: i < current ? CmColors.navy : CmColors.line,
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _dot(int i) {
    final done = i < current;
    final active = i == current;
    return Container(
      width: 22,
      height: 22,
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
          ? const Icon(Icons.check, size: 14, color: Colors.white)
          : Text(
              '${i + 1}',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: active ? Colors.white : CmColors.slate,
              ),
            ),
    );
  }
}