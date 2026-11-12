import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/api_service.dart';
import '../services/auth_storage.dart';
import 'login_screen.dart' show CmColors;

class _UpperCaseFormatter extends TextInputFormatter {
  const _UpperCaseFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final upper = newValue.text.toUpperCase();
    if (upper == newValue.text) return newValue;
    return newValue.copyWith(
      text: upper,
      selection: newValue.selection,
      composing: TextRange.empty,
    );
  }
}

class QuestionsScreen extends StatefulWidget {
  final int sectionId;
  final String sectionName;
  final String questionType;
  final int? aggregateTypeQuestionCount;

  const QuestionsScreen({
    super.key,
    required this.sectionId,
    required this.sectionName,
    required this.questionType,
    this.aggregateTypeQuestionCount,
  });

  @override
  State<QuestionsScreen> createState() => _QuestionsScreenState();
}

class _QuestionsScreenState extends State<QuestionsScreen> {
  bool _isLoading = true;
  String? _errorMessage;

  List<Map<String, dynamic>> _questions = [];

  final Map<int, List<Map<String, dynamic>>> _acceptableAnswers = {};

  @override
  void initState() {
    super.initState();
    _loadQuestions();
  }

  Future<void> _loadQuestions() async {
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

      final questions = await ApiService.getQuestions(
        token,
        widget.sectionId,
      );
      questions.sort((a, b) {
        final na = int.tryParse(a['question_number']?.toString() ?? '') ?? 0;
        final nb = int.tryParse(b['question_number']?.toString() ?? '') ?? 0;
        if (na != nb) return na.compareTo(nb);
        final ida = int.tryParse(a['id']?.toString() ?? '') ?? 0;
        final idb = int.tryParse(b['id']?.toString() ?? '') ?? 0;
        return ida.compareTo(idb);
      });

      final acceptableAnswers = <int, List<Map<String, dynamic>>>{};

      if (widget.questionType == 'identification') {
        for (final question in questions) {
          if (question['correct_answer'] != null) {
            question['correct_answer'] =
                question['correct_answer'].toString().toUpperCase();
          }
          final questionId = int.tryParse(
            question['id']?.toString() ?? '',
          );

          if (questionId == null) {
            continue;
          }

          final answers = await ApiService.getAcceptableAnswers(
            token,
            questionId,
          );
          for (final a in answers) {
            if (a['answer'] != null) {
              a['answer'] = a['answer'].toString().toUpperCase();
            }
          }

          acceptableAnswers[questionId] = answers;
        }
      }

      if (!mounted) return;

      setState(() {
        _questions = questions;
        _acceptableAnswers
          ..clear()
          ..addAll(acceptableAnswers);
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

  Future<void> _addAcceptableAnswer(
    int questionId,
  ) async {
    final answerController = TextEditingController();

    String? dialogError;
    bool saving = false;

    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (
            context,
            setDialogState,
          ) {
            Future<void> saveAnswer() async {
              final answer = answerController.text.trim().toUpperCase();

              if (answer.isEmpty) {
                setDialogState(() {
                  dialogError = 'Acceptable answer is required.';
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

                final newAnswer = await ApiService.createAcceptableAnswer(
                  token: token,
                  questionId: questionId,
                  answer: answer,
                );
                newAnswer['answer'] =
                    (newAnswer['answer']?.toString() ?? answer).toUpperCase();

                if (!mounted || !dialogContext.mounted) {
                  return;
                }

                setState(() {
                  _acceptableAnswers[questionId] ??= [];
                  _acceptableAnswers[questionId]!.add(newAnswer);
                });

                Navigator.pop(
                  dialogContext,
                  true,
                );
              } catch (e) {
                setDialogState(() {
                  saving = false;
                  dialogError = e.toString().replaceFirst(
                    'Exception: ',
                    '',
                  );
                });
              }
            }

            return AlertDialog(
              title: const Text(
                'Add Acceptable Answer',
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: answerController,
                    enabled: !saving,
                    autofocus: true,
                    textCapitalization: TextCapitalization.characters,
                    inputFormatters: const [_UpperCaseFormatter()],
                    decoration: const InputDecoration(
                      labelText: 'Answer (CAPITAL LETTERS)',
                      hintText: 'Example: DART',
                      border: OutlineInputBorder(),
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
              actions: [
                TextButton(
                  onPressed: saving
                      ? null
                      : () {
                          Navigator.pop(
                            dialogContext,
                            false,
                          );
                        },
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: saving ? null : saveAnswer,
                  child: saving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                          ),
                        )
                      : const Text('Add'),
                ),
              ],
            );
          },
        );
      },
    );

    answerController.dispose();

    if (result == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Acceptable answer added successfully.',
          ),
        ),
      );
    }
  }

  Future<void> _deleteQuestion(int questionId, String questionNumber) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete question?'),
        content: Text(
          'Delete question $questionNumber? This cannot be undone.',
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
      await ApiService.deleteQuestion(token: token, questionId: questionId);
      if (!mounted) return;
      await _loadQuestions();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Question deleted.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    }
  }

  Future<void> _showAddQuestionDialog() async {
    final questionController = TextEditingController();
    final pointsController = TextEditingController(text: '1');
    final correctAnswerController = TextEditingController();
    final choiceControllers = List.generate(
      4,
      (index) => TextEditingController(),
    );

    String? pickedAnswer;
    String? dialogError;
    bool saving = false;

    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (
            context,
            setDialogState,
          ) {
            Future<void> saveQuestion() async {
              final questionText = questionController.text.trim();
              final pointsText = pointsController.text.trim();
              final correctAnswer = widget.questionType == 'identification'
                  ? correctAnswerController.text.trim().toUpperCase()
                  : (pickedAnswer ?? '').trim();

              if (questionText.isEmpty) {
                setDialogState(() {
                  dialogError = 'Question is required.';
                });
                return;
              }

              final points = double.tryParse(pointsText);

              if (points == null || points < 0) {
                setDialogState(() {
                  dialogError = 'Please enter a valid point value.';
                });
                return;
              }

              if (correctAnswer.isEmpty) {
                setDialogState(() {
                  dialogError = 'Correct answer is required.';
                });
                return;
              }

              List<String>? choices;

              if (widget.questionType == 'multiple_choice') {
                choices = choiceControllers
                    .map(
                      (controller) => controller.text.trim(),
                    )
                    .toList();

                if (choices.any(
                  (choice) => choice.isEmpty,
                )) {
                  setDialogState(() {
                    dialogError = 'Please fill in all four choices.';
                  });
                  return;
                }
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

                await ApiService.createQuestion(
                  token: token,
                  sectionId: widget.sectionId,
                  questionNumber:
                      _questions.fold<int>(0, (maxNumber, question) {
                        final number =
                            int.tryParse(
                              question['question_number']?.toString() ?? '',
                            ) ??
                            0;
                        return number > maxNumber ? number : maxNumber;
                      }) +
                      1,
                  questionText: questionText,
                  points: points,
                  choices: choices,
                  correctAnswer: correctAnswer,
                );

                if (!dialogContext.mounted) {
                  return;
                }

                Navigator.pop(
                  dialogContext,
                  true,
                );
              } catch (e) {
                setDialogState(() {
                  saving = false;
                  dialogError = e.toString().replaceFirst(
                    'Exception: ',
                    '',
                  );
                });
              }
            }

            Widget answerKeyWidget() {
              if (widget.questionType == 'multiple_choice') {
                return Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final letter in const ['A', 'B', 'C', 'D'])
                      InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: saving
                            ? null
                            : () => setDialogState(() => pickedAnswer = letter),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: pickedAnswer == letter
                                ? CmColors.green
                                : const Color(0xFFF1F5F9),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: pickedAnswer == letter
                                  ? CmColors.green
                                  : const Color(0xFFCFD8E5),
                            ),
                          ),
                          child: Text(
                            letter,
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: pickedAnswer == letter
                                  ? Colors.white
                                  : Colors.black87,
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              }
              if (widget.questionType == 'true_false') {
                return Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final opt in const ['True', 'False'])
                      InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: saving
                            ? null
                            : () => setDialogState(() => pickedAnswer = opt),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: pickedAnswer == opt
                                ? CmColors.green
                                : const Color(0xFFF1F5F9),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: pickedAnswer == opt
                                  ? CmColors.green
                                  : const Color(0xFFCFD8E5),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (pickedAnswer == opt) ...[
                                const Icon(
                                  Icons.check,
                                  size: 16,
                                  color: Colors.white,
                                ),
                                const SizedBox(width: 4),
                              ],
                              Text(
                                opt,
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: pickedAnswer == opt
                                      ? Colors.white
                                      : Colors.black87,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                );
              }
              return TextField(
                controller: correctAnswerController,
                enabled: !saving,
                textCapitalization: TextCapitalization.characters,
                inputFormatters: const [_UpperCaseFormatter()],
                decoration: const InputDecoration(
                  labelText: 'Correct Answer (CAPITAL LETTERS)',
                  hintText: 'Example: CPU',
                  border: OutlineInputBorder(),
                ),
              );
            }

            return AlertDialog(
              title: const Text(
                'Add Question',
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: questionController,
                      enabled: !saving,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        labelText: 'Question',
                        hintText: 'Enter the question',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: pointsController,
                      enabled: !saving,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Points',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    if (widget.questionType == 'multiple_choice') ...[
                      const SizedBox(height: 20),
                      const Text(
                        'Choices',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 12),
                      for (int i = 0; i < 4; i++) ...[
                        TextField(
                          controller: choiceControllers[i],
                          enabled: !saving,
                          decoration: InputDecoration(
                            labelText:
                                'Choice ${String.fromCharCode(65 + i)}',
                            border: const OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 10),
                      ],
                    ],
                    const SizedBox(height: 12),
                    const Text(
                      'Answer Key',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 8),
                    answerKeyWidget(),
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
                          Navigator.pop(
                            dialogContext,
                            false,
                          );
                        },
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: saving ? null : saveQuestion,
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

    questionController.dispose();
    pointsController.dispose();
    correctAnswerController.dispose();

    for (final controller in choiceControllers) {
      controller.dispose();
    }

    if (result == true) {
      await _loadQuestions();

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Question added successfully.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.sectionName),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showAddQuestionDialog,
        icon: const Icon(Icons.add),
        label: const Text('Add Question'),
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
                    _errorMessage!,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _loadQuestions,
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    if (_questions.isEmpty) {
      return ListView(
        children: [
          const SizedBox(height: 120),
          Center(
            child: Column(
              children: [
                const Icon(
                  Icons.help_outline,
                  size: 56,
                ),
                const SizedBox(height: 16),
                const Text(
                  'No questions yet.',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _formatQuestionType(
                    widget.questionType,
                  ),
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: _showAddQuestionDialog,
                  icon: const Icon(Icons.add),
                  label: const Text(
                    'Add Question',
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }

    final effectiveTypeCount =
        widget.aggregateTypeQuestionCount ?? _questions.length;
    final isValidSection = effectiveTypeCount >= 5;
    final statusColor = isValidSection
        ? Colors.green.shade700
        : Colors.orange.shade800;

    return Column(
      children: [
        Container(
          width: double.infinity,
          margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: statusColor.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: statusColor.withValues(alpha: 0.4)),
          ),
          child: Row(
            children: [
              Icon(
                isValidSection
                    ? Icons.check_circle_outline
                    : Icons.info_outline,
                color: statusColor,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  isValidSection
                      ? '${_formatQuestionType(widget.questionType)} minimum met '
                            '(${_questions.length} in this section • $effectiveTypeCount/5 total for type).'
                      : '${_formatQuestionType(widget.questionType)} requires at least 5 questions '
                            'across sections of this type (currently $effectiveTypeCount/5; add ${5 - effectiveTypeCount} more).',
                  style: TextStyle(
                    color: statusColor,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _loadQuestions,
            child: ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _questions.length,
              itemBuilder: (context, index) {
                final question = _questions[index];

                final questionId = int.tryParse(
                  question['id']?.toString() ?? '',
                );

                final number =
                    question['question_number']?.toString() ?? '${index + 1}';

                final text = question['question_text']?.toString() ?? '';

                final points = question['points']?.toString() ?? '1';

                final correctAnswer =
                    question['correct_answer']?.toString() ?? '';

                final choices = question['choices'];

                final acceptable = questionId == null
                    ? <Map<String, dynamic>>[]
                    : (_acceptableAnswers[questionId] ?? []);

                return Card(
                  margin: const EdgeInsets.only(bottom: 12),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Question $number ($points pts)',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                ),
                              ),
                            ),
                            if (questionId != null)
                              IconButton(
                                tooltip: 'Delete question',
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () =>
                                    _deleteQuestion(questionId, number),
                              ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(text),
                        if (choices is List) ...[
                          const SizedBox(height: 12),
                          ...choices.asMap().entries.map((entry) {
                            final letter = String.fromCharCode(
                              65 + entry.key,
                            );

                            return Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Text('$letter. ${entry.value}'),
                            );
                          }),
                        ],
                        const SizedBox(height: 10),
                        Text(
                          'Correct Answer: $correctAnswer',
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            color: Colors.green,
                          ),
                        ),
                        if (widget.questionType == 'identification' &&
                            questionId != null) ...[
                          const SizedBox(height: 12),
                          const Text(
                            'Acceptable Answers:',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 6),
                          if (acceptable.isEmpty)
                            const Text('No additional acceptable answers.'),
                          ...acceptable.map(
                            (ans) => Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Text('• ${ans['answer']}'),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton.icon(
                              onPressed: () => _addAcceptableAnswer(questionId),
                              icon: const Icon(Icons.add),
                              label: const Text('Add Acceptable Answer'),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}
