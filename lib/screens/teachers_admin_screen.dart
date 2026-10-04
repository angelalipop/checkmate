import 'dart:math';

import 'package:flutter/foundation.dart' show setEquals;
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

int? _tSubjectId(Map<String, dynamic> t) {
  final s = t['subject'];
  final raw = t['subject_id'] ?? (s is Map ? s['id'] : null);
  return int.tryParse(raw?.toString() ?? '');
}

Set<int> _tAssigned(Map<String, dynamic> t) {
  final out = <int>{};

  final ids = t['class_ids'];
  if (ids is List) {
    for (final i in ids) {
      final v = int.tryParse(i.toString());
      if (v != null) out.add(v);
    }
  }

  final classes = t['classes'];
  if (classes is List) {
    for (final c in classes) {
      final raw = c is Map ? c['id'] : c;
      final v = int.tryParse(raw?.toString() ?? '');
      if (v != null) out.add(v);
    }
  }

  return out;
}

String _classLabel(Map<String, dynamic> item) {
  final section = item['section']?.toString() ?? 'Unknown Section';
  final subject = item['subject'];

  if (subject is! Map) return section;

  final name = subject['name']?.toString() ?? 'Unknown Subject';
  final code = subject['code']?.toString() ?? '';

  return code.isEmpty ? '$section - $name' : '$section - $code - $name';
}

String _subjectText(Map<String, dynamic> s) {
  final name = s['name']?.toString() ?? '';
  final code = s['code']?.toString() ?? '';
  if (name.isEmpty) return code;
  return code.isEmpty ? name : '$code - $name';
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
  List<Map<String, dynamic>> _classes = [];
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
        ApiService.getClasses(token),
        ApiService.getSubjects(token),
      ]);

      if (!mounted) return;

      setState(() {
        _teachers = results[0];
        _classes = results[1];
        _subjects = results[2];
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

  Map<String, dynamic>? _classById(int id) {
    for (final c in _classes) {
      if (int.tryParse(c['id']?.toString() ?? '') == id) return c;
    }
    return null;
  }

  String _subjectLabel(Map<String, dynamic> t) {
    final s = t['subject'];
    if (s is Map) return _subjectText(Map<String, dynamic>.from(s));
    if (s is String && s.trim().isNotEmpty) return s.trim();

    final id = _tSubjectId(t);
    if (id != null) {
      for (final sub in _subjects) {
        if (int.tryParse(sub['id']?.toString() ?? '') == id) {
          return _subjectText(sub);
        }
      }
    }
    return '';
  }

  bool _matches(Map<String, dynamic> t) {
    if (_query.isEmpty) return true;

    return _tName(t).toLowerCase().contains(_query) ||
        _tEmail(t).toLowerCase().contains(_query) ||
        _tUsername(t).toLowerCase().contains(_query) ||
        _subjectLabel(t).toLowerCase().contains(_query);
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
        classes: _classes,
        subjects: _subjects,
        onSubmit: (input) async {
          final token = await _token();

          final created = await ApiService.createTeacher(
            token: token,
            name: input.name,
            email: input.email,
            username: input.username,
            subjectId: input.subjectId,
            temporaryPassword: input.password!,
            classIds: input.classIds.toList(),
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

    final before = _tAssigned(teacher);

    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _TeacherFormDialog(
        teachers: _teachers,
        classes: _classes,
        subjects: _subjects,
        teacher: teacher,
        onSubmit: (input) async {
          final token = await _token();

          await ApiService.updateTeacher(
            token: token,
            teacherId: id,
            name: input.name,
            email: input.email,
            username: input.username,
            subjectId: input.subjectId,
          );

          if (!setEquals(before, input.classIds)) {
            await ApiService.setTeacherClasses(
              token: token,
              teacherId: id,
              classIds: input.classIds.toList(),
            );
          }
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
        classes: _classes,
        initial: _tAssigned(teacher),
        onSave: (ids) async {
          final token = await _token();
          await ApiService.setTeacherClasses(
            token: token,
            teacherId: id,
            classIds: ids.toList(),
          );
        },
      ),
    );

    if (ok != true) return;

    await _load(silent: true);
    if (!mounted) return;
    _snack('Sections updated.');
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
    final subject = _subjectLabel(teacher);
    final assigned = _tAssigned(teacher).toList()..sort();

    final meta = [
      if (username.isNotEmpty) '@$username',
      if (subject.isNotEmpty) subject,
    ].join('  •  ');

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
                    if (assigned.isEmpty)
                      const Text(
                        'No sections assigned',
                        style: TextStyle(color: CmColors.slate, fontSize: 12),
                      )
                    else
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final classId in assigned)
                            Tooltip(
                              message: _classById(classId) == null
                                  ? 'Unknown section'
                                  : _classLabel(_classById(classId)!),
                              child: _chip(
                                _classById(classId)?['section']?.toString() ??
                                    'Unknown',
                                color: CmColors.navy,
                                background:
                                    CmColors.navy.withValues(alpha: 0.07),
                              ),
                            ),
                        ],
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
    required this.subjectId,
    required this.classIds,
    this.password,
  });

  final String name;
  final String email;
  final String username;
  final int? subjectId;
  final Set<int> classIds;
  final String? password; // only set when creating
}

class _TeacherFormDialog extends StatefulWidget {
  const _TeacherFormDialog({
    required this.teachers,
    required this.classes,
    required this.subjects,
    required this.onSubmit,
    this.teacher,
  });

  final List<Map<String, dynamic>> teachers;
  final List<Map<String, dynamic>> classes;
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

  int? _subjectId;
  final Set<int> _classIds = {};

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
      _classIds.addAll(_tAssigned(t));

      final sid = _tSubjectId(t);
      final exists = widget.subjects
          .any((s) => int.tryParse(s['id']?.toString() ?? '') == sid);
      _subjectId = exists ? sid : null;
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
      final validIds = widget.classes
          .map((c) => int.tryParse(c['id']?.toString() ?? ''))
          .whereType<int>()
          .toSet();

      await widget.onSubmit(
        _TeacherInput(
          name: _name.text.replaceAll(RegExp(r'\s+'), ' ').trim(),
          email: _email.text.trim().toLowerCase(),
          username: _username.text.trim().toLowerCase(),
          subjectId: _subjectId,
          classIds: _classIds.where(validIds.contains).toSet(),
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
          const SizedBox(height: 14),
          _labeled(
            'Subject',
            DropdownButtonFormField<int?>(
              initialValue: _subjectId,
              isExpanded: true,
              decoration: _fieldDecoration(),
              items: [
                const DropdownMenuItem<int?>(
                  value: null,
                  child: Text('No subject'),
                ),
                ...widget.subjects.map((s) {
                  final id = int.tryParse(s['id']?.toString() ?? '');
                  return DropdownMenuItem<int?>(
                    value: id,
                    child: Text(
                      _subjectText(s),
                      overflow: TextOverflow.ellipsis,
                    ),
                  );
                }),
              ],
              onChanged: _saving
                  ? null
                  : (value) => setState(() => _subjectId = value),
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
          _labeled('Sections', _sectionPicker()),
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

  Widget _sectionPicker() {
    if (widget.classes.isEmpty) {
      return const Text(
        'No sections available yet.',
        style: TextStyle(color: CmColors.slate),
      );
    }

    return Container(
      constraints: const BoxConstraints(maxHeight: 150),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: CmColors.line),
      ),
      child: SingleChildScrollView(
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final c in widget.classes)
              Builder(builder: (context) {
                final id = int.tryParse(c['id']?.toString() ?? '');
                if (id == null) return const SizedBox.shrink();
                final selected = _classIds.contains(id);

                return FilterChip(
                  label: Text(_classLabel(c)),
                  selected: selected,
                  showCheckmark: true,
                  selectedColor: CmColors.navy.withValues(alpha: 0.12),
                  onSelected: _saving
                      ? null
                      : (on) => setState(() {
                            on ? _classIds.add(id) : _classIds.remove(id);
                          }),
                );
              }),
          ],
        ),
      ),
    );
  }
}

// =============================================================
// ASSIGN SECTIONS
// =============================================================

class _AssignSectionsDialog extends StatefulWidget {
  const _AssignSectionsDialog({
    required this.teacherName,
    required this.classes,
    required this.initial,
    required this.onSave,
  });

  final String teacherName;
  final List<Map<String, dynamic>> classes;
  final Set<int> initial;
  final Future<void> Function(Set<int> ids) onSave;

  @override
  State<_AssignSectionsDialog> createState() => _AssignSectionsDialogState();
}

class _AssignSectionsDialogState extends State<_AssignSectionsDialog> {
  late final Set<int> _selected = {...widget.initial};
  bool _saving = false;
  String? _error;

  Future<void> _save() async {
    if (_saving) return;

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      await widget.onSave(_selected);
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
          if (widget.classes.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: Text('No sections available yet.')),
            )
          else
            Container(
              constraints: const BoxConstraints(maxHeight: 320),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: CmColors.line),
              ),
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final c in widget.classes)
                    Builder(builder: (context) {
                      final id = int.tryParse(c['id']?.toString() ?? '');
                      if (id == null) return const SizedBox.shrink();

                      return CheckboxListTile(
                        value: _selected.contains(id),
                        activeColor: CmColors.navy,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: Text(_classLabel(c)),
                        onChanged: _saving
                            ? null
                            : (on) => setState(() {
                                  on == true
                                      ? _selected.add(id)
                                      : _selected.remove(id);
                                }),
                      );
                    }),
                ],
              ),
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
