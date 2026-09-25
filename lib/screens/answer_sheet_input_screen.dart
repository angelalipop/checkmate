import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../services/auth_storage.dart';
import 'answer_sheet_camera_screen.dart';
import 'answer_sheet_upload_screen.dart';

class AnswerSheetInputScreen extends StatefulWidget {
  const AnswerSheetInputScreen({
    super.key,
  });

  @override
  State<AnswerSheetInputScreen> createState() =>
      _AnswerSheetInputScreenState();
}

class _AnswerSheetInputScreenState
    extends State<AnswerSheetInputScreen> {
  bool _isLoading = true;
  bool _isLoadingSections = false;

  List<Map<String, dynamic>> _exams = [];

  dynamic _selectedExam;

  List<Map<String, dynamic>> _selectedExamSections = [];

  @override
  void initState() {
    super.initState();
    _loadExams();
  }

  // =========================
  // LOAD EXAMS
  // =========================

  Future<void> _loadExams() async {
    try {
      final token = await AuthStorage.getToken();

      if (token == null || token.isEmpty) {
        if (!mounted) return;

        setState(() {
          _isLoading = false;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Session expired. Please log in again.',
            ),
          ),
        );

        return;
      }

      final exams = await ApiService.getExams(token);

      if (!mounted) return;

      setState(() {
        _exams = exams;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _isLoading = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Failed to load exams: $e',
          ),
        ),
      );
    }
  }

  // =========================
  // LOAD SELECTED EXAM DATA
  // =========================

  Future<void> _loadExamSections() async {
    if (_selectedExam == null) {
      return;
    }

    final dynamic rawExamId = _selectedExam['id'];

    final int? examId = int.tryParse(
      rawExamId.toString(),
    );

    if (examId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Invalid exam ID.',
          ),
        ),
      );

      return;
    }

    setState(() {
      _isLoadingSections = true;
      _selectedExamSections = [];
    });

    try {
      final token = await AuthStorage.getToken();

      if (token == null || token.isEmpty) {
        throw Exception(
          'Session expired. Please log in again.',
        );
      }

      // Get sections belonging to this exam.
      final sections =
          await ApiService.getExamSections(
        token,
        examId,
      );

      final List<Map<String, dynamic>> preparedSections = [];

      // Get questions for every section.
      for (final section in sections) {
        final dynamic rawSectionId =
            section['id'];

        final int? sectionId = int.tryParse(
          rawSectionId.toString(),
        );

        if (sectionId == null) {
          continue;
        }

        final questions =
            await ApiService.getQuestions(
          token,
          sectionId,
        );

        // Make a copy so we don't modify
        // the original API response.
        final Map<String, dynamic> preparedSection =
            Map<String, dynamic>.from(section);

        // Store the actual questions.
        preparedSection['questions'] =
            questions;

        // Store the actual number of questions.
        preparedSection['question_count'] =
            questions.length;

        // Normalize the section type.
        preparedSection['question_type'] =
            _normalizeQuestionType(
          section['question_type'] ??
              section['type'],
        );

        // Make sure the section has a display name.
        preparedSection['display_name'] =
            _getSectionName(section);

        preparedSections.add(
          preparedSection,
        );
      }

      if (!mounted) return;

      setState(() {
        _selectedExamSections =
            preparedSections;
        _isLoadingSections = false;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _isLoadingSections = false;
        _selectedExamSections = [];
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Failed to load exam sections: $e',
          ),
          duration: const Duration(
            seconds: 5,
          ),
        ),
      );
    }
  }

  // =========================
  // NORMALIZE QUESTION TYPE
  // =========================

  String _normalizeQuestionType(
    dynamic value,
  ) {
    final type =
        value?.toString().trim().toLowerCase() ?? '';

    switch (type) {
      case 'multiple_choice':
      case 'multiple choice':
      case 'mc':
      case 'mcq':
        return 'multiple_choice';

      case 'true_false':
      case 'true or false':
      case 'true/false':
      case 'true_false_question':
      case 'tf':
        return 'true_false';

      case 'identification':
      case 'identify':
      case 'id':
        return 'identification';

      default:
        return type;
    }
  }

  // =========================
  // SECTION DISPLAY NAME
  // =========================

  String _getSectionName(
    Map<String, dynamic> section,
  ) {
    final name =
        section['name'] ??
        section['title'] ??
        section['section_name'];

    if (name != null &&
        name.toString().trim().isNotEmpty) {
      return name.toString();
    }

    return 'Section';
  }

  // =========================
  // CONTINUE TO SCANNER
  // =========================

  Future<void> _continueToScanner() async {
    if (_selectedExam == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Please select an exam first.',
          ),
        ),
      );

      return;
    }

    if (_isLoadingSections) {
      return;
    }

    // If sections have not been loaded yet,
    // load them now.
    if (_selectedExamSections.isEmpty) {
      await _loadExamSections();

      if (!mounted) {
        return;
      }

      if (_selectedExamSections.isEmpty) {
        return;
      }
    }

    final dynamic rawExamId =
        _selectedExam['id'];

    final int? examId = int.tryParse(
      rawExamId.toString(),
    );

    if (examId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Invalid exam ID.',
          ),
        ),
      );

      return;
    }

    // Convert the sections into the structure
    // expected by the scanner/OMR processor.
    final List<Map<String, dynamic>> scannerSections =
        _selectedExamSections.map(
      (section) {
        return {
          'id': section['id'],
          'name': _getSectionName(section),
          'section_name': _getSectionName(section),
          'question_type':
              _normalizeQuestionType(
            section['question_type'],
          ),
          'question_count':
              section['question_count'] ?? 0,
          'questions':
              section['questions'] ?? [],
        };
      },
    ).toList();

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) {
          if (kIsWeb) {
            return AnswerSheetUploadScreen(
              examId: examId,
              sections: scannerSections,
            );
          }

          return AnswerSheetCameraScreen(
            examId: examId,
          );
        },
      ),
    );
  }

  // =========================
  // BUILD
  // =========================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Scan Answer Sheet',
        ),
      ),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(),
            )
          : RefreshIndicator(
              onRefresh: _loadExams,
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  const Icon(
                    Icons.document_scanner_outlined,
                    size: 70,
                  ),

                  const SizedBox(height: 20),

                  Text(
                    'Select an Exam',
                    textAlign: TextAlign.center,
                    style: Theme.of(context)
                        .textTheme
                        .headlineSmall
                        ?.copyWith(
                          fontWeight:
                              FontWeight.bold,
                        ),
                  ),

                  const SizedBox(height: 8),

                  Text(
                    kIsWeb
                        ? 'Choose the exam you want to check, then upload the completed answer sheet.'
                        : 'Choose the exam you want to check, then use your phone camera to scan the completed answer sheet.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium,
                  ),

                  const SizedBox(height: 30),

                  // =========================
                  // NO EXAMS
                  // =========================

                  if (_exams.isEmpty)
                    Card(
                      child: Padding(
                        padding:
                            const EdgeInsets.all(24),
                        child: Column(
                          children: [
                            const Icon(
                              Icons
                                  .assignment_late_outlined,
                              size: 50,
                            ),

                            const SizedBox(height: 12),

                            const Text(
                              'No exams available.',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight:
                                    FontWeight.bold,
                              ),
                            ),

                            const SizedBox(height: 8),

                            const Text(
                              'Create an exam first before scanning an answer sheet.',
                              textAlign:
                                  TextAlign.center,
                            ),

                            const SizedBox(height: 16),

                            OutlinedButton.icon(
                              onPressed:
                                  _loadExams,
                              icon: const Icon(
                                Icons.refresh,
                              ),
                              label: const Text(
                                'Refresh',
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                  // =========================
                  // EXAM DROPDOWN
                  // =========================

                  if (_exams.isNotEmpty)
                    DropdownButtonFormField<
                        dynamic>(
                      initialValue:
                          _selectedExam,

                      decoration:
                          InputDecoration(
                        labelText: 'Exam',
                        hintText:
                            'Select an exam',
                        prefixIcon:
                            const Icon(
                          Icons
                              .assignment_outlined,
                        ),
                        border:
                            OutlineInputBorder(
                          borderRadius:
                              BorderRadius
                                  .circular(
                            12,
                          ),
                        ),
                      ),

                      items: _exams.map(
                        (exam) {
                          return DropdownMenuItem<
                              dynamic>(
                            value: exam,
                            child: Text(
                              exam['title']
                                      ?.toString() ??
                                  'Untitled Exam',
                            ),
                          );
                        },
                      ).toList(),

                      onChanged: (value) async {
                        setState(() {
                          _selectedExam = value;
                          _selectedExamSections =
                              [];
                        });

                        if (value != null) {
                          await _loadExamSections();
                        }
                      },
                    ),

                  const SizedBox(height: 20),

                  // =========================
                  // LOADING SECTIONS
                  // =========================

                  if (_isLoadingSections)
                    const Card(
                      child: Padding(
                        padding:
                            EdgeInsets.all(20),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 22,
                              height: 22,
                              child:
                                  CircularProgressIndicator(
                                strokeWidth: 2,
                              ),
                            ),
                            SizedBox(width: 14),
                            Expanded(
                              child: Text(
                                'Loading exam sections and questions...',
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                  // =========================
                  // SECTION INFORMATION
                  // =========================

                  if (!_isLoadingSections &&
                      _selectedExamSections
                          .isNotEmpty)
                    Card(
                      child: Padding(
                        padding:
                            const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment:
                              CrossAxisAlignment
                                  .start,
                          children: [
                            const Text(
                              'Exam Structure',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight:
                                    FontWeight.bold,
                              ),
                            ),

                            const SizedBox(
                              height: 12,
                            ),

                            ..._selectedExamSections
                                .map(
                              (section) {
                                final type =
                                    _normalizeQuestionType(
                                  section[
                                      'question_type'],
                                );

                                final count =
                                    section[
                                            'question_count']
                                        ?.toString() ??
                                    '0';

                                return Padding(
                                  padding:
                                      const EdgeInsets
                                          .symmetric(
                                    vertical: 5,
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        _sectionIcon(
                                          type,
                                        ),
                                        size: 20,
                                      ),
                                      const SizedBox(
                                        width: 10,
                                      ),
                                      Expanded(
                                        child: Text(
                                          _getSectionName(
                                            section,
                                          ),
                                        ),
                                      ),
                                      Text(
                                        '$count questions',
                                        style:
                                            const TextStyle(
                                          fontWeight:
                                              FontWeight
                                                  .w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                    ),

                  const SizedBox(height: 20),

                  // =========================
                  // INPUT METHOD
                  // =========================

                  if (_exams.isNotEmpty)
                    Card(
                      child: Padding(
                        padding:
                            const EdgeInsets.all(20),
                        child: Column(
                          children: [
                            Icon(
                              kIsWeb
                                  ? Icons
                                      .upload_file_outlined
                                  : Icons
                                      .photo_camera_outlined,
                              size: 45,
                            ),

                            const SizedBox(height: 12),

                            Text(
                              kIsWeb
                                  ? 'Upload Answer Sheet'
                                  : 'Scan with Camera',
                              style:
                                  const TextStyle(
                                fontSize: 18,
                                fontWeight:
                                    FontWeight.bold,
                              ),
                            ),

                            const SizedBox(height: 8),

                            Text(
                              kIsWeb
                                  ? 'Web version uses uploaded answer sheet files.'
                                  : 'Mobile version uses the phone camera for real-time scanning.',
                              textAlign:
                                  TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                    ),

                  const SizedBox(height: 24),

                  // =========================
                  // CONTINUE BUTTON
                  // =========================

                  if (_exams.isNotEmpty)
                    SizedBox(
                      width: double.infinity,
                      child:
                          ElevatedButton.icon(
                        onPressed:
                            _isLoadingSections
                                ? null
                                : _continueToScanner,

                        icon: _isLoadingSections
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child:
                                    CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Icon(
                                kIsWeb
                                    ? Icons.upload
                                    : Icons
                                        .document_scanner,
                              ),

                        label: Text(
                          _isLoadingSections
                              ? 'Loading Exam...'
                              : kIsWeb
                                  ? 'Continue to Upload'
                                  : 'Continue to Scanner',
                        ),

                        style:
                            ElevatedButton.styleFrom(
                          padding:
                              const EdgeInsets
                                  .symmetric(
                            vertical: 17,
                          ),
                          shape:
                              RoundedRectangleBorder(
                            borderRadius:
                                BorderRadius.circular(
                              12,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
    );
  }

  // =========================
  // SECTION ICON
  // =========================

  IconData _sectionIcon(
    String type,
  ) {
    switch (type) {
      case 'multiple_choice':
        return Icons.radio_button_checked;

      case 'true_false':
        return Icons.check_circle_outline;

      case 'identification':
        return Icons.edit_note;

      default:
        return Icons.article_outlined;
    }
  }
}
