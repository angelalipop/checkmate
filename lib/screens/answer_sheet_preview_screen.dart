import 'dart:math' as math;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../services/auth_storage.dart';

class AnswerSheetPreviewScreen extends StatefulWidget {
  final int examId;

  const AnswerSheetPreviewScreen({
    super.key,
    required this.examId,
  });

  @override
  State<AnswerSheetPreviewScreen> createState() =>
      _AnswerSheetPreviewScreenState();
}

class _AnswerSheetPreviewScreenState
    extends State<AnswerSheetPreviewScreen> {
  bool _isLoading = true;
  String? _errorMessage;

  Map<String, dynamic>? _exam;

  List<Map<String, dynamic>> _sections = [];

  final Map<int, List<Map<String, dynamic>>> _questions = {};

  @override
  void initState() {
    super.initState();
    _loadAnswerSheet();
  }

  Future<void> _loadAnswerSheet() async {
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

  int _getTotalQuestions() {
    int total = 0;

    for (final questions in _questions.values) {
      total += questions.length;
    }

    return total;
  }

  int _getTotalPoints() {
    double total = 0;

    for (final questions in _questions.values) {
      for (final question in questions) {
        final points = double.tryParse(
          question['points']?.toString() ?? '0',
        );

        if (points != null) {
          total += points;
        }
      }
    }

    return total.round();
  }

  // ------------------------------------------------------------
  // REGISTRATION MARKERS
  // ------------------------------------------------------------

  
  Widget _buildRegistrationMarker() {
    return Container(
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        color: Colors.black,
        border: Border.all(
          color: Colors.black,
          width: 2,
        ),
      ),
    );
  }



  // ------------------------------------------------------------
  // HEADER
  // ------------------------------------------------------------

  Widget _buildHeader() {
    return Stack(
      children: [
        Column(
          children: [
            const Text(
              'CHECKMATE',
              style: TextStyle(
                fontSize: 25,
                fontWeight: FontWeight.bold,
                letterSpacing: 2,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _exam?['title']?.toString() ?? 'Exam',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Exam ID: ${widget.examId}',
              style: const TextStyle(
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        Positioned(
          left: 0,
          top: 0,
          child: _buildRegistrationMarker(),
        ),
        Positioned(
          right: 0,
          top: 0,
          child: _buildRegistrationMarker(),
        ),
      ],
    );
  }

  // ------------------------------------------------------------
  // QR CODE
  // ------------------------------------------------------------

  Widget _buildQrCode() {
    return Container(
      width: 105,
      height: 105,
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        border: Border.all(
          width: 1.2,
        ),
      ),
      child: QrImageView(
        data: 'CHECKMATE-EXAM-${widget.examId}',
        version: QrVersions.auto,
        size: 90,
        backgroundColor: Colors.white,
      ),
    );
  }

  // ------------------------------------------------------------
  // STUDENT INFORMATION
  // ------------------------------------------------------------

  Widget _buildStudentInformation() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        border: Border.all(
          width: 1.5,
        ),
      ),
      child: Column(
        crossAxisAlignment:
            CrossAxisAlignment.start,
        children: [
          const Text(
            'STUDENT INFORMATION',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 14),
          _buildInformationLine(
            'Student Name',
          ),
          const SizedBox(height: 12),
          _buildInformationLine(
            'Student Number',
          ),
          const SizedBox(height: 12),
          _buildInformationLine(
            'Section',
          ),
        ],
      ),
    );
  }

  Widget _buildInformationLine(
    String label,
  ) {
    return Row(
      children: [
        SizedBox(
          width: 105,
          child: Text(
            '$label:',
            style: const TextStyle(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const Expanded(
          child: Divider(
            thickness: 1,
          ),
        ),
      ],
    );
  }

  // ------------------------------------------------------------
  // INSTRUCTIONS
  // ------------------------------------------------------------

  Widget _buildInstructions() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        border: Border.all(
          width: 1,
        ),
      ),
      child: const Column(
        crossAxisAlignment:
            CrossAxisAlignment.start,
        children: [
          Text(
            'ANSWER SHEET INSTRUCTIONS',
            style: TextStyle(
              fontWeight: FontWeight.bold,
            ),
          ),
          SizedBox(height: 8),
          Text(
            '• Use a dark pencil or pen when answering.',
          ),
          Text(
            '• Fill in one bubble only for each question.',
          ),
          Text(
            '• For identification, write clearly inside the box.',
          ),
          Text(
            '• Do not write over the black registration markers.',
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------
  // OMR BUBBLE
  // ------------------------------------------------------------

  Widget _buildOmrBubble(
    String label,
  ) {
    return SizedBox(
      width: 44,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 25,
            height: 25,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                width: 1.5,
              ),
            ),
          ),
          const SizedBox(height: 3),
          Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------
  // MULTIPLE CHOICE HEADER
  // ------------------------------------------------------------

  Widget _buildOmrHeader() {
    return Row(
      children: [
        const SizedBox(
          width: 38,
          child: Text(
            'No.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          ),
        ),
        const SizedBox(width: 8),
        ...['A', 'B', 'C', 'D'].map(
          (choice) {
            return SizedBox(
              width: 44,
              child: Text(
                choice,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  // ------------------------------------------------------------
  // MULTIPLE CHOICE QUESTION
  // ------------------------------------------------------------

  Widget _buildMultipleChoiceQuestion(
    Map<String, dynamic> question,
    int index,
  ) {
    final questionNumber =
        question['question_number']?.toString() ??
            '${index + 1}';

    return Padding(
      padding: const EdgeInsets.only(
        bottom: 10,
      ),
      child: Row(
        children: [
          SizedBox(
            width: 38,
            child: Text(
              questionNumber,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
            ),
          ),
          const SizedBox(width: 8),
          _buildOmrBubble('A'),
          _buildOmrBubble('B'),
          _buildOmrBubble('C'),
          _buildOmrBubble('D'),
        ],
      ),
    );
  }

  // ------------------------------------------------------------
  // TRUE / FALSE HEADER
  // ------------------------------------------------------------

  Widget _buildTrueFalseHeader() {
    return Row(
      children: [
        const SizedBox(
          width: 38,
          child: Text(
            'No.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          ),
        ),
        const SizedBox(width: 8),
        const SizedBox(
          width: 44,
          child: Text(
            'T',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          ),
        ),
        const SizedBox(width: 44),
        const SizedBox(
          width: 44,
          child: Text(
            'F',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          ),
        ),
      ],
    );
  }

  // ------------------------------------------------------------
  // TRUE / FALSE QUESTION
  // ------------------------------------------------------------

  Widget _buildTrueFalseQuestion(
    Map<String, dynamic> question,
    int index,
  ) {
    final questionNumber =
        question['question_number']?.toString() ??
            '${index + 1}';

    return Padding(
      padding: const EdgeInsets.only(
        bottom: 10,
      ),
      child: Row(
        children: [
          SizedBox(
            width: 38,
            child: Text(
              questionNumber,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
            ),
          ),
          const SizedBox(width: 8),
          _buildOmrBubble('T'),
          _buildOmrBubble('F'),
        ],
      ),
    );
  }

  // ------------------------------------------------------------
  // IDENTIFICATION QUESTION
  // ------------------------------------------------------------

  Widget _buildIdentificationQuestion(
    Map<String, dynamic> question,
    int index,
  ) {
    final questionNumber =
        question['question_number']?.toString() ??
            '${index + 1}';

    return Container(
      margin: const EdgeInsets.only(
        bottom: 18,
      ),
      child: Column(
        crossAxisAlignment:
            CrossAxisAlignment.start,
        children: [
          Text(
            '$questionNumber.',
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 6),

          // Dedicated handwriting/OCR region.
          Container(
            width: double.infinity,
            height: 68,
            decoration: BoxDecoration(
              border: Border.all(
                width: 1.2,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------
  // SECTION
  // ------------------------------------------------------------

  Widget _buildSection(
    Map<String, dynamic> section,
  ) {
    final sectionId = int.tryParse(
      section['id']?.toString() ?? '',
    );

    final sectionName =
        section['name']?.toString() ?? 'Section';

    final questionType =
        section['question_type']?.toString() ?? '';

    final questions = sectionId == null
        ? <Map<String, dynamic>>[]
        : _questions[sectionId] ?? [];

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(
        bottom: 20,
      ),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(
          width: 1.5,
        ),
      ),
      child: Column(
        crossAxisAlignment:
            CrossAxisAlignment.start,
        children: [
          Text(
            sectionName.toUpperCase(),
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 14),

          if (questions.isEmpty)
            const Text(
              'No questions in this section.',
            )
          else if (questionType ==
              'multiple_choice') ...[
            _buildOmrHeader(),
            const SizedBox(height: 8),
            ...questions
                .asMap()
                .entries
                .map(
                  (entry) =>
                      _buildMultipleChoiceQuestion(
                    entry.value,
                    entry.key,
                  ),
                ),
          ] else if (questionType ==
              'true_false') ...[
            _buildTrueFalseHeader(),
            const SizedBox(height: 8),
            ...questions
                .asMap()
                .entries
                .map(
                  (entry) =>
                      _buildTrueFalseQuestion(
                    entry.value,
                    entry.key,
                  ),
                ),
          ] else ...[
            ...questions
                .asMap()
                .entries
                .map(
                  (entry) =>
                      _buildIdentificationQuestion(
                    entry.value,
                    entry.key,
                  ),
                ),
          ],
        ],
      ),
    );
  }

  // ------------------------------------------------------------
  // BODY
  // ------------------------------------------------------------

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
                onPressed: _loadAnswerSheet,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
       const double a5Width = 559;
       const double a5Height = 794;

        final availableWidth =
            constraints.maxWidth - 32;

        final availableHeight =
            constraints.maxHeight - 32;

        final scale = math.min(
          availableWidth / a5Width,
          availableHeight / a5Height,
        );

        return Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Transform.scale(
              scale: scale,
              alignment: Alignment.topCenter,
              child: SizedBox(
                width: a5Width,
                height: a5Height,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border.all(
                      width: 1,
                    ),
                    boxShadow: const [
                      BoxShadow(
                        blurRadius: 8,
                        offset: Offset(0, 3),
                      ),
                    ],
                  ),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(28),
                    child: Column(
                      children: [
                        _buildHeader(),

                        const SizedBox(height: 12),

                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            _buildQrCode(),
                          ],
                        ),

                        const SizedBox(height: 12),

                        _buildStudentInformation(),

                        const SizedBox(height: 16),

                        _buildInstructions(),

                        const SizedBox(height: 20),

                        Row(
                          mainAxisAlignment:
                              MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'Questions: '
                              '${_getTotalQuestions()}',
                              style: const TextStyle(
                                fontWeight:
                                    FontWeight.bold,
                              ),
                            ),
                            Text(
                              'Points: '
                              '${_getTotalPoints()}',
                              style: const TextStyle(
                                fontWeight:
                                    FontWeight.bold,
                              ),
                            ),
                          ],
                        ),

                        const SizedBox(height: 14),

                        ..._sections.map(
                          _buildSection,
                        ),

                        const SizedBox(height: 8),

                        const Text(
                          'CHECKMATE ANSWER SHEET',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1,
                          ),
                        ),

                        const SizedBox(height: 14),

                        Row(
                          mainAxisAlignment:
                              MainAxisAlignment.spaceBetween,
                          children: [
                            _buildRegistrationMarker(),
                            _buildRegistrationMarker(),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Answer Sheet Preview',
        ),
      ),
      body: _buildBody(),
    );
  }
}
