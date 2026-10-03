import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../services/auth_storage.dart';
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

  Future<void> _showAddStudentDialog() async {
    int? selectedClassId = _selectedClassId;

    final studentNumberController =
        TextEditingController();

    final firstNameController =
        TextEditingController();

    final lastNameController =
        TextEditingController();

    final emailController =
        TextEditingController();

    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        bool saving = false;
        String? dialogError;

        return StatefulBuilder(
          builder: (context, setDialogState) {
            Future<void> saveStudent() async {
              if (selectedClassId == null) {
                setDialogState(() {
                  dialogError =
                      'Please select a class.';
                });
                return;
              }

              final studentNumber =
                  studentNumberController.text.trim();

              final firstName =
                  firstNameController.text.trim();

              final lastName =
                  lastNameController.text.trim();

              final email =
                  emailController.text.trim();

              if (studentNumber.isEmpty) {
                setDialogState(() {
                  dialogError =
                      'Student number is required.';
                });
                return;
              }

              if (firstName.isEmpty) {
                setDialogState(() {
                  dialogError =
                      'First name is required.';
                });
                return;
              }

              if (lastName.isEmpty) {
                setDialogState(() {
                  dialogError =
                      'Last name is required.';
                });
                return;
              }

              setDialogState(() {
                saving = true;
                dialogError = null;
              });

              try {
                final token =
                    await AuthStorage.getToken();

                if (token == null || token.isEmpty) {
                  throw Exception(
                    'Authentication token not found.',
                  );
                }

                await ApiService.createStudent(
                  token: token,
                  classId: selectedClassId!,
                  studentNumber: studentNumber,
                  firstName: firstName,
                  lastName: lastName,
                  email: email.isEmpty ? null : email,
                );

                if (!context.mounted) return;

                Navigator.pop(context, true);
              } catch (e) {
                setDialogState(() {
                  saving = false;
                  dialogError = e
                      .toString()
                      .replaceFirst(
                        'Exception: ',
                        '',
                      );
                });
              }
            }

            return AlertDialog(
              title: const Text('Add Student'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DropdownButtonFormField<int>(
                      initialValue: selectedClassId,
                      decoration: const InputDecoration(
                        labelText: 'Class',
                        prefixIcon: Icon(
                          Icons.class_outlined,
                        ),
                        border: OutlineInputBorder(),
                      ),
                      items: _classes.map((item) {
                        final id = int.parse(
                          item['id'].toString(),
                        );

                        final section =
                            item['section']
                                    ?.toString() ??
                                'Unknown Section';

                        final subject =
                            item['subject'];

                        final subjectName =
                            subject is Map
                                ? subject['name']
                                        ?.toString() ??
                                    'Unknown Subject'
                                : 'Unknown Subject';

                        final subjectCode =
                            subject is Map
                                ? subject['code']
                                        ?.toString() ??
                                    ''
                                : '';

                        final label =
                            subjectCode.isEmpty
                                ? '$section - $subjectName'
                                : '$section - '
                                    '$subjectCode '
                                    '- $subjectName';

                        return DropdownMenuItem<int>(
                          value: id,
                          child: Text(label),
                        );
                      }).toList(),
                      onChanged: saving
                          ? null
                          : (value) {
                              setDialogState(() {
                                selectedClassId =
                                    value;
                              });
                            },
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller:
                          studentNumberController,
                      enabled: !saving,
                      decoration:
                          const InputDecoration(
                        labelText: 'Student Number',
                        prefixIcon: Icon(
                          Icons.badge_outlined,
                        ),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: firstNameController,
                      enabled: !saving,
                      decoration:
                          const InputDecoration(
                        labelText: 'First Name',
                        prefixIcon: Icon(
                          Icons.person_outline,
                        ),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: lastNameController,
                      enabled: !saving,
                      decoration:
                          const InputDecoration(
                        labelText: 'Last Name',
                        prefixIcon: Icon(
                          Icons.person_outline,
                        ),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: emailController,
                      enabled: !saving,
                      keyboardType:
                          TextInputType.emailAddress,
                      decoration:
                          const InputDecoration(
                        labelText: 'Email',
                        hintText:
                            'Optional',
                        prefixIcon: Icon(
                          Icons.email_outlined,
                        ),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    if (dialogError != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        dialogError!,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Theme.of(context)
                              .colorScheme
                              .error,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: saving
                      ? null
                      : () {
                          Navigator.pop(
                            context,
                            false,
                          );
                        },
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed:
                      saving ? null : saveStudent,
                  child: saving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child:
                              CircularProgressIndicator(
                            strokeWidth: 2,
                          ),
                        )
                      : const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );

    studentNumberController.dispose();
    firstNameController.dispose();
    lastNameController.dispose();
    emailController.dispose();

    if (result == true) {
      await _loadData();

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Student added successfully.',
          ),
        ),
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
              CircleAvatar(
                backgroundColor: CmColors.bg,
                foregroundColor: CmColors.navy,
                child: Icon(icon),
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
              const Icon(Icons.chevron_right, color: CmColors.slate),
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
        icon: const Icon(Icons.group_add_outlined),
        label: const Text('Add Students'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
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
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          if (_classes.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: DropdownButtonFormField<int?>(
                initialValue: _selectedClassId,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Filter by Section',
                  prefixIcon: Icon(Icons.filter_list),
                  border: OutlineInputBorder(),
                  isDense: true,
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
                    color: CmColors.navy.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '${entry.count} Student${entry.count == 1 ? '' : 's'}',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: CmColors.navy,
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
          margin: const EdgeInsets.only(bottom: 8),
          child: ListTile(
            onTap: () => _showStudentInfo(student),
            minVerticalPadding: 10,
            leading: CircleAvatar(
              child: Text(
                firstName.isNotEmpty ? firstName[0].toUpperCase() : '?',
              ),
            ),
            title: Text(
              _fullName(student),
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            subtitle: Text(student['student_number']?.toString() ?? ''),
            trailing: const Icon(Icons.chevron_right),
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