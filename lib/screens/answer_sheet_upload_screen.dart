import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:qr/qr.dart';

import 'package:checkmate/services/answer_sheet_processor.dart';
import '../services/answer_sheet_layout.dart';
import '../services/api_service.dart';
import '../services/auth_storage.dart';
import '../services/mlkit_ocr_service.dart';
import '../services/my_subjects_api_service.dart';
import '../services/omr_processor.dart';
import '../services/opencv_omr_service.dart';
import '../services/scoring_service.dart';
import 'answer_sheet_camera_screen.dart';
import 'teacher_dashboard.dart' show TeacherPage, TeacherShell;

// =============================================================
// Brand Palette & Visual Tokens
// =============================================================
const Color _kNavy = Color(0xFF1E293B);
const Color _kNavyDark = Color(0xFF162137);
const Color _kSlate = Color(0xFF64748B);
const Color _kBg = Color(0xFFF8FAFC);
const Color _kLine = Color(0xFFE2E8F0);
const Color _kEmerald = Color(0xFF10B981);
const Color _kEmeraldDark = Color(0xFF047857);
const Color _kAmber = Color(0xFFF59E0B);
const Color _kAmberDark = Color(0xFF92400E);
const Color _kRed = Color(0xFFB91C1C);

class _UpperCaseFormatter extends TextInputFormatter {
  const _UpperCaseFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final upper = newValue.text.toUpperCase();
    if (upper == newValue.text) return newValue;
    return newValue.copyWith(
      text: upper,
      selection: newValue.selection,
      composing: TextRange.empty,
    );
  }
}

class AnswerSheetUploadScreen extends StatefulWidget {
  final dynamic examId;
  final Map<String, dynamic>? exam;
  final Uint8List? initialImageBytes;
  final String? initialFileName;
  final bool autoProcessOnStart;
  final List<Map<String, dynamic>> sections;
  final List<Map<String, dynamic>> students;
  final VoidCallback? onViewInMySubjects;

  const AnswerSheetUploadScreen({
    super.key,
    this.examId,
    this.exam,
    this.initialImageBytes,
    this.initialFileName,
    this.autoProcessOnStart = false,
    this.sections = const [],
    this.students = const [],
    this.onViewInMySubjects,
  });

  @override
  State<AnswerSheetUploadScreen> createState() =>
      _AnswerSheetUploadScreenState();
}

class _AnswerSheetUploadScreenState extends State<AnswerSheetUploadScreen> {
  Uint8List? _imageBytes;
  Uint8List? _processedImageBytes;
  Uint8List? _omrDebugImageBytes;
  String? _fileName;

  int? _sourceImageWidth;
  int? _sourceImageHeight;

  bool _isProcessing = false;
  bool _isSavingScore = false;

  List<RegistrationPoint>? _detectedMarkers;

  OMRProcessingResult? _omrResult;
  String? _identificationOcrNotice;
  ScoringResult? _scoringResult;
  bool _answersVerified = false;

  Map<String, dynamic>? _exam;
  List<Map<String, dynamic>> _allExams = [];
  List<Map<String, dynamic>> _students = [];
  int? _detectedQrSheetNumber;
  Map<String, dynamic>? _lastRecordedStudent;
  bool _lastUpdatedExisting = false;

  @override
  void initState() {
    super.initState();
    _exam = widget.exam != null ? Map<String, dynamic>.from(widget.exam!) : null;
    _students = widget.students
        .map((s) => Map<String, dynamic>.from(s))
        .toList();
    _imageBytes = widget.initialImageBytes;
    _fileName = widget.initialFileName ??
        (widget.initialImageBytes != null ? 'Camera capture.jpg' : null);

    if (_imageBytes != null) {
      _decodeSourceDimensions(_imageBytes!);
    }

    _ensureExamAndStudentsLoaded().then((_) {
      if (mounted && widget.autoProcessOnStart && _imageBytes != null) {
        _processImage();
      }
    });
  }

  void _decodeSourceDimensions(Uint8List bytes) {
    try {
      final decoded = img.decodeImage(bytes);
      if (decoded != null) {
        _sourceImageWidth = decoded.width;
        _sourceImageHeight = decoded.height;
      }
    } catch (_) {
      _sourceImageWidth = null;
      _sourceImageHeight = null;
    }
  }

  Future<void> _ensureExamAndStudentsLoaded() async {
    final int? eid = int.tryParse('${widget.examId ?? _exam?['id'] ?? ''}');
    if (eid == null) return;

    try {
      final token = await AuthStorage.getToken();
      if (token == null || token.isEmpty) return;

      List<Map<String, dynamic>> allExams = _allExams;
      if (allExams.isEmpty) {
        try {
          allExams = await ApiService.getExams(token);
        } catch (_) {
          allExams = [];
        }
      }

      Map<String, dynamic>? loadedExam = _exam;
      if (loadedExam == null || loadedExam['title'] == null) {
        try {
          loadedExam = await ApiService.getExamById(token, eid);
        } catch (_) {
          for (final item in allExams) {
            if (int.tryParse('${item['id']}') == eid) {
              loadedExam = item;
              break;
            }
          }
        }
      }

      List<Map<String, dynamic>> loadedStudents = _students;
      if (loadedStudents.isEmpty && loadedExam != null) {
        loadedStudents = await ApiService.getExamStudents(token, loadedExam);
      }

      if (!mounted) return;
      setState(() {
        if (allExams.isNotEmpty) _allExams = allExams;
        if (loadedExam != null) _exam = loadedExam;
        if (loadedStudents.isNotEmpty) _students = loadedStudents;
      });
    } catch (_) {
      // Non-fatal: manual student fields remain available.
    }
  }

  // ------------------------------------------------------------
  // PICK IMAGE
  // ------------------------------------------------------------

  Future<void> _pickImage() async {
    const XTypeGroup imageTypeGroup = XTypeGroup(
      label: 'Images',
      extensions: ['jpg', 'jpeg', 'png'],
    );

    final XFile? file = await openFile(
      acceptedTypeGroups: [imageTypeGroup],
    );

    if (file == null) return;

    final Uint8List bytes = await file.readAsBytes();
    if (!mounted) return;

    _decodeSourceDimensions(bytes);

    setState(() {
      _imageBytes = bytes;
      _processedImageBytes = null;
      _omrDebugImageBytes = null;
      _detectedMarkers = null;
      _omrResult = null;
      _identificationOcrNotice = null;
      _scoringResult = null;
      _answersVerified = false;
      _fileName = file.name;
      _isProcessing = false;
    });

    await _processImage();
  }

  Future<void> _openCameraCapture() async {
    final int? eid = int.tryParse('${widget.examId ?? _exam?['id'] ?? ''}');
    if (eid == null) return;

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AnswerSheetCameraScreen(
          examId: eid,
          exam: _exam,
          sections: widget.sections,
          students: _students,
          onViewInMySubjects: widget.onViewInMySubjects,
        ),
      ),
    );
  }

  // ------------------------------------------------------------
  // PROCESS ANSWER SHEET & DETECT CORNER REGISTRATION MARKERS
  // ------------------------------------------------------------

  Future<void> _processImage() async {
    if (_imageBytes == null) return;

    setState(() {
      _isProcessing = true;
      _processedImageBytes = null;
      _omrDebugImageBytes = null;
      _detectedMarkers = null;
      _omrResult = null;
      _identificationOcrNotice = null;
      _scoringResult = null;
      _answersVerified = false;
    });

    try {
      final result = await AnswerSheetProcessor.processAnswerSheet(
        _imageBytes!,
      );

      if (!mounted) return;

      await _ensureExamAndStudentsLoaded();
      if (!mounted) return;

      // Enforce strict 1-to-1 Answer Sheet <-> Assessment verification right
      // after perspective alignment so answer sheets from any other exam/quiz
      // are immediately rejected.
      _verifyAnswerSheetMatchesAssessment(result.correctedImageBytes);

      setState(() {
        _processedImageBytes = result.correctedImageBytes;
        _detectedMarkers = result.markers;
        _isProcessing = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: _kNavyDark,
          content: Text(
            'Answer sheet aligned, 4 corner markers detected, and 1-to-1 assessment verified.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _isProcessing = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: _kRed,
          content: Text(
            'Processing failed: ${e.toString().replaceFirst('Exception: ', '')}',
          ),
          duration: const Duration(seconds: 5),
        ),
      );
    }
  }

  // ------------------------------------------------------------
  // RUN OMR + OCR + OPEN VERIFICATION MODAL
  // ------------------------------------------------------------

  Future<void> _runOMR() async {
    final alignedImageBytes = _processedImageBytes;
    if (alignedImageBytes == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please process the answer sheet first.'),
        ),
      );
      return;
    }

    if (widget.sections.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No exam sections were provided.'),
        ),
      );
      return;
    }

    setState(() => _isProcessing = true);

    try {
      final OpenCVOMRResult openCVResult = await OpenCVOMRService.process(
        alignedImageBytes,
        sections: widget.sections,
      );

      String? extractedSheetText;
      if (!kIsWeb) {
        try {
          extractedSheetText =
              await MlKitOcrService.extractTextFromBytes(alignedImageBytes);
        } catch (_) {
          extractedSheetText = null;
        }
      }

      if (!mounted || !identical(_processedImageBytes, alignedImageBytes)) {
        return;
      }
      _verifyAnswerSheetMatchesAssessment(
        alignedImageBytes,
        ocrText: extractedSheetText,
      );
      final detected = _convertOpenCVResult(openCVResult);
      final (result, ocrNotice) = await _readIdentificationAnswers(
        alignedImageBytes,
        detected,
      );

      if (!mounted || !identical(_processedImageBytes, alignedImageBytes)) {
        return;
      }
      setState(() {
        _omrResult = result;
        _identificationOcrNotice = ocrNotice;
        _scoringResult = null;
        _answersVerified = false;
        _omrDebugImageBytes = result.debugImageBytes;
        _isProcessing = false;
      });

      await _verifyDetectedAnswers(
        result,
        ocrText: extractedSheetText,
      );
    } catch (e) {
      if (!mounted) return;

      setState(() => _isProcessing = false);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: _kRed,
          content: Text('OMR processing failed: $e'),
          duration: const Duration(seconds: 5),
        ),
      );
    }
  }

  Future<(OMRProcessingResult, String?)> _readIdentificationAnswers(
    Uint8List alignedImageBytes,
    OMRProcessingResult detected,
  ) async {
    final sections = detected.sections;
    if (!sections.any((section) => section.sectionType == 'identification')) {
      return (detected, null);
    }

    // Match the PDF's single-sheet pagination budget. Later sheets restart
    // at firstSectionY, so their answer boxes need a known page index.
    const sectionHeightBudget =
        AnswerSheetLayout.sheetHeight - 2 * AnswerSheetLayout.sheetPadding -
            18 - 97;
    final sectionHeight = sections.fold<double>(
      0,
      (height, section) => height + AnswerSheetLayout.calculateSectionHeight(
        type: section.sectionType,
        questionCount: section.questionCount,
      ),
    );
    if (sectionHeight > sectionHeightBudget ||
        sections.length != widget.sections.length) {
      return (
        detected,
        'Enter Identification answers manually for this sheet layout.',
      );
    }

    const fallback = 'Identification OCR is unavailable. '
        'Enter the answers manually.';
    try {
      final token = await AuthStorage.getToken();
      final image = img.decodeImage(alignedImageBytes);
      if (token == null || token.isEmpty || image == null) {
        return (detected, fallback);
      }

      final scaleX = image.width / AnswerSheetLayout.sheetWidth;
      final scaleY = image.height / AnswerSheetLayout.sheetHeight;
      // Stay inside the printed border and outside the question number.
      const inset = 1.5;
      final left = ((AnswerSheetLayout.sheetPadding +
                  AnswerSheetLayout.questionNumberWidth + inset) * scaleX)
          .ceil();
      final right = ((AnswerSheetLayout.sheetWidth -
                  AnswerSheetLayout.sheetPadding - inset) * scaleX)
          .floor();
      final boxes = <(int, int, int, int)>[];
      var sectionY = AnswerSheetLayout.firstSectionY;

      for (var i = 0; i < sections.length; i++) {
        final section = sections[i];
        if (section.questionCount == 0) continue;

        if (section.sectionType == 'identification') {
          var rowY = sectionY + AnswerSheetLayout.sectionTitleHeight +
              AnswerSheetLayout.sectionTitleGap;
          for (final answer in section.answers) {
            final top = ((rowY + inset) * scaleY).ceil();
            final bottom =
                ((rowY + AnswerSheetLayout.identificationBoxHeight - inset) *
                        scaleY)
                    .floor();
            boxes.add((i, answer.questionNumber, top, bottom));
            rowY += AnswerSheetLayout.identificationBoxHeight +
                AnswerSheetLayout.identificationRowSpacing;
          }
        }

        sectionY += AnswerSheetLayout.calculateSectionHeight(
          type: section.sectionType,
          questionCount: section.questionCount,
        );
      }

      final recognized = <(int, int), String>{};
      final stopwatch = Stopwatch()..start();
      const timeBudget = Duration(seconds: 35);
      var nextBox = 0;
      var failed = 0;

      Future<void> readBoxes() async {
        while (nextBox < boxes.length &&
            mounted &&
            identical(_processedImageBytes, alignedImageBytes)) {
          if (stopwatch.elapsed >= timeBudget) return;
          final (sectionIndex, number, top, bottom) = boxes[nextBox++];
          try {
            final crop = img.copyCrop(
              image,
              x: left,
              y: top,
              width: right - left,
              height: bottom - top,
            );
            final cropBytes = img.encodePng(crop);
            final remaining = timeBudget - stopwatch.elapsed;
            if (remaining <= Duration.zero) {
              failed++;
              return;
            }
            final text = await ApiService.recognizeIdentification(
              token: token,
              imageBytes: cropBytes,
              timeout: remaining,
            );
            if (text.isNotEmpty) {
              recognized[(sectionIndex, number)] = text.toUpperCase();
            }
          } catch (_) {
            failed++;
          }
        }
      }

      // Limit parallel requests and keep a slow OCR service from blocking
      // manual verification indefinitely.
      await Future.wait(
        List.generate(math.min(boxes.length, 4), (_) => readBoxes()),
      );
      final missed = failed + boxes.length - nextBox;
      final notice = missed == 0
          ? null
          : 'OCR could not process $missed Identification '
              'field(s). Review the sheet and enter missing answers manually.';

      return (
        OMRProcessingResult(
          debugImageBytes: detected.debugImageBytes,
          sections: [
            for (var i = 0; i < sections.length; i++)
              if (sections[i].sectionType != 'identification')
                sections[i]
              else
                OMRSectionResult(
                  sectionName: sections[i].sectionName,
                  sectionType: sections[i].sectionType,
                  questionCount: sections[i].questionCount,
                  answers: [
                    for (final answer in sections[i].answers)
                      OMRAnswer(
                        questionNumber: answer.questionNumber,
                        answer: recognized[(i, answer.questionNumber)] ??
                            answer.answer,
                        confidence: answer.confidence,
                      ),
                  ],
                ),
          ],
        ),
        notice,
      );
    } catch (_) {
      return (detected, fallback);
    }
  }

  // ------------------------------------------------------------
  // CONVERT OPENCV MEASUREMENTS TO APP OMR RESULTS
  // ------------------------------------------------------------

  OMRProcessingResult _convertOpenCVResult(OpenCVOMRResult openCVResult) {
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
          : int.tryParse(sourceSection['question_count']?.toString() ?? '0') ??
              0;

      if (sectionType == 'identification') {
        if (openCVSectionIndex < openCVResult.sections.length &&
            openCVResult.sections[openCVSectionIndex].sectionType ==
                'identification') {
          openCVSectionIndex++;
        }
        convertedSections.add(
          OMRSectionResult(
            sectionName: sectionName,
            sectionType: sectionType,
            questionCount: questionCount,
            answers: List<OMRAnswer>.generate(
              questionCount,
              (int index) {
                final question = index < questions.length
                    ? questions[index]
                    : null;
                final number = question is Map
                    ? int.tryParse('${question['question_number']}')
                    : null;
                return OMRAnswer(
                  questionNumber: number ?? index + 1,
                  answer: 'OCR Pending',
                  confidence: 0,
                );
              },
            ),
          ),
        );
        continue;
      }

      if (sectionType != 'multiple_choice' && sectionType != 'true_false') {
        continue;
      }

      if (openCVSectionIndex >= openCVResult.sections.length) {
        convertedSections.add(
          OMRSectionResult(
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
          ),
        );
        continue;
      }

      final OpenCVSectionMeasurement measuredSection =
          openCVResult.sections[openCVSectionIndex];
      if (measuredSection.sectionType != sectionType) {
        throw StateError(
          'OMR section mismatch at "$sectionName": '
          'expected $sectionType but received ${measuredSection.sectionType}.',
        );
      }
      openCVSectionIndex++;
      final List<OMRAnswer> answers = [];

      for (final OpenCVQuestionMeasurement question
          in measuredSection.questions) {
        final List<OpenCVBubbleMeasurement> bubbles =
            List<OpenCVBubbleMeasurement>.from(question.bubbles)
              ..sort((a, b) => b.fillRatio.compareTo(a.fillRatio));

        if (bubbles.isEmpty) {
          answers.add(
            OMRAnswer(
              questionNumber: question.questionNumber,
              answer: 'Unanswered',
              confidence: 0,
            ),
          );
          continue;
        }

        final OpenCVBubbleMeasurement strongest = bubbles.first;
        final OpenCVBubbleMeasurement? second =
            bubbles.length > 1 ? bubbles[1] : null;

        if (strongest.fillRatio >= 0.46 &&
            strongest.fillRatio < markedThreshold) {
          answers.add(
            OMRAnswer(
              questionNumber: question.questionNumber,
              answer: 'Ambiguous',
              confidence: strongest.fillRatio,
            ),
          );
          continue;
        }
        if (strongest.fillRatio < markedThreshold) {
          answers.add(
            OMRAnswer(
              questionNumber: question.questionNumber,
              answer: 'Unanswered',
              confidence: strongest.fillRatio,
            ),
          );
          continue;
        }

        if (second != null && second.fillRatio >= markedThreshold) {
          answers.add(
            OMRAnswer(
              questionNumber: question.questionNumber,
              answer: 'Multiple',
              confidence: strongest.fillRatio,
            ),
          );
          continue;
        }

        final double gap =
            second != null ? (strongest.fillRatio - second.fillRatio) : 1.0;
        if (second != null && gap < 0.12) {
          answers.add(
            OMRAnswer(
              questionNumber: question.questionNumber,
              answer: 'Ambiguous',
              confidence: strongest.fillRatio,
            ),
          );
          continue;
        }

        // Convert fillRatio + separation gap into a realistic 80%–99% confidence
        // score for clear single-bubble marks.
        final double normalizedConfidence =
            (0.80 + ((strongest.fillRatio - markedThreshold) * 0.35) + (gap * 0.25))
                .clamp(0.82, 0.99);

        answers.add(
          OMRAnswer(
            questionNumber: question.questionNumber,
            answer: strongest.label,
            confidence: normalizedConfidence,
          ),
        );
      }

      convertedSections.add(
        OMRSectionResult(
          sectionName: sectionName,
          sectionType: sectionType,
          questionCount: questionCount,
          answers: answers,
        ),
      );
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
  // STUDENT METADATA HELPERS
  // ------------------------------------------------------------

  String _formatStudentFullName(Map<String, dynamic> student) {
    final last = (student['last_name']?.toString() ?? '').trim().toUpperCase();
    final first =
        (student['first_name']?.toString() ?? '').trim().toUpperCase();
    if (last.isNotEmpty && first.isNotEmpty) return '$last, $first';
    if (last.isNotEmpty) return last;
    if (first.isNotEmpty) return first;
    return (student['name']?.toString() ?? '').trim().toUpperCase();
  }

  String _studentSectionName(Map<String, dynamic> student) {
    final direct = (student['section']?.toString() ?? '').trim();
    if (direct.isNotEmpty) return direct;
    final cls = student['class'];
    if (cls is Map) {
      return (cls['section']?.toString() ?? '').trim();
    }
    return _defaultExamSection();
  }

  String _defaultExamSection() {
    final ex = _exam;
    if (ex == null) return '';
    if (ex['sections'] is List && (ex['sections'] as List).isNotEmpty) {
      return (ex['sections'] as List).first.toString().trim();
    }
    final cls = ex['class'];
    if (cls is Map) {
      return (cls['section']?.toString() ?? '').trim();
    }
    return (ex['section']?.toString() ?? '').trim();
  }

  List<String> _availableSections() {
    final set = <String>{};
    final ex = _exam;
    if (ex != null) {
      if (ex['sections'] is List) {
        for (final s in ex['sections'] as List) {
          final clean = s?.toString().trim() ?? '';
          if (clean.isNotEmpty) set.add(clean);
        }
      }
      final cls = ex['class'];
      if (cls is Map) {
        final sec = cls['section']?.toString().trim() ?? '';
        if (sec.isNotEmpty) set.add(sec);
      }
    }
    for (final st in _students) {
      final sec = _studentSectionName(st);
      if (sec.isNotEmpty) set.add(sec);
    }
    return set.toList()..sort();
  }

  // ------------------------------------------------------------
  // STRICT 1-TO-1 ANSWER SHEET <-> ASSESSMENT VERIFICATION
  // ------------------------------------------------------------

  bool _isQrCoreFunctionModule(int row, int col, int moduleCount) {
    // 3 Finder patterns + separators
    if (row <= 7 && col <= 7) return true;
    if (row <= 7 && col >= moduleCount - 8) return true;
    if (row >= moduleCount - 8 && col <= 7) return true;
    // Timing patterns
    if (row == 6 || col == 6) return true;
    // Version >= 2 alignment pattern (5x5 at bottom-right)
    if (moduleCount >= 25 &&
        row >= moduleCount - 9 &&
        row <= moduleCount - 5 &&
        col >= moduleCount - 9 &&
        col <= moduleCount - 5) {
      return true;
    }
    return false;
  }

  double _sampleGrayscaleBlock(
    img.Image image,
    double centerX,
    double centerY,
    double halfRadius,
  ) {
    final minX = (centerX - halfRadius).floor().clamp(0, image.width - 1);
    final maxX = (centerX + halfRadius).ceil().clamp(0, image.width - 1);
    final minY = (centerY - halfRadius).floor().clamp(0, image.height - 1);
    final maxY = (centerY + halfRadius).ceil().clamp(0, image.height - 1);

    double sum = 0;
    int count = 0;
    for (int y = minY; y <= maxY; y++) {
      for (int x = minX; x <= maxX; x++) {
        final p = image.getPixel(x, y);
        sum += 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
        count++;
      }
    }
    return count > 0 ? (sum / count) : 255.0;
  }

  String _lookupExamLabel(int targetId) {
    for (final item in _allExams) {
      if (int.tryParse('${item['id']}') == targetId) {
        final t = (item['title']?.toString() ?? '').trim();
        final subj = (item['subject_code']?.toString() ?? '').trim();
        if (t.isNotEmpty && subj.isNotEmpty) return '$t ($subj)';
        if (t.isNotEmpty) return t;
      }
    }
    return 'Assessment #$targetId';
  }

  /// Enforces a strict 1-to-1 match between the scanned answer sheet and the
  /// selected assessment ([widget.examId]).
  ///
  /// Checks:
  /// 1. Explicit `CHECKMATE-EXAM-<id>` or `Exam ID: <id>` in OCR text / file name.
  /// 2. Explicit assessment title mismatch in uploaded answer sheet file name.
  /// 3. Top-right QR code (`CHECKMATE-EXAM-<id>-SHEET-<n>` at logical 345..384, 13..52)
  ///    against the selected assessment and all other assessments in [_allExams].
  void _verifyAnswerSheetMatchesAssessment(
    Uint8List alignedImageBytes, {
    String? ocrText,
  }) {
    final int? expectedExamId =
        int.tryParse('${widget.examId ?? _exam?['id'] ?? ''}');
    if (expectedExamId == null) return;

    final expectedTitle = _examTitle();
    _detectedQrSheetNumber = null;

    // 1. Check OCR text & file name for explicit CHECKMATE-EXAM-<id> or Exam ID: <id>
    final combinedText = <String>[
      if (_fileName != null) _fileName!,
      if (ocrText != null) ocrText,
    ].join(' ');

    final checkmateIdMatches = RegExp(
      r'CHECKMATE[-_\s]*EXAM[-_\s]*(\d+)',
      caseSensitive: false,
    ).allMatches(combinedText);
    for (final m in checkmateIdMatches) {
      final foundId = int.tryParse(m.group(1) ?? '');
      if (foundId != null && foundId != expectedExamId) {
        final otherLabel = _lookupExamLabel(foundId);
        throw Exception(
          'Invalid Answer Sheet: This answer sheet belongs to "$otherLabel" '
          '(Exam ID: $foundId), not "$expectedTitle" (Exam ID: $expectedExamId). '
          'Only the 1-to-1 answer sheet for "$expectedTitle" is accepted.',
        );
      }
    }

    final examIdMatches = RegExp(
      r'Exam\s*ID\s*[:#-]?\s*(\d+)',
      caseSensitive: false,
    ).allMatches(combinedText);
    for (final m in examIdMatches) {
      final foundId = int.tryParse(m.group(1) ?? '');
      if (foundId != null && foundId != expectedExamId) {
        final otherLabel = _lookupExamLabel(foundId);
        throw Exception(
          'Invalid Answer Sheet: This answer sheet belongs to "$otherLabel" '
          '(Exam ID: $foundId), not "$expectedTitle" (Exam ID: $expectedExamId). '
          'Only the 1-to-1 answer sheet for "$expectedTitle" is accepted.',
        );
      }
    }

    // Check if the uploaded file name explicitly names a different assessment title.
    final rawFileName = (_fileName ?? '').trim();
    if (rawFileName.isNotEmpty &&
        rawFileName.toLowerCase() != 'camera capture.jpg' &&
        rawFileName.toLowerCase() != 'gallery.jpg') {
      final normFile = rawFileName
          .toLowerCase()
          .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
          .trim();
      final normExpected = expectedTitle
          .toLowerCase()
          .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
          .trim();
      if (normExpected.length >= 4 && !normFile.contains(normExpected)) {
        for (final other in _allExams) {
          final oid = int.tryParse('${other['id']}');
          if (oid == null || oid == expectedExamId) continue;
          final otherTitle = (other['title']?.toString() ?? '').trim();
          final normOther = otherTitle
              .toLowerCase()
              .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
              .trim();
          if (normOther.length >= 5 && normFile.contains(normOther)) {
            throw Exception(
              'Invalid Answer Sheet: The file "$rawFileName" is for "$otherTitle", '
              'not "$expectedTitle". Only the 1-to-1 answer sheet for "$expectedTitle" '
              'is accepted.',
            );
          }
        }
      }
    }

    // 2. Top-Right QR Code Matrix Verification on the aligned 1500x2129 sheet.
    final decoded = img.decodeImage(alignedImageBytes);
    if (decoded == null) return;

    final double scaleX = decoded.width / AnswerSheetLayout.sheetWidth;
    final double scaleY = decoded.height / AnswerSheetLayout.sheetHeight;

    // Locate exact sub-pixel QR alignment in the top-right box (logical 345, 13, 39x39)
    // across candidate QR versions (Version 2 = 25x25, Version 3 = 29x29).
    const double baseQrLeft = 331.0;
    const double baseQrTop = 27.0;
    const double baseQrSize = 39.0;

    final candidateRefs = <QrImage>[
      QrImage(
        QrCode.fromData(
          data: 'CHECKMATE-EXAM-$expectedExamId-SHEET-1',
          errorCorrectLevel: QrErrorCorrectLevel.M,
        ),
      ),
      QrImage(
        QrCode.fromData(
          data: 'CHECKMATE-EXAM-100-SHEET-10',
          errorCorrectLevel: QrErrorCorrectLevel.M,
        ),
      ),
    ];

    QrImage refQr = candidateRefs.first;
    double bestContrastScore = -1e9;
    double bestDx = 0.0;
    double bestDy = 0.0;
    double bestSize = baseQrSize;
    double bestDarkMean = 0.0;
    double bestLightMean = 255.0;

    final seenModuleCounts = <int>{};
    for (final candRef in candidateRefs) {
      final mCount = candRef.moduleCount;
      if (!seenModuleCounts.add(mCount)) continue;
      for (double sizeL = 38.0; sizeL <= 40.01; sizeL += 0.5) {
        final double cellL = sizeL / mCount;
        final double sampleR = math.max(0.8, cellL * scaleX * 0.16);
        for (double dy = -3.2; dy <= 3.21; dy += 0.4) {
          for (double dx = -3.2; dx <= 3.21; dx += 0.4) {
            double darkSum = 0;
            int darkCount = 0;
            double lightSum = 0;
            int lightCount = 0;

            for (int r = 0; r < mCount; r++) {
              for (int c = 0; c < mCount; c++) {
                if (!_isQrCoreFunctionModule(r, c, mCount)) continue;
                final double lx = baseQrLeft + dx + (c + 0.5) * cellL;
                final double ly = baseQrTop + dy + (r + 0.5) * cellL;
                final double lum = _sampleGrayscaleBlock(
                  decoded,
                  lx * scaleX,
                  ly * scaleY,
                  sampleR,
                );
                if (candRef.isDark(r, c)) {
                  darkSum += lum;
                  darkCount++;
                } else {
                  lightSum += lum;
                  lightCount++;
                }
              }
            }

            if (darkCount == 0 || lightCount == 0) continue;
            final double darkMean = darkSum / darkCount;
            final double lightMean = lightSum / lightCount;
            final double contrast = lightMean - darkMean;
            if (contrast > bestContrastScore) {
              bestContrastScore = contrast;
              refQr = candRef;
              bestDx = dx;
              bestDy = dy;
              bestSize = sizeL;
              bestDarkMean = darkMean;
              bestLightMean = lightMean;
            }
          }
        }
      }
    }

    if (bestContrastScore < 20.0) {
      throw Exception(
        'Invalid Answer Sheet: Official CheckMate QR code was not detected in '
        'the top-right header. Please scan a valid answer sheet generated for '
        '"$expectedTitle".',
      );
    }

    final int moduleCount = refQr.moduleCount;
    final double cellL = bestSize / moduleCount;
    final double sampleR = math.max(0.9, cellL * scaleX * 0.18);
    final double midLum = (bestDarkMean + bestLightMean) / 2.0;

    final Map<int, List<List<bool>>> observedByCount = <int, List<List<bool>>>{};
    List<List<bool>> getObservedGrid(int mCount) {
      return observedByCount.putIfAbsent(mCount, () {
        final double cL = bestSize / mCount;
        final double sR = math.max(0.9, cL * scaleX * 0.18);
        return List<List<bool>>.generate(
          mCount,
          (r) => List<bool>.generate(mCount, (c) {
            final double lx = baseQrLeft + bestDx + (c + 0.5) * cL;
            final double ly = baseQrTop + bestDy + (r + 0.5) * cL;
            final double lum = _sampleGrayscaleBlock(
              decoded,
              lx * scaleX,
              ly * scaleY,
              sR,
            );
            return lum < midLum;
          }),
        );
      });
    }

    final List<List<bool>> observedDark = getObservedGrid(moduleCount);

    int funcMatches = 0;
    int funcTotal = 0;
    for (int r = 0; r < moduleCount; r++) {
      for (int c = 0; c < moduleCount; c++) {
        if (_isQrCoreFunctionModule(r, c, moduleCount)) {
          funcTotal++;
          if (observedDark[r][c] == refQr.isDark(r, c)) {
            funcMatches++;
          }
        }
      }
    }
    final double finderAgreement =
        funcTotal > 0 ? (funcMatches / funcTotal) : 0.0;

    if (finderAgreement < 0.72) {
      throw Exception(
        'Invalid Answer Sheet: The top-right QR code could not be verified as a '
        'valid CheckMate answer sheet for "$expectedTitle".',
      );
    }

    double scoreQrCandidate(int candidateExamId, int sheetNum) {
      final qri = QrImage(
        QrCode.fromData(
          data: 'CHECKMATE-EXAM-$candidateExamId-SHEET-$sheetNum',
          errorCorrectLevel: QrErrorCorrectLevel.M,
        ),
      );
      final int mCount = qri.moduleCount;
      final grid = getObservedGrid(mCount);
      int matches = 0;
      int total = 0;
      for (int r = 0; r < mCount; r++) {
        for (int c = 0; c < mCount; c++) {
          if (_isQrCoreFunctionModule(r, c, mCount)) continue;
          total++;
          if (grid[r][c] == qri.isDark(r, c)) {
            matches++;
          }
        }
      }
      return total > 0 ? (matches / total) : 0.0;
    }

    final int maxExpectedSheets = math.max(_students.length * 2 + 10, 60);
    double expectedBestRatio = 0.0;
    int expectedBestSheet = 1;
    for (int s = 1; s <= maxExpectedSheets; s++) {
      final ratio = scoreQrCandidate(expectedExamId, s);
      if (ratio > expectedBestRatio) {
        expectedBestRatio = ratio;
        expectedBestSheet = s;
      }
    }

    // Cross-check against all other assessments in _allExams.
    double otherBestRatio = 0.0;
    Map<String, dynamic>? otherBestExam;
    for (final other in _allExams) {
      final oid = int.tryParse('${other['id']}');
      if (oid == null || oid == expectedExamId) continue;
      for (int s = 1; s <= 50; s++) {
        final ratio = scoreQrCandidate(oid, s);
        if (ratio > otherBestRatio) {
          otherBestRatio = ratio;
          otherBestExam = other;
        }
      }
    }

    if (otherBestExam != null &&
        otherBestRatio >= 0.70 &&
        otherBestRatio >= expectedBestRatio + 0.05) {
      final otherId = otherBestExam['id'];
      final otherLabel = _lookupExamLabel(int.tryParse('$otherId') ?? 0);
      throw Exception(
        'Invalid Answer Sheet: This answer sheet belongs to "$otherLabel" '
        '(Exam ID: $otherId), not "$expectedTitle" (Exam ID: $expectedExamId). '
        'Only the 1-to-1 answer sheet for "$expectedTitle" can be used.',
      );
    }

    if (finderAgreement >= 0.76 && expectedBestRatio < 0.66) {
      throw Exception(
        'Invalid Answer Sheet: The QR code on this answer sheet does not match '
        '"$expectedTitle" (Exam ID: $expectedExamId). Only the 1-to-1 answer '
        'sheet generated specifically for "$expectedTitle" can be used.',
      );
    }

    if (expectedBestRatio >= 0.66) {
      _detectedQrSheetNumber = expectedBestSheet;
    }
  }

  Map<String, dynamic>? _autoDetectStudent({String? ocrText}) {
    if (_students.isEmpty) return null;

    final haystacks = <String>[
      ?_fileName,
      ?ocrText,
    ];
    final combined = haystacks.join(' ').toUpperCase();

    // 1. Check for QR-verified sheet number or CHECKMATE-EXAM-<id>-SHEET-<n>
    if (_detectedQrSheetNumber != null) {
      final qrIdx = _detectedQrSheetNumber! - 1;
      if (qrIdx >= 0 && qrIdx < _students.length) {
        return _students[qrIdx];
      }
    }
    final sheetMatch =
        RegExp(r'SHEET[-_\s]*(\d+)', caseSensitive: false).firstMatch(combined);
    if (sheetMatch != null) {
      final sheetIdx = (int.tryParse(sheetMatch.group(1)!) ?? 0) - 1;
      if (sheetIdx >= 0 && sheetIdx < _students.length) {
        return _students[sheetIdx];
      }
    }

    // 2. Check for exact student_number match in filename or OCR text.
    for (final st in _students) {
      final snum = (st['student_number']?.toString() ?? '').trim().toUpperCase();
      if (snum.length >= 4 && combined.contains(snum)) {
        return st;
      }
    }

    // 3. Check for student surname + first name in filename or OCR text.
    for (final st in _students) {
      final last = (st['last_name']?.toString() ?? '').trim().toUpperCase();
      final first = (st['first_name']?.toString() ?? '').trim().toUpperCase();
      if (last.length >= 3 &&
          first.length >= 2 &&
          combined.contains(last) &&
          combined.contains(first)) {
        return st;
      }
    }

    return null;
  }

  Map<String, dynamic>? _matchEnrolledStudent({
    int? selectedId,
    required String studentNumber,
    required String studentName,
    required String sectionName,
  }) {
    if (_students.isEmpty) return null;

    if (selectedId != null) {
      for (final st in _students) {
        if (int.tryParse('${st['id']}') == selectedId) {
          return st;
        }
      }
    }

    final cleanNum = studentNumber.trim().toLowerCase();
    final cleanSec = sectionName.trim().toLowerCase();

    if (cleanNum.isNotEmpty) {
      for (final st in _students) {
        final snum = (st['student_number']?.toString() ?? '').trim().toLowerCase();
        final ssec = _studentSectionName(st).toLowerCase();
        if (snum == cleanNum && (cleanSec.isEmpty || ssec == cleanSec)) {
          return st;
        }
      }
      for (final st in _students) {
        final snum = (st['student_number']?.toString() ?? '').trim().toLowerCase();
        if (snum == cleanNum) return st;
      }
    }

    final cleanName =
        studentName.trim().toUpperCase().replaceAll(RegExp(r'\s+'), ' ');
    if (cleanName.isNotEmpty) {
      for (final st in _students) {
        final formatted = _formatStudentFullName(st);
        final ssec = _studentSectionName(st).toLowerCase();
        if (formatted == cleanName && (cleanSec.isEmpty || ssec == cleanSec)) {
          return st;
        }
      }
      for (final st in _students) {
        if (_formatStudentFullName(st) == cleanName) return st;
      }
    }

    return null;
  }

  String _examTitle() =>
      _exam?['title']?.toString().trim().isNotEmpty == true
          ? _exam!['title'].toString().trim()
          : 'Examination';

  String _examSubjectCode() {
    final cls = _exam?['class'];
    final subj = cls is Map ? cls['subject'] : _exam?['subject'];
    if (subj is Map) {
      return subj['code']?.toString().trim() ?? '';
    }
    return _exam?['subject_code']?.toString().trim() ?? '';
  }

  String _examSubjectName() {
    final cls = _exam?['class'];
    final subj = cls is Map ? cls['subject'] : _exam?['subject'];
    if (subj is Map) {
      return subj['name']?.toString().trim() ?? '';
    }
    return _exam?['subject_name']?.toString().trim() ?? '';
  }

  String _examSubjectDisplay() {
    final code = _examSubjectCode();
    final name = _examSubjectName();
    return [code, name].where((e) => e.isNotEmpty).join(' • ');
  }

  // ------------------------------------------------------------
  // STEP 4: VERIFY STUDENT ANSWERS & SCANNING DETAILS MODAL
  // ------------------------------------------------------------

  Future<void> _verifyDetectedAnswers(
    OMRProcessingResult rawResult, {
    String? ocrText,
  }) async {
    await _ensureExamAndStudentsLoaded();
    if (!mounted) return;

    final edits = <String, String>{};
    final overriddenKeys = <String>{};

    for (var sectionIndex = 0;
        sectionIndex < rawResult.sections.length;
        sectionIndex++) {
      final section = rawResult.sections[sectionIndex];
      for (final answer in section.answers) {
        final key = '$sectionIndex:${answer.questionNumber}';
        if (section.sectionType == 'identification') {
          edits[key] = (answer.answer == 'OCR Pending' ||
                  answer.answer == 'Unanswered')
              ? ''
              : answer.answer.toUpperCase();
        } else {
          edits[key] = answer.answer;
        }
      }
    }

    final availableSections = _availableSections();
    final autoMatched = _autoDetectStudent(ocrText: ocrText) ??
        (_lastRecordedStudent == null && _students.length == 1
            ? _students.first
            : null);

    int? selectedStudentId =
        autoMatched != null ? int.tryParse('${autoMatched['id']}') : null;
    final bool autoDetectedHighConfidence = autoMatched != null;

    String selectedSection = autoMatched != null
        ? _studentSectionName(autoMatched)
        : (availableSections.isNotEmpty
            ? availableSections.first
            : _defaultExamSection());

    final nameController = TextEditingController(
      text: autoMatched != null ? _formatStudentFullName(autoMatched) : '',
    );
    final numberController = TextEditingController(
      text: autoMatched != null
          ? (autoMatched['student_number']?.toString() ?? '')
          : '',
    );
    final sectionController = TextEditingController(text: selectedSection);

    final idControllers = <String, TextEditingController>{};
    for (var sectionIndex = 0;
        sectionIndex < rawResult.sections.length;
        sectionIndex++) {
      final section = rawResult.sections[sectionIndex];
      if (section.sectionType == 'identification') {
        for (final answer in section.answers) {
          final key = '$sectionIndex:${answer.questionNumber}';
          idControllers[key] = TextEditingController(text: edits[key] ?? '');
        }
      }
    }

    OMRProcessingResult buildCurrentOmr() {
      return OMRProcessingResult(
        debugImageBytes: rawResult.debugImageBytes,
        sections: [
          for (var i = 0; i < rawResult.sections.length; i++)
            OMRSectionResult(
              sectionName: rawResult.sections[i].sectionName,
              sectionType: rawResult.sections[i].sectionType,
              questionCount: rawResult.sections[i].questionCount,
              answers: [
                for (final a in rawResult.sections[i].answers)
                  OMRAnswer(
                    questionNumber: a.questionNumber,
                    answer: () {
                      final val = (edits['$i:${a.questionNumber}'] ?? a.answer)
                          .trim();
                      if (val.isEmpty || val == 'OCR Pending') {
                        return 'Unanswered';
                      }
                      return rawResult.sections[i].sectionType ==
                              'identification'
                          ? val.toUpperCase()
                          : val;
                    }(),
                    confidence: overriddenKeys.contains('$i:${a.questionNumber}')
                        ? 1.0
                        : a.confidence,
                  ),
              ],
            ),
        ],
      );
    }

    final bool isMobileSheet = MediaQuery.sizeOf(context).width < 640;

    Widget buildModalBody(
      BuildContext modalContext,
      void Function(void Function()) refresh,
    ) {
      final ocrNotice = _identificationOcrNotice;
      final unresolvedCount = edits.entries.where((e) {
        final v = e.value.trim();
        return v == 'Ambiguous' || v == 'Multiple';
      }).length;

      final matchedStudent = _matchEnrolledStudent(
        selectedId: selectedStudentId,
        studentNumber: numberController.text,
        studentName: nameController.text,
        sectionName: sectionController.text,
      );

      final bool nameConfident = matchedStudent != null &&
          nameController.text.trim().isNotEmpty;
      final bool numberConfident = matchedStudent != null &&
          numberController.text.trim().isNotEmpty;
      final bool sectionConfident = sectionController.text.trim().isNotEmpty &&
          (matchedStudent != null || availableSections.contains(sectionController.text.trim()));

      final liveOmr = buildCurrentOmr();
      final liveScore = ScoringService.score(
        omrResult: liveOmr,
        sections: widget.sections,
      );

      final int totalItems = widget.sections.fold<int>(
        0,
        (sum, s) => sum + (int.tryParse('${s['question_count'] ?? 0}') ?? 0),
      );

      final sectionFilteredStudents = _students.where((st) {
        final sec = sectionController.text.trim().toLowerCase();
        if (sec.isEmpty) return true;
        return _studentSectionName(st).toLowerCase() == sec;
      }).toList();
      final rawDropdownStudents = sectionFilteredStudents.isNotEmpty
          ? sectionFilteredStudents
          : _students;
      final dropdownStudents = <Map<String, dynamic>>[];
      final seenStudentIds = <int>{};
      for (final st in rawDropdownStudents) {
        final sid = int.tryParse('${st['id']}');
        if (sid != null && sid > 0 && seenStudentIds.add(sid)) {
          dropdownStudents.add(st);
        }
      }

      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Modal Top Header
          Container(
            padding: const EdgeInsets.fromLTRB(24, 20, 20, 16),
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              border: Border(bottom: BorderSide(color: _kLine)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: _kNavy.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(
                        Icons.fact_check_outlined,
                        color: _kNavy,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Verify Student Answers & Scanning Details',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              color: _kNavy,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _examTitle(),
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: _kSlate,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(modalContext).pop(false),
                      icon: const Icon(Icons.close, color: _kSlate),
                      tooltip: 'Close',
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (_examSubjectDisplay().isNotEmpty)
                      _buildHeaderChip(
                        Icons.menu_book_outlined,
                        _examSubjectDisplay(),
                      ),
                    _buildHeaderChip(
                      Icons.quiz_outlined,
                      '$totalItems Items • ${_formatNum(liveScore.totalPoints)} pts',
                    ),
                    for (final sec in rawResult.sections)
                      _buildHeaderChip(
                        _sectionIcon(sec.sectionType),
                        '${sec.sectionName} (${sec.questionCount})',
                      ),
                  ],
                ),
                if (ocrNotice != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    ocrNotice,
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: _kAmberDark,
                    ),
                  ),
                ],
                if (unresolvedCount > 0) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: _kAmber.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: _kAmber.withValues(alpha: 0.5)),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.warning_amber_rounded,
                          size: 18,
                          color: _kAmberDark,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '$unresolvedCount bubble detection(s) need manual review before recording.',
                            style: const TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: _kAmberDark,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),

          // Scrollable Body: Student Details + Bubble Answer Verification
          Expanded(
            child: ColoredBox(
              color: _kBg,
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  // 1. STUDENT DETAILS SECTION
                  Container(
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: _kLine),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(
                              Icons.badge_outlined,
                              size: 20,
                              color: _kNavy,
                            ),
                            const SizedBox(width: 8),
                            const Expanded(
                              child: Text(
                                'Student Details',
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  color: _kNavy,
                                ),
                              ),
                            ),
                            _buildConfidencePill(
                              isConfident: matchedStudent != null,
                              confidentText: autoDetectedHighConfidence &&
                                      matchedStudent != null
                                  ? '96% Confident • Matched'
                                  : 'Matched in Section',
                              warningText: _students.isEmpty
                                  ? 'No Roster Loaded'
                                  : 'Select / Verify Student',
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),

                        // Quick Select from Enrolled Section Roster
                        if (dropdownStudents.isNotEmpty) ...[
                          DropdownButtonFormField<int>(
                            key: ValueKey(
                              'student-roster-dd-${seenStudentIds.contains(selectedStudentId) ? selectedStudentId : 0}-${dropdownStudents.length}',
                            ),
                            initialValue: seenStudentIds.contains(selectedStudentId)
                                ? selectedStudentId
                                : null,
                            isExpanded: true,
                            decoration: _modalInputDeco(
                              label: 'Select Enrolled Student (Quick Fill)',
                              hint:
                                  'Choose student from section roster (LAST NAME, FIRST NAME)',
                              prefixIcon: Icons.person_search_outlined,
                            ),
                            items: dropdownStudents.map((st) {
                              final sid = int.tryParse('${st['id']}') ?? 0;
                              final name = _formatStudentFullName(st);
                              final snum =
                                  st['student_number']?.toString() ?? '';
                              final sec = _studentSectionName(st);
                              return DropdownMenuItem<int>(
                                value: sid,
                                child: Text(
                                  '$name ($snum)${sec.isNotEmpty ? ' • $sec' : ''}',
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w600,
                                    color: _kNavy,
                                  ),
                                ),
                              );
                            }).toList(),
                            onChanged: (int? sid) {
                              if (sid == null) return;
                              final found = _students.firstWhere(
                                (s) => int.tryParse('${s['id']}') == sid,
                                orElse: () => <String, dynamic>{},
                              );
                              if (found.isEmpty) return;
                              refresh(() {
                                selectedStudentId = sid;
                                nameController.text =
                                    _formatStudentFullName(found);
                                numberController.text =
                                    found['student_number']?.toString() ?? '';
                                final sec = _studentSectionName(found);
                                if (sec.isNotEmpty) {
                                  selectedSection = sec;
                                  sectionController.text = sec;
                                }
                              });
                            },
                          ),
                          const SizedBox(height: 14),
                        ],

                        // Student Name + Confidence Badge
                        _buildFieldLabelWithConfidence(
                          label: 'Student Name (LAST NAME, FIRST NAME)',
                          isConfident: nameConfident,
                          confidentText: '95% Confident',
                          warningText: 'Review Needed',
                        ),
                        const SizedBox(height: 6),
                        TextFormField(
                          controller: nameController,
                          inputFormatters: const [_UpperCaseFormatter()],
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: _kNavy,
                          ),
                          decoration: _modalInputDeco(
                            hint: 'SURNAME, FIRST NAME',
                            prefixIcon: Icons.person_outline,
                          ),
                          onChanged: (v) {
                            refresh(() {
                              final matched = _matchEnrolledStudent(
                                selectedId: null,
                                studentNumber: numberController.text,
                                studentName: v,
                                sectionName: sectionController.text,
                              );
                              selectedStudentId = matched != null
                                  ? int.tryParse('${matched['id']}')
                                  : null;
                              if (matched != null &&
                                  numberController.text.trim().isEmpty) {
                                numberController.text =
                                    matched['student_number']?.toString() ?? '';
                              }
                            });
                          },
                        ),

                        const SizedBox(height: 14),

                        // Student Number + Section Row
                        LayoutBuilder(
                          builder: (context, box) {
                            final wide = box.maxWidth >= 520;
                            final numberField = Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _buildFieldLabelWithConfidence(
                                  label: 'Student Number / ID',
                                  isConfident: numberConfident,
                                  confidentText: '98% Confident',
                                  warningText: 'Review Needed',
                                ),
                                const SizedBox(height: 6),
                                TextFormField(
                                  controller: numberController,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: _kNavy,
                                  ),
                                  decoration: _modalInputDeco(
                                    hint: 'e.g. 02000416484',
                                    prefixIcon: Icons.numbers_outlined,
                                  ),
                                  onChanged: (v) {
                                    refresh(() {
                                      final matched = _matchEnrolledStudent(
                                        selectedId: null,
                                        studentNumber: v,
                                        studentName: nameController.text,
                                        sectionName: sectionController.text,
                                      );
                                      if (matched != null) {
                                        selectedStudentId =
                                            int.tryParse('${matched['id']}');
                                        nameController.text =
                                            _formatStudentFullName(matched);
                                        final sec =
                                            _studentSectionName(matched);
                                        if (sec.isNotEmpty) {
                                          selectedSection = sec;
                                          sectionController.text = sec;
                                        }
                                      } else {
                                        selectedStudentId = null;
                                      }
                                    });
                                  },
                                ),
                              ],
                            );

                            final sectionField = Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _buildFieldLabelWithConfidence(
                                  label: 'Section',
                                  isConfident: sectionConfident,
                                  confidentText: '99% Confident',
                                  warningText: 'Review Needed',
                                ),
                                const SizedBox(height: 6),
                                if (availableSections.length > 1)
                                  DropdownButtonFormField<String>(
                                    key: ValueKey(
                                      'section-dd-${availableSections.contains(selectedSection) ? selectedSection : availableSections.first}',
                                    ),
                                    initialValue: availableSections
                                            .contains(selectedSection)
                                        ? selectedSection
                                        : availableSections.first,
                                    isExpanded: true,
                                    decoration: _modalInputDeco(
                                      hint: 'Select section',
                                      prefixIcon: Icons.groups_outlined,
                                    ),
                                    items: availableSections
                                        .map(
                                          (sec) => DropdownMenuItem<String>(
                                            value: sec,
                                            child: Text(
                                              sec,
                                              style: const TextStyle(
                                                fontSize: 14,
                                                fontWeight: FontWeight.w600,
                                                color: _kNavy,
                                              ),
                                            ),
                                          ),
                                        )
                                        .toList(),
                                    onChanged: (val) {
                                      if (val == null) return;
                                      refresh(() {
                                        selectedSection = val;
                                        sectionController.text = val;
                                      });
                                    },
                                  )
                                else
                                  TextFormField(
                                    controller: sectionController,
                                    inputFormatters: const [
                                      _UpperCaseFormatter()
                                    ],
                                    style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color: _kNavy,
                                    ),
                                    decoration: _modalInputDeco(
                                      hint: 'e.g. BSIT31A',
                                      prefixIcon: Icons.groups_outlined,
                                    ),
                                    onChanged: (v) {
                                      refresh(() {
                                        selectedSection = v.trim();
                                      });
                                    },
                                  ),
                              ],
                            );

                            if (wide) {
                              return Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(child: numberField),
                                  const SizedBox(width: 12),
                                  Expanded(child: sectionField),
                                ],
                              );
                            }
                            return Column(
                              children: [
                                numberField,
                                const SizedBox(height: 14),
                                sectionField,
                              ],
                            );
                          },
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 18),

                  // 2. PART-BY-PART BUBBLE & IDENTIFICATION VERIFICATION
                  for (var sectionIndex = 0;
                      sectionIndex < rawResult.sections.length;
                      sectionIndex++) ...[
                    _buildSectionVerificationCard(
                      sectionIndex: sectionIndex,
                      section: rawResult.sections[sectionIndex],
                      sourceSection: sectionIndex < widget.sections.length
                          ? widget.sections[sectionIndex]
                          : const <String, dynamic>{},
                      edits: edits,
                      overriddenKeys: overriddenKeys,
                      idControllers: idControllers,
                      refresh: refresh,
                    ),
                    const SizedBox(height: 16),
                  ],
                ],
              ),
            ),
          ),

          // Sticky Modal Footer with Live Score & "Confirm & Record Score"
          Container(
            padding: const EdgeInsets.fromLTRB(24, 14, 24, 18),
            decoration: const BoxDecoration(
              color: Colors.white,
              border: Border(top: BorderSide(color: _kLine)),
              borderRadius: BorderRadius.vertical(bottom: Radius.circular(24)),
            ),
            child: SafeArea(
              top: false,
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'Live Verified Score',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: _kSlate,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Text(
                              '${_formatNum(liveScore.earnedPoints)} / ${_formatNum(liveScore.totalPoints)}',
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                                color: _kNavy,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: _kEmerald.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                '${liveScore.percentage.round()}%',
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: _kEmeraldDark,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(modalContext).pop(false),
                    style: TextButton.styleFrom(
                      foregroundColor: _kSlate,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                    ),
                    child: const Text(
                      'Cancel',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: unresolvedCount > 0 ||
                            (_students.isNotEmpty && matchedStudent == null)
                        ? null
                        : () => Navigator.of(modalContext).pop(true),
                    style: FilledButton.styleFrom(
                      backgroundColor: _kNavyDark,
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: _kLine,
                      disabledForegroundColor: _kSlate,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 15,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    icon: const Icon(Icons.check_circle_outline, size: 18),
                    label: const Text(
                      'Confirm & Record Score',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
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

    final bool? confirmed = isMobileSheet
        ? await showModalBottomSheet<bool>(
            context: context,
            isScrollControlled: true,
            isDismissible: false,
            enableDrag: false,
            backgroundColor: Colors.transparent,
            builder: (sheetContext) => FractionallySizedBox(
              heightFactor: 0.94,
              child: Container(
                decoration: const BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                ),
                child: StatefulBuilder(builder: buildModalBody),
              ),
            ),
          )
        : await showDialog<bool>(
            context: context,
            barrierDismissible: false,
            builder: (dialogContext) => Dialog(
              backgroundColor: Colors.white,
              surfaceTintColor: Colors.transparent,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
              insetPadding:
                  const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: 860,
                  maxHeight: MediaQuery.sizeOf(dialogContext).height * 0.88,
                ),
                child: StatefulBuilder(builder: buildModalBody),
              ),
            ),
          );

    final finalName = nameController.text.trim().toUpperCase();
    final finalNumber = numberController.text.trim();
    final finalSection = sectionController.text.trim();
    final matchedStudent = _matchEnrolledStudent(
      selectedId: selectedStudentId,
      studentNumber: finalNumber,
      studentName: finalName,
      sectionName: finalSection,
    );

    nameController.dispose();
    numberController.dispose();
    sectionController.dispose();
    for (final c in idControllers.values) {
      c.dispose();
    }

    if (confirmed != true || !mounted) return;

    final verified = buildCurrentOmr();
    final score = ScoringService.score(
      omrResult: verified,
      sections: widget.sections,
    );

    setState(() {
      _omrResult = verified;
      _scoringResult = score;
      _answersVerified = true;
    });

    await _recordVerifiedScoreAndPrompt(
      verifiedOmr: verified,
      score: score,
      matchedStudent: matchedStudent,
      studentName: matchedStudent != null
          ? _formatStudentFullName(matchedStudent)
          : finalName,
      studentNumber: matchedStudent != null
          ? (matchedStudent['student_number']?.toString() ?? finalNumber)
          : finalNumber,
      sectionName: matchedStudent != null
          ? _studentSectionName(matchedStudent)
          : finalSection,
    );
  }

  // ------------------------------------------------------------
  // STEP 5: SAVE TO POSTGRESQL SCOREBOOK & SHOW POST-SCORING MODAL
  // ------------------------------------------------------------

  Future<void> _recordVerifiedScoreAndPrompt({
    required OMRProcessingResult verifiedOmr,
    required ScoringResult score,
    required Map<String, dynamic>? matchedStudent,
    required String studentName,
    required String studentNumber,
    required String sectionName,
  }) async {
    final int? examId = int.tryParse('${widget.examId ?? _exam?['id'] ?? ''}');
    if (examId == null) return;

    setState(() => _isSavingScore = true);

    bool updatedExisting = false;
    int? recordedAttemptId;
    int? resolvedStudentId = matchedStudent != null
        ? int.tryParse('${matchedStudent['id']}')
        : null;
    int? resolvedClassId = matchedStudent != null
        ? int.tryParse(
            '${matchedStudent['class_id'] ?? (matchedStudent['class'] is Map ? (matchedStudent['class'] as Map)['id'] : '')}',
          )
        : int.tryParse('${_exam?['class_id'] ?? ''}');

    // Build flat answers payload for POST /attempts.
    final answersPayload = <Map<String, dynamic>>[];
    for (var sIdx = 0; sIdx < score.sections.length; sIdx++) {
      final sec = score.sections[sIdx];
      for (final ans in sec.answers) {
        answersPayload.add({
          if (ans.questionId != null) 'question_id': ans.questionId,
          if (sec.sectionId != null) 'section_id': sec.sectionId,
          'section_index': sIdx,
          'question_number': ans.questionNumber,
          'answer': ans.studentAnswer,
          'confidence': ans.confidence,
        });
      }
    }

    try {
      final token = await AuthStorage.getToken();
      if (token == null || token.isEmpty) {
        throw Exception('Your session has expired. Please log in again.');
      }

      final response = await MySubjectsApi.recordScannedAttempt(
        token,
        examId: examId,
        studentId: resolvedStudentId,
        classId: resolvedClassId,
        studentNumber: studentNumber,
        sectionName: sectionName,
        answers: answersPayload,
      );

      updatedExisting = response['updated_existing'] == true;
      final attemptMap = response['attempt'];
      if (attemptMap is Map) {
        recordedAttemptId = int.tryParse(
          '${attemptMap['attempt_id'] ?? attemptMap['id'] ?? ''}',
        );
        resolvedStudentId = int.tryParse(
              '${attemptMap['student_id'] ?? resolvedStudentId ?? ''}',
            ) ??
            resolvedStudentId;
        resolvedClassId = int.tryParse(
              '${attemptMap['class_id'] ?? resolvedClassId ?? ''}',
            ) ??
            resolvedClassId;
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSavingScore = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: _kRed,
          content: Text(
            'Failed to save score to scorebook: ${e.toString().replaceFirst('Exception: ', '')}',
          ),
          duration: const Duration(seconds: 6),
        ),
      );
      return;
    }

    if (!mounted) return;
    setState(() {
      _isSavingScore = false;
      _lastUpdatedExisting = updatedExisting;
      _lastRecordedStudent = {
        'id': resolvedStudentId,
        'class_id': resolvedClassId,
        'name': studentName,
        'student_number': studentNumber,
        'section': sectionName,
      };
    });

    final String? nextAction = await _showPostScoringDialog(
      score: score,
      updatedExisting: updatedExisting,
      studentName: studentName.isEmpty ? 'ENROLLED STUDENT' : studentName,
      studentNumber: studentNumber.isEmpty ? '—' : studentNumber,
      sectionName: sectionName.isEmpty ? _defaultExamSection() : sectionName,
    );

    if (!mounted || nextAction == null) return;

    if (nextAction == 'view_subjects') {
      if (resolvedClassId != null && resolvedStudentId != null) {
        mySubjectsScorebookTarget.value = MySubjectsScorebookTarget(
          classId: resolvedClassId,
          examId: examId,
          studentId: resolvedStudentId,
          studentNumber: studentNumber,
          studentName: studentName,
          sectionName: sectionName,
          attemptId: recordedAttemptId,
        );
      }
      if (widget.onViewInMySubjects != null) {
        Navigator.of(context).pop('view_subjects');
        widget.onViewInMySubjects!.call();
      } else {
        final shell = context.findAncestorWidgetOfExactType<TeacherShell>();
        if (shell != null) {
          shell.onSelect(TeacherPage.subjects);
        } else {
          Navigator.of(context).pop('view_subjects');
        }
      }
    } else if (nextAction == 'scan_next') {
      if (widget.initialImageBytes != null) {
        // Came from AnswerSheetCameraScreen -> return 'scan_next' so camera relaunches.
        Navigator.of(context).pop('scan_next');
      } else {
        _chooseAnother();
        await _pickImage();
      }
    }
  }

  Future<String?> _showPostScoringDialog({
    required ScoringResult score,
    required bool updatedExisting,
    required String studentName,
    required String studentNumber,
    required String sectionName,
  }) {
    final subjectDisplay = _examSubjectDisplay();

    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return Dialog(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 22),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Top Celebration Badge
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: _kEmerald.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.check_circle,
                          size: 16,
                          color: _kEmeraldDark,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          updatedExisting
                              ? 'Score updated in Scorebook'
                              : 'Saved to Scorebook',
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: _kEmeraldDark,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),

                  // Header
                  const Text(
                    'Score Recorded',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      color: _kNavy,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subjectDisplay.isNotEmpty
                        ? '${_examTitle()} • $subjectDisplay'
                        : _examTitle(),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w500,
                      color: _kSlate,
                    ),
                  ),
                  const SizedBox(height: 22),

                  // Circular Animated Score Ring
                  TweenAnimationBuilder<double>(
                    tween: Tween<double>(
                      begin: 0,
                      end: (score.percentage / 100.0).clamp(0.0, 1.0),
                    ),
                    duration: const Duration(milliseconds: 850),
                    curve: Curves.easeOutCubic,
                    builder: (context, progress, _) {
                      return SizedBox(
                        width: 152,
                        height: 152,
                        child: CustomPaint(
                          painter: _ScoreRingPainter(
                            progress: progress,
                            trackColor: _kLine,
                            progressColor: _kEmerald,
                          ),
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  '${_formatNum(score.earnedPoints)}/${_formatNum(score.totalPoints)}',
                                  style: const TextStyle(
                                    fontSize: 26,
                                    fontWeight: FontWeight.w800,
                                    color: _kNavy,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '${(progress * 100).round()}%',
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                    color: _kEmeraldDark,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 22),

                  // Student Info Summary Card
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: _kBg,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: _kLine),
                    ),
                    child: Row(
                      children: [
                        CircleAvatar(
                          radius: 20,
                          backgroundColor: _kNavy.withValues(alpha: 0.1),
                          child: Text(
                            studentName.isNotEmpty ? studentName[0] : 'S',
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              color: _kNavy,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                studentName,
                                style: const TextStyle(
                                  fontSize: 14.5,
                                  fontWeight: FontWeight.w700,
                                  color: _kNavy,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'ID: $studentNumber • Section: $sectionName',
                                style: const TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w500,
                                  color: _kSlate,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Part-by-Part Score Breakdown
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: _kLine),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Part-by-Part Score Breakdown',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: _kSlate,
                          ),
                        ),
                        const SizedBox(height: 10),
                        for (var i = 0; i < score.sections.length; i++) ...[
                          if (i > 0)
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 6),
                              child: Divider(height: 1, color: _kLine),
                            ),
                          Row(
                            children: [
                              Icon(
                                _sectionIcon(score.sections[i].sectionType),
                                size: 17,
                                color: _kNavy,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  score.sections[i].sectionName,
                                  style: const TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w600,
                                    color: _kNavy,
                                  ),
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: _kEmerald.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Text(
                                  '${_formatNum(score.sections[i].earnedPoints)} / ${_formatNum(score.sections[i].totalPoints)}',
                                  style: const TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w700,
                                    color: _kEmeraldDark,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 22),

                  // Action Buttons:
                  // 1. View in My Subjects (Primary Deep Navy CTA)
                  // 2. Scan Next Sheet (Navy Outline button)
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () =>
                          Navigator.of(dialogContext).pop('view_subjects'),
                      style: FilledButton.styleFrom(
                        backgroundColor: _kNavyDark,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 15),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      icon: const Icon(Icons.menu_book_outlined, size: 19),
                      label: const Text(
                        'View in My Subjects',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 14.5,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () =>
                          Navigator.of(dialogContext).pop('scan_next'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: _kNavyDark,
                        side: const BorderSide(color: _kNavyDark, width: 1.3),
                        padding: const EdgeInsets.symmetric(vertical: 15),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      icon: const Icon(
                        Icons.document_scanner_outlined,
                        size: 19,
                      ),
                      label: const Text(
                        'Scan Next Sheet',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 14.5,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // ------------------------------------------------------------
  // SECTION VERIFICATION CARD (BUBBLE RADIO TILES & IDENTIFICATION)
  // ------------------------------------------------------------

  Widget _buildSectionVerificationCard({
    required int sectionIndex,
    required OMRSectionResult section,
    required Map<String, dynamic> sourceSection,
    required Map<String, String> edits,
    required Set<String> overriddenKeys,
    required Map<String, TextEditingController> idControllers,
    required void Function(void Function()) refresh,
  }) {
    final bool isMc = section.sectionType == 'multiple_choice';
    final bool isTf = section.sectionType == 'true_false';
    final List<String> options =
        isMc ? const ['A', 'B', 'C', 'D'] : (isTf ? const ['T', 'F'] : const []);

    final List<Map<String, dynamic>> sourceQuestions =
        sourceSection['questions'] is List
            ? (sourceSection['questions'] as List)
                .whereType<Map>()
                .map((q) => Map<String, dynamic>.from(q))
                .toList()
            : const <Map<String, dynamic>>[];

    Map<String, dynamic>? findQuestion(int qNum) {
      for (final q in sourceQuestions) {
        if (int.tryParse('${q['question_number']}') == qNum) return q;
      }
      return null;
    }

    Widget buildAnswerCard(OMRAnswer answer, {bool compact = false}) {
      final key = '$sectionIndex:${answer.questionNumber}';
      final currentVal = (edits[key] ?? answer.answer).trim();
      final wasOverridden = overriddenKeys.contains(key);
      final qMeta = findQuestion(answer.questionNumber);
      final expectedKey = (qMeta?['correct_answer']?.toString() ?? '').trim();

      final bool isLowConfidence = !wasOverridden &&
          (currentVal == 'Ambiguous' ||
              currentVal == 'Multiple' ||
              currentVal == 'OCR Pending' ||
              (currentVal != 'Unanswered' &&
                  answer.confidence > 0 &&
                  answer.confidence < 0.80) ||
              (section.sectionType == 'identification' &&
                  currentVal.isEmpty));

      final bool isHighConfidence = wasOverridden ||
          (!isLowConfidence &&
              currentVal.isNotEmpty &&
              currentVal != 'Unanswered' &&
              answer.confidence >= 0.80);

      final int confPct = wasOverridden
          ? 100
          : (answer.confidence * 100).round().clamp(0, 99);

      final questionLabel = Container(
        width: 36,
        height: 28,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: _kLine),
        ),
        child: Text(
          'Q${answer.questionNumber}',
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 12.5,
            color: _kNavy,
          ),
        ),
      );

      final bubbleOptions = Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final opt in options)
            _BubbleOptionButton(
              label: isTf ? (opt == 'T' ? 'T (True)' : 'F (False)') : opt,
              selected: currentVal.toUpperCase() == opt ||
                  (isTf &&
                      ((opt == 'T' && currentVal.toUpperCase() == 'TRUE') ||
                          (opt == 'F' && currentVal.toUpperCase() == 'FALSE'))),
              isCorrectKey: expectedKey.isNotEmpty &&
                  (expectedKey.toUpperCase() == opt ||
                      (isTf &&
                          ((opt == 'T' && expectedKey.toUpperCase() == 'TRUE') ||
                              (opt == 'F' &&
                                  expectedKey.toUpperCase() == 'FALSE')))),
              onTap: () {
                refresh(() {
                  if (edits[key] == opt) {
                    edits[key] = 'Unanswered';
                  } else {
                    edits[key] = opt;
                  }
                  overriddenKeys.add(key);
                });
              },
            ),
        ],
      );

      final isOcrSuggestion = section.sectionType == 'identification' &&
          !wasOverridden &&
          !isLowConfidence &&
          answer.confidence == 0 &&
          currentVal.isNotEmpty &&
          currentVal != 'Unanswered';
      final confidencePill = _buildItemConfidencePill(
        isHighConfidence: isHighConfidence,
        isLowConfidence: isLowConfidence,
        wasOverridden: wasOverridden,
        confPct: confPct,
        currentVal: isOcrSuggestion ? 'OCR · Review' : currentVal,
      );

      return Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 10,
        ),
        decoration: BoxDecoration(
          color: isLowConfidence
              ? _kAmber.withValues(alpha: 0.06)
              : _kBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isLowConfidence
                ? _kAmber.withValues(alpha: 0.45)
                : _kLine,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (compact) ...[
              Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  questionLabel,
                  FittedBox(fit: BoxFit.scaleDown, child: confidencePill),
                ],
              ),
              const SizedBox(height: 6),
              bubbleOptions,
            ] else
              Row(
                children: [
                  questionLabel,
                  const SizedBox(width: 10),
                  if (section.sectionType != 'identification')
                    Expanded(child: bubbleOptions)
                  else
                    Expanded(
                      child: TextFormField(
                        controller: idControllers[key],
                        inputFormatters: const [_UpperCaseFormatter()],
                        style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                          color: _kNavy,
                        ),
                        decoration: InputDecoration(
                          hintText: 'TYPE ANSWER IN CAPITAL LETTERS',
                          hintStyle: const TextStyle(
                            fontSize: 12,
                            color: _kSlate,
                          ),
                          isDense: true,
                          filled: true,
                          fillColor: Colors.white,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: const BorderSide(color: _kLine),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: const BorderSide(color: _kLine),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: const BorderSide(
                              color: _kNavy,
                              width: 1.5,
                            ),
                          ),
                        ),
                        onChanged: (value) {
                          refresh(() {
                            edits[key] = value.trim().toUpperCase();
                            overriddenKeys.add(key);
                          });
                        },
                      ),
                    ),
                  const SizedBox(width: 8),
                  confidencePill,
                ],
              ),
            if (expectedKey.isNotEmpty) ...[
              const SizedBox(height: 4),
              Padding(
                padding: EdgeInsets.only(left: compact ? 0 : 46),
                child: Text(
                  'Answer Key: ${expectedKey.toUpperCase()}',
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: _kSlate,
                  ),
                ),
              ),
            ],
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _kLine),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: _kNavy.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  _sectionIcon(section.sectionType),
                  size: 18,
                  color: _kNavy,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      section.sectionName,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: _kNavy,
                      ),
                    ),
                    Text(
                      _displaySectionType(section.sectionType),
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: _kSlate,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: _kBg,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: _kLine),
                ),
                child: Text(
                  '${section.questionCount} items',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: _kSlate,
                  ),
                ),
              ),
            ],
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Divider(height: 1, color: _kLine),
          ),
          if (isMc || isTf)
            LayoutBuilder(
              builder: (context, constraints) {
                final answers = section.answers.toList()
                  ..sort((a, b) => a.questionNumber.compareTo(b.questionNumber));
                if (answers.isEmpty) return const SizedBox.shrink();

                final platform = Theme.of(context).platform;
                final isMobileOrTablet = platform == TargetPlatform.android ||
                    platform == TargetPlatform.iOS ||
                    MediaQuery.sizeOf(context).width < 1024;
                final int columnCount;
                if (section.questionCount <= 6) {
                  columnCount = 1;
                } else if (isMobileOrTablet || section.questionCount <= 10) {
                  columnCount = 2;
                } else {
                  columnCount = 3;
                }

                const columnGap = 12.0;
                final cardWidth =
                    (constraints.maxWidth - (columnCount - 1) * columnGap) /
                        columnCount;
                final compact = cardWidth < 320;
                final rowsPerColumn = answers.length ~/ columnCount;
                final extraRows = answers.length % columnCount;

                return Stack(
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (var column = 0; column < columnCount; column++) ...[
                          if (column > 0) const SizedBox(width: columnGap),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                for (final answer in answers
                                    .skip(
                                      column * rowsPerColumn +
                                          math.min(column, extraRows),
                                    )
                                    .take(
                                      rowsPerColumn +
                                          (column < extraRows ? 1 : 0),
                                    ))
                                  buildAnswerCard(answer, compact: compact),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (columnCount > 1)
                      Positioned.fill(
                        bottom: 10,
                        child: IgnorePointer(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (var column = 0;
                                  column < columnCount;
                                  column++) ...[
                                if (column > 0)
                                  const VerticalDivider(
                                    width: columnGap,
                                    thickness: 1,
                                    color: _kLine,
                                  ),
                                const Expanded(child: SizedBox.shrink()),
                              ],
                            ],
                          ),
                        ),
                      ),
                  ],
                );
              },
            )
          else
            for (final answer in section.answers) buildAnswerCard(answer),
        ],
      ),
    );
  }

  Widget _buildItemConfidencePill({
    required bool isHighConfidence,
    required bool isLowConfidence,
    required bool wasOverridden,
    required int confPct,
    required String currentVal,
  }) {
    if (isLowConfidence) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: _kAmber.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(999),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.warning_amber_rounded, size: 14, color: _kAmberDark),
            SizedBox(width: 4),
            Text(
              'Review Needed',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: _kAmberDark,
              ),
            ),
          ],
        ),
      );
    }

    if (isHighConfidence) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: _kEmerald.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle, size: 14, color: _kEmeraldDark),
            const SizedBox(width: 4),
            Text(
              wasOverridden ? 'Verified' : '$confPct% Confident',
              style: const TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: _kEmeraldDark,
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: _kLine,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        currentVal.isEmpty || currentVal == 'Unanswered'
            ? 'Unanswered'
            : currentVal,
        style: const TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
          color: _kSlate,
        ),
      ),
    );
  }

  Widget _buildFieldLabelWithConfidence({
    required String label,
    required bool isConfident,
    required String confidentText,
    required String warningText,
  }) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: _kNavy,
            ),
          ),
        ),
        _buildConfidencePill(
          isConfident: isConfident,
          confidentText: confidentText,
          warningText: warningText,
        ),
      ],
    );
  }

  Widget _buildConfidencePill({
    required bool isConfident,
    required String confidentText,
    required String warningText,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: isConfident
            ? _kEmerald.withValues(alpha: 0.14)
            : _kAmber.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isConfident ? Icons.check_circle : Icons.warning_amber_rounded,
            size: 13,
            color: isConfident ? _kEmeraldDark : _kAmberDark,
          ),
          const SizedBox(width: 4),
          Text(
            isConfident ? confidentText : warningText,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: isConfident ? _kEmeraldDark : _kAmberDark,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeaderChip(IconData icon, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: _kBg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: _kLine),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: _kSlate),
          const SizedBox(width: 5),
          Text(
            text,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: _kSlate,
            ),
          ),
        ],
      ),
    );
  }

  InputDecoration _modalInputDeco({
    String? label,
    String? hint,
    required IconData prefixIcon,
  }) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      hintStyle: const TextStyle(fontSize: 13, color: _kSlate),
      prefixIcon: Icon(prefixIcon, size: 18, color: _kSlate),
      isDense: true,
      filled: true,
      fillColor: _kBg,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: _kLine),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: _kLine),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: _kNavy, width: 1.5),
      ),
    );
  }

  String _formatNum(num v) {
    if (v == v.roundToDouble()) return v.toInt().toString();
    return v.toStringAsFixed(2);
  }

  String _displaySectionType(String type) {
    switch (type) {
      case 'multiple_choice':
        return 'Multiple Choice • Bubbles A–D';
      case 'true_false':
        return 'True or False • Bubbles T / F';
      case 'identification':
        return 'Identification • CAPITAL LETTERS';
      default:
        return type;
    }
  }

  IconData _sectionIcon(String type) {
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
      _identificationOcrNotice = null;
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
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: _kNavy,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Answer Sheet Scanner',
              style: TextStyle(
                color: _kNavy,
                fontWeight: FontWeight.w700,
                fontSize: 17,
              ),
            ),
            if (_examTitle().isNotEmpty)
              Text(
                _examTitle(),
                style: const TextStyle(
                  color: _kSlate,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
          ],
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: _kLine),
        ),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1000),
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
      return _buildEmptyUploadState();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Selected File Header Card
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _kLine),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: _kNavy.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.image_outlined,
                      color: _kNavy,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Selected Answer Sheet',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: _kNavy,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _fileName ?? 'Answer Sheet Image',
                          style: const TextStyle(
                            fontSize: 13,
                            color: _kSlate,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_detectedMarkers != null &&
                      _detectedMarkers!.length == 4)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: _kEmerald.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.check_circle,
                            size: 15,
                            color: _kEmeraldDark,
                          ),
                          SizedBox(width: 5),
                          Text(
                            '4 Corner Markers Registered',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: _kEmeraldDark,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              _buildImagePreviewWithOverlay(
                _processedImageBytes ?? _imageBytes!,
                showMarkerOverlay: _detectedMarkers != null &&
                    _processedImageBytes == null &&
                    _sourceImageWidth != null &&
                    _sourceImageHeight != null,
              ),
            ],
          ),
        ),

        const SizedBox(height: 20),

        if (_isProcessing || _isSavingScore) _buildProcessingCard(),

        if (_processedImageBytes != null && !_isProcessing) ...[
          _buildProcessedResult(),
          const SizedBox(height: 20),
        ],

        _buildActionButtons(),
      ],
    );
  }

  // ------------------------------------------------------------
  // DESKTOP / FALLBACK FILE UPLOAD ZONE
  // ------------------------------------------------------------

  Widget _buildEmptyUploadState() {
    final bool isMobileViewport = MediaQuery.sizeOf(context).width < 1024;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 48),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _kLine, width: 1.5),
        boxShadow: [
          BoxShadow(
            color: _kNavy.withValues(alpha: 0.04),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 76,
            height: 76,
            decoration: BoxDecoration(
              color: _kNavy.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Icon(
              Icons.upload_file_outlined,
              size: 38,
              color: _kNavy,
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            'Upload an Answer Sheet Image',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              color: _kNavy,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Select a JPG, JPEG, or PNG answer sheet scan. CheckMate will automatically detect the four corner registration markers, align perspective, and read bubble answers.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              color: _kSlate,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 28),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            alignment: WrapAlignment.center,
            children: [
              FilledButton.icon(
                onPressed: _pickImage,
                style: FilledButton.styleFrom(
                  backgroundColor: _kNavyDark,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 16,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                icon: const Icon(Icons.upload_outlined),
                label: const Text(
                  'Choose Answer Sheet Image',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14.5,
                  ),
                ),
              ),
              if (isMobileViewport && !kIsWeb)
                OutlinedButton.icon(
                  onPressed: _openCameraCapture,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _kNavy,
                    side: const BorderSide(color: _kNavy, width: 1.2),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 16,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  icon: const Icon(Icons.camera_alt_outlined),
                  label: const Text(
                    'Use Camera Viewfinder',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 14.5,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildImagePreviewWithOverlay(
    Uint8List bytes, {
    bool showMarkerOverlay = false,
  }) {
    return Container(
      width: double.infinity,
      height: 460,
      decoration: BoxDecoration(
        color: _kBg,
        border: Border.all(color: _kLine),
        borderRadius: BorderRadius.circular(14),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Stack(
          fit: StackFit.expand,
          children: [
            InteractiveViewer(
              minScale: 1.0,
              maxScale: 4.0,
              child: Image.memory(
                bytes,
                fit: BoxFit.contain,
                width: double.infinity,
                height: double.infinity,
              ),
            ),
            if (showMarkerOverlay && _detectedMarkers != null)
              IgnorePointer(
                child: CustomPaint(
                  painter: _MarkerCoordinatesOverlayPainter(
                    markers: _detectedMarkers!,
                    imageWidth: (_sourceImageWidth ?? 1500).toDouble(),
                    imageHeight: (_sourceImageHeight ?? 2129).toDouble(),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildProcessingCard() {
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _kLine),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              color: _kNavy,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              _isSavingScore
                  ? 'Saving verified student score to My Subjects scorebook...'
                  : 'Detecting registration markers, correcting perspective, and analyzing OMR bubbles...',
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                color: _kNavy,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProcessedResult() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_detectedMarkers != null) _buildMarkerInformation(),
        if (_omrResult != null) ...[
          const SizedBox(height: 16),
          _buildOMRSummary(_omrResult!),
        ],
        if (_scoringResult != null) ...[
          const SizedBox(height: 16),
          _buildScoringSummary(_scoringResult!),
        ],
      ],
    );
  }

  Widget _buildOMRSummary(OMRProcessingResult result) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _kLine),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: _kEmerald.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              Icons.check_circle_outline,
              color: _kEmeraldDark,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'OMR complete: ${result.answeredQuestions} of ${result.detectedQuestions} questions answered.',
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                color: _kNavy,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScoringSummary(ScoringResult result) {
    final rec = _lastRecordedStudent;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _kLine),
      ),
      child: Row(
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: _kEmerald.withValues(alpha: 0.14),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Text(
              '${result.percentage.round()}%',
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: _kEmeraldDark,
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      '${_formatNum(result.earnedPoints)} / ${_formatNum(result.totalPoints)} pts',
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        color: _kNavy,
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (rec != null)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: _kEmerald.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          _lastUpdatedExisting
                              ? 'Updated in Scorebook'
                              : 'Saved to Scorebook',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: _kEmeraldDark,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '${result.correctAnswers} correct • ${result.answeredQuestions} answered • ${result.totalQuestions} total',
                  style: const TextStyle(fontSize: 13, color: _kSlate),
                ),
                if (rec != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Student: ${rec['name']} (${rec['student_number']}) • Section: ${rec['section']}',
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: _kNavy,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------
  // REGISTRATION MARKERS CARD (TOP-LEFT, TOP-RIGHT, BOTTOM-LEFT, BOTTOM-RIGHT)
  // ------------------------------------------------------------

  Widget _buildMarkerInformation() {
    final List<RegistrationPoint> markers = _detectedMarkers!;
    // Order displayed: Top-Left (0), Top-Right (1), Bottom-Left (3), Bottom-Right (2)
    final orderedIndices = markers.length == 4
        ? const [0, 1, 3, 2]
        : List<int>.generate(markers.length, (i) => i);

    // Marker physical size is 10pt on a 397pt wide sheet (~38x38 px on 1500x2129).
    final int estMarkerPx = _sourceImageWidth != null
        ? ((_sourceImageWidth! / 397.0) * 10.0).round().clamp(12, 120)
        : 38;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _kLine),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.crop_free, size: 19, color: _kNavy),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Detected Corner Registration Markers',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                    color: _kNavy,
                  ),
                ),
              ),
              Text(
                'Normalized 1500×2129 px',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: _kSlate,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final idx in orderedIndices)
                Container(
                  width: 215,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: _kBg,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: _kLine),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: const BoxDecoration(
                          color: _kEmerald,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _markerName(idx),
                              style: const TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w700,
                                color: _kNavy,
                              ),
                            ),
                            Text(
                              '(${markers[idx].x.toStringAsFixed(1)}, ${markers[idx].y.toStringAsFixed(1)}) • $estMarkerPx×${estMarkerPx}px',
                              style: const TextStyle(
                                fontSize: 11.5,
                                color: _kSlate,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  String _markerName(int index) {
    switch (index) {
      case 0:
        return 'Top-Left';
      case 1:
        return 'Top-Right';
      case 2:
        return 'Bottom-Right';
      case 3:
        return 'Bottom-Left';
      default:
        return 'Marker ${index + 1}';
    }
  }

  // ------------------------------------------------------------
  // ACTION BUTTONS (CHOOSE ANOTHER SHEET & CONFIRM PROCESSED IMAGE)
  // ------------------------------------------------------------

  Widget _buildActionButtons() {
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        OutlinedButton.icon(
          onPressed: (_isProcessing || _isSavingScore) ? null : _chooseAnother,
          style: OutlinedButton.styleFrom(
            foregroundColor: _kNavy,
            side: const BorderSide(color: _kSlate),
            backgroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text(
            'Choose Another Sheet',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        if (_processedImageBytes == null)
          FilledButton.icon(
            onPressed: (_isProcessing || _isSavingScore) ? null : _processImage,
            style: FilledButton.styleFrom(
              backgroundColor: _kNavyDark,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            icon: const Icon(Icons.auto_fix_high, size: 18),
            label: const Text(
              'Process Answer Sheet',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        if (_processedImageBytes != null)
          FilledButton.icon(
            onPressed: (_isProcessing || _isSavingScore)
                ? null
                : (_omrResult == null
                    ? _runOMR
                    : () => _verifyDetectedAnswers(_omrResult!)),
            style: FilledButton.styleFrom(
              backgroundColor: _kNavyDark,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            icon: Icon(
              _omrResult == null
                  ? Icons.document_scanner_outlined
                  : Icons.fact_check_outlined,
              size: 18,
            ),
            label: Text(
              _omrResult == null
                  ? 'Confirm Processed Image & Detect Answers'
                  : (_answersVerified
                      ? 'Review & Update Recorded Score'
                      : 'Verify Student Answers & Record Score'),
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
      ],
    );
  }
}

// =============================================================
// INTERACTIVE BUBBLE RADIO BUTTON (FOR MULTIPLE CHOICE & TRUE/FALSE)
// =============================================================

class _BubbleOptionButton extends StatelessWidget {
  const _BubbleOptionButton({
    required this.label,
    required this.selected,
    required this.isCorrectKey,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool isCorrectKey;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color bg = selected ? _kNavyDark : Colors.white;
    final Color fg = selected ? Colors.white : _kNavy;
    final Color border = selected
        ? _kNavyDark
        : (isCorrectKey ? _kEmerald : _kLine);

    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          constraints: const BoxConstraints(minWidth: 40, minHeight: 36),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: border, width: selected ? 1.5 : 1.2),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                size: 15,
                color: selected ? _kEmerald : _kSlate,
              ),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: fg,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================
// CIRCULAR ANIMATED SCORE RING PAINTER
// =============================================================

class _ScoreRingPainter extends CustomPainter {
  const _ScoreRingPainter({
    required this.progress,
    required this.trackColor,
    required this.progressColor,
  });

  final double progress;
  final Color trackColor;
  final Color progressColor;

  @override
  void paint(Canvas canvas, Size size) {
    const double strokeWidth = 12.0;
    final Offset center = Offset(size.width / 2, size.height / 2);
    final double radius = (math.min(size.width, size.height) - strokeWidth) / 2;

    final Paint trackPaint = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    canvas.drawCircle(center, radius, trackPaint);

    if (progress > 0) {
      final Paint progressPaint = Paint()
        ..color = progressColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round;

      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -math.pi / 2,
        2 * math.pi * progress.clamp(0.0, 1.0),
        false,
        progressPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ScoreRingPainter oldDelegate) =>
      oldDelegate.progress != progress;
}

// =============================================================
// DETECTED REGISTRATION MARKER OVERLAY PAINTER
// =============================================================

class _MarkerCoordinatesOverlayPainter extends CustomPainter {
  const _MarkerCoordinatesOverlayPainter({
    required this.markers,
    required this.imageWidth,
    required this.imageHeight,
  });

  final List<RegistrationPoint> markers;
  final double imageWidth;
  final double imageHeight;

  @override
  void paint(Canvas canvas, Size size) {
    if (markers.isEmpty || imageWidth <= 0 || imageHeight <= 0) return;

    final double scale = math.min(
      size.width / imageWidth,
      size.height / imageHeight,
    );
    final double renderedW = imageWidth * scale;
    final double renderedH = imageHeight * scale;
    final double offsetX = (size.width - renderedW) / 2;
    final double offsetY = (size.height - renderedH) / 2;

    Offset mapPoint(RegistrationPoint p) =>
        Offset(offsetX + p.x * scale, offsetY + p.y * scale);

    final mapped = markers.map(mapPoint).toList();

    if (mapped.length == 4) {
      final poly = Path()
        ..moveTo(mapped[0].dx, mapped[0].dy)
        ..lineTo(mapped[1].dx, mapped[1].dy)
        ..lineTo(mapped[2].dx, mapped[2].dy)
        ..lineTo(mapped[3].dx, mapped[3].dy)
        ..close();

      canvas.drawPath(
        poly,
        Paint()
          ..color = _kEmerald.withValues(alpha: 0.85)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0,
      );
    }

    for (final pt in mapped) {
      canvas.drawCircle(
        pt,
        8,
        Paint()
          ..color = _kEmerald
          ..style = PaintingStyle.fill,
      );
      canvas.drawCircle(
        pt,
        12,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _MarkerCoordinatesOverlayPainter oldDelegate) =>
      oldDelegate.markers != markers;
}
