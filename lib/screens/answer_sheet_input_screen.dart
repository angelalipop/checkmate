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

  List<dynamic> _exams = [];

  dynamic _selectedExam;

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
  // CONTINUE
  // =========================

  void _continueToScanner() {
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

    final examId = _selectedExam['id'];

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) {
          if (kIsWeb) {
            return AnswerSheetUploadScreen(
              examId: examId,
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
                  // =========================
                  // HEADER
                  // =========================

                  const Icon(
                    Icons.document_scanner_outlined,
                    size: 70,
                  ),

                  const SizedBox(
                    height: 20,
                  ),

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

                  const SizedBox(
                    height: 8,
                  ),

                  Text(
                    kIsWeb
                        ? 'Choose the exam you want to check, then upload the completed answer sheet.'
                        : 'Choose the exam you want to check, then use your phone camera to scan the completed answer sheet.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium,
                  ),

                  const SizedBox(
                    height: 30,
                  ),

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

                            const SizedBox(
                              height: 12,
                            ),

                            const Text(
                              'No exams available.',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight:
                                    FontWeight.bold,
                              ),
                            ),

                            const SizedBox(
                              height: 8,
                            ),

                            const Text(
                              'Create an exam first before scanning an answer sheet.',
                              textAlign:
                                  TextAlign.center,
                            ),

                            const SizedBox(
                              height: 16,
                            ),

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
                    DropdownButtonFormField<dynamic>(
                      initialValue:
                          _selectedExam,

                      decoration:
                          InputDecoration(
                        labelText:
                            'Exam',
                        hintText:
                            'Select an exam',
                        prefixIcon:
                            const Icon(
                          Icons.assignment_outlined,
                        ),
                        border:
                            OutlineInputBorder(
                          borderRadius:
                              BorderRadius.circular(
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

                      onChanged: (value) {
                        setState(() {
                          _selectedExam = value;
                        });
                      },
                    ),

                  const SizedBox(
                    height: 30,
                  ),

                  // =========================
                  // INPUT METHOD INFORMATION
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

                            const SizedBox(
                              height: 12,
                            ),

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

                            const SizedBox(
                              height: 8,
                            ),

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

                  const SizedBox(
                    height: 24,
                  ),

                  // =========================
                  // CONTINUE BUTTON
                  // =========================

                  if (_exams.isNotEmpty)
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed:
                            _continueToScanner,

                        icon: Icon(
                          kIsWeb
                              ? Icons.upload
                              : Icons
                                  .document_scanner,
                        ),

                        label: Text(
                          kIsWeb
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
}