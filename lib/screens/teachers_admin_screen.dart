import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/api_service.dart';
import '../services/auth_storage.dart';
import '../services/student_import_service.dart' show StudentValidation;
import 'login_screen.dart' show CmColors;

// =============================================================
// Teachers — built on the same patterns as students_screen
// (search field, cards, chips, popup actions, dialogs, empty states).
// Every action calls the backend; nothing is mocked.
// =============================================================

const Color _activeGreen = Color(0xFF2F8F72);
const Color _dangerRed = Color(0xFFDC2626);

// ---------- Teacher record helpers (tolerant of API field names) ----------

int? _tId(Map<String, dynamic> t) => int.tryParse(t['id']?.toString() ?? '');

String _tRawName(Map<String, dynamic> t) =>
    (t['name'] ?? t['full_name'] ?? '').toString().trim();

String _tName(Map<String, dynamic> t) {
  final n = _tRawName(t);
  return n.isEmpty ? 'Unnamed Teacher' : n;
}

String _tEmail(Map<String, dynamic> t) => (t['email'] ?? '').toString().trim();

String _tUsername(Map<String, dynamic> t) =>
    (t['username'] ?? '').toString().trim();

bool _tActive(Map<String, dynamic> t) {
  final v = t['is_active'] ?? t['active'];
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v != null) {
    final s = v.toString().toLowerCase();
    return s == 'true' || s == '1' || s == 'active';
  }
  final status = t['status']?.toString().toLowerCase();
  if (status != null) return status == 'active';
  return true;
}

// ---------- Teaching assignments (Subject + Section) ----------

/// One section a teacher teaches for a subject.
class _Sec {
  const _Sec({
    required this.section,
    this.schoolYear = '',
    this.semester = '',
    this.yearLevel,
  });

  final String section;
  final String schoolYear;
  final String semester;
  final int? yearLevel;

  String get key => '${section.toLowerCase()}|$schoolYear|$semester';
}

/// A subject plus the sections the teacher teaches it in.
class _SubjectAssignment {
  _SubjectAssignment({
    required this.subjectId,
    required this.subjectName,
    Map<String, _Sec>? sections,
  }) : sections = sections ?? <String, _Sec>{};

  final int subjectId;
  final String subjectName;
  final Map<String, _Sec> sections;
}

List<_SubjectAssignment> _tAssignments(Map<String, dynamic> t) {
  final out = <_SubjectAssignment>[];
  final raw = t['assignments'];
  if (raw is! List) return out;

  for (final a in raw) {
    if (a is! Map) continue;

    final subjectId = int.tryParse(a['subject_id']?.toString() ?? '');
    if (subjectId == null) continue;

    final item = _SubjectAssignment(
      subjectId: subjectId,
      subjectName: (a['subject_name'] ?? 'Subject').toString(),
    );

    final classes = a['classes'];
    if (classes is List) {
      for (final c in classes) {
        if (c is! Map) continue;

        final sec = _Sec(
          section: (c['section'] ?? '').toString(),
          schoolYear: (c['school_year'] ?? '').toString(),
          semester: (c['semester'] ?? '').toString(),
          yearLevel: int.tryParse(c['year_level']?.toString() ?? ''),
        );

        if (sec.section.isNotEmpty) item.sections[sec.key] = sec;
      }
    }

    if (item.sections.isNotEmpty) out.add(item);
  }

  return out;
}

List<Map<String, dynamic>> _assignmentPayload(
  List<_SubjectAssignment> list,
) =>
    [
      for (final a in list)
        for (final s in a.sections.values)
          {
            'subject_id': a.subjectId,
            'section': s.section,
            'school_year': s.schoolYear,
            'semester': s.semester,
          },
    ];

Set<String> _assignmentKeys(List<_SubjectAssignment> list) => {
      for (final a in list)
        for (final s in a.sections.values) '${a.subjectId}|${s.key}',
    };

bool _assignmentsChanged(
  List<_SubjectAssignment> before,
  List<_SubjectAssignment> after,
) {
  final a = _assignmentKeys(before);
  final b = _assignmentKeys(after);
  return a.length != b.length || !a.containsAll(b);
}

String _assignmentSearchText(Map<String, dynamic> t) => [
      for (final a in _tAssignments(t)) ...[
        a.subjectName,
        ...a.sections.values.map((s) => s.section),
      ],
    ].join(' ').toLowerCase();

String _yearLabel(int? y) {
  switch (y) {
    case null:
      return 'Other';
    case 1:
      return '1st Year';
    case 2:
      return '2nd Year';
    case 3:
      return '3rd Year';
    default:
      return '${y}th Year';
  }
}

String _clean(Object e) => e.toString().replaceFirst('Exception: ', '');

// ---------- Shared form styling (same look as the Students dialogs) ----------

InputDecoration _fieldDecoration({String? errorText}) {
  OutlineInputBorder border(Color c, [double w = 1]) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: c, width: w),
      );

  return InputDecoration(
    isDense: true,
    filled: true,
    fillColor: Colors.white,
    errorText: errorText,
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    border: border(CmColors.line),
    enabledBorder: border(CmColors.line),
    focusedBorder: border(CmColors.navy, 1.5),
    errorBorder: border(_dangerRed),
    focusedErrorBorder: border(_dangerRed, 1.5),
  );
}

Widget _labeled(String label, Widget field) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 13,
            color: CmColors.slate,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
      field,
    ],
  );
}

ButtonStyle get _primaryButtonStyle => FilledButton.styleFrom(
      backgroundColor: CmColors.navy,
      disabledBackgroundColor: const Color(0xFF9AA3B2),
      disabledForegroundColor: Colors.white,
      minimumSize: const Size.fromHeight(50),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    );

ButtonStyle get _secondaryButtonStyle => OutlinedButton.styleFrom(
      foregroundColor: CmColors.navy,
      backgroundColor: CmColors.bg,
      side: const BorderSide(color: CmColors.line),
      minimumSize: const Size.fromHeight(50),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    );

Widget _dialogShell({required Widget child}) {
  return Dialog(
    backgroundColor: Colors.white,
    surfaceTintColor: Colors.transparent,
    insetPadding: const EdgeInsets.all(24),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 480),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
        child: child,
      ),
    ),
  );
}

Widget _dialogHeader(String title, VoidCallback? onClose) {
  return Row(
    children: [
      Expanded(
        child: Text(
          title,
          style: const TextStyle(
            fontSize: 19,
            fontWeight: FontWeight.w700,
            color: CmColors.navy,
          ),
        ),
      ),
      IconButton(
        tooltip: 'Close',
        icon: const Icon(Icons.close, size: 20),
        onPressed: onClose,
      ),
    ],
  );
}

Widget _spinner() => const SizedBox(
      width: 20,
      height: 20,
      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
    );

// =============================================================
// SCREEN
// =============================================================

class TeachersScreen extends StatefulWidget {
  const TeachersScreen({super.key});

  @override
  State<TeachersScreen> createState() => _TeachersScreenState();
}

class _TeachersScreenState extends State<TeachersScreen> {
  List<Map<String, dynamic>> _teachers = [];
  List<Map<String, dynamic>> _subjects = [];

  final _searchController = TextEditingController();
  String _query = '';

  bool _loading = true;
  String? _error;

  /// Teacher ids with a request in flight (prevents duplicate actions).
  final Set<int> _busy = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<String> _token() async {
    final token = await AuthStorage.getToken();
    if (token == null || token.isEmpty) {
      throw Exception('Your session has expired. Please log in again.');
    }
    return token;
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    try {
      final token = await _token();

      final results = await Future.wait([
        ApiService.getTeachers(token),
        ApiService.getSubjects(token),
      ]);

      if (!mounted) return;

      setState(() {
        _teachers = results[0];
        _subjects = results[1];
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;

      if (silent && _teachers.isNotEmpty) {
        _snack(_clean(e));
        return;
      }

      setState(() {
        _error = _clean(e);
        _loading = false;
      });
    }
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  // ---------- lookups ----------

  bool _matches(Map<String, dynamic> t) {
    if (_query.isEmpty) return true;

    return _tName(t).toLowerCase().contains(_query) ||
        _tEmail(t).toLowerCase().contains(_query) ||
        _tUsername(t).toLowerCase().contains(_query) ||
        _assignmentSearchText(t).contains(_query);
  }

  // =========================
  // ADD
  // =========================

  Future<void> _showAddDialog() async {
    _Credentials? creds;

    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _TeacherFormDialog(
        teachers: _teachers,
        subjects: _subjects,
        onSubmit: (input) async {
          final token = await _token();

          final created = await ApiService.createTeacher(
            token: token,
            name: input.name,
            email: input.email,
            username: input.username,
            temporaryPassword: input.password!,
            assignments: _assignmentPayload(input.assignments),
          );

          creds = _Credentials(
            name: input.name,
            username: _tUsername(created).isEmpty
                ? input.username
                : _tUsername(created),
            password: input.password!,
          );
        },
      ),
    );

    if (ok != true || creds == null) return;

    await _load(silent: true);
    if (!mounted) return;

    await _showCredentials(creds!, title: 'Teacher account created');
  }

  // =========================
  // EDIT
  // =========================

  Future<void> _showEditDialog(Map<String, dynamic> teacher) async {
    final id = _tId(teacher);
    if (id == null || _busy.contains(id)) return;

    final before = _tAssignments(teacher);

    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _TeacherFormDialog(
        teachers: _teachers,
        subjects: _subjects,
        teacher: teacher,
        onSubmit: (input) async {
          final token = await _token();

          // Profile + assignments are saved in ONE server transaction, so a
          // conflict (section already taken) saves nothing.
          await ApiService.updateTeacher(
            token: token,
            teacherId: id,
            name: input.name,
            email: input.email,
            username: input.username,
            assignments: _assignmentsChanged(before, input.assignments)
                ? _assignmentPayload(input.assignments)
                : null,
          );
        },
      ),
    );

    if (ok != true) return;

    await _load(silent: true);
    if (!mounted) return;
    _snack('Teacher updated.');
  }

  // =========================
  // ASSIGN SECTIONS
  // =========================

  Future<void> _showAssignDialog(Map<String, dynamic> teacher) async {
    final id = _tId(teacher);
    if (id == null || _busy.contains(id)) return;

    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _AssignSectionsDialog(
        teacherName: _tName(teacher),
        teacherId: id,
        subjects: _subjects,
        initial: _tAssignments(teacher),
        onSave: (list) async {
          final token = await _token();
          await ApiService.setTeacherAssignments(
            token: token,
            teacherId: id,
            assignments: _assignmentPayload(list),
          );
        },
      ),
    );

    if (ok != true) return;

    await _load(silent: true);
    if (!mounted) return;
    _snack('Assignments updated.');
  }

  // =========================
  // RESET PASSWORD
  // =========================

  Future<void> _resetPassword(Map<String, dynamic> teacher) async {
    final id = _tId(teacher);
    if (id == null || _busy.contains(id)) return;

    final confirmed = await _confirm(
      title: 'Reset password?',
      message: 'A new temporary password will replace ${_tName(teacher)}\'s '
          'current password. They must change it the next time they sign in.',
      confirmLabel: 'Reset Password',
    );
    if (confirmed != true) return;

    setState(() => _busy.add(id));

    try {
      final token = await _token();
      final password = await ApiService.resetTeacherPassword(
        token: token,
        teacherId: id,
      );

      if (!mounted) return;

      setState(() => _busy.remove(id));

      await _showCredentials(
        _Credentials(
          name: _tName(teacher),
          username: _tUsername(teacher),
          password: password,
        ),
        title: 'Password reset',
      );

      await _load(silent: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy.remove(id));
      _snack(_clean(e));
    }
  }

  // =========================
  // ENABLE / DISABLE
  // =========================

  Future<void> _toggleActive(Map<String, dynamic> teacher) async {
    final id = _tId(teacher);
    if (id == null || _busy.contains(id)) return;

    final enable = !_tActive(teacher);

    if (!enable) {
      final confirmed = await _confirm(
        title: 'Disable ${_tName(teacher)}?',
        message: 'They will no longer be able to sign in or use CheckMate '
            'until the account is enabled again.',
        confirmLabel: 'Disable',
      );
      if (confirmed != true) return;
    }

    setState(() => _busy.add(id));

    try {
      final token = await _token();
      await ApiService.setTeacherActive(
        token: token,
        teacherId: id,
        active: enable,
      );

      if (!mounted) return;
      setState(() => _busy.remove(id));
      _snack(enable ? 'Account enabled.' : 'Account disabled.');
      await _load(silent: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy.remove(id));
      _snack(_clean(e));
    }
  }

  // =========================
  // DELETE
  // =========================

  Future<void> _delete(Map<String, dynamic> teacher) async {
    final id = _tId(teacher);
    if (id == null || _busy.contains(id)) return;

    final confirmed = await _confirm(
      title: 'Delete ${_tName(teacher)}?',
      message: 'This permanently removes the account and its section '
          'assignments. This cannot be undone.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (confirmed != true) return;

    setState(() => _busy.add(id));

    try {
      final token = await _token();
      await ApiService.deleteTeacher(token: token, teacherId: id);

      if (!mounted) return;
      setState(() => _busy.remove(id));
      _snack('Teacher deleted.');
      await _load(silent: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy.remove(id));
      _snack(_clean(e));
    }
  }

  // =========================
  // DIALOG HELPERS
  // =========================

  Future<bool?> _confirm({
    required String title,
    required String message,
    required String confirmLabel,
    bool destructive = false,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Text(
          title,
          style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Text(message, style: const TextStyle(color: CmColors.slate)),
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
              backgroundColor: destructive ? _dangerRed : CmColors.navy,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
  }

  Future<void> _showCredentials(_Credentials creds, {required String title}) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _CredentialsDialog(creds: creds, title: title),
    );
  }

  void _onAction(String action, Map<String, dynamic> teacher) {
    switch (action) {
      case 'edit':
        _showEditDialog(teacher);
      case 'sections':
        _showAssignDialog(teacher);
      case 'reset':
        _resetPassword(teacher);
      case 'toggle':
        _toggleActive(teacher);
      case 'delete':
        _delete(teacher);
    }
  }

  // =========================
  // BUILD
  // =========================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Teachers'),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showAddDialog,
        backgroundColor: CmColors.navy,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.person_add_alt_1_outlined),
        label: const Text('Add Teacher'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x14000000),
                    blurRadius: 8,
                    offset: Offset(0, 2),
                  ),
                ],
              ),
              child: TextField(
                controller: _searchController,
                textInputAction: TextInputAction.search,
                onChanged: (v) =>
                    setState(() => _query = v.trim().toLowerCase()),
                decoration: InputDecoration(
                  hintText: 'Search teachers...',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear',
                          icon: const Icon(Icons.close),
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _query = '');
                          },
                        ),
                  filled: true,
                  fillColor: Colors.white,
                  contentPadding: const EdgeInsets.symmetric(vertical: 16),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: CmColors.line),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: CmColors.line),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide:
                        const BorderSide(color: CmColors.navy, width: 1.5),
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _load,
              child: _buildBody(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return ListView(
        children: [
          const SizedBox(height: 120),
          Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  const Icon(Icons.error_outline, size: 48),
                  const SizedBox(height: 16),
                  Text(_error!, textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _load,
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    final visible = _teachers.where(_matches).toList();

    if (visible.isEmpty) {
      return ListView(
        children: [
          const SizedBox(height: 100),
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                children: [
                  Icon(
                    _teachers.isEmpty ? Icons.people_outline : Icons.search_off,
                    size: 56,
                    color: _teachers.isEmpty ? null : CmColors.slate,
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'No teachers found',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  if (_teachers.isEmpty) ...[
                    const SizedBox(height: 8),
                    const Text(
                      'Add a teacher account to get started.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: _showAddDialog,
                      icon: const Icon(Icons.add),
                      label: const Text('Add Teacher'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
      itemCount: visible.length,
      itemBuilder: (context, index) => _teacherCard(visible[index]),
    );
  }

  Widget _chip(String text, {Color? color, Color? background}) {
    final fg = color ?? CmColors.slate;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: background ?? CmColors.slate.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: fg,
        ),
      ),
    );
  }

  Widget _teacherCard(Map<String, dynamic> teacher) {
    final id = _tId(teacher);
    final busy = id != null && _busy.contains(id);
    final active = _tActive(teacher);
    final name = _tName(teacher);
    final email = _tEmail(teacher);
    final username = _tUsername(teacher);
    final assignments = _tAssignments(teacher);

    final meta = username.isNotEmpty ? '@$username' : '';

    return Card(
      elevation: 0,
      color: Colors.white,
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: CmColors.line),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: busy ? null : () => _showEditDialog(teacher),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: CmColors.navy.withValues(alpha: 0.07),
                foregroundColor: CmColors.navy,
                child: Text(
                  name.isNotEmpty ? name[0].toUpperCase() : '?',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          name,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: CmColors.navy,
                          ),
                        ),
                        active
                            ? _chip(
                                'Active',
                                color: _activeGreen,
                                background:
                                    _activeGreen.withValues(alpha: 0.14),
                              )
                            : _chip('Disabled'),
                      ],
                    ),
                    if (email.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          email,
                          style: const TextStyle(color: CmColors.slate),
                        ),
                      ),
                    if (meta.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          meta,
                          style: const TextStyle(
                            color: CmColors.slate,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    const SizedBox(height: 8),
                    if (assignments.isEmpty)
                      const Text(
                        'No assignments yet',
                        style: TextStyle(color: CmColors.slate, fontSize: 12),
                      )
                    else
                      for (final a in assignments)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text(
                                a.subjectName,
                                style: const TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w600,
                                  color: CmColors.navy,
                                ),
                              ),
                              for (final sec in (a.sections.values.toList()
                                ..sort((x, y) => x.section.compareTo(y.section))))
                                _chip(
                                  sec.section,
                                  color: CmColors.navy,
                                  background:
                                      CmColors.navy.withValues(alpha: 0.07),
                                ),
                            ],
                          ),
                        ),
                  ],
                ),
              ),
              if (busy)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else
                PopupMenuButton<String>(
                  tooltip: 'Actions',
                  onSelected: (action) => _onAction(action, teacher),
                  itemBuilder: (_) => [
                    _menuItem('edit', Icons.edit_outlined, 'Edit'),
                    _menuItem(
                        'sections', Icons.class_outlined, 'Assign Sections'),
                    _menuItem('reset', Icons.lock_reset, 'Reset Password'),
                    _menuItem(
                      'toggle',
                      active
                          ? Icons.block_outlined
                          : Icons.check_circle_outline,
                      active ? 'Disable Account' : 'Enable Account',
                    ),
                    _menuItem('delete', Icons.delete_outline, 'Delete',
                        danger: true),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  PopupMenuItem<String> _menuItem(
    String value,
    IconData icon,
    String label, {
    bool danger = false,
  }) {
    final color = danger ? _dangerRed : CmColors.navy;
    return PopupMenuItem<String>(
      value: value,
      child: Row(
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 12),
          Text(label, style: TextStyle(color: color)),
        ],
      ),
    );
  }
}

// =============================================================
// ADD / EDIT FORM
// =============================================================

class _TeacherInput {
  _TeacherInput({
    required this.name,
    required this.email,
    required this.username,
    required this.assignments,
    this.password,
  });

  final String name;
  final String email;
  final String username;
  final List<_SubjectAssignment> assignments;
  final String? password; // only set when creating
}

class _TeacherFormDialog extends StatefulWidget {
  const _TeacherFormDialog({
    required this.teachers,
    required this.subjects,
    required this.onSubmit,
    this.teacher,
  });

  final List<Map<String, dynamic>> teachers;
  final List<Map<String, dynamic>> subjects;
  final Map<String, dynamic>? teacher;
  final Future<void> Function(_TeacherInput input) onSubmit;

  @override
  State<_TeacherFormDialog> createState() => _TeacherFormDialogState();
}

class _TeacherFormDialogState extends State<_TeacherFormDialog> {
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();

  final _editorKey = GlobalKey<_AssignmentEditorState>();

  bool _usernameTouched = false;
  bool _saving = false;
  String? _error;

  bool get _isEdit => widget.teacher != null;
  int? get _editId => widget.teacher == null ? null : _tId(widget.teacher!);

  @override
  void initState() {
    super.initState();

    final t = widget.teacher;
    if (t != null) {
      _name.text = _tRawName(t);
      _email.text = _tEmail(t);
      _username.text = _tUsername(t);
      _usernameTouched = true;
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  // ---------- validation ----------

  String? _nameError(String raw) {
    final v = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (v.isEmpty) return 'Full name is required.';
    if (!RegExp(r"^[\p{L}][\p{L} .,'’\-]*$", unicode: true).hasMatch(v)) {
      return 'Use letters only.';
    }
    if (v.replaceAll(RegExp(r"[^\p{L}]", unicode: true), '').length < 2) {
      return 'Enter a valid full name.';
    }
    return null;
  }

  String? _emailError(String raw) {
    final base = StudentValidation.email(raw, required: true);
    if (base != null) return base;

    final e = raw.trim().toLowerCase();
    final taken = widget.teachers.any(
      (t) => _tId(t) != _editId && _tEmail(t).toLowerCase() == e,
    );
    return taken ? 'This email is already used by another teacher.' : null;
  }

  String? _usernameError(String raw) {
    final v = raw.trim().toLowerCase();
    if (v.isEmpty) return 'Username is required.';
    if (!RegExp(r'^[a-z0-9][a-z0-9._\-]{2,31}$').hasMatch(v)) {
      return 'Use 3–32 letters, numbers, dots, dashes or underscores.';
    }
    final taken = widget.teachers.any(
      (t) => _tId(t) != _editId && _tUsername(t).toLowerCase() == v,
    );
    return taken ? 'This username is already taken.' : null;
  }

  String? _passwordError(String raw) {
    if (_isEdit) return null;
    if (raw.isEmpty) return 'Temporary password is required.';
    if (raw.length < 8) return 'Use at least 8 characters.';
    return null;
  }

  // ---------- helpers ----------

  String _suggestUsername(String email) {
    final at = email.indexOf('@');
    final local = (at == -1 ? email : email.substring(0, at)).trim();
    return local.toLowerCase().replaceAll(RegExp(r'[^a-z0-9._\-]'), '');
  }

  static String _generatePassword() {
    const upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ';
    const lower = 'abcdefghijkmnopqrstuvwxyz';
    const digits = '23456789';
    const symbols = '!@#\$%&*?';
    final all = upper + lower + digits + symbols;
    final rnd = Random.secure();

    String pick(String s) => s[rnd.nextInt(s.length)];

    final chars = [
      pick(upper),
      pick(lower),
      pick(digits),
      pick(symbols),
      for (var i = 0; i < 8; i++) pick(all),
    ]..shuffle(rnd);

    return chars.join();
  }

  Future<void> _submit() async {
    if (_saving) return;

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      // Sections ticked but not yet added with "Add assignment" are
      // included, so nothing the admin selected is silently dropped.
      final editor = _editorKey.currentState;
      editor?.commitStaged();

      await widget.onSubmit(
        _TeacherInput(
          name: _name.text.replaceAll(RegExp(r'\s+'), ' ').trim(),
          email: _email.text.trim().toLowerCase(),
          username: _username.text.trim().toLowerCase(),
          assignments: editor?.assignments ?? const [],
          password: _isEdit ? null : _password.text,
        ),
      );

      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = _clean(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    String? shown(TextEditingController c, String? error) =>
        c.text.trim().isEmpty ? null : error;

    final nameError = _nameError(_name.text);
    final emailError = _emailError(_email.text);
    final usernameError = _usernameError(_username.text);
    final passwordError = _passwordError(_password.text);

    final valid = nameError == null &&
        emailError == null &&
        usernameError == null &&
        passwordError == null;

    return _dialogShell(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _dialogHeader(
            _isEdit ? 'Edit Teacher' : 'Add Teacher',
            _saving ? null : () => Navigator.pop(context, false),
          ),
          const SizedBox(height: 12),
          _labeled(
            'Full Name',
            TextField(
              controller: _name,
              enabled: !_saving,
              textCapitalization: TextCapitalization.words,
              inputFormatters: [LengthLimitingTextInputFormatter(80)],
              onChanged: (_) => setState(() {}),
              decoration: _fieldDecoration(errorText: shown(_name, nameError)),
            ),
          ),
          const SizedBox(height: 14),
          _labeled(
            'Email',
            TextField(
              controller: _email,
              enabled: !_saving,
              keyboardType: TextInputType.emailAddress,
              onChanged: (v) {
                setState(() {
                  if (!_usernameTouched) {
                    _username.text = _suggestUsername(v);
                  }
                });
              },
              decoration:
                  _fieldDecoration(errorText: shown(_email, emailError)),
            ),
          ),
          const SizedBox(height: 14),
          _labeled(
            'Username',
            TextField(
              controller: _username,
              enabled: !_saving,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9._\-]')),
                LengthLimitingTextInputFormatter(32),
              ],
              onChanged: (_) => setState(() => _usernameTouched = true),
              decoration:
                  _fieldDecoration(errorText: shown(_username, usernameError)),
            ),
          ),
          if (!_isEdit) ...[
            const SizedBox(height: 14),
            _labeled(
              'Temporary Password',
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _password,
                      enabled: !_saving,
                      onChanged: (_) => setState(() {}),
                      decoration: _fieldDecoration(
                        errorText: shown(_password, passwordError),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    height: 48,
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: CmColors.navy,
                        side: const BorderSide(color: CmColors.line),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: _saving
                          ? null
                          : () => setState(
                                () => _password.text = _generatePassword(),
                              ),
                      icon: const Icon(Icons.autorenew, size: 18),
                      label: const Text('Generate'),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 14),
          _AssignmentEditor(
            key: _editorKey,
            subjects: widget.subjects,
            initial:
                _isEdit ? _tAssignments(widget.teacher!) : const [],
            teacherId: _editId,
            enabled: !_saving,
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: _dangerRed),
            ),
          ],
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  style: _secondaryButtonStyle,
                  onPressed:
                      _saving ? null : () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  style: _primaryButtonStyle,
                  onPressed: valid && !_saving ? _submit : null,
                  child: _saving
                      ? _spinner()
                      : Text(
                          _isEdit ? 'Save Changes' : 'Create Teacher',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

}

// =============================================================
// ASSIGN SECTIONS
// =============================================================

class _AssignmentEditor extends StatefulWidget {
  const _AssignmentEditor({
    super.key,
    required this.subjects,
    required this.initial,
    this.teacherId,
    this.enabled = true,
  });

  final List<Map<String, dynamic>> subjects;
  final List<_SubjectAssignment> initial;

  /// The teacher being edited (null when creating). Sections owned by this
  /// teacher stay selectable; sections owned by anyone else are disabled.
  final int? teacherId;
  final bool enabled;

  @override
  State<_AssignmentEditor> createState() => _AssignmentEditorState();
}

class _AssignmentEditorState extends State<_AssignmentEditor> {
  late final Map<int, _SubjectAssignment> _draft = {
    for (final a in widget.initial)
      a.subjectId: _SubjectAssignment(
        subjectId: a.subjectId,
        subjectName: a.subjectName,
        sections: {...a.sections},
      ),
  };

  int? _subjectId;
  int _dropdownResets = 0;
  List<Map<String, dynamic>> _options = [];
  final Set<String> _staged = {};
  bool _loadingOptions = false;
  String? _optionsError;
  int _requestSeq = 0;

  /// The full set to save (call [commitStaged] first).
  List<_SubjectAssignment> get assignments => _draft.values.toList();

  String _subjectName(int id) {
    for (final s in widget.subjects) {
      if (int.tryParse(s['id']?.toString() ?? '') == id) {
        return (s['name'] ?? 'Subject').toString();
      }
    }
    return 'Subject';
  }

  String _optKey(Map<String, dynamic> o) =>
      '${(o['section'] ?? '').toString().toLowerCase()}|'
      '${(o['school_year'] ?? '').toString()}|'
      '${(o['semester'] ?? '').toString()}';

  bool _ownedByOther(Map<String, dynamic> o) {
    final owner = int.tryParse(o['teacher_id']?.toString() ?? '');
    return owner != null && owner != widget.teacherId;
  }

  bool get _stagedChanged {
    final id = _subjectId;
    if (id == null) return false;
    final current = _draft[id]?.sections.keys.toSet() ?? <String>{};
    return current.length != _staged.length || !current.containsAll(_staged);
  }

  Future<void> _pickSubject(int? id) async {
    setState(() {
      _subjectId = id;
      _options = [];
      _optionsError = null;
      _staged
        ..clear()
        ..addAll(
          id == null ? const <String>[] : (_draft[id]?.sections.keys ?? []),
        );
    });

    if (id != null) await _loadOptions(id);
  }

  Future<void> _loadOptions(int id) async {
    final seq = ++_requestSeq;

    setState(() {
      _loadingOptions = true;
      _optionsError = null;
    });

    try {
      final token = await AuthStorage.getToken();

      if (token == null || token.isEmpty) {
        throw Exception('Your session has expired. Please log in again.');
      }

      final rows = await ApiService.getTeachingOptions(token, id);

      if (!mounted || seq != _requestSeq) return;

      setState(() {
        _options = rows;
        _loadingOptions = false;
      });
    } catch (e) {
      if (!mounted || seq != _requestSeq) return;

      setState(() {
        _optionsError = _clean(e);
        _loadingOptions = false;
      });
    }
  }

  void _commit() {
    final id = _subjectId;
    if (id == null) return;

    final existing = _draft[id];

    if (_staged.isEmpty) {
      _draft.remove(id);
    } else {
      final sections = <String, _Sec>{};

      for (final o in _options) {
        final key = _optKey(o);
        if (!_staged.contains(key)) continue;

        sections[key] = _Sec(
          section: (o['section'] ?? '').toString(),
          schoolYear: (o['school_year'] ?? '').toString(),
          semester: (o['semester'] ?? '').toString(),
          yearLevel: int.tryParse(o['year_level']?.toString() ?? ''),
        );
      }

      for (final key in _staged) {
        final prev = existing?.sections[key];
        if (prev != null) sections.putIfAbsent(key, () => prev);
      }

      _draft[id] = _SubjectAssignment(
        subjectId: id,
        subjectName: _subjectName(id),
        sections: sections,
      );
    }

    _subjectId = null;
    _options = [];
    _staged.clear();
    _dropdownResets++;
  }

  /// Called by the parent right before saving.
  void commitStaged() {
    if (_subjectId != null && _stagedChanged) setState(_commit);
  }

  void _remove(int subjectId, String key) {
    setState(() {
      final a = _draft[subjectId];
      if (a == null) return;

      a.sections.remove(key);
      if (a.sections.isEmpty) _draft.remove(subjectId);
      if (_subjectId == subjectId) _staged.remove(key);
    });
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: CmColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Teaching assignments',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: CmColors.navy,
            ),
          ),
          const SizedBox(height: 12),
          _labeled(
            'Subject',
            DropdownButtonFormField<int>(
              key: ValueKey('subject-$_dropdownResets-$_subjectId'),
              initialValue: _subjectId,
              isExpanded: true,
              decoration: _fieldDecoration(),
              hint: const Text('Choose a subject'),
              items: [
                for (final s in widget.subjects)
                  if (int.tryParse(s['id']?.toString() ?? '') != null)
                    DropdownMenuItem<int>(
                      value: int.parse(s['id'].toString()),
                      child: Text(
                        (s['name'] ?? '').toString(),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
              ],
              onChanged: enabled ? _pickSubject : null,
            ),
          ),
          if (_subjectId != null) ...[
            const SizedBox(height: 14),
            _sectionsArea(enabled),
          ],
          const SizedBox(height: 14),
          _assignedList(enabled),
        ],
      ),
    );
  }

  Widget _sectionsArea(bool enabled) {
    if (_loadingOptions) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    if (_optionsError != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_optionsError!, style: const TextStyle(color: _dangerRed)),
          TextButton(
            onPressed: () => _loadOptions(_subjectId!),
            child: const Text('Retry'),
          ),
        ],
      );
    }

    if (_options.isEmpty) {
      return const Text(
        'No sections exist yet. Add sections in Classes first.',
        style: TextStyle(color: CmColors.slate),
      );
    }

    final groups = <int?, List<Map<String, dynamic>>>{};
    for (final o in _options) {
      groups
          .putIfAbsent(int.tryParse(o['year_level']?.toString() ?? ''), () => [])
          .add(o);
    }

    final years = groups.keys.toList()
      ..sort((a, b) {
        if (a == null) return 1;
        if (b == null) return -1;
        return a.compareTo(b);
      });

    return LayoutBuilder(
      builder: (context, constraints) {
        final itemWidth = (constraints.maxWidth - 8) / 2;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Sections / classes',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: CmColors.navy,
              ),
            ),
            for (final y in years) ...[
              Padding(
                padding: const EdgeInsets.only(top: 10, bottom: 2),
                child: Text(
                  _yearLabel(y),
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: CmColors.slate,
                  ),
                ),
              ),
              Wrap(
                spacing: 8,
                children: [
                  for (final o in groups[y]!)
                    SizedBox(
                      width: itemWidth,
                      child: _sectionTile(o, enabled),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 10),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: CmColors.navy,
                side: const BorderSide(color: CmColors.line),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onPressed:
                  enabled && _stagedChanged ? () => setState(_commit) : null,
              icon: const Icon(Icons.add, size: 18),
              label: Text(
                _draft.containsKey(_subjectId)
                    ? 'Update assignment'
                    : 'Add assignment',
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _sectionTile(Map<String, dynamic> o, bool enabled) {
    final key = _optKey(o);
    final blocked = _ownedByOther(o);
    final owner = (o['teacher_name'] ?? 'another teacher').toString();

    return CheckboxListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      activeColor: CmColors.navy,
      value: !blocked && _staged.contains(key),
      onChanged: (!enabled || blocked)
          ? null
          : (on) => setState(() {
                on == true ? _staged.add(key) : _staged.remove(key);
              }),
      title: Text(
        (o['section'] ?? '').toString(),
        style: TextStyle(
          fontSize: 14,
          color: blocked
              ? CmColors.slate.withValues(alpha: 0.6)
              : CmColors.navy,
        ),
      ),
      subtitle: blocked
          ? Text(
              'Assigned to $owner',
              style: const TextStyle(fontSize: 11.5, color: CmColors.slate),
            )
          : null,
    );
  }

  Widget _assignedList(bool enabled) {
    if (_draft.isEmpty) {
      return const Text(
        'No assignments yet. Choose a subject, tick its sections, then '
        'press "Add assignment".',
        style: TextStyle(fontSize: 12.5, color: CmColors.slate),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Assigned to this teacher',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: CmColors.navy,
          ),
        ),
        const SizedBox(height: 8),
        for (final a in _draft.values)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFF1F5F9),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  a.subjectName,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    color: CmColors.navy,
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final e in (a.sections.entries.toList()
                      ..sort((x, y) {
                        final byYear = (x.value.yearLevel ?? 99)
                            .compareTo(y.value.yearLevel ?? 99);
                        return byYear != 0
                            ? byYear
                            : x.value.section.compareTo(y.value.section);
                      })))
                      InputChip(
                        label: Text(e.value.section),
                        labelStyle: const TextStyle(fontSize: 12.5),
                        backgroundColor: Colors.white,
                        side: const BorderSide(color: CmColors.line),
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        onDeleted:
                            enabled ? () => _remove(a.subjectId, e.key) : null,
                      ),
                  ],
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _AssignSectionsDialog extends StatefulWidget {
  const _AssignSectionsDialog({
    required this.teacherName,
    required this.teacherId,
    required this.subjects,
    required this.initial,
    required this.onSave,
  });

  final String teacherName;
  final int teacherId;
  final List<Map<String, dynamic>> subjects;
  final List<_SubjectAssignment> initial;
  final Future<void> Function(List<_SubjectAssignment> list) onSave;

  @override
  State<_AssignSectionsDialog> createState() => _AssignSectionsDialogState();
}

class _AssignSectionsDialogState extends State<_AssignSectionsDialog> {
  final _editorKey = GlobalKey<_AssignmentEditorState>();
  bool _saving = false;
  String? _error;

  Future<void> _save() async {
    if (_saving) return;

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      final editor = _editorKey.currentState;
      editor?.commitStaged();

      await widget.onSave(editor?.assignments ?? const []);

      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = _clean(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return _dialogShell(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _dialogHeader(
            'Assign Sections',
            _saving ? null : () => Navigator.pop(context, false),
          ),
          Text(
            widget.teacherName,
            style: const TextStyle(color: CmColors.slate),
          ),
          const SizedBox(height: 12),
          _AssignmentEditor(
            key: _editorKey,
            subjects: widget.subjects,
            initial: widget.initial,
            teacherId: widget.teacherId,
            enabled: !_saving,
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: _dangerRed),
            ),
          ],
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  style: _secondaryButtonStyle,
                  onPressed:
                      _saving ? null : () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  style: _primaryButtonStyle,
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? _spinner()
                      : const Text(
                          'Save',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// =============================================================
// ONE-TIME CREDENTIALS
// =============================================================

class _Credentials {
  const _Credentials({
    required this.name,
    required this.username,
    required this.password,
  });

  final String name;
  final String username;
  final String password;
}

class _CredentialsDialog extends StatefulWidget {
  const _CredentialsDialog({required this.creds, required this.title});

  final _Credentials creds;
  final String title;

  @override
  State<_CredentialsDialog> createState() => _CredentialsDialogState();
}

class _CredentialsDialogState extends State<_CredentialsDialog> {
  bool _copied = false;

  Future<void> _copy() async {
    final c = widget.creds;
    await Clipboard.setData(
      ClipboardData(
        text: 'Username: ${c.username}\nTemporary password: ${c.password}',
      ),
    );
    if (!mounted) return;
    setState(() => _copied = true);
  }

  Widget _row(String label, String value, {bool mono = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 12, color: CmColors.slate),
          ),
          const SizedBox(height: 4),
          SelectableText(
            value,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: CmColors.navy,
              fontFamily: mono ? 'monospace' : null,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.creds;

    return _dialogShell(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.title,
            style: const TextStyle(
              fontSize: 19,
              fontWeight: FontWeight.w700,
              color: CmColors.navy,
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: CmColors.bg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: CmColors.line),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _row('Teacher', c.name),
                _row('Username', c.username.isEmpty ? '—' : c.username),
                _row('Temporary password', c.password, mono: true),
              ],
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Copy this now. The password will not be shown again, and the '
            'teacher must change it on first sign-in.',
            style: TextStyle(fontSize: 13, color: CmColors.slate),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  style: _secondaryButtonStyle,
                  onPressed: _copy,
                  icon: Icon(
                    _copied ? Icons.check : Icons.copy_outlined,
                    size: 18,
                  ),
                  label: Text(_copied ? 'Copied' : 'Copy'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  style: _primaryButtonStyle,
                  onPressed: () => Navigator.pop(context),
                  child: const Text(
                    'Done',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
