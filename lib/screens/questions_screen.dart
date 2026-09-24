import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../services/auth_storage.dart';

class QuestionsScreen extends StatefulWidget {
  final int sectionId;
  final String sectionName;
  final String questionType;

  const QuestionsScreen({
    super.key,
    required this.sectionId,
    required this.sectionName,
    required this.questionType,
  });

  @override
  State<QuestionsScreen> createState() =>
      _QuestionsScreenState();
}

class _QuestionsScreenState
    extends State<QuestionsScreen> {
  bool _isLoading = true;
  String? _errorMessage;

  List<Map<String, dynamic>> _questions = [];

  final Map<int, List<Map<String, dynamic>>>
      _acceptableAnswers = {};

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

      final acceptableAnswers =
          <int, List<Map<String, dynamic>>>{};

      if (widget.questionType == 'identification') {
        for (final question in questions) {
          final questionId = int.tryParse(
            question['id']?.toString() ?? '',
          );

          if (questionId == null) {
            continue;
          }

          final answers =
              await ApiService.getAcceptableAnswers(
            token,
            questionId,
          );

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
    final answerController =
        TextEditingController();

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
              final answer =
                  answerController.text.trim();

              if (answer.isEmpty) {
                setDialogState(() {
                  dialogError =
                      'Acceptable answer is required.';
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

                final newAnswer =
                    await ApiService
                        .createAcceptableAnswer(
                  token: token,
                  questionId: questionId,
                  answer: answer,
                );

                if (!mounted ||
                    !dialogContext.mounted) {
                  return;
                }

                setState(() {
                  _acceptableAnswers[
                      questionId] ??= [];

                  _acceptableAnswers[
                          questionId]!
                      .add(newAnswer);
                });

                Navigator.pop(
                  dialogContext,
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
                'Add Acceptable Answer',
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: answerController,
                    enabled: !saving,
                    autofocus: true,
                    decoration:
                        const InputDecoration(
                      labelText: 'Answer',
                      hintText: 'Example: dart',
                      border:
                          OutlineInputBorder(),
                    ),
                  ),
                  if (dialogError != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      dialogError!,
                      textAlign:
                          TextAlign.center,
                      style: TextStyle(
                        color: Theme.of(context)
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
                            dialogContext,
                            false,
                          );
                        },
                  child:
                      const Text('Cancel'),
                ),
                FilledButton(
                  onPressed:
                      saving ? null : saveAnswer,
                  child: saving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child:
                              CircularProgressIndicator(
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
      ScaffoldMessenger.of(context)
          .showSnackBar(
        const SnackBar(
          content: Text(
            'Acceptable answer added successfully.',
          ),
        ),
      );
    }
  }

  Future<void> _showAddQuestionDialog() async {
    final questionController =
        TextEditingController();

    final pointsController =
        TextEditingController(text: '1');

    final correctAnswerController =
        TextEditingController();

    final choiceControllers = List.generate(
      4,
      (index) => TextEditingController(),
    );

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
              final questionText =
                  questionController.text.trim();

              final pointsText =
                  pointsController.text.trim();

              final correctAnswer =
                  correctAnswerController.text.trim();

              if (questionText.isEmpty) {
                setDialogState(() {
                  dialogError =
                      'Question is required.';
                });
                return;
              }

              final points =
                  double.tryParse(pointsText);

              if (points == null || points < 0) {
                setDialogState(() {
                  dialogError =
                      'Please enter a valid point value.';
                });
                return;
              }

              if (correctAnswer.isEmpty) {
                setDialogState(() {
                  dialogError =
                      'Correct answer is required.';
                });
                return;
              }

              List<String>? choices;

              if (widget.questionType ==
                  'multiple_choice') {
                choices = choiceControllers
                    .map(
                      (controller) =>
                          controller.text.trim(),
                    )
                    .toList();

                if (choices.any(
                  (choice) => choice.isEmpty,
                )) {
                  setDialogState(() {
                    dialogError =
                        'Please fill in all four choices.';
                  });
                  return;
                }
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

                await ApiService.createQuestion(
                  token: token,
                  sectionId: widget.sectionId,
                  questionNumber:
                      _questions.length + 1,
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
                'Add Question',
              ),
              content:
                  SingleChildScrollView(
                child: Column(
                  mainAxisSize:
                      MainAxisSize.min,
                  children: [
                    TextField(
                      controller:
                          questionController,
                      enabled: !saving,
                      maxLines: 4,
                      decoration:
                          const InputDecoration(
                        labelText: 'Question',
                        hintText:
                            'Enter the question',
                        border:
                            OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller:
                          pointsController,
                      enabled: !saving,
                      keyboardType:
                          const TextInputType
                              .numberWithOptions(
                        decimal: true,
                      ),
                      decoration:
                          const InputDecoration(
                        labelText: 'Points',
                        border:
                            OutlineInputBorder(),
                      ),
                    ),
                    if (widget.questionType ==
                        'multiple_choice') ...[
                      const SizedBox(height: 20),
                      const Align(
                        alignment:
                            Alignment.centerLeft,
                        child: Text(
                          'Choices',
                          style: TextStyle(
                            fontWeight:
                                FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      for (int i = 0;
                          i < 4;
                          i++) ...[
                        TextField(
                          controller:
                              choiceControllers[i],
                          enabled: !saving,
                          decoration:
                              InputDecoration(
                            labelText:
                                'Choice ${String.fromCharCode(65 + i)}',
                            border:
                                const OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(
                          height: 10,
                        ),
                      ],
                    ],
                    const SizedBox(height: 8),
                    TextField(
                      controller:
                          correctAnswerController,
                      enabled: !saving,
                      decoration:
                          const InputDecoration(
                        labelText:
                            'Correct Answer',
                        hintText:
                            'Example: B',
                        border:
                            OutlineInputBorder(),
                      ),
                    ),
                    if (dialogError != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        dialogError!,
                        textAlign:
                            TextAlign.center,
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
                  child:
                      const Text('Cancel'),
                ),
                FilledButton(
                  onPressed:
                      saving ? null : saveQuestion,
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

    questionController.dispose();
    pointsController.dispose();
    correctAnswerController.dispose();

    for (final controller
        in choiceControllers) {
      controller.dispose();
    }

    if (result == true) {
      await _loadQuestions();

      if (!mounted) return;

      ScaffoldMessenger.of(context)
          .showSnackBar(
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
      floatingActionButton:
          FloatingActionButton.extended(
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
              padding:
                  const EdgeInsets.all(24),
              child: Column(
                children: [
                  const Icon(
                    Icons.error_outline,
                    size: 48,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _errorMessage!,
                    textAlign:
                        TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed:
                        _loadQuestions,
                    child:
                        const Text('Retry'),
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
                    fontWeight:
                        FontWeight.bold,
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
                  onPressed:
                      _showAddQuestionDialog,
                  icon:
                      const Icon(Icons.add),
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

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _questions.length,
      itemBuilder: (
        context,
        index,
      ) {
        final question =
            _questions[index];

        final questionNumber =
            question['question_number']
                    ?.toString() ??
                '${index + 1}';

        final questionText =
            question['question_text']
                    ?.toString() ??
                'No question text';

        final points =
            question['points']
                    ?.toString() ??
                '0';

        final choices =
            question['choices'];

        final correctAnswer =
            question['correct_answer']
                ?.toString();

        final questionId =
            int.tryParse(
          question['id']?.toString() ?? '',
        );

        final acceptableAnswers =
            questionId == null
                ? <Map<String, dynamic>>[]
                : _acceptableAnswers[
                        questionId] ??
                    [];

        return Card(
          margin:
              const EdgeInsets.only(
            bottom: 16,
          ),
          child: Padding(
            padding:
                const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  children: [
                    CircleAvatar(
                      child: Text(
                        questionNumber,
                      ),
                    ),
                    const SizedBox(
                      width: 12,
                    ),
                    Expanded(
                      child: Text(
                        questionText,
                        style:
                            const TextStyle(
                          fontSize: 16,
                          fontWeight:
                              FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 12),

                Text(
                  '${_formatQuestionType(widget.questionType)}'
                  ' • $points pts',
                  style: TextStyle(
                    color: Theme.of(
                      context,
                    )
                        .colorScheme
                        .primary,
                    fontWeight:
                        FontWeight.w500,
                  ),
                ),

                if (choices is List &&
                    choices.isNotEmpty) ...[
                  const SizedBox(height: 12),

                  const Text(
                    'Choices',
                    style: TextStyle(
                      fontWeight:
                          FontWeight.bold,
                    ),
                  ),

                  const SizedBox(height: 6),

                  ...choices.map(
                    (choice) => Padding(
                      padding:
                          const EdgeInsets
                              .only(
                        bottom: 4,
                      ),
                      child: Text(
                        choice.toString(),
                      ),
                    ),
                  ),
                ],

                if (correctAnswer != null &&
                    correctAnswer.isNotEmpty) ...[
                  const SizedBox(height: 12),

                  Text(
                    'Correct Answer: '
                    '$correctAnswer',
                    style:
                        const TextStyle(
                      fontWeight:
                          FontWeight.w600,
                    ),
                  ),
                ],

                if (widget.questionType ==
                        'identification' &&
                    questionId != null) ...[
                  const SizedBox(height: 16),
                  const Divider(),
                  const SizedBox(height: 8),

                  const Text(
                    'Acceptable Answers',
                    style: TextStyle(
                      fontWeight:
                          FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),

                  const SizedBox(height: 8),

                  if (acceptableAnswers
                      .isEmpty)
                    const Text(
                      'No additional acceptable answers.',
                    )
                  else
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children:
                          acceptableAnswers
                              .map(
                        (answer) {
                          return Chip(
                            label: Text(
                              answer['answer']
                                      ?.toString() ??
                                  '',
                            ),
                          );
                        },
                      ).toList(),
                    ),

                  const SizedBox(height: 12),

                  OutlinedButton.icon(
                    onPressed: () =>
                        _addAcceptableAnswer(
                      questionId,
                    ),
                    icon:
                        const Icon(Icons.add),
                    label: const Text(
                      'Add Acceptable Answer',
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}