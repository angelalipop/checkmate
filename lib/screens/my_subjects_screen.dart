import 'package:flutter/material.dart';

import '../services/auth_storage.dart';
import '../services/my_subjects_api_service.dart';
import 'exams_tab.dart';

// =============================================================
// CheckMate — My Subjects (Teacher Portal)
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

const double _kDesktop = 900;
const double _kTablet = 600;

const Color _navy = Color(0xFF162137);
const Color _amber = Color(0xFFF7A224);
const Color _ink = Color(0xFF1E293B);
const Color _slate = Color(0xFF64748B);
const Color _bg = Color(0xFFF8FAFC);
const Color _line = Color(0xFFE2E8F0);
const Color _green = Color(0xFF10B981);
const Color _greenDark = Color(0xFF047857);
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
  'long_quiz': 'Long Quiz',
  'prelim': 'Prelim',
  'midterm': 'Midterm',
  'prefinal': 'Prefinal',
  'final': 'Final',
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
  const _View(this.kind, {this.subject, this.section, this.examId});

  final _Kind kind;
  final _Subject? subject;
  final _Section? section;
  final int? examId;
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
    _load();
  }

  @override
  void dispose() {
    mySubjectsSearch.removeListener(_onSearch);
    _searchC.dispose();
    super.dispose();
  }

  void _onSearch() {
    if (!mounted) return;
    if (_searchC.text != mySubjectsSearch.value) {
      _searchC.text = mySubjectsSearch.value;
    }
    setState(() {});
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

    // The embedded Assessment Builder handles its own back press; every
    // other view steps back through this screen's stack.
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
          key: ValueKey('section-${section.classId}'),
          subject: subject,
          section: section,
          onGoList: _goList,
          onGoSubject: _goSubject,
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
              fontWeight: FontWeight.w500,
              color: _ink,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Your assigned subjects across College and Senior High School.',
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
            const _Centered(child: CircularProgressIndicator())
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
        // Phones: two per row. Wider: as many as fit, up to five.
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
      ('College Department',
          filtered.where((s) => s.department == 'college').toList()),
      ('Senior High School',
          filtered.where((s) => s.department == 'shs').toList()),
      ('Other',
          filtered
              .where((s) => s.department != 'college' && s.department != 'shs')
              .toList()),
    ];

    final out = <Widget>[];
    for (final (title, items) in groups) {
      if (items.isEmpty) continue; // never show an empty group

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
                      fontWeight: FontWeight.w500,
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
        : RefreshIndicator(onRefresh: refresh, child: scroll);
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
            style: OutlinedButton.styleFrom(minimumSize: const Size(88, 44)),
            onPressed: onRetry,
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}

class _EmptyBox extends StatelessWidget {
  const _EmptyBox({required this.icon, required this.title, this.message});

  final IconData icon;
  final String title;
  final String? message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 36),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
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
              fontWeight: FontWeight.w500,
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
        ],
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
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: color,
        ),
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      style: const TextStyle(color: _ink),
      decoration: InputDecoration(
        hintText: 'Search subjects by name or code',
        hintStyle: const TextStyle(color: _slate, fontSize: 14),
        prefixIcon: const Icon(Icons.search, color: _slate),
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: _line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: _line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
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
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: _line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
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

/// 3 columns on desktop, 2 on tablet, 1 on phone.
class _ResponsiveGrid extends StatelessWidget {
  const _ResponsiveGrid({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final screenW = MediaQuery.sizeOf(context).width;
    final cols = screenW >= _kDesktop ? 3 : (screenW >= _kTablet ? 2 : 1);
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

/// White card, thin border, 8px corners, soft shadow on hover.
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
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: _line),
            boxShadow: _hover
                ? [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.08),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                  ]
                : const [],
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: widget.onTap,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 44),
                child: Padding(
                  padding: const EdgeInsets.all(16),
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
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: _navy.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.menu_book_outlined,
                    size: 20, color: _navy),
              ),
              const SizedBox(width: 10),
              if (s.code.isNotEmpty)
                Flexible(
                  child: _Pill(
                    text: s.code,
                    background: _amber.withValues(alpha: 0.18),
                    color: _amberDark,
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
              fontWeight: FontWeight.w500,
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
            style: const TextStyle(fontSize: 13, color: _slate),
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
                  '${s.totalStudents} '
                  '${s.totalStudents == 1 ? 'student' : 'students'}',
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
                fontWeight: FontWeight.w500,
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
    // Nothing is created until the teacher saves the dialog.
    final examId = await showDialog<int>(
      context: context,
      builder: (_) => _NewAssessmentDialog(subject: widget.subject),
    );
    if (examId != null && mounted) widget.onOpenBuilder(examId);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.subject;
    final narrow = MediaQuery.sizeOf(context).width < _kTablet;

    final newButton = narrow
        ? IconButton.filled(
            tooltip: 'New assessment',
            onPressed: _newAssessment,
            style: IconButton.styleFrom(
              backgroundColor: _amber,
              foregroundColor: _navy,
              minimumSize: const Size(44, 44),
            ),
            icon: const Icon(Icons.add),
          )
        : FilledButton.icon(
            onPressed: _newAssessment,
            style: FilledButton.styleFrom(
              backgroundColor: _amber,
              foregroundColor: _navy,
              minimumSize: const Size(0, 44),
              padding: const EdgeInsets.symmetric(horizontal: 18),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            icon: const Icon(Icons.add),
            label: const Text(
              'New assessment',
              style: TextStyle(fontWeight: FontWeight.w500),
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
                    fontWeight: FontWeight.w500,
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
          const Text(
            'Assigned Sections',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w500,
              color: _ink,
            ),
          ),
          const SizedBox(height: 12),
          _ResponsiveGrid(
            children: [
              for (final sec in s.sections)
                _SectionCard(
                  subject: s,
                  section: sec,
                  onTap: () => widget.onOpenSection(sec),
                ),
            ],
          ),
          const SizedBox(height: 32),
          const Text(
            'Assessment Library',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w500,
              color: _ink,
            ),
          ),
          const SizedBox(height: 12),
          if (_loading)
            const _Centered(child: CircularProgressIndicator())
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
                        if (id != null) widget.onOpenBuilder(id);
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
    required this.onTap,
  });

  final _Subject subject;
  final _Section section;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _HoverCard(
      onTap: onTap,
      semanticsLabel: 'Open section ${section.name}',
      builder: (hovered) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            section.name,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w500,
              color: _ink,
            ),
          ),
          if (subject.contextLine.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              subject.contextLine,
              style: const TextStyle(fontSize: 13, color: _slate),
            ),
          ],
          const SizedBox(height: 4),
          Text(
            '${section.students} '
            '${section.students == 1 ? 'student' : 'students'}',
            style: const TextStyle(fontSize: 13, color: _slate),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              const Text(
                'Open section',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
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
    final statusText = published
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
                    fontWeight: FontWeight.w500,
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

// ---------------------------------------------------------------
// New assessment dialog (subject already selected)
// ---------------------------------------------------------------

class _NewAssessmentDialog extends StatefulWidget {
  const _NewAssessmentDialog({required this.subject});

  final _Subject subject;

  @override
  State<_NewAssessmentDialog> createState() => _NewAssessmentDialogState();
}

class _NewAssessmentDialogState extends State<_NewAssessmentDialog> {
  final _titleC = TextEditingController();
  String _type = 'quiz';
  late final Set<int> _selected = widget.subject.classIds.toSet();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _titleC.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final title = _titleC.text.trim();

    if (title.isEmpty) {
      setState(() => _error = 'Assessment title is required.');
      return;
    }
    if (_selected.isEmpty) {
      setState(() => _error = 'Choose at least one section.');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      final token = await _token();
      final created = await MySubjectsApi.createAssessment(
        token,
        classIds: _selected.toList()..sort(),
        title: title,
        assessmentType: _type,
      );
      final id = _int(created['id']);
      if (id == null) throw Exception('The server did not return an id.');
      if (!mounted) return;
      Navigator.pop(context, id);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = _err(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.subject;

    return AlertDialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      title: const Text(
        'New assessment',
        style: TextStyle(fontWeight: FontWeight.w500, color: _ink),
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                [s.code, s.name].where((e) => e.isNotEmpty).join(' · '),
                style: const TextStyle(fontSize: 13, color: _slate),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _titleC,
                enabled: !_saving,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  labelText: 'Title',
                  hintText: 'e.g. Midterm Examination',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _FilterField(
                label: 'Type',
                value: _type,
                options: [
                  for (final e in _typeLabels.entries)
                    MapEntry(e.key, e.value),
                ],
                onChanged: (v) {
                  if (!_saving) setState(() => _type = v);
                },
              ),
              const SizedBox(height: 16),
              const Text(
                'Sections',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: _ink,
                ),
              ),
              const SizedBox(height: 4),
              for (final sec in s.sections)
                InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: _saving
                      ? null
                      : () => setState(() {
                            if (!_selected.remove(sec.classId)) {
                              _selected.add(sec.classId);
                            }
                          }),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 44),
                    child: Row(
                      children: [
                        Checkbox(
                          value: _selected.contains(sec.classId),
                          activeColor: _navy,
                          onChanged: _saving
                              ? null
                              : (v) => setState(() {
                                    if (v == true) {
                                      _selected.add(sec.classId);
                                    } else {
                                      _selected.remove(sec.classId);
                                    }
                                  }),
                        ),
                        Expanded(
                          child: Text(
                            sec.name,
                            style: const TextStyle(color: _ink),
                          ),
                        ),
                        Text(
                          '${sec.students} '
                          '${sec.students == 1 ? 'student' : 'students'}',
                          style:
                              const TextStyle(fontSize: 12, color: _slate),
                        ),
                      ],
                    ),
                  ),
                ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: const TextStyle(fontSize: 13, color: _red),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          style: TextButton.styleFrom(minimumSize: const Size(88, 44)),
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: _amber,
            foregroundColor: _navy,
            minimumSize: const Size(88, 44),
          ),
          onPressed: _saving ? null : _create,
          child: _saving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Create'),
        ),
      ],
    );
  }
}

// =============================================================
// SECTION SCOREBOOK
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
  });

  final _Subject subject;
  final _Section section;
  final VoidCallback onGoList;
  final VoidCallback onGoSubject;

  @override
  State<_SectionPage> createState() => _SectionPageState();
}

class _SectionPageState extends State<_SectionPage> {
  static const double _colW = 132;
  static const double _rowH = 56;
  static const double _headH = 76;

  List<Map<String, dynamic>> _assessments = const [];
  List<Map<String, dynamic>> _students = const [];
  bool _loading = true;
  String? _error;
  String _filter = 'all';

  final ScrollController _hScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _hScroll.dispose();
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
        s['cells'] = _maps(s['cells']); // mutable copies
      }

      if (!mounted) return;
      setState(() {
        _assessments = _maps(data['assessments']);
        _students = students;
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

  List<Map<String, dynamic>> _cells(Map<String, dynamic> s) =>
      (s['cells'] as List).cast<Map<String, dynamic>>();

  int _countFor(String f) => f == 'all'
      ? _students.length
      : _students.where((s) => _cells(s).any((c) => c['status'] == f)).length;

  List<Map<String, dynamic>> get _visible => _filter == 'all'
      ? _students
      : _students
          .where((s) => _cells(s).any((c) => c['status'] == _filter))
          .toList();

  String _studentName(Map<String, dynamic> s) =>
      '${s['last_name'] ?? ''}, ${s['first_name'] ?? ''}'.trim();

  Future<void> _toggleAbsent(
    Map<String, dynamic> student,
    Map<String, dynamic> cell,
    String examTitle,
  ) async {
    final status = cell['status'];
    if (status != 'pending' && status != 'absent') return;

    final marking = status == 'pending';
    final name = _studentName(student);

    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: Colors.white,
        title: Text(
          marking ? 'Mark as absent?' : 'Remove absent mark?',
          style: const TextStyle(fontWeight: FontWeight.w500, color: _ink),
        ),
        content: Text(
          marking
              ? '$name will be recorded as absent for "$examTitle". '
                  'Only do this once you have confirmed they did not take it.'
              : '$name will go back to Pending for "$examTitle".',
        ),
        actions: [
          TextButton(
            style: TextButton.styleFrom(minimumSize: const Size(88, 44)),
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: _amber,
              foregroundColor: _navy,
              minimumSize: const Size(88, 44),
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

  @override
  Widget build(BuildContext context) {
    final s = widget.subject;
    final sec = widget.section;

    return _PageScroll(
      onRefresh: _load,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Breadcrumb(
            items: [
              _Crumb('My Subjects', widget.onGoList),
              _Crumb(s.crumb, widget.onGoSubject),
              _Crumb(sec.name),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '${s.name} – ${sec.name}',
            style: const TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w500,
              color: _ink,
            ),
          ),
          if (s.fullContextLine.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              s.fullContextLine,
              style: const TextStyle(fontSize: 14, color: _slate),
            ),
          ],
          const SizedBox(height: 20),
          if (_loading)
            const _Centered(child: CircularProgressIndicator())
          else if (_error != null)
            _ErrorBox(message: _error!, onRetry: _load)
          else
            ..._content(),
        ],
      ),
    );
  }

  List<Widget> _content() {
    if (_students.isEmpty) {
      return const [
        _EmptyBox(
          icon: Icons.people_outline,
          title: 'No students enrolled in this section yet.',
        ),
      ];
    }

    if (_assessments.isEmpty) {
      return const [
        _EmptyBox(
          icon: Icons.assignment_outlined,
          title: 'No assessments assigned to this section yet.',
        ),
      ];
    }

    final rows = _visible;

    return [
      Wrap(
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
              labelStyle: TextStyle(
                fontSize: 13,
                color: _filter == f.$1 ? Colors.white : _ink,
              ),
              checkmarkColor: Colors.white,
              onSelected: (_) => setState(() => _filter = f.$1),
            ),
        ],
      ),
      const SizedBox(height: 16),
      if (rows.isEmpty)
        const _EmptyBox(
          icon: Icons.filter_alt_off_outlined,
          title: 'No students match this filter.',
        )
      else
        _table(rows),
      const SizedBox(height: 12),
      const Text(
        'Students without a finalized scan stay Pending. Tap a Pending cell '
        'only to confirm that the student was absent.',
        style: TextStyle(fontSize: 12, color: _slate),
      ),
    ];
  }

  Widget _table(List<Map<String, dynamic>> rows) {
    final narrow = MediaQuery.sizeOf(context).width < _kTablet;
    final leftW = narrow ? 128.0 : 200.0;

    Widget head(Widget child, double w) => Container(
          width: w,
          height: _headH,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          alignment: Alignment.centerLeft,
          decoration: const BoxDecoration(
            color: _bg,
            border: Border(bottom: BorderSide(color: _line)),
          ),
          child: child,
        );

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _line),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Fixed student column.
          Container(
            width: leftW,
            decoration: const BoxDecoration(
              border: Border(right: BorderSide(color: _line)),
            ),
            child: Column(
              children: [
                head(
                  const Text(
                    'Student',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: _ink,
                    ),
                  ),
                  leftW - 1,
                ),
                for (final s in rows)
                  Container(
                    height: _rowH,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    alignment: Alignment.centerLeft,
                    decoration: const BoxDecoration(
                      border: Border(bottom: BorderSide(color: _line)),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _studentName(s),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: _ink,
                          ),
                        ),
                        Text(
                          s['student_number']?.toString() ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11, color: _slate),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          // Assessment columns scroll sideways inside the table only.
          Expanded(
            child: Scrollbar(
              controller: _hScroll,
              child: SingleChildScrollView(
                controller: _hScroll,
                scrollDirection: Axis.horizontal,
                child: Column(
                  children: [
                    Row(
                      children: [
                        for (final a in _assessments)
                          head(
                            Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  a['title']?.toString() ?? '',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                    color: _ink,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '${_typeLabel(a['assessment_type']?.toString())}'
                                  ' · v${_int(a['version']) ?? 1}',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: _slate,
                                  ),
                                ),
                              ],
                            ),
                            _colW,
                          ),
                      ],
                    ),
                    for (final s in rows)
                      Row(
                        children: [
                          for (var i = 0; i < _assessments.length; i++)
                            _ScoreCell(
                              width: _colW,
                              height: _rowH,
                              cell: _cells(s)[i],
                              dimmed: _filter != 'all' &&
                                  _cells(s)[i]['status'] != _filter,
                              onTap: () => _toggleAbsent(
                                s,
                                _cells(s)[i],
                                _assessments[i]['title']?.toString() ?? '',
                              ),
                            ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ScoreCell extends StatelessWidget {
  const _ScoreCell({
    required this.width,
    required this.height,
    required this.cell,
    required this.dimmed,
    required this.onTap,
  });

  final double width;
  final double height;
  final Map<String, dynamic> cell;
  final bool dimmed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final status = cell['status']?.toString() ?? 'pending';

    final String text;
    final Color bg;
    final Color fg;

    switch (status) {
      case 'completed':
        final score = cell['score'] is num ? cell['score'] as num : null;
        final max = cell['max_score'] is num ? cell['max_score'] as num : null;
        text = max == null
            ? _formatScore(score)
            : '${_formatScore(score)} / ${_formatScore(max)}';
        bg = _green.withValues(alpha: 0.15);
        fg = _greenDark;
      case 'needs_review':
        text = 'Needs Review';
        bg = _amber.withValues(alpha: 0.2);
        fg = _amberDark;
      case 'absent':
        text = 'Absent';
        bg = _red.withValues(alpha: 0.1);
        fg = _red;
      default:
        text = 'Pending';
        bg = _line;
        fg = _slate;
    }

    final tappable = status == 'pending' || status == 'absent';

    return Opacity(
      opacity: dimmed ? 0.4 : 1,
      child: InkWell(
        onTap: tappable ? onTap : null,
        child: Container(
          width: width,
          height: height,
          alignment: Alignment.center,
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: _line)),
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: fg,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
