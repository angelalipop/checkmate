import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import '../services/answer_sheet_pdf_service.dart';
import '../services/api_service.dart';
import '../services/auth_storage.dart';
import '../services/question_paper_pdf_service.dart';
import 'answer_sheet_preview_screen.dart';
import 'exam_preview_screen.dart';
import 'questions_screen.dart';

class ExamBuilderScreen extends StatefulWidget {
  final int examId;

  const ExamBuilderScreen({super.key, required this.examId});

  @override
  State<ExamBuilderScreen> createState() => _ExamBuilderScreenState();
}

class _ExamBuilderScreenState extends State<ExamBuilderScreen> {
  bool _isLoading = true;
  String? _errorMessage;

  Map<String, dynamic>? _exam;
  List<Map<String, dynamic>> _sections = [];

  @override
  void initState() {
    super.initState();
    _loadExam();
  }

  Future<void> _loadExam() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final token = await AuthStorage.getToken();

      if (token == null || token.isEmpty) {
        throw Exception('Your session has expired. Please log in again.');
      }

      final exams = await ApiService.getExams(token);

      final matchingExams = exams.where(
        (exam) => exam['id'].toString() == widget.examId.toString(),
      );

      if (matchingExams.isEmpty) {
        throw Exception('Exam not found.');
      }

      final exam = matchingExams.first;

      final sections = await ApiService.getExamSections(token, widget.examId);

      if (!mounted) return;

      setState(() {
        _exam = exam;
        _sections = sections;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _errorMessage = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _deleteSection(int sectionId, String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete section?'),
        content: Text(
          'Delete "$name" and all its questions? This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final token = await AuthStorage.getToken();
      if (token == null || token.isEmpty) throw Exception('Session expired.');
      await ApiService.deleteExamSection(token: token, sectionId: sectionId);
      if (!mounted) return;
      await _loadExam();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Section deleted.')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    }
  }

  Future<void> _generateQuestionPaperPdf({bool download = false}) async {
    try {
      final token = await AuthStorage.getToken();

      if (token == null || token.isEmpty) {
        throw Exception('Your session has expired. Please log in again.');
      }

      final exams = await ApiService.getExams(token);

      final matchingExams = exams.where(
        (exam) => exam['id'].toString() == widget.examId.toString(),
      );

      if (matchingExams.isEmpty) {
        throw Exception('Exam not found.');
      }

      final exam = matchingExams.first;

      final sections = await ApiService.getExamSections(token, widget.examId);

      final questions = <int, List<Map<String, dynamic>>>{};

      for (final section in sections) {
        final sectionId = int.tryParse(section['id']?.toString() ?? '');

        if (sectionId == null) {
          continue;
        }

        questions[sectionId] = await ApiService.getQuestions(token, sectionId);
      }

      final pdfBytes = await QuestionPaperPdfService.generate(
        exam: exam,
        sections: sections,
        questions: questions,
      );

      if (download) {
        await Printing.sharePdf(
          bytes: pdfBytes,
          filename: _pdfFileName('question_paper', exam),
        );
      } else {
        await Printing.layoutPdf(
          onLayout: (format) async {
            return pdfBytes;
          },
        );
      }
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    }
  }

  Future<void> _generateAnswerSheetPdf({bool download = false}) async {
    try {
      final token = await AuthStorage.getToken();

      if (token == null || token.isEmpty) {
        throw Exception('Your session has expired. Please log in again.');
      }

      final exams = await ApiService.getExams(token);

      final matchingExams = exams.where(
        (exam) => exam['id'].toString() == widget.examId.toString(),
      );

      if (matchingExams.isEmpty) {
        throw Exception('Exam not found.');
      }

      final exam = matchingExams.first;

      final sections = await ApiService.getExamSections(token, widget.examId);

      final questions = <int, List<Map<String, dynamic>>>{};

      for (final section in sections) {
        final sectionId = int.tryParse(section['id']?.toString() ?? '');

        if (sectionId == null) {
          continue;
        }

        questions[sectionId] = await ApiService.getQuestions(token, sectionId);
      }

      final pdfBytes = await AnswerSheetPdfService.generate(
        exam: exam,
        sections: sections,
        questions: questions,
      );

      if (download) {
        await Printing.sharePdf(
          bytes: pdfBytes,
          filename: _pdfFileName('answer_sheet', exam),
        );
      } else {
        await Printing.layoutPdf(
          onLayout: (format) async {
            return pdfBytes;
          },
        );
      }
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    }
  }

  Future<void> _showAddSectionDialog() async {
    final nameController = TextEditingController();
    final pointsController = TextEditingController(text: '1');
    String questionType = 'multiple_choice';
    bool saving = false;
    String? error;
    final nextOrder =
        _sections.fold<int>(0, (maxOrder, section) {
          final order =
              int.tryParse(section['section_order']?.toString() ?? '') ?? 0;
          return order > maxOrder ? order : maxOrder;
        }) +
        1;

    try {
      final created = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, updateDialog) => AlertDialog(
            title: const Text('Add Exam Section'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: nameController,
                    enabled: !saving,
                    decoration: const InputDecoration(
                      labelText: 'Section Name',
                      hintText: 'e.g. Part I - Multiple Choice',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    initialValue: questionType,
                    decoration: const InputDecoration(
                      labelText: 'Question Type',
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'multiple_choice',
                        child: Text('Multiple Choice'),
                      ),
                      DropdownMenuItem(
                        value: 'true_false',
                        child: Text('True or False'),
                      ),
                      DropdownMenuItem(
                        value: 'identification',
                        child: Text('Identification'),
                      ),
                    ],
                    onChanged: saving
                        ? null
                        : (value) {
                            if (value != null) {
                              updateDialog(() => questionType = value);
                            }
                          },
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: pointsController,
                    enabled: !saving,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'Default Points per Item',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  if (error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      error!,
                      style: TextStyle(
                        color: Theme.of(dialogContext).colorScheme.error,
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
                    : () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: saving
                    ? null
                    : () async {
                        final name = nameController.text.trim();
                        final points = num.tryParse(
                          pointsController.text.trim(),
                        );
                        if (name.isEmpty || points == null || points <= 0) {
                          updateDialog(
                            () => error = 'Enter a section name and points greater than zero.',
                          );
                          return;
                        }
                        updateDialog(() {
                          saving = true;
                          error = null;
                        });
                        try {
                          final token = await AuthStorage.getToken();
                          if (token == null || token.isEmpty) {
                            throw Exception('Please log in again.');
                          }
                          await ApiService.createExamSection(
                            token: token,
                            examId: widget.examId,
                            name: name,
                            questionType: questionType,
                            sectionOrder: nextOrder,
                            defaultPoints: points,
                          );
                          if (dialogContext.mounted) {
                            Navigator.pop(dialogContext, true);
                          }
                        } catch (e) {
                          updateDialog(() {
                            saving = false;
                            error = e.toString().replaceFirst(
                              'Exception: ',
                              '',
                            );
                          });
                        }
                      },
                child: saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Save Section'),
              ),
            ],
          ),
        ),
      );
      if (created == true) await _loadExam();
    } finally {
      nameController.dispose();
      pointsController.dispose();
    }
  }

  String _pdfFileName(String prefix, Map<String, dynamic> exam) {
    final title = (exam['title']?.toString() ?? 'exam')
        .trim()
        .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    return '${prefix}_${title.isEmpty ? 'exam' : title}.pdf';
  }

  String _formatQuestionType(String type) {
    switch (type) {
      case 'multiple_choice':
        return 'Multiple Choice';

      case 'true_false':
        return 'True or False';

      case 'identification':
        return 'Identification';

      default:
        return type;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Exam Builder')),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48),
              const SizedBox(height: 12),
              Text(_errorMessage!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              ElevatedButton(onPressed: _loadExam, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadExam,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            _exam?['title']?.toString() ?? 'Exam',
            style: Theme.of(context).textTheme.headlineSmall,
          ),

          const SizedBox(height: 8),

          Text(
            _exam?['description']?.toString() ?? '',
            style: Theme.of(context).textTheme.bodyMedium,
          ),

          const SizedBox(height: 16),

          // PREVIEW TEST PAPER
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ExamPreviewScreen(examId: widget.examId),
                  ),
                );
              },
              child: const Text('Preview Test Paper'),
            ),
          ),

          const SizedBox(height: 10),

          // GENERATE QUESTION PAPER PDF
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _generateQuestionPaperPdf,
              child: const Text('Print Question Paper PDF'),
            ),
          ),

          const SizedBox(height: 10),

          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => _generateQuestionPaperPdf(download: true),
              icon: const Icon(Icons.download),
              label: const Text('Download Question Paper PDF'),
            ),
          ),

          const SizedBox(height: 10),

          // PREVIEW ANSWER SHEET
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        AnswerSheetPreviewScreen(examId: widget.examId),
                  ),
                );
              },
              child: const Text('Preview Answer Sheet'),
            ),
          ),

          const SizedBox(height: 10),

          // GENERATE ANSWER SHEET PDF
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _generateAnswerSheetPdf,
              child: const Text('Print Answer Sheet PDF'),
            ),
          ),

          const SizedBox(height: 10),

          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => _generateAnswerSheetPdf(download: true),
              icon: const Icon(Icons.download),
              label: const Text('Download Answer Sheet PDF'),
            ),
          ),

          const SizedBox(height: 24),

          Row(
            children: [
              const Expanded(
                child: Text(
                  'Exam Sections',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
              ),
              FilledButton.icon(
                onPressed: _showAddSectionDialog,
                icon: const Icon(Icons.add),
                label: const Text('Add Section'),
              ),
            ],
          ),

          const SizedBox(height: 12),

          if (_sections.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(20),
                child: Text('No sections have been added yet.'),
              ),
            ),

          ..._sections.map((section) {
            final type = section['question_type']?.toString() ?? '';

            final sectionId = int.tryParse(section['id']?.toString() ?? '');

            return Card(
              margin: const EdgeInsets.only(bottom: 12),
              child: ListTile(
                onTap: sectionId == null
                    ? null
                    : () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => QuestionsScreen(
                              sectionId: sectionId,
                              sectionName:
                                  section['name']?.toString() ?? 'Section',
                              questionType: type,
                            ),
                          ),
                        );
                      },
                leading: CircleAvatar(
                  child: Text(section['section_order']?.toString() ?? '-'),
                ),
                title: Text(section['name']?.toString() ?? 'Section'),
                subtitle: Text(
                  '${_formatQuestionType(type)} • '
                  '${section['default_points'] ?? '1'} '
                  'pts/item',
                ),
                trailing: IconButton(
                  tooltip: 'Delete section',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: sectionId == null
                      ? null
                      : () => _deleteSection(
                          sectionId,
                          section['name']?.toString() ?? 'Section',
                        ),
                ),
              ),
            );
          }),
        ],
      ),
    );
  }
}
