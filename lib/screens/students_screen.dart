import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/api_service.dart';
import '../services/auth_storage.dart';
import '../services/student_import_service.dart' show StudentValidation;
import 'import_students_screen.dart';
import 'login_screen.dart' show CmColors;

class StudentsScreen extends StatefulWidget {
  const StudentsScreen({
    super.key,
    this.isTeacher = false,
    this.initialClassId,
  });

  /// Teacher mode changes what the import flow asks for (no Teacher field).
  final bool isTeacher;

  /// Pre-select a class/section (used when tapping a class on Classes).
  final int? initialClassId;

  @override
  State<StudentsScreen> createState() => _StudentsScreenState();
}

class _StudentsScreenState extends State<StudentsScreen> {
  List<Map<String, dynamic>> _students = [];
  List<Map<String, dynamic>> _classes = [];

  int? _selectedClassId;

  final _searchController = TextEditingController();
  String _query = '';

  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _selectedClassId = widget.initialClassId;
    _loadData();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final token = await AuthStorage.getToken();

      if (token == null || token.isEmpty) {
        throw Exception('Authentication token not found.');
      }

      final results = await Future.wait([
        ApiService.getStudents(
          token,
          classId: _selectedClassId,
        ),
        ApiService.getClasses(token),
      ]);

      if (!mounted) return;

      setState(() {
        _students =
            results[0];
        _classes =
            results[1];
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _error =
            e.toString().replaceFirst('Exception: ', '');
        _loading = false;
      });
    }
  }

  // =========================
  // INPUT STYLE (shared by the dialogs)
  // =========================

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
      errorBorder: border(const Color(0xFFDC2626)),
      focusedErrorBorder: border(const Color(0xFFDC2626), 1.5),
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
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      );

  ButtonStyle get _secondaryButtonStyle => OutlinedButton.styleFrom(
        foregroundColor: CmColors.navy,
        backgroundColor: CmColors.bg,
        side: const BorderSide(color: CmColors.line),
        minimumSize: const Size.fromHeight(50),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      );

  static final _nameFormatter = FilteringTextInputFormatter.allow(
    RegExp(r"[\p{L} .'’\-]", unicode: true),
  );

  // =========================
  // ADD STUDENT MANUALLY
  // =========================

  Future<void> _showAddStudentDialog() async {
    int? selectedClassId = _selectedClassId;

    final studentNumberController = TextEditingController();
    final lastNameController = TextEditingController();
    final firstNameController = TextEditingController();

    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        bool saving = false;
        String? dialogError;

        return StatefulBuilder(
          builder: (context, setDialogState) {
            // Error text only appears once the field has something in it.
            String? shown(TextEditingController c, String? error) =>
                c.text.trim().isEmpty ? null : error;

            final numberError =
                StudentValidation.studentNumber(studentNumberController.text);
            final lastError = StudentValidation.name(
              lastNameController.text,
              label: 'Last name',
            );
            final firstError = StudentValidation.name(
              firstNameController.text,
              label: 'First name',
            );

            final valid = selectedClassId != null &&
                numberError == null &&
                lastError == null &&
                firstError == null;

            Future<void> saveStudent() async {
              if (!valid) return;

              setDialogState(() {
                saving = true;
                dialogError = null;
              });

              try {
                final token = await AuthStorage.getToken();

                if (token == null || token.isEmpty) {
                  throw Exception('Authentication token not found.');
                }

                String clean(String v) =>
                    v.replaceAll(RegExp(r'\s+'), ' ').trim();


                await ApiService.createStudent(
                  token: token,
                  classId: selectedClassId!,
                  studentNumber: studentNumberController.text.trim(),
                  firstName: clean(firstNameController.text),
                  lastName: clean(lastNameController.text),
                  email: null,
                );

                if (!context.mounted) return;

                Navigator.pop(context, true);
              } catch (e) {
                setDialogState(() {
                  saving = false;
                  dialogError =
                      e.toString().replaceFirst('Exception: ', '');
                });
              }
            }

            return Dialog(
              backgroundColor: Colors.white,
              surfaceTintColor: Colors.transparent,
              insetPadding: const EdgeInsets.all(24),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'Add Student Manually',
                              style: TextStyle(
                                fontSize: 19,
                                fontWeight: FontWeight.w700,
                                color: CmColors.navy,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Close',
                            icon: const Icon(Icons.close, size: 20),
                            onPressed: saving
                                ? null
                                : () => Navigator.pop(context, false),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      _labeled(
                        'Student Number',
                        TextField(
                          controller: studentNumberController,
                          enabled: !saving,
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                            LengthLimitingTextInputFormatter(15),
                          ],
                          onChanged: (_) => setDialogState(() {}),
                          decoration: _fieldDecoration(
                            errorText: shown(
                                studentNumberController, numberError),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      _labeled(
                        'Last Name',
                        TextField(
                          controller: lastNameController,
                          enabled: !saving,
                          textCapitalization: TextCapitalization.words,
                          inputFormatters: [
                            _nameFormatter,
                            LengthLimitingTextInputFormatter(50),
                          ],
                          onChanged: (_) => setDialogState(() {}),
                          decoration: _fieldDecoration(
                            errorText: shown(lastNameController, lastError),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      _labeled(
                        'First Name',
                        TextField(
                          controller: firstNameController,
                          enabled: !saving,
                          textCapitalization: TextCapitalization.words,
                          inputFormatters: [
                            _nameFormatter,
                            LengthLimitingTextInputFormatter(50),
                          ],
                          onChanged: (_) => setDialogState(() {}),
                          decoration: _fieldDecoration(
                            errorText: shown(firstNameController, firstError),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      _labeled(
                        'Section',
                        DropdownButtonFormField<int>(
                          initialValue: selectedClassId,
                          isExpanded: true,
                          decoration: _fieldDecoration(),
                          items: _classes.map((item) {
                            final id = int.parse(item['id'].toString());
                            return DropdownMenuItem<int>(
                              value: id,
                              child: Text(
                                _getClassLabel(item),
                                overflow: TextOverflow.ellipsis,
                              ),
                            );
                          }).toList(),
                          onChanged: saving
                              ? null
                              : (value) => setDialogState(() {
                                    selectedClassId = value;
                                  }),
                        ),
                      ),
                      if (dialogError != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          dialogError!,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ],
                      const SizedBox(height: 20),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              style: _secondaryButtonStyle,
                              onPressed: saving
                                  ? null
                                  : () => Navigator.pop(context, false),
                              child: const Text('Cancel'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: FilledButton(
                              style: _primaryButtonStyle,
                              onPressed: valid && !saving ? saveStudent : null,
                              child: saving
                                  ? const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Text(
                                      'Add Student',
                                      style: TextStyle(
                                          fontWeight: FontWeight.w700),
                                    ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );

    studentNumberController.dispose();
    lastNameController.dispose();
    firstNameController.dispose();

    if (result == true) {
      await _loadData();

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Student added successfully.'),
        ),
      );
    }
  }

  // =========================
  // ADD / EDIT STUDENT INFO (email, not available from Excel)
  // =========================

  Future<void> _showAddInfoDialog(Map<String, dynamic> student) async {
    final id = int.tryParse(student['id']?.toString() ?? '');
    if (id == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This student cannot be updated.')),
      );
      return;
    }

    final emailController = TextEditingController(
      text: student['email']?.toString() ?? '',
    );

    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        bool saving = false;
        String? dialogError;

        return StatefulBuilder(
          builder: (context, setDialogState) {
            final emailError = StudentValidation.email(
              emailController.text,
              required: true,
            );

            Future<void> save() async {
              setDialogState(() {
                saving = true;
                dialogError = null;
              });

              try {
                final token = await AuthStorage.getToken();

                if (token == null || token.isEmpty) {
                  throw Exception('Authentication token not found.');
                }

                await ApiService.updateStudent(
                  token: token,
                  studentId: id,
                  email: emailController.text.trim(),
                );

                if (!context.mounted) return;

                Navigator.pop(context, true);
              } catch (e) {
                setDialogState(() {
                  saving = false;
                  dialogError =
                      e.toString().replaceFirst('Exception: ', '');
                });
              }
            }

            return Dialog(
              backgroundColor: Colors.white,
              surfaceTintColor: Colors.transparent,
              insetPadding: const EdgeInsets.all(24),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'Add Student Info',
                              style: TextStyle(
                                fontSize: 19,
                                fontWeight: FontWeight.w700,
                                color: CmColors.navy,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Close',
                            icon: const Icon(Icons.close, size: 20),
                            onPressed: saving
                                ? null
                                : () => Navigator.pop(context, false),
                          ),
                        ],
                      ),
                      Text(
                        _fullName(student),
                        style: const TextStyle(color: CmColors.slate),
                      ),
                      const SizedBox(height: 16),
                      _labeled(
                        'Email',
                        TextField(
                          controller: emailController,
                          enabled: !saving,
                          keyboardType: TextInputType.emailAddress,
                          onChanged: (_) => setDialogState(() {}),
                          decoration: _fieldDecoration(
                            errorText: emailController.text.trim().isEmpty
                                ? null
                                : emailError,
                          ),
                        ),
                      ),
                      if (dialogError != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          dialogError!,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ],
                      const SizedBox(height: 20),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              style: _secondaryButtonStyle,
                              onPressed: saving
                                  ? null
                                  : () => Navigator.pop(context, false),
                              child: const Text('Cancel'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: FilledButton(
                              style: _primaryButtonStyle,
                              onPressed:
                                  emailError == null && !saving ? save : null,
                              child: saving
                                  ? const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Text(
                                      'Save',
                                      style: TextStyle(
                                          fontWeight: FontWeight.w700),
                                    ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );

    emailController.dispose();

    if (result == true) {
      await _loadData();

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Student info updated.')),
      );
    }
  }

  // =========================
  // ADD STUDENTS (chooser)
  // =========================

  Future<void> _showAddStudentsSheet() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Add Students',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: CmColors.navy,
                ),
              ),
              const SizedBox(height: 14),
              _optionTile(
                icon: Icons.upload_file_outlined,
                title: 'Import Excel',
                subtitle: 'Upload a student list using an .xlsx file.',
                onTap: () => Navigator.pop(context, 'import'),
              ),
              const SizedBox(height: 10),
              _optionTile(
                icon: Icons.person_add_alt_1_outlined,
                title: 'Add Manually',
                subtitle: 'Add one student at a time.',
                onTap: () => Navigator.pop(context, 'manual'),
              ),
            ],
          ),
        ),
      ),
    );

    if (!mounted || choice == null) return;

    if (choice == 'import') {
      final changed = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder: (_) => ImportStudentsScreen(isTeacher: widget.isTeacher),
        ),
      );
      if (changed == true && mounted) {
        await _loadData();
      }
    } else {
      if (_classes.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Create a class first, or import an Excel list to create '
              'classes automatically.',
            ),
          ),
        );
        return;
      }
      await _showAddStudentDialog();
    }
  }

  Widget _optionTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: CmColors.line),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: CmColors.bg,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: CmColors.navy),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: CmColors.slate,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // =========================
  // HELPERS
  // =========================

  String _getClassLabel(Map<String, dynamic> item) {
    final section = item['section']?.toString() ?? 'Unknown Section';
    final subject = item['subject'];

    if (subject is! Map) {
      return section;
    }

    final name = subject['name']?.toString() ?? 'Unknown Subject';
    final code = subject['code']?.toString() ?? '';

    if (code.isEmpty) {
      return '$section - $name';
    }

    return '$section - $code - $name';
  }

  int? _studentClassId(Map<String, dynamic> student) {
    final c = student['class'];
    if (c is Map && c['id'] != null) {
      return int.tryParse(c['id'].toString());
    }
    return int.tryParse(student['class_id']?.toString() ?? '');
  }

  String _studentSection(Map<String, dynamic> student) {
    final c = student['class'];
    if (c is Map) {
      final s = c['section']?.toString() ?? '';
      if (s.isNotEmpty) return s;
    }
    return 'No Section';
  }

  String _studentSubject(Map<String, dynamic> student) {
    final c = student['class'];
    if (c is Map && c['subject'] is Map) {
      final s = c['subject'] as Map;
      final name = s['name']?.toString() ?? '';
      final code = s['code']?.toString() ?? '';
      if (name.isEmpty) return code;
      return code.isEmpty ? name : '$code - $name';
    }
    return '';
  }

  String _fullName(Map<String, dynamic> s) {
    final first = s['first_name']?.toString() ?? '';
    final last = s['last_name']?.toString() ?? '';
    final full = '$first $last'.trim();
    return full.isEmpty ? 'Unnamed Student' : full;
  }

  bool _matches(Map<String, dynamic> s) {
    if (_query.isEmpty) return true;
    final haystack = [
      _fullName(s),
      s['last_name']?.toString() ?? '',
      s['student_number']?.toString() ?? '',
      s['email']?.toString() ?? '',
      _studentSection(s),
    ].join(' ').toLowerCase();
    return haystack.contains(_query);
  }

  /// Builds a flat list of header + student entries, grouped by class
  /// (section), so a single ListView.builder stays fast for 50+ students.
  List<Object> _buildEntries() {
    final groups = <String, List<Map<String, dynamic>>>{};
    final meta = <String, _GroupHeader>{};

    for (final s in _students.where(_matches)) {
      final id = _studentClassId(s);
      final key = id?.toString() ?? 'none';
      groups.putIfAbsent(key, () => []).add(s);
      meta.putIfAbsent(
        key,
        () => _GroupHeader(
          section: _studentSection(s),
          subject: _studentSubject(s),
          count: 0,
        ),
      );
    }

    final keys = groups.keys.toList()
      ..sort((a, b) => meta[a]!.section
          .toLowerCase()
          .compareTo(meta[b]!.section.toLowerCase()));

    final entries = <Object>[];
    for (final k in keys) {
      final list = groups[k]!
        ..sort((a, b) => (a['last_name']?.toString() ?? '')
            .toLowerCase()
            .compareTo((b['last_name']?.toString() ?? '').toLowerCase()));
      final m = meta[k]!;
      entries.add(_GroupHeader(
        section: m.section,
        subject: m.subject,
        count: list.length,
      ));
      entries.addAll(list);
    }
    return entries;
  }

  void _showStudentInfo(Map<String, dynamic> student) {
    final email = student['email']?.toString() ?? '';
    final c = student['class'];
    final schoolYear = c is Map ? c['school_year']?.toString() ?? '' : '';
    final semester = c is Map ? c['semester']?.toString() ?? '' : '';

    Widget row(IconData icon, String label, String value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 20, color: CmColors.slate),
              const SizedBox(width: 12),
              SizedBox(
                width: 96,
                child: Text(
                  label,
                  style: const TextStyle(color: CmColors.slate),
                ),
              ),
              Expanded(
                child: Text(
                  value.isEmpty ? '—' : value,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        );

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _fullName(student),
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: CmColors.navy,
                ),
              ),
              const SizedBox(height: 8),
              row(Icons.badge_outlined, 'Student No.',
                  student['student_number']?.toString() ?? ''),
              row(Icons.class_outlined, 'Section', _studentSection(student)),
              row(Icons.menu_book_outlined, 'Subject',
                  _studentSubject(student)),
              row(Icons.calendar_month_outlined, 'Term',
                  [semester, schoolYear].where((e) => e.isNotEmpty).join(' • ')),
              row(Icons.email_outlined, 'Email', email),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  style: _primaryButtonStyle,
                  onPressed: () {
                    Navigator.pop(context);
                    _showAddInfoDialog(student);
                  },
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: Text(
                    email.isEmpty ? 'Add Info' : 'Edit Info',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // =========================
  // BUILD
  // =========================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Students'),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showAddStudentsSheet,
        backgroundColor: CmColors.navy,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.person_add_alt_1_outlined),
        label: const Text('Add Students'),
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
                hintText: 'Search students...',
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
          if (_classes.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),
                  child: _labeled(
                    'Filter by Section',
                    DropdownButtonFormField<int?>(
                      initialValue: _selectedClassId,
                      isExpanded: true,
                      decoration: _fieldDecoration().copyWith(
                        prefixIcon: const Icon(
                          Icons.people_outline,
                          color: CmColors.slate,
                        ),
                      ),
                      items: [
                        const DropdownMenuItem<int?>(
                          value: null,
                          child: Text('All Sections'),
                        ),
                        ..._classes.map((item) {
                          final id = int.parse(item['id'].toString());

                          return DropdownMenuItem<int?>(
                            value: id,
                            child: Text(
                              _getClassLabel(item),
                              overflow: TextOverflow.ellipsis,
                            ),
                          );
                        }),
                      ],
                      onChanged: (value) {
                        setState(() {
                          _selectedClassId = value;
                        });

                        _loadData();
                      },
                    ),
                  ),
                ),
              ),
            ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _loadData,
              child: _buildBody(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(),
      );
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
                  const Icon(
                    Icons.error_outline,
                    size: 48,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _error!,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _loadData,
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    if (_students.isEmpty) {
      return ListView(
        children: [
          const SizedBox(height: 100),
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                children: [
                  const Icon(
                    Icons.people_outline,
                    size: 56,
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'No students yet.',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Add students individually or import\n'
                    'an Excel student list.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: _showAddStudentsSheet,
                    icon: const Icon(Icons.add),
                    label: const Text('Add Students'),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    final entries = _buildEntries();

    if (entries.isEmpty) {
      return ListView(
        children: const [
          SizedBox(height: 100),
          Center(
            child: Column(
              children: [
                Icon(Icons.search_off, size: 48, color: CmColors.slate),
                SizedBox(height: 12),
                Text(
                  'No matching students.',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ],
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];

        if (entry is _GroupHeader) {
          return Padding(
            padding: EdgeInsets.fromLTRB(4, index == 0 ? 4 : 20, 4, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.section,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          color: CmColors.navy,
                        ),
                      ),
                      if (entry.subject.isNotEmpty)
                        Text(
                          entry.subject,
                          style: const TextStyle(
                            fontSize: 13,
                            color: CmColors.slate,
                          ),
                        ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: CmColors.slate.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '${entry.count} student${entry.count == 1 ? '' : 's'}',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: CmColors.slate,
                    ),
                  ),
                ),
              ],
            ),
          );
        }

        final student = entry as Map<String, dynamic>;
        final firstName = student['first_name']?.toString() ?? '';

        return Card(
          elevation: 0,
          color: Colors.white,
          margin: const EdgeInsets.only(bottom: 10),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: const BorderSide(color: CmColors.line),
          ),
          child: ListTile(
            onTap: () => _showStudentInfo(student),
            minVerticalPadding: 14,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
            leading: CircleAvatar(
              radius: 24,
              backgroundColor: CmColors.navy.withValues(alpha: 0.07),
              foregroundColor: CmColors.navy,
              child: Text(
                firstName.isNotEmpty ? firstName[0].toUpperCase() : '?',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            title: Text(
              _fullName(student),
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: CmColors.navy,
              ),
            ),
            subtitle: Text(
              student['student_number']?.toString() ?? '',
              style: const TextStyle(color: CmColors.slate),
            ),
          ),
        );
      },
    );
  }
}

class _GroupHeader {
  const _GroupHeader({
    required this.section,
    required this.subject,
    required this.count,
  });

  final String section;
  final String subject;
  final int count;
}