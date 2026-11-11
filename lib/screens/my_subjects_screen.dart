import 'package:flutter/material.dart';

import '../services/auth_storage.dart';
import '../services/api_service.dart';
import '../services/grade_report_service.dart';
import 'package:file_selector/file_selector.dart';
import 'package:printing/printing.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/foundation.dart';
import 'package:share_plus/share_plus.dart';
import '../services/my_subjects_api_service.dart';
import 'exams_tab.dart';
import 'teacher_dashboard.dart' show TeacherPage, TeacherShell;

// =============================================================
// CheckMate — My Subjects & Centralized Scorebook (Teacher Portal)
//
//   My Subjects (list)  ->  Subject page  ->  Section scorebook
//                                          ->  Assessment Builder
//
// All four views live inside ONE screen, so the Teacher shell (sidebar /
// bottom bar / drawer) stays in place and "My Subjects" stays highlighted
// the whole time. System back steps back one view.
//
// Every value shown comes from the server (/my-subjects/*). Nothing is
// hard-coded, sampled or mocked: no data means an empty state.
// =============================================================

/// The text typed in the desktop top bar's search field. The shell writes to
/// it; this screen listens. (On phones/tablets the screen shows its own
/// search field because those layouts have no search in the top bar.)
final ValueNotifier<String> mySubjectsSearch = ValueNotifier<String>('');

/// Controls shell chrome only while a section scorebook is visible.
final ValueNotifier<bool> mySubjectsScorebookVisible = ValueNotifier<bool>(false);

const double _kDesktop = 900;
const double _kTablet = 600;

// Brand Palette & Visual Tokens
const Color _navy = Color(0xFF162137);
const Color _ink = Color(0xFF1E293B);
const Color _slate = Color(0xFF64748B);
const Color _bg = Color(0xFFF8FAFC);
const Color _line = Color(0xFFE2E8F0);
const Color _green = Color(0xFF10B981);
const Color _greenDark = Color(0xFF047857);
const Color _amber = Color(0xFFF59E0B);
const Color _amberDark = Color(0xFF92400E);
const Color _red = Color(0xFFB91C1C);

// ---------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------

String _err(Object e) => e.toString().replaceFirst('Exception: ', '');

Future<String> _token() async {
  final t = await AuthStorage.getToken();
  if (t == null || t.isEmpty) {
    throw Exception('Your session has expired. Please log in again.');
  }
  return t;
}

String _ordinal(int n) {
  switch (n) {
    case 1:
      return '1st';
    case 2:
      return '2nd';
    case 3:
      return '3rd';
    default:
      return '${n}th';
  }
}

const _typeLabels = <String, String>{
  'quiz': 'Quiz',
  'short_quiz': 'Short Quiz',
  'long_quiz': 'Long Quiz',
  'performance_task': 'Performance Task',
  'laboratory': 'Laboratory',
  'prelim': 'Prelim',
  'midterm': 'Midterm',
  'prefinal': 'Prefinals',
  'pre_finals': 'Prefinals',
  'final': 'Finals',
  'finals': 'Finals',
  'other': 'Other',
};

String _typeLabel(String? type) => _typeLabels[type] ?? 'Assessment';

String _formatScore(num? v) {
  if (v == null) return '';
  if (v == v.roundToDouble()) return v.toInt().toString();
  return v.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '');
}

int? _int(Object? v) => v is num ? v.toInt() : int.tryParse('$v');

// ---------------------------------------------------------------
// Models (thin wrappers over the server JSON)
// ---------------------------------------------------------------

class _Section {
  const _Section({
    required this.classId,
    required this.name,
    required this.students,
  });

  final int classId;
  final String name;
  final int students;
}

class _Subject {
  const _Subject({
    required this.key,
    required this.subjectId,
    required this.code,
    required this.name,
    required this.department,
    required this.programCode,
    required this.yearLevel,
    required this.semester,
    required this.schoolYear,
    required this.sections,
    required this.totalStudents,
  });

  final String key;
  final int? subjectId;
  final String code;
  final String name;

  /// 'college', 'shs', or null when the section is not in the catalog.
  final String? department;
  final String? programCode;
  final int? yearLevel;
  final int? semester;
  final String? schoolYear;
  final List<_Section> sections;
  final int totalStudents;

  factory _Subject.fromJson(Map<String, dynamic> j) {
    final rawSections = j['sections'];
    return _Subject(
      key: j['key']?.toString() ?? '',
      subjectId: _int(j['subject_id']),
      code: j['code']?.toString() ?? '',
      name: j['name']?.toString() ?? '',
      department: j['department']?.toString(),
      programCode: j['program_code']?.toString(),
      yearLevel: _int(j['year_level']),
      semester: _int(j['semester']),
      schoolYear: j['school_year']?.toString(),
      totalStudents: _int(j['total_students']) ?? 0,
      sections: rawSections is List
          ? rawSections
              .whereType<Map>()
              .map(
                (s) => _Section(
                  classId: _int(s['class_id']) ?? 0,
                  name: s['name']?.toString() ?? '',
                  students: _int(s['students']) ?? 0,
                ),
              )
              .toList()
          : const [],
    );
  }

  List<int> get classIds => sections.map((s) => s.classId).toList();

  String get departmentLabel {
    switch (department) {
      case 'college':
        return 'College';
      case 'shs':
        return 'SHS';
      default:
        return '';
    }
  }

  String get yearLabel {
    final y = yearLevel;
    if (y == null) return '';
    return department == 'shs' ? 'Grade ${y + 10}' : '${_ordinal(y)} Year';
  }

  String get semesterLabel {
    switch (semester) {
      case 1:
        return '1st Semester';
      case 2:
        return '2nd Semester';
      default:
        return '';
    }
  }

  /// Program · Year · Semester
  String get contextLine => [programCode ?? '', yearLabel, semesterLabel]
      .where((e) => e.isNotEmpty)
      .join(' · ');

  /// Department · Program · Year · Semester
  String get fullContextLine => [
        departmentLabel,
        programCode ?? '',
        yearLabel,
        semesterLabel,
      ].where((e) => e.isNotEmpty).join(' · ');

  String get crumb => code.isNotEmpty ? code : name;
}

enum _Kind { list, subject, section, builder }

class _View {
  const _View(
    this.kind, {
    this.subject,
    this.section,
    this.examId,
    this.highlightStudentId,
    this.highlightExamId,
  });

  final _Kind kind;
  final _Subject? subject;
  final _Section? section;
  final int? examId;
  final int? highlightStudentId;
  final int? highlightExamId;
}

// =============================================================
// SCREEN (owns the view stack and the loaded subjects)
// =============================================================

class MySubjectsScreen extends StatefulWidget {
  const MySubjectsScreen({super.key});

  @override
  State<MySubjectsScreen> createState() => _MySubjectsScreenState();
}

class _MySubjectsScreenState extends State<MySubjectsScreen> {
  final List<_View> _stack = [const _View(_Kind.list)];

  List<_Subject> _subjects = const [];
  bool _loading = true;
  String? _error;
  bool _defaultsApplied = false;

  // Filters ('all' = no filter).
  String _dept = 'all';
  String _program = 'all';
  String _year = 'all';
  String _semester = 'all';
  String _schoolYear = 'all';

  late final TextEditingController _searchC;

  @override
  void initState() {
    super.initState();
    mySubjectsSearch.value = '';
    _searchC = TextEditingController();
    mySubjectsSearch.addListener(_onSearch);
    mySubjectsScorebookTarget.addListener(_onScorebookTargetChanged);
    _load();
  }

  @override
  void dispose() {
    mySubjectsSearch.removeListener(_onSearch);
    mySubjectsScorebookTarget.removeListener(_onScorebookTargetChanged);
    _searchC.dispose();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      mySubjectsScorebookVisible.value = false;
    });
    super.dispose();
  }

  void _onSearch() {
    if (!mounted) return;
    if (_searchC.text != mySubjectsSearch.value) {
      _searchC.text = mySubjectsSearch.value;
    }
    setState(() {});
  }

  void _onScorebookTargetChanged() {
    if (!mounted) return;
    final target = mySubjectsScorebookTarget.value;
    if (target == null) return;
    if (_subjects.isNotEmpty) {
      _applyScorebookTarget(target);
    }
  }

  void _applyScorebookTarget(MySubjectsScorebookTarget target) {
    _Subject? matchedSubject;
    _Section? matchedSection;

    for (final subj in _subjects) {
      for (final sec in subj.sections) {
        if (sec.classId == target.classId) {
          matchedSubject = subj;
          matchedSection = sec;
          break;
        }
      }
      if (matchedSubject != null) break;
    }

    if (matchedSubject == null &&
        target.sectionName != null &&
        target.sectionName!.trim().isNotEmpty) {
      final cleanSec = target.sectionName!.trim().toLowerCase();
      for (final subj in _subjects) {
        for (final sec in subj.sections) {
          if (sec.name.trim().toLowerCase() == cleanSec) {
            matchedSubject = subj;
            matchedSection = sec;
            break;
          }
        }
        if (matchedSubject != null) break;
      }
    }

    if (matchedSubject != null && matchedSection != null) {
      mySubjectsScorebookTarget.value = null;
      setState(() {
        _stack
          ..removeRange(1, _stack.length)
          ..add(_View(_Kind.subject, subject: matchedSubject))
          ..add(
            _View(
              _Kind.section,
              subject: matchedSubject,
              section: matchedSection,
              highlightStudentId: target.studentId,
              highlightExamId: target.examId,
            ),
          );
      });
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final token = await _token();
      final raw = await MySubjectsApi.subjects(token);
      final list = raw.map(_Subject.fromJson).toList();

      if (!mounted) return;

      setState(() {
        _subjects = list;
        _loading = false;

        // The current school year is the default filter (once).
        if (!_defaultsApplied) {
          _defaultsApplied = true;
          final years = list
              .map((s) => s.schoolYear)
              .whereType<String>()
              .toSet()
              .toList()
            ..sort();
          _schoolYear = years.isEmpty ? 'all' : years.last;
        }
      });

      final pendingTarget = mySubjectsScorebookTarget.value;
      if (pendingTarget != null) {
        _applyScorebookTarget(pendingTarget);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _err(e);
        _loading = false;
      });
    }
  }

  // ---------- navigation ----------

  void _push(_View v) => setState(() => _stack.add(v));

  void _back() {
    if (_stack.length > 1) setState(_stack.removeLast);
  }

  void _goList() => setState(() => _stack.removeRange(1, _stack.length));

  void _goSubject() {
    setState(() {
      while (_stack.length > 1 && _stack.last.kind != _Kind.subject) {
        _stack.removeLast();
      }
    });
  }

  void _switchSectionInScorebook(_Subject subject, _Section newSection) {
    setState(() {
      if (_stack.isNotEmpty && _stack.last.kind == _Kind.section) {
        _stack[_stack.length - 1] = _View(
          _Kind.section,
          subject: subject,
          section: newSection,
        );
      } else {
        _stack.add(_View(_Kind.section, subject: subject, section: newSection));
      }
    });
  }

  // ---------- filtering ----------

  bool _matchesDept(_Subject s) => _dept == 'all' || s.department == _dept;

  List<String> get _programOptions {
    final set = _subjects
        .where(_matchesDept)
        .map((s) => s.programCode)
        .whereType<String>()
        .toSet()
        .toList()
      ..sort();
    return set;
  }

  List<int> get _yearOptions {
    final set = _subjects
        .where(_matchesDept)
        .where((s) => _program == 'all' || s.programCode == _program)
        .map((s) => s.yearLevel)
        .whereType<int>()
        .toSet()
        .toList()
      ..sort();
    return set;
  }

  List<String> get _schoolYearOptions {
    final set = _subjects
        .map((s) => s.schoolYear)
        .whereType<String>()
        .toSet()
        .toList()
      ..sort((a, b) => b.compareTo(a));
    return set;
  }

  String _yearOptionLabel(int y) {
    if (_dept == 'shs') return 'Grade ${y + 10}';
    if (_dept == 'college') return '${_ordinal(y)} Year';
    return 'Year $y';
  }

  List<_Subject> get _filtered {
    final q = mySubjectsSearch.value.trim().toLowerCase();
    return _subjects.where((s) {
      if (q.isNotEmpty &&
          !s.name.toLowerCase().contains(q) &&
          !s.code.toLowerCase().contains(q)) {
        return false;
      }
      if (!_matchesDept(s)) return false;
      if (_program != 'all' && s.programCode != _program) return false;
      if (_year != 'all' && '${s.yearLevel}' != _year) return false;
      if (_semester != 'all' && '${s.semester}' != _semester) return false;
      if (_schoolYear != 'all' && s.schoolYear != _schoolYear) return false;
      return true;
    }).toList();
  }

  // ---------- build ----------

  @override
  Widget build(BuildContext context) {
    final top = _stack.last;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final sectionVisible = _stack.last.kind == _Kind.section;
      if (mySubjectsScorebookVisible.value != sectionVisible) {
        mySubjectsScorebookVisible.value = sectionVisible;
      }
    });

    return PopScope(
      canPop: _stack.length == 1 || top.kind == _Kind.builder,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_stack.last.kind == _Kind.builder) return;
        _back();
      },
      child: ColoredBox(color: _bg, child: _buildView(top)),
    );
  }

  Widget _buildView(_View v) {
    switch (v.kind) {
      case _Kind.list:
        return _buildList();

      case _Kind.subject:
        final subject = v.subject!;
        return _SubjectPage(
          key: ValueKey('subject-${subject.key}'),
          subject: subject,
          onGoList: _goList,
          onOpenSection: (s) =>
              _push(_View(_Kind.section, subject: subject, section: s)),
          onOpenBuilder: (examId) =>
              _push(_View(_Kind.builder, subject: subject, examId: examId)),
        );

      case _Kind.section:
        final subject = v.subject!;
        final section = v.section!;
        return _SectionPage(
          key: ValueKey(
            'section-${section.classId}-${v.highlightStudentId ?? 0}-${v.highlightExamId ?? 0}',
          ),
          subject: subject,
          section: section,
          highlightStudentId: v.highlightStudentId,
          highlightExamId: v.highlightExamId,
          onGoList: _goList,
          onGoSubject: _goSubject,
          onSwitchSection: (sec) => _switchSectionInScorebook(subject, sec),
          onOpenBuilder: (examId) => _push(_View(_Kind.builder, subject: subject, examId: examId)),
        );

      case _Kind.builder:
        return ExamsTab(
          key: ValueKey('builder-${v.examId}'),
          initialExamId: v.examId,
          onExitBuilder: _back,
        );
    }
  }

  Widget _buildList() {
    final narrow = MediaQuery.sizeOf(context).width < _kDesktop;
    final filtered = _filtered;

    return _PageScroll(
      onRefresh: _load,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'My Subjects',
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w700,
              color: _ink,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Your assigned subjects and section scorebooks across College and Senior High School.',
            style: TextStyle(fontSize: 14, color: _slate),
          ),
          const SizedBox(height: 16),
          if (narrow) ...[
            _SearchField(
              controller: _searchC,
              onChanged: (v) => mySubjectsSearch.value = v,
            ),
            const SizedBox(height: 12),
          ],
          if (_loading)
            const _Centered(child: CircularProgressIndicator(color: _navy))
          else if (_error != null)
            _ErrorBox(message: _error!, onRetry: _load)
          else if (_subjects.isEmpty)
            const _EmptyBox(
              icon: Icons.menu_book_outlined,
              title: 'No subjects assigned yet.',
              message: 'Your assigned subjects will appear here once the '
                  'administrator assigns you to a subject and section.',
            )
          else ...[
            _buildFilters(),
            const SizedBox(height: 20),
            if (filtered.isEmpty)
              const _EmptyBox(
                icon: Icons.filter_alt_off_outlined,
                title: 'No subjects match these filters.',
              )
            else
              ..._buildGroups(filtered),
          ],
        ],
      ),
    );
  }

  Widget _buildFilters() {
    final programs = _programOptions;
    final years = _yearOptions;
    final schoolYears = _schoolYearOptions;

    final fields = <Widget>[
      _FilterField(
        label: 'Department',
        value: _dept,
        options: const [
          MapEntry('all', 'All'),
          MapEntry('college', 'College'),
          MapEntry('shs', 'SHS'),
        ],
        onChanged: (v) => setState(() {
          _dept = v;
          _program = 'all';
          _year = 'all';
        }),
      ),
      _FilterField(
        label: 'Program / Strand',
        value: programs.contains(_program) ? _program : 'all',
        options: [
          const MapEntry('all', 'All'),
          for (final p in programs) MapEntry(p, p),
        ],
        onChanged: (v) => setState(() {
          _program = v;
          _year = 'all';
        }),
      ),
      _FilterField(
        label: 'Year level',
        value: years.any((y) => '$y' == _year) ? _year : 'all',
        options: [
          const MapEntry('all', 'All'),
          for (final y in years) MapEntry('$y', _yearOptionLabel(y)),
        ],
        onChanged: (v) => setState(() => _year = v),
      ),
      _FilterField(
        label: 'Semester',
        value: _semester,
        options: const [
          MapEntry('all', 'All'),
          MapEntry('1', 'First Semester'),
          MapEntry('2', 'Second Semester'),
        ],
        onChanged: (v) => setState(() => _semester = v),
      ),
      _FilterField(
        label: 'School year',
        value: schoolYears.contains(_schoolYear) ? _schoolYear : 'all',
        options: [
          const MapEntry('all', 'All'),
          for (final y in schoolYears) MapEntry(y, y),
        ],
        onChanged: (v) => setState(() => _schoolYear = v),
      ),
    ];

    return LayoutBuilder(
      builder: (context, box) {
        final perRow = box.maxWidth < _kTablet
            ? 2
            : (box.maxWidth ~/ 190).clamp(2, 5);
        const gap = 12.0;
        final w = (box.maxWidth - gap * (perRow - 1)) / perRow - 0.01;

        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [for (final f in fields) SizedBox(width: w, child: f)],
        );
      },
    );
  }

  List<Widget> _buildGroups(List<_Subject> filtered) {
    final groups = <(String, List<_Subject>)>[
      (
        'College Department',
        filtered.where((s) => s.department == 'college').toList()
      ),
      (
        'Senior High School',
        filtered.where((s) => s.department == 'shs').toList()
      ),
      (
        'Other',
        filtered
            .where((s) => s.department != 'college' && s.department != 'shs')
            .toList()
      ),
    ];

    final out = <Widget>[];
    for (final (title, items) in groups) {
      if (items.isEmpty) continue;

      final distinct = items.map((s) => s.subjectId ?? s.key).toSet().length;

      out
        ..add(
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: _ink,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _Pill(text: '$distinct', background: _line, color: _ink),
              ],
            ),
          ),
        )
        ..add(
          _ResponsiveGrid(
            children: [
              for (final s in items)
                _SubjectCard(
                  subject: s,
                  onTap: () => _push(_View(_Kind.subject, subject: s)),
                ),
            ],
          ),
        )
        ..add(const SizedBox(height: 28));
    }
    return out;
  }
}

// =============================================================
// SHARED WIDGETS
// =============================================================

class _PageScroll extends StatelessWidget {
  const _PageScroll({required this.child, this.onRefresh});

  final Widget child;
  final Future<void> Function()? onRefresh;

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    final pad = w >= _kDesktop ? 32.0 : (w >= _kTablet ? 24.0 : 16.0);

    final scroll = SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.fromLTRB(pad, 24, pad, 32),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1200),
          child: child,
        ),
      ),
    );

    final refresh = onRefresh;
    return refresh == null
        ? scroll
        : RefreshIndicator(color: _navy, onRefresh: refresh, child: scroll);
  }
}

class _Centered extends StatelessWidget {
  const _Centered({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 48),
        child: Center(child: child),
      );
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return _Centered(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, size: 40, color: _slate),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: _ink),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            style: OutlinedButton.styleFrom(
              foregroundColor: _navy,
              minimumSize: const Size(88, 44),
            ),
            onPressed: onRetry,
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}

class _EmptyBox extends StatelessWidget {
  const _EmptyBox({
    required this.icon,
    required this.title,
    this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 36),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _line),
      ),
      child: Column(
        children: [
          Icon(icon, size: 40, color: _slate),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: _ink,
            ),
          ),
          if (message != null) ...[
            const SizedBox(height: 6),
            Text(
              message!,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: _slate),
            ),
          ],
          if (action != null) ...[
            const SizedBox(height: 16),
            action!,
          ],
        ],
      ),
    );
  }
}

class _AddStudentsButton extends StatelessWidget {
  const _AddStudentsButton();

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: () {
        context
            .findAncestorWidgetOfExactType<TeacherShell>()
            ?.onSelect(TeacherPage.students);
      },
      style: FilledButton.styleFrom(
        backgroundColor: _navy,
        foregroundColor: Colors.white,
        minimumSize: const Size(0, 44),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        shape: const StadiumBorder(),
      ),
      icon: const Icon(Icons.person_add_alt_1_outlined, size: 20),
      label: const Text(
        'Add Students',
        style: TextStyle(fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.text,
    required this.background,
    required this.color,
  });

  final String text;
  final Color background;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.onChanged,
    this.hintText = 'Search subjects by name or code',
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final String hintText;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      style: const TextStyle(color: _ink),
      decoration: InputDecoration(
        hintText: hintText,
        hintStyle: const TextStyle(color: _slate, fontSize: 14),
        prefixIcon: const Icon(Icons.search, color: _slate),
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: _line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: _line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: _navy, width: 1.5),
        ),
      ),
    );
  }
}

class _FilterField extends StatelessWidget {
  const _FilterField({
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final String label;
  final String value;
  final List<MapEntry<String, String>> options;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        filled: true,
        fillColor: Colors.white,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: _line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: _line),
        ),
      ),
      child: DropdownButtonHideUnderline(
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: DropdownButton<String>(
            value: value,
            isExpanded: true,
            isDense: true,
            style: const TextStyle(fontSize: 14, color: _ink),
            items: [
              for (final o in options)
                DropdownMenuItem<String>(
                  value: o.key,
                  child: Text(o.value, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (v) {
              if (v != null) onChanged(v);
            },
          ),
        ),
      ),
    );
  }
}

/// 2 columns on desktop/tablet, 1 on phone.
class _ResponsiveGrid extends StatelessWidget {
  const _ResponsiveGrid({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final screenW = MediaQuery.sizeOf(context).width;
    final cols = screenW >= _kDesktop ? 2 : (screenW >= _kTablet ? 2 : 1);
    const gap = 16.0;

    return LayoutBuilder(
      builder: (context, box) {
        final itemW = (box.maxWidth - gap * (cols - 1)) / cols - 0.01;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final c in children) SizedBox(width: itemW, child: c),
          ],
        );
      },
    );
  }
}

class _HoverCard extends StatefulWidget {
  const _HoverCard({
    required this.onTap,
    required this.semanticsLabel,
    required this.builder,
  });

  final VoidCallback onTap;
  final String semanticsLabel;
  final Widget Function(bool hovered) builder;

  @override
  State<_HoverCard> createState() => _HoverCardState();
}

class _HoverCardState extends State<_HoverCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Semantics(
        button: true,
        label: widget.semanticsLabel,
        excludeSemantics: true,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _hover ? _navy.withValues(alpha: 0.35) : _line),
            boxShadow: _hover
                ? [
                    BoxShadow(
                      color: _navy.withValues(alpha: 0.08),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                  ]
                : [
                    BoxShadow(
                      color: _navy.withValues(alpha: 0.03),
                      blurRadius: 10,
                      offset: const Offset(0, 3),
                    ),
                  ],
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: widget.onTap,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 44),
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: widget.builder(_hover),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SubjectCard extends StatelessWidget {
  const _SubjectCard({required this.subject, required this.onTap});

  final _Subject subject;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = subject;
    final sectionNames = s.sections.map((e) => e.name).join(' · ');

    return _HoverCard(
      onTap: onTap,
      semanticsLabel: '${s.code} ${s.name}. Open subject.',
      builder: (hovered) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: _navy.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.menu_book_outlined,
                  size: 20,
                  color: _navy,
                ),
              ),
              const SizedBox(width: 10),
              if (s.code.isNotEmpty)
                Flexible(
                  child: _Pill(
                    text: s.code,
                    background: _navy.withValues(alpha: 0.08),
                    color: _navy,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            s.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: _ink,
            ),
          ),
          if (s.contextLine.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              s.contextLine,
              style: const TextStyle(fontSize: 13, color: _slate),
            ),
          ],
          const SizedBox(height: 6),
          Text(
            sectionNames,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: _slate,
            ),
          ),
          const SizedBox(height: 12),
          const Divider(height: 1, color: _line),
          const SizedBox(height: 10),
          Row(
            children: [
              const Icon(Icons.people_outline, size: 18, color: _slate),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${s.sections.length} ${s.sections.length == 1 ? 'section' : 'sections'} • '
                  '${s.totalStudents} ${s.totalStudents == 1 ? 'student' : 'students'}',
                  style: const TextStyle(fontSize: 13, color: _slate),
                ),
              ),
              AnimatedSlide(
                duration: const Duration(milliseconds: 160),
                offset: hovered ? const Offset(0.25, 0) : Offset.zero,
                child: const Icon(Icons.arrow_forward, size: 20, color: _navy),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Crumb {
  const _Crumb(this.label, [this.onTap]);

  final String label;
  final VoidCallback? onTap;
}

class _Breadcrumb extends StatelessWidget {
  const _Breadcrumb({required this.items});

  final List<_Crumb> items;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4),
              child: Text('/', style: TextStyle(color: _slate)),
            ),
          if (items[i].onTap == null)
            Text(
              items[i].label,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: _ink,
              ),
            )
          else
            InkWell(
              onTap: items[i].onTap,
              borderRadius: BorderRadius.circular(6),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 44),
                child: Center(
                  widthFactor: 1,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      items[i].label,
                      style: const TextStyle(fontSize: 14, color: _slate),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ],
    );
  }
}

// =============================================================
// SUBJECT PAGE
// =============================================================

class _SubjectPage extends StatefulWidget {
  const _SubjectPage({
    super.key,
    required this.subject,
    required this.onGoList,
    required this.onOpenSection,
    required this.onOpenBuilder,
  });

  final _Subject subject;
  final VoidCallback onGoList;
  final ValueChanged<_Section> onOpenSection;
  final ValueChanged<int> onOpenBuilder;

  @override
  State<_SubjectPage> createState() => _SubjectPageState();
}

class _SubjectPageState extends State<_SubjectPage> {
  List<Map<String, dynamic>> _assessments = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final token = await _token();
      final items = await MySubjectsApi.assessments(
        token,
        widget.subject.classIds,
      );
      if (!mounted) return;
      setState(() {
        _assessments = items;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _err(e);
        _loading = false;
      });
    }
  }

  Future<void> _newAssessment() async {
    final s = widget.subject;
    final subjectClasses = <Map<String, dynamic>>[
      for (final sec in s.sections)
        <String, dynamic>{
          'id': sec.classId,
          'section': sec.name,
          'student_count': sec.students,
          'school_year': s.schoolYear,
          'semester': s.semesterLabel.isNotEmpty
              ? s.semesterLabel
              : (s.semester != null ? '${s.semester}' : ''),
          'year_level': s.yearLevel,
          'subject': <String, dynamic>{
            'id': s.subjectId,
            'code': s.code,
            'name': s.name,
          },
        },
    ];
    final created = await showAssessmentCreation(context,classes:subjectClasses,initialClassId:s.sections.isNotEmpty?s.sections.first.classId:null);
    if(created?.manual==true && mounted){
      final section=s.sections.firstWhere((sec)=>sec.classId==created!.classId);
      widget.onOpenSection(section);
      return;
    }
    final examId=created?.examId;
    if (examId != null && examId > 0 && mounted) {
      widget.onOpenBuilder(examId);
    } else if (examId != null && mounted) {
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.subject;
    final narrow = MediaQuery.sizeOf(context).width < _kTablet;

    // Deep Navy Primary CTA Button (never amber/orange).
    final newButton = narrow
        ? IconButton.filled(
            tooltip: 'New assessment',
            onPressed: _newAssessment,
            style: IconButton.styleFrom(
              backgroundColor: _navy,
              foregroundColor: Colors.white,
              minimumSize: const Size(44, 44),
            ),
            icon: const Icon(Icons.add),
          )
        : FilledButton.icon(
            onPressed: _newAssessment,
            style: FilledButton.styleFrom(
              backgroundColor: _navy,
              foregroundColor: Colors.white,
              minimumSize: const Size(0, 44),
              padding: const EdgeInsets.symmetric(horizontal: 18),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            icon: const Icon(Icons.add),
            label: const Text(
              'New assessment',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          );

    return _PageScroll(
      onRefresh: _load,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Breadcrumb(
            items: [
              _Crumb('My Subjects', widget.onGoList),
              _Crumb(s.crumb),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  s.name,
                  style: const TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                    color: _ink,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              newButton,
            ],
          ),
          if (s.fullContextLine.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              s.fullContextLine,
              style: const TextStyle(fontSize: 14, color: _slate),
            ),
          ],
          const SizedBox(height: 28),
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Assigned Sections & Scorebooks',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: _ink,
                  ),
                ),
              ),
              _Pill(
                text:
                    '${_assessments.length} ${_assessments.length == 1 ? 'exam' : 'exams'} • ${s.totalStudents} students',
                background: _line,
                color: _ink,
              ),
            ],
          ),
          const SizedBox(height: 12),
          _ResponsiveGrid(
            children: [
              for (final sec in s.sections)
                _SectionCard(
                  subject: s,
                  section: sec,
                  examCount: _assessments.length,
                  onTap: () => widget.onOpenSection(sec),
                ),
            ],
          ),
          const SizedBox(height: 32),
          const Text(
            'Assessment Library',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: _ink,
            ),
          ),
          const SizedBox(height: 12),
          if (_loading)
            const _Centered(child: CircularProgressIndicator(color: _navy))
          else if (_error != null)
            _ErrorBox(message: _error!, onRetry: _load)
          else if (_assessments.isEmpty)
            const _EmptyBox(
              icon: Icons.assignment_outlined,
              title: 'No assessments yet.',
            )
          else
            Column(
              children: [
                for (final a in _assessments)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _AssessmentRow(
                      assessment: a,
                      onTap: () {
                        final id = _int(a['id']);
                        if(a['creation_mode']=='manual'){
                          final names=(a['sections'] as List?)??[];
                          widget.onOpenSection(s.sections.firstWhere((sec)=>names.contains(sec.name),orElse:()=>s.sections.first));
                        }else if (id != null) {widget.onOpenBuilder(id);}
                      },
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.subject,
    required this.section,
    required this.examCount,
    required this.onTap,
  });

  final _Subject subject;
  final _Section section;
  final int examCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _HoverCard(
      onTap: onTap,
      semanticsLabel: 'Open section ${section.name}',
      builder: (hovered) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  section.name,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: _ink,
                  ),
                ),
              ),
              if (subject.code.isNotEmpty)
                _Pill(
                  text: subject.code,
                  background: _navy.withValues(alpha: 0.08),
                  color: _navy,
                ),
            ],
          ),
          if (subject.contextLine.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              subject.contextLine,
              style: const TextStyle(fontSize: 13, color: _slate),
            ),
          ],
          const SizedBox(height: 6),
          Text(
            '${section.students} ${section.students == 1 ? 'student' : 'students'} • '
            '$examCount ${examCount == 1 ? 'assessment' : 'assessments'}',
            style: const TextStyle(fontSize: 13, color: _slate),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              const Text(
                'Open section scorebook',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: _navy,
                ),
              ),
              const SizedBox(width: 4),
              AnimatedSlide(
                duration: const Duration(milliseconds: 160),
                offset: hovered ? const Offset(0.25, 0) : Offset.zero,
                child: const Icon(Icons.arrow_forward, size: 18, color: _navy),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AssessmentRow extends StatelessWidget {
  const _AssessmentRow({required this.assessment, required this.onTap});

  final Map<String, dynamic> assessment;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final a = assessment;
    final title = a['title']?.toString() ?? 'Untitled';
    final questions = _int(a['question_count']) ?? 0;
    final version = _int(a['version']) ?? 1;
    final status = a['status']?.toString() ?? 'draft';
    final sections = a['sections'] is List
        ? (a['sections'] as List).map((e) => '$e').toList()
        : <String>[];

    final published = status == 'published';
    final statusText = a['creation_mode']=='manual' ? 'Manual Score' : published
        ? 'Published'
        : (status == 'archived' ? 'Archived' : 'Draft');

    return _HoverCard(
      onTap: onTap,
      semanticsLabel: 'Open assessment $title',
      builder: (_) => Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: _ink,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '${_typeLabel(a['assessment_type']?.toString())} · '
                  '$questions ${questions == 1 ? 'question' : 'questions'} · '
                  'v$version',
                  style: const TextStyle(fontSize: 13, color: _slate),
                ),
                if (sections.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    sections.join(' · '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: _slate),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          _Pill(
            text: statusText,
            background: published ? _green.withValues(alpha: 0.15) : _line,
            color: published ? _greenDark : _slate,
          ),
        ],
      ),
    );
  }
}

// =============================================================
// SECTION SCOREBOOK (MOBILE CARDS + DESKTOP TABULAR GRADEBOOK)
// =============================================================

List<Map<String, dynamic>> _maps(Object? raw) => raw is List
    ? raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
    : <Map<String, dynamic>>[];

class _SectionPage extends StatefulWidget {
  const _SectionPage({
    super.key,
    required this.subject,
    required this.section,
    required this.onGoList,
    required this.onGoSubject,
    required this.onSwitchSection,
    required this.onOpenBuilder,
    this.highlightStudentId,
    this.highlightExamId,
  });

  final _Subject subject;
  final _Section section;
  final VoidCallback onGoList;
  final VoidCallback onGoSubject;
  final ValueChanged<_Section> onSwitchSection;
  final ValueChanged<int> onOpenBuilder;
  final int? highlightStudentId;
  final int? highlightExamId;

  @override
  State<_SectionPage> createState() => _SectionPageState();
}

class _SectionPageState extends State<_SectionPage> {
  static const double _colW = 76;
  static const double _totalColW = 84;
  static const double _avgColW = 108;
  static const double _rowH = 56;
  static const double _headH = 90;

  List<Map<String,dynamic>> _allAssessments=const [];
  Map<String,dynamic> _book={};
  String _period='prelims';
  bool _targetPeriodApplied=false;
  static const _categoryNames={'pt':'Performance Tasks / Laboratory','quiz':'Quizzes','exam':'Major Examination'};
  Map<String,dynamic> get _preferences => Map<String,dynamic>.from(_book['preferences'] as Map? ?? {});
  List<Map<String,dynamic>> get _assessments {
    final result=_allAssessments.where((a)=>_period=='unclassified'?a['requires_classification']==true:a['grading_period']==_period && a['requires_classification']!=true).toList();
    const rank={'pt':0,'quiz':1,'exam':2};
    result.sort((a,b){final c=(rank[a['grading_category']]??3).compareTo(rank[b['grading_category']]??3);return c!=0?c:(_int(a['id'])??0).compareTo(_int(b['id'])??0);});
    return result;
  }
  Map<String,dynamic> _periodGrade(Map<String,dynamic> s)=>Map<String,dynamic>.from((s['grading'] as Map?)?[_period] as Map? ?? {});
  String _percentage(Object? v)=>v is num?'${v.toStringAsFixed(2)}%':'INC';
  String _categoryPercentage(Map<String,dynamic> student,String key)=>_percentage((_periodGrade(student)['categories'] as Map?)?[key]?['percentage']);

  List<Map<String, dynamic>> _students = const [];
  bool _loading = true;
  String? _error;
  String _filter = 'all';
  String _studentQuery = '';

  int? _activeHighlightStudentId;
  int? _activeHighlightExamId;

  final ScrollController _hScroll = ScrollController();
  final TextEditingController _studentSearchC = TextEditingController();
  final Map<int, GlobalKey> _studentRowKeys = <int, GlobalKey>{};

  @override
  void initState() {
    super.initState();
    _activeHighlightStudentId = widget.highlightStudentId;
    _activeHighlightExamId = widget.highlightExamId;
    _load();
  }

  @override
  void dispose() {
    _hScroll.dispose();
    _studentSearchC.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final token = await _token();
      final data = await MySubjectsApi.scorebook(token, widget.section.classId);

      final students = _maps(data['students']);
      for (final s in students) {
        s['cells'] = _maps(s['cells']);
      }

      if (!mounted) return;
      setState(() {
        _book=data;
        _allAssessments = _maps(data['assessments']);
        if(!_targetPeriodApplied && _activeHighlightExamId!=null){
          _targetPeriodApplied=true;
          final target=_allAssessments.where((a)=>_int(a['id'])==_activeHighlightExamId).firstOrNull;
          if(target!=null)_period=target['requires_classification']==true?'unclassified':target['grading_period']?.toString()??'unclassified';
        }
        _students = students;
        _loading = false;
      });

      if (_activeHighlightStudentId != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _scrollToHighlightedRecord();
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _err(e);
        _loading = false;
      });
    }
  }

  void _scrollToHighlightedRecord() {
    if (!mounted) return;
    final sid = _activeHighlightStudentId;
    if (sid != null) {
      final key = _studentRowKeys[sid];
      final ctx = key?.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 450),
          curve: Curves.easeOutCubic,
          alignment: 0.3,
        );
      }
    }

    final eid = _activeHighlightExamId;
    if (eid != null && _hScroll.hasClients) {
      final idx = _assessments.indexWhere((a) => _int(a['id']) == eid);
      if (idx > 0) {
        final targetOffset = _assessmentHorizontalOffset(eid).clamp(
          0.0,
          _hScroll.position.maxScrollExtent,
        );
        _hScroll.animateTo(
          targetOffset,
          duration: const Duration(milliseconds: 450),
          curve: Curves.easeOutCubic,
        );
      }
    }

    Future<void>.delayed(const Duration(seconds: 4), () {
      if (!mounted) return;
      setState(() {
        _activeHighlightStudentId = null;
        _activeHighlightExamId = null;
      });
    });
  }

  List<Map<String,dynamic>> _cells(Map<String,dynamic> s) {
    final byId={for(final c in _maps(s['cells'])) c['exam_id']:c};
    return [for(final a in _assessments) byId[a['id']]??{'exam_id':a['id'],'status':'pending','score':null,'max_score':a['total_points']}];
  }

  int _countFor(String f) => f == 'all'
      ? _students.length
      : _students.where((s) => _cells(s).any((c) => c['status'] == f)).length;

  String _studentName(Map<String, dynamic> s) {
    final last = (s['last_name']?.toString() ?? '').trim().toUpperCase();
    final first = (s['first_name']?.toString() ?? '').trim().toUpperCase();
    if (last.isNotEmpty && first.isNotEmpty) return '$last, $first';
    return '$last $first'.trim();
  }

  double? _studentAveragePercent(Map<String,dynamic> s) {
    final grade=_periodGrade(s)['grade'];
    return grade is num?grade.toDouble():null;
  }

  List<Map<String, dynamic>> get _visible {
    final q = _studentQuery.trim().toLowerCase();
    return _students.where((s) {
      if (_filter != 'all' &&
          !_cells(s).any((c) => c['status'] == _filter)) {
        return false;
      }
      if (q.isNotEmpty) {
        final name = _studentName(s).toLowerCase();
        final snum = (s['student_number']?.toString() ?? '').toLowerCase();
        if (!name.contains(q) && !snum.contains(q)) {
          return false;
        }
      }
      return true;
    }).toList();
  }

  Future<void> _onCellTapped(
    Map<String, dynamic> student,
    Map<String, dynamic> cell,
    Map<String, dynamic> assessment,
  ) async {
    if(assessment['creation_mode']=='manual'){await _editManualScore(student,cell,assessment);return;}
    final status = cell['status']?.toString() ?? 'pending';
    final examTitle = assessment['title']?.toString() ?? 'Assessment';

    if (status == 'completed' || status == 'needs_review') {
      await _showManageScoreModal(student, cell, assessment);
      return;
    }

    if (status != 'pending' && status != 'absent') return;

    final marking = status == 'pending';
    final name = _studentName(student);

    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Text(
          marking ? 'Mark as absent?' : 'Remove absent mark?',
          style: const TextStyle(fontWeight: FontWeight.w700, color: _ink),
        ),
        content: Text(
          marking
              ? '$name will be recorded as absent for "$examTitle". '
                  'Only do this once you have confirmed they did not take it.'
              : '$name will go back to Pending for "$examTitle".',
        ),
        actions: [
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: _slate,
              minimumSize: const Size(88, 44),
            ),
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: _navy,
              foregroundColor: Colors.white,
              minimumSize: const Size(88, 44),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: () => Navigator.pop(c, true),
            child: Text(marking ? 'Mark absent' : 'Remove'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    try {
      final token = await _token();
      await MySubjectsApi.setAbsent(
        token,
        classId: widget.section.classId,
        examId: _int(cell['exam_id']) ?? 0,
        studentId: _int(student['id']) ?? 0,
        absent: marking,
      );
      if (!mounted) return;
      setState(() => cell['status'] = marking ? 'absent' : 'pending');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_err(e))),
      );
    }
  }

  Future<void> _showManageScoreModal(
    Map<String, dynamic> student,
    Map<String, dynamic> cell,
    Map<String, dynamic> assessment,
  ) async {
    final name = _studentName(student);
    final snum = student['student_number']?.toString() ?? '';
    final examTitle = assessment['title']?.toString() ?? 'Assessment';
    final examId = _int(cell['exam_id']) ?? _int(assessment['id']) ?? 0;
    final studentId = _int(student['id']) ?? 0;
    final attemptId = _int(cell['attempt_id']);
    final score = cell['score'] is num ? cell['score'] as num : null;
    final maxScore = cell['max_score'] is num ? cell['max_score'] as num : null;
    final pct = (score != null && maxScore != null && maxScore > 0)
        ? ((score.toDouble() / maxScore.toDouble()) * 100.0).round()
        : null;

    final deleteRequested = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => Dialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: _green.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(
                        Icons.fact_check_outlined,
                        color: _greenDark,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            examTitle,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: _ink,
                            ),
                          ),
                          Text(
                            '${widget.subject.code} • ${widget.section.name}',
                            style: const TextStyle(
                              fontSize: 12.5,
                              color: _slate,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(dialogContext, false),
                      icon: const Icon(Icons.close, color: _slate),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: _bg,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: _line),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: const TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700,
                          color: _ink,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Student No: $snum • Section: ${widget.section.name}',
                        style: const TextStyle(fontSize: 12.5, color: _slate),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Text(
                            maxScore != null
                                ? '${_formatScore(score)} / ${_formatScore(maxScore)}'
                                : _formatScore(score),
                            style: const TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.w800,
                              color: _ink,
                            ),
                          ),
                          if (pct != null) ...[
                            const SizedBox(width: 10),
                            _Pill(
                              text: '$pct%',
                              background: _green.withValues(alpha: 0.15),
                              color: _greenDark,
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () => Navigator.pop(dialogContext, true),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: _red,
                        side: BorderSide(color: _red.withValues(alpha: 0.4)),
                        minimumSize: const Size(0, 44),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: const Text(
                        'Delete Score',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    const SizedBox(width: 10),
                    FilledButton(
                      onPressed: () => Navigator.pop(dialogContext, false),
                      style: FilledButton.styleFrom(
                        backgroundColor: _navy,
                        foregroundColor: Colors.white,
                        minimumSize: const Size(88, 44),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text('Done'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (deleteRequested != true || !mounted) return;

    final confirmDelete = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: const Text(
          'Delete recorded score?',
          style: TextStyle(fontWeight: FontWeight.w700, color: _ink),
        ),
        content: Text(
          'Delete $name\'s recorded score for "$examTitle"? Their status will return to Pending.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: _red,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Delete Score'),
          ),
        ],
      ),
    );

    if (confirmDelete != true || !mounted) return;

    try {
      final token = await _token();
      await MySubjectsApi.deleteScore(
        token,
        classId: widget.section.classId,
        examId: examId,
        studentId: studentId,
        attemptId: attemptId,
      );
      if (!mounted) return;
      setState(() {
        cell['status'] = 'pending';
        cell['score'] = null;
        cell['attempt_id'] = null;
        student['average_percentage'] = null;
      });
      await _load();
      if(!mounted)return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: _navy,
          content: Text('Deleted recorded score for $name on "$examTitle".'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(backgroundColor: _red, content: Text(_err(e))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final subject = widget.subject;
    final section = widget.section;
    final title = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'My Subjects / Section Scorebook',
          style: TextStyle(
            fontSize: 27,
            fontWeight: FontWeight.w700,
            color: Color(0xFF26334B),
          ),
        ),
        const SizedBox(height: 5),
        Text(
          [
            subject.code,
            subject.name,
            section.name,
            subject.fullContextLine,
          ].where((s) => s.isNotEmpty).join(' · '),
          style: const TextStyle(fontSize: 13, color: Color(0xFF7A8AA5)),
        ),
      ],
    );
    return _PageScroll(
      onRefresh: _load,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Breadcrumb(
            items: [
              _Crumb('My Subjects', widget.onGoList),
              _Crumb(subject.crumb, widget.onGoSubject),
              _Crumb(section.name),
            ],
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, box) {
              if (box.maxWidth < 1050)
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    title,
                    const SizedBox(height: 16),
                    Align(
                      alignment: Alignment.centerRight,
                      child: _loading || _error != null
                          ? const SizedBox.shrink()
                          : _scorebookActions(),
                    ),
                  ],
                );
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: title),
                  const SizedBox(width: 20),
                  if (!_loading && _error == null) _scorebookActions(),
                ],
              );
            },
          ),
          const SizedBox(height: 24),
          LayoutBuilder(
            builder: (context, box) {
              if (box.maxWidth < 700)
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _periodButtons(),
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerRight,
                      child: _sectionSelector(),
                    ),
                  ],
                );
              return Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(child: _periodButtons()),
                  const SizedBox(width: 24),
                  _sectionSelector(),
                ],
              );
            },
          ),
          const SizedBox(height: 20),
          if (_period == 'unclassified') ...[
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFFF3F7FD),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Historical assessments need teacher confirmation before final grades can be calculated.',
                  ),
                  for (final a in _assessments)
                    TextButton(
                      onPressed: () => _classifyAssessment(a),
                      child: Text('Classify ${a['title']}'),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],
          if (_loading)
            const _Centered(child: CircularProgressIndicator(color: _navy))
          else if (_error != null)
            _ErrorBox(message: _error!, onRetry: _load)
          else
            ..._content(),
        ],
      ),
    );
  }

  ButtonStyle get _scorebookOutline => OutlinedButton.styleFrom(
    foregroundColor: const Color(0xFF182238),
    backgroundColor: Colors.white,
    side: const BorderSide(color: Color(0xFFDCE4EF)),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
    minimumSize: const Size(0, 42),
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
  );

  Widget _sectionSelector() => SizedBox(
    width: 170,
    child: _FilterField(
      label: 'Section',
      value: '${widget.section.classId}',
      options: [
        for (final item in widget.subject.sections)
          MapEntry('${item.classId}', item.name),
      ],
      onChanged: (value) {
        final id = int.tryParse(value);
        if (id == null || id == widget.section.classId) return;
        final section = widget.subject.sections.firstWhere(
          (s) => s.classId == id,
          orElse: () => widget.section,
        );
        widget.onSwitchSection(section);
      },
    ),
  );

  Widget _periodButtons() => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final entry in <String, String>{
        ...gradingPeriodLabels,
        if (_allAssessments.any((a) => a['requires_classification'] == true))
          'unclassified': 'Needs Classification',
      }.entries)
        OutlinedButton(
          onPressed: () => setState(() => _period = entry.key),
          style: _scorebookOutline.copyWith(
            backgroundColor: WidgetStatePropertyAll(
              _period == entry.key ? const Color(0xFF182238) : Colors.white,
            ),
            foregroundColor: WidgetStatePropertyAll(
              _period == entry.key ? Colors.white : const Color(0xFF66758E),
            ),
            side: WidgetStatePropertyAll(
              BorderSide(
                color: _period == entry.key
                    ? const Color(0xFF182238)
                    : const Color(0xFFDCE4EF),
              ),
            ),
          ),
          child: Text(entry.value),
        ),
    ],
  );

  Widget _scorebookActions() => Wrap(
    spacing: 8,
    runSpacing: 8,
    alignment: WrapAlignment.end,
    children: [
      OutlinedButton.icon(
        onPressed: _editPreferences,
        style: _scorebookOutline,
        icon: const Icon(Icons.tune, size: 16),
        label: const Text('Grading Preferences'),
      ),
      OutlinedButton(
        onPressed: _showWholeSectionReport,
        style: _scorebookOutline,
        child: const Text('Whole Section Report'),
      ),
      FilledButton.icon(
        onPressed: _createSectionAssessment,
        style: FilledButton.styleFrom(
          backgroundColor: const Color(0xFF182238),
          foregroundColor: Colors.white,
          minimumSize: const Size(0, 42),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
        ),
        icon: const Icon(Icons.add, size: 16),
        label: const Text('Add Assessment'),
      ),
    ],
  );

  Future<void> _createSectionAssessment() async {
    final subject = widget.subject;
    final classes = [
      for (final section in subject.sections)
        <String, dynamic>{
          'id': section.classId,
          'section': section.name,
          'student_count': section.students,
          'school_year': subject.schoolYear,
          'semester': subject.semesterLabel,
          'year_level': subject.yearLevel,
          'subject': {
            'id': subject.subjectId,
            'code': subject.code,
            'name': subject.name,
          },
        },
    ];
    final created = await showAssessmentCreation(
      context,
      classes: classes,
      initialClassId: widget.section.classId,
    );
    if (created == null || !mounted) return;
    if (!created.manual) {
      widget.onOpenBuilder(created.examId);
      return;
    }
    mySubjectsScorebookTarget.value = MySubjectsScorebookTarget(
      classId: created.classId ?? widget.section.classId,
      examId: created.examId,
      studentId: 0,
    );
  }

  List<String> get _scorebookGroups => [
    ..._categoryNames.keys,
    if (_period == 'unclassified' &&
        _assessments.any((a) => a['grading_category'] == null))
      'unknown',
  ];
  List<Map<String, dynamic>> _groupAssessments(String key) => _assessments
      .where((a) => (a['grading_category'] ?? 'unknown') == key)
      .toList();
  Color _assessmentHeaderColor(String key) => switch (key) {
    'pt' => const Color(0xFFD4E5F8),
    'quiz' => const Color(0xFFD9F6DF),
    'exam' => const Color(0xFFFFF1AC),
    _ => const Color(0xFFEDF2F8),
  };
  double _assessmentHorizontalOffset(int examId) {
    double offset = 0;
    for (final group in _scorebookGroups) {
      final items = _groupAssessments(group);
      if (items.isEmpty) offset += _colW;
      for (final assessment in items) {
        if (_int(assessment['id']) == examId) return offset;
        offset += _colW;
      }
      if (group != 'unknown') offset += _totalColW;
    }
    return 0;
  }

  Widget _scorebookCaption() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 17),
    child: Wrap(
      spacing: 12,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          '${gradingPeriodLabels[_period] ?? 'Needs Classification'} Scorebook',
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: Color(0xFF26334B),
          ),
        ),
        Text(
          '·  ${_assessments.length} assessments · Click a student to open grade information',
          style: const TextStyle(fontSize: 12, color: Color(0xFF7A8AA5)),
        ),
      ],
    ),
  );

  Future<void> _editManualScore(
    Map<String, dynamic> student,
    Map<String, dynamic> cell,
    Map<String, dynamic> assessment,
  ) async {
    final controller = TextEditingController(
      text: _formatScore(cell['score'] as num?),
    );
    String? error;
    bool saving = false;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (c) => StatefulBuilder(
        builder: (c, setS) => AlertDialog(
          title: Text('${assessment['column_label']} · ${assessment['title']}'),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(_studentName(student)),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  enabled: !saving,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: 'Score / ${assessment['total_points']}',
                    helperText:
                        'Leave blank to clear. Zero is a recorded score.',
                    errorText: error,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: saving ? null : () => Navigator.pop(c),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: saving
                  ? null
                  : () async {
                      final raw = controller.text.trim();
                      final score = raw.isEmpty ? null : num.tryParse(raw);
                      final max = assessment['total_points'] as num;
                      if (raw.isNotEmpty &&
                          (score == null ||
                              !score.isFinite ||
                              score < 0 ||
                              score > max)) {
                        setS(() => error = 'Enter a score between 0 and $max.');
                        return;
                      }
                      setS(() {
                        saving = true;
                        error = null;
                      });
                      try {
                        await MySubjectsApi.saveManualScore(
                          await _token(),
                          classId: widget.section.classId,
                          examId: _int(assessment['id'])!,
                          studentId: _int(student['id'])!,
                          score: score,
                        );
                        if (c.mounted) Navigator.pop(c);
                      } catch (e) {
                        if (c.mounted)
                          setS(() {
                            saving = false;
                            error = _err(e);
                          });
                      }
                    },
              child: Text(saving ? 'Saving…' : 'Save Score'),
            ),
          ],
        ),
      ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      controller.dispose();
    });
    if (mounted) await _load();
  }

  Future<void> _editPreferences() async {
    final labels = <String, String>{
      'pt': 'Performance Tasks / Laboratory',
      'quiz': 'Quizzes',
      'exam': 'Major Examination',
      ...gradingPeriodLabels,
    };
    final controls = {
      for (final k in labels.keys)
        k: TextEditingController(text: '${_preferences[k] ?? 0}'),
    };
    String? error;
    bool saving = false;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierColor: const Color(0x990D1420),
      builder: (c) => StatefulBuilder(
        builder: (c, setS) {
          Future<void> save() async {
            final values = <String, num>{};
            for (final e in controls.entries) {
              final n = num.tryParse(e.value.text.trim());
              if (n == null ||
                  !n.isFinite ||
                  n < 0 ||
                  n > 100 ||
                  (n * 100 - (n * 100).round()).abs() > 0.000001) {
                setS(
                  () => error =
                      'Use weights from 0–100 with at most two decimal places.',
                );
                return;
              }
              values[e.key] = n;
            }
            for (final keys in [
              const ['pt', 'quiz', 'exam'],
              gradingPeriodLabels.keys.toList(),
            ]) {
              if (keys.fold<int>(
                    0,
                    (sum, k) => sum + (values[k]! * 100).round(),
                  ) !=
                  10000) {
                setS(
                  () => error = 'Category weights and period weights must each total exactly 100%.',
                );
                return;
              }
            }
            setS(() {
              saving = true;
              error = null;
            });
            try {
              await MySubjectsApi.saveGradingPreferences(
                await _token(),
                widget.section.classId,
                values,
              );
              if (c.mounted) Navigator.pop(c);
            } catch (e) {
              if (c.mounted)
                setS(() {
                  saving = false;
                  error = _err(e);
                });
            }
          }

          Widget weightRow(String key) {
            return Container(
              padding: const EdgeInsets.symmetric(vertical: 9),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: Color(0xFFEDF0F5))),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      labels[key]!,
                      style: const TextStyle(
                        fontSize: 14,
                        color: Color(0xFF39465E),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 84,
                    child: Semantics(
                      label: '${labels[key]} weight in percent',
                      child: TextField(
                        controller: controls[key],
                        enabled: !saving,
                        textAlign: TextAlign.right,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        style: const TextStyle(
                          fontSize: 14,
                          color: Color(0xFF182238),
                        ),
                        decoration: InputDecoration(
                          isDense: true,
                          filled: true,
                          fillColor: Colors.white,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(
                              color: Color(0xFFDCE4EF),
                            ),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(
                              color: Color(0xFFDCE4EF),
                            ),
                          ),
                          disabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(
                              color: Color(0xFFDCE4EF),
                            ),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(
                              color: Color(0xFF7E9FD5),
                              width: 1.5,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Text(
                    '%',
                    style: TextStyle(fontSize: 14, color: Color(0xFF60718B)),
                  ),
                ],
              ),
            );
          }

          Widget weightGroup(String title, List<String> keys) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF33435B),
                  ),
                ),
                const SizedBox(height: 2),
                for (final key in keys) weightRow(key),
              ],
            );
          }

          final outlinedStyle = OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFF182238),
            backgroundColor: Colors.white,
            side: const BorderSide(color: Color(0xFFDCE4EF)),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(9),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            minimumSize: const Size(0, 42),
            textStyle: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          );

          return Dialog(
            backgroundColor: Colors.white,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            insetPadding: const EdgeInsets.symmetric(
              horizontal: 20,
              vertical: 24,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: 1000,
                maxHeight: MediaQuery.sizeOf(c).height - 48,
              ),
              child: SizedBox(
                width: 1000,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 24, 24, 18),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  'Grading Preferences',
                                  style: TextStyle(
                                    fontSize: 21,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFF26334B),
                                  ),
                                ),
                                SizedBox(height: 2),
                                Text(
                                  'Configure weights for this subject and section',
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: Color(0xFF7A8AA5),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 16),
                          SizedBox(
                            width: 40,
                            height: 42,
                            child: OutlinedButton(
                              onPressed: saving ? null : () => Navigator.pop(c),
                              style: outlinedStyle.copyWith(
                                padding: const WidgetStatePropertyAll(
                                  EdgeInsets.zero,
                                ),
                              ),
                              child: const Tooltip(
                                message: 'Close',
                                child: Icon(Icons.close, size: 18),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Flexible(
                      fit: FlexFit.loose,
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            LayoutBuilder(
                              builder: (context, constraints) {
                                final category = weightGroup(
                                  'Category weights',
                                  const ['pt', 'quiz', 'exam'],
                                );
                                final periods = weightGroup(
                                  'Grading-period weights',
                                  gradingPeriodLabels.keys.toList(),
                                );
                                if (constraints.maxWidth < 650) {
                                  return Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      category,
                                      const SizedBox(height: 24),
                                      periods,
                                    ],
                                  );
                                }
                                return Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(child: category),
                                    const SizedBox(width: 24),
                                    Expanded(child: periods),
                                  ],
                                );
                              },
                            ),
                            const SizedBox(height: 18),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 14,
                              ),
                              decoration: const BoxDecoration(
                                color: Color(0xFFF3F7FD),
                                border: Border(
                                  left: BorderSide(
                                    color: Color(0xFF8FA3C4),
                                    width: 3,
                                  ),
                                ),
                              ),
                              child: const Text(
                                'Each group must total exactly 100%. Grade calculations update when you save. Preferences are saved for this subject and section.',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Color(0xFF60718B),
                                  height: 1.5,
                                ),
                              ),
                            ),
                            if (error != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 12),
                                child: Text(
                                  error!,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    color: Colors.red,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
                      child: Wrap(
                        alignment: WrapAlignment.end,
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          OutlinedButton(
                            onPressed: saving ? null : () => Navigator.pop(c),
                            style: outlinedStyle,
                            child: const Text('Cancel'),
                          ),
                          FilledButton(
                            onPressed: saving ? null : save,
                            style: FilledButton.styleFrom(
                              foregroundColor: Colors.white,
                              backgroundColor: const Color(0xFF182238),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(9),
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 18,
                                vertical: 14,
                              ),
                              minimumSize: const Size(158, 42),
                              textStyle: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            child: Text(
                              saving ? 'Saving…' : 'Save preferences',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final c in controls.values) {
        c.dispose();
      }
    });
    if (mounted) await _load();
  }

  Future<void> _classifyAssessment(Map<String, dynamic> assessment) async {
    final s = widget.subject;
    final classes = [
      for (final sec in s.sections)
        <String, dynamic>{
          'id': sec.classId,
          'section': sec.name,
          'student_count': sec.students,
          'school_year': s.schoolYear,
          'semester': s.semesterLabel,
          'year_level': s.yearLevel,
          'subject': {'id': s.subjectId, 'code': s.code, 'name': s.name},
        },
    ];
    // Fetch full saved details so header/instructions/assignments are preserved.
    try {
      final full = await ApiService.getExamById(
        await _token(),
        _int(assessment['id'])!,
      );
      if (!mounted) return;
      await showExamDetailsModal(context, classes: classes, exam: full);
      if (mounted) await _load();
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(_err(e))));
    }
  }

  Future<void> _showStudentGrades(Map<String, dynamic> student) async {
    final grading = Map<String, dynamic>.from(student['grading'] as Map? ?? {});
    final byExam = {
      for (final cell in _maps(student['cells'])) cell['exam_id']: cell,
    };
    bool expandedDetails = false;
    const ink = Color(0xFF26334B),
        muted = Color(0xFF7A8AA5),
        line = Color(0xFFDCE4EF),
        pale = Color(0xFFEDF2F8);
    String percent(Object? value, {bool incomplete = false}) => value is num
        ? '${value.toStringAsFixed(2)}%'
        : incomplete
        ? 'INC'
        : '—';
    String weight(String key) =>
        _preferences[key] is num ? _formatScore(_preferences[key] as num) : '—';
    Widget panel(Widget child) => Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: line),
        borderRadius: BorderRadius.circular(13),
      ),
      child: child,
    );
    final outline = OutlinedButton.styleFrom(
      foregroundColor: const Color(0xFF182238),
      backgroundColor: Colors.white,
      side: const BorderSide(color: line),
      minimumSize: const Size(0, 40),
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
      textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
    );
    final filled = FilledButton.styleFrom(
      foregroundColor: Colors.white,
      backgroundColor: const Color(0xFF182238),
      minimumSize: const Size(0, 40),
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
      textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
    );
    Widget tableCell(
      String value, {
      bool header = false,
      bool bold = false,
      bool left = false,
    }) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 13),
      child: Text(
        value,
        textAlign: left ? TextAlign.left : TextAlign.center,
        style: TextStyle(
          fontSize: 12,
          color: header ? const Color(0xFF41516B) : ink,
          fontWeight: header || bold ? FontWeight.w700 : FontWeight.w400,
        ),
      ),
    );
    Widget statCard(String label, String value, {String? tooltip}) {
      final card = Container(
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
          color: const Color(0xFFF4F7FB),
          border: Border.all(color: line),
          borderRadius: BorderRadius.circular(11),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: const TextStyle(fontSize: 12, color: muted)),
            const SizedBox(height: 6),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 21,
                fontWeight: FontWeight.w700,
                color: ink,
              ),
            ),
          ],
        ),
      );
      return tooltip == null ? card : Tooltip(message: tooltip, child: card);
    }

    Widget periodDetails(String? period) {
      final assessments = _allAssessments
          .where((a) => a['grading_period'] == period)
          .toList();
      if (assessments.isEmpty)
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 10),
          child: Text(
            'No assessments in this grading period.',
            style: TextStyle(fontSize: 12, color: muted),
          ),
        );
      return LayoutBuilder(
        builder: (context, box) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: box.maxWidth < 820 ? 820 : box.maxWidth,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(9),
              child: Table(
                border: TableBorder.all(color: line),
                columnWidths: const {
                  0: FlexColumnWidth(2.4),
                  1: FlexColumnWidth(1.5),
                  2: FlexColumnWidth(.7),
                  3: FlexColumnWidth(.7),
                  4: FlexColumnWidth(1),
                  5: FlexColumnWidth(1.5),
                },
                children: [
                  TableRow(
                    decoration: const BoxDecoration(color: pale),
                    children: [
                      for (final title in [
                        'Assessment',
                        'Category',
                        'Score',
                        'Maximum',
                        'Percentage',
                        'Status',
                      ])
                        tableCell(
                          title,
                          header: true,
                          left: title == 'Assessment',
                        ),
                    ],
                  ),
                  for (final assessment in assessments)
                    TableRow(
                      children: [
                        tableCell(
                          '${assessment['column_label']} · ${assessment['title']}',
                          left: true,
                        ),
                        tableCell(
                          _categoryNames[assessment['grading_category']] ??
                              'Needs classification',
                        ),
                        tableCell(
                          byExam[assessment['id']]?['score'] is num
                              ? _formatScore(
                                  byExam[assessment['id']]!['score'] as num,
                                )
                              : '—',
                        ),
                        tableCell(
                          _formatScore(
                            (byExam[assessment['id']]?['max_score'] ??
                                    assessment['total_points'])
                                as num?,
                          ),
                        ),
                        tableCell(
                          _detailAssessmentPercentage(
                            byExam[assessment['id']] ?? const {},
                          ),
                        ),
                        tableCell(
                          '${_reportScoreStatus(byExam[assessment['id']] ?? const {})}${assessment['grade_eligible'] == true ? '' : ' · Draft, excluded'}',
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    await showDialog<void>(
      context: context,
      barrierColor: const Color(0x990D1420),
      builder: (c) => StatefulBuilder(
        builder: (c, setDialog) => Dialog(
          backgroundColor: const Color(0xFFF4F7FB),
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 24,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 1140,
              maxHeight: MediaQuery.sizeOf(c).height - 48,
            ),
            child: SizedBox(
              width: 1140,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    panel(
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          LayoutBuilder(
                            builder: (context, box) {
                              final identity = Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Text(
                                    'Student Grade Information',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: muted,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    _studentName(student),
                                    style: const TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.w700,
                                      color: ink,
                                    ),
                                  ),
                                  const SizedBox(height: 5),
                                  Text(
                                    [
                                      'Student No. ${student['student_number'] ?? ''}',
                                      widget.section.name,
                                      '${widget.subject.code} · ${widget.subject.name}',
                                      widget.subject.fullContextLine,
                                      widget.subject.schoolYear ?? '',
                                    ].where((value) => value.isNotEmpty).join(' · '),
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: muted,
                                      height: 1.5,
                                    ),
                                  ),
                                ],
                              );
                              final actions = Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                alignment: WrapAlignment.end,
                                children: [
                                  OutlinedButton.icon(
                                    onPressed: () => _exportReport(
                                      pdf: true,
                                      student: student,
                                    ),
                                    style: outline,
                                    icon: const Icon(
                                      Icons.file_download_outlined,
                                      size: 16,
                                    ),
                                    label: const Text('PDF'),
                                  ),
                                  FilledButton.icon(
                                    onPressed: () => _exportReport(
                                      pdf: false,
                                      student: student,
                                    ),
                                    style: filled,
                                    icon: const Icon(
                                      Icons.file_download_outlined,
                                      size: 16,
                                    ),
                                    label: const Text('Excel'),
                                  ),
                                  SizedBox(
                                    width: 40,
                                    child: OutlinedButton(
                                      onPressed: () => Navigator.pop(c),
                                      style: outline.copyWith(
                                        padding: const WidgetStatePropertyAll(
                                          EdgeInsets.zero,
                                        ),
                                      ),
                                      child: const Tooltip(
                                        message: 'Close',
                                        child: Icon(Icons.close, size: 18),
                                      ),
                                    ),
                                  ),
                                ],
                              );
                              if (box.maxWidth < 800)
                                return Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Align(
                                      alignment: Alignment.centerRight,
                                      child: actions,
                                    ),
                                    const SizedBox(height: 12),
                                    identity,
                                  ],
                                );
                              return Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(child: identity),
                                  const SizedBox(width: 20),
                                  actions,
                                ],
                              );
                            },
                          ),
                          const SizedBox(height: 18),
                          LayoutBuilder(
                            builder: (context, box) {
                              final cards = [
                                statCard(
                                  'Final Grade',
                                  percent(
                                    grading['final_grade'],
                                    incomplete: true,
                                  ),
                                ),
                                statCard(
                                  'Equivalent',
                                  '—',
                                  tooltip: 'A grade-equivalence scale has not been supplied.',
                                ),
                                statCard(
                                  'Class Rank',
                                  '—',
                                  tooltip: 'Class rank is not supplied by the current gradebook.',
                                ),
                                statCard(
                                  'Status',
                                  '${grading['status'] ?? 'INC'}',
                                ),
                              ];
                              final columns = box.maxWidth >= 700 ? 4 : 2;
                              final width =
                                  (box.maxWidth - (columns - 1) * 10) / columns;
                              return Wrap(
                                spacing: 10,
                                runSpacing: 10,
                                children: [
                                  for (final card in cards)
                                    SizedBox(width: width, child: card),
                                ],
                              );
                            },
                          ),
                          const SizedBox(height: 18),
                          LayoutBuilder(
                            builder: (context, box) => SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: SizedBox(
                                width: box.maxWidth < 850 ? 850 : box.maxWidth,
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(9),
                                  child: Table(
                                    border: TableBorder.all(color: line),
                                    columnWidths: const {
                                      0: FlexColumnWidth(1.2),
                                      1: FlexColumnWidth(1.5),
                                      2: FlexColumnWidth(1),
                                      3: FlexColumnWidth(1.2),
                                      4: FlexColumnWidth(1),
                                      5: FlexColumnWidth(1.5),
                                    },
                                    children: [
                                      TableRow(
                                        decoration: const BoxDecoration(
                                          color: pale,
                                        ),
                                        children: [
                                          for (final title in [
                                            'Grading Period',
                                            'Performance Tasks · ${weight('pt')}%',
                                            'Quizzes · ${weight('quiz')}%',
                                            'Major Exam · ${weight('exam')}%',
                                            'Period Grade',
                                            'Weighted Contribution',
                                          ])
                                            tableCell(
                                              title,
                                              header: true,
                                              left: title == 'Grading Period',
                                            ),
                                        ],
                                      ),
                                      for (final period
                                          in gradingPeriodLabels.entries)
                                        TableRow(
                                          children: [
                                            Padding(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 10,
                                                    vertical: 12,
                                                  ),
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Text(
                                                    period.value,
                                                    style: const TextStyle(
                                                      fontSize: 12,
                                                      fontWeight:
                                                          FontWeight.w700,
                                                      color: ink,
                                                    ),
                                                  ),
                                                  const SizedBox(height: 3),
                                                  Text(
                                                    'Weight ${weight(period.key)}%',
                                                    style: const TextStyle(
                                                      fontSize: 11,
                                                      color: muted,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                            for (final category
                                                in _categoryNames.keys)
                                              tableCell(
                                                percent(
                                                  (grading[period.key]
                                                      as Map?)?['categories']?[category]?['percentage'],
                                                ),
                                              ),
                                            tableCell(
                                              percent(
                                                (grading[period.key]
                                                    as Map?)?['grade'],
                                                incomplete: true,
                                              ),
                                              bold: true,
                                            ),
                                            tableCell(
                                              percent(
                                                (grading[period.key]
                                                    as Map?)?['contribution'],
                                              ),
                                            ),
                                          ],
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'Interim contribution: ${percent(grading['interim_contribution'], incomplete: true)}',
                            style: const TextStyle(fontSize: 12, color: muted),
                          ),
                          if (grading['requires_classification'] == true)
                            const Padding(
                              padding: EdgeInsets.only(top: 8),
                              child: Text(
                                'INC: historical assessments still require teacher classification.',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Color(0xFFB91C1C),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    panel(
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text(
                            'Individual Excel detail preview',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: ink,
                            ),
                          ),
                          const SizedBox(height: 7),
                          const Text(
                            'The workbook includes all four grading periods, every assessment score and maximum, and the grade breakdown.',
                            style: TextStyle(
                              fontSize: 12,
                              color: muted,
                              height: 1.5,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: OutlinedButton(
                              onPressed: () => setDialog(
                                () => expandedDetails = !expandedDetails,
                              ),
                              style: outline,
                              child: Text(
                                expandedDetails
                                    ? 'Hide assessment scores'
                                    : 'View all assessment scores',
                              ),
                            ),
                          ),
                          if (expandedDetails) ...[
                            for (final period
                                in gradingPeriodLabels.entries) ...[
                              Padding(
                                padding: const EdgeInsets.only(
                                  top: 18,
                                  bottom: 8,
                                ),
                                child: Text(
                                  period.value,
                                  style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700,
                                    color: ink,
                                  ),
                                ),
                              ),
                              periodDetails(period.key),
                            ],
                            if (_allAssessments.any(
                              (a) => a['grading_period'] == null,
                            )) ...[
                              const Padding(
                                padding: EdgeInsets.only(top: 18, bottom: 8),
                                child: Text(
                                  'Needs Classification',
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700,
                                    color: ink,
                                  ),
                                ),
                              ),
                              periodDetails(null),
                            ],
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _detailAssessmentPercentage(Map<String, dynamic> cell) {
    final score = cell['score'], maximum = cell['max_score'];
    return cell['status'] == 'completed' &&
            score is num &&
            maximum is num &&
            score.isFinite &&
            maximum.isFinite &&
            maximum > 0
        ? '${(score / maximum * 100).toStringAsFixed(2)}%'
        : '—';
  }

  String _reportScoreStatus(Map<String, dynamic> cell) =>
      switch (cell['status']) {
        'completed' => 'Recorded',
        'needs_review' => 'Needs review',
        'absent' => 'Absent',
        _ => 'Pending',
      };

  Future<void> _showWholeSectionReport() async {
    final book = Map<String, dynamic>.from(_book);
    final students = _maps(book['students']);
    final assessments = _maps(book['assessments']);
    final weights = Map<String, dynamic>.from(
      book['preferences'] as Map? ?? {},
    );
    final cells = {
      for (final student in students)
        student['id']: {
          for (final cell in _maps(student['cells'])) cell['exam_id']: cell,
        },
    };
    final byPeriod = {
      for (final period in gradingPeriodLabels.keys)
        period: assessments
            .where((a) => a['grading_period'] == period)
            .toList(),
    };
    final horizontal = ScrollController();
    const ink = Color(0xFF26334B),
        muted = Color(0xFF7A8AA5),
        grid = Color(0xFF8793A5),
        navy = Color(0xFF182238);
    const studentWidth = 110.0,
        nameWidth = 245.0,
        assessmentWidth = 62.0,
        totalWidth = 68.0,
        gradeWidth = 72.0;
    const periodHeight = 32.0,
        groupHeight = 34.0,
        labelHeight = 46.0,
        rowHeight = 42.0;
    const headerHeight = periodHeight + groupHeight + labelHeight;
    String weight(String key) =>
        weights[key] is num ? _formatScore(weights[key] as num) : '—';
    String percentage(Object? value, {bool incomplete = false}) => value is num
        ? '${value.toStringAsFixed(2)}%'
        : incomplete
        ? 'INC'
        : '—';
    List<Map<String, dynamic>> items(String period, String category) =>
        byPeriod[period]!
            .where((a) => (a['grading_category'] ?? 'unknown') == category)
            .toList();
    List<String> categories(String period) => [
      ..._categoryNames.keys,
      if (byPeriod[period]!.any((a) => a['grading_category'] == null))
        'unknown',
    ];
    double categoryWidth(String period, String category) =>
        items(period, category).length * assessmentWidth +
        (category == 'unknown' ? 0 : totalWidth);
    double periodWidth(String period) =>
        byPeriod[period]!.length * assessmentWidth +
        3 * totalWidth +
        gradeWidth;
    Color categoryColor(String category) => switch (category) {
      'pt' => const Color(0xFFD4E5F8),
      'quiz' => const Color(0xFFD9FFE0),
      'exam' => const Color(0xFFFFF2A5),
      _ => const Color(0xFFEDF2F8),
    };
    Widget cell(
      String text,
      double width,
      double height, {
      Color background = Colors.white,
      bool bold = false,
      bool white = false,
      bool left = false,
      String? tooltip,
    }) {
      final result = Container(
        width: width,
        height: height,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        alignment: left ? Alignment.centerLeft : Alignment.center,
        decoration: BoxDecoration(
          color: background,
          border: const Border(
            right: BorderSide(color: grid),
            bottom: BorderSide(color: grid),
          ),
        ),
        child: Text(
          text,
          textAlign: left ? TextAlign.left : TextAlign.center,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 10,
            fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
            color: white ? Colors.white : ink,
          ),
        ),
      );
      return tooltip == null
          ? result
          : Tooltip(message: tooltip, child: result);
    }

    Widget studentColumns() => SizedBox(
      width: studentWidth + nameWidth,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              cell(
                'Student No.',
                studentWidth,
                headerHeight,
                background: const Color(0xFFD8E4F3),
                bold: true,
              ),
              cell(
                'Student Name',
                nameWidth,
                headerHeight,
                background: const Color(0xFFD8E4F3),
                bold: true,
              ),
            ],
          ),
          for (final student in students)
            Row(
              children: [
                cell(
                  '${student['student_number'] ?? ''}',
                  studentWidth,
                  rowHeight,
                  left: true,
                ),
                cell(
                  _studentName(student),
                  nameWidth,
                  rowHeight,
                  left: true,
                  tooltip: _studentName(student),
                ),
              ],
            ),
        ],
      ),
    );
    Widget periodColumns() => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final period in gradingPeriodLabels.entries)
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  cell(
                    '${period.value.toUpperCase()} · ${weight(period.key)}%',
                    periodWidth(period.key),
                    periodHeight,
                    background: navy,
                    bold: true,
                    white: true,
                  ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final category in categories(period.key))
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            cell(
                              category == 'unknown'
                                  ? 'Needs Classification'
                                  : '${category == 'pt'
                                        ? 'PT / LAB'
                                        : category == 'quiz'
                                        ? 'QUIZZES'
                                        : 'EXAM'} · ${weight(category)}%',
                              categoryWidth(period.key, category),
                              groupHeight,
                              background: categoryColor(category),
                              bold: true,
                            ),
                            Row(
                              children: [
                                for (final assessment in items(
                                  period.key,
                                  category,
                                ))
                                  cell(
                                    '${assessment['column_label']}\n/${_formatScore(assessment['total_points'] as num?)}',
                                    assessmentWidth,
                                    labelHeight,
                                    background: categoryColor(category),
                                    bold: true,
                                    tooltip:
                                        '${assessment['title']}${assessment['grade_eligible'] == true ? '' : ' · Draft, excluded from grade'}',
                                  ),
                                if (category != 'unknown')
                                  cell(
                                    'Total %',
                                    totalWidth,
                                    labelHeight,
                                    background: categoryColor(category),
                                    bold: true,
                                  ),
                              ],
                            ),
                          ],
                        ),
                      cell(
                        'Grade',
                        gradeWidth,
                        groupHeight + labelHeight,
                        background: const Color(0xFFD8E4F3),
                        bold: true,
                      ),
                    ],
                  ),
                ],
              ),
          ],
        ),
        for (final student in students)
          Row(
            children: [
              for (final period in gradingPeriodLabels.keys) ...[
                for (final category in categories(period)) ...[
                  for (final assessment in items(period, category))
                    Builder(
                      builder: (_) {
                        final entry =
                            cells[student['id']]?[assessment['id']] ??
                            <String, dynamic>{};
                        final score = entry['score'];
                        final status = _reportScoreStatus(entry);
                        return cell(
                          score is num ? _formatScore(score) : '—',
                          assessmentWidth,
                          rowHeight,
                          tooltip:
                              '${assessment['title']} · $status · Maximum ${_formatScore((entry['max_score'] ?? assessment['total_points']) as num?)}${assessment['grade_eligible'] == true ? '' : ' · Draft, excluded'}',
                        );
                      },
                    ),
                  if (category != 'unknown')
                    cell(
                      percentage(
                        (student['grading']
                            as Map?)?[period]?['categories']?[category]?['percentage'],
                      ),
                      totalWidth,
                      rowHeight,
                    ),
                ],
                cell(
                  percentage(
                    (student['grading'] as Map?)?[period]?['grade'],
                    incomplete: true,
                  ),
                  gradeWidth,
                  rowHeight,
                  bold: true,
                ),
              ],
            ],
          ),
      ],
    );
    final outline = OutlinedButton.styleFrom(
      foregroundColor: navy,
      backgroundColor: Colors.white,
      side: const BorderSide(color: Color(0xFFDCE4EF)),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
      minimumSize: const Size(0, 40),
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
      textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
    );
    final unknown = assessments
        .where((a) => a['grading_period'] == null)
        .toList();
    try {
      await showDialog<void>(
        context: context,
        barrierColor: const Color(0x990D1420),
        builder: (c) => Dialog(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 24,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 1440,
              maxHeight: MediaQuery.sizeOf(c).height - 48,
            ),
            child: SizedBox(
              width: 1440,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    LayoutBuilder(
                      builder: (context, box) {
                        final identity = Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text(
                              'WHOLE-SECTION GRADE REPORT',
                              style: TextStyle(fontSize: 12, color: muted),
                            ),
                            const SizedBox(height: 7),
                            Text(
                              [
                                widget.subject.code,
                                widget.section.name,
                                widget.subject.schoolYear ?? '',
                              ].where((s) => s.isNotEmpty).join(' · '),
                              style: const TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.w700,
                                color: ink,
                              ),
                            ),
                            const SizedBox(height: 5),
                            Text(
                              [
                                widget.subject.name,
                                widget.subject.semesterLabel,
                                'All four grading periods',
                              ].where((value) => value.isNotEmpty).join(' · '),
                              style: const TextStyle(
                                fontSize: 12,
                                color: muted,
                                height: 1.5,
                              ),
                            ),
                          ],
                        );
                        final actions = Wrap(
                          alignment: WrapAlignment.end,
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            OutlinedButton.icon(
                              onPressed: () => _exportReport(pdf: true),
                              style: outline,
                              icon: const Icon(
                                Icons.file_download_outlined,
                                size: 16,
                              ),
                              label: const Text('PDF'),
                            ),
                            FilledButton.icon(
                              onPressed: () => _exportReport(pdf: false),
                              style: FilledButton.styleFrom(
                                foregroundColor: Colors.white,
                                backgroundColor: navy,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(9),
                                ),
                                minimumSize: const Size(0, 40),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 15,
                                  vertical: 12,
                                ),
                                textStyle: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              icon: const Icon(
                                Icons.file_download_outlined,
                                size: 16,
                              ),
                              label: const Text('Excel'),
                            ),
                            SizedBox(
                              width: 40,
                              child: OutlinedButton(
                                onPressed: () => Navigator.pop(c),
                                style: outline.copyWith(
                                  padding: const WidgetStatePropertyAll(
                                    EdgeInsets.zero,
                                  ),
                                ),
                                child: const Tooltip(
                                  message: 'Close',
                                  child: Icon(Icons.close, size: 18),
                                ),
                              ),
                            ),
                          ],
                        );
                        if (box.maxWidth < 850)
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Align(
                                alignment: Alignment.centerRight,
                                child: actions,
                              ),
                              const SizedBox(height: 12),
                              identity,
                            ],
                          );
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: identity),
                            const SizedBox(width: 20),
                            actions,
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: 22),
                    Container(
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        border: Border.all(color: grid),
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: LayoutBuilder(
                        builder: (context, box) {
                          if (box.maxWidth < 720)
                            return Scrollbar(
                              controller: horizontal,
                              child: SingleChildScrollView(
                                controller: horizontal,
                                scrollDirection: Axis.horizontal,
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [studentColumns(), periodColumns()],
                                ),
                              ),
                            );
                          return Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              studentColumns(),
                              Expanded(
                                child: Scrollbar(
                                  controller: horizontal,
                                  child: SingleChildScrollView(
                                    controller: horizontal,
                                    scrollDirection: Axis.horizontal,
                                    child: periodColumns(),
                                  ),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                    if (students.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 20),
                        child: Text(
                          'No students are enrolled in this section.',
                          style: TextStyle(fontSize: 13, color: muted),
                        ),
                      ),
                    const SizedBox(height: 16),
                    const Text(
                      'All periods and assigned assessments are shown. Missing scores are shown as —; zero is a recorded score. Draft assessments are excluded from grades. Hover a score or column heading for assessment and review details.',
                      style: TextStyle(fontSize: 12, color: muted, height: 1.5),
                    ),
                    if (unknown.isNotEmpty) ...[
                      const SizedBox(height: 18),
                      const Text(
                        'Needs Classification',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: ink,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'These historical assessments have no confirmed grading period. Their saved scores are retained below.',
                        style: TextStyle(fontSize: 12, color: muted),
                      ),
                      const SizedBox(height: 10),
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                cell(
                                  'Student No.',
                                  studentWidth,
                                  50,
                                  background: const Color(0xFFD8E4F3),
                                  bold: true,
                                ),
                                cell(
                                  'Student Name',
                                  nameWidth,
                                  50,
                                  background: const Color(0xFFD8E4F3),
                                  bold: true,
                                ),
                                for (final assessment in unknown)
                                  cell(
                                    '${assessment['title']}\n/${_formatScore(assessment['total_points'] as num?)}',
                                    130,
                                    50,
                                    background: const Color(0xFFEDF2F8),
                                    bold: true,
                                  ),
                              ],
                            ),
                            for (final student in students)
                              Row(
                                children: [
                                  cell(
                                    '${student['student_number'] ?? ''}',
                                    studentWidth,
                                    rowHeight,
                                    left: true,
                                  ),
                                  cell(
                                    _studentName(student),
                                    nameWidth,
                                    rowHeight,
                                    left: true,
                                  ),
                                  for (final assessment in unknown)
                                    cell(
                                      cells[student['id']]?[assessment['id']]?['score']
                                              is num
                                          ? _formatScore(
                                              cells[student['id']]![assessment['id']]!['score']
                                                  as num,
                                            )
                                          : '—',
                                      130,
                                      rowHeight,
                                    ),
                                ],
                              ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    } finally {
      Future<void>.delayed(
        const Duration(milliseconds: 400),
        horizontal.dispose,
      );
    }
  }

  Future<void> _exportReport({
    required bool pdf,
    Map<String, dynamic>? student,
  }) async {
    try {
      // The full unfiltered server book is used, regardless of the selected tab.
      final title = '${widget.subject.code} · ${widget.subject.name}';
      final section =
          '${widget.section.name} · ${widget.subject.fullContextLine}';
      if (pdf) {
        final bytes = await GradeReportService.pdf(
          book: _book,
          title: title,
          section: section,
          student: student,
          fontRegular: (await rootBundle.load(
            'assets/fonts/CheckMateGrades-Regular.ttf',
          )).buffer.asUint8List(),
          fontBold: (await rootBundle.load(
            'assets/fonts/CheckMateGrades-Bold.ttf',
          )).buffer.asUint8List(),
        );
        await Printing.sharePdf(
          bytes: bytes,
          filename: student == null
              ? 'section_grades.pdf'
              : 'student_grades_${student['id']}.pdf',
        );
      } else {
        final bytes = GradeReportService.xlsx(
          book: _book,
          title: title,
          section: section,
          student: student,
        );
        final name = student == null
            ? 'section_grades.xlsx'
            : 'student_grades_${student['id']}.xlsx';
        final file = XFile.fromData(
          bytes,
          mimeType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
          name: name,
        );
        if (kIsWeb) {
          await file.saveTo(name);
        } else if ([
              TargetPlatform.android,
              TargetPlatform.iOS,
            ].contains(defaultTargetPlatform)) {
          await SharePlus.instance.share(
            ShareParams(files: [file], subject: 'CheckMate Grade Report'),
          );
        } else {
          final location = await getSaveLocation(
            suggestedName: name,
            acceptedTypeGroups: [
              const XTypeGroup(label: 'Excel workbook', extensions: ['xlsx']),
            ],
          );
          if (location != null) await file.saveTo(location.path);
        }
      }
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Export failed: ${_err(e)}')));
    }
  }

  List<Widget> _content() {
    if (_students.isEmpty) {
      return const [
        _EmptyBox(
          icon: Icons.people_outline,
          title: 'No students enrolled in this section yet.',
          action: _AddStudentsButton(),
        ),
      ];
    }

    if (_assessments.isEmpty) {
      return const [
        _EmptyBox(
          icon: Icons.assignment_outlined,
          title: 'No assessments in this grading period.',
        ),
      ];
    }

    final rows = _visible;
    final bool isMobileView = MediaQuery.sizeOf(context).width < _kTablet;

    return [
      // Search & Filter Bar
      LayoutBuilder(
        builder: (context, box) {
          final searchWidget = _SearchField(
            controller: _studentSearchC,
            hintText: 'Search student by name or student number...',
            onChanged: (v) => setState(() => _studentQuery = v),
          );

          final filterChips = Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final f in const [
                ('all', 'All'),
                ('completed', 'Completed'),
                ('pending', 'Pending'),
                ('needs_review', 'Needs Review'),
              ])
                ChoiceChip(
                  materialTapTargetSize: MaterialTapTargetSize.padded,
                  label: Text('${f.$2} (${_countFor(f.$1)})'),
                  selected: _filter == f.$1,
                  selectedColor: _navy,
                  backgroundColor: Colors.white,
                  side: const BorderSide(color: _line),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  labelStyle: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: _filter == f.$1 ? Colors.white : _ink,
                  ),
                  checkmarkColor: Colors.white,
                  onSelected: (_) => setState(() => _filter = f.$1),
                ),
            ],
          );

          if (box.maxWidth >= 760) {
            return Row(
              children: [
                Expanded(flex: 5, child: searchWidget),
                const SizedBox(width: 16),
                Expanded(
                  flex: 6,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: filterChips,
                  ),
                ),
              ],
            );
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              searchWidget,
              const SizedBox(height: 12),
              filterChips,
            ],
          );
        },
      ),
      const SizedBox(height: 16),
      if (rows.isEmpty)
        const _EmptyBox(
          icon: Icons.filter_alt_off_outlined,
          title: 'No students match this filter or search.',
        )
      else if (isMobileView)
        _mobileCards(rows)
      else
        _table(rows),
      const SizedBox(height: 12),
      const Text(
        'Blank scores remain Pending; recorded zero is valid. Tap a manual column to enter or edit a score. Draft assessments do not affect grades. Click a student name for grade information.',
        style: TextStyle(fontSize: 12, color: _slate),
      ),
    ];
  }

  // ------------------------------------------------------------
  // MOBILE VIEW: HIGH-CONTRAST STUDENT SCORE CARDS (< 600px)
  // ------------------------------------------------------------

  Widget _mobileCards(List<Map<String, dynamic>> rows) {
    return Column(
      children: [
        for (final s in rows)
          Builder(
            builder: (context) {
              final sid = _int(s['id']) ?? 0;
              final isHighlighted = _activeHighlightStudentId == sid;
              final avg = _studentAveragePercent(s);
              final cells = _cells(s);
              final rowKey =
                  _studentRowKeys.putIfAbsent(sid, () => GlobalKey());

              return AnimatedContainer(
                key: rowKey,
                duration: const Duration(milliseconds: 350),
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: isHighlighted
                      ? _green.withValues(alpha: 0.10)
                      : Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: isHighlighted ? _green : _line,
                    width: isHighlighted ? 2 : 1,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: _navy.withValues(alpha: 0.03),
                      blurRadius: 10,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              InkWell(onTap:()=>_showStudentGrades(s),child:Text(
                                _studentName(s),
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  color: _ink,
                                ),
                              )),
                              const SizedBox(height: 2),
                              Text(
                                '${s['student_number'] ?? ''} • ${widget.section.name}',
                                style: const TextStyle(
                                  fontSize: 12.5,
                                  color: _slate,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: avg != null
                                ? _green.withValues(alpha: 0.14)
                                : _bg,
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                              color: avg != null
                                  ? _green.withValues(alpha: 0.4)
                                  : _line,
                            ),
                          ),
                          child: Text(
                            avg != null
                                ? 'Grade: ${avg.toStringAsFixed(1)}%'
                                : 'Grade: INC',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: avg != null ? _greenDark : _slate,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 10),
                      child: Divider(height: 1, color: _line),
                    ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (var i = 0; i < _assessments.length; i++)
                          _MobileScoreChip(
                            title: '${_assessments[i]['column_label']} · ${_assessments[i]['title']} / ${_formatScore(_assessments[i]['total_points'] as num?)}',
                            cell: cells[i],
                            highlighted: isHighlighted &&
                                (_activeHighlightExamId == null ||
                                    _activeHighlightExamId ==
                                        _int(_assessments[i]['id'])),
                            onTap: () => _onCellTapped(
                              s,
                              cells[i],
                              _assessments[i],
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
      ],
    );
  }

  // ------------------------------------------------------------
  // DESKTOP VIEW: COMPREHENSIVE TABULAR GRADEBOOK (>= 600px)
  // ------------------------------------------------------------

  Widget _table(List<Map<String, dynamic>> rows) {
    const numberWidth = 116.0;
    const nameWidth = 264.0;
    const leftWidth = numberWidth + nameWidth;
    const groupHeight = 38.0;
    const labelHeight = _headH - groupHeight;
    final groups = _scorebookGroups;
    final items = {for (final key in groups) key: _groupAssessments(key)};
    final displayColumns =
        groups.fold<int>(
          0,
          (n, key) =>
              n +
              (items[key]!.isEmpty ? 1 : items[key]!.length) +
              (key == 'unknown' ? 0 : 1),
        ) +
        1;
    final minimumRight =
        groups.fold<double>(
          0,
          (n, key) =>
              n +
              (items[key]!.isEmpty ? 1 : items[key]!.length) * _colW +
              (key == 'unknown' ? 0 : _totalColW),
        ) +
        _avgColW;
    final cellsByStudent = {
      for (final student in rows)
        student['id']: {
          for (final cell in _cells(student)) cell['exam_id']: cell,
        },
    };
    const grid = Color(0xFFE3E9F1);
    Widget cell(
      Widget child,
      double width,
      double height, {
      Color background = Colors.white,
      Alignment alignment = Alignment.center,
    }) => Container(
      width: width,
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      alignment: alignment,
      decoration: BoxDecoration(
        color: background,
        border: const Border(
          right: BorderSide(color: grid),
          bottom: BorderSide(color: grid),
        ),
      ),
      child: child,
    );
    Widget text(
      String value, {
      bool bold = false,
      Color color = const Color(0xFF41516B),
    }) => Text(
      value,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 12,
        fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
        color: color,
      ),
    );
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFDCE4EF)),
        borderRadius: BorderRadius.circular(13),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _scorebookCaption(),
          const Divider(height: 1, thickness: 1, color: grid),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: leftWidth,
                child: Column(
                  children: [
                    Row(
                      children: [
                        cell(
                          text('Student No.', bold: true),
                          numberWidth,
                          _headH,
                          background: const Color(0xFFEDF2F8),
                          alignment: Alignment.centerLeft,
                        ),
                        cell(
                          text('Student Name', bold: true),
                          nameWidth,
                          _headH,
                          background: const Color(0xFFEDF2F8),
                          alignment: Alignment.centerLeft,
                        ),
                      ],
                    ),
                    for (final student in rows)
                      Builder(
                        builder: (context) {
                          final id = _int(student['id']) ?? 0;
                          final highlighted = _activeHighlightStudentId == id;
                          final background = highlighted
                              ? const Color(0xFFE7F7EE)
                              : Colors.white;
                          return AnimatedContainer(
                            key: _studentRowKeys.putIfAbsent(
                              id,
                              () => GlobalKey(),
                            ),
                            duration: const Duration(milliseconds: 350),
                            child: Row(
                              children: [
                                cell(
                                  text('${student['student_number'] ?? ''}'),
                                  numberWidth,
                                  _rowH,
                                  background: background,
                                  alignment: Alignment.centerLeft,
                                ),
                                cell(
                                  Tooltip(
                                    message: _studentName(student),
                                    child: InkWell(
                                      onTap: () => _showStudentGrades(student),
                                      child: Text(
                                        _studentName(student),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w700,
                                          color: Color(0xFF2358A0),
                                          decoration: TextDecoration.underline,
                                          decorationColor: Color(0xFF2358A0),
                                        ),
                                      ),
                                    ),
                                  ),
                                  nameWidth,
                                  _rowH,
                                  background: background,
                                  alignment: Alignment.centerLeft,
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                  ],
                ),
              ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, box) {
                    final extra =
                        (box.maxWidth - minimumRight).clamp(
                          0.0,
                          double.infinity,
                        ) /
                        displayColumns;
                    final scoreWidth = _colW + extra;
                    final totalWidth = _totalColW + extra;
                    final gradeWidth = _avgColW + extra;
                    return Scrollbar(
                      controller: _hScroll,
                      child: SingleChildScrollView(
                        controller: _hScroll,
                        scrollDirection: Axis.horizontal,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                for (final key in groups)
                                  Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Container(
                                        width:
                                            (items[key]!.isEmpty
                                                    ? 1
                                                    : items[key]!.length) *
                                                scoreWidth +
                                            (key == 'unknown' ? 0 : totalWidth),
                                        height: groupHeight,
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 4,
                                        ),
                                        alignment: Alignment.center,
                                        decoration: const BoxDecoration(
                                          color: Color(0xFF182238),
                                          border: Border(
                                            right: BorderSide(
                                              color: Color(0xFF8D98AB),
                                            ),
                                          ),
                                        ),
                                        child: Text(
                                          key == 'unknown'
                                              ? 'Needs Classification'
                                              : '${_categoryNames[key]} · ${_preferences[key]}%',
                                          textAlign: TextAlign.center,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w700,
                                            color: Colors.white,
                                          ),
                                        ),
                                      ),
                                      Row(
                                        children: [
                                          if (items[key]!.isEmpty)
                                            cell(
                                              text('—'),
                                              scoreWidth,
                                              labelHeight,
                                              background:
                                                  _assessmentHeaderColor(key),
                                            ),
                                          for (final assessment in items[key]!)
                                            cell(
                                              Tooltip(
                                                message:
                                                    '${assessment['title']} · ${_typeLabel(assessment['assessment_type']?.toString())}${assessment['grade_eligible'] == true ? '' : ' · Draft, excluded from grade'}',
                                                child: Column(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    text(
                                                      '${assessment['column_label']}',
                                                      bold: true,
                                                    ),
                                                    Text(
                                                      '/${_formatScore(assessment['total_points'] as num?)}',
                                                      style: const TextStyle(
                                                        fontSize: 10,
                                                        color: Color(
                                                          0xFF60718B,
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                              scoreWidth,
                                              labelHeight,
                                              background:
                                                  _assessmentHeaderColor(key),
                                            ),
                                          if (key != 'unknown')
                                            cell(
                                              text('Total %', bold: true),
                                              totalWidth,
                                              labelHeight,
                                              background: const Color(
                                                0xFFEDF2F8,
                                              ),
                                            ),
                                        ],
                                      ),
                                    ],
                                  ),
                                cell(
                                  text('Period Grade', bold: true),
                                  gradeWidth,
                                  _headH,
                                  background: const Color(0xFFEDF2F8),
                                ),
                              ],
                            ),
                            for (final student in rows)
                              Builder(
                                builder: (context) {
                                  final highlighted =
                                      _activeHighlightStudentId ==
                                      _int(student['id']);
                                  final background = highlighted
                                      ? const Color(0xFFE7F7EE)
                                      : Colors.white;
                                  return Row(
                                    children: [
                                      for (final key in groups) ...[
                                        if (items[key]!.isEmpty)
                                          cell(
                                            text('—'),
                                            scoreWidth,
                                            _rowH,
                                            background: background,
                                          ),
                                        for (final assessment in items[key]!)
                                          _ScoreCell(
                                            width: scoreWidth,
                                            height: _rowH,
                                            cell:
                                                cellsByStudent[student['id']]![assessment['id']]!,
                                            highlighted:
                                                highlighted &&
                                                (_activeHighlightExamId ==
                                                        null ||
                                                    _activeHighlightExamId ==
                                                        _int(assessment['id'])),
                                            dimmed:
                                                _filter != 'all' &&
                                                cellsByStudent[student['id']]![assessment['id']]!['status'] !=
                                                    _filter,
                                            onTap: () => _onCellTapped(
                                              student,
                                              cellsByStudent[student['id']]![assessment['id']]!,
                                              assessment,
                                            ),
                                          ),
                                        if (key != 'unknown')
                                          cell(
                                            text(
                                              _categoryPercentage(student, key),
                                            ),
                                            totalWidth,
                                            _rowH,
                                            background: background,
                                          ),
                                      ],
                                      cell(
                                        text(
                                          _percentage(
                                            _periodGrade(student)['grade'],
                                          ),
                                          bold: true,
                                        ),
                                        gradeWidth,
                                        _rowH,
                                        background: background,
                                      ),
                                    ],
                                  );
                                },
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
        ],
      ),
    );
  }
}

class _MobileScoreChip extends StatelessWidget {
  const _MobileScoreChip({
    required this.title,
    required this.cell,
    required this.highlighted,
    required this.onTap,
  });

  final String title;
  final Map<String, dynamic> cell;
  final bool highlighted;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final status = cell['status']?.toString() ?? 'pending';
    final score = cell['score'] is num ? cell['score'] as num : null;
    final max = cell['max_score'] is num ? cell['max_score'] as num : null;

    Color bg;
    Color fg;
    String valueText;

    switch (status) {
      case 'completed':
        valueText = max == null
            ? _formatScore(score)
            : '${_formatScore(score)}/${_formatScore(max)}';
        bg = _green.withValues(alpha: 0.15);
        fg = _greenDark;
      case 'needs_review':
        valueText = 'Needs Review';
        bg = _amber.withValues(alpha: 0.20);
        fg = _amberDark;
      case 'absent':
        valueText = 'Absent';
        bg = _red.withValues(alpha: 0.10);
        fg = _red;
      default:
        valueText = 'Pending';
        bg = _line;
        fg = _slate;
    }

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(10),
          border: highlighted ? Border.all(color: _green, width: 1.5) : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: _ink,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              valueText,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: fg,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScoreCell extends StatelessWidget {
  const _ScoreCell({
    required this.width,
    required this.height,
    required this.cell,
    required this.highlighted,
    required this.dimmed,
    required this.onTap,
  });

  final double width;
  final double height;
  final Map<String, dynamic> cell;
  final bool highlighted;
  final bool dimmed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final status = cell['status']?.toString() ?? 'pending';
    final score = cell['score'] is num ? cell['score'] as num : null;
    final max = cell['max_score'] is num ? cell['max_score'] as num : null;
    final label = switch (status) {
      'completed' => _formatScore(score),
      'needs_review' => 'Review',
      'absent' => 'Absent',
      _ => '',
    };
    final color = switch (status) {
      'needs_review' => _amberDark,
      'absent' => _red,
      _ => const Color(0xFF26334B),
    };
    final tooltip = status == 'completed'
        ? 'Score ${_formatScore(score)} / ${_formatScore(max)} · Click to review'
        : status == 'needs_review'
        ? 'Needs review · Click to review answers'
        : status == 'absent'
        ? 'Absent · Click to manage'
        : 'Missing score · Click to enter a manual score or manage absence';
    return Opacity(
      opacity: dimmed ? 0.4 : 1,
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 350),
            width: width,
            height: height,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: highlighted ? const Color(0xFFE7F7EE) : Colors.white,
              border: const Border(
                right: BorderSide(color: Color(0xFFE3E9F1)),
                bottom: BorderSide(color: Color(0xFFE3E9F1)),
              ),
            ),
            child: Container(
              width: 58,
              height: 34,
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 3),
              decoration: BoxDecoration(
                color: const Color(0xFFFBFCFE),
                border: Border.all(
                  color: highlighted ? _green : const Color(0xFFDCE4EF),
                ),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: color),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
