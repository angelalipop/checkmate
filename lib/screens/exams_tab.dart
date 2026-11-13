import 'dart:math' as math;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:printing/printing.dart';

import '../services/answer_sheet_pdf_service.dart';
import '../services/api_service.dart';
import '../services/assessment_validator.dart';
import '../services/auth_storage.dart';
import '../services/my_subjects_api_service.dart';
import '../services/question_paper_import_service.dart';
import '../services/question_paper_pdf_service.dart';
import 'login_screen.dart' show CmColors;
import 'teacher_dashboard.dart' show openTeacherScansForExam, TeacherShell, TeacherPage;
import 'my_subjects_screen.dart' show MySubjectsScreen;

// =============================================================
// CheckMate — Teacher "Exams" tab
//
// One screen, no route changes:
//   Exam list  ->  "Open builder"  ->  Exam builder (in place)
//
// Builder: sections are collapsible and hold their questions inline
// (no separate Questions screen). "Preview" for the questionnaire and
// answer sheet opens a popup (no separate preview screens).
// =============================================================

typedef _Json = Map<String, dynamic>;

/// Forces all input text into CAPITAL LETTERS (used for Identification answers).
class _UpperCaseTextFormatter extends TextInputFormatter {
  const _UpperCaseTextFormatter();

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

/// CheckMate teacher palette (same values as the sidebar palette in
/// teacher_dashboard.dart).
class _Brand {
  _Brand._();

  /// Primary: headings, primary buttons, sidebar.
  static const Color ink = Color(0xFF162137);

  /// Secondary dark surface (active / hovered items).
  static const Color inkSoft = Color(0xFF2D384D);

  /// Light blue-grey: field and button outlines, text on dark.
  static const Color mist = Color(0xFFCFD8E5);

  /// Accent: draft status and warning chips (buttons use [ink]).
  static const Color amber = Color(0xFFF7A224);
}

const double _kWide = 760;
const List<String> _kTypes = [
  'multiple_choice',
  'true_false',
  'identification',
];

// ---------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------

Future<String> _token() async {
  final t = await AuthStorage.getToken();
  if (t == null || t.isEmpty) {
    throw Exception('Your session has expired. Please log in again.');
  }
  return t;
}

String _err(Object e) => e.toString().replaceFirst('Exception: ', '');

/// Disposes controllers only after the dialog / card that was using them has
/// finished its close animation. Disposing immediately causes
/// "A TextEditingController was used after being disposed".
void _disposeControllersLater(List<TextEditingController> controllers) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    Future<void>.delayed(const Duration(milliseconds: 400), () {
      for (final c in controllers) {
        c.dispose();
      }
    });
  });
}

void _toast(BuildContext c, String m) {
  ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(m)));
}

String _typeLabel(String t) {
  switch (t) {
    case 'multiple_choice':
      return 'Multiple Choice';
    case 'true_false':
      return 'True or False';
    case 'identification':
      return 'Identification';
    default:
      return t;
  }
}

String _autoSectionName(
  int sectionOrder,
  String questionType, {
  String? subpartLetter,
  num? points,
}) {
  return QuestionPaperImportService.autoSectionName(
    sectionOrder,
    questionType,
    subpartLetter: subpartLetter,
    points: points,
  );
}

String _normalizeAnswerByType(String rawAnswer, String questionType) {
  final clean = rawAnswer.trim();
  if (clean.isEmpty) return '';
  if (questionType == 'identification') {
    return clean.toUpperCase();
  }
  if (questionType == 'multiple_choice') {
    return clean.toUpperCase();
  }
  if (questionType == 'true_false') {
    final lower = clean.toLowerCase();
    if (lower.startsWith('t')) return 'True';
    if (lower.startsWith('f')) return 'False';
  }
  return clean;
}

double _num(dynamic v) => double.tryParse(v?.toString() ?? '') ?? 0;

String _trim(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);

int? _id(dynamic v) => int.tryParse(v?.toString() ?? '');

int? _examClassId(_Json? exam) {
  if (exam == null) return null;
  final direct = _id(exam['class_id']);
  if (direct != null) return direct;
  final c = exam['class'];
  return c is Map ? _id(c['id']) : null;
}

String _classLabel(dynamic cls) {
  if (cls is! Map) return 'Unknown Class';
  final section = cls['section']?.toString() ?? 'Unknown Section';
  final subject = cls['subject'];
  if (subject is! Map) return section;
  final name = subject['name']?.toString() ?? 'Unknown Subject';
  final code = subject['code']?.toString() ?? '';
  return code.isEmpty ? '$section - $name' : '$section - $code - $name';
}

String _examSubjectAndSectionsLabel(_Json exam) {
  final cls = exam['class'];
  final subject = cls is Map ? cls['subject'] : null;
  final code = subject is Map ? (subject['code']?.toString().trim() ?? '') : '';
  final name = subject is Map ? (subject['name']?.toString().trim() ?? '') : '';
  final subjectPart = [code, name].where((s) => s.isNotEmpty).join(' · ');

  final sectionsList = <String>[];
  if (exam['sections'] is List) {
    for (final s in exam['sections'] as List) {
      final clean = s?.toString().trim() ?? '';
      if (clean.isNotEmpty && !sectionsList.contains(clean)) {
        sectionsList.add(clean);
      }
    }
  }
  if (sectionsList.isEmpty && cls is Map) {
    final sec = cls['section']?.toString().trim() ?? '';
    if (sec.isNotEmpty) sectionsList.add(sec);
  }

  final sectionPart = sectionsList.join(', ');
  if (subjectPart.isNotEmpty && sectionPart.isNotEmpty) {
    return '$subjectPart · $sectionPart';
  }
  if (subjectPart.isNotEmpty) return subjectPart;
  if (sectionPart.isNotEmpty) return sectionPart;
  return _classLabel(cls);
}

String _statusLabel(String s) {
  switch (s.toLowerCase()) {
    case 'published':
      return 'Published';
    case 'archived':
      return 'Archived';
    case 'manual':
      return 'Manual Score';
    default:
      return 'Draft';
  }
}

Color _statusColor(String s) {
  switch (s.toLowerCase()) {
    case 'published':
      return CmColors.green;
    case 'archived':
      return CmColors.slate;
    case 'manual':
      return Colors.blue;
    default:
      return _Brand.amber;
  }
}

EdgeInsets _pagePad(double w) {
  final h = w > 1160 ? (w - 1120) / 2 : (w < 600 ? 16.0 : 24.0);
  return EdgeInsets.fromLTRB(h, 24, h, 32);
}

// ---------------------------------------------------------------
// Shared styling
// ---------------------------------------------------------------

OutlineInputBorder _ob(Color c, [double w = 1]) => OutlineInputBorder(
  borderRadius: BorderRadius.circular(8),
  borderSide: BorderSide(color: c, width: w),
);

InputDecoration _deco(String hint, {Widget? prefix}) => InputDecoration(
  hintText: hint,
  hintStyle: const TextStyle(color: CmColors.slate, fontSize: 13),
  prefixIcon: prefix,
  isDense: true,
  filled: true,
  fillColor: Colors.white,
  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
  border: _ob(_Brand.mist),
  enabledBorder: _ob(_Brand.mist),
  disabledBorder: _ob(_Brand.mist),
  focusedBorder: _ob(_Brand.ink, 1.5),
);

InputDecoration _floatingDeco(
  String label, {
  String? hint,
  Widget? suffixIcon,
  bool locked = false,
}) =>
    _deco(hint ?? '').copyWith(
      labelText: label,
      floatingLabelBehavior: FloatingLabelBehavior.always,
      labelStyle: const TextStyle(
        color: CmColors.slate,
        fontSize: 13,
      ),
      floatingLabelStyle: const TextStyle(
        color: CmColors.slate,
        fontSize: 13,
      ),
      fillColor: locked ? const Color(0xFFF1F5F9) : Colors.white,
      suffixIcon: suffixIcon,
    );

const TextStyle _inputText = TextStyle(fontSize: 13.5, color: _Brand.ink);

final ButtonStyle _primaryStyle = FilledButton.styleFrom(
  backgroundColor: _Brand.ink,
  foregroundColor: Colors.white,
  minimumSize: const Size(0, 40),
  padding: const EdgeInsets.symmetric(horizontal: 16),
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
  textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5),
);

final ButtonStyle _amberStyle = FilledButton.styleFrom(
  backgroundColor: _Brand.ink,
  foregroundColor: Colors.white,
  minimumSize: const Size(0, 38),
  padding: const EdgeInsets.symmetric(horizontal: 14),
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
  textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
);

final ButtonStyle _greenSaveStyle = FilledButton.styleFrom(
  backgroundColor: CmColors.green,
  foregroundColor: Colors.white,
  minimumSize: const Size(0, 38),
  padding: const EdgeInsets.symmetric(horizontal: 14),
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
  textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
);

final ButtonStyle _outlineStyle = OutlinedButton.styleFrom(
  foregroundColor: _Brand.ink,
  side: const BorderSide(color: _Brand.mist),
  minimumSize: const Size(0, 40),
  padding: const EdgeInsets.symmetric(horizontal: 14),
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
  textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5),
);

class _Card extends StatelessWidget {
  const _Card({required this.child, this.padding = 16});
  final Widget child;
  final double padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(padding),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: CmColors.line),
      ),
      child: child,
    );
  }
}

class _Field extends StatelessWidget {
  const _Field(this.label, this.child);
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: _Brand.ink,
            ),
          ),
          const SizedBox(height: 6),
          child,
        ],
      ),
    );
  }
}

class _Spin extends StatelessWidget {
  const _Spin() : color = Colors.white;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 18,
    height: 18,
    child: CircularProgressIndicator(strokeWidth: 2, color: color),
  );
}

class _ErrorText extends StatelessWidget {
  const _ErrorText(this.message);
  final String message;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      message,
      style: TextStyle(
        fontSize: 12.5,
        color: Theme.of(context).colorScheme.error,
      ),
    ),
  );
}

class _Badge extends StatelessWidget {
  const _Badge(this.text, {this.size = 26});
  final String text;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: CmColors.bg,
      borderRadius: BorderRadius.circular(7),
    ),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 11.5,
        fontWeight: FontWeight.w800,
        color: _Brand.ink,
      ),
    ),
  );
}

class _StatusPill extends StatelessWidget {
  const _StatusPill(this.status);
  final String status;

  @override
  Widget build(BuildContext context) {
    final c = _statusColor(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: c, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            _statusLabel(status),
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              color: c == CmColors.slate
                  ? _Brand.ink
                  : HSLColor.fromColor(c).withLightness(0.28).toColor(),
            ),
          ),
        ],
      ),
    );
  }
}

/// Popup frame used by every dialog in this tab.
class _CmDialog extends StatelessWidget {
  const _CmDialog({
    required this.title,
    required this.child,
    required this.actions,
    this.subtitle,
    this.maxWidth = 460,
  });

  final String title;
  final String? subtitle;
  final Widget child;
  final List<Widget> actions;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            color: _Brand.ink,
                          ),
                        ),
                        if (subtitle != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              subtitle!,
                              style: const TextStyle(
                                fontSize: 12,
                                color: CmColors.slate,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  InkWell(
                    onTap: () => Navigator.maybePop(context),
                    child: const Padding(
                      padding: EdgeInsets.all(2),
                      child: Icon(Icons.close, size: 18, color: CmColors.slate),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Flexible(child: SingleChildScrollView(child: child)),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  for (var i = 0; i < actions.length; i++) ...[
                    if (i > 0) const SizedBox(width: 10),
                    actions[i],
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<bool> _confirm(
  BuildContext context, {
  required String title,
  required String message,
  String action = 'Delete',
}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (c) => _CmDialog(
      title: title,
      maxWidth: 400,
      actions: [
        OutlinedButton(
          style: _outlineStyle,
          onPressed: () => Navigator.pop(c, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: _primaryStyle,
          onPressed: () => Navigator.pop(c, true),
          child: Text(action),
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(
          message,
          style: const TextStyle(fontSize: 13.5, color: _Brand.ink),
        ),
      ),
    ),
  );
  return r == true;
}

// ---------------------------------------------------------------
// Subject grouping & Date/Time formatting helpers for Exam Details
// ---------------------------------------------------------------

const Map<String, String> _kAssessmentTypes = {
  'quiz': 'Quiz',
  'short_quiz': 'Short Quiz',
  'long_quiz': 'Long Quiz',
  'performance_task': 'Performance Task',
  'laboratory': 'Laboratory',
  'prelim': 'Prelim',
  'midterm': 'Midterm',
  'prefinal': 'Pre-Finals',
  'final': 'Finals',
};

const List<String> _kMonthNames = <String>[
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

String _formatFullDate(DateTime d) {
  return '${_kMonthNames[d.month - 1]} ${d.day}, ${d.year}';
}

DateTime? _tryParseFullDate(String raw) {
  final clean = raw.trim();
  if (clean.isEmpty) return null;
  final iso = DateTime.tryParse(clean);
  if (iso != null) return iso;

  for (var m = 0; m < _kMonthNames.length; m++) {
    final monthName = _kMonthNames[m];
    final shortName = monthName.substring(0, 3);
    final match = RegExp(
      '^($monthName|$shortName)[a-z]*\\.?\\s+(\\d{1,2}),?\\s+(\\d{4})\$',
      caseSensitive: false,
    ).firstMatch(clean);
    if (match != null) {
      final day = int.tryParse(match.group(2)!);
      final year = int.tryParse(match.group(3)!);
      if (day != null && year != null) {
        return DateTime(year, m + 1, day);
      }
    }
  }
  return null;
}

String _formatTimeOfDay(TimeOfDay t) {
  final hour12 = t.hourOfPeriod == 0 ? 12 : t.hourOfPeriod;
  final minStr = t.minute.toString().padLeft(2, '0');
  final period = t.period == DayPeriod.am ? 'AM' : 'PM';
  return '$hour12:$minStr $period';
}

TimeOfDay? _tryParseTimeOfDay(String raw) {
  final clean = raw.trim();
  if (clean.isEmpty) return null;
  final match = RegExp(
    r'^(\d{1,2}):(\d{2})\s*(AM|PM)?$',
    caseSensitive: false,
  ).firstMatch(clean);
  if (match == null) return null;
  var hour = int.tryParse(match.group(1)!) ?? 0;
  final minute = int.tryParse(match.group(2)!) ?? 0;
  final mer = match.group(3)?.toUpperCase();
  if (mer == 'PM' && hour < 12) hour += 12;
  if (mer == 'AM' && hour == 12) hour = 0;
  return TimeOfDay(hour: hour.clamp(0, 23), minute: minute.clamp(0, 59));
}

class _SubjectOptionGroup {
  _SubjectOptionGroup({
    required this.key,
    required this.subjectId,
    required this.code,
    required this.name,
    required this.schoolYear,
    required this.semester,
    required this.sections,
  });

  final String key;
  final int? subjectId;
  final String code;
  final String name;
  final String schoolYear;
  final String semester;
  final List<_Json> sections;

  String get displayLabel {
    final joined = [code, name].where((e) => e.isNotEmpty).join(' · ');
    return joined.isEmpty ? 'Subject' : joined;
  }

  String get formattedSchoolYear =>
      AssessmentValidator.formatSchoolYear(schoolYear);

  String get formattedSchoolTerm =>
      AssessmentValidator.formatSchoolTerm(semester);

  List<int> get classIds =>
      sections.map((c) => _id(c['id'])).whereType<int>().toList();
}

List<_SubjectOptionGroup> _buildSubjectGroups(
  List<_Json> classes, {
  _Json? fallbackExam,
}) {
  final groupsByKey = <String, _SubjectOptionGroup>{};

  void addClassRecord(_Json c) {
    final cid = _id(c['id']);
    if (cid == null) return;
    final subj = c['subject'] is Map
        ? Map<String, dynamic>.from(c['subject'] as Map)
        : <String, dynamic>{};
    final subjId = _id(subj['id']);
    final code = (subj['code']?.toString() ?? '').trim();
    final name = (subj['name']?.toString() ?? '').trim();
    final sy = (c['school_year']?.toString() ?? '').trim();
    final sem = (c['semester']?.toString() ?? '').trim();
    final yl = (c['year_level']?.toString() ?? '').trim();

    final key = '${subjId ?? code}|$name|$sy|$sem|$yl';
    final group = groupsByKey.putIfAbsent(
      key,
      () => _SubjectOptionGroup(
        key: key,
        subjectId: subjId,
        code: code,
        name: name.isEmpty ? 'Subject' : name,
        schoolYear: sy,
        semester: sem,
        sections: <_Json>[],
      ),
    );
    if (!group.sections.any((existing) => _id(existing['id']) == cid)) {
      group.sections.add(c);
    }
  }

  for (final c in classes) {
    addClassRecord(c);
  }

  if (fallbackExam != null) {
    final examCls = fallbackExam['class'];
    if (examCls is Map) {
      addClassRecord(Map<String, dynamic>.from(examCls));
    }
  }

  final out = groupsByKey.values.toList();
  for (final g in out) {
    g.sections.sort(
      (a, b) => (a['section']?.toString() ?? '').toLowerCase().compareTo(
        (b['section']?.toString() ?? '').toLowerCase(),
      ),
    );
  }
  return out;
}

// ---------------------------------------------------------------
// Create / Edit Exam Details dialog (unified with live Paper Header Preview)
// ---------------------------------------------------------------

Future<void> _saveOrShareBytes({
  required Uint8List bytes,
  required String fileName,
  String mimeType =
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
}) async {
  if (!kIsWeb) {
    try {
      final location = await getSaveLocation(suggestedName: fileName);
      if (location != null && location.path.isNotEmpty) {
        final xf = XFile.fromData(bytes, name: fileName, mimeType: mimeType);
        await xf.saveTo(location.path);
        return;
      } else if (location == null) {
        return;
      }
    } catch (_) {
      // Fall back to Printing.sharePdf when getSaveLocation is unavailable.
    }
  }
  await Printing.sharePdf(bytes: bytes, filename: fileName);
}

Future<ImportedQuestionPaper?> _pickAndParseFileFromDisk(
  BuildContext context, {
  List<QuestionnaireTemplateSectionConfig>? expectedTemplate,
}) async {
  const typeGroup = XTypeGroup(
    label: 'Questionnaire (PDF, Word, Excel, CSV, TXT, RTF, ODT, HTML)',
    extensions: QuestionPaperImportService.supportedExtensions,
  );
  final file = await openFile(
    acceptedTypeGroups: const <XTypeGroup>[typeGroup],
  );
  if (file == null) return null;

  try {
    final bytes = await file.readAsBytes();
    final parsed = QuestionPaperImportService.parseBytes(
      bytes: bytes,
      fileName: file.name,
      expectedTemplate: expectedTemplate,
    );
    if (parsed.totalQuestions == 0) {
      if (context.mounted) {
        final unreadableNote = parsed.unreadablePages.isNotEmpty
            ? ' Page(s) ${parsed.unreadablePages.join(", ")} had no selectable text.'
            : '';
        await showDialog<void>(
          context: context,
          builder: (c) => _CmDialog(
            title: 'No questions detected',
            maxWidth: 440,
            actions: [
              FilledButton(
                style: _primaryStyle,
                onPressed: () => Navigator.pop(c),
                child: const Text('OK'),
              ),
            ],
            child: Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                'Could not find numbered questions (e.g. "1. ...") or tabular question rows in "${file.name}".$unreadableNote '
                'Please make sure the uploaded file is a text-based PDF or supported document with numbered items.',
                style: const TextStyle(fontSize: 13.5, color: _Brand.ink),
              ),
            ),
          ),
        );
      }
      return null;
    }
    return parsed;
  } catch (e) {
    if (context.mounted) {
      _toast(context, 'Failed to read questionnaire: ${_err(e)}');
    }
    return null;
  }
}

/// Opens the centered "Upload Questionnaire" modal offering two paths:
/// 1. Use a template (preset selector, Add section, question type, item count,
///    points per item, live section order preview, and Download Word template).
/// 2. Upload an existing file (direct upload with full import review).
Future<ImportedQuestionPaper?> showUploadQuestionnaireModal(
  BuildContext context, {
  bool startInDirectMode = false,
  ImportedQuestionPaper? initialPaper,
}) async {
  return showDialog<ImportedQuestionPaper>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => _UploadQuestionnaireDialog(
      startInDirectMode: startInDirectMode,
      initialPaper: initialPaper,
    ),
  );
}

Future<ImportedQuestionPaper?> pickAndParseQuestionPaper(
  BuildContext context, {
  bool directFilePickerOnly = false,
}) async {
  if (directFilePickerOnly) {
    return _pickAndParseFileFromDisk(context);
  }
  return showUploadQuestionnaireModal(context);
}

class _EditableTemplateRow {
  _EditableTemplateRow({
    required this.questionType,
    required int count,
    required double points,
  }) : countController = TextEditingController(text: '$count'),
       pointsController = TextEditingController(
         text: QuestionPaperImportService.formatPoints(points),
       );

  String questionType;
  final TextEditingController countController;
  final TextEditingController pointsController;

  int get parsedCount => int.tryParse(countController.text.trim()) ?? 0;

  double get parsedPoints =>
      double.tryParse(pointsController.text.trim()) ?? 0.0;

  bool get isValid => parsedCount > 0 && parsedPoints > 0 && parsedPoints.isFinite;

  QuestionnaireTemplateSectionConfig toConfig() =>
      QuestionnaireTemplateSectionConfig(
        questionType: questionType,
        itemCount: parsedCount > 0 ? parsedCount : 0,
        pointsPerItem: parsedPoints > 0 ? parsedPoints : 1.0,
      );

  void dispose() {
    _disposeControllersLater([countController, pointsController]);
  }
}

class _UploadQuestionnaireDialog extends StatefulWidget {
  const _UploadQuestionnaireDialog({
    this.startInDirectMode = false,
    this.initialPaper,
  });

  final bool startInDirectMode;
  final ImportedQuestionPaper? initialPaper;

  @override
  State<_UploadQuestionnaireDialog> createState() =>
      _UploadQuestionnaireDialogState();
}

class _UploadQuestionnaireDialogState
    extends State<_UploadQuestionnaireDialog> {
  late bool _templateMode = !widget.startInDirectMode;
  String _selectedPreset = 'default';
  final List<_EditableTemplateRow> _rows = <_EditableTemplateRow>[];
  ImportedQuestionPaper? _reviewedPaper;
  int? _expandedReviewSectionIdx = 0;
  bool _downloadingTemplate = false;
  bool _pickingFile = false;
  String? _statusMessage;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _reviewedPaper = widget.initialPaper;
    _applyPresetConfig(
      QuestionPaperImportService.templatePresets.first.sections,
      presetId: 'default',
      resetReview: false,
    );
  }

  @override
  void dispose() {
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  void _applyPresetConfig(
    List<QuestionnaireTemplateSectionConfig> configs, {
    required String presetId,
    bool resetReview = true,
  }) {
    final oldRows = List<_EditableTemplateRow>.from(_rows);
    _rows
      ..clear()
      ..addAll(
        configs.map(
          (c) => _EditableTemplateRow(
            questionType: c.questionType,
            count: c.itemCount,
            points: c.pointsPerItem,
          ),
        ),
      );
    for (final old in oldRows) {
      old.dispose();
    }
    _selectedPreset = presetId;
    if (resetReview && _reviewedPaper != null) {
      _reviewedPaper = _reviewedPaper!.rebuildWithUpdatedSections(
        _reviewedPaper!.sections,
        expectedTemplate: _templateMode ? _currentConfigs : null,
      );
    }
  }

  List<QuestionnaireTemplateSectionConfig> get _currentConfigs =>
      _rows.map((r) => r.toConfig()).toList();

  bool get _allRowsValid =>
      _rows.isNotEmpty && _rows.every((r) => r.isValid);

  int get _totalTemplateItems =>
      _rows.fold<int>(0, (sum, r) => sum + (r.parsedCount > 0 ? r.parsedCount : 0));

  double get _totalTemplatePoints => _rows.fold<double>(
    0.0,
    (sum, r) =>
        sum +
        ((r.parsedCount > 0 && r.parsedPoints > 0)
            ? r.parsedCount * r.parsedPoints
            : 0.0),
  );

  void _onSectionRowEdited() {
    setState(() {
      _selectedPreset = 'custom';
      _errorMessage = null;
      if (_reviewedPaper != null && _templateMode) {
        _reviewedPaper = _reviewedPaper!.rebuildWithUpdatedSections(
          _reviewedPaper!.sections,
          expectedTemplate: _currentConfigs,
        );
      }
    });
  }

  Future<void> _downloadWordTemplate() async {
    if (!_allRowsValid || _totalTemplateItems <= 0 || _downloadingTemplate) {
      return;
    }
    setState(() {
      _downloadingTemplate = true;
      _errorMessage = null;
    });
    try {
      final bytes = await QuestionPaperPdfService.generateTemplateDocx(
        sections: _currentConfigs,
      );
      await _saveOrShareBytes(
        bytes: bytes,
        fileName: 'checkmate_questionnaire_template.docx',
      );
      if (!mounted) return;
      setState(() {
        _statusMessage =
            'Downloaded Word template ($_totalTemplateItems items · ${_trim(_totalTemplatePoints)} pts). '
            'Fill in the questions in Word, export as a text-based PDF, and upload it below.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = _err(e));
    } finally {
      if (mounted) setState(() => _downloadingTemplate = false);
    }
  }

  Future<void> _pickQuestionnaireFile() async {
    if (_pickingFile) return;
    setState(() {
      _pickingFile = true;
      _errorMessage = null;
    });
    try {
      final picked = await _pickAndParseFileFromDisk(
        context,
        expectedTemplate:
            (_templateMode && _allRowsValid) ? _currentConfigs : null,
      );
      if (!mounted) return;
      if (picked != null) {
        setState(() {
          _reviewedPaper = picked;
          _expandedReviewSectionIdx = 0;
          _statusMessage = null;
        });
      }
    } finally {
      if (mounted) setState(() => _pickingFile = false);
    }
  }

  Future<void> _editReviewedSection(int secIdx) async {
    final paper = _reviewedPaper;
    if (paper == null || secIdx < 0 || secIdx >= paper.sections.length) return;
    final sec = paper.sections[secIdx];
    var selectedType = sec.questionType;
    final ptsC = TextEditingController(
      text: QuestionPaperImportService.formatPoints(sec.defaultPoints),
    );
    String? err;

    final updated = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setS) => _CmDialog(
          title: 'Edit detected section',
          subtitle: sec.name,
          maxWidth: 420,
          actions: [
            OutlinedButton(
              style: _outlineStyle,
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: _primaryStyle,
              onPressed: () {
                final pts = double.tryParse(ptsC.text.trim());
                if (pts == null || pts <= 0) {
                  setS(() => err = 'Enter points greater than zero.');
                  return;
                }
                Navigator.pop(c, true);
              },
              child: const Text('Apply'),
            ),
          ],
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Field(
                'Question type',
                DropdownButtonFormField<String>(
                  initialValue: selectedType,
                  isExpanded: true,
                  style: _inputText,
                  decoration: _deco('Question type'),
                  items: [
                    for (final t in _kTypes)
                      DropdownMenuItem(value: t, child: Text(_typeLabel(t))),
                  ],
                  onChanged: (v) {
                    if (v != null) setS(() => selectedType = v);
                  },
                ),
              ),
              _Field(
                'Points per item',
                TextField(
                  controller: ptsC,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  style: _inputText,
                  decoration: _deco('1'),
                ),
              ),
              if (err != null) _ErrorText(err!),
            ],
          ),
        ),
      ),
    );

    final newPts = double.tryParse(ptsC.text.trim()) ?? sec.defaultPoints;
    _disposeControllersLater([ptsC]);

    if (updated == true && mounted) {
      final sectionsCopy = List<ImportedExamSection>.from(paper.sections);
      final updatedQs = sec.questions.map((q) {
        final currentChoices = selectedType == 'multiple_choice'
            ? (q.choices.length == 4
                  ? q.choices
                  : <String>[
                      for (var i = 0; i < 4; i++)
                        i < q.choices.length ? q.choices[i] : '',
                    ])
            : const <String>[];
        return q.copyWith(
          questionType: selectedType,
          points: newPts,
          choices: currentChoices,
          classificationAmbiguous: false,
        );
      }).toList();

      sectionsCopy[secIdx] = sec.copyWith(
        questionType: selectedType,
        defaultPoints: newPts,
        questions: updatedQs,
        hasAmbiguousMetadata: false,
      );

      setState(() {
        _reviewedPaper = paper.rebuildWithUpdatedSections(
          sectionsCopy,
          expectedTemplate:
              (_templateMode && _allRowsValid) ? _currentConfigs : null,
        );
      });
    }
  }

  Future<void> _editReviewedQuestion(int secIdx, int qIdx) async {
    final paper = _reviewedPaper;
    if (paper == null || secIdx < 0 || secIdx >= paper.sections.length) return;
    final sec = paper.sections[secIdx];
    final isNew = qIdx < 0 || qIdx >= sec.questions.length;
    final existingQ = isNew ? null : sec.questions[qIdx];

    final stemC = TextEditingController(text: existingQ?.questionText ?? '');
    final ptsC = TextEditingController(
      text: QuestionPaperImportService.formatPoints(
        existingQ?.points ?? sec.defaultPoints,
      ),
    );
    final choiceCs = List<TextEditingController>.generate(
      4,
      (i) => TextEditingController(
        text: (existingQ != null && i < existingQ.choices.length)
            ? existingQ.choices[i]
            : '',
      ),
    );
    String? err;

    final saved = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setS) => _CmDialog(
          title: isNew
              ? 'Add item to ${sec.name}'
              : 'Edit Item ${existingQ!.questionNumber}',
          subtitle: _typeLabel(sec.questionType),
          maxWidth: 480,
          actions: [
            OutlinedButton(
              style: _outlineStyle,
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: _primaryStyle,
              onPressed: () {
                if (stemC.text.trim().isEmpty) {
                  setS(() => err = 'Question text is required.');
                  return;
                }
                final pts = double.tryParse(ptsC.text.trim());
                if (pts == null || pts <= 0) {
                  setS(() => err = 'Enter points greater than zero.');
                  return;
                }
                if (sec.questionType == 'multiple_choice' &&
                    choiceCs.any((cc) => cc.text.trim().isEmpty)) {
                  setS(() => err = 'Fill in all four choices (A, B, C, D).');
                  return;
                }
                Navigator.pop(c, true);
              },
              child: const Text('Save item'),
            ),
          ],
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Field(
                'Question prompt',
                TextField(
                  controller: stemC,
                  minLines: 2,
                  maxLines: 5,
                  style: _inputText,
                  decoration: _deco('Enter question text'),
                ),
              ),
              _Field(
                'Points',
                TextField(
                  controller: ptsC,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  style: _inputText,
                  decoration: _deco('1'),
                ),
              ),
              if (sec.questionType == 'multiple_choice') ...[
                for (var i = 0; i < 4; i++)
                  _Field(
                    'Choice ${String.fromCharCode(65 + i)}',
                    TextField(
                      controller: choiceCs[i],
                      style: _inputText,
                      decoration: _deco('Choice ${String.fromCharCode(65 + i)}'),
                    ),
                  ),
              ],
              if (err != null) _ErrorText(err!),
            ],
          ),
        ),
      ),
    );

    final newStem = stemC.text.trim();
    final newPts = double.tryParse(ptsC.text.trim()) ?? sec.defaultPoints;
    final newChoices = sec.questionType == 'multiple_choice'
        ? choiceCs.map((c) => c.text.trim()).toList()
        : const <String>[];
    _disposeControllersLater([stemC, ptsC, ...choiceCs]);

    if (saved == true && mounted) {
      final sectionsCopy = List<ImportedExamSection>.from(paper.sections);
      final qList = List<ImportedExamQuestion>.from(sec.questions);
      final updatedItem = ImportedExamQuestion(
        questionNumber: existingQ?.questionNumber ?? (qList.length + 1),
        sourceQuestionNumber: null,
        questionText: newStem,
        questionType: sec.questionType,
        points: newPts,
        choices: newChoices,
        correctAnswer: existingQ?.correctAnswer,
        classificationAmbiguous: false,
      );
      if (isNew) {
        qList.add(updatedItem);
      } else {
        qList[qIdx] = updatedItem;
      }
      // Normalize source numbers in this section after manual edit/add
      for (var i = 0; i < qList.length; i++) {
        qList[i] = qList[i].copyWith(sourceQuestionNumber: i + 1);
      }
      sectionsCopy[secIdx] = sec.copyWith(
        questions: qList,
        expectedItemCount: qList.length,
      );
      setState(() {
        _reviewedPaper = paper.rebuildWithUpdatedSections(
          sectionsCopy,
          expectedTemplate:
              (_templateMode && _allRowsValid) ? _currentConfigs : null,
        );
      });
    }
  }

  void _deleteReviewedQuestion(int secIdx, int qIdx) {
    final paper = _reviewedPaper;
    if (paper == null || secIdx < 0 || secIdx >= paper.sections.length) return;
    final sec = paper.sections[secIdx];
    if (qIdx < 0 || qIdx >= sec.questions.length) return;

    final sectionsCopy = List<ImportedExamSection>.from(paper.sections);
    final qList = List<ImportedExamQuestion>.from(sec.questions)
      ..removeAt(qIdx);
    for (var i = 0; i < qList.length; i++) {
      qList[i] = qList[i].copyWith(sourceQuestionNumber: i + 1);
    }
    if (qList.isEmpty) {
      sectionsCopy.removeAt(secIdx);
    } else {
      sectionsCopy[secIdx] = sec.copyWith(
        questions: qList,
        expectedItemCount: qList.length,
      );
    }
    setState(() {
      _reviewedPaper = paper.rebuildWithUpdatedSections(
        sectionsCopy,
        expectedTemplate:
            (_templateMode && _allRowsValid) ? _currentConfigs : null,
      );
    });
  }

  void _continueToExamDetails() {
    final paper = _reviewedPaper;
    if (paper == null || paper.totalQuestions == 0) {
      setState(() => _errorMessage = 'Upload a questionnaire file first.');
      return;
    }
    if (paper.hasBlockingIssues) {
      final firstBlocking = paper.issues.firstWhere((i) => i.isBlocking);
      setState(() {
        _errorMessage =
            'Please resolve the flagged issue before continuing: ${firstBlocking.message}';
        if (firstBlocking.sectionIndex != null) {
          _expandedReviewSectionIdx = firstBlocking.sectionIndex;
        }
      });
      return;
    }
    Navigator.pop(context, paper);
  }

  @override
  Widget build(BuildContext context) {
    final resolvedTemplate = _allRowsValid
        ? QuestionPaperImportService.resolveTemplateSections(_currentConfigs)
        : const <ResolvedTemplateSection>[];

    // Calculate repeated question type subtotals in template preview
    final templateTypeCounts = <String, int>{};
    final templateTypePoints = <String, double>{};
    for (final r in resolvedTemplate) {
      templateTypeCounts[r.questionType] =
          (templateTypeCounts[r.questionType] ?? 0) + 1;
      templateTypePoints[r.questionType] =
          (templateTypePoints[r.questionType] ?? 0.0) + r.totalPoints;
    }

    return _CmDialog(
      title: 'Upload Questionnaire',
      subtitle:
          'Start from a reusable template or upload an existing questionnaire.',
      maxWidth: 680,
      actions: [
        OutlinedButton(
          style: _outlineStyle,
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        if (_reviewedPaper != null)
          OutlinedButton.icon(
            style: _outlineStyle,
            onPressed: _pickingFile ? null : _pickQuestionnaireFile,
            icon: const Icon(Icons.upload_file_outlined, size: 16),
            label: const Text('Upload different file'),
          ),
        FilledButton(
          style: _primaryStyle,
          onPressed:
              (_reviewedPaper != null && _reviewedPaper!.totalQuestions > 0)
              ? _continueToExamDetails
              : null,
          child: Text(
            _reviewedPaper != null && _reviewedPaper!.totalQuestions > 0
                ? 'Continue to Exam Details (${_reviewedPaper!.totalQuestions} items)'
                : 'Continue to Exam Details',
          ),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Mode Toggle Buttons: "Use a template" vs "Upload an existing file"
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              FilledButton(
                style: _templateMode ? _primaryStyle : _outlineStyle,
                onPressed: () {
                  if (!_templateMode) {
                    setState(() {
                      _templateMode = true;
                      _errorMessage = null;
                      if (_reviewedPaper != null && _allRowsValid) {
                        _reviewedPaper = _reviewedPaper!
                            .rebuildWithUpdatedSections(
                              _reviewedPaper!.sections,
                              expectedTemplate: _currentConfigs,
                            );
                      }
                    });
                  }
                },
                child: const Text('Use a template'),
              ),
              OutlinedButton(
                style: !_templateMode ? _primaryStyle : _outlineStyle,
                onPressed: () {
                  if (_templateMode) {
                    setState(() {
                      _templateMode = false;
                      _errorMessage = null;
                      if (_reviewedPaper != null) {
                        _reviewedPaper = _reviewedPaper!
                            .rebuildWithUpdatedSections(
                              _reviewedPaper!.sections,
                              expectedTemplate: null,
                            );
                      }
                    });
                  }
                },
                child: const Text('Upload an existing file'),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // 1. Set up the Word template (visible in Template mode)
          if (_templateMode) ...[
            _Card(
              padding: 14,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    '1. Set up the Word template',
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w800,
                      color: _Brand.ink,
                    ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    key: ValueKey('preset-$_selectedPreset'),
                    initialValue: _selectedPreset,
                    isExpanded: true,
                    style: _inputText,
                    decoration: _floatingDeco('Template'),
                    items: [
                      for (final p
                          in QuestionPaperImportService.templatePresets)
                        DropdownMenuItem<String>(
                          value: p.id,
                          child: Text(
                            p.label,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      const DropdownMenuItem<String>(
                        value: 'custom',
                        child: Text('Custom setup'),
                      ),
                    ],
                    onChanged: (v) {
                      if (v == null || v == 'custom') return;
                      final match = QuestionPaperImportService.templatePresets
                          .where((p) => p.id == v)
                          .firstOrNull;
                      if (match != null) {
                        setState(() {
                          _applyPresetConfig(match.sections, presetId: match.id);
                        });
                      }
                    },
                  ),
                  const SizedBox(height: 12),

                  // Section rows
                  for (var idx = 0; idx < _rows.length; idx++)
                    Padding(
                      key: ValueKey('tpl-row-$idx'),
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10, right: 8),
                            child: Text(
                              '${QuestionPaperImportService.subpartLetterFromIndex(idx)}.',
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 13.5,
                                color: _Brand.ink,
                              ),
                            ),
                          ),
                          Expanded(
                            flex: 4,
                            child: DropdownButtonFormField<String>(
                              initialValue: _rows[idx].questionType,
                              isExpanded: true,
                              style: _inputText,
                              decoration: _floatingDeco('Question type'),
                              items: [
                                for (final t in _kTypes)
                                  DropdownMenuItem<String>(
                                    value: t,
                                    child: Text(
                                      _typeLabel(t),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                              ],
                              onChanged: (v) {
                                if (v != null) {
                                  _rows[idx].questionType = v;
                                  _onSectionRowEdited();
                                }
                              },
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            flex: 2,
                            child: TextField(
                              controller: _rows[idx].countController,
                              keyboardType: TextInputType.number,
                              onChanged: (_) => _onSectionRowEdited(),
                              style: _inputText,
                              decoration: _floatingDeco('Items'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            flex: 2,
                            child: TextField(
                              controller: _rows[idx].pointsController,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                    decimal: true,
                                  ),
                              onChanged: (_) => _onSectionRowEdited(),
                              style: _inputText,
                              decoration: _floatingDeco('Pts / item'),
                            ),
                          ),
                          const SizedBox(width: 6),
                          IconButton(
                            tooltip:
                                'Remove section ${QuestionPaperImportService.subpartLetterFromIndex(idx)}',
                            onPressed: _rows.length <= 1
                                ? null
                                : () {
                                    final removed = _rows.removeAt(idx);
                                    removed.dispose();
                                    _onSectionRowEdited();
                                  },
                            icon: const Icon(
                              Icons.close,
                              size: 18,
                              color: CmColors.slate,
                            ),
                          ),
                        ],
                      ),
                    ),

                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      style: _outlineStyle,
                      onPressed: () {
                        _rows.add(
                          _EditableTemplateRow(
                            questionType: 'multiple_choice',
                            count: 5,
                            points: 1,
                          ),
                        );
                        _onSectionRowEdited();
                      },
                      icon: const Icon(Icons.add, size: 17),
                      label: const Text('Add section'),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Final section order & continuous numbering preview
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: CmColors.bg,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: CmColors.line),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _allRowsValid
                              ? '$_totalTemplateItems total items \u00B7 ${_trim(_totalTemplatePoints)} total points'
                              : 'Enter a positive whole item count and points greater than zero for each section.',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w800,
                            color: _allRowsValid
                                ? _Brand.ink
                                : Theme.of(context).colorScheme.error,
                          ),
                        ),
                        if (_allRowsValid && resolvedTemplate.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          for (final r in resolvedTemplate)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      r.heading,
                                      style: const TextStyle(
                                        fontSize: 12.5,
                                        fontWeight: FontWeight.w700,
                                        color: _Brand.ink,
                                      ),
                                    ),
                                  ),
                                  Text(
                                    'Items ${r.itemRangeLabel} (${r.itemCount}) \u00B7 ${_trim(r.totalPoints)} pts',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: CmColors.slate,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          for (final entry in templateTypeCounts.entries)
                            if (entry.value > 1)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(
                                  '${_typeLabel(entry.key)} subtotal: ${_trim(templateTypePoints[entry.key] ?? 0)} points',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    color: _Brand.inkSoft,
                                  ),
                                ),
                              ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.icon(
                      style: _primaryStyle,
                      onPressed:
                          (!_allRowsValid ||
                              _totalTemplateItems <= 0 ||
                              _downloadingTemplate)
                          ? null
                          : _downloadWordTemplate,
                      icon: _downloadingTemplate
                          ? const _Spin()
                          : const Icon(Icons.file_download_outlined, size: 18),
                      label: const Text('Download Word template'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Open the downloaded Word template (.docx) in Microsoft Word. '
                    'Fill in the question prompts and A\u2013D choices, keep the Part headings, '
                    'point instructions, and numbering, then export as a text-based PDF and upload it below. '
                    'Enter the answer keys in CheckMate after import.',
                    style: TextStyle(fontSize: 12, color: CmColors.slate),
                  ),
                  if (_statusMessage != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _statusMessage!,
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: CmColors.green,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 14),
          ],

          // 2. Upload and review (or 1. Upload and review in direct mode)
          _Card(
            padding: 14,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  _templateMode ? '2. Upload and review' : '1. Upload and review',
                  style: const TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w800,
                    color: _Brand.ink,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _templateMode
                      ? 'Select the completed questionnaire PDF (or Word file) to classify and review before importing.'
                      : 'Select an existing questionnaire (PDF, Word, Excel, CSV, TXT, RTF, ODT, or HTML) to classify and review.',
                  style: const TextStyle(fontSize: 12.5, color: CmColors.slate),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.icon(
                    style: _reviewedPaper == null ? _primaryStyle : _outlineStyle,
                    onPressed: _pickingFile ? null : _pickQuestionnaireFile,
                    icon: _pickingFile
                        ? const _Spin()
                        : const Icon(Icons.upload_file_outlined, size: 18),
                    label: Text(
                      _reviewedPaper == null
                          ? 'Select questionnaire file'
                          : 'Change file (${_reviewedPaper!.fileName})',
                    ),
                  ),
                ),
                if (_reviewedPaper != null) ...[
                  const SizedBox(height: 14),
                  _buildImportReviewPanel(_reviewedPaper!),
                ],
                if (_errorMessage != null) ...[
                  const SizedBox(height: 10),
                  _ErrorText(_errorMessage!),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildImportReviewPanel(ImportedQuestionPaper paper) {
    final typeSubtotals = paper.pointsSubtotalByType;
    final itemSubtotals = paper.itemCountSubtotalByType;
    final typeSectionCounts = <String, int>{};
    for (final s in paper.sections) {
      final t = QuestionPaperImportService.normalizeQuestionType(s.questionType);
      typeSectionCounts[t] = (typeSectionCounts[t] ?? 0) + 1;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Summary card
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: CmColors.bg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: CmColors.line),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.fact_check_outlined,
                    size: 18,
                    color: _Brand.ink,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${paper.fileName} \u00B7 ${paper.sections.length} ${paper.sections.length == 1 ? "section" : "sections"} '
                      '\u00B7 ${paper.totalQuestions} ${paper.totalQuestions == 1 ? "item" : "items"} '
                      '\u00B7 ${_trim(paper.totalPoints)} total points',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: _Brand.ink,
                      ),
                    ),
                  ),
                ],
              ),
              for (final entry in typeSectionCounts.entries)
                if (entry.value > 1)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      '${_typeLabel(entry.key)} subtotal across ${entry.value} sections: '
                      '${itemSubtotals[entry.key] ?? 0} items \u00B7 '
                      '${_trim(typeSubtotals[entry.key] ?? 0)} points',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: _Brand.inkSoft,
                      ),
                    ),
                  ),
              const SizedBox(height: 4),
              Text(
                paper.hasExplicitAssessmentType
                    ? 'Suggested assessment type from heading: '
                          '${_kAssessmentTypes[paper.detectedAssessmentType] ?? paper.detectedAssessmentType} '
                          '(you will confirm or change this in Exam Details).'
                    : 'No explicit assessment-type heading detected in file \u2014 '
                          'you will choose whether this is a Quiz or Major Exam in Exam Details.',
                style: const TextStyle(fontSize: 12, color: CmColors.slate),
              ),
            ],
          ),
        ),

        // Issues & Discrepancies list
        if (paper.issues.isNotEmpty) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _Brand.amber.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: _Brand.amber.withValues(alpha: 0.6)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.warning_amber_rounded,
                      size: 18,
                      color: _Brand.ink,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        paper.hasBlockingIssues
                            ? 'Review required (${paper.issues.length} ${paper.issues.length == 1 ? "issue" : "issues"} flagged)'
                            : 'Template comparison notes (${paper.issues.length})',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          color: _Brand.ink,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                for (final issue in paper.issues)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      '\u2022 ${issue.message}',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: issue.isBlocking
                            ? FontWeight.w700
                            : FontWeight.w500,
                        color: issue.isBlocking
                            ? Theme.of(context).colorScheme.error
                            : _Brand.ink,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],

        const SizedBox(height: 12),
        const Text(
          'Detected Sections & Questions (click a section to review or edit items)',
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w800,
            color: _Brand.ink,
          ),
        ),
        const SizedBox(height: 8),

        for (var sIdx = 0; sIdx < paper.sections.length; sIdx++)
          _buildReviewSectionCard(paper.sections[sIdx], sIdx),
      ],
    );
  }

  Widget _buildReviewSectionCard(ImportedExamSection sec, int sIdx) {
    final expanded = _expandedReviewSectionIdx == sIdx;
    final hasSecIssues =
        sec.hasAmbiguousMetadata || sec.questions.any((q) => q.hasIssues);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: hasSecIssues ? _Brand.amber : CmColors.line,
            width: hasSecIssues ? 1.4 : 1.0,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => setState(() {
                _expandedReviewSectionIdx = expanded ? null : sIdx;
              }),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
                child: Row(
                  children: [
                    _Badge('${sIdx + 1}'.padLeft(2, '0'), size: 28),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            sec.name,
                            style: const TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w800,
                              color: _Brand.ink,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${_typeLabel(sec.questionType)} \u00B7 '
                            'Items ${sec.itemRangeLabel} (${sec.questions.length} ${sec.questions.length == 1 ? "item" : "items"}) \u00B7 '
                            '${_trim(sec.defaultPoints)} ${sec.defaultPoints == 1 ? "pt" : "pts"}/item \u00B7 '
                            '${_trim(sec.totalPoints)} pts total',
                            style: const TextStyle(
                              fontSize: 11.5,
                              color: CmColors.slate,
                            ),
                          ),
                        ],
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () => _editReviewedSection(sIdx),
                      icon: const Icon(Icons.edit_outlined, size: 15),
                      label: const Text(
                        'Edit section',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                    Icon(
                      expanded
                          ? Icons.keyboard_arrow_down
                          : Icons.chevron_right,
                      size: 18,
                      color: CmColors.slate,
                    ),
                  ],
                ),
              ),
            ),
            if (expanded) ...[
              const Divider(height: 1, color: CmColors.line),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 280),
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: const EdgeInsets.all(12),
                  itemCount: sec.questions.length,
                  separatorBuilder: (_, _) =>
                      const Divider(height: 14, color: CmColors.line),
                  itemBuilder: (context, qIdx) {
                    final q = sec.questions[qIdx];
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Text(
                                '${q.questionNumber}. ${q.questionText.isEmpty ? "[Blank question prompt]" : q.questionText}',
                                style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w600,
                                  color: q.hasIssues
                                      ? Theme.of(context).colorScheme.error
                                      : _Brand.ink,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '${_trim(q.points)} ${q.points == 1 ? "pt" : "pts"}',
                              style: const TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w700,
                                color: CmColors.slate,
                              ),
                            ),
                            IconButton(
                              tooltip: 'Edit item ${q.questionNumber}',
                              visualDensity: VisualDensity.compact,
                              iconSize: 16,
                              onPressed: () => _editReviewedQuestion(sIdx, qIdx),
                              icon: const Icon(
                                Icons.edit_outlined,
                                color: CmColors.slate,
                              ),
                            ),
                            IconButton(
                              tooltip: 'Remove item ${q.questionNumber}',
                              visualDensity: VisualDensity.compact,
                              iconSize: 16,
                              onPressed: () =>
                                  _deleteReviewedQuestion(sIdx, qIdx),
                              icon: const Icon(
                                Icons.delete_outline,
                                color: CmColors.slate,
                              ),
                            ),
                          ],
                        ),
                        if (sec.questionType == 'multiple_choice') ...[
                          const SizedBox(height: 4),
                          Wrap(
                            spacing: 12,
                            runSpacing: 4,
                            children: [
                              for (var cIdx = 0; cIdx < 4; cIdx++)
                                Builder(
                                  builder: (context) {
                                    final letter = String.fromCharCode(
                                      65 + cIdx,
                                    );
                                    final text = cIdx < q.choices.length
                                        ? q.choices[cIdx].trim()
                                        : '';
                                    final isMissing = q.missingChoiceLetters
                                        .contains(letter);
                                    return Text(
                                      '$letter. ${text.isEmpty ? "[Missing]" : text}',
                                      style: TextStyle(
                                        fontSize: 11.5,
                                        fontWeight: isMissing
                                            ? FontWeight.w700
                                            : FontWeight.w500,
                                        color: isMissing
                                            ? Theme.of(
                                                context,
                                              ).colorScheme.error
                                            : CmColors.slate,
                                      ),
                                    );
                                  },
                                ),
                            ],
                          ),
                        ],
                      ],
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => _editReviewedQuestion(sIdx, -1),
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text(
                      'Add missing item to section',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Re-sequences CheckMate Roman-numeral Part and lettered subpart headings
/// across all sections of [examId] that use automatic `Part ...` naming.
Future<void> resequenceExamSectionHeadings({
  required String token,
  required int examId,
}) async {
  try {
    final raw = await ApiService.getExamSections(token, examId);
    final sorted = List<_Json>.from(raw)
      ..sort((a, b) {
        final oa = int.tryParse(a['section_order']?.toString() ?? '') ?? 0;
        final ob = int.tryParse(b['section_order']?.toString() ?? '') ?? 0;
        if (oa != ob) return oa.compareTo(ob);
        final ida = _id(a['id']) ?? 0;
        final idb = _id(b['id']) ?? 0;
        return ida.compareTo(idb);
      });
    final headings = QuestionPaperImportService.computeSectionHeadingsForMaps(
      sorted,
    );
    for (var i = 0; i < sorted.length && i < headings.length; i++) {
      final s = sorted[i];
      final sid = _id(s['id']);
      if (sid == null) continue;
      final currentName = (s['name']?.toString() ?? '').trim();
      final qType = s['question_type']?.toString() ?? 'multiple_choice';
      final pts = _num(s['default_points']) > 0
          ? _num(s['default_points'])
          : 1.0;
      if (currentName.isEmpty ||
          RegExp(
            r'^Part\s+[IVX\d]+[\.\:\-\u00B7\s]',
            caseSensitive: false,
          ).hasMatch(currentName)) {
        final targetName = headings[i];
        if (currentName != targetName) {
          await ApiService.updateExamSection(
            token: token,
            sectionId: sid,
            name: targetName,
            defaultPoints: pts,
            questionType: qType,
          );
        }
      }
    }
  } catch (_) {}
}

/// Imports reviewed sections and questions into [examId], preserving each
/// section as a distinct ordered section with its own Part/subpart heading,
/// question type, default points, continuous item numbers, and per-item points.
///
/// Safe to retry if a network error interrupts creation midway through:
/// existing sections at the target `section_order` and existing questions at
/// the target `question_number` are reused rather than duplicated.
Future<int> importParsedSectionsIntoExam({
  required String token,
  required int examId,
  required ImportedQuestionPaper paper,
  int startingSectionOrder = 1,
  List<Map<String, dynamic>>? existingSections,
  Map<int, List<Map<String, dynamic>>>? existingQuestionsBySection,
}) async {
  var importedCount = 0;
  final currentSections = existingSections != null
      ? List<_Json>.from(existingSections)
      : await ApiService.getExamSections(token, examId);
  currentSections.sort((a, b) {
    final oa = int.tryParse(a['section_order']?.toString() ?? '') ?? 0;
    final ob = int.tryParse(b['section_order']?.toString() ?? '') ?? 0;
    if (oa != ob) return oa.compareTo(ob);
    final ida = _id(a['id']) ?? 0;
    final idb = _id(b['id']) ?? 0;
    return ida.compareTo(idb);
  });

  // Compute starting global question number if appending to an exam that already has questions
  var baseQuestionOffset = 0;
  if (startingSectionOrder > 1 && existingQuestionsBySection != null) {
    for (final qList in existingQuestionsBySection.values) {
      for (final eq in qList) {
        final qn = int.tryParse(eq['question_number']?.toString() ?? '') ?? 0;
        if (qn > baseQuestionOffset) baseQuestionOffset = qn;
      }
    }
  }

  for (var secIdx = 0; secIdx < paper.sections.length; secIdx++) {
    final sec = paper.sections[secIdx];
    if (sec.questions.isEmpty) continue;

    final targetOrder = startingSectionOrder + secIdx;
    final defaultPts = sec.defaultPoints > 0 ? sec.defaultPoints : 1.0;
    final sectionName = sec.name.trim().isNotEmpty
        ? sec.name.trim()
        : _autoSectionName(
            targetOrder,
            sec.questionType,
            subpartLetter: sec.subpartLetter,
            points: defaultPts,
          );

    // Retry-safe check: see if a section at targetOrder was already created
    _Json? matchedSection;
    for (final existing in currentSections) {
      final existingOrder =
          int.tryParse(existing['section_order']?.toString() ?? '') ?? 0;
      if (existingOrder == targetOrder) {
        matchedSection = existing;
        break;
      }
    }

    int? sectionId = _id(matchedSection?['id']);
    if (sectionId != null) {
      try {
        await ApiService.updateExamSection(
          token: token,
          sectionId: sectionId,
          name: sectionName,
          defaultPoints: defaultPts,
          questionType: sec.questionType,
        );
      } catch (_) {}
    } else {
      final createdSec = await ApiService.createExamSection(
        token: token,
        examId: examId,
        name: sectionName,
        questionType: sec.questionType,
        sectionOrder: targetOrder,
        defaultPoints: defaultPts,
      );
      sectionId = _id(createdSec['id']);
      currentSections.add(createdSec);
    }

    if (sectionId == null) continue;

    // Fetch existing questions in this section so retries never duplicate items
    final existingQs =
        existingQuestionsBySection?[sectionId] ??
        await ApiService.getQuestions(token, sectionId);
    final existingByNumber = <int, _Json>{};
    for (final eq in existingQs) {
      final qn = int.tryParse(eq['question_number']?.toString() ?? '');
      if (qn != null) existingByNumber[qn] = eq;
    }

    for (var i = 0; i < sec.questions.length; i++) {
      final q = sec.questions[i];
      final targetQNum =
          baseQuestionOffset + (q.questionNumber > 0 ? q.questionNumber : (i + 1));
      final normalizedAnswer = q.correctAnswer == null
          ? null
          : _normalizeAnswerByType(q.correctAnswer!, sec.questionType);
      final effectivePoints = q.points > 0 ? q.points : defaultPts;
      final existingQ = existingByNumber[targetQNum];
      final existingQId = _id(existingQ?['id']);

      if (existingQ != null && existingQId != null) {
        final normalizedExistingAnswer =
            normalizedAnswer == null || normalizedAnswer.isEmpty
                ? existingQ['correct_answer']?.toString()
                : normalizedAnswer;

        await ApiService.updateQuestion(
          token: token,
          questionId: existingQId,
          questionText: q.questionText,
          points: effectivePoints,
          choices: sec.questionType == 'multiple_choice' ? q.choices : null,
          correctAnswer: normalizedExistingAnswer,
        );
      } else {
        final normalizedCreatedAnswer =
            normalizedAnswer == null || normalizedAnswer.isEmpty
                ? null
                : normalizedAnswer;

        await ApiService.createQuestion(
          token: token,
          sectionId: sectionId,
          questionNumber: targetQNum,
          questionText: q.questionText,
          points: effectivePoints,
          choices: sec.questionType == 'multiple_choice' ? q.choices : null,
          correctAnswer: normalizedCreatedAnswer,
        );
      }
      importedCount++;
    }
  }

  await resequenceExamSectionHeadings(token: token, examId: examId);
  return importedCount;
}

const gradingPeriodLabels = <String, String>{
  'prelims': 'Prelims',
  'midterm': 'Midterm',
  'pre_finals': 'Pre-Finals',
  'finals': 'Finals',
};
String? _majorGradingPeriod(String type) => switch (type) {
  'prelim' => 'prelims',
  'midterm' => 'midterm',
  'prefinal' || 'pre_finals' => 'pre_finals',
  'final' || 'finals' => 'finals',
  _ => null,
};

class AssessmentCreationResult {
  const AssessmentCreationResult(
    this.examId, {
    this.manual = false,
    this.classId,
  });
  final int examId;
  final bool manual;
  final int? classId;
}

Future<AssessmentCreationResult?> showAssessmentCreation(
  BuildContext context, {
  required List<Map<String, dynamic>> classes,
  int? initialClassId,
}) async {
  String type = 'quiz';
  String period = 'prelims';
  String? mode;
  final selected = await showDialog<bool>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, setS) => _CmDialog(
        title: 'Add assessment',
        maxWidth: 500,
        actions: [
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: _Brand.inkSoft,
              minimumSize: const Size(0, 40),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              textStyle: const TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 13.5,
              ),
            ),
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          if (!['performance_task', 'laboratory'].contains(type))
            FilledButton(
              style: _amberStyle,
              onPressed: () {
                mode = 'builder';
                Navigator.pop(c, true);
              },
              child: const Text('Continue'),
            ),
        ],
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<String>(
              initialValue: type,
              isExpanded: true,
              style: _inputText,
              decoration: _floatingDeco('Assessment Type'),
              items: [
                for (final e in _kAssessmentTypes.entries)
                  DropdownMenuItem(value: e.key, child: Text(e.value)),
              ],
              onChanged: (v) {
                if (v != null) {
                  setS(() {
                    type = v;
                    period = _majorGradingPeriod(v) ?? period;
                    mode = null;
                  });
                }
              },
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              key: ValueKey('$type-$period'),
              initialValue: period,
              isExpanded: true,
              style: _inputText,
              decoration: _floatingDeco(
                'Grading Period',
                locked: _majorGradingPeriod(type) != null,
              ),
              items: [
                for (final e in gradingPeriodLabels.entries)
                  DropdownMenuItem(value: e.key, child: Text(e.value)),
              ],
              onChanged: _majorGradingPeriod(type) != null
                  ? null
                  : (v) {
                      if (v != null) setS(() => period = v);
                    },
            ),
            const SizedBox(height: 16),
            if (['performance_task', 'laboratory'].contains(type)) ...[
              OutlinedButton.icon(
                style: _outlineStyle,
                onPressed: () {
                  mode = 'builder';
                  Navigator.pop(c, true);
                },
                icon: const Icon(Icons.edit_document),
                label: const Text('Create an Assessment'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                style: _outlineStyle,
                onPressed: () {
                  mode = 'manual';
                  Navigator.pop(c, true);
                },
                icon: const Icon(Icons.table_chart_outlined),
                label: const Text('Create Scorebook Column Only'),
              ),
            ] else
              Text(
                ['quiz', 'short_quiz', 'long_quiz'].contains(type)
                    ? 'Counts under Quizzes.'
                    : 'Counts under Major Examination.',
                style: const TextStyle(color: CmColors.slate, fontSize: 13),
              ),
          ],
        ),
      ),
    ),
  );
  if (selected != true || !context.mounted) return null;
  if (mode == 'manual') {
    return _showManualColumnForm(
      context,
      classes: classes,
      type: type,
      period: period,
      initialClassId: initialClassId,
    );
  }
  AssessmentCreationResult? manualResult;
  final id = await showExamDetailsModal(
    context,
    classes: classes,
    initialClassId: initialClassId,
    initialAssessmentType: type,
    initialGradingPeriod: period,
    onManualCreated: (r) => manualResult = r,
  );
  return manualResult ?? (id == null ? null : AssessmentCreationResult(id));
}

Future<AssessmentCreationResult?> _showManualColumnForm(
  BuildContext context, {
  required List<Map<String, dynamic>> classes,
  required String type,
  required String period,
  int? initialClassId,
}) async {
  final groups = _buildSubjectGroups(classes);
  if (groups.isEmpty) {
    _toast(context, 'No assigned subjects or sections.');
    return null;
  }
  var group = groups.firstWhere(
    (g) => g.classIds.contains(initialClassId),
    orElse: () => groups.first,
  );
  final selected = <int>{...group.classIds};
  final name = TextEditingController();
  final maximum = TextEditingController(text: '30');
  var saving = false;
  String? error;
  final result = await showDialog<AssessmentCreationResult>(
    context: context,
    barrierDismissible: false,
    builder: (c) => StatefulBuilder(
      builder: (c, setS) => PopScope(
        canPop: !saving,
        child: _CmDialog(
          title: 'Create ${_kAssessmentTypes[type]} column',
          maxWidth: 500,
          actions: [
            TextButton(
              style: TextButton.styleFrom(
                foregroundColor: _Brand.inkSoft,
                minimumSize: const Size(0, 40),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                textStyle: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 13.5,
                ),
              ),
              onPressed: saving ? null : () => Navigator.pop(c),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: _amberStyle,
              onPressed: saving
                  ? null
                  : () async {
                      final max = num.tryParse(maximum.text.trim());
                      if (name.text.trim().isEmpty ||
                          selected.isEmpty ||
                          max == null ||
                          !max.isFinite ||
                          max <= 0) {
                        setS(
                          () => error = 'Enter a name, sections, and positive maximum score.',
                        );
                        return;
                      }
                      setS(() {
                        saving = true;
                        error = null;
                      });
                      try {
                        final ids = selected.toList()..sort();
                        final record = await MySubjectsApi.createAssessment(
                          await _token(),
                          classIds: ids,
                          title: name.text.trim(),
                          assessmentType: type,
                          gradingPeriod: period,
                          creationMode: 'manual',
                          maximumScore: max,
                        );
                        if (c.mounted) {
                          Navigator.pop(
                            c,
                            AssessmentCreationResult(
                              _id(record['id'])!,
                              manual: true,
                              classId: ids.first,
                            ),
                          );
                        }
                      } catch (e) {
                        if (c.mounted) {
                          setS(() {
                            saving = false;
                            error = _err(e);
                          });
                        }
                      }
                    },
              child: Text(saving ? 'Saving…' : 'Create Column'),
            ),
          ],
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: name,
                enabled: !saving,
                style: _inputText,
                decoration: _floatingDeco('Assessment Name'),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: group.key,
                isExpanded: true,
                style: _inputText,
                decoration: _floatingDeco('Subject'),
                items: [
                  for (final g in groups)
                    DropdownMenuItem(
                      value: g.key,
                      child: Text(
                        g.displayLabel,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: saving
                    ? null
                    : (v) => setS(() {
                        group = groups.firstWhere((g) => g.key == v);
                        selected
                          ..clear()
                          ..addAll(group.classIds);
                      }),
              ),
              const SizedBox(height: 12),
              const Text(
                'Assigned Sections',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: _Brand.ink,
                ),
              ),
              const SizedBox(height: 4),
              for (final sec in group.sections)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  activeColor: _Brand.ink,
                  dense: true,
                  title: Text('${sec['section'] ?? ''}', style: _inputText),
                  value: selected.contains(_id(sec['id'])),
                  onChanged: saving
                      ? null
                      : (v) => setS(() {
                          final id = _id(sec['id'])!;
                          if (v == true) {
                            selected.add(id);
                          } else {
                            selected.remove(id);
                          }
                        }),
                ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: period,
                isExpanded: true,
                style: _inputText,
                decoration: _floatingDeco('Grading Period'),
                items: [
                  for (final e in gradingPeriodLabels.entries)
                    DropdownMenuItem(value: e.key, child: Text(e.value)),
                ],
                onChanged: saving
                    ? null
                    : (v) {
                        if (v != null) setS(() => period = v);
                      },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: maximum,
                enabled: !saving,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                style: _inputText,
                decoration: _floatingDeco('Maximum Score'),
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    error!,
                    style: const TextStyle(color: Colors.red),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
  _disposeControllersLater([name, maximum]);
  return result;
}

void _openManualScorebook(BuildContext context, Map<String, dynamic> exam) {
  final cid = _examClassId(exam);
  final eid = _id(exam['id']);
  if (cid == null || eid == null) return;
  mySubjectsScorebookTarget.value = MySubjectsScorebookTarget(
    classId: cid,
    examId: eid,
    studentId: 0,
  );
  final shell = context.findAncestorWidgetOfExactType<TeacherShell>();
  if (shell != null) {
    shell.onSelect(TeacherPage.subjects);
  } else {
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const MySubjectsScreen()));
  }
}

Future<int?> showExamDetailsModal(
  BuildContext context, {
  required List<Map<String, dynamic>> classes,
  Map<String, dynamic>? exam,
  int? initialClassId,
  ImportedQuestionPaper? initialImportedPaper,
  String? initialAssessmentType,
  String? initialGradingPeriod,
  ValueChanged<AssessmentCreationResult>? onManualCreated,
}) async {
  final editing = exam != null;
  final examId = _id(exam?['id']);
  final currentClassId = initialClassId ?? _examClassId(exam);
  var importedPaper = initialImportedPaper;

  final subjectGroups = _buildSubjectGroups(classes, fallbackExam: exam);

  _SubjectOptionGroup? activeGroup;
  if (currentClassId != null) {
    for (final g in subjectGroups) {
      if (g.classIds.contains(currentClassId)) {
        activeGroup = g;
        break;
      }
    }
  }
  if (activeGroup == null && importedPaper?.detectedSubjectName != null) {
    final detSubj = importedPaper!.detectedSubjectName!.toLowerCase();
    for (final g in subjectGroups) {
      final gName = g.name.toLowerCase();
      final gCode = g.code.toLowerCase();
      if ((gName.isNotEmpty &&
              (detSubj.contains(gName) || gName.contains(detSubj))) ||
          (gCode.isNotEmpty && detSubj.contains(gCode))) {
        activeGroup = g;
        break;
      }
    }
  }
  activeGroup ??= subjectGroups.isNotEmpty ? subjectGroups.first : null;

  // Sections currently checked for this exam.
  final initialIds = <int>{};
  final rawIds = exam?['class_ids'];
  if (rawIds is List) {
    for (final v in rawIds) {
      final n = _id(v);
      if (n != null && (activeGroup?.classIds.contains(n) ?? true)) {
        initialIds.add(n);
      }
    }
  }
  if (currentClassId != null &&
      (activeGroup?.classIds.contains(currentClassId) ?? true)) {
    initialIds.add(currentClassId);
  }
  if (initialIds.isEmpty && activeGroup != null) {
    initialIds.addAll(activeGroup.classIds);
  }
  final selected = Set<int>.of(initialIds);

  // Determine initial Assessment Type (treated separately from question type).
  // When importing a questionnaire:
  // - If initialAssessmentType was explicitly passed, use and confirm it.
  // - If the uploaded document has an explicit heading (e.g. "Midterm Examination"),
  //   prefill it as a suggestion that the teacher confirms in this step.
  // - If the uploaded document is ambiguous, ask the teacher to choose.
  final hasExplicitInitialType =
      initialAssessmentType != null && initialAssessmentType.trim().isNotEmpty;
  final hasSuggestedImportType =
      importedPaper != null && importedPaper.hasExplicitAssessmentType;
  final isAmbiguousImportType =
      !editing &&
      !hasExplicitInitialType &&
      importedPaper != null &&
      importedPaper.isAssessmentTypeAmbiguous;

  String type = AssessmentValidator.normalizeAssessmentType(
    initialAssessmentType ??
        exam?['assessment_type']?.toString() ??
        importedPaper?.detectedAssessmentType,
    title: exam?['title']?.toString() ?? importedPaper?.detectedQuizTitle,
    description: exam?['description']?.toString(),
  );
  if (!_kAssessmentTypes.containsKey(type) && !(editing && type == 'other')) {
    type = 'quiz';
  }
  String? selectedTypeValue = isAmbiguousImportType ? null : type;
  var gradingPeriod =
      initialGradingPeriod ?? exam?['grading_period']?.toString();
  if (selectedTypeValue != null) {
    gradingPeriod = _majorGradingPeriod(selectedTypeValue) ?? gradingPeriod;
  }
  var classificationConfirmed = editing
      ? _kAssessmentTypes.containsKey(exam['assessment_type'])
      : (!isAmbiguousImportType);
  int? createdExamIdForRetry;

  // Initial Quiz Name (for Quiz / Short Quiz / Long Quiz / Other).
  final rawExistingTitle = (exam?['title']?.toString() ??
          importedPaper?.detectedQuizTitle ??
          '')
      .trim();
  final isExistingTitleFormalMajor = const {
    'preliminary examination',
    'midterm examination',
    'pre-final examination',
    'final examination',
  }.contains(rawExistingTitle.toLowerCase());

  final quizNameC = TextEditingController(
    text: (!AssessmentValidator.isMajorExamination(type) &&
            !isExistingTitleFormalMajor)
        ? rawExistingTitle
        : '',
  );

  // Initial Major Exam fields (Exam day, Exam date, Start time, End time, Reference no.).
  final parsedHeader = ExamHeaderDetails.fromExam(exam);
  final examDayC = TextEditingController(
    text: parsedHeader.examDay.isNotEmpty
        ? parsedHeader.examDay
        : (importedPaper?.detectedExamDay ?? ''),
  );
  var examDateText = parsedHeader.examDate.isNotEmpty
      ? parsedHeader.examDate
      : (importedPaper?.detectedExamDate ?? '');
  var startTimeText = parsedHeader.startTime.isNotEmpty
      ? parsedHeader.startTime
      : (importedPaper?.detectedStartTime ?? '');
  var endTimeText = parsedHeader.endTime.isNotEmpty
      ? parsedHeader.endTime
      : (importedPaper?.detectedEndTime ?? '');
  final refNoC = TextEditingController(
    text: parsedHeader.referenceNo.isNotEmpty
        ? parsedHeader.referenceNo
        : (importedPaper?.detectedReferenceNo ?? ''),
  );

  // Initial Instructions (pre-filled with default STI Notice & instructions when empty).
  final rawInstructions = (exam?['instructions']?.toString() ??
          importedPaper?.detectedInstructions ??
          '')
      .trim();
  final instC = TextEditingController(
    text: rawInstructions.isNotEmpty
        ? rawInstructions
        : QuestionPaperPdfService.defaultInstructionsText,
  );

  bool saving = false;
  String? error;

  final result = await showDialog<int>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setS) {
        final isMajor = AssessmentValidator.isMajorExamination(type);
        final siblings = activeGroup?.sections ?? const <_Json>[];
        final subtitle = activeGroup?.displayLabel ?? 'Examination information';
        final schoolYearStr =
            activeGroup?.formattedSchoolYear ??
            AssessmentValidator.formatSchoolYear(exam?['school_year']);
        final schoolTermStr =
            activeGroup?.formattedSchoolTerm ??
            AssessmentValidator.formatSchoolTerm(exam?['semester']);

        final currentHeaderDetails = ExamHeaderDetails(
          examDay: examDayC.text.trim(),
          examDate: examDateText.trim(),
          startTime: startTimeText.trim(),
          endTime: endTimeText.trim(),
          referenceNo: refNoC.text.trim(),
        );

        final effectiveTitle = isMajor
            ? AssessmentValidator.formalExaminationTitle(type)
            : (quizNameC.text.trim().isNotEmpty
                  ? quizNameC.text.trim()
                  : (_kAssessmentTypes[type] ?? 'Quiz'));

        Future<void> pickExamDate() async {
          final now = DateTime.now();
          final initial = _tryParseFullDate(examDateText) ?? now;
          final picked = await showDatePicker(
            context: dialogContext,
            initialDate: initial,
            firstDate: DateTime(2020),
            lastDate: DateTime(2035),
          );
          if (picked != null) {
            setS(() => examDateText = _formatFullDate(picked));
          }
        }

        Future<void> pickTime({required bool isStart}) async {
          final currentText = isStart ? startTimeText : endTimeText;
          final initial =
              _tryParseTimeOfDay(currentText) ??
              (isStart
                  ? const TimeOfDay(hour: 8, minute: 0)
                  : const TimeOfDay(hour: 9, minute: 15));
          final picked = await showTimePicker(
            context: dialogContext,
            initialTime: initial,
          );
          if (picked != null) {
            setS(() {
              if (isStart) {
                startTimeText = _formatTimeOfDay(picked);
              } else {
                endTimeText = _formatTimeOfDay(picked);
              }
            });
          }
        }

        Future<void> save() async {
          if (selectedTypeValue == null ||
              gradingPeriod == null ||
              !classificationConfirmed) {
            setS(
              () => error =
                  'Please choose and confirm an assessment type and grading period.',
            );
            return;
          }
          if (siblings.isNotEmpty && selected.isEmpty) {
            setS(() => error = 'Choose at least one section.');
            return;
          }
          if (!isMajor && quizNameC.text.trim().isEmpty) {
            setS(() => error = 'Assessment name is required.');
            return;
          }

          final finalTitle = isMajor
              ? AssessmentValidator.formalExaminationTitle(type)
              : quizNameC.text.trim();

          final finalDescription = isMajor
              ? currentHeaderDetails.toDescriptionString()
              : '';

          final sortedClassIds = selected.toList()..sort();
          final primaryClassId = sortedClassIds.isNotEmpty
              ? sortedClassIds.first
              : (currentClassId ?? _id(siblings.firstOrNull?['id']));

          if (primaryClassId == null) {
            setS(() => error = 'Please select a subject and section.');
            return;
          }

          setS(() {
            saving = true;
            error = null;
          });
          try {
            final token = await _token();
            final cleanInst = instC.text.trim();

            int? savedExamId = examId ?? createdExamIdForRetry;
            if (editing || savedExamId != null) {
              if (savedExamId == null) throw Exception('Invalid exam ID.');
              await ApiService.updateExam(
                token: token,
                examId: savedExamId,
                title: finalTitle,
                assessmentType: type,
                gradingPeriod: gradingPeriod,
                classId: primaryClassId,
                classIds: sortedClassIds,
                description: finalDescription.isEmpty ? null : finalDescription,
                instructions: cleanInst.isEmpty ? null : cleanInst,
              );
            } else {
              final created = await ApiService.createExam(
                token: token,
                classId: primaryClassId,
                classIds: sortedClassIds,
                assessmentType: type,
                gradingPeriod: gradingPeriod,
                title: finalTitle,
                description: finalDescription.isEmpty ? null : finalDescription,
                instructions: cleanInst.isEmpty ? null : cleanInst,
                status: 'draft',
              );
              savedExamId = _id(created['id']) ?? 0;
              if (savedExamId > 0) {
                createdExamIdForRetry = savedExamId;
              }
            }
            if (!editing && importedPaper != null && savedExamId > 0) {
              await importParsedSectionsIntoExam(
                token: token,
                examId: savedExamId,
                paper: importedPaper!,
              );
            }
            if (dialogContext.mounted) {
              Navigator.pop(dialogContext, savedExamId);
            }
          } catch (e) {
            setS(() {
              saving = false;
              error = _err(e);
            });
          }
        }

        Widget sectionRow(_Json sec) {
          final secId = _id(sec['id'])!;
          final count = _id(sec['student_count']) ?? 0;
          final enabled = !saving;

          void toggle(bool on) => setS(() {
            if (on) {
              selected.add(secId);
            } else {
              selected.remove(secId);
            }
          });

          return InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: enabled ? () => toggle(!selected.contains(secId)) : null,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 40),
              child: Row(
                children: [
                  Checkbox(
                    value: selected.contains(secId),
                    activeColor: _Brand.ink,
                    onChanged: enabled ? (v) => toggle(v == true) : null,
                  ),
                  Expanded(
                    child: Text(
                      sec['section']?.toString() ?? 'Section',
                      style: _inputText.copyWith(fontSize: 14),
                    ),
                  ),
                  Text(
                    '$count ${count == 1 ? 'student' : 'students'}',
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: CmColors.slate,
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        Widget pickerField({
          required String label,
          required String value,
          required String placeholder,
          required IconData icon,
          required VoidCallback onTap,
          VoidCallback? onClear,
        }) {
          return InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: saving ? null : onTap,
            child: InputDecorator(
              decoration: _floatingDeco(
                label,
                hint: placeholder,
                suffixIcon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (value.isNotEmpty && onClear != null)
                      InkWell(
                        onTap: saving ? null : onClear,
                        child: const Padding(
                          padding: EdgeInsets.all(4),
                          child: Icon(
                            Icons.clear,
                            size: 15,
                            color: CmColors.slate,
                          ),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.only(right: 10),
                      child: Icon(icon, size: 17, color: CmColors.slate),
                    ),
                  ],
                ),
              ),
              child: Text(
                value.isEmpty ? placeholder : value,
                overflow: TextOverflow.ellipsis,
                style: value.isEmpty
                    ? const TextStyle(color: CmColors.slate, fontSize: 13)
                    : _inputText,
              ),
            ),
          );
        }

        Widget lockedField({required String label, required String value}) {
          return InputDecorator(
            decoration: _floatingDeco(label, locked: true),
            child: Text(
              value,
              overflow: TextOverflow.ellipsis,
              style: _inputText.copyWith(color: CmColors.slate),
            ),
          );
        }

        Widget paperHeaderPreview() {
          final subjName = activeGroup?.name ?? 'Subject Name';
          final dateLine = currentHeaderDetails.scheduleDateLine;
          final timeLine = currentHeaderDetails.scheduleTimeLine;
          final refLine = currentHeaderDetails.referenceNo;
          final termAndSy = '$schoolTermStr, $schoolYearStr';

          return Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
            decoration: BoxDecoration(
              color: CmColors.bg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: _Brand.mist),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'PAPER HEADER PREVIEW',
                        style: TextStyle(
                          fontSize: 10.5,
                          letterSpacing: 0.7,
                          fontWeight: FontWeight.w800,
                          color: CmColors.slate,
                        ),
                      ),
                    ),
                    if (isMajor && refLine.isNotEmpty)
                      Text(
                        '$refLine · Page 1',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: _Brand.ink,
                        ),
                      )
                    else
                      const Text(
                        'Page 1',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: _Brand.ink,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  subjName,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: _Brand.ink,
                  ),
                ),
                if (isMajor) ...[
                  if (dateLine.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        dateLine,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 11.5,
                          color: _Brand.inkSoft,
                        ),
                      ),
                    ),
                  if (timeLine.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Text(
                        timeLine,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 11.5,
                          color: _Brand.inkSoft,
                        ),
                      ),
                    ),
                  const SizedBox(height: 6),
                  Text(
                    termAndSy,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                      color: _Brand.ink,
                    ),
                  ),
                  Text(
                    effectiveTitle,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                      color: _Brand.ink,
                    ),
                  ),
                ] else ...[
                  const SizedBox(height: 6),
                  Text(
                    effectiveTitle,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                      color: _Brand.ink,
                    ),
                  ),
                ],
              ],
            ),
          );
        }

        return _CmDialog(
          title: editing
              ? 'Edit Exam Details'
              : (importedPaper != null
                    ? 'Upload Questionnaire'
                    : 'Create Exam'),
          subtitle: subtitle,
          maxWidth: 500,
          actions: [
            TextButton(
              style: TextButton.styleFrom(
                foregroundColor: _Brand.inkSoft,
                minimumSize: const Size(0, 40),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                textStyle: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 13.5,
                ),
              ),
              onPressed: saving
                  ? null
                  : () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: _amberStyle,
              onPressed: saving ? null : save,
              child: saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: _Brand.ink,
                      ),
                    )
                  : Text(
                      editing
                          ? 'Save changes'
                          : (importedPaper != null
                                ? 'Create & import (${importedPaper!.totalQuestions} items)'
                                : 'Create exam'),
                    ),
            ),
          ],
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (importedPaper != null) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: CmColors.green.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: CmColors.green.withValues(alpha: 0.4),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(
                            Icons.upload_file_outlined,
                            size: 20,
                            color: _Brand.ink,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  importedPaper!.fileName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    color: _Brand.ink,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '${importedPaper!.totalQuestions} questions across '
                                  '${importedPaper!.sections.length} '
                                  '${importedPaper!.sections.length == 1 ? "section" : "sections"} '
                                  '· ${_trim(importedPaper!.totalPoints)} total points.',
                                  style: const TextStyle(
                                    fontSize: 11.5,
                                    color: CmColors.slate,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          TextButton(
                            onPressed: saving
                                ? null
                                : () async {
                                    final reviewed =
                                        await showUploadQuestionnaireModal(
                                          dialogContext,
                                          initialPaper: importedPaper,
                                        );
                                    if (reviewed != null) {
                                      setS(() {
                                        importedPaper = reviewed;
                                        if (reviewed.detectedAssessmentType !=
                                                null &&
                                            _kAssessmentTypes.containsKey(
                                              reviewed.detectedAssessmentType,
                                            )) {
                                          type =
                                              reviewed.detectedAssessmentType!;
                                          selectedTypeValue = type;
                                          classificationConfirmed = true;
                                          gradingPeriod =
                                              _majorGradingPeriod(type) ??
                                              gradingPeriod;
                                        }
                                        if (reviewed.detectedQuizTitle !=
                                                null &&
                                            !AssessmentValidator.isMajorExamination(
                                              type,
                                            )) {
                                          quizNameC.text =
                                              reviewed.detectedQuizTitle!;
                                        }
                                        if (reviewed.detectedExamDay != null) {
                                          examDayC.text =
                                              reviewed.detectedExamDay!;
                                        }
                                        if (reviewed.detectedExamDate != null) {
                                          examDateText =
                                              reviewed.detectedExamDate!;
                                        }
                                        if (reviewed.detectedStartTime !=
                                            null) {
                                          startTimeText =
                                              reviewed.detectedStartTime!;
                                        }
                                        if (reviewed.detectedEndTime != null) {
                                          endTimeText =
                                              reviewed.detectedEndTime!;
                                        }
                                        if (reviewed.detectedReferenceNo !=
                                            null) {
                                          refNoC.text =
                                              reviewed.detectedReferenceNo!;
                                        }
                                      });
                                    }
                                  },
                            child: const Text(
                              'Review / Change',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      for (final sec in importedPaper!.sections)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            '• ${sec.name} (Items ${sec.itemRangeLabel} · ${_trim(sec.totalPoints)} pts)',
                            style: const TextStyle(
                              fontSize: 11.5,
                              color: _Brand.inkSoft,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                if (hasSuggestedImportType && selectedTypeValue != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Text(
                      'Suggested from document heading: ${_kAssessmentTypes[selectedTypeValue] ?? selectedTypeValue}. '
                      'Confirm or change the Assessment Type below.',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: CmColors.green,
                      ),
                    ),
                  )
                else if (selectedTypeValue == null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Text(
                      'Assessment type is not specified in the uploaded document. '
                      'Please choose whether this questionnaire is a Quiz or Major Exam below.',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: _Brand.inkSoft,
                      ),
                    ),
                  ),
              ],
              // 1. Type dropdown (top)
              DropdownButtonFormField<String>(
                key: ValueKey('assessment-type-$selectedTypeValue'),
                initialValue: selectedTypeValue,
                isExpanded: true,
                style: _inputText,
                decoration: _floatingDeco(
                  'Assessment Type',
                  hint: 'Select assessment type',
                ),
                items: [
                  if (editing && type == 'other')
                    const DropdownMenuItem<String>(
                      value: 'other',
                      child: Text('Other (historical)'),
                    ),
                  for (final e in _kAssessmentTypes.entries)
                    DropdownMenuItem<String>(
                      value: e.key,
                      child: Text(e.value),
                    ),
                ],
                onChanged: saving
                    ? null
                    : (v) {
                        if (v != null) {
                          setS(() {
                            type = v;
                            selectedTypeValue = v;
                            classificationConfirmed = true;
                            gradingPeriod =
                                _majorGradingPeriod(v) ??
                                gradingPeriod ??
                                'prelims';
                            error = null;
                          });
                        }
                      },
              ),
              const SizedBox(height: 14),

              DropdownButtonFormField<String>(
                key: ValueKey('period-$type-$gradingPeriod'), initialValue:gradingPeriod,
                decoration:_floatingDeco('Grading Period',hint:'Select period'),
                items:[for(final e in gradingPeriodLabels.entries)DropdownMenuItem(value:e.key,child:Text(e.value))],
                onChanged:saving||_majorGradingPeriod(type)!=null?null:(v)=>setS(()=>gradingPeriod=v),
              ),
              const SizedBox(height:14),
              if(!editing && importedPaper==null && onManualCreated!=null && ['performance_task','laboratory'].contains(type))...[
                OutlinedButton.icon(onPressed:saving?null:()async{
                  final result=await _showManualColumnForm(dialogContext,classes:classes,type:type,period:gradingPeriod??'prelims',initialClassId:selected.firstOrNull);
                  if(result!=null && dialogContext.mounted){onManualCreated(result);Navigator.pop(dialogContext,result.examId);}
                },icon:const Icon(Icons.table_chart_outlined),label:const Text('Create Scorebook Column Only')),
                const SizedBox(height:14),
              ],
              // 2. Subject name dropdown
              if (subjectGroups.isNotEmpty) ...[
                DropdownButtonFormField<String>(
                  key: ValueKey(activeGroup?.key),
                  initialValue: activeGroup?.key,
                  isExpanded: true,
                  style: _inputText,
                  decoration: _floatingDeco(
                    'Subject name',
                    hint: 'Select subject',
                  ),
                  items: [
                    for (final g in subjectGroups)
                      DropdownMenuItem<String>(
                        value: g.key,
                        child: Text(
                          g.displayLabel,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: saving
                      ? null
                      : (v) {
                          if (v == null) return;
                          final found = subjectGroups
                              .where((g) => g.key == v)
                              .firstOrNull;
                          if (found != null) {
                            setS(() {
                              activeGroup = found;
                              selected
                                ..clear()
                                ..addAll(found.classIds);
                            });
                          }
                        },
                ),
                const SizedBox(height: 14),
              ],

              // 3. Fields that depend on Type
              if (!isMajor) ...[
                TextField(
                  controller: quizNameC,
                  enabled: !saving,
                  onChanged: (_) => setS(() {}),
                  style: _inputText,
                  decoration: _floatingDeco(
                    ['performance_task','laboratory'].contains(type)?'Assessment name':'Quiz name',
                    hint: ['performance_task','laboratory'].contains(type)?'Enter assessment name':'e.g. Long Quiz 1 - Loops',
                  ),
                ),
              ] else ...[
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: examDayC,
                        enabled: !saving,
                        keyboardType: TextInputType.number,
                        onChanged: (_) => setS(() {}),
                        style: _inputText,
                        decoration: _floatingDeco('Exam day', hint: 'e.g. 1'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: pickerField(
                        label: 'Exam date',
                        value: examDateText,
                        placeholder: 'Select date',
                        icon: Icons.calendar_today_outlined,
                        onTap: pickExamDate,
                        onClear: () => setS(() => examDateText = ''),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: pickerField(
                        label: 'Start time',
                        value: startTimeText,
                        placeholder: '8:00 AM',
                        icon: Icons.access_time_outlined,
                        onTap: () => pickTime(isStart: true),
                        onClear: () => setS(() => startTimeText = ''),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: pickerField(
                        label: 'End time',
                        value: endTimeText,
                        placeholder: '9:15 AM',
                        icon: Icons.access_time_outlined,
                        onTap: () => pickTime(isStart: false),
                        onClear: () => setS(() => endTimeText = ''),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: refNoC,
                  enabled: !saving,
                  onChanged: (_) => setS(() {}),
                  style: _inputText,
                  decoration: _floatingDeco(
                    'Reference no.',
                    hint: '1000014607 - IT2511',
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: lockedField(
                        label: 'School year',
                        value: schoolYearStr,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: lockedField(
                        label: 'School term',
                        value: schoolTermStr,
                      ),
                    ),
                  ],
                ),
              ],

              // 4. Sections checkbox list
              if (siblings.isNotEmpty) ...[
                const SizedBox(height: 18),
                const Text(
                  'Sections',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: _Brand.ink,
                  ),
                ),
                const SizedBox(height: 4),
                for (final sec in siblings)
                  if (_id(sec['id']) != null) sectionRow(sec),
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text(
                    'Checked sections are pre-selected when you assign & publish.',
                    style: TextStyle(fontSize: 12, color: CmColors.slate),
                  ),
                ),
              ],

              // 5. Instructions (~6 rows, scrollable, pre-filled with Notice)
              const SizedBox(height: 18),
              TextField(
                controller: instC,
                enabled: !saving,
                minLines: 6,
                maxLines: 8,
                style: _inputText,
                decoration: _floatingDeco(
                  'Instructions',
                  hint: 'Enter examination instructions',
                ),
              ),

              // 6. Paper header preview
              const SizedBox(height: 16),
              paperHeaderPreview(),
              const SizedBox(height: 10),
              if (error != null) _ErrorText(error!),
            ],
          ),
        );
      },
    ),
  );

  _disposeControllersLater([quizNameC, examDayC, refNoC, instC]);
  return result;
}

// =============================================================
// EXAMS TAB (list + in-place builder)
// =============================================================

class _Counts {
  const _Counts(this.sections, this.questions);
  final int sections;
  final int questions;
}

class ExamsTab extends StatefulWidget {
  const ExamsTab({super.key, this.initialExamId, this.onExitBuilder});

  /// Opens the builder for this exam straight away (used by My Subjects).
  final int? initialExamId;

  /// When set, leaving the builder calls this instead of showing the exam
  /// list (My Subjects uses it to return to the subject page).
  final VoidCallback? onExitBuilder;

  @override
  State<ExamsTab> createState() => _ExamsTabState();
}

class _ExamsTabState extends State<ExamsTab> {
  List<_Json> _exams = [];
  List<_Json> _classes = [];
  final Map<String, _Counts> _counts = {};

  String? _selectedSection;
  int? _openExamId;
  bool _openedFromUpload = false;
  bool _initialTargetResolved = false;

  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final token = await _token();
      final results = await Future.wait([
        ApiService.getExams(token),
        ApiService.getClasses(token),
      ]);
      if (!mounted) return;
      setState(() {
        _exams = results[0];
        if(!_initialTargetResolved){
          _initialTargetResolved=true;
          final initial=_exams.where((e)=>_id(e['id'])==widget.initialExamId).firstOrNull;
          if(initial!=null && initial['creation_mode']!='manual')_openExamId=widget.initialExamId;
          if(initial?['creation_mode']=='manual')WidgetsBinding.instance.addPostFrameCallback((_){if(mounted)_openManualScorebook(context,initial!);});
        }
        _classes = results[1];
        _loading = false;
      });
      _loadCounts(token, results[0]);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _err(e);
        _loading = false;
      });
    }
  }

  /// Section / question totals for the list cards (loaded in the background).
  Future<void> _loadCounts(String token, List<_Json> exams) async {
    await Future.wait(
      exams.map((exam) async {
        if(exam['creation_mode']=='manual') return;
        final key = exam['id']?.toString();
        final examId = _id(exam['id']);
        if (key == null || examId == null) return;
        try {
          final sections = await ApiService.getExamSections(token, examId);
          var q = 0;
          for (final s in sections) {
            final sid = _id(s['id']);
            if (sid == null) continue;
            q += (await ApiService.getQuestions(token, sid)).length;
          }
          if (!mounted) return;
          setState(() => _counts[key] = _Counts(sections.length, q));
        } catch (_) {
          // The card simply omits the counts.
        }
      }),
    );
  }

  String _sectionOf(_Json item) => (item['section']?.toString() ?? '').trim();

  List<String> get _sections {
    final values =
        _classes.map(_sectionOf).where((s) => s.isNotEmpty).toSet().toList()
          ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return values;
  }

  List<_Json> get _visibleExams {
    if (_selectedSection == null) return _exams;
    final classIds = _classes
        .where((c) => _sectionOf(c) == _selectedSection)
        .map((c) => c['id']?.toString())
        .toSet();
    return _exams.where((exam) {
      final linked = exam['class'];
      if (linked is Map && linked['section']?.toString() == _selectedSection) {
        return true;
      }
      return classIds.contains(exam['class_id']?.toString()) ||
          (linked is Map && classIds.contains(linked['id']?.toString()));
    }).toList();
  }

  Future<void> _chooseCreationMethod() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      backgroundColor: Colors.white,
      constraints: const BoxConstraints(maxWidth: 560),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Create Exam',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: _Brand.ink,
                ),
              ),
              const SizedBox(height: 8),
              ListTile(
                leading: const Icon(Icons.edit_document, color: _Brand.ink),
                title: const Text('Build Exam'),
                subtitle: const Text(
                  'Create an exam using CheckMate questions and answer keys.',
                ),
                onTap: () => Navigator.pop(sheetContext, 'builder'),
              ),
              ListTile(
                leading: const Icon(
                  Icons.picture_as_pdf_outlined,
                  color: _Brand.ink,
                ),
                title: const Text('Upload Questionnaire'),
                subtitle: const Text(
                  'Use a Word template or upload an existing questionnaire.',
                ),
                onTap: () => Navigator.pop(sheetContext, 'pdf'),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;

    if (choice == 'builder') {
      if (_classes.isEmpty) {
        _toast(
          context,
          'No subject or section is assigned to you yet. '
          'Ask an administrator to assign one.',
        );
        return;
      }
      int? preselect;
      if (_selectedSection != null) {
        for (final c in _classes) {
          if (_sectionOf(c) == _selectedSection) {
            preselect = _id(c['id']);
            break;
          }
        }
      }
      final created = await showAssessmentCreation(context,classes:_classes,initialClassId:preselect);
      if(created?.manual == true){
        await _loadData();
        if(mounted)_openManualScorebook(context,{'id':created!.examId,'class_id':created.classId});
        return;
      }
      final createdId = created?.examId;
      if (createdId != null) {
        await _loadData();
        if (!mounted) return;
        if (createdId > 0) {
          setState(() {
            _openedFromUpload = false;
            _openExamId = createdId;
          });
        }
        _toast(context, 'Exam added successfully.');
      }
    } else if (choice == 'pdf') {
      if (_classes.isEmpty) {
        _toast(
          context,
          'No subject or section is assigned to you yet. '
          'Ask an administrator to assign one.',
        );
        return;
      }
      final parsedPaper = await pickAndParseQuestionPaper(context);
      if (parsedPaper == null || !mounted) return;

      int? preselect;
      if (_selectedSection != null) {
        for (final c in _classes) {
          if (_sectionOf(c) == _selectedSection) {
            preselect = _id(c['id']);
            break;
          }
        }
      }
      final createdId = await showExamDetailsModal(
        context,
        classes: _classes,
        initialClassId: preselect,
        initialImportedPaper: parsedPaper,
      );
      if (createdId != null) {
        await _loadData();
        if (!mounted) return;
        if (createdId > 0) {
          setState(() {
            _openedFromUpload = true;
            _openExamId = createdId;
          });
          _toast(
            context,
            'Imported ${parsedPaper.totalQuestions} questions organized by test type. '
            'Select the answer keys and click "Save Questions and Answers".',
          );
        } else {
          _toast(context, 'Exam imported successfully.');
        }
      }
    }
  }

  void _openBuilder(_Json exam) {
    if(exam['creation_mode']=='manual'){_openManualScorebook(context,exam);return;}
    final id = _id(exam['id']);
    if (id == null) {
      _toast(context, 'Invalid exam ID.');
      return;
    }
    setState(() {
      _openedFromUpload = false;
      _openExamId = id;
    });
  }

  void _closeBuilder() {
    final exit = widget.onExitBuilder;
    if (exit != null) {
      exit();
      return;
    }
    setState(() {
      _openExamId = null;
      _openedFromUpload = false;
    });
    _loadData();
  }

  @override
  Widget build(BuildContext context) {
    final openId = _openExamId;
    return PopScope(
      canPop: openId == null,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _openExamId != null) _closeBuilder();
      },
      child: openId != null
          ? _ExamBuilderPane(
              key: ValueKey('$openId-$_openedFromUpload'),
              examId: openId,
              classes: _classes,
              initialBulkMode: _openedFromUpload,
              onBack: _closeBuilder,
            )
          : _buildList(),
    );
  }

  Widget _buildList() {
    return LayoutBuilder(
      builder: (context, box) {
        final narrow = box.maxWidth < 600;

        final filter = _classes.isEmpty
            ? null
            : SizedBox(
                width: narrow ? double.infinity : 200,
                child: DropdownButtonFormField<String?>(
                  key: ValueKey(_selectedSection),
                  initialValue: _selectedSection,
                  isExpanded: true,
                  style: _inputText,
                  decoration: _deco(
                    'All sections',
                    prefix: const Icon(
                      Icons.filter_list,
                      size: 18,
                      color: CmColors.slate,
                    ),
                  ),
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('All sections'),
                    ),
                    for (final s in _sections)
                      DropdownMenuItem<String?>(value: s, child: Text(s)),
                  ],
                  onChanged: (v) => setState(() => _selectedSection = v),
                ),
              );

        final addButton = FilledButton.icon(
          style: _primaryStyle,
          onPressed: _chooseCreationMethod,
          icon: const Icon(Icons.add, size: 18),
          label: const Text('Add exam'),
        );

        return RefreshIndicator(
          onRefresh: _loadData,
          child: ListView(
            padding: _pagePad(box.maxWidth),
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Exams',
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                        color: _Brand.ink,
                      ),
                    ),
                  ),
                  if (!narrow && filter != null) ...[
                    filter,
                    const SizedBox(width: 12),
                  ],
                  addButton,
                ],
              ),
              if (narrow && filter != null) ...[
                const SizedBox(height: 12),
                filter,
              ],
              const SizedBox(height: 20),
              _listBody(narrow),
            ],
          ),
        );
      },
    );
  }

  Widget _listBody(bool narrow) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.only(top: 80),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    if (_error != null) {
      return _Card(
        padding: 24,
        child: Column(
          children: [
            const Icon(Icons.error_outline, size: 40, color: CmColors.slate),
            const SizedBox(height: 12),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: _Brand.ink),
            ),
            const SizedBox(height: 12),
            FilledButton(
              style: _primaryStyle,
              onPressed: _loadData,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    final exams = _visibleExams;
    if (exams.isEmpty) {
      final noClasses = _classes.isEmpty;
      return _Card(
        padding: 36,
        child: Column(
          children: [
            const Icon(
              Icons.assignment_outlined,
              size: 44,
              color: CmColors.slate,
            ),
            const SizedBox(height: 12),
            Text(
              noClasses
                  ? 'No subjects assigned to you yet.'
                  : (_selectedSection == null
                        ? 'No exams yet.'
                        : 'No exams in this section.'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: _Brand.ink,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              noClasses
                  ? 'Ask an administrator to assign a subject and section to you.'
                  : (_selectedSection == null
                        ? 'Tap Add exam to create one.'
                        : 'Choose another section or tap Add exam.'),
              textAlign: TextAlign.center,
              style: const TextStyle(color: CmColors.slate),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        for (final exam in exams)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _examCard(exam, narrow),
          ),
      ],
    );
  }

  Widget _examCard(_Json exam, bool narrow) {
    final title = exam['title']?.toString() ?? 'Untitled Exam';
    final status = exam['creation_mode']=='manual'?'manual':exam['status']?.toString() ?? 'draft';
    final counts = _counts[exam['id']?.toString() ?? ''];

    final info = Row(
      children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: CmColors.bg,
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Icon(
            Icons.assignment_outlined,
            size: 20,
            color: _Brand.ink,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 15.5,
                  fontWeight: FontWeight.w700,
                  color: _Brand.ink,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                '${_examSubjectAndSectionsLabel(exam)} · ${gradingPeriodLabels[exam['grading_period']] ?? 'Period unassigned'}',
                style: const TextStyle(fontSize: 12.5, color: CmColors.slate),
              ),
              if (counts != null) ...[
                const SizedBox(height: 3),
                Text(
                  '${counts.sections} ${counts.sections == 1 ? 'section' : 'sections'}'
                  ' · ${counts.questions} ${counts.questions == 1 ? 'question' : 'questions'}',
                  style: const TextStyle(fontSize: 11.5, color: CmColors.slate),
                ),
              ],
            ],
          ),
        ),
      ],
    );

    final open = OutlinedButton(
      style: _outlineStyle,
      onPressed: () => _openBuilder(exam),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(exam['creation_mode']=='manual'?'Open Scorebook':'Open builder'),
          SizedBox(width: 6),
          Icon(Icons.arrow_forward, size: 16),
        ],
      ),
    );

    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => _openBuilder(exam),
      child: _Card(
        child: narrow
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  info,
                  const SizedBox(height: 12),
                  Row(children: [_StatusPill(status), const Spacer(), open]),
                ],
              )
            : Row(
                children: [
                  Expanded(child: info),
                  const SizedBox(width: 12),
                  _StatusPill(status),
                  const SizedBox(width: 12),
                  open,
                ],
              ),
      ),
    );
  }
}

// =============================================================
// PERSISTENT DRAFT ENTRY MODEL FOR BULK QUESTION ENTRY
// =============================================================

class _DraftQuestionEntry {
  _DraftQuestionEntry({
    required this.uid,
    required this.sectionId,
    required this.questionType,
  }) : textController = TextEditingController(),
       answerController = TextEditingController(),
       choiceControllers = List<TextEditingController>.generate(
         4,
         (_) => TextEditingController(),
       );

  final String uid;
  final int sectionId;
  final String questionType;
  final TextEditingController textController;
  final TextEditingController answerController;
  final List<TextEditingController> choiceControllers;
  String? pickedAnswer;
  String? errorMessage;

  String get resolvedCorrectAnswer {
    if (questionType == 'identification') {
      return answerController.text.trim().toUpperCase();
    }
    return (pickedAnswer ?? '').trim();
  }

  List<String>? get resolvedChoices {
    if (questionType != 'multiple_choice') return null;
    return choiceControllers.map((c) => c.text.trim()).toList();
  }

  bool _disposed = false;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _disposeControllersLater([
      textController,
      answerController,
      ...choiceControllers,
    ]);
  }
}

// =============================================================
// EXAM BUILDER (in place)
// =============================================================

class _ExamBuilderPane extends StatefulWidget {
  const _ExamBuilderPane({
    super.key,
    required this.examId,
    required this.classes,
    required this.onBack,
    this.initialBulkMode = false,
  });

  final int examId;
  final List<_Json> classes;
  final VoidCallback onBack;
  final bool initialBulkMode;

  @override
  State<_ExamBuilderPane> createState() => _ExamBuilderPaneState();
}

class _ExamBuilderPaneState extends State<_ExamBuilderPane> {
  bool _loading = true;
  bool _savingBulk = false;
  String? _error;

  _Json? _exam;
  List<_Json> _sections = [];
  final Map<int, List<_Json>> _questions = {};
  final Map<int, List<_Json>> _acceptable = {};
  List<_Json> _students = [];
  bool _updatingStatus = false;

  /// Accordion: only one section open at a time.
  int? _expandedId;

  /// Unsaved bulk draft questions per section id.
  final Map<int, List<_DraftQuestionEntry>> _drafts = {};

  /// Pending answer-key changes on existing/uploaded questions (questionId -> newAnswer).
  final Map<int, String> _pendingAnswerKeys = {};

  /// Persistent TextEditingControllers for saved Identification questions,
  /// keyed by questionId so typing in Question 3 and navigating to Question 10
  /// never loses state or shifts question positions.
  final Map<int, TextEditingController> _identificationAnswerControllers = {};

  /// Whether newly uploaded questions are awaiting centralized bulk save.
  bool _awaitingUploadedSave = false;

  /// Id of the saved question currently open in the per-question inline editor.
  int? _editingQuestionId;

  int _draftCounter = 0;

  @override
  void initState() {
    super.initState();
    _awaitingUploadedSave = widget.initialBulkMode;
    _load();
  }

  @override
  void dispose() {
    for (final list in _drafts.values) {
      for (final d in list) {
        d.dispose();
      }
    }
    for (final c in _identificationAnswerControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  List<_Json> _sortSections(List<_Json> raw) {
    final copy = List<_Json>.from(raw);
    copy.sort((a, b) {
      final oa = int.tryParse(a['section_order']?.toString() ?? '') ?? 0;
      final ob = int.tryParse(b['section_order']?.toString() ?? '') ?? 0;
      if (oa != ob) return oa.compareTo(ob);
      final ida = _id(a['id']) ?? 0;
      final idb = _id(b['id']) ?? 0;
      return ida.compareTo(idb);
    });
    return copy;
  }

  List<_Json> _sortQuestions(List<_Json> raw) {
    final copy = List<_Json>.from(raw);
    copy.sort((a, b) {
      final na = int.tryParse(a['question_number']?.toString() ?? '') ?? 0;
      final nb = int.tryParse(b['question_number']?.toString() ?? '') ?? 0;
      if (na != nb) return na.compareTo(nb);
      final ida = _id(a['id']) ?? 0;
      final idb = _id(b['id']) ?? 0;
      return ida.compareTo(idb);
    });
    return copy;
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final token = await _token();

      final exams = await ApiService.getExams(token);
      final match = exams.where(
        (e) => e['id'].toString() == widget.examId.toString(),
      );
      if (match.isEmpty) throw Exception('Exam not found.');

      final rawSections = await ApiService.getExamSections(
        token,
        widget.examId,
      );
      final sections = _sortSections(rawSections);

      final qs = <int, List<_Json>>{};
      final acc = <int, List<_Json>>{};
      var anyMissingKey = false;

      // Fetch questions for all sections concurrently.
      final questionResults = await Future.wait(
        sections.map((section) async {
          final sid = _id(section['id']);
          if (sid == null) return null;

          final rawList = await ApiService.getQuestions(token, sid);

          return MapEntry(sid, _sortQuestions(rawList));
        }),
      );

      // Process the questions.
      final identificationQuestionIds = <int>[];

      for (var sectionIndex = 0;
          sectionIndex < sections.length;
          sectionIndex++) {
        final section = sections[sectionIndex];
        final sid = _id(section['id']);

        if (sid == null) continue;

        final result = questionResults[sectionIndex];
        if (result == null) continue;

        final list = result.value;
        final qType = (section['question_type']?.toString() ?? '').trim();

        for (var idx = 0; idx < list.length; idx++) {
          final q = list[idx];

          q['question_number'] ??= idx + 1;

          final rawAns = (q['correct_answer']?.toString() ?? '').trim();

          if (rawAns.isEmpty || rawAns.toLowerCase() == 'null') {
            anyMissingKey = true;
          } else if (qType == 'identification') {
            q['correct_answer'] = rawAns.toUpperCase();
          }

          final qid = _id(q['id']);

          if (qid != null && qType == 'identification') {
            identificationQuestionIds.add(qid);

            final effectiveAns = _pendingAnswerKeys[qid] ??
                ((rawAns.toLowerCase() == 'null') ? '' : rawAns.toUpperCase());

            final existingCtrl = _identificationAnswerControllers[qid];

            if (existingCtrl == null) {
              _identificationAnswerControllers[qid] =
                  TextEditingController(text: effectiveAns);
            } else if (!_pendingAnswerKeys.containsKey(qid) &&
                existingCtrl.text != effectiveAns) {
              existingCtrl.text = effectiveAns;
            }
          }
        }

        qs[sid] = list;
      }

      // Fetch acceptable answers concurrently.
      final acceptableResults = await Future.wait(
        identificationQuestionIds.map((qid) async {
          final rawAcc = await ApiService.getAcceptableAnswers(token, qid);

          for (final answer in rawAcc) {
            if (answer['answer'] != null) {
              answer['answer'] = answer['answer'].toString().toUpperCase();
            }
          }

          return MapEntry(qid, rawAcc);
        }),
      );

      for (final result in acceptableResults) {
        acc[result.key] = result.value;
      }

      final students = await ApiService.getExamStudents(token, match.first);
      // Fetch classes and subjects for the answer sheet PDF header.
        final allClasses = await ApiService.getClasses(token);

        final examWithHeaders = Map<String, dynamic>.from(match.first);

        // Get the class IDs assigned to this exam.
        final classIds = <int>{};

        final rawClassIds = examWithHeaders['class_ids'];

        if (rawClassIds is List) {
          for (final id in rawClassIds) {
            final parsedId = _id(id);
            if (parsedId != null) classIds.add(parsedId);
          }
        }

        // Support exams assigned to a single class.
        final singleClassId = _id(examWithHeaders['class_id']);
        if (singleClassId != null) {
          classIds.add(singleClassId);
        }

        // Match the assigned classes.
        final matchingClasses = allClasses.where((classItem) {
          final classId = _id(classItem['id']);
          return classId != null && classIds.contains(classId);
        }).toList();

        // Get the subject IDs from the matching classes.
        final matchingSubjects = matchingClasses
          .map((classItem) => classItem['subject'])
          .whereType<Map>()
          .map((subject) => Map<String, dynamic>.from(subject))
          .toList();

        // Attach the data to the exam for PDF generation.
        examWithHeaders['header_classes'] = matchingClasses;
        examWithHeaders['header_subjects'] = matchingSubjects;

        print('PDF HEADER CLASSES: ${examWithHeaders['header_classes']}');
        print('PDF HEADER SUBJECTS: ${examWithHeaders['header_subjects']}');
      if (!mounted) return;
      setState(() {
        _exam = examWithHeaders;
        _sections = sections;
        if (_expandedId == null && sections.isNotEmpty) {
          _expandedId = _id(sections.first['id']);
        }
        _questions
          ..clear()
          ..addAll(qs);
        _acceptable
          ..clear()
          ..addAll(acc);
        _students = students;
        if (anyMissingKey) {
          _awaitingUploadedSave = true;
        }
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      if (silent) {
        _toast(context, _err(e));
        return;
      }
      setState(() {
        _error = _err(e);
        _loading = false;
      });
    }
  }

  // ---------- derived ----------

  int get _totalDraftCount =>
      _drafts.values.fold<int>(0, (sum, list) => sum + list.length);

  bool get _hasAnyMissingAnswerKey {
    for (final list in _questions.values) {
      for (final q in list) {
        final qid = _id(q['id']);
        final pending = qid != null ? _pendingAnswerKeys[qid] : null;
        final saved = (q['correct_answer']?.toString() ?? '').trim();
        final effective = (pending ?? saved).trim();
        if (effective.isEmpty || effective.toLowerCase() == 'null') {
          return true;
        }
      }
    }
    return false;
  }

  bool get _isPublished =>
      (_exam?['status']?.toString() ?? 'draft').trim().toLowerCase() ==
      'published';

  /// True only for Quiz assessment types (Quiz, Short Quiz, Long Quiz).
  /// Major examinations (Prelim, Midterm, Prefinals, Finals) return false.
  bool get _isQuizAssessment {
    final exam = _exam;
    if (exam == null) return false;
    final rawType = exam['assessment_type']?.toString();
    final rawTitle = exam['title']?.toString() ?? '';
    final rawDesc = exam['description']?.toString() ?? '';
    final normalizedType = AssessmentValidator.normalizeAssessmentType(
      rawType,
      title: rawTitle,
      description: rawDesc,
    );
    final isMajor = AssessmentValidator.isMajorExamination(
      normalizedType,
      title: rawTitle,
      description: rawDesc,
    );
    if (isMajor) return false;
    return normalizedType == 'quiz' ||
        normalizedType == 'short_quiz' ||
        normalizedType == 'long_quiz' ||
        rawTitle.toLowerCase().contains('quiz');
  }

  /// Controls visibility of the centralized "Save Questions and Answers" button.
  /// Visible while creating/entering new draft questions, editing answer keys
  /// in bulk, or configuring uploaded questions; hidden once everything is saved
  /// or once the assessment is published.
  bool get _showCentralizedSaveButton =>
      !_isPublished &&
      (_totalDraftCount > 0 ||
          _pendingAnswerKeys.isNotEmpty ||
          _awaitingUploadedSave ||
          _hasAnyMissingAnswerKey);

  int get _totalQuestions => _questions.values.fold(0, (a, l) => a + l.length);

  double get _totalPoints {
    var t = 0.0;
    for (final l in _questions.values) {
      for (final q in l) {
        t += _num(q['points']);
      }
    }
    return t;
  }

  AssessmentValidationResult get _validation {
    return AssessmentValidator.validate(
      assessmentType: _exam?['assessment_type']?.toString(),
      title: _exam?['title']?.toString(),
      description: _exam?['description']?.toString(),
      sections: _sections,
      questionsBySectionId: _questions,
    );
  }

  Future<void> _setStatus(String targetStatus) async {
    if (_isPublished) {
      _toast(context, 'Once published, an assessment cannot be republished or reverted to draft.');
      return;
    }
    if (_showCentralizedSaveButton) {
      final savedOk = await _saveAllQuestionsAndAnswers();
      if (!savedOk || !mounted) return;
    }

    final exam = _exam;
    if (exam == null || _updatingStatus) return;

    final validation = _validation;
    if (targetStatus == 'published' && !validation.isValid) {
      _toast(context, validation.errors.join('\n'));
      return;
    }

    setState(() => _updatingStatus = true);
    try {
      final token = await _token();
      await ApiService.updateExam(
        token: token,
        examId: widget.examId,
        title: exam['title']?.toString() ?? 'Exam',
        description: exam['description']?.toString(),
        instructions: exam['instructions']?.toString(),
        assessmentType: exam['assessment_type']?.toString(),
        status: targetStatus,
      );
      await _load(silent: true);
      if (!mounted) return;
      _toast(
        context,
        targetStatus == 'published'
            ? 'Assessment published successfully.'
            : 'Assessment saved as draft.',
      );
    } catch (e) {
      if (mounted) _toast(context, _err(e));
    } finally {
      if (mounted) setState(() => _updatingStatus = false);
    }
  }

  // ---------- PDFs & Word (.docx) ----------

  Future<Uint8List> _generate({required bool answerSheet}) async {
  final exam = _exam;

  if (exam == null) {
    throw Exception('Exam not loaded.');
  }

  print('GENERATING PDF SUBJECTS: ${exam['header_subjects']}');
  print('GENERATING PDF CLASSES: ${exam['header_classes']}');

  if (answerSheet) {
    return await AnswerSheetPdfService.generate(
      exam: exam,
      sections: _sections,
      questions: _questions,
      students: _students,
    );
  }

  return await QuestionPaperPdfService.generate(
    exam: exam,
    sections: _sections,
    questions: _questions,
  );
}

  String _docFileName(String prefix, String ext) {
    final title = (_exam?['title']?.toString() ?? 'exam')
        .trim()
        .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    return '${prefix}_${title.isEmpty ? 'exam' : title}.$ext';
  }

  Future<void> _printPaper(bool answerSheet) async {
    try {
      final bytes = await _generate(answerSheet: answerSheet);
      await Printing.layoutPdf(onLayout: (format) async => bytes);
    } catch (e) {
      if (mounted) _toast(context, _err(e));
    }
  }

  Future<void> _downloadPaper(bool answerSheet) async {
    try {
      final exam = _exam;
      if (exam == null) throw Exception('Exam not loaded.');
      if (answerSheet) {
        final bytes = await _generate(answerSheet: true);
        await Printing.sharePdf(
          bytes: bytes,
          filename: _docFileName('answer_sheet', 'pdf'),
        );
      } else {
        final docxBytes = await QuestionPaperPdfService.generateDocx(
          exam: exam,
          sections: _sections,
          questions: _questions,
        );
        await Printing.sharePdf(
          bytes: docxBytes,
          filename: _docFileName('questionnaire', 'docx'),
        );
      }
    } catch (e) {
      if (mounted) _toast(context, _err(e));
    }
  }

  void _showPreview(bool answerSheet) {
    showDialog<void>(
      context: context,
      builder: (_) => _PaperPreviewDialog(
        initialAnswerSheet: answerSheet,
        questionCount: _totalQuestions,
        totalPoints: _totalPoints,
        generate: (a) => _generate(answerSheet: a),
        onPrint: _printPaper,
        onDownload: _downloadPaper,
      ),
    );
  }

  // ---------- exam details ----------

  Future<void> _editDetails() async {
    final exam = _exam;
    if (exam == null) return;
    final updatedId = await showExamDetailsModal(
      context,
      classes: widget.classes,
      exam: exam,
    );
    if (updatedId != null) await _load(silent: true);
  }

  // ---------- sections (with automatic Part I / Part II section naming) ----------

  Future<void> _showSectionDialog({_Json? section, int? sectionIndex}) async {
    final editing = section != null;
    var type = section?['question_type']?.toString() ?? 'multiple_choice';
    if (!_kTypes.contains(type)) type = 'multiple_choice';

    final nextOrder =
        _sections.fold<int>(0, (m, s) {
          final o = int.tryParse(s['section_order']?.toString() ?? '') ?? 0;
          return o > m ? o : m;
        }) +
        1;

    final effectiveOrder = editing
        ? (int.tryParse(section['section_order']?.toString() ?? '') ??
              ((sectionIndex ?? 0) + 1))
        : nextOrder;

    final initialName = editing
        ? ((section['name']?.toString().trim().isNotEmpty ?? false)
              ? section['name'].toString().trim()
              : _autoSectionName(effectiveOrder, type))
        : _autoSectionName(effectiveOrder, type);

    final nameC = TextEditingController(text: initialName);
    final ptsC = TextEditingController(
      text: editing ? _trim(_num(section['default_points'])) : '1',
    );
    bool saving = false;
    String? error;

    final created = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setS) {
          Future<void> save() async {
            final rawName = nameC.text.trim();
            final name = rawName.isEmpty
                ? _autoSectionName(effectiveOrder, type)
                : rawName;
            final points = num.tryParse(ptsC.text.trim());
            if (points == null || points <= 0) {
              setS(
                () => error = 'Enter default points greater than zero.',
              );
              return;
            }
            setS(() {
              saving = true;
              error = null;
            });
            try {
              final token = await _token();
              if (editing) {
                final sectionId = _id(section['id']);
                if (sectionId == null) throw Exception('Invalid section ID.');
                await ApiService.updateExamSection(
                  token: token,
                  sectionId: sectionId,
                  name: name,
                  defaultPoints: points,
                  questionType: type,
                );
              } else {
                final createdSec = await ApiService.createExamSection(
                  token: token,
                  examId: widget.examId,
                  name: name,
                  questionType: type,
                  sectionOrder: nextOrder,
                  defaultPoints: points,
                );
                final newSid = _id(createdSec['id']);
                if (newSid != null) {
                  _expandedId = newSid;
                }
              }
              await resequenceExamSectionHeadings(
                token: token,
                examId: widget.examId,
              );
              if (dialogContext.mounted) Navigator.pop(dialogContext, true);
            } catch (e) {
              setS(() {
                saving = false;
                error = _err(e);
              });
            }
          }

          return _CmDialog(
            title: editing ? 'Edit exam section' : 'Add exam section',
            subtitle: 'Section details',
            actions: [
              OutlinedButton(
                style: _outlineStyle,
                onPressed: saving
                    ? null
                    : () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                style: _primaryStyle,
                onPressed: saving ? null : save,
                child: saving
                    ? const _Spin()
                    : Text(editing ? 'Save changes' : 'Save section'),
              ),
            ],
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Field(
                  'Section name',
                  TextField(
                    controller: nameC,
                    enabled: !saving,
                    style: _inputText,
                    decoration: _deco(_autoSectionName(effectiveOrder, type)),
                  ),
                ),
                _Field(
                  'Question type',
                  DropdownButtonFormField<String>(
                    initialValue: type,
                    isExpanded: true,
                    style: _inputText,
                    decoration: _deco('Question type'),
                    items: [
                      for (final t in _kTypes)
                        DropdownMenuItem(value: t, child: Text(_typeLabel(t))),
                    ],
                    onChanged: saving
                        ? null
                        : (v) {
                            if (v != null) {
                              setS(() {
                                type = v;
                                // Automatically generate section name based on
                                // the selected exam type and section sequence.
                                nameC.text = _autoSectionName(
                                  effectiveOrder,
                                  v,
                                );
                              });
                            }
                          },
                  ),
                ),
                _Field(
                  'Default points per item',
                  TextField(
                    controller: ptsC,
                    enabled: !saving,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    style: _inputText,
                    decoration: _deco('1'),
                  ),
                ),
                if (error != null) _ErrorText(error!),
              ],
            ),
          );
        },
      ),
    );

    _disposeControllersLater([nameC, ptsC]);
    if (created == true) await _load(silent: true);
  }

  Future<void> _deleteSection(int sectionId, String name) async {
    final ok = await _confirm(
      context,
      title: 'Delete section?',
      message: 'Delete "$name" and all its questions? This cannot be undone.',
    );
    if (!ok || !mounted) return;
    try {
      final token = await _token();
      await ApiService.deleteExamSection(token: token, sectionId: sectionId);
      if (!mounted) return;
      final removedDrafts = _drafts.remove(sectionId);
      if (removedDrafts != null) {
        for (final d in removedDrafts) {
          d.dispose();
        }
      }
      if (_expandedId == sectionId) _expandedId = null;

      // Re-sequence remaining sections' auto-generated Part & subpart headings
      await resequenceExamSectionHeadings(
        token: token,
        examId: widget.examId,
      );

      await _load(silent: true);
      if (!mounted) return;
      _toast(context, 'Section deleted.');
    } catch (e) {
      if (mounted) _toast(context, _err(e));
    }
  }

  // ---------- questions, bulk save & shuffling ----------

  void _addDraft(int sectionId, String questionType) {
    setState(() {
      _expandedId = sectionId;
      final entry = _DraftQuestionEntry(
        uid: 'draft_${++_draftCounter}',
        sectionId: sectionId,
        questionType: questionType,
      );
      _drafts.putIfAbsent(sectionId, () => []).add(entry);
    });
  }

  void _discardDraft(int sectionId, _DraftQuestionEntry entry) {
    setState(() {
      _drafts[sectionId]?.remove(entry);
      entry.dispose();
    });
  }

  /// Centralized bulk save for all unsaved draft questions and all pending
  /// answer key changes across all sections in the exam.
  Future<bool> _saveAllQuestionsAndAnswers() async {
    if (_savingBulk) return false;

    // 1. Validate all draft questions across all sections
    for (final sec in _sections) {
      final sid = _id(sec['id']);
      if (sid == null) continue;
      final secName = sec['name']?.toString() ?? 'Section';
      final secType = sec['question_type']?.toString() ?? 'multiple_choice';
      final savedQs = _questions[sid] ?? const <_Json>[];
      final draftList = _drafts[sid] ?? const <_DraftQuestionEntry>[];

      // Validate existing/uploaded questions in this section have answer keys
      for (var i = 0; i < savedQs.length; i++) {
        final q = savedQs[i];
        final qid = _id(q['id']);
        final qNum = q['question_number']?.toString() ?? '${i + 1}';
        final pendingAns = qid != null ? _pendingAnswerKeys[qid] : null;
        final savedAns = (q['correct_answer']?.toString() ?? '').trim();
        final effectiveAns = (pendingAns ?? savedAns).trim();
        if (effectiveAns.isEmpty || effectiveAns.toLowerCase() == 'null') {
          setState(() => _expandedId = sid);
          _toast(
            context,
            'Please provide the correct answer for Question $qNum in $secName before saving.',
          );
          return false;
        }
      }

      // Validate new draft questions in this section
      for (var i = 0; i < draftList.length; i++) {
        final d = draftList[i];
        final qNum = savedQs.length + i + 1;
        final text = d.textController.text.trim();
        if (text.isEmpty) {
          setState(() {
            _expandedId = sid;
            d.errorMessage = 'Question text is required.';
          });
          _toast(
            context,
            'Question $qNum in $secName is missing question text.',
          );
          return false;
        }
        if (secType == 'multiple_choice') {
          final choices = d.resolvedChoices ?? const <String>[];
          if (choices.any((c) => c.isEmpty)) {
            setState(() {
              _expandedId = sid;
              d.errorMessage = 'Please fill in all four options (A, B, C, D).';
            });
            _toast(
              context,
              'Please fill in all four options for Question $qNum in $secName.',
            );
            return false;
          }
        }
        final correct = d.resolvedCorrectAnswer;
        if (correct.isEmpty) {
          setState(() {
            _expandedId = sid;
            d.errorMessage = 'Correct answer is required.';
          });
          _toast(
            context,
            'Please select or enter the correct answer for Question $qNum in $secName.',
          );
          return false;
        }
        d.errorMessage = null;
      }
    }

    setState(() => _savingBulk = true);
    try {
      final token = await _token();

      // 2. Save all pending answer-key updates on existing/uploaded questions
      // in their exact question order without changing their question_number.
      for (final sec in _sections) {
        final sid = _id(sec['id']);
        if (sid == null) continue;
        final secType = sec['question_type']?.toString() ?? 'multiple_choice';
        final savedQs = _sortQuestions(_questions[sid] ?? const <_Json>[]);

        for (final q in savedQs) {
          final qid = _id(q['id']);
          if (qid == null || !_pendingAnswerKeys.containsKey(qid)) continue;
          final newAns = _normalizeAnswerByType(
            _pendingAnswerKeys[qid]!,
            secType,
          );
          if (newAns.isEmpty) continue;

          await ApiService.updateQuestion(
            token: token,
            questionId: qid,
            questionText: q['question_text']?.toString() ?? '',
            points: _num(q['points']) > 0 ? _num(q['points']) : 1.0,
            choices: q['choices'],
            correctAnswer: newAns,
          );
          q['correct_answer'] = newAns;
        }
      }

      // 3. Create all new draft questions sequentially per section
      for (final sec in _sections) {
        final sid = _id(sec['id']);
        if (sid == null) continue;
        final secType = sec['question_type']?.toString() ?? 'multiple_choice';
        final defaultPoints = _num(sec['default_points']) > 0
            ? _num(sec['default_points'])
            : 1.0;
        final existing = _sortQuestions(_questions[sid] ?? const <_Json>[]);
        var nextQuestionNumber = existing.fold<int>(0, (m, q) {
          final n = int.tryParse(q['question_number']?.toString() ?? '') ?? 0;
          return n > m ? n : m;
        });

        final draftList = List<_DraftQuestionEntry>.from(
          _drafts[sid] ?? const <_DraftQuestionEntry>[],
        );
        for (final d in draftList) {
          nextQuestionNumber++;
          final normalizedCorrect = _normalizeAnswerByType(
            d.resolvedCorrectAnswer,
            secType,
          );
          await ApiService.createQuestion(
            token: token,
            sectionId: sid,
            questionNumber: nextQuestionNumber,
            questionText: d.textController.text.trim(),
            points: defaultPoints,
            choices: d.resolvedChoices,
            correctAnswer: normalizedCorrect,
          );
          // Remove the draft as soon as it is saved so that a later failure
          // never leaves an already-saved draft behind (no duplicates on retry).
          _drafts[sid]?.remove(d);
          d.dispose();
        }
        _drafts.remove(sid);
      }

      _pendingAnswerKeys.clear();
      _awaitingUploadedSave = false;

      await _load(silent: true);
      if (mounted) {
        _toast(context, 'All questions and answers saved successfully.');
      }
      return true;
    } catch (e) {
      // Refresh so questions that were already saved are not re-created and
      // question numbers stay in sync on the next attempt.
      if (mounted) await _load(silent: true);
      if (mounted) _toast(context, _err(e));
      return false;
    } finally {
      if (mounted) setState(() => _savingBulk = false);
    }
  }

  /// Shuffles the questions within [sectionId] while preserving sequential
  /// 1..N question numbers and their corresponding answers.
  ///
  /// Only saved questions that already have an answer key are shuffled (the
  /// server requires an answer when editing). Questions without one stay in
  /// place, and if saving fails part-way the original content is restored so
  /// no question is lost or duplicated.
  Future<void> _shuffleSectionQuestions(int sectionId) async {
    final savedQs = _sortQuestions(_questions[sectionId] ?? const <_Json>[]);
    final draftList = _drafts[sectionId] ?? <_DraftQuestionEntry>[];

    if (savedQs.length + draftList.length < 2) {
      _toast(context, 'Add at least 2 questions to shuffle this section.');
      return;
    }

    final rng = math.Random();
    if (draftList.length >= 2) {
      setState(() {
        draftList.shuffle(rng);
      });
    }

    if (savedQs.length < 2) {
      _toast(context, 'Questions shuffled.');
      return;
    }

    final section = _sections.firstWhere(
      (s) => _id(s['id']) == sectionId,
      orElse: () => <String, dynamic>{},
    );
    final secType = section['question_type']?.toString() ?? 'multiple_choice';

    // Snapshot every saved question that has an answer key.
    final slots = <_Json>[];
    final originals = <Map<String, dynamic>>[];
    for (final q in savedQs) {
      final qid = _id(q['id']);
      if (qid == null) continue;
      final pendingAns = _pendingAnswerKeys[qid];
      final rawAns =
          pendingAns ?? (q['correct_answer']?.toString() ?? '').trim();
      final ans = rawAns.toLowerCase() == 'null'
          ? ''
          : _normalizeAnswerByType(rawAns, secType).trim();
      if (ans.isEmpty) continue;
      slots.add(q);
      originals.add(<String, dynamic>{
        'question_text': q['question_text']?.toString() ?? '',
        'points': _num(q['points']) > 0 ? _num(q['points']) : 1.0,
        'choices': q['choices'],
        'correct_answer': ans,
      });
    }

    if (slots.length < 2) {
      _toast(
        context,
        'Set the answer key for at least 2 saved questions before shuffling.',
      );
      return;
    }

    final skipped = savedQs.length - slots.length;
    final payloads = List<Map<String, dynamic>>.from(originals)..shuffle(rng);
    final applied = <int>[];
    String? token;

    try {
      token = await _token();
      for (var i = 0; i < slots.length; i++) {
        final targetQ = slots[i];
        final qid = _id(targetQ['id'])!;
        final p = payloads[i];
        final ans = p['correct_answer'] as String;

        await ApiService.updateQuestion(
          token: token,
          questionId: qid,
          questionText: p['question_text'] as String,
          points: p['points'] as num,
          choices: p['choices'],
          correctAnswer: ans,
        );
        applied.add(i);

        targetQ['question_text'] = p['question_text'];
        targetQ['points'] = p['points'];
        targetQ['choices'] = p['choices'];
        targetQ['correct_answer'] = ans;

        if (_identificationAnswerControllers.containsKey(qid)) {
          _identificationAnswerControllers[qid]!.text = ans.toUpperCase();
        }
        if (_pendingAnswerKeys.containsKey(qid)) {
          _pendingAnswerKeys[qid] = ans;
        }
      }

      await _load(silent: true);
      if (mounted) {
        _toast(
          context,
          skipped > 0
              ? 'Questions shuffled. $skipped question(s) without an answer '
                    'key were left in place.'
              : 'Questions shuffled successfully.',
        );
      }
    } catch (e) {
      // Best-effort rollback so no question is lost or duplicated.
      try {
        final t = token ?? await _token();
        for (final i in applied) {
          final qid = _id(slots[i]['id']);
          if (qid == null) continue;
          final o = originals[i];
          await ApiService.updateQuestion(
            token: t,
            questionId: qid,
            questionText: o['question_text'] as String,
            points: o['points'] as num,
            choices: o['choices'],
            correctAnswer: o['correct_answer'] as String,
          );
        }
      } catch (_) {}
      if (mounted) await _load(silent: true);
      if (mounted) _toast(context, _err(e));
    }
  }

  Future<void> _importPdfIntoCurrentExam() async {
    final parsedPaper = await pickAndParseQuestionPaper(context);
    if (parsedPaper == null || !mounted) return;
    try {
      final token = await _token();
      final nextOrder =
          _sections.fold<int>(0, (m, s) {
            final o = int.tryParse(s['section_order']?.toString() ?? '') ?? 0;
            return o > m ? o : m;
          }) +
          1;
      final count = await importParsedSectionsIntoExam(
        token: token,
        examId: widget.examId,
        paper: parsedPaper,
        startingSectionOrder: nextOrder,
        existingSections: _sections,
        existingQuestionsBySection: _questions,
      );
      setState(() => _awaitingUploadedSave = true);
      await _load(silent: true);
      if (mounted) {
        _toast(
          context,
          'Imported $count questions from "${parsedPaper.fileName}" organized by test type. '
          'Set the answer keys and click "Save Questions and Answers".',
        );
      }
    } catch (e) {
      if (mounted) _toast(context, _err(e));
    }
  }

  /// Sets or updates the answer key for an existing/uploaded question [q] in
  /// local state (preserving exact question order) and exposes the centralized
  /// "Save Questions and Answers" button.
  void _setSavedQuestionAnswerKey(_Json q, String newAnswer, String type) {
    final qid = _id(q['id']);
    if (qid == null) return;
    final normalized = _normalizeAnswerByType(newAnswer, type);
    setState(() {
      q['correct_answer'] = normalized;
      _pendingAnswerKeys[qid] = normalized;
    });
  }

  Future<void> _updateSingleSavedQuestion(
    _Json q,
    String text,
    List<String>? choices,
    String correct,
    String type,
  ) async {
    final qid = _id(q['id']);
    if (qid == null) throw Exception('Invalid question ID.');
    final token = await _token();
    final normalizedCorrect = _normalizeAnswerByType(correct, type);

    await ApiService.updateQuestion(
      token: token,
      questionId: qid,
      questionText: text,
      points: _num(q['points']) > 0 ? _num(q['points']) : 1.0,
      choices: choices,
      correctAnswer: normalizedCorrect,
    );

    if (_identificationAnswerControllers.containsKey(qid)) {
      _identificationAnswerControllers[qid]!.text = normalizedCorrect;
    }
    _pendingAnswerKeys.remove(qid);

    if (mounted) setState(() => _editingQuestionId = null);
    await _load(silent: true);
    if (mounted) _toast(context, 'Question updated.');
  }

  Future<void> _deleteQuestion(int questionId, String number) async {
    final ok = await _confirm(
      context,
      title: 'Delete question?',
      message: 'Delete question $number? This cannot be undone.',
    );
    if (!ok || !mounted) return;
    try {
      final token = await _token();
      await ApiService.deleteQuestion(token: token, questionId: questionId);
      _pendingAnswerKeys.remove(questionId);
      _identificationAnswerControllers.remove(questionId)?.dispose();
      if (!mounted) return;
      await _load(silent: true);
      if (!mounted) return;
      _toast(context, 'Question deleted.');
    } catch (e) {
      if (mounted) _toast(context, _err(e));
    }
  }

  Future<void> _addAcceptableAnswer(int questionId) async {
    final c = TextEditingController();
    bool saving = false;
    String? error;

    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setS) {
          Future<void> save() async {
            final answer = c.text.trim().toUpperCase();
            if (answer.isEmpty) {
              setS(() => error = 'Acceptable answer is required.');
              return;
            }
            setS(() {
              saving = true;
              error = null;
            });
            try {
              final token = await _token();
              await ApiService.createAcceptableAnswer(
                token: token,
                questionId: questionId,
                answer: answer,
              );
              if (dialogContext.mounted) Navigator.pop(dialogContext, true);
            } catch (e) {
              setS(() {
                saving = false;
                error = _err(e);
              });
            }
          }

          return _CmDialog(
            title: 'Add acceptable answer',
            subtitle: 'Another answer in CAPITAL LETTERS that earns full credit',
            maxWidth: 400,
            actions: [
              OutlinedButton(
                style: _outlineStyle,
                onPressed: saving
                    ? null
                    : () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                style: _primaryStyle,
                onPressed: saving ? null : save,
                child: saving ? const _Spin() : const Text('Add'),
              ),
            ],
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Field(
                  'Answer (CAPITAL LETTERS)',
                  TextField(
                    controller: c,
                    enabled: !saving,
                    autofocus: true,
                    textCapitalization: TextCapitalization.characters,
                    inputFormatters: const [_UpperCaseTextFormatter()],
                    style: _inputText,
                    decoration: _deco('Example: DART'),
                  ),
                ),
                if (error != null) _ErrorText(error!),
              ],
            ),
          );
        },
      ),
    );

    _disposeControllersLater([c]);
    if (ok == true) {
      await _load(silent: true);
      if (mounted) _toast(context, 'Acceptable answer added successfully.');
    }
  }

  // ---------- build ----------

  Widget _buildExamTitleArea(_Json exam, String status) {
    final rawType = exam['assessment_type']?.toString();
    final rawTitle = exam['title']?.toString() ?? 'Exam';
    final rawDesc = exam['description']?.toString() ?? '';

    final normalizedType = AssessmentValidator.normalizeAssessmentType(
      rawType,
      title: rawTitle,
      description: rawDesc,
    );
    final isMajor = AssessmentValidator.isMajorExamination(
      normalizedType,
      title: rawTitle,
      description: rawDesc,
    );

    final badgeCategory = isMajor
        ? 'EXAMINATION'
        : (normalizedType == 'other' ? 'ASSESSMENT' : 'QUIZ');

    final displayTitle = isMajor
        ? AssessmentValidator.formalExaminationTitle(
            normalizedType,
            title: rawTitle,
            description: rawDesc,
          )
        : rawTitle;

    final subjectAndSections = _examSubjectAndSectionsLabel(exam);
    final headerDetails = ExamHeaderDetails.fromExam(exam);
    final sy = AssessmentValidator.formatSchoolYear(
      exam['school_year'] ??
          (exam['class'] is Map ? (exam['class'] as Map)['school_year'] : null),
    );
    final term = AssessmentValidator.formatSchoolTerm(
      exam['semester'] ??
          (exam['class'] is Map ? (exam['class'] as Map)['semester'] : null),
    );

    final metaParts = <String>[
      if (isMajor) ...[
        if (headerDetails.scheduleDateLine.isNotEmpty)
          headerDetails.scheduleDateLine,
        if (headerDetails.scheduleTimeLine.isNotEmpty)
          headerDetails.scheduleTimeLine,
        '$term, $sy',
        if (headerDetails.referenceNo.isNotEmpty)
          'Ref: ${headerDetails.referenceNo}',
      ],
    ];

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    badgeCategory,
                    style: const TextStyle(
                      fontSize: 11,
                      letterSpacing: 0.8,
                      fontWeight: FontWeight.w700,
                      color: CmColors.slate,
                    ),
                  ),
                  const SizedBox(width: 10),
                  _StatusPill(status),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                displayTitle,
                style: const TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.w800,
                  color: _Brand.ink,
                ),
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.class_outlined,
                    size: 14,
                    color: CmColors.slate,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      subjectAndSections,
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: CmColors.slate,
                      ),
                    ),
                  ),
                ],
              ),
              if (metaParts.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  metaParts.join(' · '),
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: CmColors.slate,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (status.trim().toLowerCase() != 'published') ...[
          const SizedBox(width: 12),
          OutlinedButton.icon(
            style: _outlineStyle,
            onPressed: _editDetails,
            icon: const Icon(Icons.edit_outlined, size: 16),
            label: const Text('Edit details'),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 44, color: CmColors.slate),
              const SizedBox(height: 12),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: _Brand.ink),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 10,
                children: [
                  OutlinedButton(
                    style: _outlineStyle,
                    onPressed: widget.onBack,
                    child: const Text('All exams'),
                  ),
                  FilledButton(
                    style: _primaryStyle,
                    onPressed: _load,
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth >= _kWide;
        final exam = _exam!;
        final status = exam['status']?.toString() ?? 'draft';

        final sectionsColumn = _sectionsColumn();
        final papers = _papersColumn(exam);

        return RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            padding: _pagePad(box.maxWidth),
            children: [
              // Title row
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Exam Builder',
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                        color: _Brand.ink,
                      ),
                    ),
                  ),
                  OutlinedButton.icon(
                    style: _outlineStyle,
                    onPressed: widget.onBack,
                    icon: const Icon(Icons.arrow_back, size: 16),
                    label: const Text('All exams'),
                  ),
                ],
              ),
              const SizedBox(height: 14),

              // Exam header (updated title area)
              _buildExamTitleArea(exam, status),
              const SizedBox(height: 18),

              // Stats
              Row(
                children: [
                  Expanded(
                    child: _stat(
                      Icons.assignment_outlined,
                      '${_sections.length}',
                      'Sections',
                      compact: box.maxWidth < 480,
                    ),
                  ),
                  Expanded(
                    child: _stat(
                      Icons.checklist,
                      '$_totalQuestions',
                      'Questions',
                      compact: box.maxWidth < 480,
                    ),
                  ),
                  Expanded(
                    child: _stat(
                      Icons.check,
                      _trim(_totalPoints),
                      'Total points',
                      compact: box.maxWidth < 480,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _validationBanner(status),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 18),
                child: Divider(height: 1, color: CmColors.line),
              ),

              if (wide)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: sectionsColumn),
                    const SizedBox(width: 24),
                    SizedBox(width: 300, child: papers),
                  ],
                )
              else ...[
                sectionsColumn,
                const SizedBox(height: 24),
                papers,
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _validationBanner(String status) {
    final v = _validation;
    final ok = v.isValid;
    final isPublished = status.toLowerCase() == 'published';
    final accent = ok ? CmColors.green : _Brand.amber;

    return _Card(
      padding: 16,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                ok ? Icons.check_circle_outline : Icons.info_outline,
                size: 20,
                color: accent,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${v.assessmentLabel} Question Requirements',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: _Brand.ink,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'Each included question type requires at least '
                      '${v.requiredPerQuestionType} questions.',
                      style: const TextStyle(
                        fontSize: 12,
                        color: CmColors.slate,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              if (isPublished)
                FilledButton.icon(
                  style: _primaryStyle,
                  onPressed: () =>
                      openTeacherScansForExam(context, widget.examId),
                  icon: const Icon(Icons.document_scanner_outlined, size: 16),
                  label: const Text('Scan Now'),
                )
              else
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      style: _outlineStyle,
                      onPressed: _updatingStatus
                          ? null
                          : () => _setStatus('draft'),
                      icon: const Icon(Icons.save_outlined, size: 16),
                      label: const Text('Save draft'),
                    ),
                    FilledButton.icon(
                      style: _primaryStyle,
                      onPressed: (_updatingStatus || !ok)
                          ? null
                          : () => _setStatus('published'),
                      icon: _updatingStatus
                          ? const _Spin()
                          : const Icon(Icons.publish_outlined, size: 16),
                      label: const Text('Publish exam'),
                    ),
                  ],
                ),
            ],
          ),
          if (!ok) ...[
            const SizedBox(height: 8),
            for (final err in v.errors)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '• $err',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.error,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _stat(
    IconData icon,
    String value,
    String label, {
    bool compact = false,
  }) {
    final tile = compact ? 30.0 : 36.0;
    return Row(
      children: [
        Container(
          width: tile,
          height: tile,
          decoration: BoxDecoration(
            color: CmColors.bg,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: CmColors.line),
          ),
          child: Icon(icon, size: compact ? 16 : 18, color: _Brand.ink),
        ),
        SizedBox(width: compact ? 8 : 10),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                value,
                style: TextStyle(
                  fontSize: compact ? 16 : 18,
                  fontWeight: FontWeight.w800,
                  color: _Brand.ink,
                ),
              ),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  label,
                  style: const TextStyle(fontSize: 11.5, color: CmColors.slate),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ---------- sections column ----------

  Widget _sectionsColumn() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: double.infinity,
          child: Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Exam Sections',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: _Brand.ink,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '(${_sections.length})',
                  style: const TextStyle(fontSize: 12.5, color: CmColors.slate),
                ),
              ],
            ),
            if (!_isPublished)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  OutlinedButton.icon(
                    style: _outlineStyle.copyWith(
                      minimumSize: const WidgetStatePropertyAll(Size(0, 38)),
                    ),
                    onPressed: _savingBulk ? null : _importPdfIntoCurrentExam,
                    icon: const Icon(Icons.upload_file_outlined, size: 17),
                    label: const Text('Upload PDF'),
                  ),
                  FilledButton.icon(
                    style: _amberStyle,
                    onPressed: _savingBulk ? null : () => _showSectionDialog(),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Add section'),
                  ),
                ],
              ),
          ],
          ),
        ),
        const SizedBox(height: 12),
        if (_sections.isEmpty)
          const _Card(
            padding: 36,
            child: Center(
              child: Text(
                'No sections yet',
                style: TextStyle(fontSize: 13, color: CmColors.slate),
              ),
            ),
          )
        else
          for (var i = 0; i < _sections.length; i++)
            _sectionCard(_sections[i], i),
        const SizedBox(height: 4),
        const Text(
          'Changes updated for this session',
          style: TextStyle(fontSize: 11.5, color: CmColors.slate),
        ),
      ],
    );
  }

  Widget _sectionCard(_Json section, int index) {
    final sid = _id(section['id']);
    final type = section['question_type']?.toString() ?? 'multiple_choice';
    final qs = sid == null
        ? <_Json>[]
        : _sortQuestions(_questions[sid] ?? <_Json>[]);
    final drafts = sid == null
        ? <_DraftQuestionEntry>[]
        : (_drafts[sid] ?? <_DraftQuestionEntry>[]);
    final expanded = sid != null && _expandedId == sid;
    final order = section['section_order']?.toString() ?? '${index + 1}';
    final name = section['name']?.toString() ?? _autoSectionName(index + 1, type);
    final totalInSection = qs.length + drafts.length;

    return Padding(
      key: ValueKey('section-${sid ?? index}'),
      padding: const EdgeInsets.only(bottom: 12),
      child: _Card(
        padding: 0,
        child: Column(
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: sid == null
                  ? null
                  : () => setState(() => _expandedId = expanded ? null : sid),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
                child: Row(
                  children: [
                    _Badge(order.padLeft(2, '0'), size: 34),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name,
                            style: const TextStyle(
                              fontSize: 14.5,
                              fontWeight: FontWeight.w700,
                              color: _Brand.ink,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${_typeLabel(type)} · '
                            '${_trim(_num(section['default_points']))} ${_num(section['default_points']) == 1 ? 'pt' : 'pts'}/item · '
                            '${qs.isEmpty ? '0 questions' : 'Items ${qs.first['question_number'] ?? 1}–${qs.last['question_number'] ?? qs.length} (${qs.length} ${qs.length == 1 ? 'question' : 'questions'})'}'
                            '${drafts.isNotEmpty ? ' (+${drafts.length} unsaved)' : ''}',
                            style: const TextStyle(
                              fontSize: 11.5,
                              color: CmColors.slate,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (!_isPublished &&
                        _isQuizAssessment &&
                        totalInSection >= 2 &&
                        sid != null)
                      IconButton(
                        tooltip: 'Shuffle questions',
                        visualDensity: VisualDensity.compact,
                        iconSize: 18,
                        color: CmColors.slate,
                        icon: const Icon(Icons.shuffle),
                        onPressed: _savingBulk
                            ? null
                            : () => _shuffleSectionQuestions(sid),
                      ),
                    if (!_isPublished) ...[
                      IconButton(
                        tooltip: 'Edit section',
                        visualDensity: VisualDensity.compact,
                        iconSize: 18,
                        color: CmColors.slate,
                        icon: const Icon(Icons.edit_outlined),
                        onPressed: () => _showSectionDialog(
                          section: section,
                          sectionIndex: index,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Delete section',
                        visualDensity: VisualDensity.compact,
                        iconSize: 18,
                        color: CmColors.slate,
                        icon: const Icon(Icons.delete_outline),
                        onPressed: sid == null
                            ? null
                            : () => _deleteSection(sid, name),
                      ),
                    ],
                    Icon(
                      expanded
                          ? Icons.keyboard_arrow_down
                          : Icons.chevron_right,
                      size: 20,
                      color: CmColors.slate,
                    ),
                    const SizedBox(width: 4),
                  ],
                ),
              ),
            ),
            if (expanded) ...[
              const Divider(height: 1, color: CmColors.line),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (qs.isEmpty && drafts.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 18),
                        child: Center(
                          child: Column(
                            children: [
                              Icon(
                                Icons.description_outlined,
                                size: 22,
                                color: CmColors.slate,
                              ),
                              SizedBox(height: 6),
                              Text(
                                'No questions yet',
                                style: TextStyle(
                                  fontSize: 12.5,
                                  color: CmColors.slate,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    for (var i = 0; i < qs.length; i++)
                      _savedQuestion(qs[i], i, type),
                    for (var i = 0; i < drafts.length; i++)
                      _buildBulkDraftQuestionCard(
                        entry: drafts[i],
                        number: qs.length + i + 1,
                        pointsLabel: _trim(_num(section['default_points'])),
                      ),
                    if (!_isPublished) ...[
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              style: _outlineStyle.copyWith(
                                backgroundColor: WidgetStatePropertyAll(
                                  CmColors.bg,
                                ),
                              ),
                              onPressed: _savingBulk
                                  ? null
                                  : () => _addDraft(sid, type),
                              icon: const Icon(Icons.add, size: 16),
                              label: const Text('Add question'),
                            ),
                          ),
                          if (_showCentralizedSaveButton) ...[
                            const SizedBox(width: 10),
                            FilledButton.icon(
                              style: _greenSaveStyle.copyWith(
                                minimumSize: const WidgetStatePropertyAll(
                                  Size(0, 40),
                                ),
                              ),
                              onPressed: _savingBulk
                                  ? null
                                  : _saveAllQuestionsAndAnswers,
                              icon: _savingBulk
                                  ? const _Spin()
                                  : const Icon(
                                      Icons.check_circle_outline,
                                      size: 17,
                                    ),
                              label: const Text('Save Questions and Answers'),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Renders a bulk-entry draft question card (no individual "Save question"
  /// button—saved together with all other questions via "Save Questions and Answers").
  Widget _buildBulkDraftQuestionCard({
    required _DraftQuestionEntry entry,
    required int number,
    required String pointsLabel,
  }) {
    final type = entry.questionType;
    final currentAnswer = entry.resolvedCorrectAnswer;
    final missingKey = currentAnswer.isEmpty;

    Widget choiceInputRow(int idx) {
      final letter = String.fromCharCode(65 + idx);
      final isSelected =
          !missingKey && currentAnswer.toUpperCase() == letter;
      return Row(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(7),
            onTap: _savingBulk
                ? null
                : () => setState(() {
                    entry.pickedAnswer = letter;
                    entry.errorMessage = null;
                  }),
            child: Container(
              width: 26,
              height: 26,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: isSelected ? CmColors.green : CmColors.bg,
                borderRadius: BorderRadius.circular(7),
              ),
              child: Text(
                letter,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                  color: isSelected ? Colors.white : _Brand.ink,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: entry.choiceControllers[idx],
              enabled: !_savingBulk,
              onChanged: (_) {
                if (entry.errorMessage != null) {
                  setState(() => entry.errorMessage = null);
                }
              },
              style: _inputText,
              decoration: _deco('Option $letter').copyWith(
                fillColor: isSelected
                    ? CmColors.green.withValues(alpha: 0.08)
                    : Colors.white,
                enabledBorder: _ob(
                  isSelected ? CmColors.green : _Brand.mist,
                ),
              ),
            ),
          ),
        ],
      );
    }

    Widget answerKeySelector() {
      if (type == 'multiple_choice') {
        return _buildMultipleChoiceKeyTiles(
          selectedLetter: missingKey ? null : currentAnswer.toUpperCase(),
          enabled: !_savingBulk,
          onSelect: (letter) => setState(() {
            entry.pickedAnswer = letter;
            entry.errorMessage = null;
          }),
        );
      }
      if (type == 'true_false') {
        return _buildTrueFalseKeyButtons(
          selectedValue: missingKey ? null : currentAnswer,
          enabled: !_savingBulk,
          onSelect: (val) => setState(() {
            entry.pickedAnswer = val;
            entry.errorMessage = null;
          }),
        );
      }
      return SizedBox(
        width: 240,
        child: TextField(
          controller: entry.answerController,
          enabled: !_savingBulk,
          textCapitalization: TextCapitalization.characters,
          inputFormatters: const [_UpperCaseTextFormatter()],
          onChanged: (_) => setState(() {
            entry.errorMessage = null;
          }),
          style: _inputText.copyWith(fontWeight: FontWeight.w700),
          decoration: _deco('ENTER ANSWER IN CAPS').copyWith(
            fillColor: !missingKey
                ? CmColors.green.withValues(alpha: 0.08)
                : Colors.white,
            enabledBorder: _ob(!missingKey ? CmColors.green : _Brand.mist),
          ),
        ),
      );
    }

    return Padding(
      key: ValueKey('draft-card-${entry.uid}'),
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Question $number',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: _Brand.ink,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '$pointsLabel ${pointsLabel == '1' ? 'pt' : 'pts'}',
                style: const TextStyle(fontSize: 11.5, color: CmColors.slate),
              ),
              if (missingKey) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: _Brand.amber.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Text(
                    'Answer key needed',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: _Brand.ink,
                    ),
                  ),
                ),
              ],
              const Spacer(),
              IconButton(
                tooltip: 'Discard question',
                visualDensity: VisualDensity.compact,
                iconSize: 17,
                color: CmColors.slate,
                icon: const Icon(Icons.delete_outline),
                onPressed: _savingBulk
                    ? null
                    : () => _discardDraft(entry.sectionId, entry),
              ),
            ],
          ),
          const SizedBox(height: 4),
          TextField(
            controller: entry.textController,
            enabled: !_savingBulk,
            minLines: 2,
            maxLines: 5,
            onChanged: (_) {
              if (entry.errorMessage != null) {
                setState(() => entry.errorMessage = null);
              }
            },
            style: _inputText,
            decoration: _deco('Enter your question'),
          ),
          if (type == 'multiple_choice') ...[
            const SizedBox(height: 10),
            LayoutBuilder(
              builder: (context, box) {
                if (box.maxWidth >= 480) {
                  return Column(
                    children: [
                      Row(
                        children: [
                          Expanded(child: choiceInputRow(0)),
                          const SizedBox(width: 12),
                          Expanded(child: choiceInputRow(1)),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(child: choiceInputRow(2)),
                          const SizedBox(width: 12),
                          Expanded(child: choiceInputRow(3)),
                        ],
                      ),
                    ],
                  );
                }
                return Column(
                  children: [
                    for (var k = 0; k < 4; k++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: choiceInputRow(k),
                      ),
                  ],
                );
              },
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    missingKey ? Icons.key_outlined : Icons.check,
                    size: 16,
                    color: missingKey ? _Brand.amber : CmColors.green,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    missingKey ? 'Select answer key:' : 'Correct answer:',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: missingKey ? _Brand.ink : CmColors.green,
                    ),
                  ),
                ],
              ),
              answerKeySelector(),
            ],
          ),
          if (entry.errorMessage != null) ...[
            const SizedBox(height: 8),
            _ErrorText(entry.errorMessage!),
          ],
          const SizedBox(height: 8),
          const Divider(height: 1, color: CmColors.line),
        ],
      ),
    );
  }

  // A saved question, shown in the same layout as the editor. The pencil
  // swaps it for the inline per-question editor (prefilled) while preserving
  // its exact position and question_number.
  Widget _savedQuestion(_Json q, int i, String type) {
    final qid = _id(q['id']);
    final number = q['question_number']?.toString() ?? '${i + 1}';

    if (qid != null && _editingQuestionId == qid) {
      return _DraftQuestion(
        key: ValueKey('edit-saved-$qid'),
        number: int.tryParse(number) ?? i + 1,
        type: type,
        initial: q,
        saveLabel: 'Save changes',
        onDiscard: () => setState(() => _editingQuestionId = null),
        onSave: (text, choices, correct) =>
            _updateSingleSavedQuestion(q, text, choices, correct, type),
      );
    }

    final text = q['question_text']?.toString() ?? '';
    final points = _trim(_num(q['points']));
    final choices = q['choices'];
    final pendingAns = qid != null ? _pendingAnswerKeys[qid] : null;
    final rawCorrect = pendingAns ?? (q['correct_answer']?.toString() ?? '');
    final correct = rawCorrect.trim().toLowerCase() == 'null'
        ? ''
        : (type == 'identification'
              ? rawCorrect.trim().toUpperCase()
              : rawCorrect.trim());
    final answers = qid == null ? <_Json>[] : (_acceptable[qid] ?? <_Json>[]);

    final missingKey = correct.isEmpty;

    Widget choiceBox(int idx) {
      final letter = String.fromCharCode(65 + idx);
      final value = (choices is List && idx < choices.length)
          ? choices[idx].toString()
          : '';
      final isCorrect =
          !missingKey &&
          (correct.toUpperCase() == letter ||
              (correct.isNotEmpty && correct == value));
      return InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: (qid == null || _isPublished)
            ? null
            : () => _setSavedQuestionAnswerKey(q, letter, type),
        child: Row(
          children: [
            Container(
              width: 26,
              height: 26,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: isCorrect ? CmColors.green : CmColors.bg,
                borderRadius: BorderRadius.circular(7),
              ),
              child: Text(
                letter,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                  color: isCorrect ? Colors.white : _Brand.ink,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(child: _ReadBox(value, highlight: isCorrect)),
          ],
        ),
      );
    }

    Widget answerKeySelector() {
      if (type == 'multiple_choice') {
        return _buildMultipleChoiceKeyTiles(
          selectedLetter: missingKey ? null : correct.toUpperCase(),
          enabled: qid != null && !_savingBulk && !_isPublished,
          onSelect: (letter) => _setSavedQuestionAnswerKey(q, letter, type),
        );
      }
      if (type == 'true_false') {
        return _buildTrueFalseKeyButtons(
          selectedValue: missingKey ? null : correct,
          enabled: qid != null && !_savingBulk && !_isPublished,
          onSelect: (opt) => _setSavedQuestionAnswerKey(q, opt, type),
        );
      }

      // Identification: persistent inline CAPITAL LETTERS answer key field
      // keyed by qid so typing in Question 3 and navigating to Question 10
      // never shifts question order or loses the typed answer.
      if (qid != null) {
        final ctrl = _identificationAnswerControllers.putIfAbsent(
          qid,
          () => TextEditingController(text: correct),
        );
        return SizedBox(
          width: 240,
          child: TextField(
            key: ValueKey('id-ans-field-$qid'),
            controller: ctrl,
            enabled: !_savingBulk && !_isPublished,
            textCapitalization: TextCapitalization.characters,
            inputFormatters: const [_UpperCaseTextFormatter()],
            onChanged: (val) {
              _setSavedQuestionAnswerKey(q, val.toUpperCase(), type);
            },
            style: _inputText.copyWith(fontWeight: FontWeight.w700),
            decoration: _deco('ENTER ANSWER IN CAPS').copyWith(
              fillColor: !missingKey
                  ? CmColors.green.withValues(alpha: 0.08)
                  : Colors.white,
              enabledBorder: _ob(!missingKey ? CmColors.green : _Brand.mist),
            ),
          ),
        );
      }

      return SizedBox(
        width: 200,
        child: _ReadBox(
          missingKey ? 'Click to set answer key' : correct.toUpperCase(),
          highlight: !missingKey,
        ),
      );
    }

    return Padding(
      key: ValueKey('saved-question-${qid ?? i}'),
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Question $number',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: _Brand.ink,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '$points ${points == '1' ? 'pt' : 'pts'}',
                style: const TextStyle(fontSize: 11.5, color: CmColors.slate),
              ),
              if (missingKey) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: _Brand.amber.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Text(
                    'Answer key needed',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: _Brand.ink,
                    ),
                  ),
                ),
              ],
              const Spacer(),
              if (!_isPublished) ...[
                IconButton(
                  tooltip: 'Edit question',
                  visualDensity: VisualDensity.compact,
                  iconSize: 17,
                  color: CmColors.slate,
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: qid == null
                      ? null
                      : () => setState(() => _editingQuestionId = qid),
                ),
                IconButton(
                  tooltip: 'Delete question',
                  visualDensity: VisualDensity.compact,
                  iconSize: 17,
                  color: CmColors.slate,
                  icon: const Icon(Icons.delete_outline),
                  onPressed: qid == null
                      ? null
                      : () => _deleteQuestion(qid, number),
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          _ReadBox(text),
          if (type == 'multiple_choice' && choices is List) ...[
            const SizedBox(height: 10),
            LayoutBuilder(
              builder: (context, box) {
                if (box.maxWidth >= 480) {
                  return Column(
                    children: [
                      Row(
                        children: [
                          Expanded(child: choiceBox(0)),
                          const SizedBox(width: 12),
                          Expanded(child: choiceBox(1)),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(child: choiceBox(2)),
                          const SizedBox(width: 12),
                          Expanded(child: choiceBox(3)),
                        ],
                      ),
                    ],
                  );
                }
                return Column(
                  children: [
                    for (var k = 0; k < 4; k++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: choiceBox(k),
                      ),
                  ],
                );
              },
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    missingKey ? Icons.key_outlined : Icons.check,
                    size: 16,
                    color: missingKey ? _Brand.amber : CmColors.green,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    missingKey ? 'Select answer key:' : 'Correct answer:',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: missingKey ? _Brand.ink : CmColors.green,
                    ),
                  ),
                ],
              ),
              answerKeySelector(),
            ],
          ),
          if (type == 'identification' && qid != null) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (answers.isNotEmpty)
                  const Text(
                    'Also accepted:',
                    style: TextStyle(fontSize: 12, color: CmColors.slate),
                  ),
                for (final a in answers)
                  Chip(
                    visualDensity: VisualDensity.compact,
                    backgroundColor: CmColors.bg,
                    side: const BorderSide(color: CmColors.line),
                    label: Text(
                      (a['answer']?.toString() ?? '').toUpperCase(),
                      style: const TextStyle(fontSize: 12, color: _Brand.ink),
                    ),
                  ),
                if (!_isPublished)
                  TextButton.icon(
                    onPressed: () => _addAcceptableAnswer(qid),
                    icon: const Icon(Icons.add, size: 15),
                    label: const Text('Add acceptable answer'),
                    style: TextButton.styleFrom(
                      foregroundColor: _Brand.ink,
                      textStyle: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 4),
          const Divider(height: 1, color: CmColors.line),
        ],
      ),
    );
  }

  // ---------- papers column ----------

  Widget _papersColumn(_Json exam) {
    final instructions = exam['instructions']?.toString() ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Exam Papers',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w800,
            color: _Brand.ink,
          ),
        ),
        const SizedBox(height: 12),
        _paperCard(
          icon: Icons.description_outlined,
          title: 'Questionnaire',
          answerSheet: false,
        ),
        const SizedBox(height: 12),
        _paperCard(
          icon: Icons.document_scanner_outlined,
          title: 'Answer sheet',
          answerSheet: true,
        ),
        if (instructions.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Divider(height: 1, color: CmColors.line),
          ),
          const Text(
            'Instructions',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w800,
              color: _Brand.ink,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            instructions,
            style: const TextStyle(
              fontSize: 12.5,
              height: 1.4,
              color: CmColors.slate,
            ),
          ),
        ],
      ],
    );
  }

  Widget _paperCard({
    required IconData icon,
    required String title,
    required bool answerSheet,
  }) {
    const linkStyle = TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600);
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: CmColors.bg,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(icon, size: 18, color: _Brand.ink),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: _Brand.ink,
                    ),
                  ),
                  const Text(
                    'A4 · PDF document',
                    style: TextStyle(fontSize: 11.5, color: CmColors.slate),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: CmColors.bg,
                foregroundColor: _Brand.ink,
                minimumSize: const Size(0, 38),
                side: const BorderSide(color: CmColors.line),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                textStyle: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
              onPressed: () => _showPreview(answerSheet),
              icon: const Icon(Icons.visibility_outlined, size: 16),
              label: const Text('Preview'),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: TextButton.icon(
                  style: TextButton.styleFrom(foregroundColor: _Brand.ink),
                  onPressed: () => _printPaper(answerSheet),
                  icon: const Icon(Icons.print_outlined, size: 16),
                  label: const Text('Print', style: linkStyle),
                ),
              ),
              Expanded(
                child: TextButton.icon(
                  style: TextButton.styleFrom(foregroundColor: _Brand.ink),
                  onPressed: () => _downloadPaper(answerSheet),
                  icon: const Icon(Icons.file_download_outlined, size: 16),
                  label: const Text('Download', style: linkStyle),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// =============================================================
// SHARED ANSWER KEY TILE & BUTTON SELECTORS
// =============================================================

Widget _buildMultipleChoiceKeyTiles({
  required String? selectedLetter,
  required bool enabled,
  required ValueChanged<String> onSelect,
}) {
  return Wrap(
    spacing: 6,
    runSpacing: 6,
    children: [
      for (final letter in const ['A', 'B', 'C', 'D'])
        Builder(
          builder: (context) {
            final isSelected =
                selectedLetter != null &&
                selectedLetter.toUpperCase() == letter;
            return InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: enabled ? () => onSelect(letter) : null,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: isSelected ? CmColors.green : CmColors.bg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: isSelected ? CmColors.green : CmColors.line,
                  ),
                ),
                child: Text(
                  letter,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                    color: isSelected ? Colors.white : _Brand.ink,
                  ),
                ),
              ),
            );
          },
        ),
    ],
  );
}

Widget _buildTrueFalseKeyButtons({
  required String? selectedValue,
  required bool enabled,
  required ValueChanged<String> onSelect,
}) {
  return Wrap(
    spacing: 6,
    runSpacing: 6,
    children: [
      for (final opt in const ['True', 'False'])
        Builder(
          builder: (context) {
            final isSelected =
                selectedValue != null &&
                selectedValue.trim().toLowerCase() == opt.toLowerCase();
            return InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: enabled ? () => onSelect(opt) : null,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: isSelected ? CmColors.green : CmColors.bg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: isSelected ? CmColors.green : CmColors.line,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isSelected) ...[
                      const Icon(
                        Icons.check,
                        size: 14,
                        color: Colors.white,
                      ),
                      const SizedBox(width: 5),
                    ],
                    Text(
                      opt,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800,
                        color: isSelected ? Colors.white : _Brand.ink,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
    ],
  );
}

/// Read-only value box that matches the editor fields.
class _ReadBox extends StatelessWidget {
  const _ReadBox(this.text, {this.highlight = false});
  final String text;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 40),
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: highlight ? CmColors.green.withValues(alpha: 0.08) : CmColors.bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: highlight ? CmColors.green : CmColors.line),
      ),
      child: Text(
        text.isEmpty ? '—' : text,
        style: const TextStyle(fontSize: 13.5, color: _Brand.ink),
      ),
    );
  }
}

// =============================================================
// PER-QUESTION INLINE EDITOR (used when clicking Edit on a saved question)
// =============================================================

class _DraftQuestion extends StatefulWidget {
  const _DraftQuestion({
    super.key,
    required this.number,
    required this.type,
    required this.onSave,
    required this.onDiscard,
    this.initial,
    this.saveLabel = 'Save changes',
  });

  final int number;
  final String type;

  /// A saved question to edit; null for a brand-new question.
  final _Json? initial;
  final String saveLabel;
  final Future<void> Function(
    String text,
    List<String>? choices,
    String correct,
  )
  onSave;
  final VoidCallback onDiscard;

  @override
  State<_DraftQuestion> createState() => _DraftQuestionState();
}

class _DraftQuestionState extends State<_DraftQuestion> {
  final _text = TextEditingController();
  final _answer = TextEditingController();
  final List<TextEditingController> _choices = List.generate(
    4,
    (_) => TextEditingController(),
  );

  String? _picked;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final q = widget.initial;
    if (q == null) return;

    _text.text = q['question_text']?.toString() ?? '';

    final ch = q['choices'];
    if (ch is List) {
      for (var i = 0; i < 4 && i < ch.length; i++) {
        _choices[i].text = ch[i].toString();
      }
    }

    final correct = (q['correct_answer']?.toString() ?? '').trim();
    final cleanCorrect = correct.toLowerCase() == 'null' ? '' : correct;
    final upper = cleanCorrect.toUpperCase();
    if (widget.type == 'identification') {
      _answer.text = upper;
    } else if (widget.type == 'true_false') {
      _picked = upper.startsWith('T')
          ? 'True'
          : (upper.startsWith('F') ? 'False' : null);
    } else {
      _picked = const ['A', 'B', 'C', 'D'].contains(upper) ? upper : null;
    }
  }

  @override
  void dispose() {
    _disposeControllersLater([_text, _answer, ..._choices]);
    super.dispose();
  }

  Future<void> _submit() async {
    final text = _text.text.trim();
    if (text.isEmpty) {
      setState(() => _error = 'Question is required.');
      return;
    }

    List<String>? choices;
    if (widget.type == 'multiple_choice') {
      choices = _choices.map((c) => c.text.trim()).toList();
      if (choices.any((c) => c.isEmpty)) {
        setState(() => _error = 'Please fill in all four options.');
        return;
      }
    }

    final correct = widget.type == 'identification'
        ? _answer.text.trim().toUpperCase()
        : (_picked ?? '');
    if (correct.isEmpty) {
      setState(() => _error = 'Correct answer is required.');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSave(text, choices, correct);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = _err(e);
      });
    }
  }

  Widget _choiceField(int i) {
    final letter = String.fromCharCode(65 + i);
    final isSelected = _picked != null && _picked!.toUpperCase() == letter;
    return Row(
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(7),
          onTap: _saving ? null : () => setState(() => _picked = letter),
          child: Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: isSelected ? CmColors.green : CmColors.bg,
              borderRadius: BorderRadius.circular(7),
            ),
            child: Text(
              letter,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w800,
                color: isSelected ? Colors.white : _Brand.ink,
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: TextField(
            controller: _choices[i],
            enabled: !_saving,
            style: _inputText,
            decoration: _deco('Option $letter').copyWith(
              fillColor: isSelected
                  ? CmColors.green.withValues(alpha: 0.08)
                  : Colors.white,
              enabledBorder: _ob(isSelected ? CmColors.green : _Brand.mist),
            ),
          ),
        ),
      ],
    );
  }

  Widget _correctControl() {
    switch (widget.type) {
      case 'identification':
        return SizedBox(
          width: 240,
          child: TextField(
            controller: _answer,
            enabled: !_saving,
            textCapitalization: TextCapitalization.characters,
            inputFormatters: const [_UpperCaseTextFormatter()],
            onChanged: (_) => setState(() {}),
            style: _inputText.copyWith(fontWeight: FontWeight.w700),
            decoration: _deco('ENTER ANSWER IN CAPS'),
          ),
        );
      case 'true_false':
        return _buildTrueFalseKeyButtons(
          selectedValue: _picked,
          enabled: !_saving,
          onSelect: (v) => setState(() => _picked = v),
        );
      case 'multiple_choice':
        return _buildMultipleChoiceKeyTiles(
          selectedLetter: _picked,
          enabled: !_saving,
          onSelect: (v) => setState(() => _picked = v),
        );
      default:
        return const SizedBox.shrink();
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasKey = widget.type == 'identification'
        ? _answer.text.trim().isNotEmpty
        : (_picked != null && _picked!.isNotEmpty);

    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Question ${widget.number}',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: _Brand.ink,
                ),
              ),
              const Spacer(),
              IconButton(
                tooltip: widget.initial == null
                    ? 'Discard question'
                    : 'Cancel editing',
                visualDensity: VisualDensity.compact,
                iconSize: 17,
                color: CmColors.slate,
                icon: Icon(
                  widget.initial == null ? Icons.delete_outline : Icons.close,
                ),
                onPressed: _saving ? null : widget.onDiscard,
              ),
            ],
          ),
          const SizedBox(height: 4),
          TextField(
            controller: _text,
            enabled: !_saving,
            minLines: 2,
            maxLines: 5,
            style: _inputText,
            decoration: _deco('Enter your question'),
          ),
          if (widget.type == 'multiple_choice') ...[
            const SizedBox(height: 10),
            LayoutBuilder(
              builder: (context, box) {
                if (box.maxWidth >= 480) {
                  return Column(
                    children: [
                      Row(
                        children: [
                          Expanded(child: _choiceField(0)),
                          const SizedBox(width: 12),
                          Expanded(child: _choiceField(1)),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(child: _choiceField(2)),
                          const SizedBox(width: 12),
                          Expanded(child: _choiceField(3)),
                        ],
                      ),
                    ],
                  );
                }
                return Column(
                  children: [
                    for (var k = 0; k < 4; k++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _choiceField(k),
                      ),
                  ],
                );
              },
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    hasKey ? Icons.check : Icons.key_outlined,
                    size: 16,
                    color: hasKey ? CmColors.green : _Brand.amber,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    hasKey ? 'Correct answer:' : 'Select answer key:',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: hasKey ? CmColors.green : _Brand.ink,
                    ),
                  ),
                ],
              ),
              _correctControl(),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            _ErrorText(_error!),
          ],
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              OutlinedButton(
                style: _outlineStyle.copyWith(
                  minimumSize: const WidgetStatePropertyAll(Size(0, 36)),
                ),
                onPressed: _saving ? null : widget.onDiscard,
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                style: _primaryStyle.copyWith(
                  minimumSize: const WidgetStatePropertyAll(Size(0, 36)),
                ),
                onPressed: _saving ? null : _submit,
                child: _saving ? const _Spin() : Text(widget.saveLabel),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// =============================================================
// PAPER PREVIEW POPUP (questionnaire + answer sheet)
//
// Renders the exact PDF that Print / Download produce, so what the
// teacher previews is what comes out of the printer.
// =============================================================

class _PaperPreviewDialog extends StatefulWidget {
  const _PaperPreviewDialog({
    required this.initialAnswerSheet,
    required this.questionCount,
    required this.totalPoints,
    required this.generate,
    required this.onPrint,
    required this.onDownload,
  });

  final bool initialAnswerSheet;
  final int questionCount;
  final double totalPoints;
  final Future<Uint8List> Function(bool answerSheet) generate;
  final Future<void> Function(bool answerSheet) onPrint;
  final Future<void> Function(bool answerSheet) onDownload;

  @override
  State<_PaperPreviewDialog> createState() => _PaperPreviewDialogState();
}

class _PaperPreviewDialogState extends State<_PaperPreviewDialog> {
  late bool _answerSheet = widget.initialAnswerSheet;

  Widget _tab(String label, IconData icon, bool selected, VoidCallback onTap) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? CmColors.line : Colors.transparent,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: selected ? _Brand.ink : CmColors.slate),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? _Brand.ink : CmColors.slate,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final q = widget.questionCount;

    return Dialog(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SizedBox(
        width: math.min(860, size.width - 32),
        height: math.min(size.height * 0.9, 920),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Paper preview',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            color: _Brand.ink,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '$q ${q == 1 ? 'question' : 'questions'} · '
                          '${_trim(widget.totalPoints)} '
                          '${widget.totalPoints == 1 ? 'point' : 'points'}',
                          style: const TextStyle(
                            fontSize: 12,
                            color: CmColors.slate,
                          ),
                        ),
                      ],
                    ),
                  ),
                  InkWell(
                    onTap: () => Navigator.maybePop(context),
                    child: const Padding(
                      padding: EdgeInsets.all(2),
                      child: Icon(Icons.close, size: 18, color: CmColors.slate),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                runSpacing: 8,
                children: [
                  Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      color: CmColors.bg,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _tab(
                          'Questionnaire',
                          Icons.description_outlined,
                          !_answerSheet,
                          () => setState(() => _answerSheet = false),
                        ),
                        _tab(
                          'Answer sheet',
                          Icons.document_scanner_outlined,
                          _answerSheet,
                          () => setState(() => _answerSheet = true),
                        ),
                      ],
                    ),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Print',
                        style: IconButton.styleFrom(
                          side: const BorderSide(color: CmColors.line),
                        ),
                        icon: const Icon(Icons.print_outlined, size: 18),
                        color: _Brand.ink,
                        onPressed: () => widget.onPrint(_answerSheet),
                      ),
                      const SizedBox(width: 6),
                      IconButton(
                        tooltip: 'Download',
                        style: IconButton.styleFrom(
                          side: const BorderSide(color: CmColors.line),
                        ),
                        icon: const Icon(
                          Icons.file_download_outlined,
                          size: 18,
                        ),
                        color: _Brand.ink,
                        onPressed: () => widget.onDownload(_answerSheet),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    decoration: BoxDecoration(
                      color: CmColors.bg,
                      border: Border.all(color: CmColors.line),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: PdfPreview(
                      key: ValueKey(_answerSheet),
                      build: (format) => widget.generate(_answerSheet),
                      useActions: false,
                      canChangePageFormat: false,
                      canChangeOrientation: false,
                      canDebug: false,
                      maxPageWidth: 700,
                      onError: (context, error) => Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            _err(error),
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: _Brand.ink),
                          ),
                        ),
                      ),
                    ),
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
