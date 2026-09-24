import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../services/auth_storage.dart';

class ClassesScreen extends StatefulWidget {
  const ClassesScreen({super.key});

  @override
  State<ClassesScreen> createState() => _ClassesScreenState();
}

class _ClassesScreenState extends State<ClassesScreen> {
  List<Map<String, dynamic>> _classes = [];
  List<Map<String, dynamic>> _subjects = [];
  List<Map<String, dynamic>> _teachers = [];

  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadData();
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
        ApiService.getClasses(token),
        ApiService.getSubjects(token),
        ApiService.getTeachers(token),
      ]);

      if (!mounted) return;

      setState(() {
        _classes = results[0];
        _subjects = results[1];
        _teachers = results[2];
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

  Future<void> _showAddClassDialog() async {
    int? selectedSubjectId;
    int? selectedTeacherId;

    final sectionController = TextEditingController();
    final schoolYearController = TextEditingController();

    String? selectedSemester;

    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        bool saving = false;
        String? dialogError;

        return StatefulBuilder(
          builder: (context, setDialogState) {
            Future<void> saveClass() async {
              if (selectedSubjectId == null) {
                setDialogState(() {
                  dialogError = 'Please select a subject.';
                });
                return;
              }

              if (selectedTeacherId == null) {
                setDialogState(() {
                  dialogError = 'Please select a teacher.';
                });
                return;
              }

              final section = sectionController.text.trim();

              if (section.isEmpty) {
                setDialogState(() {
                  dialogError = 'Section is required.';
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
                  throw Exception(
                    'Authentication token not found.',
                  );
                }

                await ApiService.createClass(
                  token: token,
                  subjectId: selectedSubjectId!,
                  teacherId: selectedTeacherId!,
                  section: section,
                  schoolYear:
                      schoolYearController.text.trim().isEmpty
                          ? null
                          : schoolYearController.text.trim(),
                  semester: selectedSemester,
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

            return AlertDialog(
              title: const Text('Add Class'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DropdownButtonFormField<int>(
                      value: selectedSubjectId,
                      decoration: const InputDecoration(
                        labelText: 'Subject',
                        prefixIcon: Icon(
                          Icons.menu_book_outlined,
                        ),
                        border: OutlineInputBorder(),
                      ),
                      items: _subjects.map((subject) {
                        final id = int.parse(
                          subject['id'].toString(),
                        );

                        final name =
                            subject['name']?.toString() ??
                                'Unnamed Subject';

                        final code =
                            subject['code']?.toString();

                        return DropdownMenuItem<int>(
                          value: id,
                          child: Text(
                            code == null || code.isEmpty
                                ? name
                                : '$code - $name',
                          ),
                        );
                      }).toList(),
                      onChanged: saving
                          ? null
                          : (value) {
                              setDialogState(() {
                                selectedSubjectId = value;
                              });
                            },
                    ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<int>(
                      value: selectedTeacherId,
                      decoration: const InputDecoration(
                        labelText: 'Teacher',
                        prefixIcon: Icon(
                          Icons.person_outline,
                        ),
                        border: OutlineInputBorder(),
                      ),
                      items: _teachers.map((teacher) {
                        final id = int.parse(
                          teacher['id'].toString(),
                        );

                        final name =
                            teacher['name']?.toString() ??
                                'Unnamed Teacher';

                        return DropdownMenuItem<int>(
                          value: id,
                          child: Text(name),
                        );
                      }).toList(),
                      onChanged: saving
                          ? null
                          : (value) {
                              setDialogState(() {
                                selectedTeacherId = value;
                              });
                            },
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: sectionController,
                      enabled: !saving,
                      decoration: const InputDecoration(
                        labelText: 'Section',
                        hintText: 'e.g. BSIT-3A',
                        prefixIcon: Icon(
                          Icons.class_outlined,
                        ),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: schoolYearController,
                      enabled: !saving,
                      decoration: const InputDecoration(
                        labelText: 'School Year',
                        hintText: 'e.g. 2026-2027',
                        prefixIcon: Icon(
                          Icons.calendar_today_outlined,
                        ),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<String>(
                      value: selectedSemester,
                      decoration: const InputDecoration(
                        labelText: 'Semester',
                        prefixIcon: Icon(
                          Icons.calendar_month_outlined,
                        ),
                        border: OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: '1st Semester',
                          child: Text('1st Semester'),
                        ),
                        DropdownMenuItem(
                          value: '2nd Semester',
                          child: Text('2nd Semester'),
                        ),
                        DropdownMenuItem(
                          value: 'Summer',
                          child: Text('Summer'),
                        ),
                      ],
                      onChanged: saving
                          ? null
                          : (value) {
                              setDialogState(() {
                                selectedSemester = value;
                              });
                            },
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
                          Navigator.pop(context, false);
                        },
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: saving ? null : saveClass,
                  child: saving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
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

    sectionController.dispose();
    schoolYearController.dispose();

    if (result == true) {
      await _loadData();

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Class added successfully.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Classes'),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showAddClassDialog,
        icon: const Icon(Icons.add),
        label: const Text('Add Class'),
      ),
      body: RefreshIndicator(
        onRefresh: _loadData,
        child: _buildBody(),
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

    if (_classes.isEmpty) {
      return ListView(
        children: const [
          SizedBox(height: 140),
          Center(
            child: Column(
              children: [
                Icon(
                  Icons.class_outlined,
                  size: 56,
                ),
                SizedBox(height: 16),
                Text(
                  'No classes yet.',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                SizedBox(height: 8),
                Text(
                  'Tap "Add Class" to create one.',
                ),
              ],
            ),
          ),
        ],
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _classes.length,
      itemBuilder: (context, index) {
        final item = _classes[index];

        final section =
            item['section']?.toString() ??
                'Unknown Section';

        final schoolYear =
            item['school_year']?.toString() ?? '';

        final semester =
            item['semester']?.toString() ?? '';

        final subject = item['subject'];
        final teacher = item['teacher'];

        final subjectName = subject is Map
            ? subject['name']?.toString() ??
                'Unknown Subject'
            : 'Unknown Subject';

        final subjectCode = subject is Map
            ? subject['code']?.toString() ?? ''
            : '';

        final teacherName = teacher is Map
            ? teacher['name']?.toString() ??
                'Unknown Teacher'
            : 'Unknown Teacher';

        return Card(
          margin: const EdgeInsets.only(
            bottom: 12,
          ),
          child: ListTile(
            contentPadding: const EdgeInsets.all(16),
            leading: const CircleAvatar(
              child: Icon(Icons.class_outlined),
            ),
            title: Text(
              section,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(
                top: 8,
              ),
              child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  Text(
                    subjectCode.isEmpty
                        ? subjectName
                        : '$subjectCode - $subjectName',
                    style: const TextStyle(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Teacher: $teacherName',
                  ),
                  if (schoolYear.isNotEmpty ||
                      semester.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      [
                        if (schoolYear.isNotEmpty)
                          schoolYear,
                        if (semester.isNotEmpty)
                          semester,
                      ].join(' • '),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}