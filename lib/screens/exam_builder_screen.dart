import 'package:flutter/material.dart';
import 'package:printing/printing.dart';
import 'answer_sheet_camera_screen.dart';
import '../services/answer_sheet_pdf_service.dart';
import '../services/api_service.dart';
import '../services/auth_storage.dart';
import '../services/question_paper_pdf_service.dart';
import 'answer_sheet_preview_screen.dart';
import 'exam_preview_screen.dart';
import 'questions_screen.dart';

class ExamBuilderScreen extends StatefulWidget {
  final int examId;

  const ExamBuilderScreen({
    super.key,
    required this.examId,
  });

  @override
  State<ExamBuilderScreen> createState() =>
      _ExamBuilderScreenState();
}

class _ExamBuilderScreenState
    extends State<ExamBuilderScreen> {
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
        throw Exception(
          'Your session has expired. Please log in again.',
        );
      }

      final exams = await ApiService.getExams(token);

      final matchingExams = exams.where(
        (exam) =>
            exam['id'].toString() ==
            widget.examId.toString(),
      );

      if (matchingExams.isEmpty) {
        throw Exception('Exam not found.');
      }

      final exam = matchingExams.first;

      final sections = await ApiService.getExamSections(
        token,
        widget.examId,
      );

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

  Future<void> _generateQuestionPaperPdf() async {
    try {
      final token = await AuthStorage.getToken();

      if (token == null || token.isEmpty) {
        throw Exception(
          'Your session has expired. Please log in again.',
        );
      }

      final exams = await ApiService.getExams(token);

      final matchingExams = exams.where(
        (exam) =>
            exam['id'].toString() ==
            widget.examId.toString(),
      );

      if (matchingExams.isEmpty) {
        throw Exception('Exam not found.');
      }

      final exam = matchingExams.first;

      final sections = await ApiService.getExamSections(
        token,
        widget.examId,
      );

      final questions =
          <int, List<Map<String, dynamic>>>{};

      for (final section in sections) {
        final sectionId = int.tryParse(
          section['id']?.toString() ?? '',
        );

        if (sectionId == null) {
          continue;
        }

        questions[sectionId] =
            await ApiService.getQuestions(
          token,
          sectionId,
        );
      }

      final pdfBytes =
          await QuestionPaperPdfService.generate(
        exam: exam,
        sections: sections,
        questions: questions,
      );

      await Printing.layoutPdf(
        onLayout: (format) async {
          return pdfBytes;
        },
      );
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            e.toString().replaceFirst(
              'Exception: ',
              '',
            ),
          ),
        ),
      );
    }
  }

  Future<void> _generateAnswerSheetPdf() async {
    try {
      final token = await AuthStorage.getToken();

      if (token == null || token.isEmpty) {
        throw Exception(
          'Your session has expired. Please log in again.',
        );
      }

      final exams = await ApiService.getExams(token);

      final matchingExams = exams.where(
        (exam) =>
            exam['id'].toString() ==
            widget.examId.toString(),
      );

      if (matchingExams.isEmpty) {
        throw Exception('Exam not found.');
      }

      final exam = matchingExams.first;

      final sections = await ApiService.getExamSections(
        token,
        widget.examId,
      );

      final questions =
          <int, List<Map<String, dynamic>>>{};

      for (final section in sections) {
        final sectionId = int.tryParse(
          section['id']?.toString() ?? '',
        );

        if (sectionId == null) {
          continue;
        }

        questions[sectionId] =
            await ApiService.getQuestions(
          token,
          sectionId,
        );
      }

      final pdfBytes =
          await AnswerSheetPdfService.generate(
        exam: exam,
        sections: sections,
        questions: questions,
      );

      await Printing.layoutPdf(
        onLayout: (format) async {
          return pdfBytes;
        },
      );
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            e.toString().replaceFirst(
              'Exception: ',
              '',
            ),
          ),
        ),
      );
    }
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
      appBar: AppBar(
        title: const Text('Exam Builder'),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(),
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.error_outline,
                size: 48,
              ),
              const SizedBox(height: 12),
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _loadExam,
                child: const Text('Retry'),
              ),
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
            style: Theme.of(context)
                .textTheme
                .headlineSmall,
          ),

          const SizedBox(height: 8),

          Text(
            _exam?['description']?.toString() ?? '',
            style: Theme.of(context)
                .textTheme
                .bodyMedium,
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
                    builder: (_) => ExamPreviewScreen(
                      examId: widget.examId,
                    ),
                  ),
                );
              },
              child: const Text(
                'Preview Test Paper',
              ),
            ),
          ),

          const SizedBox(height: 10),

          // GENERATE QUESTION PAPER PDF
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _generateQuestionPaperPdf,
              child: const Text(
                'Generate Question Paper PDF',
              ),
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
                        AnswerSheetPreviewScreen(
                      examId: widget.examId,
                    ),
                  ),
                );
              },
              child: const Text(
                'Preview Answer Sheet',
              ),
            ),
          ),

          const SizedBox(height: 10),

          // GENERATE ANSWER SHEET PDF
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _generateAnswerSheetPdf,
              child: const Text(
                'Generate Answer Sheet PDF',
              ),
            ),
          ),

          const SizedBox(height: 24),

          const Text(
            'Exam Sections',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),

          const SizedBox(height: 12),

          if (_sections.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(20),
                child: Text(
                  'No sections have been added yet.',
                ),
              ),
            ),

          ..._sections.map(
            (section) {
              final type =
                  section['question_type']
                          ?.toString() ??
                      '';

              final sectionId = int.tryParse(
                section['id']?.toString() ?? '',
              );

              return Card(
                margin:
                    const EdgeInsets.only(
                  bottom: 12,
                ),
                child: ListTile(
                  onTap: sectionId == null
                      ? null
                      : () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  QuestionsScreen(
                                sectionId: sectionId,
                                sectionName:
                                    section['name']
                                            ?.toString() ??
                                        'Section',
                                questionType:
                                    type,
                              ),
                            ),
                          );
                        },
                  leading: CircleAvatar(
                    child: Text(
                      section['section_order']
                              ?.toString() ??
                          '-',
                    ),
                  ),
                  title: Text(
                    section['name']?.toString() ??
                        'Section',
                  ),
                  subtitle: Text(
                    '${_formatQuestionType(type)} • '
                    '${section['default_points'] ?? '1'} '
                    'pts/item',
                  ),
                  trailing: const Icon(
                    Icons.arrow_forward_ios,
                    size: 18,
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
