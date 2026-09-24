import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../services/auth_storage.dart';

class StudentsScreen extends StatefulWidget {
  const StudentsScreen({super.key});

  @override
  State<StudentsScreen> createState() => _StudentsScreenState();
}

class _StudentsScreenState extends State<StudentsScreen> {
  List<Map<String, dynamic>> _students = [];
  List<Map<String, dynamic>> _classes = [];

  int? _selectedClassId;

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
        ApiService.getStudents(
          token,
          classId: _selectedClassId,
        ),
        ApiService.getClasses(token),
      ]);

      if (!mounted) return;

      setState(() {
        _students =
            results[0] as List<Map<String, dynamic>>;
        _classes =
            results[1] as List<Map<String, dynamic>>;
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
                      value: selectedClassId,
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
                        hintText: 'e.g. 2026-00001',
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

  String _getClassLabel(
    Map<String, dynamic> item,
  ) {
    final section =
        item['section']?.toString() ??
            'Unknown Section';

    final subject = item['subject'];

    if (subject is! Map) {
      return section;
    }

    final name =
        subject['name']?.toString() ??
            'Unknown Subject';

    final code =
        subject['code']?.toString() ?? '';

    if (code.isEmpty) {
      return '$section - $name';
    }

    return '$section - $code - $name';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Students'),
      ),
      floatingActionButton:
          FloatingActionButton.extended(
        onPressed: _showAddStudentDialog,
        icon: const Icon(Icons.person_add),
        label: const Text('Add Student'),
      ),
      body: Column(
        children: [
          if (_classes.isNotEmpty)
            Padding(
              padding:
                  const EdgeInsets.fromLTRB(
                16,
                16,
                16,
                8,
              ),
              child:
                  DropdownButtonFormField<int?>(
                value: _selectedClassId,
                decoration:
                    const InputDecoration(
                  labelText: 'Filter by Class',
                  prefixIcon: Icon(
                    Icons.filter_list,
                  ),
                  border: OutlineInputBorder(),
                ),
                items: [
                  const DropdownMenuItem<int?>(
                    value: null,
                    child: Text('All Classes'),
                  ),
                  ..._classes.map((item) {
                    final id = int.parse(
                      item['id'].toString(),
                    );

                    return DropdownMenuItem<int?>(
                      value: id,
                      child: Text(
                        _getClassLabel(item),
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
        children: const [
          SizedBox(height: 120),
          Center(
            child: Column(
              children: [
                Icon(
                  Icons.people_outline,
                  size: 56,
                ),
                SizedBox(height: 16),
                Text(
                  'No students yet.',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                SizedBox(height: 8),
                Text(
                  'Tap "Add Student" to enroll one.',
                ),
              ],
            ),
          ),
        ],
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _students.length,
      itemBuilder: (context, index) {
        final student = _students[index];

        final studentNumber =
            student['student_number']
                    ?.toString() ??
                '';

        final firstName =
            student['first_name']?.toString() ??
                '';

        final lastName =
            student['last_name']?.toString() ??
                '';

        final email =
            student['email']?.toString() ?? '';

        final classData = student['class'];

        String classLabel =
            'Unknown Class';

        if (classData is Map) {
          final section =
              classData['section']
                      ?.toString() ??
                  '';

          final subject =
              classData['subject'];

          if (subject is Map) {
            final subjectName =
                subject['name']
                        ?.toString() ??
                    '';

            final subjectCode =
                subject['code']
                        ?.toString() ??
                    '';

            classLabel =
                subjectCode.isEmpty
                    ? '$section - $subjectName'
                    : '$section - '
                        '$subjectCode - '
                        '$subjectName';
          } else {
            classLabel = section;
          }
        }

        return Card(
          margin:
              const EdgeInsets.only(
            bottom: 12,
          ),
          child: ListTile(
            contentPadding:
                const EdgeInsets.all(16),
            leading: CircleAvatar(
              child: Text(
                firstName.isNotEmpty
                    ? firstName[0]
                        .toUpperCase()
                    : '?',
              ),
            ),
            title: Text(
              '$lastName, $firstName',
              style: const TextStyle(
                fontSize: 17,
                fontWeight:
                    FontWeight.bold,
              ),
            ),
            subtitle: Padding(
              padding:
                  const EdgeInsets.only(
                top: 8,
              ),
              child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  Text(
                    studentNumber,
                    style:
                        const TextStyle(
                      fontWeight:
                          FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(classLabel),
                  if (email.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(email),
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