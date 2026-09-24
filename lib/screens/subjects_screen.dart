import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../services/auth_storage.dart';

class SubjectsScreen extends StatefulWidget {
  const SubjectsScreen({super.key});

  @override
  State<SubjectsScreen> createState() => _SubjectsScreenState();
}

class _SubjectsScreenState extends State<SubjectsScreen> {
  List<Map<String, dynamic>> _subjects = [];

  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadSubjects();
  }

  // =========================
  // LOAD SUBJECTS
  // =========================

  Future<void> _loadSubjects() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final token = await AuthStorage.getToken();

      if (token == null || token.isEmpty) {
        throw Exception(
          'Authentication token not found.',
        );
      }

      final subjects =
          await ApiService.getSubjects(token);

      if (!mounted) {
        return;
      }

      setState(() {
        _subjects = subjects;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) {
        return;
      }

      setState(() {
        _error = e.toString().replaceFirst(
              'Exception: ',
              '',
            );

        _loading = false;
      });
    }
  }

  // =========================
  // ADD SUBJECT DIALOG
  // =========================

  Future<void> _showAddSubjectDialog() async {
    final nameController = TextEditingController();
    final codeController = TextEditingController();

    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        bool saving = false;
        String? dialogError;

        return StatefulBuilder(
          builder: (
            context,
            setDialogState,
          ) {
            Future<void> saveSubject() async {
              final name =
                  nameController.text.trim();

              final code =
                  codeController.text.trim();

              if (name.isEmpty) {
                setDialogState(() {
                  dialogError =
                      'Subject name is required.';
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

                if (token == null ||
                    token.isEmpty) {
                  throw Exception(
                    'Authentication token not found.',
                  );
                }

                await ApiService.createSubject(
                  token: token,
                  name: name,
                  code: code.isEmpty
                      ? null
                      : code,
                );

                if (!context.mounted) {
                  return;
                }

                Navigator.pop(
                  context,
                  true,
                );
              } catch (e) {
                setDialogState(() {
                  saving = false;

                  dialogError =
                      e.toString().replaceFirst(
                            'Exception: ',
                            '',
                          );
                });
              }
            }

            return AlertDialog(
              title: const Text(
                'Add Subject',
              ),

              content: Column(
                mainAxisSize:
                    MainAxisSize.min,
                children: [
                  TextField(
                    controller:
                        nameController,
                    enabled: !saving,
                    textCapitalization:
                        TextCapitalization.words,
                    decoration:
                        const InputDecoration(
                      labelText:
                          'Subject Name',
                      hintText:
                          'e.g. Information Management',
                      prefixIcon: Icon(
                        Icons.menu_book_outlined,
                      ),
                      border:
                          OutlineInputBorder(),
                    ),
                  ),

                  const SizedBox(
                    height: 16,
                  ),

                  TextField(
                    controller:
                        codeController,
                    enabled: !saving,
                    textCapitalization:
                        TextCapitalization.characters,
                    decoration:
                        const InputDecoration(
                      labelText:
                          'Subject Code',
                      hintText:
                          'e.g. IT 301',
                      prefixIcon: Icon(
                        Icons.tag,
                      ),
                      border:
                          OutlineInputBorder(),
                    ),
                  ),

                  if (dialogError != null) ...[
                    const SizedBox(
                      height: 12,
                    ),

                    Text(
                      dialogError!,
                      style: TextStyle(
                        color: Theme.of(
                          context,
                        )
                            .colorScheme
                            .error,
                      ),
                    ),
                  ],
                ],
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
                  child:
                      const Text('Cancel'),
                ),

                FilledButton(
                  onPressed:
                      saving
                          ? null
                          : saveSubject,
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

    nameController.dispose();
    codeController.dispose();

    if (result == true) {
      await _loadSubjects();

      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context)
          .showSnackBar(
        const SnackBar(
          content: Text(
            'Subject added successfully.',
          ),
        ),
      );
    }
  }

  // =========================
  // BUILD
  // =========================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Subjects',
        ),
      ),

      floatingActionButton:
          FloatingActionButton.extended(
        onPressed:
            _showAddSubjectDialog,
        icon: const Icon(
          Icons.add,
        ),
        label: const Text(
          'Add Subject',
        ),
      ),

      body: RefreshIndicator(
        onRefresh:
            _loadSubjects,
        child: _buildBody(),
      ),
    );
  }

  // =========================
  // BODY
  // =========================

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child:
            CircularProgressIndicator(),
      );
    }

    if (_error != null) {
      return ListView(
        children: [
          const SizedBox(
            height: 120,
          ),

          Center(
            child: Padding(
              padding:
                  const EdgeInsets.all(24),
              child: Column(
                children: [
                  const Icon(
                    Icons.error_outline,
                    size: 48,
                  ),

                  const SizedBox(
                    height: 16,
                  ),

                  Text(
                    _error!,
                    textAlign:
                        TextAlign.center,
                  ),

                  const SizedBox(
                    height: 16,
                  ),

                  FilledButton(
                    onPressed:
                        _loadSubjects,
                    child:
                        const Text(
                      'Retry',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    if (_subjects.isEmpty) {
      return ListView(
        children: const [
          SizedBox(
            height: 140,
          ),

          Center(
            child: Column(
              children: [
                Icon(
                  Icons
                      .menu_book_outlined,
                  size: 56,
                ),

                SizedBox(
                  height: 16,
                ),

                Text(
                  'No subjects yet.',
                  style:
                      TextStyle(
                    fontSize: 18,
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),

                SizedBox(
                  height: 8,
                ),

                Text(
                  'Tap "Add Subject" to create one.',
                ),
              ],
            ),
          ),
        ],
      );
    }

    return ListView.builder(
      padding:
          const EdgeInsets.all(16),

      itemCount:
          _subjects.length,

      itemBuilder:
          (context, index) {
        final subject =
            _subjects[index];

        final name =
            subject['name']
                    ?.toString() ??
                'Unnamed Subject';

        final code =
            subject['code']
                ?.toString();

        return Card(
          margin:
              const EdgeInsets.only(
            bottom: 12,
          ),

          child: ListTile(
            leading:
                CircleAvatar(
              child: Text(
                name.isNotEmpty
                    ? name[0]
                        .toUpperCase()
                    : '?',
              ),
            ),

            title: Text(
              name,
              style:
                  const TextStyle(
                fontWeight:
                    FontWeight.bold,
              ),
            ),

            subtitle:
                code == null ||
                        code.isEmpty
                    ? const Text(
                        'No subject code',
                      )
                    : Text(code),

            trailing:
                const Icon(
              Icons.chevron_right,
            ),
          ),
        );
      },
    );
  }
}