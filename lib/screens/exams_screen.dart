import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../services/auth_storage.dart';
import 'exam_builder_screen.dart';

class ExamsScreen extends StatefulWidget {
  const ExamsScreen({super.key});

  @override
  State<ExamsScreen> createState() => _ExamsScreenState();
}

class _ExamsScreenState extends State<ExamsScreen> {
  List<Map<String, dynamic>> _exams = [];
  List<Map<String, dynamic>> _classes = [];

  String? _selectedSection;

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
        ApiService.getExams(token),
        ApiService.getClasses(token),
      ]);

      if (!mounted) return;

      setState(() {
        _exams = results[0];
        _classes = results[1];
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

  String _sectionOf(Map<String, dynamic> item) =>
      (item['section']?.toString() ?? '').trim();

  List<String> get _sections {
    final values =
        _classes
            .map(_sectionOf)
            .where((section) => section.isNotEmpty)
            .toSet()
            .toList()
          ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return values;
  }

  List<Map<String, dynamic>> get _visibleExams {
    if (_selectedSection == null) return _exams;
    final classIds = _classes
        .where((c) => _sectionOf(c) == _selectedSection)
        .map((c) => c['id']?.toString())
        .toSet();
    return _exams.where((exam) {
      final linkedClass = exam['class'];
      if (linkedClass is Map &&
          linkedClass['section']?.toString() == _selectedSection) {
        return true;
      }
      return classIds.contains(exam['class_id']?.toString()) ||
          (linkedClass is Map &&
              classIds.contains(linkedClass['id']?.toString()));
    }).toList();
  }

  Future<void> _chooseCreationMethod() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Create Exam',
                style: Theme.of(sheetContext).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              ListTile(
                leading: const Icon(Icons.edit_document),
                title: const Text('Build Exam'),
                subtitle: const Text(
                  'Create an exam using CheckMate questions and answer keys.',
                ),
                onTap: () => Navigator.pop(sheetContext, 'builder'),
              ),
              ListTile(
                leading: const Icon(Icons.picture_as_pdf_outlined),
                title: const Text('Upload Question Paper PDF'),
                subtitle: const Text(
                  'Use an existing PDF and configure its answer key.',
                ),
                onTap: () => Navigator.pop(sheetContext, 'pdf'),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;
    if (choice == 'builder') {
      await _showAddExamDialog();
    } else if (choice == 'pdf') {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('PDF Upload — Coming Next'),
          content: const Text(
            'The PDF upload workflow needs file storage and an API endpoint. '
            'It is not connected yet, so no exam or file will be saved. '
            'You can use Build Exam in the meantime.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
  }

  Future<void> _showAddExamDialog() async {
    int? selectedClassId;
    if (_selectedSection != null) {
      for (final item in _classes) {
        if (_sectionOf(item) == _selectedSection) {
          selectedClassId = int.tryParse(item['id']?.toString() ?? '');
          break;
        }
      }
    }

    final titleController = TextEditingController();
    final descriptionController = TextEditingController();
    final instructionsController = TextEditingController();

    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        bool saving = false;
        String? dialogError;

        return StatefulBuilder(
          builder: (context, setDialogState) {
            Future<void> saveExam() async {
              if (selectedClassId == null) {
                setDialogState(() {
                  dialogError = 'Please select a class.';
                });
                return;
              }

              final title = titleController.text.trim();
              final description = descriptionController.text.trim();
              final instructions = instructionsController.text.trim();

              if (title.isEmpty) {
                setDialogState(() {
                  dialogError = 'Exam title is required.';
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

                await ApiService.createExam(
                  token: token,
                  classId: selectedClassId!,
                  title: title,
                  description: description.isEmpty ? null : description,
                  instructions: instructions.isEmpty ? null : instructions,
                  status: 'draft',
                );

                if (!context.mounted) {
                  return;
                }

                Navigator.pop(context, true);
              } catch (e) {
                setDialogState(() {
                  saving = false;
                  dialogError = e.toString().replaceFirst('Exception: ', '');
                });
              }
            }

            return AlertDialog(
              title: const Text('Add Exam'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DropdownButtonFormField<int>(
                      initialValue: selectedClassId,
                      decoration: const InputDecoration(
                        labelText: 'Class',
                        prefixIcon: Icon(Icons.class_outlined),
                        border: OutlineInputBorder(),
                      ),
                      items: _classes.map((item) {
                        final id = int.parse(item['id'].toString());

                        return DropdownMenuItem<int>(
                          value: id,
                          child: Text(_getClassLabel(item)),
                        );
                      }).toList(),
                      onChanged: saving
                          ? null
                          : (value) {
                              setDialogState(() {
                                selectedClassId = value;
                              });
                            },
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: titleController,
                      enabled: !saving,
                      decoration: const InputDecoration(
                        labelText: 'Exam Title',
                        hintText: 'e.g. Computer Programming Midterm Exam',
                        prefixIcon: Icon(Icons.assignment_outlined),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: descriptionController,
                      enabled: !saving,
                      maxLines: 3,
                      decoration: const InputDecoration(
                        labelText: 'Description',
                        hintText: 'Optional',
                        prefixIcon: Icon(Icons.description_outlined),
                        border: OutlineInputBorder(),
                        alignLabelWithHint: true,
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: instructionsController,
                      enabled: !saving,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        labelText: 'Instructions',
                        hintText: 'Optional',
                        prefixIcon: Icon(Icons.list_alt_outlined),
                        border: OutlineInputBorder(),
                        alignLabelWithHint: true,
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
                  onPressed: saving ? null : saveExam,
                  child: saving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );

    titleController.dispose();
    descriptionController.dispose();
    instructionsController.dispose();

    if (result == true) {
      await _loadData();

      if (!mounted) return;

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Exam added successfully.')));
    }
  }

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

  String _getStatusLabel(String status) {
    switch (status.toLowerCase()) {
      case 'published':
        return 'Published';

      case 'archived':
        return 'Archived';

      case 'draft':
      default:
        return 'Draft';
    }
  }

  Color _getStatusColor(BuildContext context, String status) {
    switch (status.toLowerCase()) {
      case 'published':
        return Colors.green;

      case 'archived':
        return Colors.grey;

      case 'draft':
      default:
        return Colors.orange;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Exams')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _chooseCreationMethod,
        icon: const Icon(Icons.add),
        label: const Text('Add Exam'),
      ),
      body: Column(
        children: [
          if (_classes.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: DropdownButtonFormField<String?>(
                key: ValueKey(_selectedSection),
                initialValue: _selectedSection,
                decoration: const InputDecoration(
                  labelText: 'Filter by Section',
                  prefixIcon: Icon(Icons.filter_list),
                  border: OutlineInputBorder(),
                ),
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('All Sections'),
                  ),
                  ..._sections.map(
                    (section) => DropdownMenuItem<String?>(
                      value: section,
                      child: Text(section),
                    ),
                  ),
                ],
                onChanged: (value) {
                  setState(() => _selectedSection = value);
                },
              ),
            ),
          Expanded(
            child: RefreshIndicator(onRefresh: _loadData, child: _buildBody()),
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

    if (_visibleExams.isEmpty) {
      return ListView(
        children: const [
          SizedBox(height: 120),
          Center(
            child: Column(
              children: [
                Icon(Icons.assignment_outlined, size: 56),
                SizedBox(height: 16),
                Text(
                  'No exams in this section.',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 8),
                Text('Choose another section or tap Add Exam.'),
              ],
            ),
          ),
        ],
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _visibleExams.length,
      itemBuilder: (context, index) {
        final exam = _visibleExams[index];

        final title = exam['title']?.toString() ?? 'Untitled Exam';

        final description = exam['description']?.toString() ?? '';

        final instructions = exam['instructions']?.toString() ?? '';

        final status = exam['status']?.toString() ?? 'draft';

        final classData = exam['class'];

        String classLabel = 'Unknown Class';

        if (classData is Map) {
          classLabel = _getClassLabel({
            'section': classData['section'],
            'subject': classData['subject'],
          });
        }

        return Card(
          margin: const EdgeInsets.only(bottom: 12),
          child: ListTile(
            onTap: () {
              final examId = int.tryParse(exam['id']?.toString() ?? '');

              if (examId == null) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Invalid exam ID.')),
                );
                return;
              }

              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ExamBuilderScreen(examId: examId),
                ),
              );
            },
            contentPadding: const EdgeInsets.all(16),
            leading: const CircleAvatar(child: Icon(Icons.assignment_outlined)),
            title: Text(
              title,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    classLabel,
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
                  if (description.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(description),
                  ],
                  if (instructions.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(instructions),
                  ],
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: _getStatusColor(
                        context,
                        status,
                      ).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      _getStatusLabel(status),
                      style: TextStyle(
                        color: _getStatusColor(context, status),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
