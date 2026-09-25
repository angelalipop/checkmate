import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../services/answer_sheet_processor.dart';
import '../services/omr_processor.dart';

class AnswerSheetUploadScreen extends StatefulWidget {
  final dynamic examId;

  final List<Map<String, dynamic>> sections;

  const AnswerSheetUploadScreen({
    super.key,
    this.examId,
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
  String? _fileName;

  bool _isProcessing = false;

  List<RegistrationPoint>? _detectedMarkers;

  OMRProcessingResult? _omrResult;

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
      _detectedMarkers = null;
      _omrResult = null;
      _fileName = file.name;
    });
  }

  Future<void> _processImage() async {
    if (_imageBytes == null) {
      return;
    }

    setState(() {
      _isProcessing = true;
      _processedImageBytes = null;
      _detectedMarkers = null;
      _omrResult = null;
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
      final OMRProcessingResult result =
          await OMRProcessor.process(
        _processedImageBytes!,
        sections: widget.sections,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _omrResult = result;
        _isProcessing = false;
      });

      await _showOMRResults(result);
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

  Future<void> _showOMRResults(
    OMRProcessingResult result,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text(
            'OMR Detection Results',
          ),
          content: SizedBox(
            width: 650,
            height: 500,
            child: _buildOMRDialogContent(result),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
              },
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  Widget _buildOMRDialogContent(
    OMRProcessingResult result,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${result.detectedQuestions} questions',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 4),
        Text(
          '${result.answeredQuestions} answered',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 16),
        Expanded(
          child: ListView.builder(
            itemCount: result.sections.length,
            itemBuilder: (context, index) {
              return _buildSectionResult(
                result.sections[index],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildSectionResult(
    OMRSectionResult section,
  ) {
    final String displayType =
        _displaySectionType(section.sectionType);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Icon(
                  _sectionIcon(section.sectionType),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    section.sectionName,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '$displayType • '
              '${section.questionCount} questions',
            ),
            const Divider(),

            // Use Column instead of another ListView.
            //
            // The outer dialog already contains the single
            // scrollable ListView.
            for (final answer in section.answers)
              _buildAnswerRow(
                answer,
                section.sectionType,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildAnswerRow(
    OMRAnswer answer,
    String sectionType,
  ) {
    final bool unanswered = answer.isUnanswered;

    final bool ocrPending =
        answer.answer == 'OCR Pending';

    String answerText = answer.answer;

    if (sectionType == 'true_false') {
      if (answer.answer == 'T') {
        answerText = 'True';
      } else if (answer.answer == 'F') {
        answerText = 'False';
      }
    }

    return Padding(
      padding: const EdgeInsets.symmetric(
        vertical: 4,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 55,
            child: Text(
              'Q${answer.questionNumber}',
              style: const TextStyle(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Text(
              answerText,
            ),
          ),
          if (!unanswered &&
              !ocrPending &&
              answer.confidence > 0)
            Padding(
              padding: const EdgeInsets.only(
                left: 8,
              ),
              child: Text(
                '${(answer.confidence * 100).round()}%',
              ),
            ),
        ],
      ),
    );
  }

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

  void _chooseAnother() {
    setState(() {
      _imageBytes = null;
      _processedImageBytes = null;
      _detectedMarkers = null;
      _omrResult = null;
      _fileName = null;
      _isProcessing = false;
    });
  }

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

        // Do NOT render the OMR result list here.
        //
        // The complete result is already displayed in
        // the dialog after Run OMR.
        if (_omrResult != null)
          _buildOMRSummary(_omrResult!),
      ],
    );
  }

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
                '${result.detectedQuestions} questions answered.',
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMarkerInformation() {
    final List<RegistrationPoint> markers =
        _detectedMarkers!;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
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
                padding: const EdgeInsets.symmetric(
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

  Widget _buildActionButtons() {
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        OutlinedButton.icon(
          onPressed:
              _isProcessing ? null : _chooseAnother,
          icon: const Icon(Icons.refresh),
          label: const Text(
            'Choose Another',
          ),
        ),

        if (_processedImageBytes == null)
          ElevatedButton.icon(
            onPressed:
                _isProcessing ? null : _processImage,
            icon: const Icon(
              Icons.auto_fix_high,
            ),
            label: const Text(
              'Process Answer Sheet',
            ),
          ),

        if (_processedImageBytes != null)
          ElevatedButton.icon(
            onPressed:
                _isProcessing ? null : _runOMR,
            icon: const Icon(
              Icons.document_scanner,
            ),
            label: const Text(
              'Run OMR',
            ),
          ),
      ],
    );
  }
}