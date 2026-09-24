
import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../services/auth_storage.dart';

class ExamPreviewScreen extends StatefulWidget {
  final int examId;

  const ExamPreviewScreen({
    super.key,
    required this.examId,
  });

  @override
  State<ExamPreviewScreen> createState() =>
      _ExamPreviewScreenState();
}

class _ExamPreviewScreenState
    extends State<ExamPreviewScreen> {
  bool _isLoading = true;
  String? _errorMessage;

  Map<String, dynamic>? _exam;

  List<Map<String, dynamic>> _sections = [];

  final Map<int, List<Map<String, dynamic>>> _questions = {};

  @override
  void initState() {
    super.initState();
    _loadPreview();
  }

  Future<void> _loadPreview() async {
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

      final questionsBySection =
          <int, List<Map<String, dynamic>>>{};

      for (final section in sections) {
        final sectionId = int.tryParse(
          section['id']?.toString() ?? '',
        );

        if (sectionId == null) {
          continue;
        }

        final questions = await ApiService.getQuestions(
          token,
          sectionId,
        );

        questionsBySection[sectionId] = questions;
      }

      if (!mounted) return;

      setState(() {
        _exam = exam;
        _sections = sections;
        _questions
          ..clear()
          ..addAll(questionsBySection);
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _errorMessage = e.toString().replaceFirst(
          'Exception: ',
          '',
        );
        _isLoading = false;
      });
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

  Widget _buildQuestion(
    Map<String, dynamic> question,
    String questionType,
    int index,
  ) {
    final questionNumber =
        question['question_number']?.toString() ??
            '${index + 1}';

    final questionText =
        question['question_text']?.toString() ??
            'No question text';

    final points =
        question['points']?.toString() ?? '0';

    final choices = question['choices'];

    return Padding(
      padding: const EdgeInsets.only(
        bottom: 24,
      ),
      child: Column(
        crossAxisAlignment:
            CrossAxisAlignment.start,
        children: [
          Text(
            '$questionNumber. $questionText',
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w500,
            ),
          ),

          const SizedBox(height: 6),

          Text(
            '$points point${points == '1' ? '' : 's'}',
            style: TextStyle(
              fontSize: 13,
              color: Theme.of(context)
                  .colorScheme
                  .onSurfaceVariant,
            ),
          ),

          const SizedBox(height: 12),

          // MULTIPLE CHOICE
          if (questionType == 'multiple_choice' &&
              choices is List &&
              choices.isNotEmpty)
            ...choices.asMap().entries.map(
              (entry) {
                final choiceIndex = entry.key;
                final choice = entry.value.toString();

                return Padding(
                  padding: const EdgeInsets.only(
                    bottom: 8,
                  ),
                  child: Row(
                    crossAxisAlignment:
                        CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${String.fromCharCode(65 + choiceIndex)}. ',
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Expanded(
                        child: Text(choice),
                      ),
                    ],
                  ),
                );
              },
            ),

          // TRUE OR FALSE
          if (questionType == 'true_false')
            Column(
              children: [
                _buildAnswerLine('True'),
                const SizedBox(height: 8),
                _buildAnswerLine('False'),
              ],
            ),

          // IDENTIFICATION
          if (questionType == 'identification')
            _buildIdentificationLines(),
        ],
      ),
    );
  }

  Widget _buildAnswerLine(String text) {
    return Row(
      children: [
        Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            border: Border.all(),
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 10),
        Text(text),
      ],
    );
  }

  Widget _buildIdentificationLines() {
    return Column(
      children: [
        Container(
          width: double.infinity,
          height: 40,
          decoration: const BoxDecoration(
            border: Border(
              bottom: BorderSide(),
            ),
          ),
        ),
      ],
    );
  }

  int _getTotalQuestions() {
    int total = 0;

    for (final questions in _questions.values) {
      total += questions.length;
    }

    return total;
  }

  double _getTotalPoints() {
    double total = 0;

    for (final questions in _questions.values) {
      for (final question in questions) {
        total +=
            double.tryParse(
                  question['points']?.toString() ?? '0',
                ) ??
                0;
      }
    }

    return total;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Exam Preview'),
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

              const SizedBox(height: 16),

              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
              ),

              const SizedBox(height: 16),

              ElevatedButton(
                onPressed: _loadPreview,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadPreview,
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          // EXAM HEADER
          Center(
            child: Column(
              children: [
                Text(
                  _exam?['title']?.toString() ?? 'Exam',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),

                const SizedBox(height: 8),

                Text(
                  'Total Questions: '
                  '${_getTotalQuestions()}',
                  style: const TextStyle(
                    fontSize: 14,
                  ),
                ),

                Text(
                  'Total Points: '
                  '${_getTotalPoints().toStringAsFixed(2)}',
                  style: const TextStyle(
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),

          // STUDENT INFORMATION
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Student Information',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                    ),
                  ),

                  const SizedBox(height: 16),

                  _buildInfoLine('Student Name'),
                  _buildInfoLine('Student Number'),
                  _buildInfoLine('Section'),
                ],
              ),
            ),
          ),

          const SizedBox(height: 20),

          // INSTRUCTIONS
          if ((_exam?['instructions']?.toString() ?? '')
              .isNotEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Instructions',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                      ),
                    ),

                    const SizedBox(height: 8),

                    Text(
                      _exam?['instructions']?.toString() ?? '',
                    ),
                  ],
                ),
              ),
            ),

          const SizedBox(height: 24),

          // EXAM SECTIONS
          ..._sections.map(
            (section) {
              final sectionId = int.tryParse(
                section['id']?.toString() ?? '',
              );

              final sectionName =
                  section['name']?.toString() ??
                      'Section';

              final questionType =
                  section['question_type']?.toString() ??
                      '';

              final questions =
                  sectionId == null
                      ? <Map<String, dynamic>>[]
                      : _questions[sectionId] ?? [];

              return Card(
                margin: const EdgeInsets.only(
                  bottom: 20,
                ),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment:
                        CrossAxisAlignment.start,
                    children: [
                      Text(
                        sectionName,
                        style: const TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.bold,
                        ),
                      ),

                      const SizedBox(height: 4),

                      Text(
                        _formatQuestionType(
                          questionType,
                        ),
                        style: TextStyle(
                          color: Theme.of(context)
                              .colorScheme
                              .primary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),

                      const SizedBox(height: 20),

                      if (questions.isEmpty)
                        const Text(
                          'No questions in this section.',
                        )
                      else
                        ...questions.asMap().entries.map(
                          (questionEntry) {
                            return _buildQuestion(
                              questionEntry.value,
                              questionType,
                              questionEntry.key,
                            );
                          },
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildInfoLine(String label) {
    return Padding(
      padding: const EdgeInsets.only(
        bottom: 14,
      ),
      child: Row(
        children: [
          SizedBox(
            width: 120,
            child: Text(
              '$label:',
              style: const TextStyle(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),

          const Expanded(
            child: Divider(),
          ),
        ],
      ),
    );
  }
}
