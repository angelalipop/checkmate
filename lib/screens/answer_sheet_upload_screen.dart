import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

class AnswerSheetUploadScreen extends StatefulWidget {
  final int examId;

  const AnswerSheetUploadScreen({
    super.key,
    required this.examId,
  });

  @override
  State<AnswerSheetUploadScreen> createState() =>
      _AnswerSheetUploadScreenState();
}

class _AnswerSheetUploadScreenState
    extends State<AnswerSheetUploadScreen> {
  Uint8List? _imageBytes;
  String? _fileName;
  bool _isProcessing = false;

  Future<void> _pickAnswerSheet() async {
    try {
      const XTypeGroup typeGroup = XTypeGroup(
        label: 'Answer Sheets',
        extensions: <String>[
          'jpg',
          'jpeg',
          'png',
        ],
        mimeTypes: <String>[
          'image/jpeg',
          'image/png',
        ],
      );

      final XFile? file = await openFile(
        acceptedTypeGroups: <XTypeGroup>[
          typeGroup,
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
        _fileName = file.name;
      });
    } catch (e) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Unable to upload answer sheet: $e',
          ),
        ),
      );
    }
  }

  void _removeImage() {
    setState(() {
      _imageBytes = null;
      _fileName = null;
    });
  }

  Future<void> _continueWithImage() async {
    if (_imageBytes == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Please upload an answer sheet first.',
          ),
        ),
      );
      return;
    }

    setState(() {
      _isProcessing = true;
    });

    // TODO:
    // Send _imageBytes to the CheckMate answer-sheet
    // processing pipeline.
    //
    // Future processing steps:
    // 1. Detect registration/alignment markers
    // 2. Correct perspective
    // 3. Normalize the image
    // 4. Detect MC/T/F answers using OMR
    // 5. Perform OCR for identification answers
    // 6. Send uncertain answers for manual verification
    // 7. Calculate the student's score
    // 8. Save the attempt and result

    await Future.delayed(
      const Duration(milliseconds: 500),
    );

    if (!mounted) {
      return;
    }

    setState(() {
      _isProcessing = false;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Answer sheet uploaded successfully. '
          'Processing will be added next.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Upload Answer Sheet'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: 700,
            ),
            child: _imageBytes == null
                ? _buildUploadView()
                : _buildPreviewView(),
          ),
        ),
      ),
    );
  }

  Widget _buildUploadView() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(
          Icons.cloud_upload_outlined,
          size: 80,
        ),
        const SizedBox(height: 20),
        Text(
          'Upload Answer Sheet',
          style: Theme.of(context)
              .textTheme
              .headlineSmall
              ?.copyWith(
                fontWeight: FontWeight.bold,
              ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Select a clear image of the completed answer sheet.',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 30),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _pickAnswerSheet,
            icon: const Icon(
              Icons.upload_file,
              size: 28,
            ),
            label: const Text(
              'Choose Answer Sheet',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(
                vertical: 18,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        const Text(
          'Supported formats: JPG, JPEG, PNG',
          style: TextStyle(
            fontSize: 12,
          ),
        ),
      ],
    );
  }

  Widget _buildPreviewView() {
    return Column(
      children: [
        Expanded(
          child: Container(
            width: double.infinity,
            decoration: BoxDecoration(
              border: Border.all(
                color: Theme.of(context).dividerColor,
              ),
              borderRadius: BorderRadius.circular(12),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.memory(
                _imageBytes!,
                fit: BoxFit.contain,
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (_fileName != null)
          Text(
            _fileName!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
            ),
          ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed:
                    _isProcessing ? null : _removeImage,
                icon: const Icon(
                  Icons.refresh,
                ),
                label: const Text(
                  'Choose Another',
                ),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    vertical: 15,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton.icon(
                onPressed:
                    _isProcessing ? null : _continueWithImage,
                icon: _isProcessing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                        ),
                      )
                    : const Icon(
                        Icons.check,
                      ),
                label: Text(
                  _isProcessing
                      ? 'Processing...'
                      : 'Continue',
                ),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    vertical: 15,
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}