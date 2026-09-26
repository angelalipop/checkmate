import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'package:checkmate/services/answer_sheet_processor.dart';
import 'package:checkmate/services/opencv_test_service.dart';
import 'package:checkmate/services/opencv_omr_service.dart';

class AnswerSheetCameraScreen extends StatefulWidget {
  final int examId;
  final List<Map<String, dynamic>> sections;

  const AnswerSheetCameraScreen({
    super.key,
    required this.examId,
    required this.sections,
  });

  @override
  State<AnswerSheetCameraScreen> createState() =>
      _AnswerSheetCameraScreenState();
}

class _AnswerSheetCameraScreenState extends State<AnswerSheetCameraScreen> {
  CameraController? _cameraController;

  bool _isInitializing = true;
  bool _isTakingPicture = false;
  bool _isProcessing = false;

  bool _hasError = false;

  String? _errorMessage;

  XFile? _capturedImage;

  Uint8List? _capturedImageBytes;
  Uint8List? _correctedImageBytes;
  Uint8List? _openCVThresholdImageBytes;
  OpenCVOMRResult? _openCVOmrResult;
  bool _showThresholdPreview = false;
  bool _showOmrDebugPreview = false;

  List<RegistrationPoint> _detectedMarkers = <RegistrationPoint>[];

  FlashMode _flashMode = FlashMode.off;

  // ============================================================
  // INITIALIZE CAMERA
  // ============================================================

  @override
  void initState() {
    super.initState();
    _initializeCamera();
  }

  Future<void> _initializeCamera() async {
    try {
      final cameras = await availableCameras();

      if (cameras.isEmpty) {
        throw Exception('No camera was found on this device.');
      }

      CameraDescription selectedCamera = cameras.first;

      for (final camera in cameras) {
        if (camera.lensDirection == CameraLensDirection.back) {
          selectedCamera = camera;
          break;
        }
      }

      final controller = CameraController(
        selectedCamera,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );

      await controller.initialize();

      await controller.setFlashMode(_flashMode);

      if (!mounted) {
        await controller.dispose();
        return;
      }

      setState(() {
        _cameraController = controller;
        _isInitializing = false;
        _hasError = false;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _isInitializing = false;
        _hasError = true;
        _errorMessage = e.toString();
      });
    }
  }

  // ============================================================
  // FLASH
  // ============================================================

  Future<void> _toggleFlash() async {
    final controller = _cameraController;

    if (controller == null || !controller.value.isInitialized) {
      return;
    }

    try {
      final FlashMode newFlashMode = _flashMode == FlashMode.off
          ? FlashMode.torch
          : FlashMode.off;

      await controller.setFlashMode(newFlashMode);

      if (!mounted) return;

      setState(() {
        _flashMode = newFlashMode;
      });
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Unable to change flash: $e')));
    }
  }

  // ============================================================
  // CHOOSE FROM GALLERY
  // ============================================================

  Future<void> _chooseFromGallery() async {
    try {
      const XTypeGroup imageTypeGroup = XTypeGroup(
        label: 'Images',
        uniformTypeIdentifiers: <String>[
          'public.jpeg',
          'public.png',
          'public.image',
        ],
      );

      final XFile? image = await openFile(
        acceptedTypeGroups: <XTypeGroup>[imageTypeGroup],
      );

      if (image == null) {
        return;
      }

      final Uint8List imageBytes = await image.readAsBytes();

      if (!mounted) {
        return;
      }

      setState(() {
        _capturedImage = image;
        _capturedImageBytes = imageBytes;

        // Reset previous processing results.
        _correctedImageBytes = null;
        _openCVThresholdImageBytes = null;
        _openCVOmrResult = null;
        _showThresholdPreview = false;
        _showOmrDebugPreview = false;
        _detectedMarkers = <RegistrationPoint>[];
        _isProcessing = false;
      });
    } catch (e) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 5),
          content: Text('Unable to choose image:\n$e'),
        ),
      );
    }
  }

  // ============================================================
  // TAKE PICTURE
  // ============================================================

  Future<void> _takePicture() async {
    final controller = _cameraController;

    if (controller == null ||
        !controller.value.isInitialized ||
        _isTakingPicture) {
      return;
    }

    try {
      setState(() {
        _isTakingPicture = true;
      });

      final XFile image = await controller.takePicture();

      final Uint8List imageBytes = await image.readAsBytes();

      if (!mounted) return;

      setState(() {
        _capturedImage = image;
        _capturedImageBytes = imageBytes;
        _correctedImageBytes = null;
        _openCVThresholdImageBytes = null;
        _openCVOmrResult = null;
        _showThresholdPreview = false;
        _showOmrDebugPreview = false;
        _detectedMarkers = <RegistrationPoint>[];
        _isTakingPicture = false;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _isTakingPicture = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to capture answer sheet: $e')),
      );
    }
  }

  // ============================================================
  // RETAKE
  // ============================================================

  void _retakePicture() {
    setState(() {
      _capturedImage = null;
      _capturedImageBytes = null;
      _correctedImageBytes = null;
      _openCVThresholdImageBytes = null;
      _openCVOmrResult = null;
      _showThresholdPreview = false;
      _showOmrDebugPreview = false;
      _detectedMarkers = <RegistrationPoint>[];
      _isProcessing = false;
    });
  }

  // ============================================================
  // PROCESS IMAGE
  // ============================================================

  Future<void> _continueWithImage() async {
    if (_capturedImageBytes == null || _isProcessing) {
      return;
    }

    setState(() {
      _isProcessing = true;
      _correctedImageBytes = null;
      _openCVThresholdImageBytes = null;
      _openCVOmrResult = null;
      _showThresholdPreview = false;
      _showOmrDebugPreview = false;
      _detectedMarkers = <RegistrationPoint>[];
    });

    try {
      final AnswerSheetProcessingResult result =
          await AnswerSheetProcessor.processAnswerSheet(_capturedImageBytes!);

      final Uint8List? thresholdImage =
          await OpenCVTestService.adaptiveThreshold(
        result.correctedImageBytes,
      );

      final OpenCVOMRResult omrResult = await OpenCVOMRService.process(
        result.correctedImageBytes,
        sections: widget.sections,
      );

      if (!mounted) return;

      setState(() {
        _correctedImageBytes = result.correctedImageBytes;
        _openCVThresholdImageBytes = thresholdImage;
        _openCVOmrResult = omrResult;
        _showThresholdPreview = thresholdImage != null;
        _showOmrDebugPreview = false;
        _detectedMarkers = result.markers;
        _isProcessing = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Four registration markers detected and perspective corrected.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _isProcessing = false;
        _correctedImageBytes = null;
        _openCVThresholdImageBytes = null;
        _openCVOmrResult = null;
        _showThresholdPreview = false;
        _showOmrDebugPreview = false;
        _detectedMarkers = <RegistrationPoint>[];
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 5),
          content: Text('Answer sheet processing failed:\n$e'),
        ),
      );
    }
  }

  Uint8List? _currentPreviewBytes() {
    final bool hasCorrectedImage = _correctedImageBytes != null;

    if (hasCorrectedImage &&
        _showOmrDebugPreview &&
        _openCVOmrResult?.debugImageBytes != null) {
      return _openCVOmrResult!.debugImageBytes;
    }

    if (hasCorrectedImage &&
        _showThresholdPreview &&
        _openCVThresholdImageBytes != null) {
      return _openCVThresholdImageBytes;
    }

    if (hasCorrectedImage) {
      return _correctedImageBytes;
    }

    return _capturedImageBytes;
  }

  void _openFullscreenPreview() {
    final Uint8List? imageBytes = _currentPreviewBytes();
    if (imageBytes == null) return;

    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => _FullscreenImagePreview(
          imageBytes: imageBytes,
          title: _showOmrDebugPreview
              ? 'OMR Debug Overlay'
              : _showThresholdPreview
              ? 'OpenCV Threshold'
              : 'Corrected Answer Sheet',
        ),
      ),
    );
  }

  // ============================================================
  // OMR ANSWER CLASSIFICATION
  // ============================================================

  /// Classifies one MC/TF row without changing the OpenCV measurement logic.
  ///
  /// The classifier intentionally uses BOTH an absolute darkness check and
  /// the gap between the strongest and second-strongest bubble. This keeps a
  /// blank row from becoming an answer just because one printed bubble outline
  /// happens to be slightly darker than its neighbours.
  _OMRAnswerClassification _classifyQuestion(dynamic question) {
    final bubbles = List<dynamic>.from(question.bubbles);

    if (bubbles.isEmpty) {
      return const _OMRAnswerClassification(
        status: _OMRAnswerStatus.blank,
        labels: <String>[],
        strongest: 0,
        secondStrongest: 0,
      );
    }

    final sorted = List<dynamic>.from(bubbles)
      ..sort(
        (a, b) => (b.fillRatio as double).compareTo(a.fillRatio as double),
      );

    final double strongest = sorted.first.fillRatio as double;
    final double secondStrongest = sorted.length > 1
        ? sorted[1].fillRatio as double
        : 0.0;
    final double gap = strongest - secondStrongest;

    // These are deliberately conservative starting values based on the
    // current CheckMate sheet measurements. They can be tuned later after
    // testing more blank and answered sheets under different lighting.
    const double clearMarkMinimum = 0.52;
    const double possibleMarkMinimum = 0.46;
    const double clearWinnerGap = 0.12;
    const double ambiguousWinnerGap = 0.07;
    const double multipleMarkMinimum = 0.52;
    const double multiplePairGap = 0.10;

    final strongBubbles = bubbles
        .where((bubble) => (bubble.fillRatio as double) >= multipleMarkMinimum)
        .toList();

    if (strongBubbles.length >= 2) {
      strongBubbles.sort(
        (a, b) => (b.fillRatio as double).compareTo(a.fillRatio as double),
      );

      final double first = strongBubbles[0].fillRatio as double;
      final double second = strongBubbles[1].fillRatio as double;

      if ((first - second).abs() <= multiplePairGap) {
        return _OMRAnswerClassification(
          status: _OMRAnswerStatus.multiple,
          labels: strongBubbles
              .map<String>((bubble) => bubble.label.toString())
              .toList(),
          strongest: strongest,
          secondStrongest: secondStrongest,
        );
      }
    }

    if (strongest >= clearMarkMinimum && gap >= clearWinnerGap) {
      return _OMRAnswerClassification(
        status: _OMRAnswerStatus.answered,
        labels: <String>[sorted.first.label.toString()],
        strongest: strongest,
        secondStrongest: secondStrongest,
      );
    }

    // A reasonably dark bubble with a smaller-than-normal lead is not trusted
    // automatically. It is surfaced for manual verification instead.
    if (strongest >= possibleMarkMinimum && gap >= ambiguousWinnerGap) {
      return _OMRAnswerClassification(
        status: _OMRAnswerStatus.ambiguous,
        labels: <String>[sorted.first.label.toString()],
        strongest: strongest,
        secondStrongest: secondStrongest,
      );
    }

    // If the strongest bubble is dark but has almost no separation from the
    // runner-up, treat the row as ambiguous rather than guessing.
    if (strongest >= clearMarkMinimum) {
      return _OMRAnswerClassification(
        status: _OMRAnswerStatus.ambiguous,
        labels: <String>[sorted.first.label.toString()],
        strongest: strongest,
        secondStrongest: secondStrongest,
      );
    }

    return _OMRAnswerClassification(
      status: _OMRAnswerStatus.blank,
      labels: const <String>[],
      strongest: strongest,
      secondStrongest: secondStrongest,
    );
  }

  Widget _buildClassificationBadge(_OMRAnswerClassification result) {
    final IconData icon;
    final String text;
    final Color color;

    switch (result.status) {
      case _OMRAnswerStatus.answered:
        icon = Icons.check_circle_outline;
        text = result.labels.first;
        color = Colors.greenAccent;
        break;
      case _OMRAnswerStatus.blank:
        icon = Icons.remove_circle_outline;
        text = 'Blank';
        color = Colors.white60;
        break;
      case _OMRAnswerStatus.multiple:
        icon = Icons.warning_amber_rounded;
        text = 'Multiple: ${result.labels.join(', ')}';
        color = Colors.orangeAccent;
        break;
      case _OMRAnswerStatus.ambiguous:
        icon = Icons.help_outline;
        text = result.labels.isEmpty
            ? 'Ambiguous'
            : 'Ambiguous: ${result.labels.first}';
        color = Colors.amberAccent;
        break;
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 5),
        Flexible(
          child: Text(
            text,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w600,
              fontSize: 12,
            ),
          ),
        ),
      ],
    );
  }

  // ============================================================
  // DISPOSE
  // ============================================================

  @override
  void dispose() {
    _cameraController?.dispose();
    super.dispose();
  }

  // ============================================================
  // BUILD
  // ============================================================

  @override
  Widget build(BuildContext context) {
    if (_capturedImageBytes != null) {
      return _buildPreviewScreen();
    }

    return _buildCameraScreen();
  }

  // ============================================================
  // CAMERA SCREEN
  // ============================================================

  Widget _buildCameraScreen() {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Scan Answer Sheet'),
        actions: [
          if (!_isInitializing && !_hasError)
            IconButton(
              tooltip: _flashMode == FlashMode.off
                  ? 'Turn Flash On'
                  : 'Turn Flash Off',
              onPressed: _toggleFlash,
              icon: Icon(
                _flashMode == FlashMode.off ? Icons.flash_off : Icons.flash_on,
              ),
            ),
        ],
      ),
      body: _isInitializing
          ? const Center(child: CircularProgressIndicator(color: Colors.white))
          : _hasError
          ? _buildCameraError()
          : _buildCameraPreview(),
    );
  }

  // ============================================================
  // CAMERA PREVIEW
  // ============================================================

  Widget _buildCameraPreview() {
    final controller = _cameraController;

    if (controller == null || !controller.value.isInitialized) {
      return _buildCameraError();
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        CameraPreview(controller),

        CustomPaint(painter: ScannerOverlayPainter()),

        Positioned(
          top: 20,
          left: 20,
          right: 20,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.65),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Column(
              children: [
                Text(
                  'Position the answer sheet inside the frame',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'Make sure all four corners are visible',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ],
            ),
          ),
        ),

        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Container(
            padding: const EdgeInsets.only(top: 18, bottom: 28),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  Colors.black.withValues(alpha: 0.9),
                ],
              ),
            ),
            child: Column(
              children: [
                const Text(
                  'Keep the sheet flat and well lit',
                  style: TextStyle(color: Colors.white, fontSize: 13),
                ),
                const SizedBox(height: 14),

                GestureDetector(
                  onTap: _isTakingPicture ? null : _takePicture,
                  child: Container(
                    width: 78,
                    height: 78,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white,
                      border: Border.all(color: Colors.white, width: 5),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.4),
                          blurRadius: 8,
                        ),
                      ],
                    ),
                    child: _isTakingPicture
                        ? const Padding(
                            padding: EdgeInsets.all(20),
                            child: CircularProgressIndicator(),
                          )
                        : const Icon(
                            Icons.camera_alt,
                            color: Colors.black,
                            size: 32,
                          ),
                  ),
                ),
                const SizedBox(height: 12),
                TextButton.icon(
                  onPressed: _isTakingPicture ? null : _chooseFromGallery,
                  icon: const Icon(Icons.photo_library_outlined),
                  label: const Text('Choose From Gallery'),
                  style: TextButton.styleFrom(foregroundColor: Colors.white),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ============================================================
  // CAMERA ERROR
  // ============================================================

  Widget _buildCameraError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.no_photography_outlined,
              color: Colors.white,
              size: 70,
            ),
            const SizedBox(height: 20),
            const Text(
              'Camera unavailable',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              _errorMessage ?? 'Unable to access the camera.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () {
                setState(() {
                  _isInitializing = true;
                  _hasError = false;
                  _errorMessage = null;
                });

                _initializeCamera();
              },
              icon: const Icon(Icons.refresh),
              label: const Text('Try Again'),
            ),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // IMAGE PREVIEW / CORRECTED IMAGE
  // ============================================================

  Widget _buildPreviewScreen() {
    final bool hasCorrectedImage = _correctedImageBytes != null;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          hasCorrectedImage ? 'Processed Answer Sheet' : 'Review Answer Sheet',
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: _capturedImageBytes != null
                  ? GestureDetector(
                      onTap: _openFullscreenPreview,
                      child: Stack(
                        alignment: Alignment.bottomCenter,
                        children: [
                          Image.memory(
                            _currentPreviewBytes()!,
                            fit: BoxFit.contain,
                          ),
                          Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.70),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.zoom_in,
                                  color: Colors.white,
                                  size: 18,
                                ),
                                SizedBox(width: 6),
                                Text(
                                  'Tap to zoom',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    )
                  : const SizedBox(),
            ),
          ),

          if (_isProcessing)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 2,
                    ),
                  ),
                  SizedBox(width: 10),
                  Text(
                    'Detecting registration markers...',
                    style: TextStyle(color: Colors.white),
                  ),
                ],
              ),
            ),

          if (hasCorrectedImage)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white24),
              ),
              child: Column(
                children: [
                  const Icon(
                    Icons.check_circle_outline,
                    color: Colors.white,
                    size: 28,
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Perspective correction complete',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Detected ${_detectedMarkers.length} registration markers.',
                    style: const TextStyle(color: Colors.white70),
                  ),
                  if (_openCVThresholdImageBytes != null ||
                      _openCVOmrResult?.debugImageBytes != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      _showOmrDebugPreview
                          ? 'Showing OMR debug overlay'
                          : _showThresholdPreview
                          ? 'Showing OpenCV threshold preview'
                          : 'Showing corrected answer sheet',
                      style: const TextStyle(color: Colors.white70),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (_openCVThresholdImageBytes != null)
                          OutlinedButton.icon(
                            onPressed: () {
                              setState(() {
                                if (_showThresholdPreview ||
                                    _showOmrDebugPreview) {
                                  _showThresholdPreview = false;
                                  _showOmrDebugPreview = false;
                                } else {
                                  _showThresholdPreview = true;
                                  _showOmrDebugPreview = false;
                                }
                              });
                            },
                            icon: Icon(
                              _showThresholdPreview && !_showOmrDebugPreview
                                  ? Icons.image_outlined
                                  : Icons.contrast,
                            ),
                            label: Text(
                              _showThresholdPreview && !_showOmrDebugPreview
                                  ? 'View Corrected Image'
                                  : 'View OpenCV Threshold',
                            ),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.white,
                              side: const BorderSide(color: Colors.white54),
                            ),
                          ),
                        if (_openCVOmrResult?.debugImageBytes != null)
                          OutlinedButton.icon(
                            onPressed: () {
                              setState(() {
                                _showOmrDebugPreview = true;
                                _showThresholdPreview = false;
                              });
                            },
                            icon: const Icon(Icons.center_focus_strong),
                            label: const Text('View OMR Debug Overlay'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.white,
                              side: const BorderSide(color: Colors.white54),
                            ),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),

          if (hasCorrectedImage && _openCVOmrResult != null)
            Container(
              constraints: const BoxConstraints(maxHeight: 220),
              margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white24),
              ),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'OMR Answer Detection',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    ..._openCVOmrResult!.sections.map((section) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              section.sectionName,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (section.sectionType == 'identification')
                              const Text(
                                'Identification: OCR pending',
                                style: TextStyle(color: Colors.white70),
                              )
                            else
                              ...section.questions.map((question) {
                                final values = question.bubbles
                                    .map(
                                      (bubble) =>
                                          '${bubble.label}:${bubble.fillRatio.toStringAsFixed(3)}',
                                    )
                                    .join('  ');
                                final classification =
                                    _classifyQuestion(question);

                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          SizedBox(
                                            width: 38,
                                            child: Text(
                                              'Q${question.questionNumber}',
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontWeight: FontWeight.w600,
                                                fontSize: 12,
                                              ),
                                            ),
                                          ),
                                          Expanded(
                                            child: _buildClassificationBadge(
                                              classification,
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        values,
                                        style: const TextStyle(
                                          color: Colors.white54,
                                          fontFamily: 'monospace',
                                          fontSize: 11,
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              }),
                          ],
                        ),
                      );
                    }),
                  ],
                ),
              ),
            ),

          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.black,
              border: Border(
                top: BorderSide(color: Colors.white.withValues(alpha: 0.15)),
              ),
            ),
            child: SafeArea(
              top: false,
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _isProcessing ? null : _retakePicture,
                      icon: const Icon(Icons.refresh),
                      label: Text(hasCorrectedImage ? 'Retake' : 'Retake'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Colors.white),
                        padding: const EdgeInsets.symmetric(vertical: 15),
                      ),
                    ),
                  ),

                  const SizedBox(width: 12),

                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _isProcessing ? null : _continueWithImage,
                      icon: _isProcessing
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(
                              hasCorrectedImage ? Icons.refresh : Icons.check,
                            ),
                      label: Text(
                        _isProcessing
                            ? 'Processing...'
                            : hasCorrectedImage
                            ? 'Process Again'
                            : 'Process Sheet',
                      ),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 15),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

enum _OMRAnswerStatus { answered, blank, multiple, ambiguous }

class _OMRAnswerClassification {
  final _OMRAnswerStatus status;
  final List<String> labels;
  final double strongest;
  final double secondStrongest;

  const _OMRAnswerClassification({
    required this.status,
    required this.labels,
    required this.strongest,
    required this.secondStrongest,
  });
}

class _FullscreenImagePreview extends StatelessWidget {
  final Uint8List imageBytes;
  final String title;

  const _FullscreenImagePreview({
    required this.imageBytes,
    required this.title,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(title),
      ),
      body: SafeArea(
        child: InteractiveViewer(
          minScale: 0.5,
          maxScale: 8.0,
          boundaryMargin: const EdgeInsets.all(120),
          child: Center(child: Image.memory(imageBytes, fit: BoxFit.contain)),
        ),
      ),
    );
  }
}

// ============================================================
// SCANNER OVERLAY PAINTER
// ============================================================

class ScannerOverlayPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    const double answerSheetRatio = 0.705;

    final double frameWidth = size.width * 0.82;

    final double frameHeight = frameWidth / answerSheetRatio;

    final double left = (size.width - frameWidth) / 2;

    final double top = (size.height - frameHeight) / 2;

    final Rect frame = Rect.fromLTWH(left, top, frameWidth, frameHeight);

    // ----------------------------------------------------------
    // DARK OVERLAY
    // ----------------------------------------------------------

    final Paint overlayPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.55);

    final Path outsidePath = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height));

    final Path framePath = Path()..addRect(frame);

    final Path overlayPath = Path.combine(
      PathOperation.difference,
      outsidePath,
      framePath,
    );

    canvas.drawPath(overlayPath, overlayPaint);

    // ----------------------------------------------------------
    // FRAME
    // ----------------------------------------------------------

    final Paint framePaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;

    canvas.drawRect(frame, framePaint);

    // ----------------------------------------------------------
    // CORNER GUIDES
    // ----------------------------------------------------------

    final Paint cornerPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round;

    const double cornerLength = 28;

    // TOP LEFT

    canvas.drawLine(
      Offset(frame.left, frame.top),
      Offset(frame.left + cornerLength, frame.top),
      cornerPaint,
    );

    canvas.drawLine(
      Offset(frame.left, frame.top),
      Offset(frame.left, frame.top + cornerLength),
      cornerPaint,
    );

    // TOP RIGHT

    canvas.drawLine(
      Offset(frame.right, frame.top),
      Offset(frame.right - cornerLength, frame.top),
      cornerPaint,
    );

    canvas.drawLine(
      Offset(frame.right, frame.top),
      Offset(frame.right, frame.top + cornerLength),
      cornerPaint,
    );

    // BOTTOM LEFT

    canvas.drawLine(
      Offset(frame.left, frame.bottom),
      Offset(frame.left + cornerLength, frame.bottom),
      cornerPaint,
    );

    canvas.drawLine(
      Offset(frame.left, frame.bottom),
      Offset(frame.left, frame.bottom - cornerLength),
      cornerPaint,
    );

    // BOTTOM RIGHT

    canvas.drawLine(
      Offset(frame.right, frame.bottom),
      Offset(frame.right - cornerLength, frame.bottom),
      cornerPaint,
    );

    canvas.drawLine(
      Offset(frame.right, frame.bottom),
      Offset(frame.right, frame.bottom - cornerLength),
      cornerPaint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return false;
  }
}