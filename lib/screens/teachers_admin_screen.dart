import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/api_service.dart';
import '../services/auth_storage.dart';
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

String _tFirst(Map<String, dynamic> t) =>
    (t['first_name'] ?? '').toString().trim();

String _tMiddle(Map<String, dynamic> t) =>
    (t['middle_name'] ?? '').toString().trim();

String _tLast(Map<String, dynamic> t) =>
    (t['last_name'] ?? '').toString().trim();

String _tTeacherId(Map<String, dynamic> t) =>
    (t['teacher_id_no'] ?? '').toString().trim();

String _tDepartment(Map<String, dynamic> t) =>
    (t['department'] ?? '').toString().trim();

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

/// Mirror of the server's name / email rules (teacher_identity.dart),
/// used for instant feedback. The server re-checks everything on save.
class _Identity {
  _Identity._();

  static const emailDomain = 'sti.checkmate.com';

  // Latin letters (accents allowed), spaces, hyphens, apostrophes, periods.
  static const _letter = 'A-Za-zÀ-ÖØ-öø-ÿĀ-ſ';
  static final _nameChars = RegExp("^[$_letter][$_letter .'’-]*\$");
  static final _lettersOnly = RegExp('[^$_letter]');
  static final _teacherId = RegExp(r'^\d{3,20}$');

  static const _fold = <String, String>{
    'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a', 'ā': 'a',
    'ă': 'a', 'ą': 'a', 'æ': 'ae', 'ç': 'c', 'ć': 'c', 'č': 'c', 'ď': 'd',
    'đ': 'd', 'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e', 'ē': 'e', 'ę': 'e',
    'ě': 'e', 'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i', 'ī': 'i', 'ł': 'l',
    'ñ': 'n', 'ń': 'n', 'ň': 'n', 'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o',
    'ö': 'o', 'ø': 'o', 'ō': 'o', 'œ': 'oe', 'ř': 'r', 'ś': 's', 'š': 's',
    'ş': 's', 'ß': 'ss', 'ť': 't', 'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u',
    'ū': 'u', 'ů': 'u', 'ý': 'y', 'ÿ': 'y', 'ź': 'z', 'ż': 'z', 'ž': 'z',
  };

  // ------------------------------------------------------------------
  // Name helpers
  // ------------------------------------------------------------------

  /// Trims and collapses repeated whitespace.
  static String collapse(String raw) =>
      raw.trim().replaceAll(RegExp(r'\s+'), ' ');

  /// "juan miguel dela cruz" -> "Juan Miguel Dela Cruz";
  /// "o'brien-REYES" -> "O'Brien-Reyes".
  static String titleCase(String input) {
    final out = StringBuffer();
    var startOfWord = true;

    for (final rune in input.runes) {
      final ch = String.fromCharCode(rune);

      if (' -\'’.'.contains(ch)) {
        out.write(ch);
        startOfWord = true;
      } else {
        out.write(startOfWord ? ch.toUpperCase() : ch.toLowerCase());
        startOfWord = false;
      }
    }

    return out.toString();
  }

  static String normalizeName(String raw) => titleCase(collapse(raw));

  /// Returns an error message, or null when the name is acceptable.
  static String? nameError(
    String raw, {
    required String label,
    required bool isRequired,
    int minLetters = 2,
  }) {
    final v = collapse(raw);

    if (v.isEmpty) return isRequired ? '$label is required.' : null;

    if (v.length > 50) return '$label must be 50 characters or fewer.';

    if (RegExp(r'[0-9]').hasMatch(v)) {
      return '$label cannot contain numbers.';
    }

    if (!_nameChars.hasMatch(v)) {
      return '$label can only contain letters, spaces, hyphens (-), '
          "apostrophes (') and periods (.).";
    }

    if (RegExp("[.'’-]{2,}|(^|\\s)[-'’]|[-'’](\\s|\$)").hasMatch(v)) {
      return '$label has misplaced punctuation.';
    }

    if (v.replaceAll(_lettersOnly, '').length < minLetters) {
      return minLetters > 1
          ? '$label is too short.'
          : '$label must contain a letter.';
    }

    return null;
  }

  static String? teacherIdError(String raw) {
    final v = raw.trim();

    if (v.isEmpty) return 'Teacher ID No. is required.';

    if (!_teacherId.hasMatch(v)) {
      return 'Teacher ID No. must contain 3–20 digits only.';
    }

    return null;
  }

  // ------------------------------------------------------------------
  // Email
  // ------------------------------------------------------------------

  /// Lowercase a-z / 0-9 only; accents are folded (ñ -> n); everything
  /// else (spaces, hyphens, apostrophes, periods) is dropped.
  static String slug(String input) {
    final out = StringBuffer();

    for (final rune in input.toLowerCase().runes) {
      final ch = String.fromCharCode(rune);
      final code = rune;

      final isLower = code >= 0x61 && code <= 0x7A;
      final isDigit = code >= 0x30 && code <= 0x39;

      if (isLower || isDigit) {
        out.write(ch);
      } else {
        final folded = _fold[ch];
        if (folded != null) out.write(folded);
      }
    }

    return out.toString();
  }

  /// surname.f.m.teacherid@sti.checkmate.com  (no middle name: surname.f.id)
  /// Returns null if a usable email cannot be built.
  static String? buildEmail({
    required String firstName,
    required String middleName,
    required String lastName,
    required String teacherIdNo,
  }) {
    final surname = slug(lastName);
    final first = slug(firstName);
    final middle = slug(middleName);
    final id = teacherIdNo.trim().toLowerCase();

    if (surname.isEmpty || first.isEmpty || id.isEmpty) return null;

    final local = [
      surname,
      first[0],
      if (middle.isNotEmpty) middle[0],
      id,
    ].join('.');

    return '$local@$emailDomain';
  }
}

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
  List<String> _departments = [];

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

      final (teachers, subjects, departments) = await (
        ApiService.getTeachers(token),
        ApiService.getSubjects(token),
        ApiService.getTeacherDepartments(token),
      ).wait;

      if (!mounted) return;

      setState(() {
        _teachers = teachers;
        _subjects = subjects;
        _departments = departments;
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
        _tFirst(t).toLowerCase().contains(_query) ||
        _tMiddle(t).toLowerCase().contains(_query) ||
        _tLast(t).toLowerCase().contains(_query) ||
        _tTeacherId(t).toLowerCase().contains(_query) ||
        _tEmail(t).toLowerCase().contains(_query) ||
        _tUsername(t).toLowerCase().contains(_query) ||
        _tDepartment(t).toLowerCase().contains(_query) ||
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
        departments: _departments,
        onSubmit: (input) async {
          final token = await _token();

          final created = await ApiService.createTeacher(
            token: token,
            teacherIdNo: input.teacherIdNo,
            firstName: input.firstName,
            middleName: input.middleName,
            lastName: input.lastName,
            department: input.department,
            temporaryPassword: input.password!,
            assignments: _assignmentPayload(input.assignments),
          );

          // The login is the institutional email the server generated.
          creds = _Credentials(
            name: _tName(created),
            username:
                _tEmail(created).isEmpty ? input.email : _tEmail(created),
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
    final oldEmail = _tEmail(teacher);
    String? newEmail;

    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _TeacherFormDialog(
        teachers: _teachers,
        subjects: _subjects,
        departments: _departments,
        teacher: teacher,
        onSubmit: (input) async {
          final token = await _token();

          // Profile, status and assignments are saved in ONE server
          // transaction, so a conflict saves nothing. The server regenerates
          // the institutional email when the ID or a name part changed.
          final updated = await ApiService.updateTeacher(
            token: token,
            teacherId: id,
            teacherIdNo: input.teacherIdNo,
            firstName: input.firstName,
            middleName: input.middleName,
            lastName: input.lastName,
            department: input.department,
            isActive: input.isActive != _tActive(teacher)
                ? input.isActive
                : null,
            assignments: _assignmentsChanged(before, input.assignments)
                ? _assignmentPayload(input.assignments)
                : null,
          );

          newEmail = _tEmail(updated);
        },
      ),
    );

    if (ok != true) return;

    await _load(silent: true);
    if (!mounted) return;

    final changed = newEmail != null &&
        newEmail!.isNotEmpty &&
        newEmail!.toLowerCase() != oldEmail.toLowerCase();

    _snack(
      changed
          ? 'Teacher updated. Login email is now $newEmail.'
          : 'Teacher updated.',
    );
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
          username: _tEmail(teacher).isEmpty
              ? _tUsername(teacher)
              : _tEmail(teacher),
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

    final released = _tAssignments(teacher)
        .fold<int>(0, (n, a) => n + a.sections.length);

    final confirmed = await _confirm(
      title: 'Delete ${_tName(teacher)}?',
      message: released == 0
          ? 'This permanently deletes the teacher account. This cannot be '
              'undone.'
          : 'This permanently deletes the teacher account. Its $released '
              'section assignment${released == 1 ? '' : 's'} will be '
              'released so another teacher can take them. The sections, '
              'students and exams are kept. This cannot be undone.',
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
    final assignments = _tAssignments(teacher);

    final teacherNo = _tTeacherId(teacher);
    final department = _tDepartment(teacher);
    final incomplete = teacherNo.isEmpty || department.isEmpty;

    final meta = [
      if (teacherNo.isNotEmpty) 'ID $teacherNo',
      if (department.isNotEmpty) department,
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
                        if (incomplete)
                          _chip(
                            'Profile incomplete',
                            color: const Color(0xFFB45309),
                            background: const Color(0xFFFEF3C7),
                          ),
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
    required this.teacherIdNo,
    required this.firstName,
    required this.middleName,
    required this.lastName,
    required this.email,
    required this.department,
    required this.assignments,
    required this.isActive,
    this.password,
  });

  final String teacherIdNo;
  final String firstName;
  final String middleName;
  final String lastName;
  final String email; // generated; shown to the admin, regenerated server-side
  final String department;
  final List<_SubjectAssignment> assignments;
  final bool isActive;
  final String? password; // only set when creating
}

class _TeacherFormDialog extends StatefulWidget {
  const _TeacherFormDialog({
    required this.teachers,
    required this.subjects,
    required this.departments,
    required this.onSubmit,
    this.teacher,
  });

  final List<Map<String, dynamic>> teachers;
  final List<Map<String, dynamic>> subjects;
  final List<String> departments;
  final Map<String, dynamic>? teacher;
  final Future<void> Function(_TeacherInput input) onSubmit;

  @override
  State<_TeacherFormDialog> createState() => _TeacherFormDialogState();
}

class _TeacherFormDialogState extends State<_TeacherFormDialog> {
  final _teacherNo = TextEditingController();
  final _first = TextEditingController();
  final _middle = TextEditingController();
  final _last = TextEditingController();
  final _password = TextEditingController();

  final _editorKey = GlobalKey<_AssignmentEditorState>();

  String? _department;
  bool _active = true;
  bool _saving = false;
  String? _error;

  bool get _isEdit => widget.teacher != null;
  int? get _editId => widget.teacher == null ? null : _tId(widget.teacher!);

  /// An account created before Teacher IDs / split names existed.
  bool get _legacy =>
      _isEdit && (_tTeacherId(widget.teacher!).isEmpty ||
          _tFirst(widget.teacher!).isEmpty);

  @override
  void initState() {
    super.initState();

    final t = widget.teacher;
    if (t != null) {
      _teacherNo.text = _tTeacherId(t);
      _first.text = _tFirst(t);
      _middle.text = _tMiddle(t);
      _last.text = _tLast(t);
      _active = _tActive(t);

      final dept = _tDepartment(t);
      _department = widget.departments.contains(dept) ? dept : null;
    }
  }

  @override
  void dispose() {
    _teacherNo.dispose();
    _first.dispose();
    _middle.dispose();
    _last.dispose();
    _password.dispose();
    super.dispose();
  }

  // ---------- validation ----------

  String? _teacherNoError(String raw) {
    final base = _Identity.teacherIdError(raw);
    if (base != null) return base;

    final v = raw.trim().toLowerCase();
    final taken = widget.teachers.any(
      (t) => _tId(t) != _editId && _tTeacherId(t).toLowerCase() == v,
    );

    return taken ? 'This Teacher ID No. already belongs to another teacher.' : null;
  }

  String? _firstError(String raw) =>
      _Identity.nameError(raw, label: 'First name', isRequired: true);

  String? _middleError(String raw) => _Identity.nameError(
        raw,
        label: 'Middle name',
        isRequired: false,
        minLetters: 1,
      );

  String? _lastError(String raw) =>
      _Identity.nameError(raw, label: 'Last name', isRequired: true);

  String? _passwordError(String raw) {
    if (_isEdit) return null;
    if (raw.isEmpty) return 'Temporary password is required.';
    if (raw.length < 8) return 'Use at least 8 characters.';
    return null;
  }

  String? _generatedEmail() {
    if (_teacherNoError(_teacherNo.text) != null ||
        _firstError(_first.text) != null ||
        _middleError(_middle.text) != null ||
        _lastError(_last.text) != null) {
      return null;
    }

    final email = _Identity.buildEmail(
      firstName: _Identity.normalizeName(_first.text),
      middleName: _Identity.normalizeName(_middle.text),
      lastName: _Identity.normalizeName(_last.text),
      teacherIdNo: _teacherNo.text,
    );

    if (email == null || email.split('@').first.length > 64) return null;

    return email;
  }

  String? _emailError(String? email) {
    if (email == null) return null;

    final taken = widget.teachers.any(
      (t) =>
          _tId(t) != _editId &&
          (_tEmail(t).toLowerCase() == email ||
              _tUsername(t).toLowerCase() == email),
    );

    return taken ? 'The generated email is already used by another account.' : null;
  }

  // ---------- helpers ----------

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

  /// Name fields tidy themselves (capitalisation, spaces) when you leave them.
  Widget _nameField(
    TextEditingController controller,
    String? error,
  ) {
    return Focus(
      onFocusChange: (hasFocus) {
        if (!hasFocus) {
          setState(() {
            controller.text = _Identity.normalizeName(controller.text);
          });
        }
      },
      child: TextField(
        controller: controller,
        enabled: !_saving,
        textCapitalization: TextCapitalization.words,
        inputFormatters: [LengthLimitingTextInputFormatter(60)],
        onChanged: (_) => setState(() {}),
        decoration: _fieldDecoration(
          errorText: controller.text.trim().isEmpty ? null : error,
        ),
      ),
    );
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
          teacherIdNo: _teacherNo.text.trim(),
          firstName: _Identity.normalizeName(_first.text),
          middleName: _Identity.normalizeName(_middle.text),
          lastName: _Identity.normalizeName(_last.text),
          email: _generatedEmail() ?? '',
          department: _department!,
          assignments: editor?.assignments ?? const [],
          isActive: _active,
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
    final teacherNoError = _teacherNoError(_teacherNo.text);
    final firstError = _firstError(_first.text);
    final middleError = _middleError(_middle.text);
    final lastError = _lastError(_last.text);
    final passwordError = _passwordError(_password.text);

    final email = _generatedEmail();
    final emailError = _emailError(email);

    final oldEmail = _isEdit ? _tEmail(widget.teacher!).toLowerCase() : '';
    final emailWillChange =
        _isEdit && email != null && oldEmail.isNotEmpty && email != oldEmail;

    final valid = teacherNoError == null &&
        firstError == null &&
        middleError == null &&
        lastError == null &&
        email != null &&
        emailError == null &&
        _department != null &&
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
          if (_legacy) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFFEF3C7),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                'This account (${_tName(widget.teacher!)}) was created before '
                'Teacher IDs and separate name fields existed. Enter the '
                'details below to complete the profile. Saving will change '
                'the login email to the generated institutional address.',
                style: const TextStyle(fontSize: 12.5, color: Color(0xFF92400E)),
              ),
            ),
          ],
          const SizedBox(height: 12),
          _labeled(
            'Teacher ID No.',
            TextField(
              controller: _teacherNo,
              enabled: !_saving,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(20),
              ],
              onChanged: (_) => setState(() {}),
              decoration: _fieldDecoration(
                errorText:
                    _teacherNo.text.trim().isEmpty ? null : teacherNoError,
              ),
            ),
          ),
          const SizedBox(height: 14),
          _labeled('First Name', _nameField(_first, firstError)),
          const SizedBox(height: 14),
          _labeled('Middle Name (optional)', _nameField(_middle, middleError)),
          const SizedBox(height: 14),
          _labeled('Last Name', _nameField(_last, lastError)),
          const SizedBox(height: 14),
          _labeled(
            'Institutional Email (generated)',
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: double.infinity,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                  decoration: BoxDecoration(
                    color: CmColors.bg,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: emailError == null ? CmColors.line : _dangerRed,
                    ),
                  ),
                  child: SelectableText(
                    email ?? 'Enter the Teacher ID and name to generate it',
                    style: TextStyle(
                      color: email == null ? CmColors.slate : CmColors.navy,
                      fontWeight:
                          email == null ? FontWeight.w400 : FontWeight.w600,
                    ),
                  ),
                ),
                if (emailError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6, left: 4),
                    child: Text(
                      emailError,
                      style: const TextStyle(color: _dangerRed, fontSize: 12),
                    ),
                  )
                else if (emailWillChange)
                  Padding(
                    padding: const EdgeInsets.only(top: 6, left: 4),
                    child: Text(
                      'The login email will change from '
                      '${_tEmail(widget.teacher!)}. Tell the teacher.',
                      style: const TextStyle(
                        color: Color(0xFFB45309),
                        fontSize: 12,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _labeled(
            'Department',
            widget.departments.isEmpty
                ? const Text(
                    'No departments available.',
                    style: TextStyle(color: CmColors.slate),
                  )
                : DropdownButtonFormField<String>(
                    initialValue: _department,
                    isExpanded: true,
                    decoration: _fieldDecoration(),
                    hint: const Text('Choose a department'),
                    items: [
                      for (final d in widget.departments)
                        DropdownMenuItem<String>(
                          value: d,
                          child: Text(d, overflow: TextOverflow.ellipsis),
                        ),
                    ],
                    onChanged: _saving
                        ? null
                        : (value) => setState(() => _department = value),
                  ),
          ),
          const SizedBox(height: 14),
          _AssignmentEditor(
            key: _editorKey,
            subjects: widget.subjects,
            initial: _isEdit ? _tAssignments(widget.teacher!) : const [],
            teacherId: _editId,
            enabled: !_saving,
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
                        errorText: _password.text.trim().isEmpty
                            ? null
                            : passwordError,
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
          if (_isEdit) ...[
            const SizedBox(height: 10),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _active,
              onChanged: _saving ? null : (v) => setState(() => _active = v),
              title: const Text('Account active'),
              subtitle: Text(
                _active
                    ? 'The teacher can sign in.'
                    : 'Disabled: the teacher cannot sign in or use the app.',
                style: const TextStyle(fontSize: 12.5, color: CmColors.slate),
              ),
            ),
          ],
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
// SECTION ASSIGNMENTS (Subject + Section)
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
            'Section Assignments',
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
              'Sections',
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
        text: 'Login: ${c.username}\nTemporary password: ${c.password}',
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
                _row('Login (email)', c.username.isEmpty ? '—' : c.username),
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
