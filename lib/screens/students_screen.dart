import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:share_plus/share_plus.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/academic_api_service.dart';
import '../services/api_service.dart';
import '../services/auth_storage.dart';
import '../services/section_api_service.dart';
import '../services/student_import_service.dart' show StudentValidation;
import '../services/student_email_excel_service.dart';
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
  static const int _maxVisibleStudents = 5;
  static const double _studentTileHeight = 64.0;
  static const double _studentTileSpacing = 7.0;
  static const double _studentRowExtent =
      _studentTileHeight + _studentTileSpacing;

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

  final _searchController = TextEditingController();
  String _query = '';

  final Set<String> _collapsedSectionKeys = <String>{};

  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
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

  InputDecoration _fieldDecoration({String? errorText, Color? fillColor}) {
    OutlineInputBorder border(Color c, [double w = 1]) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: c, width: w),
    );

    return InputDecoration(
      isDense: true,
      filled: true,
      fillColor: fillColor ?? Colors.white,
      errorText: errorText,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: border(CmColors.line),
      enabledBorder: border(CmColors.line),
      disabledBorder: border(CmColors.line),
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

  Future<void> _showAddStudentDialog({
    required _AssignedSection section,
  }) async {
    final classIds = section.classes
        .map((c) => _id(c['id']))
        .whereType<int>()
        .where((id) => _classes.any((c) => _id(c['id']) == id))
        .toSet()
        .toList();

    final studentNumberController = TextEditingController();
    final lastNameController = TextEditingController();
    final firstNameController = TextEditingController();

    String clean(String v) =>
        v.replaceAll(RegExp(r'\s+'), ' ').trim().toUpperCase();

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        var saving = false;
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
              label: 'First and middle name',
            );

            final valid =
                classIds.isNotEmpty &&
                numberError == null &&
                lastError == null &&
                firstError == null;

            Future<bool> performSave() async {
              setDialogState(() {
                saving = true;
                dialogError = null;
              });

              try {
                final token = await AuthStorage.getToken();

                if (token == null || token.isEmpty) {
                  throw Exception('Authentication token not found.');
                }

                // Students can only be added to the teacher's own sections.
                if (classIds.isEmpty ||
                    !classIds.every(
                      (id) => _classes.any((c) => _id(c['id']) == id),
                    )) {
                  throw Exception(
                    'You can only add students to sections assigned to you.',
                  );
                }

                final studentNumber = studentNumberController.text.trim();
                final firstName = clean(firstNameController.text);
                final lastName = clean(lastNameController.text);

                // Prevent duplicate student number within the same section.
                if (_sectionHasStudentNumber(section, studentNumber)) {
                  throw Exception(
                    'A student with student number $studentNumber is already '
                    'listed in ${section.name}.',
                  );
                }

                for (final classId in classIds) {
                  await ApiService.createStudent(
                    token: token,
                    classId: classId,
                    studentNumber: studentNumber,
                    firstName: firstName,
                    lastName: lastName,
                    email: null,
                  );
                }

                return true;
              } catch (e) {
                if (context.mounted) {
                  setDialogState(() {
                    saving = false;
                    dialogError = e.toString().replaceFirst('Exception: ', '');
                  });
                }
                return false;
              }
            }

            Future<void> confirmAndSave() async {
              if (!valid || saving) return;

              final studentNumber = studentNumberController.text.trim();
              final firstName = clean(firstNameController.text);
              final lastName = clean(lastNameController.text);
              final fullName = '$lastName, $firstName'.trim();

              // Pre-check before opening the confirmation box:
              // 1. Check if already in this section.
              if (_sectionHasStudentNumber(section, studentNumber)) {
                setDialogState(() {
                  dialogError =
                      'A student with student number $studentNumber is already '
                      'listed in ${section.name}.';
                });
                return;
              }

              // 2. Check if already in another section (local + server check).
              final localOtherSection = _otherSectionForStudentNumber(
                section,
                studentNumber,
              );
              if (localOtherSection != null) {
                setDialogState(() {
                  dialogError =
                      'Student $studentNumber is already uploaded to section '
                      '$localOtherSection and cannot be added to ${section.name}.';
                });
                return;
              }

              setDialogState(() {
                saving = true;
                dialogError = null;
              });

              try {
                final token = await AuthStorage.getToken();
                if (token == null || token.isEmpty) {
                  throw Exception('Authentication token not found.');
                }

                final otherSectionStudents = await ApiService.getStudents(
                  token,
                  excludeSection: section.name,
                );
                for (final s in otherSectionStudents) {
                  if (_text(s['student_number']).toLowerCase() ==
                      studentNumber.toLowerCase()) {
                    final existingSec = _text(
                      (s['class'] is Map
                              ? (s['class'] as Map)['section']
                              : null) ??
                          s['section'],
                    );
                    if (existingSec.isNotEmpty) {
                      if (context.mounted) {
                        setDialogState(() {
                          saving = false;
                          dialogError =
                              'Student $studentNumber is already uploaded to '
                              'section $existingSec and cannot be added to '
                              '${section.name}.';
                        });
                      }
                      return;
                    }
                  }
                }
              } catch (e) {
                if (context.mounted) {
                  setDialogState(() {
                    saving = false;
                    dialogError = e.toString().replaceFirst('Exception: ', '');
                  });
                }
                return;
              }

              if (!context.mounted) return;
              setDialogState(() {
                saving = false;
              });

              final added = await showDialog<bool>(
                context: context,
                barrierDismissible: false,
                builder: (confirmContext) {
                  bool confirming = false;

                  return StatefulBuilder(
                    builder: (confirmContext, setConfirmState) {
                      Future<void> onProceed() async {
                        if (confirming) return;
                        setConfirmState(() => confirming = true);

                        final ok = await performSave();
                        if (!confirmContext.mounted) return;

                        Navigator.pop(confirmContext, ok);
                      }

                      return PopScope(
                        canPop: !confirming,
                        child: Dialog(
                          backgroundColor: Colors.white,
                          surfaceTintColor: Colors.transparent,
                          insetPadding: const EdgeInsets.all(24),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(24),
                          ),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 440),
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(
                                24,
                                22,
                                24,
                                24,
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  const Text(
                                    'Confirm Add Student',
                                    style: TextStyle(
                                      fontSize: 19,
                                      fontWeight: FontWeight.w700,
                                      color: CmColors.navy,
                                    ),
                                  ),
                                  const SizedBox(height: 14),
                                  Text.rich(
                                    TextSpan(
                                      style: const TextStyle(
                                        fontSize: 14,
                                        height: 1.5,
                                        color: CmColors.navy,
                                      ),
                                      children: [
                                        const TextSpan(text: 'You will add '),
                                        TextSpan(
                                          text: fullName,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                        const TextSpan(
                                          text: ', with student number ',
                                        ),
                                        TextSpan(
                                          text: studentNumber,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                        TextSpan(
                                          text:
                                              ', to section ${section.name}. '
                                              'Once added, the student’s details '
                                              'can be edited only once, and the '
                                              'student cannot be deleted from '
                                              'this section. Do you want to '
                                              'proceed?',
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 22),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: OutlinedButton(
                                          style: _secondaryButtonStyle,
                                          onPressed: confirming
                                              ? null
                                              : () => Navigator.pop(
                                                  confirmContext,
                                                  false,
                                                ),
                                          child: const Text('Cancel'),
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: FilledButton(
                                          style: _primaryButtonStyle,
                                          onPressed: confirming
                                              ? null
                                              : onProceed,
                                          child: confirming
                                              ? const SizedBox(
                                                  width: 20,
                                                  height: 20,
                                                  child:
                                                      CircularProgressIndicator(
                                                        strokeWidth: 2,
                                                        color: Colors.white,
                                                      ),
                                                )
                                              : const Text(
                                                  'Proceed',
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
                        ),
                      );
                    },
                  );
                },
              );

              if (added == true && dialogContext.mounted) {
                Navigator.pop(dialogContext, true);
              }
            }

            return PopScope(
              canPop: !saving,
              child: Dialog(
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
                                  : () => Navigator.pop(dialogContext, false),
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
                            onChanged: (_) =>
                                setDialogState(() => dialogError = null),
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
                            onChanged: (_) =>
                                setDialogState(() => dialogError = null),
                            decoration: _fieldDecoration(
                              errorText: shown(lastNameController, lastError),
                            ).copyWith(hintText: 'e.g. DELA CRUZ'),
                          ),
                        ),
                        const SizedBox(height: 14),
                        _labeled(
                          'First Name and Middle Name',
                          TextField(
                            controller: firstNameController,
                            enabled: !saving,
                            textCapitalization: TextCapitalization.words,
                            inputFormatters: [
                              _nameFormatter,
                              LengthLimitingTextInputFormatter(80),
                            ],
                            onChanged: (_) =>
                                setDialogState(() => dialogError = null),
                            decoration: _fieldDecoration(
                              errorText: shown(firstNameController, firstError),
                            ).copyWith(hintText: 'e.g. JUAN SANTOS'),
                          ),
                        ),
                        const SizedBox(height: 14),
                        _labeled(
                          'Section',
                          InputDecorator(
                            decoration: _fieldDecoration(
                              fillColor: CmColors.bg,
                            ),
                            child: Text(
                              section.name,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: CmColors.navy,
                              ),
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
                                    : () => Navigator.pop(dialogContext, false),
                                child: const Text('Cancel'),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: FilledButton(
                                style: _primaryButtonStyle,
                                onPressed: valid && !saving
                                    ? confirmAndSave
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
  // EDIT STUDENT (ONE TIME ONLY)
  // =========================

  Future<void> _showEditStudentDialog(Map<String, dynamic> student) async {
    final studentId = _id(student['id']);
    if (studentId == null) return;

    final section = _sectionOf(student);

    String clean(String v) =>
        v.replaceAll(RegExp(r'\s+'), ' ').trim().toUpperCase();

    final origNumber = _text(student['student_number']);
    final origLast = clean(_text(student['last_name']));
    final origFirst = clean(_text(student['first_name']));
    final origEmail = _text(student['email']);

    final studentNumberController = TextEditingController(text: origNumber);
    final lastNameController = TextEditingController(text: origLast);
    final firstNameController = TextEditingController(text: origFirst);
    const studentEmailDomain = '@malolos.sti.edu.ph';

    final existingEmailUsername = origEmail.contains('@')
        ? origEmail.split('@').first
        : '';

    final surname = origLast.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

    final studentDigits = origNumber.replaceAll(RegExp(r'\D'), '');
    final lastSixDigits = studentDigits.length >= 6
        ? studentDigits.substring(studentDigits.length - 6)
        : studentDigits;

    final suggestedUsername = surname.isEmpty
        ? lastSixDigits
        : '$surname.$lastSixDigits';

    final initialUsername = existingEmailUsername.isNotEmpty
        ? existingEmailUsername
        : suggestedUsername;

    final emailController = TextEditingController(text: initialUsername);
    bool emailTouched = false;

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        bool saving = false;
        String? dialogError;

        return StatefulBuilder(
          builder: (context, setDialogState) {
            final number = studentNumberController.text.trim();
            final numberChanged =
                number.toLowerCase() != origNumber.toLowerCase();
            final lastChanged = clean(lastNameController.text) != origLast;
            final firstChanged = clean(firstNameController.text) != origFirst;
            final emailUsername = emailController.text.trim();
            final emailValue = emailUsername.isEmpty
                ? null
                : '$emailUsername$studentEmailDomain';

            final emailChanged =
                emailTouched && (emailValue ?? '') != origEmail;

            // Fields that were not touched are not re-validated, so an
            // imported record can still have just its email filled in.
            final numberError = numberChanged
                ? StudentValidation.studentNumber(number)
                : (number.isEmpty ? 'Student number is required.' : null);
            final lastError = lastNameController.text.trim().isEmpty
                ? 'Last name is required.'
                : (lastChanged
                      ? StudentValidation.name(
                          lastNameController.text,
                          label: 'Last name',
                        )
                      : null);
            final firstError = firstNameController.text.trim().isEmpty
                ? 'First and middle name is required.'
                : (firstChanged
                      ? StudentValidation.name(
                          firstNameController.text,
                          label: 'First and middle name',
                        )
                      : null);
            final emailError = emailTouched
                ? StudentValidation.studentEmailUsername(emailUsername)
                : null;
            final hasChanges =
                numberChanged || lastChanged || firstChanged || emailChanged;
            final valid =
                hasChanges &&
                numberError == null &&
                lastError == null &&
                firstError == null &&
                emailError == null;

            // Error text only appears once the field has something in it
            // (or it was changed), like the Add Student form.
            String? shown(bool changed, String? error) =>
                changed ? error : null;

            Future<void> confirmAndSave() async {
              if (!valid || saving) return;

              // Duplicate checks against what the screen already knows. The
              // server repeats them.
              if (numberChanged && section != null) {
                if (_sectionHasStudentNumber(section, number)) {
                  setDialogState(() {
                    dialogError =
                        'A student with student number $number is already '
                        'listed in ${section.name}.';
                  });
                  return;
                }
                final other = _otherSectionForStudentNumber(section, number);
                if (other != null) {
                  setDialogState(() {
                    dialogError =
                        'Student $number is already uploaded to section '
                        '$other and cannot be used in ${section.name}.';
                  });
                  return;
                }
              }

              final proceed = await showDialog<bool>(
                context: context,
                barrierDismissible: false,
                builder: (confirmContext) => AlertDialog(
                  backgroundColor: Colors.white,
                  surfaceTintColor: Colors.transparent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(24),
                  ),
                  title: const Text(
                    'Save changes?',
                    style: TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w700,
                      color: CmColors.navy,
                    ),
                  ),
                  content: const Text(
                    'A student’s details can be edited only once. After '
                    'saving, they can no longer be changed. Do you want to '
                    'proceed?',
                    style: TextStyle(height: 1.5, color: CmColors.navy),
                  ),
                  actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                  actions: [
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: CmColors.navy,
                        side: const BorderSide(color: CmColors.line),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: () => Navigator.pop(confirmContext, false),
                      child: const Text('Go back'),
                    ),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: CmColors.navy,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: () => Navigator.pop(confirmContext, true),
                      child: const Text(
                        'Save',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
              );

              if (proceed != true || !context.mounted) return;

              setDialogState(() {
                saving = true;
                dialogError = null;
              });

              try {
                final token = await AuthStorage.getToken();
                if (token == null || token.isEmpty) {
                  throw Exception('Authentication token not found.');
                }

                final emailToSave = emailTouched
                    ? emailValue
                    : (origEmail.isEmpty ? null : origEmail);

                await ApiService.updateStudent(
                  token: token,
                  studentId: studentId,
                  studentNumber: number,
                  firstName: clean(firstNameController.text),
                  lastName: clean(lastNameController.text),
                  email: emailToSave,
                );

                if (dialogContext.mounted) {
                  Navigator.pop(dialogContext, true);
                }
              } catch (e) {
                if (context.mounted) {
                  setDialogState(() {
                    saving = false;
                    dialogError = e.toString().replaceFirst('Exception: ', '');
                  });
                }
              }
            }

            return PopScope(
              canPop: !saving,
              child: Dialog(
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
                                'Edit Student Details',
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
                                  : () => Navigator.pop(dialogContext, false),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          section == null
                              ? 'You can edit these details only once.'
                              : 'You can edit these details only once. '
                                    'Changes apply to this student in every '
                                    'subject of ${section.name} that you '
                                    'teach.',
                          style: const TextStyle(
                            fontSize: 12.5,
                            height: 1.4,
                            color: CmColors.slate,
                          ),
                        ),
                        const SizedBox(height: 16),
                        _labeled(
                          'Email username (optional)',
                          TextField(
                            controller: emailController,
                            enabled: !saving,
                            keyboardType: TextInputType.emailAddress,
                            autocorrect: false,
                            inputFormatters: [
                              FilteringTextInputFormatter.deny(RegExp(r'\s')),
                              LengthLimitingTextInputFormatter(
                                255 - studentEmailDomain.length,
                              ),
                            ],
                            onChanged: (_) => setDialogState(() {
                              emailTouched = true;
                              dialogError = null;
                            }),
                            decoration:
                                _fieldDecoration(
                                  errorText: shown(emailTouched, emailError),
                                ).copyWith(
                                  hintText: 'Enter email username',
                                  suffixText: studentEmailDomain,
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
                                    : () => Navigator.pop(dialogContext, false),
                                child: const Text('Cancel'),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: FilledButton(
                                style: _primaryButtonStyle,
                                onPressed: valid && !saving
                                    ? confirmAndSave
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
                                        'Save Changes',
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
              ),
            );
          },
        );
      },
    );

    studentNumberController.dispose();
    lastNameController.dispose();
    firstNameController.dispose();
    emailController.dispose();

    if (result == true) {
      await _loadData();

      if (!mounted) return;

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Student details updated.')));
    }
  }

  // =========================
  // ADD STUDENTS (section-specific chooser)
  // =========================

  Future<void> _showAddStudentsSheet({
    required _AssignedSection section,
  }) async {
    // Use the section's actual student count (ignoring search/filter results)
    // to decide whether Import Excel is offered.
    final canImportExcel = _actualStudentCount(section) == 0;

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
              const SizedBox(height: 4),
              Text(
                'Section ${section.name}',
                style: const TextStyle(color: CmColors.slate),
              ),
              const SizedBox(height: 14),
              if (canImportExcel) ...[
                _optionTile(
                  icon: Icons.upload_file_outlined,
                  title: 'Import Excel',
                  subtitle: 'Upload a student list using an .xlsx file.',
                  onTap: () => Navigator.pop(context, 'import'),
                ),
                const SizedBox(height: 10),
              ],
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
      // Do not allow Import Excel if the section already has at least one student.
      if (_actualStudentCount(section) > 0) return;

      final populatedSections = _assigned
          .where((s) => _actualStudentCount(s) > 0)
          .map((s) => s.name)
          .where((name) => name.isNotEmpty)
          .toSet()
          .toList();

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
            populatedSections: populatedSections,
            initialSection: section.name,
            initialClass: section.classes.isNotEmpty
                ? section.classes.first
                : null,
            sectionClasses: section.classes,
          ),
        ),
      );
      if (changed == true && mounted) {
        await _loadData();
      }
    } else {
      if (_classes.isEmpty || section.classes.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'No sections are assigned to you yet. Ask an '
              'administrator to assign your subjects and sections.',
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
    final last = (s['last_name']?.toString() ?? '').trim().toUpperCase();
    final first = (s['first_name']?.toString() ?? '').trim().toUpperCase();
    if (last.isEmpty && first.isEmpty) return 'UNNAMED STUDENT';
    if (last.isEmpty) return first;
    if (first.isEmpty) return last;
    return '$last, $first';
  }

  bool _matches(Map<String, dynamic> s) {
    if (_query.isEmpty) return true;
    final first = (s['first_name']?.toString() ?? '').trim();
    final last = (s['last_name']?.toString() ?? '').trim();
    final haystack = [
      _fullName(s),
      '$last $first',
      '$first $last',
      s['student_number']?.toString() ?? '',
      s['email']?.toString() ?? '',
      _studentSection(s),
    ].join(' ').toLowerCase();
    return haystack.contains(_query);
  }

  /// Actual number of distinct students enrolled in [section], independent of
  /// any active search query or dropdown filters.
  int _actualStudentCount(_AssignedSection? section) {
    if (section == null) return 0;
    final identities = <String>{};
    for (var i = 0; i < _students.length; i++) {
      final student = _students[i];
      final classId = _studentClassId(student);
      final key = classId == null ? null : _classToSection[classId];
      if (key != section.key) continue;
      final number = _text(student['student_number']).toLowerCase();
      final identity = number.isNotEmpty
          ? 'number:$number'
          : 'id:${student['id'] ?? i}';
      identities.add(identity);
    }
    return identities.length;
  }

  bool _sectionHasStudentNumber(
    _AssignedSection section,
    String studentNumber,
  ) {
    final wanted = studentNumber.trim().toLowerCase();
    if (wanted.isEmpty) return false;
    for (final student in _students) {
      final classId = _studentClassId(student);
      final key = classId == null ? null : _classToSection[classId];
      if (key != section.key) continue;
      if (_text(student['student_number']).toLowerCase() == wanted) {
        return true;
      }
    }
    return false;
  }

  String? _otherSectionForStudentNumber(
    _AssignedSection targetSection,
    String studentNumber,
  ) {
    final wanted = studentNumber.trim().toLowerCase();
    if (wanted.isEmpty) return null;
    final targetNorm = _sectionName(targetSection.name);
    for (final student in _students) {
      if (_text(student['student_number']).toLowerCase() != wanted) continue;
      final secName = _studentSection(student);
      if (secName.isNotEmpty && _sectionName(secName) != targetNorm) {
        return secName;
      }
    }
    return null;
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

    // Empty sections must remain expanded by default.
    for (final section in _assigned) {
      if (_actualStudentCount(section) == 0) {
        _collapsedSectionKeys.remove(section.key);
      }
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
          assignedSection: section,
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
          count: _actualStudentCount(section),
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

  Future<void> _showStudentEmailsDialog(_AssignedSection section) async {
    // Collect every student enrolled in any subject class in this section.
    // A student enrolled in multiple subjects appears only once.
    final byIdentity = <String, Map<String, dynamic>>{};

    for (var i = 0; i < _students.length; i++) {
      final student = _students[i];
      final classId = _studentClassId(student);
      final sectionKey = classId == null ? null : _classToSection[classId];

      if (sectionKey != section.key) continue;

      final number = _text(student['student_number']);
      final identity = number.isNotEmpty
          ? 'number:${number.toLowerCase()}'
          : 'id:${student['id'] ?? i}';

      final existing = byIdentity[identity];

      if (existing == null) {
        byIdentity[identity] = student;
      } else if (_text(existing['email']).isEmpty &&
          _text(student['email']).isNotEmpty) {
        // Prefer an existing email if another subject row contains one.
        byIdentity[identity] = student;
      }
    }

    final students = byIdentity.values.toList()
      ..sort(
        (a, b) =>
            _text(a['student_number']).compareTo(_text(b['student_number'])),
      );

    const studentEmailDomain = '@malolos.sti.edu.ph';

    final entries = students.map((student) {
      final email = _text(student['email']);
      final username = email.contains('@') ? email.split('@').first : email;

      return <String, dynamic>{
        'student_number': _text(student['student_number']),
        'name': _fullName(student),
        'original_email': email,
        'original_username': username,
        'controller': TextEditingController(text: username),
      };
    }).toList();

    Map<String, dynamic>? result;

    try {
      result = await showDialog<Map<String, dynamic>>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) {
          var saving = false;
          String? saveError;
          String? importMessage;
          bool replaceExistingEmails = false;

          return StatefulBuilder(
            builder: (context, setDialogState) {
              final changedCount = entries.where((entry) {
                final controller = entry['controller'] as TextEditingController;
                return controller.text.trim() !=
                    (entry['original_username'] as String).trim();
              }).length;

              return AlertDialog(
                title: Text(
                  'Student emails · ${section.name}',
                  style: const TextStyle(
                    color: CmColors.navy,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                content: SizedBox(
                  width: 520,
                  height: 500,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '${entries.length} unique student${entries.length == 1 ? '' : 's'}',
                        style: const TextStyle(
                          color: CmColors.slate,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 12),

                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          const Text(
                            'Download the template first, fill in the students’ email addresses, '
                            'then upload the completed file. Review the changes before saving.',
                            style: TextStyle(
                              color: CmColors.slate,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 10),
                          OutlinedButton.icon(
                            onPressed: saving
                                ? null
                                : () async {
                                    const mime =
                                        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';

                                    try {
                                      final bytes =
                                          StudentEmailExcelService.buildTemplate(
                                            entries: entries,
                                          );

                                      final safeSection = section.name
                                          .replaceAll(
                                            RegExp(r'[^A-Za-z0-9_-]'),
                                            '_',
                                          );

                                      final fileName =
                                          'CheckMate_Student_Emails_$safeSection.xlsx';

                                      final file = XFile.fromData(
                                        Uint8List.fromList(bytes),
                                        name: fileName,
                                        mimeType: mime,
                                      );

                                      final isDesktop =
                                          defaultTargetPlatform ==
                                              TargetPlatform.windows ||
                                          defaultTargetPlatform ==
                                              TargetPlatform.macOS ||
                                          defaultTargetPlatform ==
                                              TargetPlatform.linux;

                                      if (kIsWeb) {
                                        await file.saveTo(fileName);
                                      } else if (isDesktop) {
                                        final location = await getSaveLocation(
                                          suggestedName: fileName,
                                          acceptedTypeGroups: const [
                                            XTypeGroup(
                                              label: 'Excel',
                                              extensions: ['xlsx'],
                                            ),
                                          ],
                                        );

                                        if (location == null) return;

                                        await file.saveTo(location.path);
                                      } else {
                                        await SharePlus.instance.share(
                                          ShareParams(
                                            files: [file],
                                            subject:
                                                'Student emails - ${section.name}',
                                          ),
                                        );
                                      }

                                      if (!dialogContext.mounted) return;

                                      setDialogState(() {
                                        importMessage = 'Excel template prepared successfully.';
                                      });
                                    } catch (e) {
                                      if (!dialogContext.mounted) return;

                                      setDialogState(() {
                                        importMessage = 'Download failed: $e';
                                      });
                                    }
                                  },
                            icon: const Icon(Icons.download_outlined),
                            label: const Text(
                              'Step 1 — Download Excel Template',
                            ),
                          ),

                          OutlinedButton.icon(
                            onPressed: saving
                                ? null
                                : () async {
                                    try {
                                      const xlsxType = XTypeGroup(
                                        label: 'Excel',
                                        extensions: ['xlsx'],
                                        mimeTypes: [
                                          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
                                        ],
                                      );

                                      final file = await openFile(
                                        acceptedTypeGroups: [xlsxType],
                                      );

                                      if (file == null) return;

                                      final bytes = await file.readAsBytes();
                                      final imported =
                                          StudentEmailExcelService.parse(bytes);

                                      final entriesByNumber =
                                          <String, Map<String, dynamic>>{
                                            for (final entry in entries)
                                              (entry['student_number']
                                                          as String)
                                                      .trim()
                                                      .toLowerCase():
                                                  entry,
                                          };

                                      final matchedNumbers = imported
                                          .where(
                                            (row) =>
                                                entriesByNumber.containsKey(
                                                  row.studentNumber
                                                      .trim()
                                                      .toLowerCase(),
                                                ),
                                          )
                                          .map(
                                            (row) => row.studentNumber
                                                .trim()
                                                .toLowerCase(),
                                          )
                                          .toSet();

                                      if (matchedNumbers.isEmpty) {
                                        throw const FormatException(
                                          'This Excel file has no students matching the selected section.',
                                        );
                                      }

                                      final numberCounts = <String, int>{};
                                      final emailCounts = <String, int>{};

                                      for (final row in imported) {
                                        final number = row.studentNumber
                                            .trim()
                                            .toLowerCase();
                                        final email = row.email
                                            .trim()
                                            .toLowerCase();

                                        numberCounts.update(
                                          number,
                                          (count) => count + 1,
                                          ifAbsent: () => 1,
                                        );

                                        if (email.isNotEmpty) {
                                          emailCounts.update(
                                            email,
                                            (count) => count + 1,
                                            ifAbsent: () => 1,
                                          );
                                        }
                                      }

                                      final emailOwners =
                                          <String, Set<String>>{};

                                      for (final entry in entries) {
                                        final number =
                                            (entry['student_number'] as String)
                                                .trim()
                                                .toLowerCase();

                                        final email =
                                            (entry['controller']
                                                    as TextEditingController)
                                                .text
                                                .trim()
                                                .toLowerCase();

                                        if (email.isNotEmpty) {
                                          emailOwners
                                              .putIfAbsent(email, () => {})
                                              .add(number);
                                        }
                                      }

                                      final pending = <Map<String, dynamic>>[];
                                      final messages = <String>[];

                                      var unknownCount = 0;
                                      var invalidCount = 0;
                                      var duplicateCount = 0;
                                      var skippedExistingCount = 0;
                                      var blankCount = 0;

                                      for (final row in imported) {
                                        final number = row.studentNumber
                                            .trim()
                                            .toLowerCase();
                                        final email = row.email.trim();
                                        final normalizedEmail = email
                                            .toLowerCase();

                                        final entry = entriesByNumber[number];

                                        if (entry == null) {
                                          unknownCount++;
                                          continue;
                                        }

                                        if (numberCounts[number] != 1) {
                                          duplicateCount++;
                                          continue;
                                        }

                                        if (email.isEmpty) {
                                          blankCount++;
                                          continue;
                                        }

                                        final controller =
                                            entry['controller']
                                                as TextEditingController;

                                        final currentEmail = controller.text
                                            .trim();

                                        if (currentEmail.isNotEmpty &&
                                            !replaceExistingEmails) {
                                          skippedExistingCount++;
                                          continue;
                                        }

                                        if (StudentValidation.studentEmailUsername(
                                              email,
                                            ) !=
                                            null) {
                                          invalidCount++;
                                          messages.add(
                                            'Invalid email username: ${row.studentNumber}',
                                          );
                                          continue;
                                        }
                                        if ((emailCounts[normalizedEmail] ??
                                                0) >
                                            1) {
                                          duplicateCount++;
                                          messages.add(
                                            'Duplicate Excel email: $normalizedEmail',
                                          );
                                          continue;
                                        }

                                        final owners =
                                            emailOwners[normalizedEmail] ?? {};

                                        if (owners.any(
                                          (owner) => owner != number,
                                        )) {
                                          duplicateCount++;
                                          messages.add(
                                            'Email already belongs to another student: $normalizedEmail',
                                          );
                                          continue;
                                        }

                                        pending.add({
                                          'controller': controller,
                                          'email': email,
                                        });
                                      }

                                      if (!dialogContext.mounted) return;

                                      setDialogState(() {
                                        for (final item in pending) {
                                          (item['controller']
                                                      as TextEditingController)
                                                  .text =
                                              item['email'] as String;
                                        }

                                        final parts = <String>[
                                          '${pending.length} email(s) filled in.',
                                          if (unknownCount > 0)
                                            '$unknownCount unknown student(s)',
                                          if (invalidCount > 0)
                                            '$invalidCount invalid email(s)',
                                          if (duplicateCount > 0)
                                            '$duplicateCount duplicate(s)',
                                          if (skippedExistingCount > 0)
                                            '$skippedExistingCount existing email(s) kept',
                                          if (blankCount > 0)
                                            '$blankCount blank email(s) kept',
                                        ];

                                        importMessage = parts.join(' ');
                                        if (messages.isNotEmpty) {
                                          importMessage =
                                              '$importMessage\n${messages.take(5).join('\n')}';
                                        }
                                      });
                                    } catch (e) {
                                      if (!dialogContext.mounted) return;

                                      setDialogState(() {
                                        importMessage =
                                            'Upload failed: ${e.toString().replaceFirst('FormatException: ', '')}';
                                      });
                                    }
                                  },
                            icon: const Icon(Icons.upload_file_outlined),
                            label: const Text(
                              'Step 2 — Upload Filled Excel Template',
                            ),
                          ),
                        ],
                      ),

                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        value: replaceExistingEmails,
                        onChanged: saving
                            ? null
                            : (value) {
                                setDialogState(() {
                                  replaceExistingEmails = value ?? false;
                                });
                              },
                        title: const Text(
                          'Replace emails that are already filled in',
                          style: TextStyle(fontSize: 13),
                        ),
                      ),

                      if (importMessage != null) ...[
                        Text(
                          importMessage!,
                          style: const TextStyle(
                            color: CmColors.slate,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 8),
                      ],

                      if (saveError != null) ...[
                        Text(
                          saveError!,
                          style: const TextStyle(
                            color: Color(0xFFDC2626),
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 8),
                      ],
                      Expanded(
                        child: entries.isEmpty
                            ? const Center(
                                child: Text(
                                  'No students are listed in this section.',
                                  textAlign: TextAlign.center,
                                ),
                              )
                            : ListView.separated(
                                itemCount: entries.length,
                                separatorBuilder: (_, _) =>
                                    const Divider(height: 20),
                                itemBuilder: (context, index) {
                                  final entry = entries[index];
                                  final controller =
                                      entry['controller']
                                          as TextEditingController;

                                  return Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        entry['name'] as String,
                                        style: const TextStyle(
                                          color: CmColors.navy,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        entry['student_number'] as String,
                                        style: const TextStyle(
                                          color: CmColors.slate,
                                          fontSize: 12,
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      TextField(
                                        controller: controller,
                                        enabled: !saving,
                                        keyboardType:
                                            TextInputType.emailAddress,
                                        autocorrect: false,
                                        inputFormatters: [
                                          FilteringTextInputFormatter.deny(
                                            RegExp(r'\s'),
                                          ),
                                          LengthLimitingTextInputFormatter(
                                            255 - studentEmailDomain.length,
                                          ),
                                        ],
                                        decoration:
                                            _fieldDecoration(
                                              fillColor: CmColors.bg,
                                            ).copyWith(
                                              hintText: 'Enter email username',
                                              prefixIcon: const Icon(
                                                Icons.email_outlined,
                                                size: 19,
                                              ),
                                              suffixText: studentEmailDomain,
                                              errorText:
                                                  controller.text.trim().isEmpty
                                                  ? null
                                                  : StudentValidation.studentEmailUsername(
                                                      controller.text,
                                                    ),
                                            ),
                                        onChanged: (_) {
                                          setDialogState(() {});
                                        },
                                      ),
                                    ],
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: saving
                        ? null
                        : () => Navigator.of(dialogContext).pop(),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed: saving || changedCount == 0
                        ? null
                        : () async {
                            final invalidEntries = entries.where((entry) {
                              final controller =
                                  entry['controller'] as TextEditingController;

                              return StudentValidation.studentEmailUsername(
                                    controller.text,
                                  ) !=
                                  null;
                            }).toList();

                            if (invalidEntries.isNotEmpty) {
                              setDialogState(() {
                                saveError = 'Please correct the invalid email usernames before saving.';
                              });
                              return;
                            }

                            final updates = entries
                                .where((entry) {
                                  final controller =
                                      entry['controller']
                                          as TextEditingController;

                                  return controller.text.trim() !=
                                      (entry['original_username'] as String)
                                          .trim();
                                })
                                .map((entry) {
                                  final username =
                                      (entry['controller']
                                              as TextEditingController)
                                          .text
                                          .trim();

                                  return <String, dynamic>{
                                    'student_number': entry['student_number'],
                                    'email': username.isEmpty
                                        ? null
                                        : '$username$studentEmailDomain',
                                  };
                                })
                                .toList();

                            setDialogState(() {
                              saving = true;
                              saveError = null;
                            });

                            try {
                              final token = await AuthStorage.getToken();
                              if (token == null || token.isEmpty) {
                                throw Exception(
                                  'Authentication token not found.',
                                );
                              }

                              final response =
                                  await ApiService.updateStudentEmails(
                                    token: token,
                                    section: section.name,
                                    updates: updates,
                                  );

                              if (dialogContext.mounted) {
                                Navigator.of(dialogContext).pop(response);
                              }
                            } catch (e) {
                              setDialogState(() {
                                saving = false;
                                saveError = e.toString().replaceFirst(
                                  'Exception: ',
                                  '',
                                );
                              });
                            }
                          },
                    style: FilledButton.styleFrom(
                      backgroundColor: CmColors.navy,
                    ),
                    child: saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : Text('Save changes ($changedCount)'),
                  ),
                ],
              );
            },
          );
        },
      );
    } finally {
      for (final entry in entries) {
        (entry['controller'] as TextEditingController).dispose();
      }
    }

    if (!mounted || result == null) return;

    await _loadData();

    final errors = result['errors'];
    final errorCount = errors is List ? errors.length : 0;
    final updated = result['updated'] ?? 0;

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          errorCount > 0
              ? 'Email update completed. Updated: $updated. Skipped/errors: $errorCount.'
              : 'Student emails saved successfully. Updated: $updated.',
        ),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  /// Displays student details. A student's details (name, student number,
  /// email) can be edited ONCE; after that they are locked. A student cannot
  /// be deleted from the section.
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
              const SizedBox(height: 8),
              if (student['edited_at'] == null) ...[
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    style: _secondaryButtonStyle,
                    onPressed: () {
                      Navigator.pop(context);
                      _showEditStudentDialog(student);
                    },
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text(
                      'Edit details',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Fill in the email or fix a typo. This can be done only once.',
                  style: TextStyle(fontSize: 12, color: CmColors.slate),
                ),
              ] else
                const Text(
                  'These details were already edited once and can no longer '
                  'be changed.',
                  style: TextStyle(fontSize: 12, color: CmColors.slate),
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
                        _sectionKey = null;
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
    body: RefreshIndicator(onRefresh: _loadData, child: _buildBody()),
  );

  Widget _studentTile(Map<String, dynamic> student) {
    final lastName = (student['last_name']?.toString() ?? '').trim();
    final firstName = (student['first_name']?.toString() ?? '').trim();
    final initialSource = lastName.isNotEmpty ? lastName : firstName;
    return Padding(
      padding: const EdgeInsets.only(bottom: _studentTileSpacing),
      child: SizedBox(
        height: _studentTileHeight,
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
                initialSource.isNotEmpty ? initialSource[0].toUpperCase() : '?',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            title: Text(
              _fullName(student),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: CmColors.navy,
              ),
            ),
            subtitle: Text(
              student['student_number']?.toString() ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: CmColors.slate),
            ),
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
    final actualCount = _actualStudentCount(section);
    final isEmptySection = actualCount == 0;
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
                borderRadius: BorderRadius.vertical(
                  top: const Radius.circular(17),
                  bottom: collapsed ? const Radius.circular(17) : Radius.zero,
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
                  child: isEmptySection
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
                          children: [
                            if (students.length > _maxVisibleStudents)
                              SizedBox(
                                height:
                                    _maxVisibleStudents * _studentRowExtent -
                                    _studentTileSpacing,
                                child: Scrollbar(
                                  thumbVisibility: true,
                                  child: ListView.builder(
                                    primary: false,
                                    padding: EdgeInsets.zero,
                                    physics: const ClampingScrollPhysics(),
                                    itemCount: students.length,
                                    itemExtent: _studentRowExtent,
                                    itemBuilder: (context, index) =>
                                        _studentTile(students[index]),
                                  ),
                                ),
                              )
                            else
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: students.map(_studentTile).toList(),
                              ),
                            const SizedBox(height: 4),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  OutlinedButton(
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: CmColors.navy,
                                      backgroundColor: CmColors.bg,
                                      side: const BorderSide(
                                        color: CmColors.line,
                                      ),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 8,
                                      ),
                                      minimumSize: const Size(0, 34),
                                      tapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                    ),
                                    onPressed: section == null
                                        ? null
                                        : () => _showAddStudentsSheet(
                                            section: section,
                                          ),
                                    child: const Text(
                                      '+ Add students',
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  OutlinedButton.icon(
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: CmColors.navy,
                                      backgroundColor: Colors.white,
                                      side: const BorderSide(
                                        color: CmColors.line,
                                      ),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 8,
                                      ),
                                      minimumSize: const Size(0, 34),
                                      tapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                    ),
                                    onPressed: section == null
                                        ? null
                                        : () =>
                                              _showStudentEmailsDialog(section),
                                    icon: const Icon(
                                      Icons.email_outlined,
                                      size: 16,
                                    ),
                                    label: const Text(
                                      'Student emails',
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
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
      var section = entry.assignedSection;
      for (
        var j = i + 1;
        j < entries.length && entries[j] is! _GroupHeader;
        j++
      ) {
        final item = entries[j];
        if (item is _EmptySection) {
          section ??= item.section;
        } else if (item is Map<String, dynamic>) {
          students.add(item);
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
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
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
                  const gap = 16.0;
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
    this.assignedSection,
  });
  final String section;
  final String subject;
  final int count;
  final _AssignedSection? assignedSection;
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
