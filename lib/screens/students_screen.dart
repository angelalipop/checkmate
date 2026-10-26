import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/api_service.dart';
import '../services/academic_api_service.dart';
import '../services/section_api_service.dart';
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

  List<Map<String, dynamic>> _programs = [];
  List<Map<String, dynamic>> _sections = [];
  String? _department;
  int? _programId;
  int? _yearLevel;
  int? _sectionId;
  bool _initialSelectionApplied = false;
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
        ApiService.getStudents(token),
        ApiService.getClasses(token),
        AcademicApi.programs(token),
        SectionApi.getSections(token),
      ]);

      if (!mounted) return;

      setState(() {
        _students =
            results[0];
        _classes =
            results[1];
        _programs = results[2];
        _sections = results[3];
        _validateFilters();
        if (!_initialSelectionApplied) {
          _initialSelectionApplied = true;
          _applyInitialClass();
        }
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
    final catalog = _catalogSection(student);
    if (catalog != null) return _text(catalog['name']);
    final name = _text(_classFor(student)?['section'] ?? student['section']);
    return name.isEmpty ? 'No Section' : name;
  }

  String _studentSubject(Map<String, dynamic> student) {
    final c = _classFor(student);
    if (c != null && c['subject'] is Map) {
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

  static String _text(Object? value) => value?.toString().trim() ?? '';
  static int? _id(Object? value) => int.tryParse(_text(value));
  static String _sectionName(Object? value) =>
      _text(value).toUpperCase().replaceAll(RegExp(r'[\s-]+'), '');

  String _departmentOf(Map<String, dynamic> program) =>
      program['level'] == 'shs'
          ? 'Senior High School'
          : (_text(program['department']).isEmpty
              ? 'College'
              : _text(program['department']));

  List<String> get _departments =>
      _programs.map(_departmentOf).toSet().toList()
        ..sort((a, b) {
          if (a == b) return 0;
          if (a == 'Senior High School') return -1;
          if (b == 'Senior High School') return 1;
          return a.compareTo(b);
        });

  Map<String, dynamic>? get _program {
    for (final program in _programs) {
      if (_id(program['id']) == _programId) return program;
    }
    return null;
  }

  List<Map<String, dynamic>> get _departmentPrograms => _programs
      .where((p) => _departmentOf(p) == _department)
      .toList()
    ..sort((a, b) => _text(a['code']).compareTo(_text(b['code'])));

  bool _sectionInProgram(Map<String, dynamic> section) {
    final program = _program;
    if (program == null) return false;
    final id = _id(section['program_id']);
    return id != null
        ? id == _programId
        : _text(section['program_code']).toUpperCase() ==
            _text(program['code']).toUpperCase();
  }

  int? _sectionYear(Map<String, dynamic> section) {
    final year = _id(section['year_level']);
    // Sections stores SHS grades as 1/2; also accept explicit 11/12.
    return _program?['level'] == 'shs' && year != null && year >= 11
        ? year - 10
        : year;
  }

  String _yearLabel(int year) {
    if (_program?['level'] == 'shs') return 'Grade ${year + 10}';
    const labels = ['1st Year', '2nd Year', '3rd Year', '4th Year'];
    return year >= 1 && year <= labels.length ? labels[year - 1] : 'Year $year';
  }

  List<int> get _years => _sections.where(_sectionInProgram)
      .map(_sectionYear).whereType<int>().toSet().toList()..sort();

  List<Map<String, dynamic>> get _availableSections => _sections
      .where((s) => _sectionInProgram(s) &&
          (_yearLevel == null || _sectionYear(s) == _yearLevel))
      .toList()
    ..sort((a, b) => _text(a['name']).compareTo(_text(b['name'])));

  String _sectionOption(Map<String, dynamic> section) {
    final name = _text(section['name']);
    final duplicates = _availableSections.where(
        (s) => _sectionName(s['name']) == _sectionName(name)).length;
    if (duplicates < 2) return name;
    return [name, _text(section['school_year']),
      if (section['semester'] != null) 'Semester ${section['semester']}',
    ].where((part) => part.isNotEmpty).join(' · ');
  }

  Map<String, dynamic>? _classFor(Map<String, dynamic> student) {
    final classId = _studentClassId(student);
    for (final item in _classes) {
      if (classId != null && _id(item['id']) == classId) return item;
    }
    final embedded = student['class'];
    return embedded is Map ? Map<String, dynamic>.from(embedded) : null;
  }

  Map<String, dynamic>? _catalogSection(Map<String, dynamic> student) {
    final classInfo = _classFor(student);
    final sectionId = _id(student['section_id']) ?? _id(classInfo?['section_id']);
    if (sectionId != null) {
      for (final section in _sections) {
        if (_id(section['id']) == sectionId) return section;
      }
      return null;
    }
    // Legacy students reference a subject class. Match its section name and
    // term against the catalog, never treat a class ID as a section ID.
    final name = _sectionName(classInfo?['section'] ?? student['section']);
    if (name.isEmpty) return null;
    final candidates = _sections.where((section) {
      if (_sectionName(section['name']) != name) return false;
      for (final key in ['school_year', 'semester', 'program_id']) {
        final expected = _text(classInfo?[key]);
        final actual = _text(section[key]);
        if (expected.isNotEmpty && actual.isNotEmpty && expected != actual) {
          return false;
        }
      }
      return true;
    }).toList();
    return candidates.length == 1 ? candidates.single : null;
  }

  void _validateFilters() {
    if (!_departments.contains(_department)) _department = null;
    if (!_departmentPrograms.any((p) => _id(p['id']) == _programId)) {
      _programId = null;
    }
    if (!_years.contains(_yearLevel)) _yearLevel = null;
    if (!_availableSections.any((s) => _id(s['id']) == _sectionId)) {
      _sectionId = null;
    }
  }

  void _applyInitialClass() {
    if (widget.initialClassId == null) return;
    final section = _catalogSection({'class_id': widget.initialClassId});
    if (section == null) return;
    for (final program in _programs) {
      if (_id(program['id']) == _id(section['program_id']) ||
          _text(program['code']) == _text(section['program_code'])) {
        _department = _departmentOf(program);
        _programId = _id(program['id']);
        _yearLevel = _sectionYear(section);
        _sectionId = _id(section['id']);
        break;
      }
    }
  }

  void _clearSearch() {
    _searchController.clear();
    _query = '';
    _selectedClassId = null;
  }

  /// Group by catalog section, with one student identity per section even
  /// when the same student appears in several subject classes.
  List<Object> _buildEntries() {
    if (_department == null || _programId == null) return [];
    final allowed = {for (final s in _availableSections)
      if (_sectionId == null || _id(s['id']) == _sectionId) _id(s['id']): s};
    final groups = <int, Map<String, Map<String, dynamic>>>{};
    for (final student in _students) {
      final section = _catalogSection(student);
      final sectionId = _id(section?['id']);
      if (sectionId == null || !allowed.containsKey(sectionId) || !_matches(student)) {
        continue;
      }
      final number = _text(student['student_number']);
      final identity = number.isNotEmpty
          ? 'number:$number'
          : 'id:${student['id'] ?? _students.indexOf(student)}';
      groups.putIfAbsent(sectionId, () => {}).putIfAbsent(identity, () => student);
    }
    final entries = <Object>[];
    for (final section in allowed.values) {
      final students = groups[_id(section['id'])]?.values.toList() ?? [];
      if (students.isEmpty) continue;
      students.sort((a, b) {
        final last = _text(a['last_name']).toLowerCase()
            .compareTo(_text(b['last_name']).toLowerCase());
        return last != 0 ? last : _fullName(a).compareTo(_fullName(b));
      });
      final year = _sectionYear(section);
      entries.add(_GroupHeader(
        section: _text(section['name']),
        subject: [_text(_program?['code']), if (year != null) _yearLabel(year),
          _text(section['school_year']),
          if (section['semester'] != null) 'Semester ${section['semester']}',
        ].where((part) => part.isNotEmpty).join(' · '),
        count: students.length,
      ));
      entries.addAll(students);
    }
    return entries;
  }

  void _showStudentInfo(Map<String, dynamic> student) {
    final email = student['email']?.toString() ?? '';
    final c = _classFor(student);
    final schoolYear = c?['school_year']?.toString() ?? '';
    final semester = c?['semester']?.toString() ?? '';

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

  Widget _filter<T>({
    required String label,
    required T? value,
    required String hint,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?> onChanged,
    required String identity,
  }) => _labeled(label, DropdownButtonFormField<T>(
    key: ValueKey('$identity:$value'),
    initialValue: value,
    isExpanded: true,
    dropdownColor: Colors.white,
    style: const TextStyle(color: CmColors.navy, fontSize: 14),
    decoration: _fieldDecoration(),
    hint: Text(hint, overflow: TextOverflow.ellipsis),
    items: items,
    onChanged: _loading || _error != null ? null : onChanged,
  ));

  Widget _filters() => LayoutBuilder(builder: (context, constraints) {
    final columns = constraints.maxWidth >= 1050 ? 4
        : constraints.maxWidth >= 600 ? 2 : 1;
    final width = (constraints.maxWidth - 16 * (columns - 1)) / columns;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        TextField(
          controller: _searchController,
          onChanged: (value) => setState(() => _query = value.trim().toLowerCase()),
          decoration: _fieldDecoration().copyWith(
            hintText: 'Search students...',
            prefixIcon: const Icon(Icons.search, color: CmColors.slate),
            suffixIcon: _query.isEmpty ? null : IconButton(
              tooltip: 'Clear search', icon: const Icon(Icons.close),
              onPressed: () => setState(() {
                _searchController.clear();
                _query = '';
              }),
            ),
          ),
        ),
        const SizedBox(height: 20),
        Wrap(spacing: 16, runSpacing: 16, children: [
          SizedBox(width: width, child: _filter<String>(
            label: 'Department', value: _department,
            hint: 'Select department', identity: 'department',
            items: [for (final d in _departments)
              DropdownMenuItem(value: d, child: Text(d, overflow: TextOverflow.ellipsis))],
            onChanged: (value) => setState(() {
              _department = value;
              _programId = null;
              _yearLevel = null;
              _sectionId = null;
              _clearSearch();
            }),
          )),
          if (_department != null)
            SizedBox(width: width, child: _filter<int>(
              label: 'Program / Strand', value: _programId,
              hint: 'Select program / strand', identity: 'program:$_department',
              items: [for (final p in _departmentPrograms)
                DropdownMenuItem(value: _id(p['id']), child: Text(
                  _text(p['code']), overflow: TextOverflow.ellipsis))],
              onChanged: (value) => setState(() {
                _programId = value;
                _yearLevel = null;
                _sectionId = null;
                _clearSearch();
              }),
            )),
          if (_programId != null) ...[
            SizedBox(width: width, child: _filter<int>(
              label: 'Year Level', value: _yearLevel,
              hint: 'All year levels', identity: 'year:$_programId',
              items: [
                const DropdownMenuItem<int>(value: null, child: Text('All year levels')),
                for (final y in _years) DropdownMenuItem(value: y, child: Text(_yearLabel(y))),
              ],
              onChanged: (value) => setState(() {
                _yearLevel = value;
                _sectionId = null;
                _selectedClassId = null;
              }),
            )),
            SizedBox(width: width, child: _filter<int>(
              label: 'Section', value: _sectionId,
              hint: 'All sections', identity: 'section:$_programId:$_yearLevel',
              items: [
                const DropdownMenuItem<int>(value: null, child: Text('All sections')),
                for (final section in _availableSections)
                  DropdownMenuItem(value: _id(section['id']), child: Text(
                    _sectionOption(section), overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (value) => setState(() {
                _sectionId = value;
                _selectedClassId = null;
              }),
            )),
          ],
        ]),
      ]),
    );
  });

  Widget _emptyMessage(IconData icon, String message) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 64),
    child: Column(children: [
      Icon(icon, size: 48, color: CmColors.slate),
      const SizedBox(height: 16),
      Text(message, textAlign: TextAlign.center,
        style: const TextStyle(color: CmColors.slate, fontSize: 16)),
    ]),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: CmColors.bg,
    appBar: AppBar(title: const Text('Students')),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: _loading ? null : _showAddStudentsSheet,
      backgroundColor: CmColors.navy,
      foregroundColor: Colors.white,
      icon: const Icon(Icons.person_add_alt_1_outlined),
      label: const Text('Add Students'),
    ),
    body: RefreshIndicator(onRefresh: _loadData, child: _buildBody()),
  );

  Widget _buildBody() {
    final entries = _loading || _error != null ? <Object>[] : _buildEntries();
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 104),
      itemCount: entries.isEmpty ? 2 : entries.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) return _filters();
        if (_loading) {
          return const Padding(padding: EdgeInsets.all(64),
            child: Center(child: CircularProgressIndicator()));
        }
        if (_error != null) {
          return Column(children: [
            _emptyMessage(Icons.error_outline, _error!),
            FilledButton(onPressed: _loadData, child: const Text('Retry')),
          ]);
        }
        if (_department == null) {
          return _emptyMessage(Icons.apartment_outlined,
            _programs.isEmpty ? 'Add programs in Academic Management to get started.'
              : 'Select a department to view students');
        }
        if (_programId == null) {
          return _emptyMessage(Icons.apartment_outlined, 'Select a program or strand to continue');
        }
        if (entries.isEmpty) {
          return _emptyMessage(Icons.people_outline,
            _availableSections.isEmpty ? 'No sections found for these filters.'
              : _query.isNotEmpty ? 'No matching students.'
              : 'No students found in these sections.');
        }
        final entry = entries[index - 1];

        if (entry is _GroupHeader) {
          return Padding(
            padding: EdgeInsets.fromLTRB(4, index == 1 ? 4 : 20, 4, 8),
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
  const _GroupHeader({required this.section, required this.subject, required this.count});
  final String section;
  final String subject;
  final int count;
}
