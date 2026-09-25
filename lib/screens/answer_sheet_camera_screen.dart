import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../services/answer_sheet_processor.dart';

class AnswerSheetCameraScreen extends StatefulWidget {
  final int examId;

  const AnswerSheetCameraScreen({
    super.key,
    required this.examId,
  });

  @override
  State<AnswerSheetCameraScreen> createState() =>
      _AnswerSheetCameraScreenState();
}

class _AnswerSheetCameraScreenState
    extends State<AnswerSheetCameraScreen> {
  CameraController? _cameraController;

  bool _isInitializing = true;
  bool _isTakingPicture = false;
  bool _isProcessing = false;

  bool _hasError = false;

  String? _errorMessage;

  XFile? _capturedImage;

  Uint8List? _capturedImageBytes;
  Uint8List? _correctedImageBytes;

  List<RegistrationPoint> _detectedMarkers =
      <RegistrationPoint>[];

  FlashMode _flashMode =
      FlashMode.off;

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
      final cameras =
          await availableCameras();

      if (cameras.isEmpty) {
        throw Exception(
          'No camera was found on this device.',
        );
      }

      CameraDescription selectedCamera =
          cameras.first;

      for (final camera in cameras) {
        if (camera.lensDirection ==
            CameraLensDirection.back) {
          selectedCamera = camera;
          break;
        }
      }

      final controller =
          CameraController(
        selectedCamera,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup:
            ImageFormatGroup.jpeg,
      );

      await controller.initialize();

      await controller.setFlashMode(
        _flashMode,
      );

      if (!mounted) {
        await controller.dispose();
        return;
      }

      setState(() {
        _cameraController =
            controller;
        _isInitializing = false;
        _hasError = false;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _isInitializing = false;
        _hasError = true;
        _errorMessage =
            e.toString();
      });
    }
  }

  // ============================================================
  // FLASH
  // ============================================================

  Future<void> _toggleFlash() async {
    final controller =
        _cameraController;

    if (controller == null ||
        !controller.value.isInitialized) {
      return;
    }

    try {
      final FlashMode newFlashMode =
          _flashMode ==
                  FlashMode.off
              ? FlashMode.torch
              : FlashMode.off;

      await controller.setFlashMode(
        newFlashMode,
      );

      if (!mounted) return;

      setState(() {
        _flashMode =
            newFlashMode;
      });
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context)
          .showSnackBar(
        SnackBar(
          content: Text(
            'Unable to change flash: $e',
          ),
        ),
      );
    }
  }

  // ============================================================
  // TAKE PICTURE
  // ============================================================

  Future<void> _takePicture() async {
    final controller =
        _cameraController;

    if (controller == null ||
        !controller.value.isInitialized ||
        _isTakingPicture) {
      return;
    }

    try {
      setState(() {
        _isTakingPicture = true;
      });

      final XFile image =
          await controller.takePicture();

      final Uint8List imageBytes =
          await image.readAsBytes();

      if (!mounted) return;

      setState(() {
        _capturedImage = image;
        _capturedImageBytes =
            imageBytes;
        _correctedImageBytes = null;
        _detectedMarkers =
            <RegistrationPoint>[];
        _isTakingPicture = false;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _isTakingPicture = false;
      });

      ScaffoldMessenger.of(context)
          .showSnackBar(
        SnackBar(
          content: Text(
            'Failed to capture answer sheet: $e',
          ),
        ),
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
      _detectedMarkers =
          <RegistrationPoint>[];
      _isProcessing = false;
    });
  }

  // ============================================================
  // PROCESS IMAGE
  // ============================================================

  Future<void> _continueWithImage() async {
    if (_capturedImageBytes == null ||
        _isProcessing) {
      return;
    }

    setState(() {
      _isProcessing = true;
      _correctedImageBytes = null;
      _detectedMarkers =
          <RegistrationPoint>[];
    });

    try {
      final AnswerSheetProcessingResult
          result =
          await AnswerSheetProcessor
              .processAnswerSheet(
        _capturedImageBytes!,
      );

      if (!mounted) return;

      setState(() {
        _correctedImageBytes =
            result.correctedImageBytes;

        _detectedMarkers =
            result.markers;

        _isProcessing = false;
      });

      ScaffoldMessenger.of(context)
          .showSnackBar(
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
        _detectedMarkers =
            <RegistrationPoint>[];
      });

      ScaffoldMessenger.of(context)
          .showSnackBar(
        SnackBar(
          duration:
              const Duration(seconds: 5),
          content: Text(
            'Answer sheet processing failed:\n$e',
          ),
        ),
      );
    }
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
        foregroundColor:
            Colors.white,
        title: const Text(
          'Scan Answer Sheet',
        ),
        actions: [
          if (!_isInitializing &&
              !_hasError)
            IconButton(
              tooltip:
                  _flashMode ==
                          FlashMode.off
                      ? 'Turn Flash On'
                      : 'Turn Flash Off',
              onPressed:
                  _toggleFlash,
              icon: Icon(
                _flashMode ==
                        FlashMode.off
                    ? Icons.flash_off
                    : Icons.flash_on,
              ),
            ),
        ],
      ),
      body: _isInitializing
          ? const Center(
              child:
                  CircularProgressIndicator(
                color: Colors.white,
              ),
            )
          : _hasError
              ? _buildCameraError()
              : _buildCameraPreview(),
    );
  }

  // ============================================================
  // CAMERA PREVIEW
  // ============================================================

  Widget _buildCameraPreview() {
    final controller =
        _cameraController;

    if (controller == null ||
        !controller.value
            .isInitialized) {
      return _buildCameraError();
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        CameraPreview(
          controller,
        ),

        CustomPaint(
          painter:
              ScannerOverlayPainter(),
        ),

        Positioned(
          top: 20,
          left: 20,
          right: 20,
          child: Container(
            padding:
                const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 12,
            ),
            decoration:
                BoxDecoration(
              color: Colors.black
                  .withValues(
                alpha: 0.65,
              ),
              borderRadius:
                  BorderRadius.circular(
                12,
              ),
            ),
            child: const Column(
              children: [
                Text(
                  'Position the answer sheet inside the frame',
                  textAlign:
                      TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'Make sure all four corners are visible',
                  textAlign:
                      TextAlign.center,
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                  ),
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
            padding:
                const EdgeInsets.only(
              top: 18,
              bottom: 28,
            ),
            decoration:
                BoxDecoration(
              gradient:
                  LinearGradient(
                begin:
                    Alignment.topCenter,
                end:
                    Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  Colors.black.withValues(
                    alpha: 0.9,
                  ),
                ],
              ),
            ),
            child: Column(
              children: [
                const Text(
                  'Keep the sheet flat and well lit',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(
                  height: 14,
                ),

                GestureDetector(
                  onTap:
                      _isTakingPicture
                          ? null
                          : _takePicture,
                  child: Container(
                    width: 78,
                    height: 78,
                    decoration:
                        BoxDecoration(
                      shape:
                          BoxShape.circle,
                      color:
                          Colors.white,
                      border:
                          Border.all(
                        color:
                            Colors.white,
                        width: 5,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black
                              .withValues(
                            alpha: 0.4,
                          ),
                          blurRadius: 8,
                        ),
                      ],
                    ),
                    child:
                        _isTakingPicture
                            ? const Padding(
                                padding:
                                    EdgeInsets.all(
                                  20,
                                ),
                                child:
                                    CircularProgressIndicator(),
                              )
                            : const Icon(
                                Icons
                                    .camera_alt,
                                color:
                                    Colors.black,
                                size: 32,
                              ),
                  ),
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
        padding:
            const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment:
              MainAxisAlignment.center,
          children: [
            const Icon(
              Icons
                  .no_photography_outlined,
              color: Colors.white,
              size: 70,
            ),
            const SizedBox(
              height: 20,
            ),
            const Text(
              'Camera unavailable',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight:
                    FontWeight.bold,
              ),
            ),
            const SizedBox(
              height: 10,
            ),
            Text(
              _errorMessage ??
                  'Unable to access the camera.',
              textAlign:
                  TextAlign.center,
              style:
                  const TextStyle(
                color:
                    Colors.white70,
              ),
            ),
            const SizedBox(
              height: 24,
            ),
            ElevatedButton.icon(
              onPressed: () {
                setState(() {
                  _isInitializing =
                      true;
                  _hasError = false;
                  _errorMessage =
                      null;
                });

                _initializeCamera();
              },
              icon: const Icon(
                Icons.refresh,
              ),
              label: const Text(
                'Try Again',
              ),
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
    final bool hasCorrectedImage =
        _correctedImageBytes != null;

    return Scaffold(
      backgroundColor:
          Colors.black,
      appBar: AppBar(
        backgroundColor:
            Colors.black,
        foregroundColor:
            Colors.white,
        title: Text(
          hasCorrectedImage
              ? 'Processed Answer Sheet'
              : 'Review Answer Sheet',
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child:
                  _capturedImageBytes !=
                              null
                      ? Image.memory(
                          hasCorrectedImage
                              ? _correctedImageBytes!
                              : _capturedImageBytes!,
                          fit:
                              BoxFit.contain,
                        )
                      : const SizedBox(),
            ),
          ),

          if (_isProcessing)
            const Padding(
              padding:
                  EdgeInsets.symmetric(
                vertical: 12,
              ),
              child: Row(
                mainAxisAlignment:
                    MainAxisAlignment
                        .center,
                children: [
                  SizedBox(
                    width: 20,
                    height: 20,
                    child:
                        CircularProgressIndicator(
                      color:
                          Colors.white,
                      strokeWidth: 2,
                    ),
                  ),
                  SizedBox(
                    width: 10,
                  ),
                  Text(
                    'Detecting registration markers...',
                    style: TextStyle(
                      color:
                          Colors.white,
                    ),
                  ),
                ],
              ),
            ),

          if (hasCorrectedImage)
            Container(
              width: double.infinity,
              margin:
                  const EdgeInsets.symmetric(
                horizontal: 20,
                vertical: 8,
              ),
              padding:
                  const EdgeInsets.all(
                12,
              ),
              decoration:
                  BoxDecoration(
                borderRadius:
                    BorderRadius.circular(
                  10,
                ),
                border: Border.all(
                  color: Colors.white24,
                ),
              ),
              child: Column(
                children: [
                  const Icon(
                    Icons
                        .check_circle_outline,
                    color: Colors.white,
                    size: 28,
                  ),
                  const SizedBox(
                    height: 6,
                  ),
                  const Text(
                    'Perspective correction complete',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight:
                          FontWeight.bold,
                    ),
                  ),
                  const SizedBox(
                    height: 4,
                  ),
                  Text(
                    'Detected ${_detectedMarkers.length} registration markers.',
                    style:
                        const TextStyle(
                      color:
                          Colors.white70,
                    ),
                  ),
                ],
              ),
            ),

          Container(
            padding:
                const EdgeInsets.all(
              20,
            ),
            decoration:
                BoxDecoration(
              color: Colors.black,
              border: Border(
                top: BorderSide(
                  color: Colors.white
                      .withValues(
                    alpha: 0.15,
                  ),
                ),
              ),
            ),
            child: SafeArea(
              top: false,
              child: Row(
                children: [
                  Expanded(
                    child:
                        OutlinedButton.icon(
                      onPressed:
                          _isProcessing
                              ? null
                              : _retakePicture,
                      icon: const Icon(
                        Icons.refresh,
                      ),
                      label: Text(
                        hasCorrectedImage
                            ? 'Retake'
                            : 'Retake',
                      ),
                      style:
                          OutlinedButton
                              .styleFrom(
                        foregroundColor:
                            Colors.white,
                        side:
                            const BorderSide(
                          color:
                              Colors.white,
                        ),
                        padding:
                            const EdgeInsets
                                .symmetric(
                          vertical: 15,
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(
                    width: 12,
                  ),

                  Expanded(
                    child:
                        ElevatedButton.icon(
                      onPressed:
                          _isProcessing
                              ? null
                              : _continueWithImage,
                      icon: _isProcessing
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child:
                                  CircularProgressIndicator(
                                strokeWidth:
                                    2,
                              ),
                            )
                          : Icon(
                              hasCorrectedImage
                                  ? Icons
                                      .refresh
                                  : Icons
                                      .check,
                            ),
                      label: Text(
                        _isProcessing
                            ? 'Processing...'
                            : hasCorrectedImage
                                ? 'Process Again'
                                : 'Process Sheet',
                      ),
                      style:
                          ElevatedButton
                              .styleFrom(
                        padding:
                            const EdgeInsets
                                .symmetric(
                          vertical: 15,
                        ),
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

// ============================================================
// SCANNER OVERLAY PAINTER
// ============================================================

class ScannerOverlayPainter
    extends CustomPainter {
  @override
  void paint(
    Canvas canvas,
    Size size,
  ) {
    const double answerSheetRatio =
        0.705;

    final double frameWidth =
        size.width * 0.82;

    final double frameHeight =
        frameWidth /
            answerSheetRatio;

    final double left =
        (size.width - frameWidth) /
            2;

    final double top =
        (size.height - frameHeight) /
            2;

    final Rect frame =
        Rect.fromLTWH(
      left,
      top,
      frameWidth,
      frameHeight,
    );

    // ----------------------------------------------------------
    // DARK OVERLAY
    // ----------------------------------------------------------

    final Paint overlayPaint =
        Paint()
          ..color =
              Colors.black.withValues(
            alpha: 0.55,
          );

    final Path outsidePath =
        Path()
          ..addRect(
            Rect.fromLTWH(
              0,
              0,
              size.width,
              size.height,
            ),
          );

    final Path framePath =
        Path()..addRect(frame);

    final Path overlayPath =
        Path.combine(
      PathOperation.difference,
      outsidePath,
      framePath,
    );

    canvas.drawPath(
      overlayPath,
      overlayPaint,
    );

    // ----------------------------------------------------------
    // FRAME
    // ----------------------------------------------------------

    final Paint framePaint =
        Paint()
          ..color = Colors.white
          ..style =
              PaintingStyle.stroke
          ..strokeWidth = 3;

    canvas.drawRect(
      frame,
      framePaint,
    );

    // ----------------------------------------------------------
    // CORNER GUIDES
    // ----------------------------------------------------------

    final Paint cornerPaint =
        Paint()
          ..color = Colors.white
          ..style =
              PaintingStyle.stroke
          ..strokeWidth = 5
          ..strokeCap =
              StrokeCap.round;

    const double cornerLength = 28;

    // TOP LEFT

    canvas.drawLine(
      Offset(
        frame.left,
        frame.top,
      ),
      Offset(
        frame.left +
            cornerLength,
        frame.top,
      ),
      cornerPaint,
    );

    canvas.drawLine(
      Offset(
        frame.left,
        frame.top,
      ),
      Offset(
        frame.left,
        frame.top +
            cornerLength,
      ),
      cornerPaint,
    );

    // TOP RIGHT

    canvas.drawLine(
      Offset(
        frame.right,
        frame.top,
      ),
      Offset(
        frame.right -
            cornerLength,
        frame.top,
      ),
      cornerPaint,
    );

    canvas.drawLine(
      Offset(
        frame.right,
        frame.top,
      ),
      Offset(
        frame.right,
        frame.top +
            cornerLength,
      ),
      cornerPaint,
    );

    // BOTTOM LEFT

    canvas.drawLine(
      Offset(
        frame.left,
        frame.bottom,
      ),
      Offset(
        frame.left +
            cornerLength,
        frame.bottom,
      ),
      cornerPaint,
    );

    canvas.drawLine(
      Offset(
        frame.left,
        frame.bottom,
      ),
      Offset(
        frame.left,
        frame.bottom -
            cornerLength,
      ),
      cornerPaint,
    );

    // BOTTOM RIGHT

    canvas.drawLine(
      Offset(
        frame.right,
        frame.bottom,
      ),
      Offset(
        frame.right -
            cornerLength,
        frame.bottom,
      ),
      cornerPaint,
    );

    canvas.drawLine(
      Offset(
        frame.right,
        frame.bottom,
      ),
      Offset(
        frame.right,
        frame.bottom -
            cornerLength,
      ),
      cornerPaint,
    );
  }

  @override
  bool shouldRepaint(
    covariant CustomPainter
        oldDelegate,
  ) {
    return false;
  }
}
