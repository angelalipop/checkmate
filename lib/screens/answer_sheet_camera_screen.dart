
import 'dart:typed_data';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:camera/camera.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:checkmate/services/answer_sheet_processor.dart';

import 'package:checkmate/screens/answer_sheet_upload_screen.dart';
import 'package:checkmate/services/answer_sheet_processor.dart';

const Color _kNavy = Color(0xFF1E293B);
const Color _kNavyDark = Color(0xFF162137);
const Color _kSlate = Color(0xFF64748B);
const Color _kEmerald = Color(0xFF10B981);

class AnswerSheetCameraScreen extends StatefulWidget {
  final int examId;
  final Map<String, dynamic>? exam;
  final List<Map<String, dynamic>> sections;
  final List<Map<String, dynamic>> students;
  final VoidCallback? onViewInMySubjects;

  const AnswerSheetCameraScreen({
    super.key,
    required this.examId,
    required this.sections,
    this.exam,
    this.students = const [],
    this.onViewInMySubjects,
  });

  @override
  State<AnswerSheetCameraScreen> createState() =>
      _AnswerSheetCameraScreenState();
}

class _AnswerSheetCameraScreenState extends State<AnswerSheetCameraScreen> {
  CameraController? _cameraController;
  final TransformationController _zoomController =
      TransformationController();

  Size? _scannerViewportSize;

  bool _isInitializing = true;
  bool _isTakingPicture = false;
  bool _isProcessing = false;
  bool _hasError = false;

  bool _isAnalyzingFrame = false;
  bool _autoCaptureTriggered = false;

  int _stableFrameCount = 0;

  DateTime _lastFrameCheck = DateTime.fromMillisecondsSinceEpoch(0);

  List<Offset>? _previousNormalizedMarkers;

  String _markerStatus = 'Position the answer sheet';

  String? _errorMessage;

  Uint8List? _capturedImageBytes;
  String _capturedFileName = 'Camera capture.jpg';

  double _zoomScale = 1.0;
  FlashMode _flashMode = FlashMode.off;

  @override
  void initState() {
    super.initState();
    _initializeCamera();
  }

  Future<void> _startLiveMarkerDetection(
  CameraController controller,
  ) async {
    if (defaultTargetPlatform != TargetPlatform.iOS ||
        !controller.value.isInitialized ||
        controller.value.isStreamingImages) {
      return;
    }

    _stableFrameCount = 0;
    _previousNormalizedMarkers = null;
    _autoCaptureTriggered = false;
    _markerStatus = 'Position the answer sheet';

    try {
      debugPrint('CHECKMATE: Attempting to start iPhone image stream');
      await controller.startImageStream((CameraImage image) {
        debugPrint(
          'CHECKMATE: Camera frame received '
          '${image.width}x${image.height}, '
          'format: ${image.format.group}',
        );

        _analyzeCameraFrame(image);
      });

debugPrint('CHECKMATE: Live camera stream started');
    } catch (e) {
      debugPrint('CHECKMATE LIVE DETECTION ERROR: $e');

      if (mounted) {
        setState(() {
          _markerStatus = 'Automatic capture unavailable. Use the shutter.';
        });
      }
    }
  }


img.Image? _convertBgraFrame(CameraImage cameraImage) {
  if (cameraImage.format.group != ImageFormatGroup.bgra8888 ||
      cameraImage.planes.isEmpty) {
    return null;
  }

  final plane = cameraImage.planes.first;
  final bytesPerPixel = plane.bytesPerPixel ?? 4;

  if (bytesPerPixel < 4) return null;

  const maxDimension = 360;

  final scale = math.max(
    cameraImage.width / maxDimension,
    cameraImage.height / maxDimension,
  );

  final targetWidth =
      (cameraImage.width / scale).round().clamp(1, maxDimension);

  final targetHeight =
      (cameraImage.height / scale).round().clamp(1, maxDimension);

  final result = img.Image(
    width: targetWidth,
    height: targetHeight,
    numChannels: 3,
  );

  for (int y = 0; y < targetHeight; y++) {
    final sourceY = (y * cameraImage.height / targetHeight).floor();

    for (int x = 0; x < targetWidth; x++) {
      final sourceX = (x * cameraImage.width / targetWidth).floor();

      final offset =
          sourceY * plane.bytesPerRow + sourceX * bytesPerPixel;

      if (offset + 2 >= plane.bytes.length) return null;

      final blue = plane.bytes[offset];
      final green = plane.bytes[offset + 1];
      final red = plane.bytes[offset + 2];

      result.setPixelRgb(x, y, red, green, blue);
    }
  }

  if (result.width > result.height) {
    return img.copyRotate(result, angle: 90);
  }

  return result;
}

Future<void> _analyzeCameraFrame(CameraImage cameraImage) async {
  if (!mounted ||
      _autoCaptureTriggered ||
      _isTakingPicture ||
      _isProcessing ||
      _isAnalyzingFrame) {
    return;
  }

  final now = DateTime.now();

  if (now.difference(_lastFrameCheck).inMilliseconds < 200) {
    return;
  }

  _lastFrameCheck = now;
  _isAnalyzingFrame = true;

  try {
    final frame = _convertBgraFrame(cameraImage);
    debugPrint(
      'CHECKMATE: Frame conversion ${frame == null ? "FAILED" : "SUCCESS"}',
    );
    if (frame == null) {
      _stableFrameCount = 0;
      _previousNormalizedMarkers = null;
      if (mounted) {
        setState(() {
          _markerStatus = 'Automatic detection unavailable. Use the shutter.';
        });
      }
      return;
    }

    final markers = AnswerSheetProcessor.detectLiveMarkers(frame);
    debugPrint(
      'CHECKMATE: Markers detected: ${markers?.length ?? 0}',
    );
    if (markers == null || markers.length != 4) {
      _stableFrameCount = 0;
      _previousNormalizedMarkers = null;

      if (mounted) {
        setState(() {
          _markerStatus = 'Align all four corner markers';
        });
      }
      return;
    }

    final currentMarkers = markers.map((marker) {
      return Offset(
        marker.x / frame.width,
        marker.y / frame.height,
      );
    }).toList();

    bool stable = false;

    if (_previousNormalizedMarkers != null &&
        _previousNormalizedMarkers!.length == 4) {
      stable = true;

      for (int i = 0; i < 4; i++) {
        final dx = (currentMarkers[i].dx -
                _previousNormalizedMarkers![i].dx)
            .abs();

        final dy = (currentMarkers[i].dy -
                _previousNormalizedMarkers![i].dy)
            .abs();

        if (dx > 0.015 || dy > 0.015) {
          stable = false;
          break;
        }
      }
    }

    _stableFrameCount = stable ? _stableFrameCount + 1 : 1;
      _previousNormalizedMarkers = currentMarkers;

      debugPrint(
        'CHECKMATE: Stable frames: $_stableFrameCount/5',
      );

    if (_stableFrameCount >= 5) {
      debugPrint('CHECKMATE: AUTO-CAPTURE TRIGGERED');

      _autoCaptureTriggered = true;

      if (mounted) {
        setState(() {
          _markerStatus = 'Capturing automatically...';
        });
      }

      await _takePicture(automatic: true);
      return;
    }

    if (mounted) {
      setState(() {
        _markerStatus = stable
            ? 'Hold still... ($_stableFrameCount/5)'
            : 'Four markers detected. Hold still...';
      });
    }
  } catch (e) {
    debugPrint('CHECKMATE FRAME ANALYSIS ERROR: $e');
  } finally {
    _isAnalyzingFrame = false;
  }
}


  Future<void> _initializeCamera() async {
  CameraController? controller;

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

    controller = CameraController(
      selectedCamera,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: defaultTargetPlatform == TargetPlatform.iOS
          ? ImageFormatGroup.bgra8888
          : ImageFormatGroup.jpeg,
    );

    await controller.initialize();
    await controller.setFlashMode(_flashMode);

    if (!mounted) {
      await controller.dispose();
      return;
    }

    // Assign the controller BEFORE starting the image stream.
    setState(() {
      _cameraController = controller;
      _isInitializing = false;
      _hasError = false;
    });

    debugPrint('CHECKMATE: Camera initialized successfully');

    // Start automatic detection only after initialization.
    await _startLiveMarkerDetection(controller);
  } catch (e) {
    debugPrint('CHECKMATE CAMERA INITIALIZATION ERROR: $e');

    if (controller != null) {
      await controller.dispose();
    }

    if (!mounted) return;

    setState(() {
      _cameraController = null;
      _isInitializing = false;
      _hasError = true;
      _errorMessage = e.toString();
    });
  }
}

  Future<void> _toggleFlash() async {
    final controller = _cameraController;

    if (controller == null || !controller.value.isInitialized) {
      return;
    }

    try {
      final FlashMode newFlashMode =
          _flashMode == FlashMode.off
              ? FlashMode.torch
              : FlashMode.off;

      await controller.setFlashMode(newFlashMode);

      if (!mounted) return;

      setState(() => _flashMode = newFlashMode);
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unable to change flash: $e')),
      );
    }
  }

  
Future<void> _chooseFromGallery() async {
  try {
    final ImagePicker picker = ImagePicker();

    final image = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 100,
    );

    if (image == null) return;

    final Uint8List imageBytes = await image.readAsBytes();

    if (!mounted) return;

    _resetZoom();

    setState(() {
      // Gallery images remain uncropped.
      _capturedImageBytes = imageBytes;
      _capturedFileName =
          image.name.isNotEmpty ? image.name : 'Gallery.jpg';
      _isProcessing = false;
    });

    debugPrint(
      '[CheckMate] Gallery image selected: ${image.name}',
    );
  } catch (e) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 5),
        content: Text('Unable to choose image:\n$e'),
      ),
    );
  }
}

  // ============================================================
  // CROP IMAGE TO SCANNER FRAME
  // ============================================================

  Uint8List? _cropImageToScannerFrame(
    Uint8List imageBytes,
    Size viewportSize,
  ) {
    try {
      final decodedImage = img.decodeImage(imageBytes);

      if (decodedImage == null) {
        debugPrint('CHECKMATE CROP: Unable to decode image.');
        return null;
      }

      // Correct the captured photo orientation before cropping.
      final orientedImage = img.bakeOrientation(decodedImage);

      // These values match ScannerOverlayPainter.
      const double answerSheetRatio = 0.705;

      final double frameWidth = viewportSize.width * 0.82;
      final double frameHeight = frameWidth / answerSheetRatio;

      final double frameLeft =
          (viewportSize.width - frameWidth) / 2;

      final double frameTop =
          (viewportSize.height - frameHeight) / 2;

      // Add a small safety margin around the scanner frame.
      const double safetyMarginRatio = 0.03;

      final double marginX = frameWidth * safetyMarginRatio;
      final double marginY = frameHeight * safetyMarginRatio;

      final double cropLeft = frameLeft - marginX;
      final double cropTop = frameTop - marginY;

      final double cropWidth = frameWidth + (marginX * 2);
      final double cropHeight = frameHeight + (marginY * 2);

      // Map preview coordinates to captured image coordinates.
      // Assumes centered BoxFit.cover scaling.
      final double scale = math.max(
        viewportSize.width / orientedImage.width,
        viewportSize.height / orientedImage.height,
      );

      final double renderedWidth = orientedImage.width * scale;
      final double renderedHeight = orientedImage.height * scale;

      final double offsetX =
          (renderedWidth - viewportSize.width) / 2;

      final double offsetY =
          (renderedHeight - viewportSize.height) / 2;

      final int cropX = ((cropLeft + offsetX) / scale)
          .floor()
          .clamp(0, orientedImage.width - 1)
          .toInt();

      final int cropY = ((cropTop + offsetY) / scale)
          .floor()
          .clamp(0, orientedImage.height - 1)
          .toInt();

      final int cropRight =
          ((cropLeft + cropWidth + offsetX) / scale)
              .ceil()
              .clamp(cropX + 1, orientedImage.width)
              .toInt();

      final int cropBottom =
          ((cropTop + cropHeight + offsetY) / scale)
              .ceil()
              .clamp(cropY + 1, orientedImage.height)
              .toInt();

      final croppedImage = img.copyCrop(
        orientedImage,
        x: cropX,
        y: cropY,
        width: cropRight - cropX,
        height: cropBottom - cropY,
      );

      debugPrint(
        'CHECKMATE CROP: '
        '${orientedImage.width}x${orientedImage.height} -> '
        '${croppedImage.width}x${croppedImage.height}',
      );

      return Uint8List.fromList(
        img.encodeJpg(croppedImage, quality: 95),
      );
    } catch (e) {
      debugPrint('CHECKMATE FRAME CROP ERROR: $e');
      return null;
    }
  }

  // ============================================================
  // TAKE PICTURE
  // ============================================================

  Future<void> _takePicture({bool automatic = false}) async {
    final controller = _cameraController;

    if (controller == null ||
        !controller.value.isInitialized ||
        _isTakingPicture) {
      return;
    }

    try {
      setState(() => _isTakingPicture = true);
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }

      final XFile image = await controller.takePicture();
      final Uint8List imageBytes = await image.readAsBytes();

      final viewportSize = _scannerViewportSize;

      final Uint8List? croppedBytes = viewportSize == null
          ? null
          : _cropImageToScannerFrame(imageBytes, viewportSize);

      if (!mounted) return;

      _resetZoom();

      setState(() {
        // Use the cropped image when cropping succeeds.
        // Otherwise, retain the original camera image.
        _capturedImageBytes = croppedBytes ?? imageBytes;

        _capturedFileName = 'Camera capture.jpg';
        _isTakingPicture = false;
      });

      debugPrint(
        'CHECKMATE ORIGINAL IMAGE: ${imageBytes.length} bytes',
      );

      debugPrint(
        'CHECKMATE CROPPED IMAGE: '
        '${croppedBytes?.length ?? 0} bytes',
      );

      if (croppedBytes == null) {
        debugPrint(
          'CHECKMATE CROP: Using original image as fallback.',
        );
      }
    } catch (e) {
      if (!mounted) return;

      setState(() => _isTakingPicture = false);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to capture answer sheet: $e'),
        ),
      );
    }
  }

  void _resetZoom() {
    _zoomScale = 1.0;
    _zoomController.value = Matrix4.identity();
  }

  void _toggleInspectZoom() {
    setState(() {
      if (_zoomScale == 1.0) {
        _zoomScale = 2.0;

        _zoomController.value = Matrix4.identity()
          ..scaleByDouble(2.0, 2.0, 1.0, 1.0);
      } else {
        _zoomScale = 1.0;
        _zoomController.value = Matrix4.identity();
      }
    });
  }

  // ============================================================
  // OPEN UPLOAD VERIFICATION
  // ============================================================

  Future<void> _openUploadVerification() async {
    final bytes = _capturedImageBytes;

    if (bytes == null || _isProcessing) return;

    final result = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) => AnswerSheetUploadScreen(
          examId: widget.examId,
          exam: widget.exam,
          sections: widget.sections,
          students: widget.students,
          initialImageBytes: bytes,
          initialFileName: _capturedFileName,
          autoProcessOnStart: true,
          onViewInMySubjects: () {
            Navigator.of(context).pop();
            widget.onViewInMySubjects?.call();
          },
        ),
      ),
    );

    if (!mounted) return;

    if (result == 'scan_next') {
      _retakePicture();
    }
  }

  Future<void> _retakePicture() async {
  final controller = _cameraController;

  if (!mounted || controller == null || !controller.value.isInitialized) {
    return;
  }

  setState(() {
    _capturedImageBytes = null;
    _isProcessing = false;
    _isTakingPicture = false;
    _markerStatus = 'Position the answer sheet';
  });

  _stableFrameCount = 0;
  _previousNormalizedMarkers = null;
  _autoCaptureTriggered = false;
  _isAnalyzingFrame = false;

  _resetZoom();

  // Restart automatic detection after returning to the camera preview.
  await Future.delayed(const Duration(milliseconds: 300));

  if (!mounted) return;

  if (!controller.value.isStreamingImages) {
    await _startLiveMarkerDetection(controller);
  }
}

  @override
  void dispose() {
    _cameraController?.dispose();
    _zoomController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_capturedImageBytes != null) {
      return _buildReviewScreen();
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
        backgroundColor: _kNavyDark,
        foregroundColor: Colors.white,
        title: const Text(
          'Scan Answer Sheet',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 17,
          ),
        ),
        actions: [
          if (!_isInitializing && !_hasError)
            IconButton(
              tooltip: _flashMode == FlashMode.off
                  ? 'Turn Flash On'
                  : 'Turn Flash Off',
              onPressed: _toggleFlash,
              icon: Icon(
                _flashMode == FlashMode.off
                    ? Icons.flash_off
                    : Icons.flash_on,
              ),
            ),
        ],
      ),
      body: _isInitializing
          ? const Center(
              child: CircularProgressIndicator(color: Colors.white),
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
    final controller = _cameraController;

    if (controller == null || !controller.value.isInitialized) {
      return _buildCameraError();
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // Record the exact dimensions used by the scanner overlay.
        _scannerViewportSize = Size(
          constraints.maxWidth,
          constraints.maxHeight,
        );

        return Stack(
          fit: StackFit.expand,
          children: [
            CameraPreview(controller),

            CustomPaint(
              painter: ScannerOverlayPainter(),
            ),

            Positioned(
              top: 20,
              left: 20,
              right: 20,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: _kNavyDark.withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white24),
                ),
                child: const Column(
                  children: [
                    Text(
                      'Align sheet corners within the frame',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Keep all four black corner registration markers visible',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 12.5,
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
                padding: const EdgeInsets.only(
                  top: 20,
                  bottom: 28,
                  left: 20,
                  right: 20,
                ),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      _kNavyDark.withValues(alpha: 0.94),
                    ],
                  ),
                ),
                child: SafeArea(
                  top: false,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'Keep the sheet flat and well lit',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 16),

                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          // Gallery button
                          OutlinedButton.icon(
                            onPressed: _isTakingPicture
                                ? null
                                : _chooseFromGallery,
                            icon: const Icon(
                              Icons.photo_library_outlined,
                              size: 18,
                            ),
                            label: const Text('Gallery'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.white,
                              side: const BorderSide(
                                color: Colors.white38,
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 12,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                          ),

                          // Shutter button
                          GestureDetector(
                            onTap: _isTakingPicture
                                ? null
                                : _takePicture,
                            child: Container(
                              width: 78,
                              height: 78,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.white,
                                border: Border.all(
                                  color: _kEmerald,
                                  width: 4,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(
                                      alpha: 0.4,
                                    ),
                                    blurRadius: 10,
                                  ),
                                ],
                              ),
                              child: _isTakingPicture
                                  ? const Padding(
                                      padding: EdgeInsets.all(20),
                                      child: CircularProgressIndicator(
                                        color: _kNavy,
                                      ),
                                    )
                                  : const Icon(
                                      Icons.camera_alt_rounded,
                                      color: _kNavyDark,
                                      size: 32,
                                    ),
                            ),
                          ),

                          const SizedBox(width: 96),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
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
              size: 64,
            ),
            const SizedBox(height: 16),
            const Text(
              'Camera unavailable',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _errorMessage ??
                  'Unable to access the camera. You can still pick a photo from your device gallery.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 24),

            Wrap(
              spacing: 12,
              runSpacing: 12,
              alignment: WrapAlignment.center,
              children: [
                OutlinedButton.icon(
                  onPressed: () {
                    setState(() {
                      _isInitializing = true;
                      _hasError = false;
                      _errorMessage = null;
                    });

                    _initializeCamera();
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white54),
                  ),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Try Camera Again'),
                ),

                FilledButton.icon(
                  onPressed: _chooseFromGallery,
                  style: FilledButton.styleFrom(
                    backgroundColor: _kNavy,
                    foregroundColor: Colors.white,
                  ),
                  icon: const Icon(Icons.photo_library_outlined),
                  label: const Text('Pick from Gallery'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // REVIEW SCREEN
  // ============================================================

  Widget _buildReviewScreen() {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: _kNavyDark,
        foregroundColor: Colors.white,
        title: const Text(
          'Review Captured Sheet',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 17,
          ),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: ActionChip(
              avatar: Icon(
                _zoomScale > 1.0
                    ? Icons.zoom_out
                    : Icons.zoom_in,
                size: 18,
                color: Colors.white,
              ),
              label: Text(
                _zoomScale > 1.0 ? '2x Zoom' : '1x / 2x',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 12.5,
                ),
              ),
              backgroundColor: _kNavy,
              side: const BorderSide(color: Colors.white24),
              onPressed: _toggleInspectZoom,
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              alignment: Alignment.bottomCenter,
              children: [
                InteractiveViewer(
                  transformationController: _zoomController,
                  minScale: 1.0,
                  maxScale: 4.0,
                  child: Center(
                    child: Image.memory(
                      _capturedImageBytes!,
                      fit: BoxFit.contain,
                    ),
                  ),
                ),

                Positioned(
                  bottom: 16,
                  child: GestureDetector(
                    onTap: _toggleInspectZoom,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: _kNavyDark.withValues(alpha: 0.85),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: Colors.white24),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _zoomScale > 1.0
                                ? Icons.zoom_out
                                : Icons.zoom_in,
                            color: Colors.white,
                            size: 18,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            _zoomScale > 1.0
                                ? 'Inspecting at 2x • Tap for 1x'
                                : 'Tap to toggle 1x / 2x zoom',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Sticky review actions
          Container(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(
                top: Radius.circular(24),
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
                      label: const Text(
                        'Retake',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: _kNavy,
                        side: const BorderSide(color: _kSlate),
                        padding: const EdgeInsets.symmetric(vertical: 15),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(width: 12),

                  Expanded(
                    flex: 2,
                    child: FilledButton.icon(
                      onPressed: _isProcessing
                          ? null
                          : _openUploadVerification,
                      icon: const Icon(Icons.arrow_forward),
                      label: const Text(
                        'Review & Process',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      style: FilledButton.styleFrom(
                        backgroundColor: _kNavyDark,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 15),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
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

class ScannerOverlayPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    const double answerSheetRatio = 0.705;

    final double frameWidth = size.width * 0.82;
    final double frameHeight = frameWidth / answerSheetRatio;

    final double left = (size.width - frameWidth) / 2;
    final double top = (size.height - frameHeight) / 2;

    final Rect frame = Rect.fromLTWH(
      left,
      top,
      frameWidth,
      frameHeight,
    );

    final Paint overlayPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.55);

    final Path outsidePath = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height));

    final Path framePath = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          frame,
          const Radius.circular(12),
        ),
      );

    final Path overlayPath = Path.combine(
      PathOperation.difference,
      outsidePath,
      framePath,
    );

    canvas.drawPath(overlayPath, overlayPaint);

    final Paint framePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        frame,
        const Radius.circular(12),
      ),
      framePaint,
    );

    final Paint cornerPaint = Paint()
      ..color = _kEmerald
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
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
