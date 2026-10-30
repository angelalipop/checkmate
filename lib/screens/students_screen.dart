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

  /// Every section assigned to the logged-in teacher (built from the classes
  /// the server returns for them), whether or not it has students yet.
  List<_AssignedSection> _assigned = [];
  final Map<int, String> _classToSection = {};
  final Map<String, _AssignedSection> _sectionByKey = {};
  bool _isTeacher = false;

  String? _department;
  int? _programId;
  int? _yearLevel;
  String? _sectionKey;
  bool _initialSelectionApplied = false;
  int? _selectedClassId;

  final _searchController = TextEditingController();
  String _query = '';

  final Set<String> _collapsedSectionKeys = <String>{};

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

  Future<List<Map<String, dynamic>>> _tolerant(
    Future<List<Map<String, dynamic>>> request,
  ) async {
    try {
      return await request;
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  Future<bool> _roleIsTeacher(String token) async {
    try {
      final result = await ApiService.getCurrentUser(token);
      final user = result['user'];
      return user is Map && user['role']?.toString().toLowerCase() == 'teacher';
    } catch (_) {
      return false;
    }
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

      final results = await Future.wait<Object?>([
        ApiService.getStudents(token),
        ApiService.getClasses(token),
        // Programs only add department names to the filters; the list itself
        // must still load if they are unavailable.
        _tolerant(AcademicApi.programs(token)),
        SectionApi.getSections(token),
        _roleIsTeacher(token),
      ]);

      if (!mounted) return;

      setState(() {
        _students = results[0]! as List<Map<String, dynamic>>;
        _classes = results[1]! as List<Map<String, dynamic>>;
        _programs = results[2]! as List<Map<String, dynamic>>;
        _sections = results[3]! as List<Map<String, dynamic>>;
        _isTeacher = widget.isTeacher || results[4] == true;
        _rebuildAssigned();
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
        _error = e.toString().replaceFirst('Exception: ', '');
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
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
  );

  ButtonStyle get _secondaryButtonStyle => OutlinedButton.styleFrom(
    foregroundColor: CmColors.navy,
    backgroundColor: CmColors.bg,
    side: const BorderSide(color: CmColors.line),
    minimumSize: const Size.fromHeight(50),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
  );

  static final _nameFormatter = FilteringTextInputFormatter.allow(
    RegExp(r"[\p{L} .'’\-]", unicode: true),
  );

  // =========================
  // ADD STUDENT MANUALLY
  // =========================

  Future<void> _showAddStudentDialog({_AssignedSection? section}) async {
    // Opened from an empty section: only that section's classes are offered.
    // Otherwise every class assigned to the teacher is (the server only
    // returns the teacher's own classes).
    final dialogClasses = section == null ? _classes : section.classes;
    final preselect = section ?? _selectedSection;
    int? selectedClassId = preselect != null && preselect.classes.length == 1
        ? _id(preselect.classes.first['id'])
        : (preselect == null ? _selectedClassId : null);
    if (!dialogClasses.any((c) => _id(c['id']) == selectedClassId)) {
      selectedClassId = null;
    }

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

            final numberError = StudentValidation.studentNumber(
              studentNumberController.text,
            );
            final lastError = StudentValidation.name(
              lastNameController.text,
              label: 'Last name',
            );
            final firstError = StudentValidation.name(
              firstNameController.text,
              label: 'First name',
            );

            final valid =
                selectedClassId != null &&
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

                // Students can only be added to the teacher's own sections.
                if (!_classes.any((c) => _id(c['id']) == selectedClassId)) {
                  throw Exception(
                    'You can only add students to sections assigned to you.',
                  );
                }

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
                  dialogError = e.toString().replaceFirst('Exception: ', '');
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
                              studentNumberController,
                              numberError,
                            ),
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
                          items: dialogClasses.map((item) {
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
                                        fontWeight: FontWeight.w700,
                                      ),
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
        const SnackBar(content: Text('Student added successfully.')),
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
                  dialogError = e.toString().replaceFirst('Exception: ', '');
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
                              onPressed: emailError == null && !saving
                                  ? save
                                  : null,
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
                                        fontWeight: FontWeight.w700,
                                      ),
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

      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Student info updated.')));
    }
  }

  // =========================
  // ADD STUDENTS (chooser)
  // =========================

  Future<void> _showAddStudentsSheet({_AssignedSection? section}) async {
    // Carry the section into the add flow: the one whose button was tapped,
    // or else the section currently chosen in the filters.
    final target = section ?? _selectedSection;
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
              if (section != null) ...[
                const SizedBox(height: 4),
                Text(
                  'Section ${section.name}',
                  style: const TextStyle(color: CmColors.slate),
                ),
              ],
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
          builder: (_) => ImportStudentsScreen(
            isTeacher: widget.isTeacher,
            // Only a teacher's own sections may receive imported students.
            assignedSections: _isTeacher
                ? {for (final c in _classes) _text(c['section'])}
                      .where((name) => name.isNotEmpty)
                      .toList()
                : null,
            initialSection: target?.name,
            initialClass: target != null && target.classes.length == 1
                ? target.classes.first
                : null,
          ),
        ),
      );
      if (changed == true && mounted) {
        await _loadData();
      }
    } else {
      if (_classes.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _isTeacher
                  ? 'No sections are assigned to you yet. Ask an '
                        'administrator to assign your subjects and sections.'
                  : 'Create a class first, or import an Excel list to '
                        'create classes automatically.',
            ),
          ),
        );
        return;
      }
      await _showAddStudentDialog(section: section);
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
    final section = _sectionOf(student);
    if (section != null) return section.name;
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
      _text(value).toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

  String _departmentOf(Map<String, dynamic> program) =>
      program['level'] == 'shs'
      ? 'Senior High School'
      : (_text(program['department']).isEmpty
            ? 'College'
            : _text(program['department']));

  /// "1st Semester" -> 1, "2nd Semester" -> 2, "Summer" -> null.
  static int? _semesterNumber(Object? value) {
    final text = _text(value);
    final match = RegExp(r'^\d').firstMatch(text);
    return match == null ? null : int.parse(match.group(0)!);
  }

  Map<String, dynamic> _programFor(Map<String, dynamic> section) {
    final id = _id(section['program_id']);
    final code = _text(section['program_code']).toUpperCase();
    for (final program in _programs) {
      if (id != null && _id(program['id']) == id) return program;
      if (id == null &&
          code.isNotEmpty &&
          _text(program['code']).toUpperCase() == code) {
        return program;
      }
    }
    // Programs unavailable: fall back to what the section itself carries.
    return {
      'id': id,
      'code': _text(section['program_code']),
      'level': section['program_level'],
      'department': null,
    };
  }

  /// The catalog section a teacher's class belongs to, or null when it
  /// cannot be matched to exactly one.
  Map<String, dynamic>? _catalogFor(Map<String, dynamic> classInfo) {
    final sectionId = _id(classInfo['section_id']);
    if (sectionId != null) {
      for (final section in _sections) {
        if (_id(section['id']) == sectionId) return section;
      }
      return null;
    }
    final name = _sectionName(classInfo['section']);
    if (name.isEmpty) return null;
    final schoolYear = _text(classInfo['school_year']);
    final semester = _semesterNumber(classInfo['semester']);

    // The Sections screen is the source of truth: look the name up there.
    final byName = _sections
        .where((section) => _sectionName(section['name']) == name)
        .toList();
    if (byName.isEmpty) return null;

    // Prefer the section of the class's own school year and semester.
    final sameTerm = byName.where((section) {
      if (schoolYear.isNotEmpty &&
          _text(section['school_year']) != schoolYear) {
        return false;
      }
      if (semester != null &&
          _semesterNumber(section['semester']) != semester) {
        return false;
      }
      return true;
    }).toList();

    final pool = sameTerm.isNotEmpty ? sameTerm : byName;
    if (pool.length == 1) return pool.single;

    // Several terms share the name: take the most recent one.
    pool.sort((x, y) {
      final year = _text(y['school_year']).compareTo(_text(x['school_year']));
      return year != 0
          ? year
          : (_semesterNumber(y['semester']) ?? 0).compareTo(
              _semesterNumber(x['semester']) ?? 0,
            );
    });
    return pool.first;
  }

  int? _yearOf(Map<String, dynamic> program, Object? raw) {
    final year = _id(raw);
    // Sections stores SHS grades as 1/2; also accept explicit 11/12.
    return program['level'] == 'shs' && year != null && year >= 11
        ? year - 10
        : year;
  }

  /// Builds the teacher's assigned sections from their classes. A section
  /// that has several subject classes is still one section.
  void _rebuildAssigned() {
    final byKey = <String, _AssignedSection>{};
    _classToSection.clear();
    _sectionByKey.clear();

    for (final item in _classes) {
      final classId = _id(item['id']);
      final rawName = _text(item['section']);
      if (classId == null || rawName.isEmpty) continue;

      final catalog = _catalogFor(item);
      final key = catalog != null
          ? 'section:${_id(catalog['id'])}'
          : 'class:${_sectionName(rawName)}|${_text(item['school_year'])}|'
                '${_semesterNumber(item['semester'])}';

      final existing = byKey[key];
      if (existing != null) {
        existing.classes.add(item);
      } else {
        final program = catalog == null ? null : _programFor(catalog);
        byKey[key] = _AssignedSection(
          key: key,
          name: catalog != null ? _text(catalog['name']) : rawName,
          program: program,
          year: program != null
              ? _yearOf(program, catalog!['year_level'])
              : _id(item['year_level']),
          schoolYear: catalog != null
              ? _text(catalog['school_year'])
              : _text(item['school_year']),
          semester: catalog != null
              ? _semesterNumber(catalog['semester'])
              : _semesterNumber(item['semester']),
          classes: [item],
        );
      }
      _classToSection[classId] = key;
    }

    _assigned = byKey.values.toList()
      ..sort((a, b) {
        final program = _text(a.program?['code'])
            .compareTo(_text(b.program?['code']));
        if (program != 0) return program;
        final year = (a.year ?? 0).compareTo(b.year ?? 0);
        return year != 0 ? year : a.name.compareTo(b.name);
      });
    for (final section in _assigned) {
      _sectionByKey[section.key] = section;
    }
  }

  _AssignedSection? _sectionOf(Map<String, dynamic> student) {
    final classId = _studentClassId(student);
    final key = classId == null ? null : _classToSection[classId];
    return key == null ? null : _sectionByKey[key];
  }

  // ----- filter choices: only from the teacher's assigned sections -----

  List<String> get _departments =>
      {
        for (final s in _assigned)
          if (s.program != null) _departmentOf(s.program!),
      }.toList()..sort((a, b) {
        if (a == b) return 0;
        if (a == 'Senior High School') return -1;
        if (b == 'Senior High School') return 1;
        return a.compareTo(b);
      });

  List<Map<String, dynamic>> get _departmentPrograms {
    final byId = <int, Map<String, dynamic>>{};
    for (final s in _assigned) {
      final program = s.program;
      final id = s.programId;
      if (program == null || id == null) continue;
      if (_departmentOf(program) == _department) byId[id] = program;
    }
    return byId.values.toList()
      ..sort((a, b) => _text(a['code']).compareTo(_text(b['code'])));
  }

  Map<String, dynamic>? get _program {
    for (final program in _departmentPrograms) {
      if (_id(program['id']) == _programId) return program;
    }
    return null;
  }

  String _yearLabel(int year) {
    if (_program?['level'] == 'shs') return 'Grade ${year + 10}';
    const labels = ['1st Year', '2nd Year', '3rd Year', '4th Year'];
    return year >= 1 && year <= labels.length ? labels[year - 1] : 'Year $year';
  }

  List<int> get _years => _programId == null
      ? <int>[]
      : (_assigned
            .where((s) => s.programId == _programId)
            .map((s) => s.year)
            .whereType<int>()
            .toSet()
            .toList()
          ..sort());

  /// Sections for the Section dropdown. Year Level narrows them but is never
  /// required.
  List<_AssignedSection> get _availableSections => _programId == null
      ? <_AssignedSection>[]
      : (_assigned
            .where(
              (s) =>
                  s.programId == _programId &&
                  (_yearLevel == null || s.year == _yearLevel),
            )
            .toList()
          ..sort((a, b) => a.name.compareTo(b.name)));

  String _sectionOption(_AssignedSection section) {
    final duplicates = _availableSections
        .where((s) => _sectionName(s.name) == _sectionName(section.name))
        .length;
    if (duplicates < 2) return section.name;
    return [
      section.name,
      section.schoolYear,
      if (section.semester != null) 'Semester ${section.semester}',
    ].where((part) => part.isNotEmpty).join(' · ');
  }

  _AssignedSection? get _selectedSection =>
      _sectionKey == null ? null : _sectionByKey[_sectionKey];

  /// Assigned sections that pass the (optional) filters.
  List<_AssignedSection> get _filteredSections => _assigned.where((s) {
    if (_department != null &&
        (s.program == null || _departmentOf(s.program!) != _department)) {
      return false;
    }
    if (_programId != null && s.programId != _programId) return false;
    if (_yearLevel != null && s.year != _yearLevel) return false;
    if (_sectionKey != null && s.key != _sectionKey) return false;
    return true;
  }).toList();

  Map<String, dynamic>? _classFor(Map<String, dynamic> student) {
    final classId = _studentClassId(student);
    for (final item in _classes) {
      if (classId != null && _id(item['id']) == classId) return item;
    }
    final embedded = student['class'];
    return embedded is Map ? Map<String, dynamic>.from(embedded) : null;
  }

  /// Reset dependent filters whenever a parent choice is no longer valid.
  void _validateFilters() {
    if (!_departments.contains(_department)) _department = null;
    if (!_departmentPrograms.any((p) => _id(p['id']) == _programId)) {
      _programId = null;
    }
    if (!_years.contains(_yearLevel)) _yearLevel = null;
    if (!_availableSections.any((s) => s.key == _sectionKey)) {
      _sectionKey = null;
    }
  }

  void _applyInitialClass() {
    final classId = widget.initialClassId;
    if (classId == null) return;
    final key = _classToSection[classId];
    final section = key == null ? null : _sectionByKey[key];
    if (section == null) return;
    final program = section.program;
    if (program != null) {
      _department = _departmentOf(program);
      _programId = section.programId;
      _yearLevel = section.year;
    }
    _sectionKey = section.key;
  }

  /// One entry per assigned section (header + its students, or an empty
  /// state), with one student identity per section even when the same
  /// student appears in several subject classes.
  List<Object> _buildEntries() {
    final visible = _filteredSections;
    final visibleKeys = {for (final s in visible) s.key};
    final groups = <String, Map<String, Map<String, dynamic>>>{};

    for (final student in _students) {
      final classId = _studentClassId(student);
      final key = classId == null ? null : _classToSection[classId];
      if (key == null || !visibleKeys.contains(key) || !_matches(student)) {
        continue;
      }
      final number = _text(student['student_number']);
      final identity = number.isNotEmpty
          ? 'number:$number'
          : 'id:${student['id'] ?? _students.indexOf(student)}';
      groups.putIfAbsent(key, () => {}).putIfAbsent(identity, () => student);
    }

    final entries = <Object>[];
    for (final section in visible) {
      final students = groups[section.key]?.values.toList() ?? [];
      // While searching, only sections with a match are worth showing.
      if (students.isEmpty && _query.isNotEmpty) continue;
      students.sort((a, b) {
        final last = _text(a['last_name'])
            .toLowerCase()
            .compareTo(_text(b['last_name']).toLowerCase());
        return last != 0 ? last : _fullName(a).compareTo(_fullName(b));
      });
      final year = section.year;
      final shs = section.program?['level'] == 'shs';
      entries.add(
        _GroupHeader(
          section: section.name,
          subject: [
            _text(section.program?['code']),
            if (year != null)
              (shs
                  ? 'Grade ${year + 10}'
                  : const [
                          '1st Year',
                          '2nd Year',
                          '3rd Year',
                          '4th Year',
                        ].elementAtOrNull(year - 1) ??
                        'Year $year'),
            section.schoolYear,
            if (section.semester != null) 'Semester ${section.semester}',
          ].where((part) => part.isNotEmpty).join(' · '),
          count: students.length,
        ),
      );
      if (students.isEmpty) {
        entries.add(_EmptySection(section));
      } else {
        entries.addAll(students);
      }
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
            child: Text(label, style: const TextStyle(color: CmColors.slate)),
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
              row(
                Icons.badge_outlined,
                'Student No.',
                student['student_number']?.toString() ?? '',
              ),
              row(Icons.class_outlined, 'Section', _studentSection(student)),
              row(
                Icons.menu_book_outlined,
                'Subject',
                _studentSubject(student),
              ),
              row(
                Icons.calendar_month_outlined,
                'Term',
                [semester, schoolYear].where((e) => e.isNotEmpty).join(' • '),
              ),
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
  }) => _labeled(
    label,
    DropdownButtonFormField<T>(
      key: ValueKey('$identity:$value'),
      initialValue: value,
      isExpanded: true,
      dropdownColor: Colors.white,
      style: const TextStyle(color: CmColors.navy, fontSize: 14),
      decoration: _fieldDecoration(),
      hint: Text(hint, overflow: TextOverflow.ellipsis),
      items: items,
      onChanged: _loading || _error != null ? null : onChanged,
    ),
  );

  Widget _filters() => LayoutBuilder(
    builder: (context, constraints) {
      final columns = constraints.maxWidth >= 1050
          ? 4
          : constraints.maxWidth >= 600
          ? 2
          : 1;
      final width = (constraints.maxWidth - 16 * (columns - 1)) / columns;
      return Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _searchController,
              onChanged: (value) =>
                  setState(() => _query = value.trim().toLowerCase()),
              decoration: _fieldDecoration().copyWith(
                hintText: 'Search students...',
                prefixIcon: const Icon(Icons.search, color: CmColors.slate),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear search',
                        icon: const Icon(Icons.close),
                        onPressed: () => setState(() {
                          _searchController.clear();
                          _query = '';
                        }),
                      ),
              ),
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 16,
              runSpacing: 16,
              children: [
                SizedBox(
                  width: width,
                  child: _filter<String>(
                    label: 'Department',
                    value: _department,
                    hint: 'All departments',
                    identity: 'department',
                    items: [
                      const DropdownMenuItem<String>(
                        value: null,
                        child: Text('All departments'),
                      ),
                      for (final d in _departments)
                        DropdownMenuItem(
                          value: d,
                          child: Text(d, overflow: TextOverflow.ellipsis),
                        ),
                    ],
                    onChanged: (value) => setState(() {
                      _department = value;
                      _programId = null;
                      _yearLevel = null;
                      _sectionKey = null;
                      _selectedClassId = null;
                    }),
                  ),
                ),
                if (_department != null)
                  SizedBox(
                    width: width,
                    child: _filter<int>(
                      label: 'Program / Strand',
                      value: _programId,
                      hint: 'All programs / strands',
                      identity: 'program:$_department',
                      items: [
                        const DropdownMenuItem<int>(
                          value: null,
                          child: Text('All programs / strands'),
                        ),
                        for (final p in _departmentPrograms)
                          DropdownMenuItem(
                            value: _id(p['id']),
                            child: Text(
                              _text(p['code']),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (value) => setState(() {
                        _programId = value;
                        _yearLevel = null;
                        _sectionKey = null;
                        _selectedClassId = null;
                      }),
                    ),
                  ),
                if (_programId != null) ...[
                  SizedBox(
                    width: width,
                    child: _filter<int>(
                      label: 'Year Level',
                      value: _yearLevel,
                      hint: 'All year levels',
                      identity: 'year:$_programId',
                      items: [
                        const DropdownMenuItem<int>(
                          value: null,
                          child: Text('All year levels'),
                        ),
                        for (final y in _years)
                          DropdownMenuItem(
                            value: y,
                            child: Text(_yearLabel(y)),
                          ),
                      ],
                      onChanged: (value) => setState(() {
                        _yearLevel = value;
                        // Keep the chosen section if it is still in this year level.
                        if (!_availableSections.any(
                          (s) => s.key == _sectionKey,
                        )) {
                          _sectionKey = null;
                        }
                        _selectedClassId = null;
                      }),
                    ),
                  ),
                  SizedBox(
                    width: width,
                    child: _filter<String>(
                      label: 'Section',
                      value: _sectionKey,
                      hint: 'All sections',
                      identity: 'section:$_programId:$_yearLevel',
                      items: [
                        const DropdownMenuItem<String>(
                          value: null,
                          child: Text('All sections'),
                        ),
                        for (final section in _availableSections)
                          DropdownMenuItem(
                            value: section.key,
                            child: Text(
                              _sectionOption(section),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (value) => setState(() {
                        _sectionKey = value;
                        _selectedClassId = null;
                      }),
                    ),
                  ),
                ],
              ],
            ),
            if (_assigned.any((s) => s.program == null)) ...[
              const SizedBox(height: 12),
              Text(
                'Not in the Sections catalog (cannot be filtered by department): '
                '${_assigned.where((s) => s.program == null).map((s) => s.name).join(', ')}',
                style: const TextStyle(color: CmColors.amber, fontSize: 12),
              ),
            ],
          ],
        ),
      );
    },
  );

  Widget _emptyMessage(IconData icon, String message) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 64),
    child: Column(
      children: [
        Icon(icon, size: 48, color: CmColors.slate),
        const SizedBox(height: 16),
        Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(color: CmColors.slate, fontSize: 16),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: CmColors.bg,
    appBar: AppBar(title: const Text('Students')),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: _loading ? null : () => _showAddStudentsSheet(),
      backgroundColor: CmColors.navy,
      foregroundColor: Colors.white,
      icon: const Icon(Icons.person_add_alt_1_outlined),
      label: const Text('Add Students'),
    ),
    body: RefreshIndicator(onRefresh: _loadData, child: _buildBody()),
  );

  Widget _studentTile(Map<String, dynamic> student) {
    final firstName = student['first_name']?.toString() ?? '';
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Material(
        color: CmColors.bg,
        borderRadius: BorderRadius.circular(13),
        child: ListTile(
          onTap: () => _showStudentInfo(student),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 2,
          ),
          leading: CircleAvatar(
            radius: 20,
            backgroundColor: CmColors.navy.withValues(alpha: 0.05),
            foregroundColor: CmColors.navy,
            child: Text(
              firstName.isNotEmpty ? firstName[0].toUpperCase() : '?',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          title: Text(
            _fullName(student),
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: CmColors.navy,
            ),
          ),
          subtitle: Text(
            student['student_number']?.toString() ?? '',
            style: const TextStyle(fontSize: 12, color: CmColors.slate),
          ),
        ),
      ),
    );
  }

  Widget _sectionCard(
    _GroupHeader header,
    List<Map<String, dynamic>> students,
    _AssignedSection? section,
    String key,
  ) {
    final collapsed = _collapsedSectionKeys.contains(key);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      header.section,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: CmColors.navy,
                      ),
                    ),
                    if (header.subject.isNotEmpty)
                      Text(
                        header.subject,
                        style: const TextStyle(
                          fontSize: 12,
                          color: CmColors.slate,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${header.count} student${header.count == 1 ? '' : 's'}',
                style: const TextStyle(fontSize: 12, color: CmColors.slate),
              ),
            ],
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(17),
            border: Border.all(color: CmColors.line),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              InkWell(
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(17),
                ),
                onTap: () => setState(() {
                  if (collapsed) {
                    _collapsedSectionKeys.remove(key);
                  } else {
                    _collapsedSectionKeys.add(key);
                  }
                }),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 13,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          collapsed ? 'Show students' : 'Hide students',
                          style: const TextStyle(
                            fontSize: 13,
                            color: CmColors.slate,
                          ),
                        ),
                      ),
                      Icon(
                        collapsed
                            ? Icons.keyboard_arrow_down
                            : Icons.keyboard_arrow_up,
                        color: CmColors.slate,
                        size: 20,
                      ),
                    ],
                  ),
                ),
              ),
              if (!collapsed) ...[
                const Divider(height: 1, color: CmColors.line),
                Padding(
                  padding: const EdgeInsets.all(11),
                  child: students.isEmpty
                      ? Column(
                          children: [
                            const SizedBox(height: 14),
                            const Text(
                              'No students listed in this section yet.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: CmColors.slate,
                                fontSize: 13,
                              ),
                            ),
                            const SizedBox(height: 10),
                            FilledButton.icon(
                              style: FilledButton.styleFrom(
                                backgroundColor: CmColors.navy,
                              ),
                              onPressed: section == null
                                  ? null
                                  : () =>
                                        _showAddStudentsSheet(section: section),
                              icon: const Icon(
                                Icons.person_add_alt_1_outlined,
                                size: 18,
                              ),
                              label: Text('Add students to ${header.section}'),
                            ),
                            const SizedBox(height: 14),
                          ],
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: students.map(_studentTile).toList(),
                        ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildBody() {
    final entries = _loading || _error != null ? <Object>[] : _buildEntries();
    final groups = <Widget>[];
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      if (entry is! _GroupHeader) continue;
      final students = <Map<String, dynamic>>[];
      for (
        var j = i + 1;
        j < entries.length && entries[j] is! _GroupHeader;
        j++
      ) {
        if (entries[j] is Map<String, dynamic>) {
          students.add(entries[j] as Map<String, dynamic>);
        }
      }
      _AssignedSection? section;
      for (final candidate in _filteredSections) {
        if (candidate.name == entry.section) {
          section = candidate;
          break;
        }
      }
      final key = section?.key ?? 'display:${entry.section}:$i';
      groups.add(_sectionCard(entry, students, section, key));
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 900 ? 2 : 1;
        return ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 104),
          children: [
            _filters(),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(64),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error != null) ...[
              _emptyMessage(Icons.error_outline, _error!),
              FilledButton(onPressed: _loadData, child: const Text('Retry')),
            ] else if (groups.isEmpty)
              _emptyMessage(
                Icons.people_outline,
                _assigned.isEmpty
                    ? (_isTeacher
                          ? 'No sections are assigned to you yet. Ask an administrator to assign your subjects and sections.'
                          : 'No sections found.')
                    : _query.isNotEmpty
                    ? 'No matching students.'
                    : 'No sections match these filters.',
              )
            else
              LayoutBuilder(
                builder: (context, gridConstraints) {
                  final gap = 16.0;
                  final width =
                      (gridConstraints.maxWidth - gap * (columns - 1)) /
                      columns;
                  return Wrap(
                    spacing: gap,
                    runSpacing: 24,
                    children: groups
                        .map((card) => SizedBox(width: width, child: card))
                        .toList(),
                  );
                },
              ),
          ],
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

/// An empty section's placeholder row (empty-state message + add button).
class _EmptySection {
  const _EmptySection(this.section);
  final _AssignedSection section;
}

/// A section assigned to the logged-in teacher. It can hold several subject
/// classes; students belong to those classes.
class _AssignedSection {
  _AssignedSection({
    required this.key,
    required this.name,
    required this.program,
    required this.year,
    required this.schoolYear,
    required this.semester,
    required this.classes,
  });

  final String key;
  final String name;
  final Map<String, dynamic>? program;
  final int? year;
  final String schoolYear;
  final int? semester;
  final List<Map<String, dynamic>> classes;

  int? get programId => int.tryParse(program?['id']?.toString() ?? '');
}
