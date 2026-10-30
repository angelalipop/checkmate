import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import '../services/answer_sheet_pdf_service.dart';
import '../services/api_service.dart';
import '../services/auth_storage.dart';
import '../services/question_paper_pdf_service.dart';
import 'login_screen.dart' show CmColors;

// =============================================================
// CheckMate — Teacher "Exams" tab
//
// One screen, no route changes:
//   Exam list  ->  "Open builder"  ->  Exam builder (in place)
//
// Builder: sections are collapsible and hold their questions inline
// (no separate Questions screen). "Preview" for the question paper and
// answer sheet opens a popup (no separate preview screens).
//
// Existing ApiService calls are reused. Editing uses the new PATCH
// endpoints (updateExam / updateExamSection / updateQuestion). The server
// only allows editing sections and questions of a DRAFT exam that has no
// attempts, and only by the class owner (or an admin).
// =============================================================

typedef _Json = Map<String, dynamic>;

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

  /// Accent: Add section, draft status.
  static const Color amber = Color(0xFFF7A224);
}

const double _kWide = 760;
const List<String> _kTypes = ['multiple_choice', 'true_false', 'identification'];

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

double _num(dynamic v) => double.tryParse(v?.toString() ?? '') ?? 0;

String _fixed2(double v) => v.toStringAsFixed(2);

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

String _statusLabel(String s) {
  switch (s.toLowerCase()) {
    case 'published':
      return 'Published';
    case 'archived':
      return 'Archived';
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
  backgroundColor: _Brand.amber,
  foregroundColor: _Brand.ink,
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
          Text(label,
              style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: _Brand.ink)),
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
        child: Text(message,
            style: TextStyle(
                fontSize: 12.5, color: Theme.of(context).colorScheme.error)),
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
        child: Text(text,
            style: const TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w800,
                color: _Brand.ink)),
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
              decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
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
                        Text(title,
                            style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                                color: _Brand.ink)),
                        if (subtitle != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(subtitle!,
                                style: const TextStyle(
                                    fontSize: 12, color: CmColors.slate)),
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
            child: const Text('Cancel')),
        FilledButton(
            style: _primaryStyle,
            onPressed: () => Navigator.pop(c, true),
            child: Text(action)),
      ],
      child: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(message,
            style: const TextStyle(fontSize: 13.5, color: _Brand.ink)),
      ),
    ),
  );
  return r == true;
}

// ---------------------------------------------------------------
// Create / edit exam dialog
// ---------------------------------------------------------------

Future<bool?> _showExamDetailsDialog(
  BuildContext context, {
  required List<_Json> classes,
  _Json? exam,
  int? initialClassId,
}) async {
  final editing = exam != null;
  final titleC = TextEditingController(text: exam?['title']?.toString() ?? '');
  final descC =
      TextEditingController(text: exam?['description']?.toString() ?? '');
  final instC =
      TextEditingController(text: exam?['instructions']?.toString() ?? '');

  int? classId = initialClassId ?? _examClassId(exam);
  if (classId != null && !classes.any((c) => _id(c['id']) == classId)) {
    classId = null;
  }
  bool saving = false;
  String? error;

  final result = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setS) {
        Future<void> save() async {
          final title = titleC.text.trim();
          if (classId == null) {
            setS(() => error = 'Please select a class.');
            return;
          }
          if (title.isEmpty) {
            setS(() => error = 'Exam title is required.');
            return;
          }
          setS(() {
            saving = true;
            error = null;
          });
          try {
            final token = await _token();
            final d = descC.text.trim();
            final i = instC.text.trim();
            if (editing) {
              final examId = _id(exam['id']);
              if (examId == null) throw Exception('Invalid exam ID.');
              await ApiService.updateExam(
                token: token,
                examId: examId,
                classId: classId!,
                title: title,
                description: d.isEmpty ? null : d,
                instructions: i.isEmpty ? null : i,
              );
            } else {
              await ApiService.createExam(
                token: token,
                classId: classId!,
                title: title,
                description: d.isEmpty ? null : d,
                instructions: i.isEmpty ? null : i,
                status: 'draft',
              );
            }
            if (dialogContext.mounted) Navigator.pop(dialogContext, true);
          } catch (e) {
            setS(() {
              saving = false;
              error = _err(e);
            });
          }
        }

        return _CmDialog(
          title: editing ? 'Edit exam details' : 'Create exam',
          subtitle: editing ? 'Examination information' : 'New examination · Draft',
          actions: [
            OutlinedButton(
                style: _outlineStyle,
                onPressed: saving ? null : () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel')),
            FilledButton(
                style: _primaryStyle,
                onPressed: saving ? null : save,
                child: saving
                    ? const _Spin()
                    : Text(editing ? 'Save changes' : 'Create exam')),
          ],
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Field(
                'Class',
                DropdownButtonFormField<int>(
                  initialValue: classId,
                  isExpanded: true,
                  style: _inputText,
                  decoration: _deco('Select class'),
                  items: [
                    for (final c in classes)
                      if (_id(c['id']) != null)
                        DropdownMenuItem<int>(
                          value: _id(c['id']),
                          child: Text(_classLabel(c),
                              overflow: TextOverflow.ellipsis),
                        ),
                  ],
                  onChanged: saving ? null : (v) => setS(() => classId = v),
                ),
              ),
              _Field(
                'Exam title',
                TextField(
                  controller: titleC,
                  enabled: !saving,
                  style: _inputText,
                  decoration: _deco('e.g. Computer Programming Midterm'),
                ),
              ),
              _Field(
                'Description',
                TextField(
                  controller: descC,
                  enabled: !saving,
                  style: _inputText,
                  decoration: _deco('e.g. Midterm'),
                ),
              ),
              _Field(
                'Instructions',
                TextField(
                  controller: instC,
                  enabled: !saving,
                  minLines: 3,
                  maxLines: 5,
                  style: _inputText,
                  decoration: _deco('Enter examination instructions'),
                ),
              ),
              if (error != null) _ErrorText(error!),
            ],
          ),
        );
      },
    ),
  );

  titleC.dispose();
  descC.dispose();
  instC.dispose();
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

  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _openExamId = widget.initialExamId;
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
    await Future.wait(exams.map((exam) async {
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
    }));
  }

  String _sectionOf(_Json item) => (item['section']?.toString() ?? '').trim();

  List<String> get _sections {
    final values = _classes
        .map(_sectionOf)
        .where((s) => s.isNotEmpty)
        .toSet()
        .toList()
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
              const Text('Create Exam',
                  style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: _Brand.ink)),
              const SizedBox(height: 8),
              ListTile(
                leading: const Icon(Icons.edit_document, color: _Brand.ink),
                title: const Text('Build Exam'),
                subtitle: const Text(
                    'Create an exam using CheckMate questions and answer keys.'),
                onTap: () => Navigator.pop(sheetContext, 'builder'),
              ),
              ListTile(
                leading: const Icon(Icons.picture_as_pdf_outlined,
                    color: _Brand.ink),
                title: const Text('Upload Question Paper PDF'),
                subtitle: const Text(
                    'Use an existing PDF and configure its answer key.'),
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
      final ok = await _showExamDetailsDialog(
        context,
        classes: _classes,
        initialClassId: preselect,
      );
      if (ok == true) {
        await _loadData();
        if (!mounted) return;
        _toast(context, 'Exam added successfully.');
      }
    } else if (choice == 'pdf') {
      await showDialog<void>(
        context: context,
        builder: (c) => _CmDialog(
          title: 'PDF Upload — Coming Next',
          maxWidth: 420,
          actions: [
            FilledButton(
                style: _primaryStyle,
                onPressed: () => Navigator.pop(c),
                child: const Text('OK')),
          ],
          child: const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: Text(
              'The PDF upload workflow needs file storage and an API endpoint. '
              'It is not connected yet, so no exam or file will be saved. '
              'You can use Build Exam in the meantime.',
              style: TextStyle(fontSize: 13.5, color: _Brand.ink),
            ),
          ),
        ),
      );
    }
  }

  void _openBuilder(_Json exam) {
    final id = _id(exam['id']);
    if (id == null) {
      _toast(context, 'Invalid exam ID.');
      return;
    }
    setState(() => _openExamId = id);
  }

  void _closeBuilder() {
    final exit = widget.onExitBuilder;
    if (exit != null) {
      exit();
      return;
    }
    setState(() => _openExamId = null);
    _loadData();
  }

  @override
  Widget build(BuildContext context) {
    final openId = _openExamId;
    // System back (Android / browser) returns to the exam list first.
    return PopScope(
      canPop: openId == null,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _openExamId != null) _closeBuilder();
      },
      child: openId != null
          ? _ExamBuilderPane(
              key: ValueKey(openId),
              examId: openId,
              classes: _classes,
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
                  decoration: _deco('All sections',
                      prefix: const Icon(Icons.filter_list,
                          size: 18, color: CmColors.slate)),
                  items: [
                    const DropdownMenuItem<String?>(
                        value: null, child: Text('All sections')),
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
                    child: Text('Exams',
                        style: TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.w800,
                            color: _Brand.ink)),
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
            Text(_error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: _Brand.ink)),
            const SizedBox(height: 12),
            FilledButton(
                style: _primaryStyle,
                onPressed: _loadData,
                child: const Text('Retry')),
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
            const Icon(Icons.assignment_outlined,
                size: 44, color: CmColors.slate),
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
                  color: _Brand.ink),
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
    final status = exam['status']?.toString() ?? 'draft';
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
          child: const Icon(Icons.assignment_outlined,
              size: 20, color: _Brand.ink),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: const TextStyle(
                      fontSize: 15.5,
                      fontWeight: FontWeight.w700,
                      color: _Brand.ink)),
              const SizedBox(height: 3),
              Text(_classLabel(exam['class']),
                  style: const TextStyle(fontSize: 12.5, color: CmColors.slate)),
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
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Open builder'),
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
                  Row(
                    children: [
                      _StatusPill(status),
                      const Spacer(),
                      open,
                    ],
                  ),
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
// EXAM BUILDER (in place)
// =============================================================

class _ExamBuilderPane extends StatefulWidget {
  const _ExamBuilderPane({
    super.key,
    required this.examId,
    required this.classes,
    required this.onBack,
  });

  final int examId;
  final List<_Json> classes;
  final VoidCallback onBack;

  @override
  State<_ExamBuilderPane> createState() => _ExamBuilderPaneState();
}

class _ExamBuilderPaneState extends State<_ExamBuilderPane> {
  bool _loading = true;
  String? _error;

  _Json? _exam;
  List<_Json> _sections = [];
  final Map<int, List<_Json>> _questions = {};
  final Map<int, List<_Json>> _acceptable = {};

  /// Accordion: only one section open at a time.
  int? _expandedId;

  /// Unsaved question editors, per section id.
  final Map<int, List<Key>> _drafts = {};

  /// Id of the saved question currently open in the inline editor.
  int? _editingQuestionId;

  @override
  void initState() {
    super.initState();
    _load();
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
      final match = exams
          .where((e) => e['id'].toString() == widget.examId.toString());
      if (match.isEmpty) throw Exception('Exam not found.');

      final sections = await ApiService.getExamSections(token, widget.examId);

      final qs = <int, List<_Json>>{};
      final acc = <int, List<_Json>>{};
      for (final s in sections) {
        final sid = _id(s['id']);
        if (sid == null) continue;
        final list = await ApiService.getQuestions(token, sid);
        qs[sid] = list;
        if (s['question_type']?.toString() == 'identification') {
          for (final q in list) {
            final qid = _id(q['id']);
            if (qid == null) continue;
            acc[qid] = await ApiService.getAcceptableAnswers(token, qid);
          }
        }
      }

      if (!mounted) return;
      setState(() {
        _exam = match.first;
        _sections = sections;
        _questions
          ..clear()
          ..addAll(qs);
        _acceptable
          ..clear()
          ..addAll(acc);
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

  int get _totalQuestions =>
      _questions.values.fold(0, (a, l) => a + l.length);

  double get _totalPoints {
    var t = 0.0;
    for (final l in _questions.values) {
      for (final q in l) {
        t += _num(q['points']);
      }
    }
    return t;
  }

  // ---------- PDFs ----------

  Future<Uint8List> _generate({required bool answerSheet}) async {
    final exam = _exam;
    if (exam == null) throw Exception('Exam not loaded.');
    if (answerSheet) {
      return await AnswerSheetPdfService.generate(
        exam: exam,
        sections: _sections,
        questions: _questions,
      );
    }
    return await QuestionPaperPdfService.generate(
      exam: exam,
      sections: _sections,
      questions: _questions,
    );
  }

  String _pdfFileName(String prefix) {
    final title = (_exam?['title']?.toString() ?? 'exam')
        .trim()
        .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    return '${prefix}_${title.isEmpty ? 'exam' : title}.pdf';
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
      final bytes = await _generate(answerSheet: answerSheet);
      await Printing.sharePdf(
        bytes: bytes,
        filename: _pdfFileName(answerSheet ? 'answer_sheet' : 'question_paper'),
      );
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
    final ok = await _showExamDetailsDialog(
      context,
      classes: widget.classes,
      exam: _exam,
    );
    if (ok == true) await _load(silent: true);
  }

  // ---------- sections ----------

  Future<void> _showSectionDialog({_Json? section}) async {
    final editing = section != null;
    final nameC = TextEditingController(text: section?['name']?.toString() ?? '');
    final ptsC = TextEditingController(
        text: editing ? _trim(_num(section['default_points'])) : '1');
    var type = section?['question_type']?.toString() ?? 'multiple_choice';
    if (!_kTypes.contains(type)) type = 'multiple_choice';
    bool saving = false;
    String? error;

    final nextOrder = _sections.fold<int>(0, (m, s) {
          final o = int.tryParse(s['section_order']?.toString() ?? '') ?? 0;
          return o > m ? o : m;
        }) +
        1;

    final created = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setS) {
          Future<void> save() async {
            final name = nameC.text.trim();
            final points = num.tryParse(ptsC.text.trim());
            if (name.isEmpty || points == null || points <= 0) {
              setS(() => error =
                  'Enter a section name and points greater than zero.');
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
                );
              } else {
                await ApiService.createExamSection(
                  token: token,
                  examId: widget.examId,
                  name: name,
                  questionType: type,
                  sectionOrder: nextOrder,
                  defaultPoints: points,
                );
              }
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
                  onPressed:
                      saving ? null : () => Navigator.pop(dialogContext, false),
                  child: const Text('Cancel')),
              FilledButton(
                  style: _primaryStyle,
                  onPressed: saving ? null : save,
                  child: saving
                      ? const _Spin()
                      : Text(editing ? 'Save changes' : 'Save section')),
            ],
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Field(
                  'Section name',
                  TextField(
                    controller: nameC,
                    enabled: !saving,
                    autofocus: !editing,
                    style: _inputText,
                    decoration: _deco('e.g. Part II · Identification'),
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
                    // A section's type can't change once it exists.
                    onChanged: (saving || editing)
                        ? null
                        : (v) {
                            if (v != null) setS(() => type = v);
                          },
                  ),
                ),
                _Field(
                  'Default points per item',
                  TextField(
                    controller: ptsC,
                    enabled: !saving,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
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

    nameC.dispose();
    ptsC.dispose();
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
      _drafts.remove(sectionId);
      if (_expandedId == sectionId) _expandedId = null;
      await _load(silent: true);
      if (!mounted) return;
      _toast(context, 'Section deleted.');
    } catch (e) {
      if (mounted) _toast(context, _err(e));
    }
  }

  // ---------- questions ----------

  void _addDraft(int sectionId) {
    setState(() {
      _expandedId = sectionId;
      _drafts.putIfAbsent(sectionId, () => []).add(UniqueKey());
    });
  }

  void _discardDraft(int sectionId, Key key) {
    setState(() => _drafts[sectionId]?.remove(key));
  }

  Future<void> _saveQuestion(
    int sectionId,
    Key key,
    String text,
    List<String>? choices,
    String correct,
  ) async {
    final token = await _token();
    final existing = _questions[sectionId] ?? const <_Json>[];
    final next = existing.fold<int>(0, (m, q) {
          final n = int.tryParse(q['question_number']?.toString() ?? '') ?? 0;
          return n > m ? n : m;
        }) +
        1;

    final section = _sections.firstWhere(
      (s) => _id(s['id']) == sectionId,
      orElse: () => <String, dynamic>{},
    );
    final defaultPoints = _num(section['default_points']);

    await ApiService.createQuestion(
      token: token,
      sectionId: sectionId,
      questionNumber: next,
      questionText: text,
      points: defaultPoints > 0 ? defaultPoints : 1.0,
      choices: choices,
      correctAnswer: correct,
    );

    _drafts[sectionId]?.remove(key);
    await _load(silent: true);
    if (mounted) _toast(context, 'Question added successfully.');
  }

  Future<void> _updateQuestion(
    _Json q,
    String text,
    List<String>? choices,
    String correct,
  ) async {
    final qid = _id(q['id']);
    if (qid == null) throw Exception('Invalid question ID.');
    final token = await _token();

    await ApiService.updateQuestion(
      token: token,
      questionId: qid,
      questionText: text,
      points: _num(q['points']),
      choices: choices,
      correctAnswer: correct,
    );

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
            final answer = c.text.trim();
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
            subtitle: 'Another answer that earns full credit',
            maxWidth: 400,
            actions: [
              OutlinedButton(
                  style: _outlineStyle,
                  onPressed:
                      saving ? null : () => Navigator.pop(dialogContext, false),
                  child: const Text('Cancel')),
              FilledButton(
                  style: _primaryStyle,
                  onPressed: saving ? null : save,
                  child: saving ? const _Spin() : const Text('Add')),
            ],
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Field(
                  'Answer',
                  TextField(
                    controller: c,
                    enabled: !saving,
                    autofocus: true,
                    style: _inputText,
                    decoration: _deco('Example: dart'),
                  ),
                ),
                if (error != null) _ErrorText(error!),
              ],
            ),
          );
        },
      ),
    );

    c.dispose();
    if (ok == true) {
      await _load(silent: true);
      if (mounted) _toast(context, 'Acceptable answer added successfully.');
    }
  }

  // ---------- build ----------

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
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: _Brand.ink)),
              const SizedBox(height: 14),
              Wrap(
                spacing: 10,
                children: [
                  OutlinedButton(
                      style: _outlineStyle,
                      onPressed: widget.onBack,
                      child: const Text('All exams')),
                  FilledButton(
                      style: _primaryStyle,
                      onPressed: _load,
                      child: const Text('Retry')),
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
        final description = exam['description']?.toString() ?? '';

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
                    child: Text('Exam Builder',
                        style: TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.w800,
                            color: _Brand.ink)),
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

              // Exam header
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Text('EXAMINATION',
                                style: TextStyle(
                                    fontSize: 11,
                                    letterSpacing: 0.8,
                                    fontWeight: FontWeight.w700,
                                    color: CmColors.slate)),
                            const SizedBox(width: 10),
                            _StatusPill(status),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(exam['title']?.toString() ?? 'Exam',
                            style: const TextStyle(
                                fontSize: 21,
                                fontWeight: FontWeight.w800,
                                color: _Brand.ink)),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 16,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.class_outlined,
                                    size: 14, color: CmColors.slate),
                                const SizedBox(width: 6),
                                Flexible(
                                  child: Text(_classLabel(exam['class']),
                                      style: const TextStyle(
                                          fontSize: 12.5,
                                          color: CmColors.slate)),
                                ),
                              ],
                            ),
                            if (description.isNotEmpty)
                              Text(description,
                                  style: const TextStyle(
                                      fontSize: 12.5, color: CmColors.slate)),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    style: _outlineStyle,
                    onPressed: _editDetails,
                    icon: const Icon(Icons.edit_outlined, size: 16),
                    label: const Text('Edit details'),
                  ),
                ],
              ),
              const SizedBox(height: 18),

              // Stats
              Row(
                children: [
                  Expanded(
                    child: _stat(Icons.assignment_outlined,
                        '${_sections.length}', 'Sections',
                        compact: box.maxWidth < 480),
                  ),
                  Expanded(
                    child: _stat(Icons.checklist, '$_totalQuestions', 'Questions',
                        compact: box.maxWidth < 480),
                  ),
                  Expanded(
                    child: _stat(
                        Icons.check, _trim(_totalPoints), 'Total points',
                        compact: box.maxWidth < 480),
                  ),
                ],
              ),
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

  Widget _stat(IconData icon, String value, String label,
      {bool compact = false}) {
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
              Text(value,
                  style: TextStyle(
                      fontSize: compact ? 16 : 18,
                      fontWeight: FontWeight.w800,
                      color: _Brand.ink)),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(label,
                    style:
                        const TextStyle(fontSize: 11.5, color: CmColors.slate)),
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
        Row(
          children: [
            const Text('Exam Sections',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: _Brand.ink)),
            const SizedBox(width: 6),
            Text('(${_sections.length})',
                style: const TextStyle(fontSize: 12.5, color: CmColors.slate)),
            const Spacer(),
            FilledButton.icon(
              style: _amberStyle,
              onPressed: () => _showSectionDialog(),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add section'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (_sections.isEmpty)
          const _Card(
            padding: 36,
            child: Center(
              child: Text('No sections yet',
                  style: TextStyle(fontSize: 13, color: CmColors.slate)),
            ),
          )
        else
          for (var i = 0; i < _sections.length; i++) _sectionCard(_sections[i], i),
        const SizedBox(height: 4),
        const Text('Changes updated for this session',
            style: TextStyle(fontSize: 11.5, color: CmColors.slate)),
      ],
    );
  }

  Widget _sectionCard(_Json section, int index) {
    final sid = _id(section['id']);
    final type = section['question_type']?.toString() ?? '';
    final qs = sid == null ? <_Json>[] : (_questions[sid] ?? <_Json>[]);
    final drafts = sid == null ? <Key>[] : (_drafts[sid] ?? <Key>[]);
    final expanded = sid != null && _expandedId == sid;
    final order = section['section_order']?.toString() ?? '${index + 1}';
    final name = section['name']?.toString() ?? 'Section';

    return Padding(
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
                          Text(name,
                              style: const TextStyle(
                                  fontSize: 14.5,
                                  fontWeight: FontWeight.w700,
                                  color: _Brand.ink)),
                          const SizedBox(height: 2),
                          Text(
                            '${_typeLabel(type)} · '
                            '${_fixed2(_num(section['default_points']))} pts/item · '
                            '${qs.length} ${qs.length == 1 ? 'question' : 'questions'}',
                            style: const TextStyle(
                                fontSize: 11.5, color: CmColors.slate),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Edit section',
                      visualDensity: VisualDensity.compact,
                      iconSize: 18,
                      color: CmColors.slate,
                      icon: const Icon(Icons.edit_outlined),
                      onPressed: () => _showSectionDialog(section: section),
                    ),
                    IconButton(
                      tooltip: 'Delete section',
                      visualDensity: VisualDensity.compact,
                      iconSize: 18,
                      color: CmColors.slate,
                      icon: const Icon(Icons.delete_outline),
                      onPressed:
                          sid == null ? null : () => _deleteSection(sid, name),
                    ),
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
                              Icon(Icons.description_outlined,
                                  size: 22, color: CmColors.slate),
                              SizedBox(height: 6),
                              Text('No questions yet',
                                  style: TextStyle(
                                      fontSize: 12.5, color: CmColors.slate)),
                            ],
                          ),
                        ),
                      ),
                    for (var i = 0; i < qs.length; i++)
                      _savedQuestion(qs[i], i, type),
                    for (var i = 0; i < drafts.length; i++)
                      _DraftQuestion(
                        key: drafts[i],
                        number: qs.length + i + 1,
                        type: type,
                        onDiscard: () => _discardDraft(sid, drafts[i]),
                        onSave: (text, choices, correct) =>
                            _saveQuestion(sid, drafts[i], text, choices, correct),
                      ),
                    const SizedBox(height: 4),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        style: _outlineStyle.copyWith(
                          backgroundColor:
                              WidgetStatePropertyAll(CmColors.bg),
                        ),
                        onPressed: () => _addDraft(sid),
                        icon: const Icon(Icons.add, size: 16),
                        label: const Text('Add question'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // A saved question, shown in the same layout as the editor. The pencil
  // swaps it for the inline editor (prefilled).
  Widget _savedQuestion(_Json q, int i, String type) {
    final qid = _id(q['id']);
    final number = q['question_number']?.toString() ?? '${i + 1}';

    if (qid != null && _editingQuestionId == qid) {
      return _DraftQuestion(
        key: ValueKey('edit-$qid'),
        number: int.tryParse(number) ?? i + 1,
        type: type,
        initial: q,
        saveLabel: 'Save changes',
        onDiscard: () => setState(() => _editingQuestionId = null),
        onSave: (text, choices, correct) =>
            _updateQuestion(q, text, choices, correct),
      );
    }

    final text = q['question_text']?.toString() ?? '';
    final points = _trim(_num(q['points']));
    final choices = q['choices'];
    final correct = (q['correct_answer']?.toString() ?? '').trim();
    final answers = qid == null ? <_Json>[] : (_acceptable[qid] ?? <_Json>[]);

    Widget choiceBox(int idx) {
      final letter = String.fromCharCode(65 + idx);
      final value = (choices is List && idx < choices.length)
          ? choices[idx].toString()
          : '';
      final isCorrect = correct.toUpperCase() == letter ||
          (correct.isNotEmpty && correct == value);
      return Row(
        children: [
          _Badge(letter),
          const SizedBox(width: 8),
          Expanded(child: _ReadBox(value, highlight: isCorrect)),
        ],
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Question $number',
                  style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: _Brand.ink)),
              const SizedBox(width: 8),
              Text('$points ${points == '1' ? 'pt' : 'pts'}',
                  style: const TextStyle(fontSize: 11.5, color: CmColors.slate)),
              const Spacer(),
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
                onPressed:
                    qid == null ? null : () => _deleteQuestion(qid, number),
              ),
            ],
          ),
          const SizedBox(height: 4),
          _ReadBox(text),
          if (type == 'multiple_choice' && choices is List) ...[
            const SizedBox(height: 10),
            LayoutBuilder(builder: (context, box) {
              if (box.maxWidth >= 480) {
                return Column(
                  children: [
                    Row(children: [
                      Expanded(child: choiceBox(0)),
                      const SizedBox(width: 12),
                      Expanded(child: choiceBox(1)),
                    ]),
                    const SizedBox(height: 8),
                    Row(children: [
                      Expanded(child: choiceBox(2)),
                      const SizedBox(width: 12),
                      Expanded(child: choiceBox(3)),
                    ]),
                  ],
                );
              }
              return Column(
                children: [
                  for (var k = 0; k < 4; k++)
                    Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: choiceBox(k)),
                ],
              );
            }),
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
                  Icon(Icons.check, size: 16, color: CmColors.green),
                  const SizedBox(width: 6),
                  Text('Correct answer',
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: CmColors.green)),
                ],
              ),
              SizedBox(width: 170, child: _ReadBox(correct)),
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
                  const Text('Also accepted:',
                      style: TextStyle(fontSize: 12, color: CmColors.slate)),
                for (final a in answers)
                  Chip(
                    visualDensity: VisualDensity.compact,
                    backgroundColor: CmColors.bg,
                    side: const BorderSide(color: CmColors.line),
                    label: Text(a['answer']?.toString() ?? '',
                        style: const TextStyle(
                            fontSize: 12, color: _Brand.ink)),
                  ),
                TextButton.icon(
                  onPressed: () => _addAcceptableAnswer(qid),
                  icon: const Icon(Icons.add, size: 15),
                  label: const Text('Add acceptable answer'),
                  style: TextButton.styleFrom(
                    foregroundColor: _Brand.ink,
                    textStyle: const TextStyle(
                        fontSize: 12.5, fontWeight: FontWeight.w600),
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
        const Text('Exam Papers',
            style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: _Brand.ink)),
        const SizedBox(height: 12),
        _paperCard(
          icon: Icons.description_outlined,
          title: 'Question paper',
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
          const Text('Instructions',
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w800,
                  color: _Brand.ink)),
          const SizedBox(height: 6),
          Text(instructions,
              style: const TextStyle(
                  fontSize: 12.5, height: 1.4, color: CmColors.slate)),
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
                  Text(title,
                      style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                          color: _Brand.ink)),
                  const Text('A4 · PDF document',
                      style: TextStyle(fontSize: 11.5, color: CmColors.slate)),
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
                    borderRadius: BorderRadius.circular(8)),
                textStyle:
                    const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
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
        border: Border.all(
          color: highlight ? CmColors.green : CmColors.line,
        ),
      ),
      child: Text(
        text.isEmpty ? '—' : text,
        style: const TextStyle(fontSize: 13.5, color: _Brand.ink),
      ),
    );
  }
}

// =============================================================
// DRAFT QUESTION (inline editor for a not-yet-saved question)
// =============================================================

class _DraftQuestion extends StatefulWidget {
  const _DraftQuestion({
    super.key,
    required this.number,
    required this.type,
    required this.onSave,
    required this.onDiscard,
    this.initial,
    this.saveLabel = 'Save question',
  });

  final int number;
  final String type;

  /// A saved question to edit; null for a brand-new question.
  final _Json? initial;
  final String saveLabel;
  final Future<void> Function(String text, List<String>? choices, String correct)
      onSave;
  final VoidCallback onDiscard;

  @override
  State<_DraftQuestion> createState() => _DraftQuestionState();
}

class _DraftQuestionState extends State<_DraftQuestion> {
  final _text = TextEditingController();
  final _answer = TextEditingController();
  final List<TextEditingController> _choices =
      List.generate(4, (_) => TextEditingController());

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
    final upper = correct.toUpperCase();
    if (widget.type == 'identification') {
      _answer.text = correct;
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
    _text.dispose();
    _answer.dispose();
    for (final c in _choices) {
      c.dispose();
    }
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

    final correct =
        widget.type == 'identification' ? _answer.text.trim() : (_picked ?? '');
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
    return Row(
      children: [
        _Badge(letter),
        const SizedBox(width: 8),
        Expanded(
          child: TextField(
            controller: _choices[i],
            enabled: !_saving,
            style: _inputText,
            decoration: _deco('Option $letter'),
          ),
        ),
      ],
    );
  }

  Widget _correctControl() {
    switch (widget.type) {
      case 'identification':
        return TextField(
          controller: _answer,
          enabled: !_saving,
          style: _inputText,
          decoration: _deco('Accepted answer'),
        );
      case 'true_false':
      case 'multiple_choice':
        final options = widget.type == 'true_false'
            ? const ['True', 'False']
            : const ['A', 'B', 'C', 'D'];
        return DropdownButtonFormField<String>(
          initialValue: _picked,
          isExpanded: true,
          style: _inputText,
          decoration: _deco('Select answer'),
          items: [
            for (final o in options) DropdownMenuItem(value: o, child: Text(o)),
          ],
          onChanged: _saving ? null : (v) => setState(() => _picked = v),
        );
      default:
        return const SizedBox.shrink();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Question ${widget.number}',
                  style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: _Brand.ink)),
              const Spacer(),
              IconButton(
                tooltip: widget.initial == null
                    ? 'Discard question'
                    : 'Cancel editing',
                visualDensity: VisualDensity.compact,
                iconSize: 17,
                color: CmColors.slate,
                icon: Icon(widget.initial == null
                    ? Icons.delete_outline
                    : Icons.close),
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
            LayoutBuilder(builder: (context, box) {
              if (box.maxWidth >= 480) {
                return Column(
                  children: [
                    Row(children: [
                      Expanded(child: _choiceField(0)),
                      const SizedBox(width: 12),
                      Expanded(child: _choiceField(1)),
                    ]),
                    const SizedBox(height: 8),
                    Row(children: [
                      Expanded(child: _choiceField(2)),
                      const SizedBox(width: 12),
                      Expanded(child: _choiceField(3)),
                    ]),
                  ],
                );
              }
              return Column(
                children: [
                  for (var k = 0; k < 4; k++)
                    Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _choiceField(k)),
                ],
              );
            }),
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
                  Icon(Icons.check, size: 16, color: CmColors.green),
                  const SizedBox(width: 6),
                  Text('Correct answer',
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: CmColors.green)),
                ],
              ),
              SizedBox(width: 170, child: _correctControl()),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            _ErrorText(_error!),
          ],
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              style: _primaryStyle.copyWith(
                minimumSize: const WidgetStatePropertyAll(Size(0, 36)),
              ),
              onPressed: _saving ? null : _submit,
              child: _saving ? const _Spin() : Text(widget.saveLabel),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================
// PAPER PREVIEW POPUP (question paper + answer sheet)
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
          border:
              Border.all(color: selected ? CmColors.line : Colors.transparent),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 15, color: selected ? _Brand.ink : CmColors.slate),
            const SizedBox(width: 6),
            Text(label,
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected ? _Brand.ink : CmColors.slate)),
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
                        const Text('Paper preview',
                            style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                                color: _Brand.ink)),
                        const SizedBox(height: 2),
                        Text(
                          '$q ${q == 1 ? 'question' : 'questions'} · '
                          '${_trim(widget.totalPoints)} '
                          '${widget.totalPoints == 1 ? 'point' : 'points'}',
                          style: const TextStyle(
                              fontSize: 12, color: CmColors.slate),
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
                        _tab('Question paper', Icons.description_outlined,
                            !_answerSheet,
                            () => setState(() => _answerSheet = false)),
                        _tab('Answer sheet', Icons.document_scanner_outlined,
                            _answerSheet,
                            () => setState(() => _answerSheet = true)),
                      ],
                    ),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                  IconButton(
                    tooltip: 'Print',
                    style: IconButton.styleFrom(
                        side: const BorderSide(color: CmColors.line)),
                    icon: const Icon(Icons.print_outlined, size: 18),
                    color: _Brand.ink,
                    onPressed: () => widget.onPrint(_answerSheet),
                  ),
                  const SizedBox(width: 6),
                  IconButton(
                    tooltip: 'Download',
                    style: IconButton.styleFrom(
                        side: const BorderSide(color: CmColors.line)),
                    icon: const Icon(Icons.file_download_outlined, size: 18),
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
                          child: Text(_err(error),
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: _Brand.ink)),
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
