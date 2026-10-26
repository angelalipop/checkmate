import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'package:checkmate/services/answer_sheet_processor.dart';
import '../services/omr_processor.dart';
import '../services/opencv_omr_service.dart';
import '../services/scoring_service.dart';

class AnswerSheetUploadScreen extends StatefulWidget {
  final dynamic examId;
  final Uint8List? initialImageBytes;
  final String? initialFileName;

  final List<Map<String, dynamic>> sections;

  const AnswerSheetUploadScreen({
    super.key,
    this.examId,
    this.initialImageBytes,
    this.initialFileName,
    this.sections = const [],
  });

  @override
  State<AnswerSheetUploadScreen> createState() =>
      _AnswerSheetUploadScreenState();
}

class _AnswerSheetUploadScreenState
    extends State<AnswerSheetUploadScreen> {
  Uint8List? _imageBytes;
  Uint8List? _processedImageBytes;
  Uint8List? _omrDebugImageBytes;
  String? _fileName;

  bool _isProcessing = false;

  List<RegistrationPoint>? _detectedMarkers;

  OMRProcessingResult? _omrResult;
  ScoringResult? _scoringResult;
  bool _answersVerified = false;

  @override
  void initState() {
    super.initState();
    _imageBytes = widget.initialImageBytes;
    _fileName = widget.initialFileName ??
        (widget.initialImageBytes != null ? 'Camera capture' : null);
  }

  // ------------------------------------------------------------
  // PICK IMAGE
  // ------------------------------------------------------------

  Future<void> _pickImage() async {
    const XTypeGroup imageTypeGroup = XTypeGroup(
      label: 'Images',
      extensions: [
        'jpg',
        'jpeg',
        'png',
      ],
    );

    final XFile? file = await openFile(
      acceptedTypeGroups: [
        imageTypeGroup,
      ],
    );

    if (file == null) {
      return;
    }

    final Uint8List bytes = await file.readAsBytes();

    if (!mounted) {
      return;
    }

    setState(() {
      _imageBytes = bytes;
      _processedImageBytes = null;
      _omrDebugImageBytes = null;
      _detectedMarkers = null;
      _omrResult = null;
      _scoringResult = null;
      _answersVerified = false;
      _fileName = file.name;
      _isProcessing = false;
    });
  }

  // ------------------------------------------------------------
  // PROCESS ANSWER SHEET
  // ------------------------------------------------------------

  Future<void> _processImage() async {
    if (_imageBytes == null) {
      return;
    }

    setState(() {
      _isProcessing = true;
      _processedImageBytes = null;
      _omrDebugImageBytes = null;
      _detectedMarkers = null;
      _omrResult = null;
      _scoringResult = null;
      _answersVerified = false;
    });

    try {
      final result =
          await AnswerSheetProcessor.processAnswerSheet(
        _imageBytes!,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _processedImageBytes = result.correctedImageBytes;
        _detectedMarkers = result.markers;
        _isProcessing = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Answer sheet processed successfully.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) {
        return;
      }

      setState(() {
        _isProcessing = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Processing failed: $e',
          ),
          duration: const Duration(seconds: 5),
        ),
      );
    }
  }

  // ------------------------------------------------------------
  // RUN OMR + SCORING
  // ------------------------------------------------------------

  Future<void> _runOMR() async {
    if (_processedImageBytes == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Please process the answer sheet first.',
          ),
        ),
      );

      return;
    }

    if (widget.sections.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No exam sections were provided.',
          ),
        ),
      );

      return;
    }

    setState(() {
      _isProcessing = true;
    });

    try {
      // ----------------------------------------------------------
      // STEP 1: RUN OMR AFTER IMAGE CONFIRMATION
      // ----------------------------------------------------------

      final OpenCVOMRResult openCVResult = await OpenCVOMRService.process(
        _processedImageBytes!,
        sections: widget.sections,
      );

      final OMRProcessingResult result = _convertOpenCVResult(
        openCVResult,
      );

      if (!mounted) return;
      setState(() {
        _omrResult = result;
        _scoringResult = null;
        _answersVerified = false;
        _omrDebugImageBytes = result.debugImageBytes;
        _isProcessing = false;
      });
      await _verifyDetectedAnswers(result);
    } catch (e) {
      if (!mounted) {
        return;
      }

      setState(() {
        _isProcessing = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'OMR processing failed: $e',
          ),
          duration: const Duration(seconds: 5),
        ),
      );
    }
  }

  // ------------------------------------------------------------
  // CONVERT OPENCV MEASUREMENTS TO APP OMR RESULTS
  // ------------------------------------------------------------

  OMRProcessingResult _convertOpenCVResult(
    OpenCVOMRResult openCVResult,
  ) {
    const double markedThreshold = 0.55;

    final List<OMRSectionResult> convertedSections = [];
    int openCVSectionIndex = 0;

    for (final Map<String, dynamic> sourceSection in widget.sections) {
      final String sectionType = _normalizeQuestionType(
        sourceSection['question_type'] ?? sourceSection['type'],
      );
      final String sectionName = sourceSection['display_name']?.toString() ??
          sourceSection['section_name']?.toString() ??
          sourceSection['name']?.toString() ??
          'Section';
      final List<dynamic> questions = sourceSection['questions'] is List
          ? List<dynamic>.from(sourceSection['questions'] as List)
          : <dynamic>[];
      final int questionCount = questions.isNotEmpty
          ? questions.length
          : int.tryParse(sourceSection['question_count']?.toString() ?? '0') ?? 0;

      if (sectionType == 'identification') {
        if (openCVSectionIndex < openCVResult.sections.length &&
            openCVResult.sections[openCVSectionIndex].sectionType == 'identification') {
          openCVSectionIndex++;
        }
        convertedSections.add(OMRSectionResult(
          sectionName: sectionName,
          sectionType: sectionType,
          questionCount: questionCount,
          answers: List<OMRAnswer>.generate(
            questionCount,
            (int index) => OMRAnswer(
              questionNumber: index + 1,
              answer: 'OCR Pending',
              confidence: 0,
            ),
          ),
        ));
        continue;
      }

      if (sectionType != 'multiple_choice' && sectionType != 'true_false') {
        continue;
      }

      if (openCVSectionIndex >= openCVResult.sections.length) {
        convertedSections.add(OMRSectionResult(
          sectionName: sectionName,
          sectionType: sectionType,
          questionCount: questionCount,
          answers: List<OMRAnswer>.generate(
            questionCount,
            (int index) => OMRAnswer(
              questionNumber: index + 1,
              answer: 'Unanswered',
              confidence: 0,
            ),
          ),
        ));
        continue;
      }

      final OpenCVSectionMeasurement measuredSection =
          openCVResult.sections[openCVSectionIndex];
      if (measuredSection.sectionType != sectionType) {
        throw StateError('OMR section mismatch at "$sectionName": '
            'expected $sectionType but received ${measuredSection.sectionType}.');
      }
      openCVSectionIndex++;
      final List<OMRAnswer> answers = [];

      for (final OpenCVQuestionMeasurement question in measuredSection.questions) {
        final List<OpenCVBubbleMeasurement> bubbles =
            List<OpenCVBubbleMeasurement>.from(question.bubbles)
              ..sort((a, b) => b.fillRatio.compareTo(a.fillRatio));

        if (bubbles.isEmpty) {
          answers.add(OMRAnswer(
            questionNumber: question.questionNumber,
            answer: 'Unanswered',
            confidence: 0,
          ));
          continue;
        }

        final OpenCVBubbleMeasurement strongest = bubbles.first;
        final OpenCVBubbleMeasurement? second =
            bubbles.length > 1 ? bubbles[1] : null;

        if (strongest.fillRatio >= 0.46 && strongest.fillRatio < markedThreshold) {
          answers.add(OMRAnswer(
            questionNumber: question.questionNumber,
            answer: 'Ambiguous',
            confidence: strongest.fillRatio,
          ));
          continue;
        }
        if (strongest.fillRatio < markedThreshold) {
          answers.add(OMRAnswer(
            questionNumber: question.questionNumber,
            answer: 'Unanswered',
            confidence: strongest.fillRatio,
          ));
          continue;
        }

        if (second != null && second.fillRatio >= markedThreshold) {
          answers.add(OMRAnswer(
            questionNumber: question.questionNumber,
            answer: 'Multiple',
            confidence: strongest.fillRatio,
          ));
          continue;
        }

        if (second != null && strongest.fillRatio - second.fillRatio < 0.12) {
          answers.add(OMRAnswer(
            questionNumber: question.questionNumber,
            answer: 'Ambiguous',
            confidence: strongest.fillRatio,
          ));
          continue;
        }
        answers.add(OMRAnswer(
          questionNumber: question.questionNumber,
          answer: strongest.label,
          confidence: strongest.fillRatio,
        ));
      }

      convertedSections.add(OMRSectionResult(
        sectionName: sectionName,
        sectionType: sectionType,
        questionCount: questionCount,
        answers: answers,
      ));
    }

    return OMRProcessingResult(
      sections: convertedSections,
      debugImageBytes: openCVResult.debugImageBytes,
    );
  }

  String _normalizeQuestionType(dynamic value) {
    final String type = value?.toString().trim().toLowerCase() ?? '';
    switch (type) {
      case 'multiple choice':
      case 'mc':
      case 'mcq':
      case 'multiple_choice':
        return 'multiple_choice';
      case 'true or false':
      case 'true/false':
      case 'tf':
      case 'true_false':
        return 'true_false';
      case 'identification':
      case 'identify':
      case 'id':
        return 'identification';
      default:
        return type;
    }
  }

  // ------------------------------------------------------------
  // REVIEW DETECTED STUDENT ANSWERS BEFORE SCORING
  // ------------------------------------------------------------

  Future<void> _verifyDetectedAnswers(OMRProcessingResult rawResult) async {
    final edits = <String, String>{};
    for (var sectionIndex = 0; sectionIndex < rawResult.sections.length; sectionIndex++) {
      final section = rawResult.sections[sectionIndex];
      for (final answer in section.answers) {
        edits['$sectionIndex:${answer.questionNumber}'] = answer.answer;
      }
    }

    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, refresh) {
          final pending = edits.values.where((v) =>
              v == 'Ambiguous' || v == 'Multiple').length;
          return AlertDialog(
            title: const Text('Verify Student Answers'),
            content: SizedBox(
              width: MediaQuery.sizeOf(dialogContext).width * 0.85,
              height: MediaQuery.sizeOf(dialogContext).height * 0.65,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Compare each detection against the scanned sheet. '
                      'Change incorrect answers before scoring.'),
                  const SizedBox(height: 8),
                  if (pending > 0)
                    Text('$pending answer(s) require manual review.',
                        style: const TextStyle(color: Colors.deepOrange)),
                  const Divider(),
                  Expanded(
                    child: ListView.builder(
                      itemCount: rawResult.sections.length,
                      itemBuilder: (context, sectionIndex) {
                        final section = rawResult.sections[sectionIndex];
                        final options = section.sectionType == 'multiple_choice'
                            ? <String>['A', 'B', 'C', 'D']
                            : section.sectionType == 'true_false'
                                ? <String>['T', 'F']
                                : <String>[];
                        return Card(
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(section.sectionName,
                                    style: Theme.of(context).textTheme.titleMedium),
                                Text(_displaySectionType(section.sectionType)),
                                const SizedBox(height: 8),
                                for (final answer in section.answers)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 4),
                                    child: Row(
                                      children: [
                                        SizedBox(width: 48,
                                            child: Text('Q${answer.questionNumber}')),
                                        Expanded(
                                          child: section.sectionType == 'identification'
                                              ? TextFormField(
                                                  initialValue: (edits['$sectionIndex:${answer.questionNumber}'] == 'OCR Pending' ||
                                                      edits['$sectionIndex:${answer.questionNumber}'] == 'Unanswered')
                                                      ? ''
                                                      : edits['$sectionIndex:${answer.questionNumber}'],
                                                  decoration: const InputDecoration(
                                                    labelText: 'Transcribe handwritten answer',
                                                    isDense: true,
                                                    border: OutlineInputBorder(),
                                                  ),
                                                  onChanged: (value) => refresh(() => edits[
                                                      '$sectionIndex:${answer.questionNumber}'] =
                                                      value.trim().isEmpty ? 'Unanswered' : value.trim()),
                                                )
                                              : DropdownButtonFormField<String>(
                                                  initialValue: options.contains(edits['$sectionIndex:${answer.questionNumber}'])
                                                      ? edits['$sectionIndex:${answer.questionNumber}']
                                                      : edits['$sectionIndex:${answer.questionNumber}'] == 'Unanswered'
                                                          ? 'Unanswered'
                                                          : 'Ambiguous',
                                                  isExpanded: true,
                                                  decoration: const InputDecoration(
                                                    labelText: 'Verified answer',
                                                    isDense: true,
                                                    border: OutlineInputBorder(),
                                                  ),
                                                  items: [
                                                    ...options,
                                                    'Unanswered',
                                                    'Ambiguous',
                                                  ].map((value) => DropdownMenuItem(
                                                    value: value,
                                                    child: Text(value),
                                                  )).toList(),
                                                  onChanged: (value) {
                                                    if (value != null) {
                                                      refresh(() => edits[
                                                        '$sectionIndex:${answer.questionNumber}'] = value);
                                                    }
                                                  },
                                                ),
                                        ),
                                        const SizedBox(width: 8),
                                        SizedBox(width: 65,
                                          child: Text(answer.confidence > 0
                                              ? '${(answer.confidence * 100).round()}%'
                                              : 'Manual',
                                            textAlign: TextAlign.end),
                                        ),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: pending > 0 ? null : () => Navigator.of(dialogContext).pop(true),
                child: const Text('Confirm & Calculate Score'),
              ),
            ],
          );
        },
      ),
    );

    if (confirmed != true || !mounted) return;
    final verifiedSections = <OMRSectionResult>[];
    for (var i = 0; i < rawResult.sections.length; i++) {
      final section = rawResult.sections[i];
      verifiedSections.add(OMRSectionResult(
        sectionName: section.sectionName,
        sectionType: section.sectionType,
        questionCount: section.questionCount,
        answers: [
          for (final answer in section.answers)
            OMRAnswer(
              questionNumber: answer.questionNumber,
              answer: (edits['$i:${answer.questionNumber}'] ?? answer.answer) == 'OCR Pending'
                  ? 'Unanswered'
                  : (edits['$i:${answer.questionNumber}'] ?? answer.answer),
              confidence: answer.confidence,
            ),
        ],
      ));
    }
    final verified = OMRProcessingResult(
      sections: verifiedSections,
      debugImageBytes: rawResult.debugImageBytes,
    );
    final score = ScoringService.score(
      omrResult: verified,
      sections: widget.sections,
    );
    setState(() {
      _omrResult = verified;
      _scoringResult = score;
      _answersVerified = true;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Answers verified and score calculated. Not yet saved to database.')),
    );
  }

  // ------------------------------------------------------------
  // DISPLAY SECTION TYPE
  // ------------------------------------------------------------

  String _displaySectionType(
    String type,
  ) {
    switch (type) {
      case 'multiple_choice':
        return 'Multiple Choice • A–D';

      case 'true_false':
        return 'True or False • T/F';

      case 'identification':
        return 'Identification • OCR';

      default:
        return type;
    }
  }

  // ------------------------------------------------------------
  // SECTION ICON
  // ------------------------------------------------------------

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

  // ------------------------------------------------------------
  // CHOOSE ANOTHER IMAGE
  // ------------------------------------------------------------

  void _chooseAnother() {
    setState(() {
      _imageBytes = null;
      _processedImageBytes = null;
      _omrDebugImageBytes = null;
      _detectedMarkers = null;
      _omrResult = null;
      _scoringResult = null;
      _answersVerified = false;
      _fileName = null;
      _isProcessing = false;
    });
  }

  // ------------------------------------------------------------
  // BUILD
  // ------------------------------------------------------------

  @override
  Widget build(
    BuildContext context,
  ) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Answer Sheet Scanner',
        ),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: constraints.maxHeight,
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: 1000,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: _buildContent(),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  // ------------------------------------------------------------
  // MAIN CONTENT
  // ------------------------------------------------------------

  Widget _buildContent() {
    if (_imageBytes == null) {
      return _buildEmptyState();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Selected Answer Sheet',
          style: Theme.of(context).textTheme.headlineSmall,
        ),

        const SizedBox(height: 8),

        Text(
          _fileName ?? 'Image',
        ),

        const SizedBox(height: 20),

        _buildImagePreview(
          _imageBytes!,
        ),

        const SizedBox(height: 20),

        if (_isProcessing)
          _buildProcessingCard(),

        if (_processedImageBytes != null &&
            !_isProcessing)
          _buildProcessedResult(),

        const SizedBox(height: 20),

        _buildActionButtons(),
      ],
    );
  }

  // ------------------------------------------------------------
  // EMPTY STATE
  // ------------------------------------------------------------

  Widget _buildEmptyState() {
    return SizedBox(
      width: double.infinity,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.upload_file,
            size: 70,
          ),

          const SizedBox(height: 20),

          const Text(
            'Upload an Answer Sheet',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
            ),
          ),

          const SizedBox(height: 8),

          const Text(
            'Upload a JPG, JPEG, or PNG image.',
          ),

          const SizedBox(height: 24),

          ElevatedButton.icon(
            onPressed: _pickImage,
            icon: const Icon(Icons.upload),
            label: const Text(
              'Choose Image',
            ),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------
  // IMAGE PREVIEW
  // ------------------------------------------------------------

  Widget _buildImagePreview(
    Uint8List bytes,
  ) {
    return Container(
      width: double.infinity,
      height: 500,
      decoration: BoxDecoration(
        border: Border.all(
          color: Colors.grey.shade300,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.memory(
          bytes,
          fit: BoxFit.contain,
          width: double.infinity,
          height: double.infinity,
        ),
      ),
    );
  }

  // ------------------------------------------------------------
  // PROCESSING CARD
  // ------------------------------------------------------------

  Widget _buildProcessingCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(),
            ),

            const SizedBox(width: 16),

            const Expanded(
              child: Text(
                'Detecting markers, correcting '
                'perspective, and processing '
                'the answer sheet...',
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------
  // PROCESSED RESULT
  // ------------------------------------------------------------

  Widget _buildProcessedResult() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Processed Answer Sheet',
          style: Theme.of(context).textTheme.titleLarge,
        ),

        const SizedBox(height: 12),

        _buildImagePreview(
          _processedImageBytes!,
        ),

        const SizedBox(height: 16),

        if (_detectedMarkers != null)
          _buildMarkerInformation(),

        const SizedBox(height: 16),

        // Do NOT render the full OMR result list here.
        //
        // The complete result is displayed in the dialog
        // after Run OMR.
        if (_omrResult != null)
          _buildOMRSummary(
            _omrResult!,
          ),

        if (_scoringResult != null) ...[
          const SizedBox(height: 12),
          _buildScoringSummary(
            _scoringResult!,
          ),
        ],
      ],
    );
  }

  // ------------------------------------------------------------
  // OMR SUMMARY
  // ------------------------------------------------------------

  Widget _buildOMRSummary(
    OMRProcessingResult result,
  ) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const Icon(
              Icons.check_circle_outline,
            ),

            const SizedBox(width: 12),

            Expanded(
              child: Text(
                'OMR complete: '
                '${result.answeredQuestions} of '
                '${result.detectedQuestions} '
                'questions answered.',
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------
  // SCORING SUMMARY
  // ------------------------------------------------------------

  Widget _buildScoringSummary(
    ScoringResult result,
  ) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment:
              CrossAxisAlignment.start,
          children: [
            const Text(
              'Score',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),

            const SizedBox(height: 8),

            Text(
              '${result.earnedPoints.toStringAsFixed(2)} '
              '/ '
              '${result.totalPoints.toStringAsFixed(2)}',
              style: const TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
              ),
            ),

            const SizedBox(height: 4),

            Text(
              '${result.percentage.toStringAsFixed(1)}%',
            ),

            const SizedBox(height: 4),

            Text(
              '${result.correctAnswers} correct • '
              '${result.answeredQuestions} answered • '
              '${result.totalQuestions} total',
            ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------
  // MARKER INFORMATION
  // ------------------------------------------------------------

  Widget _buildMarkerInformation() {
    final List<RegistrationPoint> markers =
        _detectedMarkers!;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment:
              CrossAxisAlignment.start,
          children: [
            const Text(
              'Registration Markers',
              style: TextStyle(
                fontWeight: FontWeight.bold,
              ),
            ),

            const SizedBox(height: 8),

            for (int i = 0; i < markers.length; i++)
              Padding(
                padding:
                    const EdgeInsets.symmetric(
                  vertical: 2,
                ),
                child: Text(
                  '${_markerName(i)}: '
                  '(${markers[i].x.toStringAsFixed(1)}, '
                  '${markers[i].y.toStringAsFixed(1)})',
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------
  // MARKER NAME
  // ------------------------------------------------------------

  String _markerName(
    int index,
  ) {
    switch (index) {
      case 0:
        return 'Top Left';

      case 1:
        return 'Top Right';

      case 2:
        return 'Bottom Right';

      case 3:
        return 'Bottom Left';

      default:
        return 'Marker ${index + 1}';
    }
  }

  // ------------------------------------------------------------
  // ACTION BUTTONS
  // ------------------------------------------------------------

  Widget _buildActionButtons() {
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        OutlinedButton.icon(
          onPressed:
              _isProcessing
                  ? null
                  : _chooseAnother,
          icon: const Icon(Icons.refresh),
          label: const Text(
            'Choose Another',
          ),
        ),

        if (_processedImageBytes == null)
          ElevatedButton.icon(
            onPressed:
                _isProcessing
                    ? null
                    : _processImage,
            icon: const Icon(
              Icons.auto_fix_high,
            ),
            label: const Text(
              'Process Answer Sheet',
            ),
          ),

        if (_omrResult != null)
          OutlinedButton.icon(
            onPressed: _isProcessing ? null : () => _verifyDetectedAnswers(_omrResult!),
            icon: const Icon(Icons.fact_check_outlined),
            label: Text(_answersVerified ? 'Review Answers Again' : 'Verify Answers'),
          ),

        if (_processedImageBytes != null && _omrResult == null)
          ElevatedButton.icon(
            onPressed:
                _isProcessing
                    ? null
                    : _runOMR,
            icon: const Icon(
              Icons.document_scanner,
            ),
            label: const Text(
              'Confirm Processed Image & Detect Answers',
            ),
          ),
      ],
    );
  }
}