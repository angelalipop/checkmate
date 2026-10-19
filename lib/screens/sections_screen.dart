import 'package:flutter/material.dart';

import '../services/academic_api_service.dart';
import '../services/auth_storage.dart';
import '../services/section_api_service.dart';
import 'login_screen.dart' show CmColors;

// =============================================================
// Sections — catalog of sections per program / strand.
// Programs and SHS strands come from Academic Management
// (AcademicApi.programs). Styling follows that screen: plain AppBar,
// CmColors palette, 12px rounded fields, navy primary button.
// =============================================================

const Color _activeGreen = Color(0xFF2F8F72);
const Color _dangerRed = Color(0xFFDC2626);

/// Tile / badge colours, picked from the program code.
const List<Color> _palette = [
  Color(0xFF6A499B), // purple
  Color(0xFF2F8F72), // green
  Color(0xFF2F63B8), // blue
  Color(0xFFB26A00), // amber
  Color(0xFFB0305F), // rose
];

typedef _M = Map<String, dynamic>;

String _s(Object? v) => v?.toString().trim() ?? '';
int _i(Object? v) => int.tryParse(v?.toString() ?? '') ?? 0;
bool _isShs(_M? p) => p != null && p['level'] == 'shs';

String _yearLabel(bool shs, int y) => shs ? 'Grade ${10 + y}' : 'Year $y';
String _semLabel(int t) => t == 1 ? '1st Semester' : '2nd Semester';

String _currentSchoolYear() {
  final now = DateTime.now();
  final start = now.month >= 6 ? now.year : now.year - 1;
  return '$start-${start + 1}';
}

/// Aug–Dec = 1st semester, otherwise 2nd.
int _currentSemester() => DateTime.now().month >= 8 ? 1 : 2;

Color _colorFor(String code) =>
    _palette[code.codeUnits.fold<int>(0, (a, b) => a + b) % _palette.length];

/// College: BSIT + year + semester + letter -> BSIT11D
/// SHS:     ABM  + grade + "-" + letter     -> ABM11-A
String _suggestName({
  required _M program,
  required int year,
  required int semester,
  required Iterable<String> taken,
}) {
  final code = _s(program['code']).toUpperCase();
  final prefix = _isShs(program)
      ? '$code${10 + year}-'
      : '$code$year$semester';
  final used = taken.map((e) => e.toUpperCase()).toSet();
  for (var i = 0; i < 26; i++) {
    final name = '$prefix${String.fromCharCode(65 + i)}';
    if (!used.contains(name)) return name;
  }
  return '${prefix}A';
}

// ---------- shared styling (same as Academic Management) ----------

InputDecoration _fieldDecoration({String? hint}) {
  OutlineInputBorder border(Color c, [double w = 1]) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: c, width: w),
      );
  return InputDecoration(
    isDense: true,
    filled: true,
    fillColor: Colors.white,
    hintText: hint,
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    border: border(CmColors.line),
    enabledBorder: border(CmColors.line),
    focusedBorder: border(CmColors.navy, 1.5),
  );
}

Widget _labeled(String label, Widget field) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
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

// =============================================================
// SCREEN
// =============================================================
Widget _groupedFilter({
    required BuildContext context,
    required String? value,
    required String hint,
    required Map<String, List<String>> groups,
    required ValueChanged<String?> onChanged,
    double width = 210,
    bool includeAll = true,
    bool enabled = true,
    bool showGroupHeadings = true,
  }) {
    const hoverColor = Color(0xFFF0EFF5);
    const selectedColor = Color(0xFFDDDBE1);

    Widget option(String? item, String label) {
      final selected = value == item;

      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: MenuItemButton(
          onPressed: enabled ? () => onChanged(item) : null,
          trailingIcon:
              selected ? const Icon(Icons.check, size: 20) : null,
          style: ButtonStyle(
            minimumSize: const WidgetStatePropertyAll(Size(0, 46)),
            padding: const WidgetStatePropertyAll(
              EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            ),
            foregroundColor:
                const WidgetStatePropertyAll(CmColors.navy),
            iconColor:
                const WidgetStatePropertyAll(CmColors.navy),
            overlayColor:
                const WidgetStatePropertyAll(Colors.transparent),
            shape: WidgetStatePropertyAll(
              RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            backgroundColor: WidgetStateProperty.resolveWith<Color>(
              (states) {
                if (selected) return selectedColor;

                if (states.contains(WidgetState.hovered) ||
                    states.contains(WidgetState.focused) ||
                    states.contains(WidgetState.pressed)) {
                  return hoverColor;
                }

                return Colors.transparent;
              },
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 14,
              fontWeight:
                  selected ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
      );
    }

    final visibleGroups = groups.entries
        .where((group) => group.value.isNotEmpty)
        .toList();

    final menuWidth = (MediaQuery.sizeOf(context).width - 32)
        .clamp(0.0, 340.0)
        .toDouble();

    return SizedBox(
      width: width,
      child: MenuAnchor(
        style: MenuStyle(
          backgroundColor:
              const WidgetStatePropertyAll(Colors.white),
          surfaceTintColor:
              const WidgetStatePropertyAll(Colors.transparent),
          elevation: const WidgetStatePropertyAll(3),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(vertical: 6),
          ),
          minimumSize: WidgetStatePropertyAll(Size(menuWidth, 0)),
          maximumSize: WidgetStatePropertyAll(
            Size(menuWidth, MediaQuery.sizeOf(context).height * 0.55),
          ),
          side: const WidgetStatePropertyAll(
            BorderSide(color: CmColors.line),
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        menuChildren: [
          if (includeAll) option(null, hint),
          for (var i = 0; i < visibleGroups.length; i++) ...[
            if (i > 0)
              const Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                child: Divider(height: 1, color: CmColors.line),
              ),
          if (showGroupHeadings)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Text(
                visibleGroups[i].key,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: CmColors.slate,
                ),
              ),
            ),
            for (final item in visibleGroups[i].value)
              option(item, item),
          ],
        ],
        builder: (context, controller, child) {
          return Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              hoverColor: hoverColor,
              focusColor: hoverColor,
              onTap: () {
                if (!enabled) return;
                if (controller.isOpen) {
                  controller.close();
                } else {
                  controller.open();
                }
              },
              child: InputDecorator(
                decoration: _fieldDecoration(),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        value ?? hint,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          color: CmColors.navy,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      controller.isOpen
                          ? Icons.keyboard_arrow_up
                          : Icons.keyboard_arrow_down,
                      size: 20,
                      color: CmColors.slate,
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }


class SectionsScreen extends StatefulWidget {
  const SectionsScreen({super.key});

  @override
  State<SectionsScreen> createState() => _SectionsScreenState();
}

class _SectionsScreenState extends State<SectionsScreen> {
  List<_M> _sections = [];
  List<_M> _programs = [];
  bool _loading = true;
  String? _error;

  final _search = TextEditingController();
  String? _fProgram; // program code
  String? _fYear; // label, e.g. "1ˢᵗ Year" / "Grade 11"
  String? _fSchoolYear = _currentSchoolYear();
  int? _fSemester = _currentSemester();

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<String> _token() async {
    final token = await AuthStorage.getToken();
    if (token == null || token.isEmpty) {
      throw Exception('Authentication token not found.');
    }
    return token;
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final token = await _token();
      final r = await Future.wait([
        SectionApi.getSections(token),
        AcademicApi.programs(token),
      ]);
      if (!mounted) return;
      setState(() {
        _sections = r[0];
        _programs = r[1];
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _loading = false;
      });
    }
  }

  // ---------- derived ----------

  String _yearOf(_M s) => _yearLabel(s['program_level'] == 'shs', _i(s['year_level']));

  List<_M> get _filtered {
    final q = _search.text.trim().toLowerCase();
    return _sections.where((s) {
      if (q.isNotEmpty &&
          !_s(s['name']).toLowerCase().contains(q) &&
          !_s(s['program_code']).toLowerCase().contains(q)) {
        return false;
      }
      if (_fProgram != null && _s(s['program_code']) != _fProgram) return false;
      if (_fYear != null && _yearOf(s) != _fYear) return false;
      if (_fSchoolYear != null && _s(s['school_year']) != _fSchoolYear) {
        return false;
      }
      if (_fSemester != null && _i(s['semester']) != _fSemester) return false;
      return true;
    }).toList();
  }

  List<String> get _schoolYears {
    final cur = int.parse(_currentSchoolYear().substring(0, 4));
    final set = <String>{
      for (var y = cur - 1; y <= cur + 1; y++) '$y-${y + 1}',
      ..._sections.map((s) => _s(s['school_year'])).where((e) => e.isNotEmpty),
    };
    return set.toList()..sort();
  }

  void _reset() => setState(() {
        _search.clear();
        _fProgram = null;
        _fYear = null;
        _fSchoolYear = null;
        _fSemester = null;
      });

  // ---------- add section ----------

  Future<void> _addSection() async {
    if (_programs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(
            'No programs or strands yet. Add them in Academic Management first.'),
      ));
      return;
    }

    final added = await showGeneralDialog<bool>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close',
      barrierColor: Colors.black38,
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (ctx, _, _) {
        final width = MediaQuery.of(ctx).size.width;
        return Align(
          alignment: Alignment.centerRight,
          child: Material(
            color: CmColors.bg,
            child: SizedBox(
              width: width < 500 ? width : 460,
              height: double.infinity,
              child: SafeArea(
                child: _AddSectionPanel(
                  programs: _programs,
                  existing: _sections,
                  schoolYears: _schoolYears,
                  initialSchoolYear: _fSchoolYear ?? _currentSchoolYear(),
                  initialSemester: _fSemester ?? _currentSemester(),
                  getToken: _token,
                ),
              ),
            ),
          ),
        );
      },
      transitionBuilder: (ctx, anim, _, child) => SlideTransition(
        position: Tween(begin: const Offset(1, 0), end: Offset.zero).animate(
          CurvedAnimation(parent: anim, curve: Curves.easeOutCubic),
        ),
        child: child,
      ),
    );

    if (added == true) {
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Section added.')));
    }
  }

  // ---------- build ----------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sections')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: LayoutBuilder(
          builder: (context, c) {
            final pad = c.maxWidth < 600 ? 16.0 : 32.0;
            return SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.fromLTRB(pad, 24, pad, 40),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1320),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _pageHeader(c.maxWidth < 600),
                      const SizedBox(height: 24),
                      _filters(),
                      const SizedBox(height: 20),
                      _catalog(c.maxWidth < 700),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _pageHeader(bool narrow) {
    final titleBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        const Text(
          'Section catalog',
          style: TextStyle(
            fontSize: 30,
            fontWeight: FontWeight.w800,
            color: CmColors.navy,
            height: 1.1,
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const Icon(Icons.calendar_today_outlined,
                size: 15, color: CmColors.slate),
            Text('School year ${_fSchoolYear ?? _currentSchoolYear()}',
                style: const TextStyle(color: CmColors.slate, fontSize: 14)),
            const Text('/', style: TextStyle(color: CmColors.line)),
            const Text('College & Senior High School',
                style: TextStyle(color: CmColors.slate, fontSize: 14)),
          ],
        ),
      ],
    );

    final button = FilledButton.icon(
      style: _primaryButtonStyle,
      onPressed: _loading ? null : _addSection,
      icon: const Icon(Icons.add, size: 20),
      label: const Text('Add section'),
    );

    if (narrow) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          titleBlock,
          const SizedBox(height: 16),
          SizedBox(width: double.infinity, child: button),
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [Expanded(child: titleBlock), const SizedBox(width: 16), button],
    );
  }

  Widget _filters() {
    final shsCodes = _programs
        .where((p) => _isShs(p))
        .map((p) => _s(p['code']))
        .where((code) => code.isNotEmpty)
        .toSet()
        .toList()
      ..sort();

    final collegeCodes = _programs
        .where((p) => !_isShs(p))
        .map((p) => _s(p['code']))
        .where((code) => code.isNotEmpty)
        .toSet()
        .toList()
      ..sort();

    Widget dropdown<T>({
      required T? value,
      required String hint,
      required List<T> items,
      required String Function(T) label,
      required ValueChanged<T?> onChanged,
    }) {
      return SizedBox(
        width: 210,
        child: DropdownButtonFormField<T>(
          key: ValueKey('$hint-$value'),
          initialValue: items.contains(value) ? value : null,
          isExpanded: true,
          icon: const Icon(Icons.keyboard_arrow_down, size: 20),
          decoration: _fieldDecoration(),
          items: [
            DropdownMenuItem<T>(value: null, child: Text(hint)),
            ...items.map(
              (e) => DropdownMenuItem<T>(value: e, child: Text(label(e))),
            ),
          ],
          onChanged: onChanged,
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: const [
            Icon(Icons.tune, size: 18, color: CmColors.navy),
            SizedBox(width: 8),
            Text(
              'Filter catalog',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: CmColors.navy,
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 14,
          runSpacing: 14,
          crossAxisAlignment: WrapCrossAlignment.end,
          children: [
            _labeled(
              'Search sections',
              SizedBox(
                width: 300,
                child: TextField(
                  controller: _search,
                  decoration: _fieldDecoration(hint: 'Section or program...')
                      .copyWith(prefixIcon: const Icon(Icons.search, size: 20)),
                ),
              ),
            ),
            _labeled(
              'Program / Strand',
              _groupedFilter(
                context: context,
                value: _fProgram,
                hint: 'All programs / strands',
                groups: {
                  'SHS · Senior High School': shsCodes,
                  'College · Undergraduate programs': collegeCodes,
                },
                onChanged: (value) =>
                    setState(() => _fProgram = value),
              ),
            ),
            _labeled(
              'Year level',
              _groupedFilter(
                context: context,
                value: _fYear,
                hint: 'All year levels',
                groups: const {
                  'SHS · Senior High School': [
                    'Grade 11',
                    'Grade 12',
                  ],
                  'College · Undergraduate programs': [
                    '1ˢᵗ Year',
                    '2ⁿᵈ Year',
                    '3ʳᵈ Year',
                    '4ᵗʰ Year',
                  ],
                },
                onChanged: (value) =>
                    setState(() => _fYear = value),
              ),
            ),
            _labeled(
              'School year',
              dropdown<String>(
                value: _fSchoolYear,
                hint: 'All school years',
                items: _schoolYears,
                label: (e) => e,
                onChanged: (v) => setState(() => _fSchoolYear = v),
              ),
            ),
            _labeled(
              'Semester',
              dropdown<int>(
                value: _fSemester,
                hint: 'All semesters',
                items: const [1, 2],
                label: _semLabel,
                onChanged: (v) => setState(() => _fSemester = v),
              ),
            ),
            TextButton.icon(
              onPressed: _reset,
              icon: const Icon(Icons.close, size: 18),
              label: const Text('Reset'),
              style: TextButton.styleFrom(
                foregroundColor: CmColors.slate,
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _catalog(bool compact) {
    final rows = _filtered;

    return Container(
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
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
            child: Row(
              children: [
                const Text(
                  'All sections',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: CmColors.navy,
                  ),
                ),
                const SizedBox(width: 10),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: CmColors.bg,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '${rows.length}',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: CmColors.slate,
                    ),
                  ),
                ),
                const Spacer(),
                if (_fSemester != null && !compact) ...[
                  const Icon(Icons.circle, size: 6, color: _activeGreen),
                  const SizedBox(width: 6),
                  Text(
                    _fSemester == _currentSemester()
                        ? '${_semLabel(_fSemester!)} · Active'
                        : _semLabel(_fSemester!),
                    style: const TextStyle(
                        fontSize: 12, color: CmColors.slate),
                  ),
                ],
              ],
            ),
          ),
          const Divider(height: 1, color: CmColors.line),
          if (!compact) ...[_tableHeader(), const Divider(height: 1, color: CmColors.line)],
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(48),
              child: CircularProgressIndicator(),
            )
          else if (_error != null)
            _message(Icons.error_outline, _error!, retry: true)
          else if (rows.isEmpty)
            _message(
              Icons.layers_outlined,
              _sections.isEmpty
                  ? 'No sections yet. Click "Add section" to create one.'
                  : 'No sections match your filters.',
            )
          else
            for (var i = 0; i < rows.length; i++)
              compact ? _cardRow(rows[i]) : _row(rows[i], i.isOdd),
        ],
      ),
    );
  }

  Widget _message(IconData icon, String text, {bool retry = false}) {
    return Padding(
      padding: const EdgeInsets.all(48),
      child: Column(
        children: [
          Icon(icon, size: 44, color: CmColors.slate),
          const SizedBox(height: 12),
          Text(text, textAlign: TextAlign.center),
          if (retry) ...[
            const SizedBox(height: 14),
            FilledButton(
              style: _primaryButtonStyle,
              onPressed: _load,
              child: const Text('Retry'),
            ),
          ],
        ],
      ),
    );
  }

  static const _flex = [3, 3, 2, 2, 2];

  Widget _tableHeader() {
    const style = TextStyle(
      fontSize: 12.5,
      fontWeight: FontWeight.w600,
      color: CmColors.slate,
    );
    const labels = [
      'Section', 'Program / Strand', 'Year level', 'School year', 'Semester',
    ];
    return Container(
      color: const Color(0xFFF8FAFC),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i++)
            Expanded(flex: _flex[i], child: Text(labels[i], style: style)),
        ],
      ),
    );
  }

  Widget _tile(String code) => Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: _colorFor(code).withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(Icons.layers_outlined, size: 19, color: _colorFor(code)),
      );

  Widget _badge(String code) {
    final color = _colorFor(code);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        code,
        style: TextStyle(
            fontSize: 12, fontWeight: FontWeight.w700, color: color),
      ),
    );
  }

  Widget _row(_M s, bool alt) {
    final code = _s(s['program_code']);
    const cell = TextStyle(fontSize: 14, color: CmColors.slate);
    return Container(
      color: alt ? const Color(0xFFFAFBFD) : Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Row(
        children: [
          Expanded(
            flex: _flex[0],
            child: Row(
              children: [
                _tile(code),
                const SizedBox(width: 14),
                Flexible(
                  child: Text(
                    _s(s['name']),
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                      color: CmColors.navy,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            flex: _flex[1],
            child: Align(alignment: Alignment.centerLeft, child: _badge(code)),
          ),
          Expanded(
            flex: _flex[2],
            child: Text(_yearOf(s),
                style: cell.copyWith(color: CmColors.navy)),
          ),
          Expanded(flex: _flex[3], child: Text(_s(s['school_year']), style: cell)),
          Expanded(
            flex: _flex[4],
            child: Text(_semLabel(_i(s['semester'])), style: cell),
          ),
        ],
      ),
    );
  }

  /// Phone layout: one stacked row per section.
  Widget _cardRow(_M s) {
    final code = _s(s['program_code']);
    return Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: CmColors.line)),
      ),
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          _tile(code),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _s(s['name']),
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: CmColors.navy,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${_yearOf(s)} · ${_s(s['school_year'])} · ${_semLabel(_i(s['semester']))}',
                  style: const TextStyle(fontSize: 13, color: CmColors.slate),
                ),
              ],
            ),
          ),
          _badge(code),
        ],
      ),
    );
  }
}

// =============================================================
// ADD SECTION PANEL (right-hand drawer)
// =============================================================

class _AddSectionPanel extends StatefulWidget {
  const _AddSectionPanel({
    required this.programs,
    required this.existing,
    required this.schoolYears,
    required this.initialSchoolYear,
    required this.initialSemester,
    required this.getToken,
  });

  final List<_M> programs;
  final List<_M> existing;
  final List<String> schoolYears;
  final String initialSchoolYear;
  final int initialSemester;
  final Future<String> Function() getToken;

  @override
  State<_AddSectionPanel> createState() => _AddSectionPanelState();
}

class _AddSectionPanelState extends State<_AddSectionPanel> {
  late String _schoolYear =
      widget.schoolYears.contains(widget.initialSchoolYear)
          ? widget.initialSchoolYear
          : widget.schoolYears.first;
  late _M _program = _ordered.first;
  int _year = 1;
  late int _semester = widget.initialSemester;

  bool _saving = false;
  String? _error;

  /// College programs first, then SHS strands.
  late final List<_M> _ordered = [
    ...widget.programs.where((p) => !_isShs(p)),
    ...widget.programs.where(_isShs),
  ];

  int get _maxYear => _isShs(_program) ? 2 : 4;

  String get _name => _suggestName(
        program: _program,
        year: _year,
        semester: _semester,
        taken: widget.existing
            .where((s) =>
                _s(s['school_year']) == _schoolYear &&
                _i(s['semester']) == _semester)
            .map((s) => _s(s['name'])),
      );

    String _addYearLabel(int year) {
    if (_isShs(_program)) return 'Grade ${10 + year}';

    const labels = [
      '1ˢᵗ Year',
      '2ⁿᵈ Year',
      '3ʳᵈ Year',
      '4ᵗʰ Year',
    ];

    return labels[year - 1];
  }

  Future<void> _save() async {
    final match = RegExp(r'^(\d{4})-(\d{4})$')
        .firstMatch(_schoolYear);

    if (match == null ||
        int.parse(match.group(2)!) !=
            int.parse(match.group(1)!) + 1) {
      setState(() {
        _error =
            'Enter consecutive school years, for example 2027-2028.';
      });
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final token = await widget.getToken();
      await SectionApi.createSection(
        token,
        programId: _i(_program['id']),
        name: _name,
        yearLevel: _year,
        schoolYear: _schoolYear,
        semester: _semester,
      );
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Widget _field<T>({
    required String label,
    required T value,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: _labeled(
        label,
        DropdownButtonFormField<T>(
          key: ValueKey('$label-$value-$_schoolYear-$_semester'),
          initialValue: value,
          isExpanded: true,
          icon: const Icon(Icons.keyboard_arrow_down, size: 20),
          decoration: _fieldDecoration(),
          items: items,
          onChanged: _saving ? null : (v) => v == null ? null : onChanged(v),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final shs = _isShs(_program);

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
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
                      'Add section',
                      style: TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w800,
                        color: CmColors.navy,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(_schoolYear,
                        style: const TextStyle(
                            color: CmColors.slate, fontSize: 14)),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Close',
                icon: const Icon(Icons.close, size: 20),
                onPressed: _saving ? null : () => Navigator.pop(context, false),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                   _labeled(
                    'School year',
                    TextFormField(
                      initialValue: _schoolYear,
                      enabled: !_saving,
                      keyboardType: TextInputType.text,
                      decoration: _fieldDecoration(
                        hint: 'Example: 2027-2028',
                      ).copyWith(
                        helperText: 'Enter the school year for this section.',
                      ),
                      onChanged: (value) {
                        setState(() {
                          _schoolYear = value.trim();
                          _error = null;
                        });
                      },
                    ),
                  ),
                  const SizedBox(height: 18),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 18),
                    child: _labeled(
                      'Program / Strand',
                        _groupedFilter(
                        context: context,
                        width: double.infinity,
                        includeAll: false,
                        enabled: !_saving,
                        value: _s(_program['code']),
                        hint: 'Select program / strand',
                        groups: {
                          'SHS · Senior High School':
                              (_ordered
                                  .where((p) => _isShs(p))
                                  .map((p) => _s(p['code']))
                                  .toList()
                                ..sort()),
                          'College · Undergraduate programs':
                              (_ordered
                                  .where((p) => !_isShs(p))
                                  .map((p) => _s(p['code']))
                                  .toList()
                                ..sort()),
                        },
                        onChanged: (value) {
                          if (value == null) return;

                          setState(() {
                            _program = _ordered.firstWhere(
                              (p) => _s(p['code']) == value,
                            );

                            if (_year > _maxYear) {
                              _year = 1;
                            }
                          });
                        },
                      ),
                    ),
                  ),

                  Padding(
                    padding: const EdgeInsets.only(bottom: 18),
                    child: _labeled(
                      'Year level',
                        _groupedFilter(
                        context: context,
                        width: double.infinity,
                        includeAll: false,
                        enabled: !_saving,
                        showGroupHeadings: false,
                        value: _addYearLabel(_year),
                        hint: 'Select year level',
                        groups: {
                          shs
                              ? 'SHS · Senior High School'
                              : 'College · Undergraduate programs': [
                            for (var y = 1; y <= _maxYear; y++)
                              _addYearLabel(y),
                          ],
                        },
                        onChanged: (value) {
                          if (value == null) return;

                          final selectedYear = [
                            for (var y = 1; y <= _maxYear; y++) y,
                          ].firstWhere(
                            (y) => _addYearLabel(y) == value,
                          );

                          setState(() => _year = selectedYear);
                        },
                      ),
                    ),
                  ),
                  
                  _field<int>(
                    label: 'Semester',
                    value: _semester,
                    items: [
                      for (final t in const [1, 2])
                        DropdownMenuItem(value: t, child: Text(_semLabel(t))),
                    ],
                    onChanged: (v) => setState(() => _semester = v),
                  ),
                  const Divider(color: CmColors.line),
                  const SizedBox(height: 14),
                  const Text(
                    'SECTION NAME',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.4,
                      color: CmColors.slate,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _name,
                    style: const TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.w800,
                      color: CmColors.navy,
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 14),
                    Text(_error!, style: const TextStyle(color: _dangerRed)),
                  ],
                ],
              ),
            ),
          ),
          const Divider(color: CmColors.line),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  style: _secondaryButtonStyle,
                  onPressed:
                      _saving ? null : () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  style: _primaryButtonStyle,
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.add, size: 20),
                  label: const Text('Add section'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
