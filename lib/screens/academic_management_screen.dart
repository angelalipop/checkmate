import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../services/academic_api_service.dart';
import '../services/auth_storage.dart';
import '../services/curriculum_file_parser.dart';
import '../services/curriculum_template.dart';
import 'login_screen.dart' show CmColors;

// =============================================================
// Academic Management — Curricula and Subjects.
// Built on the same patterns as the Teachers screen (navy/slate palette,
// rounded fields, dialogs, empty states). Every action calls the Dart Frog
// server, which reads and writes PostgreSQL. Nothing is mocked or stored
// in the browser. Teacher assignment and student import are not here.
// =============================================================

const Color _activeGreen = Color(0xFF2F8F72);
const Color _dangerRed = Color(0xFFDC2626);
const Color _draftBlue = Color(0xFF2F63B8);

// Icons used for the program list.
const IconData _collegeIcon = Icons.apartment_outlined; // campus building
const IconData _shsIcon = Icons.domain_outlined; // school building
const IconData _programIcon = Icons.local_library_outlined; // learning library

typedef _M = Map<String, dynamic>;

int? _idOf(_M m, [String key = 'id']) => int.tryParse(m[key]?.toString() ?? '');

String _s(Object? v) => v?.toString().trim() ?? '';

bool _isShs(_M? program) => program != null && program['level'] == 'shs';

String _yearLabel(bool shs, int y) {
  if (shs) return 'Grade ${10 + y}';
  const names = ['1st', '2nd', '3rd', '4th'];
  return '${names[y - 1]} Year';
}

String _termLabel(bool shs, int t) {
  if (shs) return t == 1 ? '1st Term' : '2nd Term';
  return t == 1 ? '1st Semester' : '2nd Semester';
}

String _currentSchoolYear() {
  final now = DateTime.now();
  final start = now.month >= 6 ? now.year : now.year - 1;
  return '$start-${start + 1}';
}

List<String> _schoolYearOptions() {
  final current = int.parse(_currentSchoolYear().substring(0, 4));
  return [for (var y = current - 2; y <= current + 2; y++) '$y-${y + 1}'];
}

String _cleanError(Object e) => e.toString().replaceFirst('Exception: ', '');

String _unitsText(Object? v) {
  final d = double.tryParse(v?.toString() ?? '');
  if (d == null) return '';
  return d == d.roundToDouble() ? d.toInt().toString() : d.toString();
}

// ---------- shared form styling (same look as the Teachers dialogs) ----------

InputDecoration _fieldDecoration({String? hint, String? errorText}) {
  OutlineInputBorder border(Color c, [double w = 1]) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(12),
    borderSide: BorderSide(color: c, width: w),
  );

  return InputDecoration(
    isDense: true,
    filled: true,
    fillColor: Colors.white,
    hintText: hint,
    errorText: errorText,
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    border: border(CmColors.line),
    enabledBorder: border(CmColors.line),
    focusedBorder: border(CmColors.navy, 1.5),
    errorBorder: border(_dangerRed),
    focusedErrorBorder: border(_dangerRed, 1.5),
  );
}

Widget _labeled(String label, Widget field) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 13,
            color: CmColors.slate,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
      field,
    ],
  );
}

ButtonStyle get _primaryButtonStyle => FilledButton.styleFrom(
  backgroundColor: CmColors.navy,
  disabledBackgroundColor: const Color(0xFF9AA3B2),
  disabledForegroundColor: Colors.white,
  minimumSize: const Size(0, 44),
  padding: const EdgeInsets.symmetric(horizontal: 18),
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
);

ButtonStyle get _secondaryButtonStyle => OutlinedButton.styleFrom(
  foregroundColor: CmColors.navy,
  backgroundColor: CmColors.bg,
  side: const BorderSide(color: CmColors.line),
  minimumSize: const Size(0, 44),
  padding: const EdgeInsets.symmetric(horizontal: 18),
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
);

ButtonStyle get _dangerOutlineStyle => OutlinedButton.styleFrom(
  foregroundColor: _dangerRed,
  side: BorderSide(color: _dangerRed.withValues(alpha: 0.4)),
  minimumSize: const Size(0, 44),
  padding: const EdgeInsets.symmetric(horizontal: 18),
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
);

Widget _dialogShell({required Widget child, double maxWidth = 520}) {
  return Dialog(
    backgroundColor: Colors.white,
    surfaceTintColor: Colors.transparent,
    insetPadding: const EdgeInsets.all(24),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
        child: child,
      ),
    ),
  );
}

Widget _dialogHeader(String title, VoidCallback? onClose) {
  return Row(
    children: [
      Expanded(
        child: Text(
          title,
          style: const TextStyle(
            fontSize: 19,
            fontWeight: FontWeight.w700,
            color: CmColors.navy,
          ),
        ),
      ),
      IconButton(
        tooltip: 'Close',
        icon: const Icon(Icons.close, size: 20),
        onPressed: onClose,
      ),
    ],
  );
}

Widget _spinner() => const SizedBox(
  width: 20,
  height: 20,
  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
);

Widget _badge(String text, Color color) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      text,
      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: color),
    ),
  );
}

// =============================================================
// DIALOGS
// =============================================================

/// Add / edit a program or Senior High School strand.
class _ProgramDialog extends StatefulWidget {
  const _ProgramDialog({this.initial, required this.departments});

  final _M? initial;
  final List<String> departments;

  @override
  State<_ProgramDialog> createState() => _ProgramDialogState();
}

class _ProgramDialogState extends State<_ProgramDialog> {
  late String _level = _s(widget.initial?['level']).isEmpty
      ? 'college'
      : _s(widget.initial?['level']);
  late final _code = TextEditingController(text: _s(widget.initial?['code']));
  late final _name = TextEditingController(text: _s(widget.initial?['name']));
  late final _dept = TextEditingController(
    text: _s(widget.initial?['department']),
  );
  String? _codeError;
  String? _nameError;
  String? _deptError;

  bool get _editing => widget.initial != null;
  bool get _levelLocked =>
      _editing &&
      (int.tryParse('${widget.initial?['curriculum_count']}') ?? 0) > 0;

  @override
  void dispose() {
    _code.dispose();
    _name.dispose();
    _dept.dispose();
    super.dispose();
  }

  void _submit() {
    final code = _code.text.trim().toUpperCase();
    final name = _name.text.trim();
    final dept = _dept.text.trim();
    setState(() {
      _codeError = RegExp(r'^[A-Za-z0-9][A-Za-z0-9 _-]{1,19}$').hasMatch(code)
          ? null
          : 'Use 2 to 20 letters or numbers (e.g. BSIT).';
      _nameError = name.isEmpty ? 'Program name is required.' : null;
      _deptError = _level == 'college' && dept.isEmpty
          ? 'Department is required for a college program.'
          : null;
    });
    if (_codeError != null || _nameError != null || _deptError != null) return;

    Navigator.pop<_M>(context, {
      'code': code,
      'name': name,
      'level': _level,
      'department': _level == 'college' ? dept : null,
    });
  }

  @override
  Widget build(BuildContext context) {
    final shs = _level == 'shs';
    return _dialogShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _dialogHeader(
            _editing
                ? (shs ? 'Edit Strand' : 'Edit Program')
                : (shs ? 'Add Strand' : 'Add Program'),
            () => Navigator.pop(context),
          ),
          const SizedBox(height: 12),
          _labeled(
            'Level',
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                  value: 'college',
                  label: Text('College'),
                  icon: Icon(_collegeIcon),
                ),
                ButtonSegment(
                  value: 'shs',
                  label: Text('Senior High'),
                  icon: Icon(_shsIcon),
                ),
              ],
              selected: {_level},
              onSelectionChanged: _levelLocked
                  ? null
                  : (s) => setState(() => _level = s.first),
            ),
          ),
          if (_levelLocked)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                'The level cannot change after curricula exist.',
                style: TextStyle(fontSize: 12, color: CmColors.slate),
              ),
            ),
          const SizedBox(height: 14),
          _labeled(
            shs ? 'Strand code' : 'Program code',
            TextField(
              controller: _code,
              textCapitalization: TextCapitalization.characters,
              decoration: _fieldDecoration(
                hint: shs ? 'e.g. STEM' : 'e.g. BSIT',
                errorText: _codeError,
              ),
            ),
          ),
          const SizedBox(height: 14),
          _labeled(
            shs ? 'Strand name' : 'Program name',
            TextField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
              decoration: _fieldDecoration(
                hint: shs
                    ? 'e.g. Science, Technology, Engineering, and Mathematics'
                    : 'e.g. Bachelor of Science in Information Technology',
                errorText: _nameError,
              ),
            ),
          ),
          if (!shs) ...[
            const SizedBox(height: 14),
            _labeled(
              'Department',
              TextField(
                controller: _dept,
                textCapitalization: TextCapitalization.words,
                decoration: _fieldDecoration(
                  hint: 'Select a department below or enter another',
                  errorText: _deptError,
                ),
              ),
            ),
            if (widget.departments.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final d in widget.departments)
                    ActionChip(
                      label: Text(d, style: const TextStyle(fontSize: 12)),
                      onPressed: () => setState(() => _dept.text = d),
                    ),
                ],
              ),
            ],
          ],
          const SizedBox(height: 22),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  style: _secondaryButtonStyle,
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  style: _primaryButtonStyle,
                  onPressed: _submit,
                  child: Text(_editing ? 'Save Changes' : 'Save'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// New curriculum version: a copy of an existing curriculum, or one read from
/// an uploaded file (the Excel Sample Guide or the STI Program Guide PDF).
class _CurriculumDialog extends StatefulWidget {
  const _CurriculumDialog({
    required this.program,
    required this.curricula,
    this.initialCopyId,
  });

  final _M program;
  final List<_M> curricula;
  final int? initialCopyId;

  @override
  State<_CurriculumDialog> createState() => _CurriculumDialogState();
}

enum _Source { copy, upload }

class _CurriculumDialogState extends State<_CurriculumDialog> {
  final _code = TextEditingController();
  late _Source _source = widget.curricula.isNotEmpty
      ? _Source.copy
      : _Source.upload;
  late int? _copyId =
      widget.initialCopyId ??
      (widget.curricula.isEmpty ? null : _idOf(widget.curricula.first));
  String? _codeError;
  String? _fileError;
  String? _info;
  String? _fileName;
  ParsedCurriculumFile? _parsed;
  bool _reading = false;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  String get _programCode => _s(widget.program['code']);

  String? _mismatch(ParsedCurriculumFile parsed) {
    final found = parsed.programCode?.toUpperCase();
    if (found != null && found != _programCode.toUpperCase()) {
      return 'This file is for $found, but $_programCode is selected.';
    }
    return null;
  }

  Future<void> _pickFile() async {
    setState(() {
      _fileError = null;
      _info = null;
      _reading = true;
    });
    try {
      final file = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(label: 'Curriculum', extensions: ['xlsx', 'pdf', 'csv']),
        ],
      );
      if (file == null) {
        if (mounted) setState(() => _reading = false);
        return;
      }
      final bytes = await file.readAsBytes();
      final parsed = CurriculumFileParser.parse(bytes, file.name);
      if (!mounted) return;
      setState(() {
        _fileName = file.name;
        _parsed = parsed;
        _reading = false;
        _fileError = _mismatch(parsed);
        if (_code.text.trim().isEmpty && parsed.curriculumCode != null) {
          _code.text = parsed.curriculumCode!;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _parsed = null;
        _fileName = null;
        _fileError = _cleanError(e);
        _reading = false;
      });
    }
  }

  Future<void> _downloadSample() async {
    setState(() {
      _fileError = null;
      _info = null;
    });
    try {
      final bytes = CurriculumTemplate.buildXlsx();
      final file = XFile.fromData(
        bytes,
        name: CurriculumTemplate.fileName,
        mimeType: CurriculumTemplate.mimeType,
      );
      if (kIsWeb) {
        await file.saveTo(CurriculumTemplate.fileName);
      } else {
        final location = await getSaveLocation(
          suggestedName: CurriculumTemplate.fileName,
          acceptedTypeGroups: const [
            XTypeGroup(label: 'Excel', extensions: ['xlsx']),
          ],
        );
        if (location == null) return;
        await file.saveTo(location.path);
      }
      if (mounted) {
        setState(
          () => _info = 'Sample guide saved (${CurriculumTemplate.fileName}).',
        );
      }
    } catch (e) {
      if (mounted) {
        setState(
          () =>
              _fileError = 'Could not save the sample guide: ${_cleanError(e)}',
        );
      }
    }
  }

  void _submit() {
    final code = _code.text.trim().toUpperCase();
    setState(() {
      _codeError = RegExp(r'^[0-9A-Za-z-]{2,20}$').hasMatch(code)
          ? null
          : 'Use 2 to 20 letters, numbers or dashes (e.g. 2601).';
      _fileError = null;
    });
    if (_codeError != null) return;

    if (_source == _Source.copy && _copyId == null) {
      setState(() => _fileError = 'Choose the curriculum to copy.');
      return;
    }
    if (_source == _Source.upload) {
      final parsed = _parsed;
      if (parsed == null) {
        setState(() => _fileError = 'Choose the file to upload.');
        return;
      }
      final mismatch = _mismatch(parsed);
      if (mismatch != null) {
        setState(() => _fileError = mismatch);
        return;
      }
      if (parsed.problems.isNotEmpty) {
        setState(
          () => _fileError = 'Fix the file problems below and upload again.',
        );
        return;
      }
      if (parsed.rows.isEmpty && parsed.electives.isEmpty) {
        setState(() => _fileError = 'The file has no subjects to import.');
        return;
      }
    }

    Navigator.pop<_M>(context, {
      'code': code,
      'copy_from_id': _source == _Source.copy ? _copyId : null,
      'rows': _source == _Source.upload ? _parsed!.rows : null,
      'electives': _source == _Source.upload ? _parsed!.electives : null,
    });
  }

  Widget _sourceChip(String label, _Source value, {bool enabled = true}) {
    final selected = _source == value;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      showCheckmark: false,
      selectedColor: CmColors.navy,
      labelStyle: TextStyle(
        color: selected ? Colors.white : CmColors.navy,
        fontWeight: FontWeight.w600,
      ),
      onSelected: enabled ? (_) => setState(() => _source = value) : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final parsed = _parsed;
    final hasOlder = widget.curricula.isNotEmpty;

    return _dialogShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _dialogHeader('New Curriculum', () => Navigator.pop(context)),
          Text(
            '$_programCode · the new version starts as a draft you can edit.',
            style: const TextStyle(color: CmColors.slate, fontSize: 13),
          ),
          const SizedBox(height: 14),
          _labeled(
            'Curriculum code',
            TextField(
              controller: _code,
              textCapitalization: TextCapitalization.characters,
              decoration: _fieldDecoration(
                hint: 'e.g. 2601',
                errorText: _codeError,
              ),
            ),
          ),
          const SizedBox(height: 14),
          _labeled(
            'Start from',
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                _sourceChip('Copy existing', _Source.copy, enabled: hasOlder),
                _sourceChip('Upload file', _Source.upload),
              ],
            ),
          ),
          if (!hasOlder)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                'There is no curriculum to copy yet. Upload a file instead.',
                style: TextStyle(fontSize: 12, color: CmColors.slate),
              ),
            ),
          if (_source == _Source.copy && hasOlder) ...[
            const SizedBox(height: 10),
            DropdownButtonFormField<int>(
              initialValue: _copyId,
              isExpanded: true,
              decoration: _fieldDecoration(),
              items: [
                for (final c in widget.curricula)
                  DropdownMenuItem(
                    value: _idOf(c),
                    child: Text(
                      '$_programCode ${c['code']} '
                      '(${c['status'] == 'published' ? 'Published' : 'Draft'}, '
                      '${c['subject_count']} subjects)',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (v) => setState(() => _copyId = v),
            ),
            const SizedBox(height: 6),
            const Text(
              'Every subject and elective is copied. Change only what is new in the draft.',
              style: TextStyle(fontSize: 12, color: CmColors.slate),
            ),
          ],
          if (_source == _Source.upload) ...[
            const SizedBox(height: 12),
            const Text(
              'Upload one of these:',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            const Text(
              '·  The Excel Sample Guide, filled in and named Program_Curriculum '
              '(for example BSIT_2601.xlsx).\n'
              '·  The STI Program Guide PDF from the STI website '
              '(for example STI_College_BSAIS_Program.pdf). The program and '
              'curriculum (BSAIS-24-01 = 2401) are read from the file.',
              style: TextStyle(
                fontSize: 12,
                color: CmColors.slate,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'OJT and practicum subjects are skipped.',
              style: TextStyle(fontSize: 12, color: CmColors.slate),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  style: _secondaryButtonStyle,
                  onPressed: _reading ? null : _downloadSample,
                  icon: const Icon(Icons.download_outlined),
                  label: const Text('Download Sample Guide (.xlsx)'),
                ),
                FilledButton.icon(
                  style: _primaryButtonStyle,
                  onPressed: _reading ? null : _pickFile,
                  icon: _reading
                      ? _spinner()
                      : const Icon(Icons.upload_file_outlined),
                  label: Text(_fileName ?? 'Choose File'),
                ),
              ],
            ),
            if (parsed != null) ...[
              const SizedBox(height: 12),
              Text(
                '${parsed.rows.length} subjects · ${parsed.electives.length} electives'
                '${parsed.skippedOjt > 0 ? ' · ${parsed.skippedOjt} OJT/practicum rows skipped' : ''}',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: CmColors.navy,
                ),
              ),
              if (parsed.programCode != null || parsed.curriculumCode != null)
                Text(
                  'Found in file: ${parsed.programCode ?? '?'} · ${parsed.curriculumCode ?? '?'}',
                  style: const TextStyle(fontSize: 12, color: CmColors.slate),
                ),
              for (final p in parsed.problems.take(6))
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    p,
                    style: const TextStyle(fontSize: 12, color: _dangerRed),
                  ),
                ),
              if (parsed.problems.length > 6)
                Text(
                  '+ ${parsed.problems.length - 6} more problems',
                  style: const TextStyle(fontSize: 12, color: _dangerRed),
                ),
            ],
          ],
          if (_info != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                _info!,
                style: const TextStyle(fontSize: 13, color: _activeGreen),
              ),
            ),
          if (_fileError != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                _fileError!,
                style: const TextStyle(fontSize: 13, color: _dangerRed),
              ),
            ),
          const SizedBox(height: 22),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  style: _secondaryButtonStyle,
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  style: _primaryButtonStyle,
                  onPressed: _reading ? null : _submit,
                  child: const Text('Create Draft'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One text field in a dialog (used to rename a curriculum code).
class _CodeDialog extends StatefulWidget {
  const _CodeDialog({required this.title, required this.initial});

  final String title;
  final String initial;

  @override
  State<_CodeDialog> createState() => _CodeDialogState();
}

class _CodeDialogState extends State<_CodeDialog> {
  late final _c = TextEditingController(text: widget.initial);
  String? _error;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _submit() {
    final v = _c.text.trim().toUpperCase();
    if (!RegExp(r'^[0-9A-Za-z-]{2,20}$').hasMatch(v)) {
      setState(() => _error = 'Use 2 to 20 letters, numbers or dashes.');
      return;
    }
    Navigator.pop<String>(context, v);
  }

  @override
  Widget build(BuildContext context) {
    return _dialogShell(
      maxWidth: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _dialogHeader(widget.title, () => Navigator.pop(context)),
          const SizedBox(height: 8),
          _labeled(
            'Curriculum code',
            TextField(
              controller: _c,
              textCapitalization: TextCapitalization.characters,
              decoration: _fieldDecoration(errorText: _error),
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  style: _secondaryButtonStyle,
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  style: _primaryButtonStyle,
                  onPressed: _submit,
                  child: const Text('Save Changes'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Add / edit a term subject, or an entry of the list of electives.
/// Existing subjects are searched in the shared catalog so a subject that
/// already exists in another curriculum is reused, not duplicated.
class _SubjectDialog extends StatefulWidget {
  const _SubjectDialog({
    required this.title,
    required this.shs,
    required this.search,
    this.initial,
    this.electiveMode = false,
    this.year = 1,
    this.term = 1,
    this.groups = const [],
  });

  final String title;
  final bool shs;
  final Future<List<_M>> Function(String q) search;
  final _M? initial;
  final bool electiveMode;
  final int year;
  final int term;
  final List<String> groups;

  @override
  State<_SubjectDialog> createState() => _SubjectDialogState();
}

class _SubjectDialogState extends State<_SubjectDialog> {
  late final _code = TextEditingController(text: _s(widget.initial?['code']));
  late final _name = TextEditingController(text: _s(widget.initial?['name']));
  late final _hours = TextEditingController(
    text: widget.initial?['hours'] == null ? '' : '${widget.initial?['hours']}',
  );
  late final _group = TextEditingController(
    text: _s(widget.initial?['group_name']),
  );
  late final _units = TextEditingController(
    text: widget.initial != null
        ? _unitsText(widget.initial?['units'])
        : (widget.shs ? '' : '3'),
  );
  final _find = TextEditingController();

  late int _year = (widget.initial?['year_level'] as int?) ?? widget.year;
  late int _term = (widget.initial?['term'] as int?) ?? widget.term;
  late bool _slot = widget.initial?['is_elective_slot'] == true;
  late String? _category = _s(widget.initial?['category']).isEmpty
      ? null
      : _s(widget.initial?['category']);
  late int? _subjectId = widget.initial == null
      ? null
      : int.tryParse('${widget.initial?['subject_id']}');

  List<_M> _results = [];
  bool _searching = false;
  Timer? _debounce;
  String? _codeError;
  String? _nameError;
  String? _categoryError;
  String? _hoursError;
  String? _unitsError;

  bool get _locked => _subjectId != null;

  @override
  void dispose() {
    _debounce?.cancel();
    _code.dispose();
    _name.dispose();
    _hours.dispose();
    _group.dispose();
    _units.dispose();
    _find.dispose();
    super.dispose();
  }

  void _onFind(String q) {
    _debounce?.cancel();
    if (q.trim().length < 2) {
      setState(() => _results = []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      setState(() => _searching = true);
      try {
        final found = await widget.search(q.trim());
        if (!mounted) return;
        setState(() {
          _results = found;
          _searching = false;
        });
      } catch (_) {
        if (!mounted) return;
        setState(() => _searching = false);
      }
    });
  }

  void _pick(_M subject) {
    setState(() {
      _subjectId = _idOf(subject);
      _code.text = _s(subject['code']);
      _name.text = _s(subject['name']);
      _hours.text = subject['hours'] == null ? '' : '${subject['hours']}';
      _units.text = _unitsText(subject['units']);
      _results = [];
      _find.clear();
    });
  }

  void _unlock() {
    setState(() {
      _subjectId = null;
      _code.clear();
      _name.clear();
      _hours.clear();
      _units.text = widget.shs ? '' : '3';
    });
  }

  void _submit() {
    final code = _code.text.trim().toUpperCase();
    final name = _name.text.trim();

    setState(() {
      _codeError = null;
      _nameError = null;
      _categoryError = null;
      _hoursError = null;
      _unitsError = null;

      if (!_locked) {
        if (name.isEmpty) _nameError = 'Course name is required.';
        if (!widget.shs && code.isEmpty) {
          _codeError = 'Course code is required.';
        } else if (code.isNotEmpty &&
            !RegExp(r'^[A-Za-z0-9][A-Za-z0-9 ._/-]{1,29}$').hasMatch(code)) {
          _codeError = 'Course code looks invalid (e.g. GEDC1002).';
        }
      }
      if (widget.shs && !widget.electiveMode && _category == null) {
        _categoryError = 'Choose Core, Applied or Specialized.';
      }
      if (widget.shs &&
          _hours.text.trim().isNotEmpty &&
          int.tryParse(_hours.text.trim()) == null) {
        _hoursError = 'Hours must be a whole number.';
      }
      if (!_locked && !widget.shs) {
        final u = double.tryParse(_units.text.trim());
        if (_units.text.trim().isNotEmpty && (u == null || u < 0 || u > 99)) {
          _unitsError = 'Units must be a number.';
        }
      }
    });
    if (_codeError != null ||
        _nameError != null ||
        _categoryError != null ||
        _hoursError != null ||
        _unitsError != null) {
      return;
    }

    final body = <String, dynamic>{};
    if (_locked) {
      body['subject_id'] = _subjectId;
    } else {
      body['name'] = name;
      if (code.isNotEmpty) body['code'] = code;
      if (widget.shs && _hours.text.trim().isNotEmpty) {
        body['hours'] = _hours.text.trim();
      }
      if (!widget.shs && _units.text.trim().isNotEmpty) {
        body['units'] = _units.text.trim();
      }
    }

    if (widget.electiveMode) {
      body['group_name'] = _group.text.trim().isEmpty
          ? null
          : _group.text.trim();
    } else {
      body['year_level'] = _year;
      body['term'] = _term;
      body['category'] = widget.shs ? _category : null;
      body['is_elective_slot'] = !widget.shs && _slot;
    }
    Navigator.pop<_M>(context, body);
  }

  @override
  Widget build(BuildContext context) {
    final yearCount = widget.shs ? 2 : 4;

    return _dialogShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _dialogHeader(widget.title, () => Navigator.pop(context)),
          const SizedBox(height: 4),
          if (!_locked) ...[
            _labeled(
              'Search existing subjects',
              TextField(
                controller: _find,
                onChanged: _onFind,
                decoration: _fieldDecoration(hint: 'Type a course code or name')
                    .copyWith(
                      prefixIcon: const Icon(Icons.search, size: 20),
                      suffixIcon: _searching
                          ? const Padding(
                              padding: EdgeInsets.all(12),
                              child: SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            )
                          : null,
                    ),
              ),
            ),
            if (_results.isNotEmpty)
              Container(
                margin: const EdgeInsets.only(top: 6),
                constraints: const BoxConstraints(maxHeight: 180),
                decoration: BoxDecoration(
                  border: Border.all(color: CmColors.line),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final r in _results)
                      ListTile(
                        dense: true,
                        title: Text(
                          _s(r['code']).isEmpty
                              ? _s(r['name'])
                              : '${r['code']}  ${r['name']}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => _pick(r),
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 6),
            const Text(
              'Or enter a new subject below.',
              style: TextStyle(fontSize: 12, color: CmColors.slate),
            ),
            const SizedBox(height: 12),
          ],
          _labeled(
            widget.shs ? 'Course code (optional)' : 'Course code',
            TextField(
              controller: _code,
              enabled: !_locked,
              textCapitalization: TextCapitalization.characters,
              decoration: _fieldDecoration(
                hint: 'e.g. GEDC1002',
                errorText: _codeError,
              ),
            ),
          ),
          const SizedBox(height: 14),
          _labeled(
            'Course name',
            TextField(
              controller: _name,
              enabled: !_locked,
              textCapitalization: TextCapitalization.words,
              decoration: _fieldDecoration(
                hint: 'e.g. The Contemporary World',
                errorText: _nameError,
              ),
            ),
          ),
          if (!widget.shs) ...[
            const SizedBox(height: 14),
            _labeled(
              'Units',
              SizedBox(
                width: 140,
                child: TextField(
                  controller: _units,
                  enabled: !_locked,
                  keyboardType: TextInputType.number,
                  decoration: _fieldDecoration(
                    hint: 'e.g. 3',
                    errorText: _unitsError,
                  ),
                ),
              ),
            ),
          ],
          if (_locked)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _unlock,
                icon: const Icon(Icons.swap_horiz, size: 18),
                label: const Text('Use a different subject'),
              ),
            ),
          if (widget.electiveMode) ...[
            const SizedBox(height: 14),
            _labeled(
              'Group (optional)',
              TextField(
                controller: _group,
                textCapitalization: TextCapitalization.words,
                decoration: _fieldDecoration(
                  hint: 'e.g. Application Development',
                ),
              ),
            ),
            if (widget.groups.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final g in widget.groups)
                    ActionChip(
                      label: Text(g, style: const TextStyle(fontSize: 12)),
                      onPressed: () => setState(() => _group.text = g),
                    ),
                ],
              ),
            ],
          ] else ...[
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: _labeled(
                    widget.shs ? 'Grade' : 'Year level',
                    DropdownButtonFormField<int>(
                      initialValue: _year,
                      decoration: _fieldDecoration(),
                      items: [
                        for (var y = 1; y <= yearCount; y++)
                          DropdownMenuItem(
                            value: y,
                            child: Text(_yearLabel(widget.shs, y)),
                          ),
                      ],
                      onChanged: (v) => setState(() => _year = v ?? _year),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _labeled(
                    widget.shs ? 'Term' : 'Semester',
                    DropdownButtonFormField<int>(
                      initialValue: _term,
                      decoration: _fieldDecoration(),
                      items: [
                        for (var t = 1; t <= 2; t++)
                          DropdownMenuItem(
                            value: t,
                            child: Text(_termLabel(widget.shs, t)),
                          ),
                      ],
                      onChanged: (v) => setState(() => _term = v ?? _term),
                    ),
                  ),
                ),
              ],
            ),
            if (widget.shs) ...[
              const SizedBox(height: 14),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _labeled(
                      'Subject group',
                      DropdownButtonFormField<String>(
                        initialValue: _category,
                        decoration: _fieldDecoration(errorText: _categoryError),
                        items: const [
                          DropdownMenuItem(value: 'core', child: Text('Core')),
                          DropdownMenuItem(
                            value: 'applied',
                            child: Text('Applied'),
                          ),
                          DropdownMenuItem(
                            value: 'specialized',
                            child: Text('Specialized'),
                          ),
                        ],
                        onChanged: (v) => setState(() => _category = v),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _labeled(
                      'Required hours',
                      TextField(
                        controller: _hours,
                        enabled: !_locked,
                        keyboardType: TextInputType.number,
                        decoration: _fieldDecoration(
                          hint: 'e.g. 80',
                          errorText: _hoursError,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ] else ...[
              const SizedBox(height: 6),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                activeThumbColor: CmColors.navy,
                title: const Text('This is an elective slot'),
                subtitle: const Text(
                  'An elective from the list can be finalized for it each school year.',
                  style: TextStyle(fontSize: 12),
                ),
                value: _slot,
                onChanged: (v) => setState(() => _slot = v),
              ),
            ],
          ],
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  style: _secondaryButtonStyle,
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  style: _primaryButtonStyle,
                  onPressed: _submit,
                  child: Text(widget.initial == null ? 'Save' : 'Save Changes'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Finalize (or clear) the elective chosen for a slot in a school year.
class _ElectiveChoiceDialog extends StatefulWidget {
  const _ElectiveChoiceDialog({
    required this.slot,
    required this.electives,
    required this.schoolYear,
  });

  final _M slot;
  final List<_M> electives;
  final String schoolYear;

  @override
  State<_ElectiveChoiceDialog> createState() => _ElectiveChoiceDialogState();
}

class _ElectiveChoiceDialogState extends State<_ElectiveChoiceDialog> {
  late int? _chosen = widget.slot['selection'] is Map
      ? int.tryParse('${(widget.slot['selection'] as Map)['elective_id']}')
      : null;

  @override
  Widget build(BuildContext context) {
    final hasChoice = widget.slot['selection'] is Map;
    final slotName = _s(widget.slot['name']);

    return _dialogShell(
      maxWidth: 460,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _dialogHeader('Choose Elective', () => Navigator.pop(context)),
          Text(
            '$slotName · School year ${widget.schoolYear}',
            style: const TextStyle(color: CmColors.slate, fontSize: 13),
          ),
          const SizedBox(height: 14),
          _labeled(
            'Elective',
            DropdownButtonFormField<int>(
              initialValue: _chosen,
              isExpanded: true,
              decoration: _fieldDecoration(hint: 'Select from the list'),
              items: [
                for (final e in widget.electives)
                  DropdownMenuItem(
                    value: _idOf(e),
                    child: Text(
                      '${e['code']}  ${e['name']}'
                      '${_s(e['group_name']).isEmpty ? '' : '  (${e['group_name']})'}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (v) => setState(() => _chosen = v),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Until an elective is finalized, the subject stays as listed.',
            style: TextStyle(fontSize: 12, color: CmColors.slate),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              if (hasChoice) ...[
                Expanded(
                  child: OutlinedButton(
                    style: _dangerOutlineStyle,
                    onPressed: () =>
                        Navigator.pop<_M>(context, {'action': 'clear'}),
                    child: const Text('Clear Choice'),
                  ),
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: FilledButton(
                  style: _primaryButtonStyle,
                  onPressed: _chosen == null
                      ? null
                      : () => Navigator.pop<_M>(context, {
                          'action': 'set',
                          'elective_id': _chosen,
                        }),
                  child: const Text('Finalize'),
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
// SCREEN
// =============================================================

class AcademicManagementScreen extends StatefulWidget {
  const AcademicManagementScreen({super.key});

  @override
  State<AcademicManagementScreen> createState() =>
      _AcademicManagementScreenState();
}

class _AcademicManagementScreenState extends State<AcademicManagementScreen> {
  // programs
  List<_M> _programs = [];
  bool _loadingPrograms = true;
  String? _programsError;
  final _programSearch = TextEditingController();
  String _programQuery = '';
  _M? _program;

  // curricula of the selected program
  List<_M> _curricula = [];
  bool _loadingCurricula = false;
  String? _curriculaError;
  int? _curriculumId;
  String _statusFilter = 'All';

  // selected context
  int _year = 1;
  int _term = 1;
  String _schoolYear = _currentSchoolYear();
  int _tab = 0; // 0 = Curricula, 1 = Subjects

  // subjects + electives of the selected context
  List<_M> _subjects = [];
  List<_M> _electives = [];
  bool _loadingSubjects = false;
  String? _subjectsError;
  final _subjectSearch = TextEditingController();
  String _subjectQuery = '';

  bool _busy = false;
  bool _showElectiveTools = false;
  int? _toolsFor;

  @override
  void initState() {
    super.initState();
    _loadPrograms();
  }

  @override
  void dispose() {
    _programSearch.dispose();
    _subjectSearch.dispose();
    super.dispose();
  }

  // ---------- helpers ----------

  bool get _shs => _isShs(_program);

  _M? get _curriculum {
    for (final c in _curricula) {
      if (_idOf(c) == _curriculumId) return c;
    }
    return null;
  }

  bool get _isDraft => _curriculum?['status'] == 'draft';

  String _label(_M c) => '${_program?['code']} ${c['code']}';

  Future<String> _token() async {
    final token = await AuthStorage.getToken();
    if (token == null || token.isEmpty) {
      throw Exception('Authentication token not found.');
    }
    return token;
  }

  void _toast(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: error ? _dangerRed : null,
        ),
      );
  }

  /// Runs an action that changes data: guards double taps, shows errors.
  Future<bool> _run(
    Future<void> Function(String token) action, {
    String? success,
  }) async {
    if (_busy) return false;
    setState(() => _busy = true);
    try {
      final token = await _token();
      await action(token);
      if (success != null) _toast(success);
      return true;
    } catch (e) {
      if (e is AcademicApiException && e.issues.isNotEmpty) {
        await _showIssues(e.message, e.issues);
      } else {
        _toast(_cleanError(e), error: true);
      }
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool?> _confirm({
    required String title,
    required String message,
    required String confirmLabel,
    bool destructive = false,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Text(
          title,
          style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Text(message, style: const TextStyle(color: CmColors.slate)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            style: TextButton.styleFrom(foregroundColor: CmColors.navy),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: destructive ? _dangerRed : CmColors.navy,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
  }

  Future<void> _showIssues(String message, List<String> issues) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Text(
          message,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Fix these first:',
                  style: TextStyle(color: CmColors.slate),
                ),
                const SizedBox(height: 8),
                for (final i in issues)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Padding(
                          padding: EdgeInsets.only(top: 2, right: 8),
                          child: Icon(
                            Icons.error_outline,
                            size: 16,
                            color: _dangerRed,
                          ),
                        ),
                        Expanded(child: Text(i)),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            style: FilledButton.styleFrom(backgroundColor: CmColors.navy),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  // ---------- loading ----------

  Future<void> _loadPrograms({int? select}) async {
    setState(() {
      _loadingPrograms = true;
      _programsError = null;
    });
    try {
      final token = await _token();
      final programs = await AcademicApi.programs(token);
      if (!mounted) return;

      final wanted = select ?? _idOf(_program ?? {});
      _M? chosen;
      for (final p in programs) {
        if (_idOf(p) == wanted) chosen = p;
      }
      chosen ??= programs.isEmpty ? null : programs.first;

      setState(() {
        _programs = programs;
        _program = chosen;
        _loadingPrograms = false;
      });
      await _loadCurricula();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _programsError = _cleanError(e);
        _loadingPrograms = false;
      });
    }
  }

  Future<void> _selectProgram(_M program) async {
    if (_idOf(program) == _idOf(_program ?? {})) return;
    setState(() {
      _program = program;
      _curricula = [];
      _curriculumId = null;
      _subjects = [];
      _electives = [];
      _year = 1;
      _term = 1;
      _statusFilter = 'All';
      _subjectQuery = '';
      _subjectSearch.clear();
      _tab = 0;
    });
    await _loadCurricula();
  }

  Future<void> _loadCurricula({int? prefer}) async {
    final program = _program;
    if (program == null) return;

    setState(() {
      _loadingCurricula = true;
      _curriculaError = null;
    });
    try {
      final token = await _token();
      final list = await AcademicApi.curricula(token, _idOf(program)!);
      if (!mounted) return;

      int? chosen;
      final wanted = prefer ?? _curriculumId;
      for (final c in list) {
        if (_idOf(c) == wanted) chosen = _idOf(c);
      }
      if (chosen == null) {
        for (final c in list) {
          if (c['status'] == 'published') {
            chosen = _idOf(c);
            break;
          }
        }
      }
      chosen ??= list.isEmpty ? null : _idOf(list.first);

      setState(() {
        _curricula = list;
        _curriculumId = chosen;
        _loadingCurricula = false;
      });
      await _loadContext();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _curriculaError = _cleanError(e);
        _loadingCurricula = false;
      });
    }
  }

  /// Subjects + electives for the selected curriculum, year level, semester.
  Future<void> _loadContext() async {
    final id = _curriculumId;
    if (_toolsFor != id) {
      _toolsFor = id;
      _showElectiveTools = false;
    }
    if (id == null) {
      setState(() {
        _subjects = [];
        _electives = [];
        _loadingSubjects = false;
        _subjectsError = null;
      });
      return;
    }

    setState(() {
      _loadingSubjects = true;
      _subjectsError = null;
    });
    try {
      final token = await _token();
      final results = await Future.wait([
        AcademicApi.subjects(
          token,
          id,
          yearLevel: _year,
          term: _term,
          schoolYear: _schoolYear,
        ),
        AcademicApi.electives(token, id),
      ]);
      if (!mounted || id != _curriculumId) return;
      setState(() {
        _subjects = results[0];
        _electives = results[1];
        _loadingSubjects = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _subjectsError = _cleanError(e);
        _loadingSubjects = false;
      });
    }
  }

  Future<void> _reloadAll() async {
    await _loadCurricula();
    final id = _idOf(_program ?? {});
    // keep the program list counts fresh
    try {
      final token = await _token();
      final programs = await AcademicApi.programs(token);
      if (!mounted) return;
      setState(() {
        _programs = programs;
        for (final p in programs) {
          if (_idOf(p) == id) _program = p;
        }
      });
    } catch (_) {}
  }

  // ---------- programs ----------

  List<String> get _departments {
    const defaults = [
      'Information Technology Department',
      'Engineering Department',
      'Business & Management Department',
      'Hospitality Management Department',
      'Arts & Sciences Department',
      'Tourism Management Department',
      'Maritime Department',
      'Criminal Justice Education Department',
    ];

    final departments = <String>{...defaults};

    for (final program in _programs) {
      if (program['level'] != 'college') continue;

      final department = _s(program['department']);
      if (department.isNotEmpty) {
        departments.add(department);
      }
    }

    return departments.toList();
  }

  Future<void> _addProgram() async {
    final input = await showDialog<_M>(
      context: context,
      builder: (_) => _ProgramDialog(departments: _departments),
    );
    if (input == null) return;

    int? createdId;
    final ok = await _run((token) async {
      final created = await AcademicApi.createProgram(
        token,
        code: input['code'] as String,
        name: input['name'] as String,
        level: input['level'] as String,
        department: input['department'] as String?,
      );
      createdId = _idOf(created);
    }, success: 'Program added.');
    if (ok) {
      _program = null;
      await _loadPrograms(select: createdId);
    }
  }

  Future<void> _editProgram() async {
    final program = _program;
    if (program == null) return;
    final input = await showDialog<_M>(
      context: context,
      builder: (_) =>
          _ProgramDialog(initial: program, departments: _departments),
    );
    if (input == null) return;

    final ok = await _run((token) async {
      await AcademicApi.updateProgram(
        token,
        _idOf(program)!,
        code: input['code'] as String,
        name: input['name'] as String,
        level: input['level'] as String,
        department: input['department'] as String?,
      );
    }, success: 'Program updated.');
    if (ok) await _loadPrograms(select: _idOf(program));
  }

  Future<void> _deleteProgram() async {
    final program = _program;
    if (program == null) return;
    final confirmed = await _confirm(
      title: 'Delete ${program['code']}?',
      message:
          'This removes the program from Academic Management. '
          'A program that still has curricula cannot be deleted.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (confirmed != true) return;

    final ok = await _run((token) async {
      await AcademicApi.deleteProgram(token, _idOf(program)!);
    }, success: 'Program deleted.');
    if (ok) {
      setState(() {
        _program = null;
        _curricula = [];
        _curriculumId = null;
        _subjects = [];
        _electives = [];
      });
      await _loadPrograms();
    }
  }

  // ---------- curricula ----------

  Future<void> _newCurriculum({int? copyId}) async {
    final program = _program;
    if (program == null) return;
    final input = await showDialog<_M>(
      context: context,
      builder: (_) => _CurriculumDialog(
        program: program,
        curricula: _curricula,
        initialCopyId: copyId,
      ),
    );
    if (input == null) return;

    int? createdId;
    final ok = await _run((token) async {
      final created = await AcademicApi.createCurriculum(
        token,
        programId: _idOf(program)!,
        code: input['code'] as String,
        copyFromId: input['copy_from_id'] as int?,
        rows: (input['rows'] as List?)?.cast<Map<String, dynamic>>(),
        electives: (input['electives'] as List?)?.cast<Map<String, dynamic>>(),
      );
      createdId = _idOf(created);
    }, success: 'Draft curriculum created.');
    if (ok) {
      _year = 1;
      _term = 1;
      await _loadCurricula(prefer: createdId);
      await _refreshProgramCounts();
    }
  }

  Future<void> _refreshProgramCounts() async {
    try {
      final token = await _token();
      final programs = await AcademicApi.programs(token);
      if (!mounted) return;
      final id = _idOf(_program ?? {});
      setState(() {
        _programs = programs;
        for (final p in programs) {
          if (_idOf(p) == id) _program = p;
        }
      });
    } catch (_) {}
  }

  Future<void> _editCurriculum(_M c) async {
    final code = await showDialog<String>(
      context: context,
      builder: (_) =>
          _CodeDialog(title: 'Edit Draft Curriculum', initial: _s(c['code'])),
    );
    if (code == null) return;

    final ok = await _run((token) async {
      await AcademicApi.updateCurriculum(token, _idOf(c)!, code: code);
    }, success: 'Curriculum updated.');
    if (ok) await _loadCurricula(prefer: _idOf(c));
  }

  Future<void> _publish(_M c) async {
    final confirmed = await _confirm(
      title: 'Publish ${_label(c)}?',
      message:
          'The curriculum is checked first. Once published it becomes '
          'read-only. To change it later, copy it to a new draft.',
      confirmLabel: 'Publish',
    );
    if (confirmed != true) return;

    final ok = await _run((token) async {
      await AcademicApi.publishCurriculum(token, _idOf(c)!);
    }, success: '${_label(c)} published.');
    if (ok) {
      await _loadCurricula(prefer: _idOf(c));
      await _refreshProgramCounts();
    }
  }

  Future<void> _deleteCurriculum(_M c) async {
    final confirmed = await _confirm(
      title: 'Delete ${_label(c)}?',
      message:
          'This draft and its ${c['subject_count']} subjects will be '
          'removed from Academic Management. Subjects shared with other '
          'curricula are not affected.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (confirmed != true) return;

    final ok = await _run((token) async {
      await AcademicApi.deleteCurriculum(token, _idOf(c)!);
    }, success: 'Curriculum deleted.');
    if (ok) {
      await _loadCurricula();
      await _refreshProgramCounts();
    }
  }

  /// [view] jumps to the read-only Subjects tab (used for published
  /// curricula). [stay] keeps the current tab (used by the dropdowns).
  void _openCurriculum(_M c, {bool view = false, bool stay = false}) {
    setState(() {
      _curriculumId = _idOf(c);
      _year = 1;
      _term = 1;
      if (view) _tab = 1;
      if (!view && !stay) _tab = 0;
    });
    _loadContext();
  }

  // ---------- subjects ----------

  Future<List<_M>> _searchCatalog(String q) async {
    final token = await _token();
    return AcademicApi.searchCatalog(token, q);
  }

  Future<void> _addSubject() async {
    final id = _curriculumId;
    if (id == null) return;
    final body = await showDialog<_M>(
      context: context,
      builder: (_) => _SubjectDialog(
        title: 'Add Subject',
        shs: _shs,
        search: _searchCatalog,
        year: _year,
        term: _term,
      ),
    );
    if (body == null) return;

    final ok = await _run((token) async {
      await AcademicApi.addSubject(token, id, body);
    }, success: 'Subject added.');
    if (ok) {
      // follow the subject if it was placed in another term
      setState(() {
        _year = body['year_level'] as int;
        _term = body['term'] as int;
      });
      await _loadContext();
      await _refreshProgramCounts();
      await _refreshCurriculumRow();
    }
  }

  Future<void> _refreshCurriculumRow() async {
    final program = _program;
    if (program == null) return;
    try {
      final token = await _token();
      final list = await AcademicApi.curricula(token, _idOf(program)!);
      if (mounted) setState(() => _curricula = list);
    } catch (_) {}
  }

  Future<void> _editSubject(_M subject) async {
    final id = _curriculumId;
    if (id == null) return;
    final body = await showDialog<_M>(
      context: context,
      builder: (_) => _SubjectDialog(
        title: 'Edit Subject',
        shs: _shs,
        search: _searchCatalog,
        initial: subject,
        year: _year,
        term: _term,
      ),
    );
    if (body == null) return;

    final ok = await _run((token) async {
      await AcademicApi.updateSubject(token, id, _idOf(subject)!, body);
    }, success: 'Subject updated.');
    if (ok) {
      setState(() {
        _year = body['year_level'] as int;
        _term = body['term'] as int;
      });
      await _loadContext();
    }
  }

  Future<void> _deleteSubject(_M subject) async {
    final id = _curriculumId;
    if (id == null) return;
    final confirmed = await _confirm(
      title: 'Delete subject?',
      message:
          '${_s(subject['code']).isEmpty ? '' : '${subject['code']}  '}'
          '${subject['name']} will be removed from '
          '${_yearLabel(_shs, _year)}, ${_termLabel(_shs, _term)} of this '
          'curriculum. It stays available in other curricula.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (confirmed != true) return;

    final ok = await _run((token) async {
      await AcademicApi.deleteSubject(token, id, _idOf(subject)!);
    }, success: 'Subject deleted.');
    if (ok) {
      await _loadContext();
      await _refreshCurriculumRow();
    }
  }

  Future<void> _deleteTerm() async {
    final id = _curriculumId;
    if (id == null || _subjects.isEmpty) return;
    final confirmed = await _confirm(
      title: 'Delete term subjects?',
      message:
          'All ${_subjects.length} subjects of '
          '${_yearLabel(_shs, _year)}, ${_termLabel(_shs, _term)} will be '
          'removed from this curriculum. Other terms and other curricula are '
          'not affected.',
      confirmLabel: 'Delete All',
      destructive: true,
    );
    if (confirmed != true) return;

    final ok = await _run((token) async {
      final n = await AcademicApi.deleteTermSubjects(
        token,
        id,
        yearLevel: _year,
        term: _term,
      );
      _toast('$n subjects deleted.');
    });
    if (ok) {
      await _loadContext();
      await _refreshCurriculumRow();
    }
  }

  Future<void> _chooseElective(_M slot) async {
    final id = _curriculumId;
    if (id == null || _electives.isEmpty) return;
    final choice = await showDialog<_M>(
      context: context,
      builder: (_) => _ElectiveChoiceDialog(
        slot: slot,
        electives: _electives,
        schoolYear: _schoolYear,
      ),
    );
    if (choice == null) return;

    final ok = await _run(
      (token) async {
        if (choice['action'] == 'clear') {
          await AcademicApi.clearSelection(
            token,
            id,
            curriculumSubjectId: _idOf(slot)!,
            schoolYear: _schoolYear,
          );
        } else {
          await AcademicApi.setSelection(
            token,
            id,
            curriculumSubjectId: _idOf(slot)!,
            electiveId: choice['elective_id'] as int,
            schoolYear: _schoolYear,
          );
        }
      },
      success: choice['action'] == 'clear'
          ? 'Elective choice cleared.'
          : 'Elective finalized.',
    );
    if (ok) await _loadContext();
  }

  // ---------- list of electives ----------

  Future<void> _addElective() async {
    final id = _curriculumId;
    if (id == null) return;
    final groups = <String>{
      for (final e in _electives)
        if (_s(e['group_name']).isNotEmpty) _s(e['group_name']),
    }.toList();
    final body = await showDialog<_M>(
      context: context,
      builder: (_) => _SubjectDialog(
        title: 'Add Elective',
        shs: _shs,
        search: _searchCatalog,
        electiveMode: true,
        groups: groups,
      ),
    );
    if (body == null) return;

    final ok = await _run((token) async {
      await AcademicApi.addElective(token, id, body);
    }, success: 'Elective added.');
    if (ok) {
      await _loadContext();
      await _refreshCurriculumRow();
    }
  }

  Future<void> _editElective(_M elective) async {
    final id = _curriculumId;
    if (id == null) return;
    final groups = <String>{
      for (final e in _electives)
        if (_s(e['group_name']).isNotEmpty) _s(e['group_name']),
    }.toList();
    final body = await showDialog<_M>(
      context: context,
      builder: (_) => _SubjectDialog(
        title: 'Edit Elective',
        shs: _shs,
        search: _searchCatalog,
        initial: elective,
        electiveMode: true,
        groups: groups,
      ),
    );
    if (body == null) return;

    final ok = await _run((token) async {
      await AcademicApi.updateElective(token, id, _idOf(elective)!, body);
    }, success: 'Elective updated.');
    if (ok) await _loadContext();
  }

  Future<void> _deleteElective(_M elective) async {
    final id = _curriculumId;
    if (id == null) return;
    final confirmed = await _confirm(
      title: 'Delete elective?',
      message:
          '${elective['code']}  ${elective['name']} will be removed from '
          'the list of electives. An elective that is finalized for a school '
          'year must be cleared first.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (confirmed != true) return;

    final ok = await _run((token) async {
      await AcademicApi.deleteElective(token, id, _idOf(elective)!);
    }, success: 'Elective deleted.');
    if (ok) {
      await _loadContext();
      await _refreshCurriculumRow();
    }
  }

  // =========================
  // BUILD
  // =========================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Academic Management')),
      body: LayoutBuilder(
        builder: (context, constraints) {
          if (_loadingPrograms) {
            return const Center(child: CircularProgressIndicator());
          }
          if (_programsError != null) {
            return _errorBox(_programsError!, () => _loadPrograms());
          }
          if (constraints.maxWidth >= 900) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 300,
                  margin: const EdgeInsets.fromLTRB(16, 16, 8, 16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: CmColors.line),
                    boxShadow: [
                      BoxShadow(
                        color: CmColors.navy.withValues(alpha: 0.05),
                        blurRadius: 14,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: _programPanel(),
                ),
                Expanded(child: _detail()),
              ],
            );
          }
          return Column(
            children: [
              _programPicker(),
              Expanded(child: _detail()),
            ],
          );
        },
      ),
    );
  }

  // ---------- program list (wide) / picker (narrow) ----------

  /// Department order shown in the program list.
  static const List<String> _deptOrder = [
    'Information Technology Department',
    'Engineering Department',
    'Business & Management Department',
    'Hospitality Management Department',
    'Arts & Sciences Department',
    'Tourism Management Department',
  ];

  /// Program order inside a department (anything else follows alphabetically).
  static const List<String> _programOrder = [
    'BSIT',
    'BSCpE',
    'BSBA',
    'BSAIS',
    'BSA',
    'BSHM',
    'BMMA',
    'BACOMM',
    'BSTM',
    'STEM',
    'ABM',
  ];

  static int _rank(List<String> order, String value) {
    final i = order.indexWhere((e) => e.toLowerCase() == value.toLowerCase());
    return i < 0 ? 999 : i;
  }

  static int _byProgramOrder(_M a, _M b) {
    final c = _rank(
      _programOrder,
      _s(a['code']),
    ).compareTo(_rank(_programOrder, _s(b['code'])));
    return c != 0 ? c : _s(a['code']).compareTo(_s(b['code']));
  }

  Widget _programPanel() {
    final q = _programQuery;

    bool matches(_M p) =>
        q.isEmpty ||
        _s(p['code']).toLowerCase().contains(q) ||
        _s(p['name']).toLowerCase().contains(q) ||
        _s(p['department']).toLowerCase().contains(q);

    final visible = _programs.where(matches).toList();

    final shs = visible.where((p) => p['level'] == 'shs').toList()
      ..sort(_byProgramOrder);

    final byDept = <String, List<_M>>{};

    for (final p in visible.where((p) => p['level'] != 'shs')) {
      final department = _s(p['department']);
      final name = department.isEmpty ? 'College' : department;
      byDept.putIfAbsent(name, () => []).add(p);
    }

    final deptNames = byDept.keys.toList()
      ..sort((a, b) {
        final comparison = _rank(_deptOrder, a).compareTo(_rank(_deptOrder, b));
        return comparison != 0 ? comparison : a.compareTo(b);
      });

    return Container(
      color: Colors.white,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
            child: TextField(
              controller: _programSearch,
              onChanged: (value) =>
                  setState(() => _programQuery = value.trim().toLowerCase()),
              decoration: _fieldDecoration(hint: 'Search programs...').copyWith(
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: q.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear',
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () {
                          _programSearch.clear();
                          setState(() => _programQuery = '');
                        },
                      ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                style: _primaryButtonStyle,
                onPressed: _busy ? null : _addProgram,
                icon: const Icon(Icons.add, size: 20),
                label: const Text('Add Program'),
              ),
            ),
          ),
          Expanded(
            child: visible.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      _programs.isEmpty
                          ? 'No programs yet.'
                          : 'No programs match your search.',
                      style: const TextStyle(color: CmColors.slate),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.only(bottom: 16),
                    children: [
                      if (shs.isNotEmpty)
                        _navigationGroup(
                          label: 'Senior High School',
                          icon: _shsIcon,
                          expanded: true,
                          children: [
                            for (final p in shs) _programTile(p, indent: 34),
                          ],
                        ),
                      if (byDept.isNotEmpty)
                        _navigationGroup(
                          label: 'College',
                          icon: _collegeIcon,
                          expanded: true,
                          children: [
                            for (final d in deptNames)
                              _navigationGroup(
                                label: d,
                                icon: Icons.account_balance_outlined,
                                indent: 16,
                                expanded:
                                    q.isNotEmpty ||
                                    byDept[d]!.any(
                                      (p) => _idOf(p) == _idOf(_program ?? {}),
                                    ),
                                children: [
                                  for (final p
                                      in (byDept[d]!..sort(_byProgramOrder)))
                                    _programTile(p, indent: 52),
                                ],
                              ),
                          ],
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _navigationGroup({
    required String label,
    required IconData icon,
    required List<Widget> children,
    bool expanded = false,
    double indent = 0,
  }) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        key: PageStorageKey('academic-nav:$label:$_programQuery'),
        initiallyExpanded: expanded,
        controlAffinity: ListTileControlAffinity.leading,
        tilePadding: EdgeInsets.only(left: indent + 8, right: 12),
        childrenPadding: EdgeInsets.zero,
        iconColor: CmColors.navy,
        collapsedIconColor: CmColors.slate,
        title: Row(
          children: [
            Icon(icon, size: 18, color: CmColors.navy),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: CmColors.navy,
                ),
              ),
            ),
          ],
        ),
        children: children,
      ),
    );
  }

  Widget _programTile(_M p, {required double indent}) {
    final selected = _idOf(p) == _idOf(_program ?? {});
    final published = _s(p['published_curriculum']);
    return Padding(
      padding: EdgeInsets.fromLTRB(indent - 8, 1, 10, 1),
      child: Material(
        color: selected
            ? CmColors.navy.withValues(alpha: 0.08)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => _selectProgram(p),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(
                    _programIcon,
                    size: 18,
                    color: selected ? CmColors.navy : CmColors.slate,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _s(p['code']),
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.25,
                          fontWeight: selected
                              ? FontWeight.w700
                              : FontWeight.w500,
                          color: CmColors.navy,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        published.isEmpty
                            ? 'No published curriculum'
                            : 'Curriculum $published',
                        style: const TextStyle(
                          fontSize: 11,
                          color: CmColors.slate,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _programPicker() {
    final id = _idOf(_program ?? {});
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Row(
        children: [
          Expanded(
            child: _programs.isEmpty
                ? const Text(
                    'No programs yet.',
                    style: TextStyle(color: CmColors.slate),
                  )
                : DropdownButtonFormField<int>(
                    key: ValueKey('program-$id'),
                    initialValue: id,
                    isExpanded: true,
                    decoration: _fieldDecoration(),
                    items: [
                      for (final p in _programs)
                        DropdownMenuItem(
                          value: _idOf(p),
                          child: Text(
                            '${p['code']}  ·  ${p['level'] == 'shs' ? 'Senior High' : _s(p['department'])}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (v) {
                      for (final p in _programs) {
                        if (_idOf(p) == v) _selectProgram(p);
                      }
                    },
                  ),
          ),
          const SizedBox(width: 10),
          FilledButton.icon(
            style: _primaryButtonStyle,
            onPressed: _busy ? null : _addProgram,
            icon: const Icon(Icons.add, size: 20),
            label: const Text('Add'),
          ),
        ],
      ),
    );
  }

  // ---------- detail ----------

  Widget _detail() {
    final program = _program;
    if (program == null) {
      return _emptyCard(
        icon: Icons.school_outlined,
        title: 'No programs yet',
        message: 'Add a college program or a Senior High School strand to get started.',
        action: FilledButton.icon(
          style: _primaryButtonStyle,
          onPressed: _busy ? null : _addProgram,
          icon: const Icon(Icons.add),
          label: const Text('Add Program'),
        ),
      );
    }

    final crumb = _shs
        ? 'Senior High School  ›  ${program['code']}'
        : 'College  ›  ${_s(program['department'])}  ›  ${program['code']}';

    return RefreshIndicator(
      onRefresh: _reloadAll,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      crumb,
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: CmColors.slate,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${program['name']} (${program['code']})',
                      style: const TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w700,
                        color: CmColors.navy,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _shs
                          ? 'Senior High School strand · Grade 11 and Grade 12'
                          : 'Curriculum versions are managed separately for each program.',
                      style: const TextStyle(
                        fontSize: 13,
                        color: CmColors.slate,
                      ),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'Program actions',
                enabled: !_busy,
                onSelected: (v) {
                  if (v == 'edit') _editProgram();
                  if (v == 'delete') _deleteProgram();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'edit',
                    child: ListTile(
                      dense: true,
                      leading: Icon(Icons.edit_outlined),
                      title: Text('Edit'),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: ListTile(
                      dense: true,
                      leading: Icon(Icons.delete_outline, color: _dangerRed),
                      title: Text(
                        'Delete',
                        style: TextStyle(color: _dangerRed),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: CmColors.line)),
            ),
            child: Row(
              children: [_tabButton('Curricula', 0), _tabButton('Subjects', 1)],
            ),
          ),
          const SizedBox(height: 18),
          if (_loadingCurricula)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 48),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_curriculaError != null)
            _errorBox(_curriculaError!, () => _loadCurricula())
          else if (_tab == 0)
            _curriculaTab()
          else
            _subjectsTab(),
        ],
      ),
    );
  }

  Widget _tabButton(String label, int index) {
    final active = _tab == index;

    return InkWell(
      onTap: () => setState(() => _tab = index),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: active ? _activeGreen : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 16,
            fontWeight: active ? FontWeight.w600 : FontWeight.w400,
            color: active ? _activeGreen : CmColors.slate,
          ),
        ),
      ),
    );
  }

  // =========================
  // CURRICULA TAB
  // =========================

  Widget _curriculaTab() {
    final filtered = _curricula.where((c) {
      if (_statusFilter == 'All') return true;
      return (c['status'] == 'draft') == (_statusFilter == 'Draft');
    }).toList();
    final selected = _curriculum;
    final editing = selected != null && selected['status'] == 'draft';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const Text(
              'Curriculum Versions',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: CmColors.navy,
              ),
            ),
            DropdownButton<String>(
              value: _statusFilter,
              underline: const SizedBox.shrink(),
              items: const [
                DropdownMenuItem(value: 'All', child: Text('All statuses')),
                DropdownMenuItem(value: 'Draft', child: Text('Draft')),
                DropdownMenuItem(value: 'Published', child: Text('Published')),
              ],
              onChanged: (v) => setState(() => _statusFilter = v ?? 'All'),
            ),
            if (!_shs)
              FilledButton.icon(
                style: _primaryButtonStyle,
                onPressed: _busy ? null : () => _newCurriculum(),
                icon: const Icon(Icons.add, size: 20),
                label: const Text('New Curriculum'),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          _shs
              ? 'A strand has one fixed curriculum. View its subjects in the Subjects tab.'
              : 'Published curricula are read-only: view them in the Subjects tab. '
                    'To change one, copy it to a new draft.',
          style: const TextStyle(fontSize: 12.5, color: CmColors.slate),
        ),
        const SizedBox(height: 12),
        if (_curricula.isEmpty)
          _emptyCard(
            icon: Icons.library_books_outlined,
            title: 'No curriculum yet',
            message: _shs
                ? 'This strand has no curriculum.'
                : 'Create a curriculum version for ${_program?['code']} by '
                      'copying an older one or uploading a file.',
          )
        else if (filtered.isEmpty)
          _emptyCard(
            icon: Icons.search_off,
            title: 'No curricula match this filter',
          )
        else
          _table(
            headers: const [
              'Curriculum',
              'Status',
              'Subjects',
              'Electives',
              'Actions',
            ],
            rows: [
              for (final c in filtered)
                DataRow(
                  selected: _idOf(c) == _curriculumId,
                  cells: [
                    DataCell(
                      Text(
                        _label(c),
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    DataCell(
                      c['status'] == 'published'
                          ? _badge('Published', _activeGreen)
                          : _badge('Draft', _draftBlue),
                    ),
                    DataCell(Text('${c['subject_count']}')),
                    DataCell(Text('${c['elective_count']}')),
                    DataCell(
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (c['status'] == 'published')
                            _rowAction(
                              'View',
                              Icons.visibility_outlined,
                              () => _openCurriculum(c, view: true),
                            )
                          else
                            _rowAction(
                              'Edit Subjects',
                              Icons.edit_note,
                              () => _openCurriculum(c),
                            ),
                          if (!_shs)
                            _rowAction(
                              'Copy',
                              Icons.copy_outlined,
                              () => _newCurriculum(copyId: _idOf(c)),
                            ),
                          if (c['status'] == 'draft') ...[
                            _rowAction(
                              'Rename',
                              Icons.edit_outlined,
                              () => _editCurriculum(c),
                            ),
                            _rowAction(
                              'Publish',
                              Icons.check_circle_outline,
                              () => _publish(c),
                            ),
                            _rowAction(
                              'Delete',
                              Icons.delete_outline,
                              () => _deleteCurriculum(c),
                              danger: true,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
            ],
          ),
        if (editing) ..._draftEditor(selected),
      ],
    );
  }

  /// The editor of a draft curriculum: per year level, per semester, per
  /// subject, plus the list of electives when the curriculum has one.
  List<Widget> _draftEditor(_M selected) {
    return [
      const SizedBox(height: 26),
      const Divider(height: 1, color: CmColors.line),
      const SizedBox(height: 18),
      Wrap(
        spacing: 10,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            '${_label(selected)} Draft',
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: CmColors.navy,
            ),
          ),
          _badge('Draft', _draftBlue),
        ],
      ),
      const SizedBox(height: 4),
      const Text(
        'Pick a year level and semester, then add, edit or delete subjects one by one. '
        'Subjects kept from the old curriculum stay as they are. Replace only the '
        'ones that changed, such as a core subject with a new course code and name.',
        style: TextStyle(fontSize: 12.5, color: CmColors.slate, height: 1.4),
      ),
      const SizedBox(height: 14),
      _contextBar(schoolYear: false, draftsOnly: true),
      const SizedBox(height: 16),
      _subjectsBlock(editor: true),

      if (!_shs) ...[
        const SizedBox(height: 24),
        if (_electives.isNotEmpty || _showElectiveTools)
          _electivesPanel()
        else
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              style: _secondaryButtonStyle,
              onPressed: () => setState(() => _showElectiveTools = true),
              icon: const Icon(Icons.playlist_add, size: 20),
              label: const Text('This curriculum has a list of electives'),
            ),
          ),
      ],
    ];
  }

  // =========================
  // SUBJECTS TAB (read-only)
  // =========================

  Widget _subjectsTab() {
    if (_curriculum == null) {
      return _emptyCard(
        icon: Icons.library_books_outlined,
        title: 'No curriculum selected',
        message: 'Create a curriculum in the Curricula tab to see its subjects here.',
        action: OutlinedButton(
          style: _secondaryButtonStyle,
          onPressed: () => setState(() => _tab = 0),
          child: const Text('Go to Curricula'),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _contextBar(schoolYear: _electives.isNotEmpty),
        const SizedBox(height: 16),
        _subjectsBlock(editor: false),
      ],
    );
  }

  /// Curriculum version + year level + semester (+ school year when the
  /// curriculum has electives to finalize).
  Widget _contextBar({required bool schoolYear, bool draftsOnly = false}) {
    final yearCount = _shs ? 2 : 4;
    final choices = draftsOnly
        ? _curricula.where((c) => c['status'] == 'draft').toList()
        : _curricula;

    Widget chips(
      int count,
      int current,
      String Function(int) label,
      void Function(int) onPick,
    ) {
      return Wrap(
        spacing: 8,
        runSpacing: 6,
        children: [
          for (var i = 1; i <= count; i++)
            ChoiceChip(
              label: Text(label(i)),
              selected: current == i,
              showCheckmark: false,
              selectedColor: CmColors.navy,
              backgroundColor: CmColors.bg,
              side: const BorderSide(color: CmColors.line),
              labelStyle: TextStyle(
                color: current == i ? Colors.white : CmColors.navy,
                fontWeight: FontWeight.w600,
              ),
              onSelected: (_) => onPick(i),
            ),
        ],
      );
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: CmColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 14,
            runSpacing: 12,
            children: [
              SizedBox(
                width: 260,
                child: _labeled(
                  'Curriculum',
                  DropdownButtonFormField<int>(
                    key: ValueKey(
                      'cur-$_curriculumId-${choices.length}-$draftsOnly',
                    ),
                    initialValue: choices.any((c) => _idOf(c) == _curriculumId)
                        ? _curriculumId
                        : null,
                    isExpanded: true,
                    decoration: _fieldDecoration(),
                    items: [
                      for (final c in choices)
                        DropdownMenuItem(
                          value: _idOf(c),
                          child: Text(
                            '${_label(c)}  ·  ${c['status'] == 'published' ? 'Published' : 'Draft'}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (v) {
                      for (final c in _curricula) {
                        if (_idOf(c) == v) _openCurriculum(c, stay: true);
                      }
                    },
                  ),
                ),
              ),
              if (schoolYear)
                SizedBox(
                  width: 180,
                  child: _labeled(
                    'School year',
                    DropdownButtonFormField<String>(
                      key: ValueKey('sy-$_schoolYear'),
                      initialValue: _schoolYear,
                      isExpanded: true,
                      decoration: _fieldDecoration(),
                      items: [
                        for (final y in _schoolYearOptions())
                          DropdownMenuItem(value: y, child: Text(y)),
                      ],
                      onChanged: (v) {
                        if (v == null) return;
                        setState(() => _schoolYear = v);
                        _loadContext();
                      },
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          _labeled(
            _shs ? 'Grade' : 'Year level',
            chips(yearCount, _year, (i) => _yearLabel(_shs, i), (i) {
              setState(() => _year = i);
              _loadContext();
            }),
          ),
          const SizedBox(height: 12),
          _labeled(
            _shs ? 'Term' : 'Semester',
            chips(2, _term, (i) => _termLabel(_shs, i), (i) {
              setState(() => _term = i);
              _loadContext();
            }),
          ),
        ],
      ),
    );
  }

  /// The subjects of the exact selected curriculum + year level + semester.
  /// [editor] = the draft editor in the Curricula tab; otherwise read-only.
  Widget _subjectsBlock({required bool editor}) {
    final editable = editor && _isDraft;
    final q = _subjectQuery;
    final visible = _subjects.where((s) {
      if (q.isEmpty) return true;
      return _s(s['code']).toLowerCase().contains(q) ||
          _s(s['name']).toLowerCase().contains(q);
    }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              '${_yearLabel(_shs, _year)} Subjects  ·  ${_termLabel(_shs, _term)}',
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: CmColors.navy,
              ),
            ),
            if (editable) ...[
              FilledButton.icon(
                style: _primaryButtonStyle,
                onPressed: _busy ? null : _addSubject,
                icon: const Icon(Icons.add, size: 20),
                label: const Text('Add Subject'),
              ),
              OutlinedButton.icon(
                style: _dangerOutlineStyle,
                onPressed: _busy || _subjects.isEmpty ? null : _deleteTerm,
                icon: const Icon(Icons.delete_sweep_outlined, size: 20),
                label: const Text('Delete Term Subjects'),
              ),
            ],
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '${_program?['code']} · '
          '${_curriculum == null ? '' : 'Curriculum ${_curriculum!['code']} · '}'
          '${_yearLabel(_shs, _year)} · ${_termLabel(_shs, _term)}',
          style: const TextStyle(fontSize: 12.5, color: CmColors.slate),
        ),
        if (!editor && _electives.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Tap an elective subject to finalize which elective is taken for $_schoolYear.',
              style: const TextStyle(fontSize: 12.5, color: CmColors.slate),
            ),
          ),
        const SizedBox(height: 12),
        SizedBox(
          width: 360,
          child: TextField(
            controller: _subjectSearch,
            onChanged: (v) =>
                setState(() => _subjectQuery = v.trim().toLowerCase()),
            decoration:
                _fieldDecoration(
                  hint: _shs
                      ? 'Search course name'
                      : 'Search course code or name',
                ).copyWith(
                  prefixIcon: const Icon(Icons.search, size: 20),
                  suffixIcon: _subjectQuery.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear',
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () {
                            _subjectSearch.clear();
                            setState(() => _subjectQuery = '');
                          },
                        ),
                ),
          ),
        ),
        const SizedBox(height: 12),
        if (_loadingSubjects)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 32),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_subjectsError != null)
          _errorBox(_subjectsError!, _loadContext)
        else if (_curriculum == null)
          _emptyCard(
            icon: Icons.library_books_outlined,
            title: 'No curriculum selected',
          )
        else if (_subjects.isEmpty)
          _emptyCard(
            icon: Icons.inbox_outlined,
            title: 'No subjects in this term',
            message: editable
                ? 'Use Add Subject to place a subject here.'
                : 'This term has no subjects.',
          )
        else if (visible.isEmpty)
          _emptyCard(
            icon: Icons.search_off,
            title: 'No subjects match your search',
          )
        else
          _table(
            headers: [
              if (!_shs) 'Course Code',
              'Course Name',
              if (editable) 'Actions',
            ],
            rows: [for (final s in visible) _subjectRow(s, editor, editable)],
          ),
      ],
    );
  }

  DataRow _subjectRow(_M s, bool editor, bool editable) {
    final slot = s['is_elective_slot'] == true;
    final selection = s['selection'] is Map ? s['selection'] as Map : null;
    final canChoose = !editor && slot && _electives.isNotEmpty;
    final code = _s(s['code']);
    final tap = canChoose ? () => _chooseElective(s) : null;

    final detail = <String>[];
    if (_shs) {
      final cat = _s(s['category']);
      if (cat.isNotEmpty) {
        detail.add('${cat[0].toUpperCase()}${cat.substring(1)}');
      }
      if (s['hours'] != null) detail.add('${s['hours']} hrs');
    }

    return DataRow(
      cells: [
        if (!_shs)
          DataCell(
            Text(
              code.isEmpty ? '—' : code,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            onTap: tap,
          ),
        DataCell(
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 220, maxWidth: 520),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        _s(s['name']),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (slot) ...[
                      const SizedBox(width: 8),
                      _badge('Elective', _draftBlue),
                    ],
                    if (canChoose) ...[
                      const SizedBox(width: 4),
                      const Icon(
                        Icons.arrow_drop_down,
                        size: 20,
                        color: CmColors.slate,
                      ),
                    ],
                  ],
                ),
                if (selection != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      'Finalized for $_schoolYear: ${selection['code']}  ${selection['name']}',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: _activeGreen,
                      ),
                    ),
                  )
                else if (detail.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      detail.join(' · '),
                      style: const TextStyle(
                        fontSize: 12,
                        color: CmColors.slate,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          onTap: tap,
        ),
        if (editable)
          DataCell(
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _rowAction('Edit', Icons.edit_outlined, () => _editSubject(s)),
                _rowAction(
                  'Delete',
                  Icons.delete_outline,
                  () => _deleteSubject(s),
                  danger: true,
                ),
              ],
            ),
          ),
      ],
    );
  }

  // ---------- LIST OF ELECTIVES (draft editor only) ----------

  Widget _electivesPanel() {
    final groups = <String, List<_M>>{};
    for (final e in _electives) {
      final g = _s(e['group_name']).isEmpty
          ? 'Other electives'
          : _s(e['group_name']);
      groups.putIfAbsent(g, () => []).add(e);
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: CmColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Text(
                'LIST OF ELECTIVES',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.6,
                  color: CmColors.navy,
                ),
              ),
              FilledButton.icon(
                style: _primaryButtonStyle,
                onPressed: _busy ? null : _addElective,
                icon: const Icon(Icons.add, size: 20),
                label: const Text('Add Elective'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'These are the electives that can replace an elective subject in a term. '
            'An elective subject with no choice finalized stays as listed.',
            style: TextStyle(fontSize: 12.5, color: CmColors.slate),
          ),
          if (_electives.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text(
                'No electives yet. Use Add Elective.',
                style: TextStyle(color: CmColors.slate),
              ),
            )
          else ...[
            const SizedBox(height: 14),
            for (final g in groups.entries) ...[
              Padding(
                padding: const EdgeInsets.only(bottom: 6, top: 4),
                child: Text(
                  g.key,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    color: CmColors.slate,
                  ),
                ),
              ),
              _table(
                headers: const ['Course Code', 'Course Name', 'Actions'],
                rows: [
                  for (final e in g.value)
                    DataRow(
                      cells: [
                        DataCell(
                          Text(
                            _s(e['code']).isEmpty ? '—' : _s(e['code']),
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        DataCell(Text(_s(e['name']))),
                        DataCell(
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _rowAction(
                                'Edit',
                                Icons.edit_outlined,
                                () => _editElective(e),
                              ),
                              _rowAction(
                                'Delete',
                                Icons.delete_outline,
                                () => _deleteElective(e),
                                danger: true,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                ],
              ),
              const SizedBox(height: 12),
            ],
          ],
        ],
      ),
    );
  }

  // =========================
  // SHARED WIDGETS
  // =========================

  Widget _rowAction(
    String label,
    IconData icon,
    VoidCallback onTap, {
    bool danger = false,
  }) {
    return TextButton.icon(
      onPressed: _busy ? null : onTap,
      icon: Icon(icon, size: 16),
      label: Text(label),
      style: TextButton.styleFrom(
        foregroundColor: danger ? _dangerRed : CmColors.navy,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: const Size(0, 36),
        visualDensity: VisualDensity.compact,
      ),
    );
  }

  Widget _table({required List<String> headers, required List<DataRow> rows}) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return Container(
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: CmColors.line),
            borderRadius: BorderRadius.circular(12),
          ),
          clipBehavior: Clip.antiAlias,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: constraints.maxWidth),
              child: DataTable(
                headingRowColor: const WidgetStatePropertyAll(
                  Color(0xFFF1F5F9),
                ),
                headingRowHeight: 44,
                dataRowMinHeight: 48,
                dataRowMaxHeight: 76,
                columnSpacing: 28,
                horizontalMargin: 16,
                columns: [
                  for (final h in headers)
                    DataColumn(
                      label: Text(
                        h,
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: CmColors.slate,
                        ),
                      ),
                    ),
                ],
                rows: rows,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _emptyCard({
    required IconData icon,
    required String title,
    String? message,
    Widget? action,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 36),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: CmColors.line),
      ),
      child: Column(
        children: [
          Icon(icon, size: 48, color: CmColors.slate),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
          ),
          if (message != null) ...[
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: CmColors.slate),
            ),
          ],
          if (action != null) ...[const SizedBox(height: 16), action],
        ],
      ),
    );
  }

  Widget _errorBox(String message, VoidCallback onRetry) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48),
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
