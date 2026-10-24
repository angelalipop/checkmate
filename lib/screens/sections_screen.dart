import 'package:flutter/material.dart';
  import 'package:flutter/services.dart';

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

  /// One source of truth for year-level text (table, filter, caption):
  /// SHS -> "Grade 11" / "Grade 12", college -> "1st Year" ... "4th Year".
  String _yearLabel(bool shs, int y) {
    if (shs) return 'Grade ${10 + y}';
    const labels = ['1st Year', '2nd Year', '3rd Year', '4th Year'];
    return (y >= 1 && y <= labels.length) ? labels[y - 1] : 'Year $y';
  }
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
  List<String> _availableSectionNames({
    required _M program,
    required int year,
    required int semester,
    required Iterable<String> taken,
  }) {
    final code = _s(program['code']).toUpperCase();
    final prefix = _isShs(program)
        ? '$code${10 + year}-'
        : '$code$year$semester';

    final used = taken.map((name) => name.toUpperCase()).toSet();

    return [
      for (var i = 0; i < 26; i++)
        if (!used.contains('$prefix${String.fromCharCode(65 + i)}'))
          '$prefix${String.fromCharCode(65 + i)}',
    ];
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

  /// Filter-bar field style: white, 10px radius, faint border (the soft
  /// shadow comes from [_softShadow]).
  InputDecoration _softFieldDecoration({String? hint, Widget? prefix}) {
    OutlineInputBorder border(Color c, [double w = 1]) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: c, width: w),
        );
    final faint = CmColors.line.withValues(alpha: 0.7);
    return InputDecoration(
      isDense: true,
      filled: true,
      fillColor: Colors.white,
      hintText: hint,
      hintStyle: const TextStyle(color: CmColors.slate, fontSize: 14),
      prefixIcon: prefix,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: border(faint),
      enabledBorder: border(faint),
      focusedBorder: border(CmColors.navy, 1.5),
    );
  }

  Widget _softShadow(Widget child) => DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          boxShadow: [
            BoxShadow(
              color: CmColors.navy.withValues(alpha: 0.06),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: child,
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
      bool soft = false,
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
                borderRadius: BorderRadius.circular(soft ? 10 : 12),
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
                  decoration: soft ? _softFieldDecoration() : _fieldDecoration(),
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
    String? _fYear; // label, e.g. "1st Year" / "Grade 11"
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

    /// True when [code] belongs to an SHS strand (false for college / null).
    bool _programIsShs(String? code) => _programs.any(
          (p) => _s(p['code']) == code && _isShs(p),
        );

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

      final added = await showGeneralDialog<int>(
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

      if (added != null && added > 0) {
        await _load();
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(
              content: Text('$added section${added == 1 ? '' : 's'} created.'),
            ));
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
        return _softShadow(
          DropdownButtonFormField<T>(
            key: ValueKey('$hint-$value'),
            initialValue: items.contains(value) ? value : null,
            isExpanded: true,
            icon: const Icon(Icons.keyboard_arrow_down,
                size: 20, color: CmColors.slate),
            decoration: _softFieldDecoration(),
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

      Widget searchField() => _softShadow(
            TextField(
              controller: _search,
              decoration: _softFieldDecoration(
                hint: 'Section or program...',
                prefix: const Icon(Icons.search,
                    size: 20, color: CmColors.slate),
              ),
            ),
          );

      Widget programField(double width) => _softShadow(
            _groupedFilter(
              context: context,
              width: width,
              soft: true,
              value: _fProgram,
              hint: 'All programs / strands',
              groups: {
                'SHS · Senior High School': shsCodes,
                'College · Undergraduate programs': collegeCodes,
              },
              onChanged: (value) => setState(() {
                _fProgram = value;
                // Keep the year filter valid for the newly chosen program.
                final shs = _programIsShs(value);
                if (value != null &&
                    _fYear != null &&
                    _fYear!.startsWith('Grade') != shs) {
                  _fYear = null;
                }
              }),
            ),
          );

      Widget yearField(double width) => _softShadow(
            _groupedFilter(
              context: context,
              width: width,
              soft: true,
              value: _fYear,
              hint: 'All year levels',
              // A program / strand is picked -> only its own year levels,
              // with no group heading. Nothing picked -> both groups.
              showGroupHeadings: _fProgram == null,
              groups: _fProgram == null
                  ? const {
                      'SHS · Senior High School': ['Grade 11', 'Grade 12'],
                      'College · Undergraduate programs': [
                        '1st Year',
                        '2nd Year',
                        '3rd Year',
                        '4th Year',
                      ],
                    }
                  : _programIsShs(_fProgram)
                      ? const {
                          'Senior High School': ['Grade 11', 'Grade 12'],
                        }
                      : const {
                          'College': [
                            '1st Year',
                            '2nd Year',
                            '3rd Year',
                            '4th Year',
                          ],
                        },
              onChanged: (value) => setState(() => _fYear = value),
            ),
          );

      Widget schoolYearField() => dropdown<String>(
            value: _fSchoolYear,
            hint: 'All school years',
            items: _schoolYears,
            label: (e) => e,
            onChanged: (v) => setState(() => _fSchoolYear = v),
          );

      Widget semesterField() => dropdown<int>(
            value: _fSemester,
            hint: 'All semesters',
            items: const [1, 2],
            label: _semLabel,
            onChanged: (v) => setState(() => _fSemester = v),
          );

      Widget resetButton() => SizedBox(
            height: 46,
            child: TextButton.icon(
              onPressed: _reset,
              icon: const Icon(Icons.close, size: 16),
              label: const Text('Reset'),
              style: TextButton.styleFrom(
                foregroundColor: CmColors.slate,
                textStyle: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
                padding: const EdgeInsets.symmetric(horizontal: 14),
              ),
            ),
          );

      Widget lab(String text, Widget field) => _labeled(text, field);

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: const [
              Icon(Icons.tune, size: 18, color: _activeGreen),
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
          LayoutBuilder(
            builder: (context, c) {
              // Wide: one row, fields share the width (search a bit wider).
              if (c.maxWidth >= 960) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      flex: 3,
                      child: lab('Search sections', searchField()),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      flex: 2,
                      child: lab(
                          'Program / Strand', programField(double.infinity)),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      flex: 2,
                      child: lab('Year level', yearField(double.infinity)),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      flex: 2,
                      child: lab('School year', schoolYearField()),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      flex: 2,
                      child: lab('Semester', semesterField()),
                    ),
                    const SizedBox(width: 6),
                    resetButton(),
                  ],
                );
              }

              // Narrower: wrap onto several lines.
              return Wrap(
                spacing: 14,
                runSpacing: 14,
                crossAxisAlignment: WrapCrossAlignment.end,
                children: [
                  SizedBox(
                    width: c.maxWidth < 320 ? c.maxWidth : 300,
                    child: lab('Search sections', searchField()),
                  ),
                  SizedBox(
                    width: 210,
                    child: lab('Program / Strand', programField(210)),
                  ),
                  SizedBox(
                    width: 210,
                    child: lab('Year level', yearField(210)),
                  ),
                  SizedBox(
                    width: 210,
                    child: lab('School year', schoolYearField()),
                  ),
                  SizedBox(
                    width: 210,
                    child: lab('Semester', semesterField()),
                  ),
                  resetButton(),
                ],
              );
            },
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

    int? _quantity = 1;
    final _quantityController = TextEditingController(text: '1');

    bool _saving = false;
    String? _error;

    /// College programs first, then SHS strands.
    late final List<_M> _ordered = [
      ...widget.programs.where((p) => !_isShs(p)),
      ...widget.programs.where(_isShs),
    ];

    int get _maxYear => _isShs(_program) ? 2 : 4;

    List<String> get _availableNames => _availableSectionNames(
          program: _program,
          year: _year,
          semester: _semester,
          taken: widget.existing
              .where((s) =>
                  _s(s['school_year']) == _schoolYear &&
                  _i(s['semester']) == _semester)
              .map((s) => _s(s['name'])),
        );

  List<String> get _names {
      final quantity = _quantity;
      if (quantity == null || quantity < 1 || quantity > 26) return [];
      return _availableNames.take(quantity).toList();
    }

    bool get _canCreate {
      final quantity = _quantity;
      return quantity != null && quantity >= 1 &&
          quantity <= 26 && quantity <= _availableNames.length;
    }

    void _changeQuantity(int change) {
      final capacity = _availableNames.length;
      if (_saving || capacity == 0) return;
      final next = ((_quantity ?? 0) + change).clamp(1, capacity).toInt();
      setState(() {
        _quantity = next;
        _quantityController.text = '$next';
        _error = null;
      });
    }

    @override
    void dispose() {
      _quantityController.dispose();
      super.dispose();
    }

      String _addYearLabel(int year) {
      if (_isShs(_program)) return 'Grade ${10 + year}';

      const labels = [
        '1st Year',
        '2nd Year',
        '3rd Year',
        '4th Year',
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
      if (!_canCreate) {
        setState(() {
          _error = 'Choose a quantity from 1 to ${_availableNames.length}.';
        });
        return;
      }
      final names = _names;
      setState(() {
        _saving = true;
        _error = null;
      });
      try {
        final token = await widget.getToken();
        final created = await SectionApi.createSections(
          token,
          programId: _i(_program['id']),
          names: names,
          yearLevel: _year,
          schoolYear: _schoolYear,
          semester: _semester,
        );
        if (!mounted) return;
        Navigator.pop(context, created.length);
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _saving = false;
          _error = e.toString().replaceFirst('Exception: ', '');
        });
      }
    }

    /// Square stepper button used next to the quantity field.
    Widget _stepButton({
      required IconData icon,
      required String tooltip,
      required VoidCallback? onPressed,
      required bool primary,
    }) {
      final enabled = onPressed != null;
      final fg = primary ? CmColors.navy : CmColors.slate;
      return Tooltip(
        message: tooltip,
        child: Material(
          color: primary
              ? CmColors.navy.withValues(alpha: enabled ? 0.08 : 0.04)
              : CmColors.bg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
              color: primary
                  ? CmColors.navy.withValues(alpha: enabled ? 0.35 : 0.15)
                  : CmColors.line,
            ),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onPressed,
            child: SizedBox(
              width: 46,
              height: 46,
              child: Icon(
                icon,
                size: 20,
                color: enabled ? fg : fg.withValues(alpha: 0.35),
              ),
            ),
          ),
        ),
      );
    }

    @override
    Widget build(BuildContext context) {
      final shs = _isShs(_program);
      final names = _names;
      // Accent for the section-name preview. Change this one line to
      // recolor the chips / name (e.g. _activeGreen).
      const accent = CmColors.navy;

      final canDecrease =
          !_saving && _availableNames.isNotEmpty && (_quantity ?? 0) > 1;
      final canIncrease = !_saving &&
          _availableNames.isNotEmpty &&
          (_quantity ?? 0) < _availableNames.length;

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ---------- header ----------
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 16, 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Add section',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          color: CmColors.navy,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          const Icon(Icons.calendar_today_outlined,
                              size: 15, color: CmColors.slate),
                          const SizedBox(width: 8),
                          Text(
                            'School year $_schoolYear',
                            style: const TextStyle(
                              color: CmColors.slate,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Close',
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: _saving ? null : () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: CmColors.line),

          // ---------- form ----------
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 22, 24, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _labeled(
                    'School year',
                    TextFormField(
                      initialValue: _schoolYear,
                      enabled: !_saving,
                      keyboardType: TextInputType.text,
                      decoration: _fieldDecoration(hint: 'Example: 2027-2028'),
                      onChanged: (value) {
                        setState(() {
                          _schoolYear = value.trim();
                          _error = null;
                        });
                      },
                    ),
                  ),
                  const SizedBox(height: 20),

                  // Program / Strand  |  Year level
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
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
                              'SHS · Senior High School': (_ordered
                                  .where((p) => _isShs(p))
                                  .map((p) => _s(p['code']))
                                  .toList()
                                ..sort()),
                              'College · Undergraduate programs': (_ordered
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
                                if (_year > _maxYear) _year = 1;
                              });
                            },
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
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
                              ].firstWhere((y) => _addYearLabel(y) == value);
                              setState(() => _year = selectedYear);
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),

                  // Semester  |  How many sections?
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: _labeled(
                          'Semester',
                          DropdownButtonFormField<int>(
                            key: ValueKey('semester-$_semester'),
                            initialValue: _semester,
                            isExpanded: true,
                            icon: const Icon(Icons.keyboard_arrow_down,
                                size: 20),
                            decoration: _fieldDecoration(),
                            items: [
                              for (final t in const [1, 2])
                                DropdownMenuItem(
                                  value: t,
                                  child: Text(_semLabel(t)),
                                ),
                            ],
                            onChanged: _saving
                                ? null
                                : (v) => v == null
                                    ? null
                                    : setState(() => _semester = v),
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: _labeled(
                          'How many sections?',
                          Row(
                            children: [
                              _stepButton(
                                icon: Icons.remove,
                                tooltip: 'Fewer sections',
                                primary: false,
                                onPressed:
                                    canDecrease ? () => _changeQuantity(-1) : null,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: SizedBox(
                                  height: 46,
                                  child: TextFormField(
                                    controller: _quantityController,
                                    enabled: !_saving,
                                    keyboardType: TextInputType.number,
                                    inputFormatters: [
                                      FilteringTextInputFormatter.digitsOnly,
                                      LengthLimitingTextInputFormatter(2),
                                    ],
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                      color: CmColors.navy,
                                    ),
                                    decoration: _fieldDecoration().copyWith(
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                              horizontal: 4, vertical: 12),
                                    ),
                                    onChanged: (value) => setState(() {
                                      _quantity = int.tryParse(value);
                                      _error = null;
                                    }),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              _stepButton(
                                icon: Icons.add,
                                tooltip: 'More sections',
                                primary: true,
                                onPressed:
                                    canIncrease ? () => _changeQuantity(1) : null,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 22),
                  const Divider(height: 1, color: CmColors.line),
                  const SizedBox(height: 18),

                  // ---------- section names preview ----------
                  Row(
                    children: [
                      const Icon(Icons.layers_outlined,
                          size: 18, color: accent),
                      const SizedBox(width: 8),
                      Text(
                        names.length == 1 ? 'Section name' : 'Section names',
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: CmColors.slate,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        '${names.length} section${names.length == 1 ? '' : 's'}',
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w500,
                          color: CmColors.slate,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (names.length == 1)
                    Text(
                      names.first,
                      style: const TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.w800,
                        color: accent,
                        height: 1.15,
                      ),
                    )
                  else
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final name in names)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 10,
                            ),
                            decoration: BoxDecoration(
                              color: accent.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              name,
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                                color: accent,
                              ),
                            ),
                          ),
                      ],
                    ),
                  const SizedBox(height: 12),
                  Text(
                    '${shs ? 'Senior High School' : 'College'} · '
                    '${_addYearLabel(_year)} · ${_semLabel(_semester)}',
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: CmColors.slate,
                    ),
                  ),
                  if (!_canCreate) ...[
                    const SizedBox(height: 10),
                    Text(
                      _availableNames.isEmpty
                          ? 'All section letters A–Z are already used for this context.'
                          : 'Enter a quantity from 1 to ${_availableNames.length}.',
                      style: const TextStyle(color: _dangerRed),
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 14),
                    Text(_error!, style: const TextStyle(color: _dangerRed)),
                  ],
                ],
              ),
            ),
          ),

          // ---------- footer ----------
          const Divider(height: 1, color: CmColors.line),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 14, 24, 20),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    style: _secondaryButtonStyle,
                    onPressed: _saving ? null : () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    style: _primaryButtonStyle,
                    onPressed: _saving || !_canCreate ? null : _save,
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
                    label: Text(
                      _saving
                          ? 'Creating…'
                          : 'Create ${_quantity ?? 0} section${_quantity == 1 ? '' : 's'}',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }
  }