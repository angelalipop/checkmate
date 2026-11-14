import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../services/api_service.dart';
import '../services/auth_storage.dart';
import 'answer_sheet_input_screen.dart';
import 'exams_tab.dart';
import 'login_screen.dart' show CmColors, LoginScreen;
import 'my_subjects_screen.dart';
import 'students_screen.dart';

typedef JsonMap = Map<String, dynamic>;

const double _kDesktop = 900;
const double _kTablet = 600;
const double _kSidebarWide = 256;
const double _kSidebarRail = 80;

class _Pal {
  _Pal._();
  static const Color sidebar = Color(0xFF162137);
  static const Color sidebarActive = Color(0xFF2D384D);
  static const Color sidebarFg = Color(0xFFCFD8E5);
  static const Color notifDot = Color(0xFFF7A224);
  static final Color divider = Colors.white.withValues(alpha: 0.12);
}

final ValueNotifier<bool> _sidebarCollapsed = ValueNotifier<bool>(false);
Route<dynamic>? _teacherDashboardRoute;
void Function(TeacherPage page)? _dashboardNavigate;

enum TeacherPage {
  dashboard('Dashboard', Icons.space_dashboard_outlined),
  subjects('My Subjects', Icons.menu_book_outlined),
  students('Students', Icons.school_outlined),
  exams('Exams', Icons.assignment_outlined),
  scans('Scans', Icons.document_scanner_outlined);

  const TeacherPage(this.label, this.icon);
  final String label;
  final IconData icon;
}

const List<TeacherPage> _bottomPages = [
  TeacherPage.dashboard,
  TeacherPage.subjects,
  TeacherPage.exams,
  TeacherPage.scans,
];

String _prettyStatus(String? raw) {
  final s = (raw ?? '').replaceAll('_', ' ').trim();
  if (s.isEmpty) return 'Draft';
  return s
      .split(' ')
      .map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1))
      .join(' ');
}

bool _isDone(String status) =>
    status == 'Completed' || status == 'Finalized';

String _classCode(JsonMap c) {
  final subject = c['subject'];
  final code = subject is Map ? subject['code']?.toString() ?? '' : '';
  final section = c['section']?.toString() ?? '';
  return [code, section].where((e) => e.isNotEmpty).join(' - ');
}

class _ExamInfo {
  const _ExamInfo({
    this.id,
    required this.title,
    required this.code,
    required this.date,
    required this.students,
    required this.status,
  });

  final int? id;
  final String title, code, date, status;
  final int students;
}

class _ExamAnalytics {
  const _ExamAnalytics({
    required this.examId,
    required this.examTitle,
    required this.attemptPercentages,
    required this.lowAccuracyItemCount,
    required this.missedQuestionNumbers,
    required this.hasIdentificationSection,
    required this.lowestSectionName,
    required this.lowestSectionAvg,
    required this.idReviewCount,
    required this.omrReviewCount,
    required this.pendingScanCount,
  });

  final int examId;
  final String examTitle;
  final List<double> attemptPercentages;
  final int lowAccuracyItemCount;
  final List<int> missedQuestionNumbers;
  final bool hasIdentificationSection;
  final String? lowestSectionName;
  final double? lowestSectionAvg;
  final int idReviewCount;
  final int omrReviewCount;
  final int pendingScanCount;
}

class _DashboardMetrics {
  const _DashboardMetrics({
    required this.totalForReview,
    required this.idReviewPapers,
    required this.omrReviewPapers,
    required this.unscannedPapers,
    required this.firstReviewExamId,
    required this.totalAttempts,
    required this.averagePercent,
    required this.highestPercent,
    required this.lowestPercent,
    required this.buckets,
    required this.lowAccuracyItems,
    required this.insightBannerText,
  });

  final int totalForReview;
  final int idReviewPapers;
  final int omrReviewPapers;
  final int unscannedPapers;
  final int? firstReviewExamId;
  final int totalAttempts;
  final double averagePercent;
  final double highestPercent;
  final double lowestPercent;
  final Map<String, int> buckets;
  final int lowAccuracyItems;
  final String insightBannerText;

  static const emptyBuckets = <String, int>{
    '0-59': 0,
    '60-69': 0,
    '70-79': 0,
    '80-89': 0,
    '90-100': 0,
  };

  factory _DashboardMetrics.fromExams(
    List<_ExamInfo> exams,
    Map<int, _ExamAnalytics> byExam, {
    int? selectedExamId,
  }) {
    final targetAnalytics =
        selectedExamId != null && byExam.containsKey(selectedExamId)
            ? [byExam[selectedExamId]!]
            : byExam.values.toList();

    int idRev = 0;
    int omrRev = 0;
    int pendingScans = 0;
    int? reviewExamId;

    for (final e in exams) {
      final id = e.id;
      if (id == null) continue;
      final a = byExam[id];
      if (a != null) {
        idRev += a.idReviewCount;
        omrRev += a.omrReviewCount;
        pendingScans += a.pendingScanCount;
        if (reviewExamId == null &&
            (a.idReviewCount + a.omrReviewCount + a.pendingScanCount) > 0) {
          reviewExamId = id;
        }
      }
    }

    final allPercentages = <double>[];
    int lowItems = 0;
    final missedQuestions = <int>[];
    String? weakestSection;
    double? weakestSectionVal;

    for (final a in targetAnalytics) {
      allPercentages.addAll(a.attemptPercentages);
      lowItems += a.lowAccuracyItemCount;
      missedQuestions.addAll(a.missedQuestionNumbers);
      if (a.lowestSectionName != null && a.lowestSectionAvg != null) {
        if (weakestSectionVal == null ||
            a.lowestSectionAvg! < weakestSectionVal) {
          weakestSectionVal = a.lowestSectionAvg;
          weakestSection = a.lowestSectionName;
        }
      }
    }

    final buckets = Map<String, int>.from(emptyBuckets);
    double sum = 0;
    double high = 0;
    double low = 100;

    for (final p in allPercentages) {
      final clamped = p.clamp(0.0, 100.0);
      sum += clamped;
      if (clamped > high) high = clamped;
      if (clamped < low) low = clamped;

      if (clamped < 60) {
        buckets['0-59'] = (buckets['0-59'] ?? 0) + 1;
      } else if (clamped < 70) {
        buckets['60-69'] = (buckets['60-69'] ?? 0) + 1;
      } else if (clamped < 80) {
        buckets['70-79'] = (buckets['70-79'] ?? 0) + 1;
      } else if (clamped < 90) {
        buckets['80-89'] = (buckets['80-89'] ?? 0) + 1;
      } else {
        buckets['90-100'] = (buckets['90-100'] ?? 0) + 1;
      }
    }

    final count = allPercentages.length;
    final avg = count > 0 ? (sum / count) : 0.0;
    if (count == 0) low = 0.0;

    String banner;
    if (count == 0) {
      banner =
          'No recorded exam attempts yet. Scan answer sheets to generate item difficulty analysis and smart recommendations.';
    } else if (lowItems > 0) {
      final sampleNums = missedQuestions.take(4).map((q) => '#$q').join(', ');
      final itemWord = lowItems == 1 ? 'item' : 'items';
      banner = sampleNums.isNotEmpty
          ? '$lowItems $itemWord ($sampleNums) answered correctly by fewer than 40% — review recommended.'
          : '$lowItems $itemWord answered correctly by fewer than 40% — review these concepts with the class.';
    } else if (weakestSection != null &&
        weakestSectionVal != null &&
        weakestSectionVal < 60) {
      banner =
          'Lowest accuracy in $weakestSection (${weakestSectionVal.toStringAsFixed(0)}%) — consider a targeted topic review.';
    } else if (avg < 75.0) {
      banner =
          'Class average (${avg.toStringAsFixed(1)}%) is below 75% — a remedial review session is recommended.';
    } else {
      banner =
          'Strong class mastery! All items achieved at least 40% accuracy (Class average: ${avg.toStringAsFixed(1)}%).';
    }

    final totalReview = idRev + omrRev + pendingScans;

    return _DashboardMetrics(
      totalForReview: totalReview,
      idReviewPapers: idRev,
      omrReviewPapers: omrRev,
      unscannedPapers: pendingScans,
      firstReviewExamId:
          reviewExamId ?? (exams.isNotEmpty ? exams.first.id : null),
      totalAttempts: count,
      averagePercent: avg,
      highestPercent: high,
      lowestPercent: low,
      buckets: buckets,
      lowAccuracyItems: lowItems,
      insightBannerText: banner,
    );
  }
}

class _TeacherIdentity {
  static String? name;
  static String? email;
  static String fallbackName = 'Teacher';
  static bool _loaded = false;

  static Future<void> load() async {
    if (_loaded) return;
    try {
      final token = await AuthStorage.getToken();
      if (token == null || token.isEmpty) return;

      final parts = token.split('.');
      if (parts.length != 3) return;

      final payload = utf8.decode(
        base64Url.decode(base64Url.normalize(parts[1])),
      );

      final decoded = jsonDecode(payload);

      if (decoded is Map) {
        final source = decoded['user'] is Map
            ? decoded['user'] as Map
            : decoded;

        final n = (source['name'] ?? source['full_name'] ?? source['username'])
            ?.toString();
        final e = source['email']?.toString();
        if (n != null && n.isNotEmpty) name = n;
        if (e != null && e.isNotEmpty) email = e;
      }
      _loaded = true;
    } catch (_) {}
  }

  static void reset() {
    name = null;
    email = null;
    fallbackName = 'Teacher';
    _loaded = false;
  }

  static String get displayName => name ?? fallbackName;

  static String initials(String n) {
    final parts = n
        .trim()
        .split(RegExp(r'\s+'))
        .where((s) => s.isNotEmpty)
        .toList();

    if (parts.isEmpty) return 'T';
    if (parts.length == 1) {
      return parts[0].substring(0, math.min(2, parts[0].length)).toUpperCase();
    }
    return (parts[0][0] + parts[1][0]).toUpperCase();
  }
}

Widget? _moduleScreenFor(TeacherPage page) {
  switch (page) {
    case TeacherPage.subjects:
      return const MySubjectsScreen();
    case TeacherPage.students:
      return const StudentsScreen();
    case TeacherPage.exams:
      return const ExamsTab();
    case TeacherPage.scans:
      return const AnswerSheetInputScreen();
    default:
      return null;
  }
}

Route<void> _shellRoute(TeacherPage page, Widget screen) {
  return PageRouteBuilder<void>(
    transitionDuration: Duration.zero,
    reverseTransitionDuration: Duration.zero,
    pageBuilder: (_, _, _) => _ModuleShell(page: page, child: screen),
  );
}

void openTeacherScansForExam(BuildContext context, int examId) {
  Navigator.of(context).pushReplacement(
    _shellRoute(
      TeacherPage.scans,
      AnswerSheetInputScreen(
        key: ValueKey('scan-exam-$examId'),
        initialExamId: examId,
      ),
    ),
  );
}

Future<void> _performLogout(BuildContext context) async {
  await AuthStorage.deleteToken();
  _TeacherIdentity.reset();
  if (!context.mounted) return;
  Navigator.pushAndRemoveUntil(
    context,
    MaterialPageRoute(builder: (_) => const LoginScreen()),
    (route) => false,
  );
}

void _soon(BuildContext context, String what) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text('$what is coming soon.')),
  );
}

class _ModuleShell extends StatelessWidget {
  const _ModuleShell({required this.page, required this.child});

  final TeacherPage page;
  final Widget child;

  void _select(BuildContext context, TeacherPage target) {
    if (target == page && target != TeacherPage.exams) return;

    final screen = _moduleScreenFor(target);
    if (screen != null) {
      Navigator.of(context).pushReplacement(_shellRoute(target, screen));
      return;
    }

    final dashboard = _teacherDashboardRoute;
    if (dashboard != null) {
      Navigator.of(context).popUntil((route) => route == dashboard);
      _dashboardNavigate?.call(target);
    } else {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isSubjects = page == TeacherPage.subjects;
    final hasHeader = page == TeacherPage.exams || isSubjects;
    return TeacherShell(
      current: page,
      onSelect: (p) => _select(context, p),
      onLogout: () => _performLogout(context),
      desktopHeader: isSubjects
          ? _DesktopTopBar(
              hint: 'Search subjects by name or code',
              onSearchChanged: (v) => mySubjectsSearch.value = v,
            )
          : (hasHeader ? const _DesktopTopBar() : null),
      mobileActions:
          hasHeader ? const [_NotificationBell(onDark: true)] : const [],
      child: child,
    );
  }
}

class TeacherShell extends StatefulWidget {
  const TeacherShell({
    super.key,
    required this.current,
    required this.onSelect,
    required this.onLogout,
    required this.child,
    this.desktopHeader,
    this.mobileActions = const [],
  });

  final TeacherPage current;
  final ValueChanged<TeacherPage> onSelect;
  final VoidCallback onLogout;
  final Widget child;
  final Widget? desktopHeader;
  final List<Widget> mobileActions;

  @override
  State<TeacherShell> createState() => _TeacherShellState();
}

class _TeacherShellState extends State<TeacherShell> {
  bool _drawerOpen = false;

  @override
  void initState() {
    super.initState();
    _TeacherIdentity.load().then((_) {
      if (mounted) setState(() {});
    });
  }

  void _openDrawer() => setState(() => _drawerOpen = true);

  void _closeDrawer() {
    if (_drawerOpen) setState(() => _drawerOpen = false);
  }

  void _select(TeacherPage page) {
    _closeDrawer();
    widget.onSelect(page);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;

        if (w >= _kDesktop) {
          return Scaffold(
            backgroundColor: CmColors.bg,
            body: Row(
              children: [
                ValueListenableBuilder<bool>(
                  valueListenable: _sidebarCollapsed,
                  builder: (context, collapsed, _) {
                    return AnimatedContainer(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutCubic,
                      width: collapsed ? _kSidebarRail : _kSidebarWide,
                      child: _Sidebar(
                        current: widget.current,
                        onSelect: _select,
                        onLogout: widget.onLogout,
                        userName: _TeacherIdentity.displayName,
                        userEmail: _TeacherIdentity.email,
                        collapsible: widget.desktopHeader == null,
                        collapsed: collapsed,
                        onToggle: () => _sidebarCollapsed.value = !collapsed,
                      ),
                    );
                  },
                ),
                Expanded(
                  child: Column(
                    children: [
                      if (widget.desktopHeader != null) widget.desktopHeader!,
                      Expanded(child: widget.child),
                    ],
                  ),
                ),
              ],
            ),
          );
        }

        final isMobile = w < _kTablet;
        final bottomIndex = _bottomPages.indexOf(widget.current);

        return Stack(
          children: [
            Positioned.fill(
              child: Scaffold(
                backgroundColor: CmColors.bg,
                body: Column(
                  children: [
                    _MobileTopBar(
                      onMenu: _openDrawer,
                      actions: widget.mobileActions,
                    ),
                    Expanded(child: widget.child),
                  ],
                ),
                bottomNavigationBar: isMobile
                    ? NavigationBar(
                        backgroundColor: Colors.white,
                        indicatorColor:
                            _Pal.sidebar.withValues(alpha: 0.10),
                        selectedIndex: bottomIndex == -1 ? 4 : bottomIndex,
                        onDestinationSelected: (i) {
                          if (i == 4) {
                            _openDrawer();
                          } else {
                            _select(_bottomPages[i]);
                          }
                        },
                        destinations: [
                          for (final p in _bottomPages)
                            NavigationDestination(
                              icon: Icon(p.icon, color: CmColors.slate),
                              selectedIcon: Icon(p.icon, color: _Pal.sidebar),
                              label: p == TeacherPage.dashboard
                                  ? 'Home'
                                  : p.label,
                            ),
                          const NavigationDestination(
                            icon: Icon(Icons.more_horiz, color: CmColors.slate),
                            selectedIcon:
                                Icon(Icons.more_horiz, color: _Pal.sidebar),
                            label: 'More',
                          ),
                        ],
                      )
                    : null,
              ),
            ),
            if (_drawerOpen) _buildDrawer(w),
          ],
        );
      },
    );
  }

  Widget _buildDrawer(double screenWidth) {
    final drawerWidth = math.min(300.0, screenWidth * 0.85);

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): _closeDrawer,
      },
      child: Focus(
        autofocus: true,
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          builder: (context, t, child) {
            return Stack(
              children: [
                Positioned.fill(
                  child: Semantics(
                    button: true,
                    label: 'Close navigation menu',
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _closeDrawer,
                      child: ColoredBox(
                        color: Colors.black.withValues(alpha: 0.5 * t),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: 0,
                  bottom: 0,
                  left: -drawerWidth * (1 - t),
                  width: drawerWidth,
                  child: child!,
                ),
              ],
            );
          },
          child: Semantics(
            scopesRoute: true,
            explicitChildNodes: true,
            namesRoute: true,
            label: 'Navigation drawer',
            child: Material(
              color: _Pal.sidebar,
              elevation: 16,
              child: SafeArea(
                child: _Sidebar(
                  current: widget.current,
                  onSelect: _select,
                  onLogout: () {
                    _closeDrawer();
                    widget.onLogout();
                  },
                  userName: _TeacherIdentity.displayName,
                  userEmail: _TeacherIdentity.email,
                  onClose: _closeDrawer,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MobileTopBar extends StatelessWidget {
  const _MobileTopBar({required this.onMenu, required this.actions});

  final VoidCallback onMenu;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: _Pal.sidebar,
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: 64,
          child: Row(
            children: [
              const SizedBox(width: 4),
              IconButton(
                tooltip: 'Open navigation menu',
                icon: const Icon(Icons.menu, color: _Pal.sidebarFg),
                onPressed: onMenu,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Image.asset(
                    'assets/transparent_logo1.png',
                    height: 44,
                    fit: BoxFit.contain,
                    alignment: Alignment.centerLeft,
                    cacheHeight: 132,
                    errorBuilder: (context, error, stackTrace) => const Text(
                      'CheckMate',
                      style: TextStyle(
                        color: _Pal.sidebarFg,
                        fontWeight: FontWeight.w700,
                        fontSize: 18,
                      ),
                    ),
                  ),
                ),
              ),
              ...actions,
              const SizedBox(width: 8),
            ],
          ),
        ),
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.current,
    required this.onSelect,
    required this.onLogout,
    required this.userName,
    this.userEmail,
    this.collapsible = false,
    this.collapsed = false,
    this.onToggle,
    this.onClose,
  });

  final TeacherPage current;
  final ValueChanged<TeacherPage> onSelect;
  final VoidCallback onLogout;
  final String userName;
  final String? userEmail;
  final bool collapsible;
  final bool collapsed;
  final VoidCallback? onToggle;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: _Pal.sidebar,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final showLabels = constraints.maxWidth > 180;

          return Padding(
            padding: const EdgeInsets.fromLTRB(12, 16, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _header(showLabels),
                Divider(color: _Pal.divider, height: 24),
                Expanded(
                  child: ListView(
                    children: [
                      for (final p in TeacherPage.values)
                        _SidebarItem(
                          icon: p.icon,
                          label: p.label,
                          active: p == current,
                          showLabel: showLabels,
                          onTap: () => onSelect(p),
                        ),
                    ],
                  ),
                ),
                Divider(color: _Pal.divider, height: 20),
                _userCard(context, showLabels),
                const SizedBox(height: 4),
                _SidebarItem(
                  icon: Icons.logout,
                  label: 'Log out',
                  active: false,
                  showLabel: showLabels,
                  onTap: onLogout,
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _userCard(BuildContext context, bool showLabels) {
    final avatar = CircleAvatar(
      radius: 16,
      backgroundColor: _Pal.sidebarActive,
      child: Text(
        _TeacherIdentity.initials(userName),
        style: const TextStyle(
          color: _Pal.sidebarFg,
          fontSize: 11,
          fontWeight: FontWeight.w800,
        ),
      ),
    );

    final email = userEmail;

    final content = InkWell(
      borderRadius: BorderRadius.circular(12),
      hoverColor: _Pal.sidebarActive,
      highlightColor: _Pal.sidebarActive,
      splashColor: _Pal.sidebarActive,
      onTap: () => _soon(context, 'Profile'),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Row(
          mainAxisAlignment:
              showLabels ? MainAxisAlignment.start : MainAxisAlignment.center,
          children: [
            avatar,
            if (showLabels) ...[
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      userName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: _Pal.sidebarFg,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (email != null && email.isNotEmpty)
                      Text(
                        email,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: _Pal.sidebarFg.withValues(alpha: 0.7),
                          fontSize: 12,
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

    return Material(
      color: Colors.transparent,
      child: showLabels
          ? content
          : Tooltip(message: 'Profile — $userName', child: content),
    );
  }

  Widget _header(bool showLabels) {
    final toggle = collapsible
        ? IconButton(
            tooltip: collapsed ? 'Expand sidebar' : 'Collapse sidebar',
            icon: Icon(
              collapsed
                  ? Icons.keyboard_double_arrow_right
                  : Icons.keyboard_double_arrow_left,
              color: _Pal.sidebarFg,
            ),
            onPressed: onToggle,
          )
        : null;

    final close = onClose != null
        ? IconButton(
            tooltip: 'Close navigation menu',
            icon: const Icon(Icons.close, color: _Pal.sidebarFg),
            onPressed: onClose,
          )
        : null;

    if (!showLabels) {
      return Column(
        children: [
          Image.asset(
            'assets/logo_circle.png',
            width: 52,
            height: 52,
            fit: BoxFit.contain,
            errorBuilder: (context, error, stackTrace) => const Icon(
              Icons.fact_check_rounded,
              color: _Pal.sidebarFg,
              size: 32,
            ),
          ),
          if (toggle != null) ...[const SizedBox(height: 8), toggle],
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: SizedBox(
                height: 60,
                child: Image.asset(
                  'assets/dashboard_logo.png',
                  fit: BoxFit.contain,
                  alignment: Alignment.centerLeft,
                  cacheWidth: 600,
                  errorBuilder: (context, error, stackTrace) => const Row(
                    children: [
                      Icon(Icons.fact_check_rounded, color: _Pal.sidebarFg),
                      SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          'CheckMate',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: _Pal.sidebarFg,
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            ?toggle,
            ?close,
          ],
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: _Pal.sidebarActive,
            borderRadius: BorderRadius.circular(6),
          ),
          child: const Text(
            'TEACHER PORTAL',
            style: TextStyle(
              color: _Pal.sidebarFg,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
            ),
          ),
        ),
      ],
    );
  }
}

class _SidebarItem extends StatelessWidget {
  const _SidebarItem({
    required this.icon,
    required this.label,
    required this.active,
    required this.showLabel,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool active;
  final bool showLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final item = Material(
      color: active ? _Pal.sidebarActive : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        hoverColor: _Pal.sidebarActive,
        highlightColor: _Pal.sidebarActive,
        splashColor: _Pal.sidebarActive,
        onTap: onTap,
        child: SizedBox(
          height: 44,
          child: Row(
            mainAxisAlignment: showLabel
                ? MainAxisAlignment.start
                : MainAxisAlignment.center,
            children: [
              if (showLabel) const SizedBox(width: 12),
              Icon(icon, color: _Pal.sidebarFg, size: 21),
              if (showLabel) ...[
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: _Pal.sidebarFg,
                      fontSize: 14.5,
                      fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Semantics(
        button: true,
        selected: active,
        label: label,
        excludeSemantics: true,
        child: showLabel ? item : Tooltip(message: label, child: item),
      ),
    );
  }
}

class TeacherDashboard extends StatefulWidget {
  const TeacherDashboard({super.key, this.teacherName = 'Teacher'});

  final String teacherName;

  @override
  State<TeacherDashboard> createState() => _TeacherDashboardState();
}

class _TeacherDashboardState extends State<TeacherDashboard> {
  TeacherPage _page = TeacherPage.dashboard;
  Route<dynamic>? _route;

  bool _loading = true;
  String? _error;
  List<_ExamInfo> _exams = [];
  Map<int, _ExamAnalytics> _analyticsByExam = {};
  int? _selectedAnalyticsExamId;

  @override
  void initState() {
    super.initState();
    _TeacherIdentity.fallbackName = widget.teacherName;
    _dashboardNavigate = _goTo;
    _loadData();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
    _teacherDashboardRoute = _route;
  }

  @override
  void dispose() {
    if (_teacherDashboardRoute == _route) _teacherDashboardRoute = null;
    if (_dashboardNavigate == _goTo) _dashboardNavigate = null;
    super.dispose();
  }

  void _goTo(TeacherPage page) {
    if (!mounted) return;
    setState(() => _page = page);
  }

  Future<dynamic> _fetchBackendJson(String token, String path) async {
    try {
      final uri = Uri.parse('${ApiService.baseUrl}$path');
      final res = await http.get(
        uri,
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
      );
      if (res.statusCode >= 200 && res.statusCode < 300 && res.body.isNotEmpty) {
        return jsonDecode(res.body);
      }
    } catch (_) {}
    return null;
  }

  Future<_ExamAnalytics> _computeExamAnalytics(
    String token,
    _ExamInfo examInfo,
    JsonMap rawExam,
  ) async {
    final examId = examInfo.id!;

    JsonMap examMap = rawExam;
    try {
      examMap = await ApiService.getExamById(token, examId);
    } catch (_) {}

    List<JsonMap> sectionsList = [];
    try {
      sectionsList = await ApiService.getExamSections(token, examId);
    } catch (_) {}

    final attemptsData = await _fetchBackendJson(
      token,
      '/attempts?exam_id=$examId',
    );

    double maxPossiblePoints = 0;
    bool hasIdentification = false;
    final questionTypeById = <int, String>{};
    final questionNumberById = <int, int>{};
    final sectionNameByQuestionId = <int, String>{};

    final rawEmbeddedSections = examMap['sections'] ?? examMap['exam_sections'];
    final List<JsonMap> effectiveSections = [];
    if (sectionsList.isNotEmpty) {
      effectiveSections.addAll(sectionsList);
    } else if (rawEmbeddedSections is List) {
      for (final item in rawEmbeddedSections) {
        if (item is Map) {
          effectiveSections.add(JsonMap.from(item));
        }
      }
    }

    for (final s in effectiveSections) {
      final secId = int.tryParse(s['id']?.toString() ?? '');
      final secType = (s['question_type'] ?? s['exam_type'] ?? s['type'] ?? '')
          .toString()
          .toLowerCase();
      final secName =
          (s['name'] ?? s['section_name'] ?? s['title'] ?? secType).toString();
      final defaultPts = double.tryParse(
            (s['default_points'] ?? s['item_weight'] ?? 1).toString(),
          ) ??
          1.0;

      if (secType.contains('ident')) hasIdentification = true;

      final List<JsonMap> qList = [];
      if (s['questions'] is List) {
        for (final item in s['questions'] as List) {
          if (item is Map) {
            qList.add(JsonMap.from(item));
          }
        }
      } else if (secId != null) {
        try {
          final fetched = await ApiService.getQuestions(token, secId);
          qList.addAll(fetched);
        } catch (_) {}
      }

      for (final q in qList) {
        final qId = int.tryParse(q['id']?.toString() ?? '');
        final qNo = int.tryParse(
              (q['question_number'] ?? q['question_no'] ?? q['number'] ?? '')
                  .toString(),
            ) ??
            0;
        final pts =
            double.tryParse((q['points'] ?? defaultPts).toString()) ?? defaultPts;
        final qType = (q['question_type'] ?? q['exam_type'] ?? secType)
            .toString()
            .toLowerCase();

        if (qType.contains('ident')) hasIdentification = true;
        maxPossiblePoints += pts;

        if (qId != null) {
          questionTypeById[qId] = qType;
          questionNumberById[qId] = qNo;
          sectionNameByQuestionId[qId] = secName;
        }
      }
    }

    if (maxPossiblePoints <= 0) {
      maxPossiblePoints = double.tryParse(
            (examMap['total_points'] ??
                    rawExam['total_points'] ??
                    rawExam['total_items'] ??
                    100)
                .toString(),
          ) ??
          100.0;
    }

    List<dynamic> attemptsList = [];
    if (attemptsData is List) {
      attemptsList = attemptsData;
    } else if (attemptsData is Map) {
      final inner = attemptsData['attempts'] ??
          attemptsData['data'] ??
          attemptsData['results'];
      if (inner is List) attemptsList = inner;
    }
    if (attemptsList.isEmpty && examMap['attempts'] is List) {
      attemptsList = examMap['attempts'] as List;
    }

    final percentages = <double>[];
    final itemCorrect = <int, int>{};
    final itemTotal = <int, int>{};
    final sectionCorrect = <String, int>{};
    final sectionTotal = <String, int>{};
    int idFlagged = 0;
    int omrFlagged = 0;

    for (final att in attemptsList) {
      if (att is! Map) continue;

      final score = double.tryParse(
            (att['total_score'] ?? att['score'] ?? 0).toString(),
          ) ??
          0.0;
      final attMax = double.tryParse(
            (att['max_score'] ?? att['total_points'] ?? maxPossiblePoints)
                .toString(),
          ) ??
          maxPossiblePoints;
      final pct = attMax > 0 ? (score / attMax) * 100.0 : 0.0;
      percentages.add(pct);

      final answers = att['answers'] ?? att['student_answers'];
      if (answers is List) {
        bool paperHasIdReview = false;
        bool paperHasOmrReview = false;

        for (final ans in answers) {
          if (ans is! Map) continue;
          final qId =
              int.tryParse((ans['question_id'] ?? ans['id'] ?? '').toString());
          final qNo = int.tryParse(
                (ans['question_number'] ?? ans['question_no'] ?? '').toString(),
              ) ??
              (qId != null ? (questionNumberById[qId] ?? 0) : 0);
          final key = qNo > 0 ? qNo : (qId ?? 0);

          final isCorrect = ans['is_correct'] == true ||
              ans['is_correct']?.toString() == 'true' ||
              ans['is_correct'] == 1;

          if (key > 0) {
            itemTotal[key] = (itemTotal[key] ?? 0) + 1;
            if (isCorrect) {
              itemCorrect[key] = (itemCorrect[key] ?? 0) + 1;
            }
          }

          final secName = qId != null ? sectionNameByQuestionId[qId] : null;
          if (secName != null && secName.isNotEmpty) {
            sectionTotal[secName] = (sectionTotal[secName] ?? 0) + 1;
            if (isCorrect) {
              sectionCorrect[secName] = (sectionCorrect[secName] ?? 0) + 1;
            }
          }

          final status = (ans['status'] ?? ans['verification_status'] ?? '')
              .toString()
              .toLowerCase();
          final recognized =
              (ans['recognized_text'] ?? ans['answer'] ?? '').toString().trim();
          final qType = (ans['question_type'] ??
                  ans['exam_type'] ??
                  (qId != null ? questionTypeById[qId] : '') ??
                  '')
              .toString()
              .toLowerCase();

          if (status.contains('review') ||
              status.contains('ambiguous') ||
              status.contains('multiple') ||
              recognized.isEmpty) {
            if (qType.contains('ident')) {
              paperHasIdReview = true;
            } else {
              paperHasOmrReview = true;
            }
          }
        }

        if (paperHasIdReview) idFlagged++;
        if (paperHasOmrReview) omrFlagged++;
      }
    }

    int lowAccuracyCount = 0;
    final missedQNums = <int>[];
    itemTotal.forEach((qNum, total) {
      if (total > 0) {
        final corr = itemCorrect[qNum] ?? 0;
        final pValue = corr / total;
        if (pValue < 0.40) {
          lowAccuracyCount++;
          missedQNums.add(qNum);
        }
      }
    });
    missedQNums.sort();

    String? lowestSec;
    double? lowestSecPct;
    sectionTotal.forEach((sec, total) {
      if (total > 0) {
        final pct = ((sectionCorrect[sec] ?? 0) / total) * 100.0;
        if (lowestSecPct == null || pct < lowestSecPct!) {
          lowestSecPct = pct;
          lowestSec = sec;
        }
      }
    });

    final bool activeExam = !_isDone(examInfo.status);
    final int unscanned = activeExam
        ? math.max(0, examInfo.students - attemptsList.length)
        : 0;

    return _ExamAnalytics(
      examId: examId,
      examTitle: examInfo.title,
      attemptPercentages: percentages,
      lowAccuracyItemCount: lowAccuracyCount,
      missedQuestionNumbers: missedQNums,
      hasIdentificationSection: hasIdentification,
      lowestSectionName: lowestSec,
      lowestSectionAvg: lowestSecPct,
      idReviewCount: idFlagged,
      omrReviewCount: omrFlagged,
      pendingScanCount: unscanned,
    );
  }

  Future<void> _loadData({bool silent = false}) async {
    if (!mounted) return;
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    try {
      final token = await AuthStorage.getToken();
      if (token == null || token.isEmpty) {
        throw Exception('Your session has expired. Please log in again.');
      }

      final results = await Future.wait([
        ApiService.getClasses(token),
        ApiService.getExams(token),
      ]);
      final rawClasses = results[0];
      final rawExams = results[1];

      final counts = <String, int>{};
      await Future.wait(rawClasses.map((c) async {
        final id = int.tryParse(c['id']?.toString() ?? '');
        if (id == null) return;
        final students = await ApiService.getStudents(token, classId: id);
        counts[id.toString()] = students.length;
      }));

      String codeForExam(JsonMap e) {
        final cd = e['class'];
        return cd is Map ? _classCode(JsonMap.from(cd)) : '';
      }

      int studentCountForExam(JsonMap e) {
        final rawIds = e['class_ids'];
        if (rawIds is List && rawIds.isNotEmpty) {
          int sum = 0;
          for (final cid in rawIds) {
            sum += counts[cid.toString()] ?? 0;
          }
          if (sum > 0) return sum;
        }
        final cd = e['class'];
        final classId = cd is Map ? cd['id']?.toString() : null;
        return counts[e['class_id']?.toString() ?? classId ?? ''] ?? 0;
      }

      final exams = <_ExamInfo>[];
      final rawExamById = <int, JsonMap>{};

      for (final e in rawExams) {
        final id = int.tryParse(e['id']?.toString() ?? '');
        final info = _ExamInfo(
          id: id,
          title: e['title']?.toString() ?? 'Untitled exam',
          code: codeForExam(e),
          date: (e['created_at']?.toString() ?? '').split('T').first,
          students: studentCountForExam(e),
          status: _prettyStatus(e['status']?.toString()),
        );
        exams.add(info);
        if (id != null) rawExamById[id] = e;
      }

      final analyticsMap = <int, _ExamAnalytics>{};
      await Future.wait(
        exams.where((e) => e.id != null).map((e) async {
          final a = await _computeExamAnalytics(
            token,
            e,
            rawExamById[e.id!] ?? const {},
          );
          analyticsMap[e.id!] = a;
        }),
      );

      if (!mounted) return;
      setState(() {
        _exams = exams;
        _analyticsByExam = analyticsMap;
        if (_selectedAnalyticsExamId != null &&
            !_analyticsByExam.containsKey(_selectedAnalyticsExamId)) {
          _selectedAnalyticsExamId = null;
        }
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      if (silent) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _loading = false;
      });
    }
  }

  Future<void> _logout() => _performLogout(context);

  Future<void> _select(TeacherPage page) async {
    final screen = _moduleScreenFor(page);
    if (screen != null) {
      await Navigator.push(context, _shellRoute(page, screen));
      if (mounted) _loadData(silent: true);
      return;
    }

    setState(() => _page = page);
  }

  Future<void> _openExamBuilder(int? examId) async {
    final screen = ExamsTab(
      key: examId != null ? ValueKey('builder-$examId') : null,
      initialExamId: examId,
    );
    await Navigator.push(context, _shellRoute(TeacherPage.exams, screen));
    if (mounted) _loadData(silent: true);
  }

  Widget _body() {
    if (_page == TeacherPage.dashboard) {
      final metrics = _DashboardMetrics.fromExams(
        _exams,
        _analyticsByExam,
        selectedExamId: _selectedAnalyticsExamId,
      );
      return _DashboardContent(
        teacherName: widget.teacherName,
        onNavigate: _select,
        onOpenExam: _openExamBuilder,
        loading: _loading,
        error: _error,
        onRetry: _loadData,
        exams: _exams,
        metrics: metrics,
        selectedExamId: _selectedAnalyticsExamId,
        onSelectExamId: (id) => setState(() => _selectedAnalyticsExamId = id),
      );
    }
    return _PlaceholderPage(page: _page);
  }

  @override
  Widget build(BuildContext context) {
    return TeacherShell(
      current: _page,
      onSelect: _select,
      onLogout: _logout,
      desktopHeader: const _DesktopTopBar(),
      mobileActions: const [_NotificationBell(onDark: true)],
      child: _body(),
    );
  }
}

class _DesktopTopBar extends StatelessWidget {
  const _DesktopTopBar({
    this.hint = 'Search classes, exams, students',
    this.onSearchChanged,
  });

  final String hint;
  final ValueChanged<String>? onSearchChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: CmColors.line)),
      ),
      child: Row(
        children: [
          ValueListenableBuilder<bool>(
            valueListenable: _sidebarCollapsed,
            builder: (context, collapsed, _) {
              return IconButton(
                tooltip: collapsed ? 'Expand sidebar' : 'Collapse sidebar',
                icon: Icon(
                  collapsed ? Icons.chevron_right : Icons.chevron_left,
                  color: CmColors.slate,
                ),
                onPressed: () => _sidebarCollapsed.value = !collapsed,
              );
            },
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: TextField(
                  onChanged: onSearchChanged,
                  style: const TextStyle(color: CmColors.navy),
                  decoration: InputDecoration(
                    hintText: hint,
                    hintStyle:
                        const TextStyle(color: CmColors.slate, fontSize: 14),
                    prefixIcon:
                        const Icon(Icons.search, color: CmColors.slate),
                    isDense: true,
                    filled: true,
                    fillColor: CmColors.bg,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: CmColors.line),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: CmColors.line),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide:
                          const BorderSide(color: _Pal.sidebar, width: 1.5),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const _NotificationBell(),
          const SizedBox(width: 8),
        ],
      ),
    );
  }
}

class _NotificationBell extends StatelessWidget {
  const _NotificationBell({this.onDark = false});
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Notifications',
      onPressed: () => _soon(context, 'Notifications'),
      icon: Stack(
        clipBehavior: Clip.none,
        children: [
          Icon(
            Icons.notifications_none,
            color: onDark ? _Pal.sidebarFg : CmColors.navy,
          ),
          Positioned(
            right: -1,
            top: -1,
            child: Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(
                color: _Pal.notifDot,
                shape: BoxShape.circle,
                border: Border.all(
                  color: onDark ? _Pal.sidebar : Colors.white,
                  width: 1.5,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlaceholderPage extends StatelessWidget {
  const _PlaceholderPage({required this.page});
  final TeacherPage page;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(page.icon, size: 56, color: CmColors.slate),
            const SizedBox(height: 16),
            Text(page.label,
                style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: CmColors.navy)),
            const SizedBox(height: 8),
            const Text('This section is not built yet.',
                style: TextStyle(color: CmColors.slate)),
          ],
        ),
      ),
    );
  }
}

class _DashboardContent extends StatelessWidget {
  const _DashboardContent({
    required this.teacherName,
    required this.onNavigate,
    required this.onOpenExam,
    required this.loading,
    required this.error,
    required this.onRetry,
    required this.exams,
    required this.metrics,
    required this.selectedExamId,
    required this.onSelectExamId,
  });

  final String teacherName;
  final ValueChanged<TeacherPage> onNavigate;
  final ValueChanged<int?> onOpenExam;
  final bool loading;
  final String? error;
  final VoidCallback onRetry;
  final List<_ExamInfo> exams;
  final _DashboardMetrics metrics;
  final int? selectedExamId;
  final ValueChanged<int?> onSelectExamId;

  static const _months = [
    'January', 'February', 'March', 'April', 'May', 'June', 'July',
    'August', 'September', 'October', 'November', 'December'
  ];
  static const _days = [
    'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday',
    'Sunday'
  ];

  String _today() {
    final d = DateTime.now();
    return '${_days[d.weekday - 1]}, ${_months[d.month - 1]} ${d.day}, ${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final pad = constraints.maxWidth >= _kTablet ? 32.0 : 16.0;

      return SingleChildScrollView(
        padding: EdgeInsets.all(pad),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1200),
            child: LayoutBuilder(builder: (context, inner) {
              final w = inner.maxWidth;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Welcome Back, $teacherName',
                    style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w700,
                      color: CmColors.navy,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(_today(),
                      style: const TextStyle(color: CmColors.slate)),
                  const SizedBox(height: 24),
                  if (loading)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 48),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (error != null)
                    _ErrorPanel(message: error!, onRetry: onRetry)
                  else ...[
                    _stats(w),
                    const SizedBox(height: 24),
                    _reviewAndAnalytics(context, w),
                    const SizedBox(height: 32),
                    _sectionHeader('Recent Examinations', 'View all',
                        () => onNavigate(TeacherPage.exams)),
                    const SizedBox(height: 12),
                    if (exams.isEmpty)
                      const _EmptyPanel('No examinations yet.')
                    else if (w >= 720)
                      _ExamTable(exams: exams, onOpenExam: onOpenExam)
                    else
                      _ExamCards(exams: exams, onOpenExam: onOpenExam),
                    const SizedBox(height: 16),
                  ],
                ],
              );
            }),
          ),
        ),
      );
    });
  }

  Widget _stats(double w) {
    final cols = w >= _kTablet ? 3 : 2;
    final completed = exams.where((e) => _isDone(e.status)).length;
    final active = exams.length - completed;
    return _grid(w, cols, [
      _StatCard(
        icon: Icons.assignment_outlined,
        value: '$active',
        label: 'Active Exams',
        note: 'Not yet finalized',
      ),
      _StatCard(
        icon: Icons.rate_review_outlined,
        value: '${metrics.totalForReview}',
        label: 'For Review',
        note: metrics.totalForReview == 0
            ? 'All sheets verified'
            : 'Pending scan or verification',
        color: CmColors.amber,
      ),
      _StatCard(
        icon: Icons.check_circle_outline,
        value: '$completed',
        label: 'Completed Exams',
        note: 'Finalized',
        color: CmColors.green,
      ),
    ]);
  }

  Widget _reviewAndAnalytics(BuildContext context, double w) {
    final review = _ReviewQueueCard(
      metrics: metrics,
      onReview: () {
        final targetExamId = metrics.firstReviewExamId;
        if (targetExamId != null) {
          openTeacherScansForExam(context, targetExamId);
        } else {
          onNavigate(TeacherPage.scans);
        }
      },
    );
    final analytics = _AnalyticsCard(
      exams: exams,
      metrics: metrics,
      selectedExamId: selectedExamId,
      onSelectExamId: onSelectExamId,
    );

    if (w >= _kDesktop) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(flex: 5, child: review),
          const SizedBox(width: 16),
          Expanded(flex: 6, child: analytics),
        ],
      );
    }
    return Column(
      children: [review, const SizedBox(height: 16), analytics],
    );
  }

  Widget _sectionHeader(String title, String? action, VoidCallback? onTap) {
    return Row(
      children: [
        Expanded(
          child: Text(title,
              style: const TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                  color: CmColors.navy)),
        ),
        if (action != null)
          TextButton(
            onPressed: onTap,
            child: Text(action,
                style: const TextStyle(
                    color: CmColors.navy, fontWeight: FontWeight.w700)),
          ),
      ],
    );
  }

  Widget _grid(double w, int cols, List<Widget> children) {
    const gap = 16.0;
    final itemW = (w - gap * (cols - 1)) / cols;
    return Wrap(
      spacing: gap,
      runSpacing: gap,
      children: [
        for (final c in children) SizedBox(width: itemW, child: c),
      ],
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child, this.padding = 20, this.borderColor});

  final Widget child;
  final double padding;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(padding),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor ?? CmColors.line),
      ),
      child: child,
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.icon,
    required this.value,
    required this.label,
    required this.note,
    this.color = CmColors.navy,
  });

  final IconData icon;
  final String value, label, note;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(value,
                    style: const TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.w700,
                        color: CmColors.navy,
                        height: 1.1)),
                const SizedBox(height: 4),
                Text(label,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, color: CmColors.navy)),
                const SizedBox(height: 2),
                Text(note,
                    style: const TextStyle(
                        fontSize: 12, color: CmColors.slate)),
              ],
            ),
          ),
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: color, size: 22),
          ),
        ],
      ),
    );
  }
}

class _ReviewQueueCard extends StatelessWidget {
  const _ReviewQueueCard({
    required this.metrics,
    required this.onReview,
  });

  final _DashboardMetrics metrics;
  final VoidCallback onReview;

  @override
  Widget build(BuildContext context) {
    final total = metrics.totalForReview;
    final headline = total == 1
        ? '1 answer sheet needs verification or scanning'
        : '$total answer sheets need verification or scanning';

    return _Panel(
      borderColor: CmColors.amber.withValues(alpha: 0.6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.rate_review_outlined, color: CmColors.amber),
              SizedBox(width: 8),
              Text('Review Queue',
                  style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: CmColors.navy)),
            ],
          ),
          const SizedBox(height: 4),
          const Text('Live verification & scanning queue across active exams',
              style: TextStyle(fontSize: 12, color: CmColors.slate)),
          const SizedBox(height: 12),
          Text(headline,
              style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: CmColors.navy)),
          const SizedBox(height: 16),
          _ReviewRow(
            icon: Icons.edit_note,
            title: 'Identification recognition',
            engine: 'Microsoft Azure AI Vision',
            count: metrics.idReviewPapers,
          ),
          _ReviewRow(
            icon: Icons.radio_button_checked,
            title: 'Low-confidence / multiple bubbles',
            engine: 'OpenCV OMR',
            count: metrics.omrReviewPapers,
          ),
          _ReviewRow(
            icon: Icons.document_scanner_outlined,
            title: 'Unscanned roster sheets',
            engine: 'Awaiting camera scan or upload',
            count: metrics.unscannedPapers,
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: FilledButton(
              onPressed: onReview,
              style: FilledButton.styleFrom(
                backgroundColor: CmColors.amber,
                foregroundColor: CmColors.navy,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('Review now',
                  style: TextStyle(fontWeight: FontWeight.w700)),
            ),
          ),
        ],
      ),
    );
  }
}

class _ReviewRow extends StatelessWidget {
  const _ReviewRow({
    required this.icon,
    required this.title,
    required this.engine,
    required this.count,
  });

  final IconData icon;
  final String title, engine;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Icon(icon, size: 20, color: CmColors.slate),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, color: CmColors.navy)),
                Text(engine,
                    style: const TextStyle(
                        fontSize: 12, color: CmColors.slate)),
              ],
            ),
          ),
          Text('$count ${count == 1 ? 'paper' : 'papers'}',
              style: const TextStyle(
                  fontWeight: FontWeight.w700, color: CmColors.navy)),
        ],
      ),
    );
  }
}

class _AnalyticsCard extends StatelessWidget {
  const _AnalyticsCard({
    required this.exams,
    required this.metrics,
    required this.selectedExamId,
    required this.onSelectExamId,
  });

  final List<_ExamInfo> exams;
  final _DashboardMetrics metrics;
  final int? selectedExamId;
  final ValueChanged<int?> onSelectExamId;

  @override
  Widget build(BuildContext context) {
    final buckets = metrics.buckets;
    final rawMax = buckets.values.isEmpty
        ? 0
        : buckets.values.reduce((a, b) => a > b ? a : b);
    final maxCount = rawMax > 0 ? rawMax : 1;

    final hasAttempts = metrics.totalAttempts > 0;
    final avgText =
        hasAttempts ? '${metrics.averagePercent.toStringAsFixed(1)}%' : '—';
    final highText =
        hasAttempts ? '${metrics.highestPercent.toStringAsFixed(0)}%' : '—';
    final lowText =
        hasAttempts ? '${metrics.lowestPercent.toStringAsFixed(0)}%' : '—';

    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Score Distribution',
                        style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: CmColors.navy)),
                    SizedBox(height: 2),
                    Text('Live class performance & item difficulty insights',
                        style: TextStyle(fontSize: 12, color: CmColors.slate)),
                  ],
                ),
              ),
              if (exams.isNotEmpty)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 210),
                  child: DropdownButtonHideUnderline(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 2),
                      decoration: BoxDecoration(
                        color: CmColors.bg,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: CmColors.line),
                      ),
                      child: DropdownButton<int?>(
                        value: selectedExamId,
                        isDense: true,
                        isExpanded: true,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: CmColors.navy,
                        ),
                        items: [
                          const DropdownMenuItem<int?>(
                            value: null,
                            child: Text('All Examinations',
                                overflow: TextOverflow.ellipsis),
                          ),
                          for (final e in exams.where((x) => x.id != null))
                            DropdownMenuItem<int?>(
                              value: e.id,
                              child: Text(e.title,
                                  overflow: TextOverflow.ellipsis),
                            ),
                        ],
                        onChanged: onSelectExamId,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 24,
            runSpacing: 8,
            children: [
              _MiniStat('Class average', avgText),
              _MiniStat('Highest', highText),
              _MiniStat('Lowest', lowText),
              _MiniStat('Checked', '${metrics.totalAttempts}'),
            ],
          ),
          const SizedBox(height: 20),
          SizedBox(
            height: 140,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final e in buckets.entries)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Text('${e.value}',
                              style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: CmColors.navy)),
                          const SizedBox(height: 4),
                          Container(
                            height:
                                e.value == 0 ? 4 : (90 * e.value / maxCount),
                            decoration: BoxDecoration(
                              color: e.value == 0
                                  ? CmColors.line
                                  : CmColors.navy,
                              borderRadius: BorderRadius.circular(6),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(e.key,
                              style: const TextStyle(
                                  fontSize: 11, color: CmColors.slate)),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: CmColors.amber.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Icon(
                  metrics.lowAccuracyItems > 0
                      ? Icons.warning_amber_rounded
                      : Icons.lightbulb_outline_rounded,
                  size: 20,
                  color: CmColors.amber,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    metrics.insightBannerText,
                    style: const TextStyle(fontSize: 13, color: CmColors.navy),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat(this.label, this.value);
  final String label, value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value,
            style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: CmColors.navy)),
        Text(label,
            style: const TextStyle(fontSize: 12, color: CmColors.slate)),
      ],
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip(this.status);
  final String status;

  Color get _color {
    switch (status) {
      case 'Completed':
      case 'Finalized':
        return CmColors.green;
      case 'Needs Review':
      case 'Processing':
        return CmColors.amber;
      default:
        return CmColors.slate;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _color;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: c, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            status,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: c == CmColors.slate
                  ? CmColors.navy
                  : HSLColor.fromColor(c).withLightness(0.28).toColor(),
            ),
          ),
        ],
      ),
    );
  }
}

class _ExamTable extends StatelessWidget {
  const _ExamTable({required this.exams, required this.onOpenExam});
  final List<_ExamInfo> exams;
  final ValueChanged<int?> onOpenExam;

  static const _head = TextStyle(
      fontSize: 12, fontWeight: FontWeight.w700, color: CmColors.slate);

  @override
  Widget build(BuildContext context) {
    return _Panel(
      padding: 8,
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Row(
              children: [
                Expanded(flex: 4, child: Text('Examination', style: _head)),
                Expanded(flex: 2, child: Text('Class Code', style: _head)),
                Expanded(flex: 2, child: Text('Date', style: _head)),
                Expanded(flex: 1, child: Text('Students', style: _head)),
                Expanded(flex: 2, child: Text('Status', style: _head)),
                SizedBox(width: 90),
              ],
            ),
          ),
          for (final e in exams) ...[
            const Divider(height: 1, color: CmColors.line),
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              child: Row(
                children: [
                  Expanded(
                    flex: 4,
                    child: Text(e.title,
                        style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            color: CmColors.navy)),
                  ),
                  Expanded(flex: 2, child: Text(e.code)),
                  Expanded(flex: 2, child: Text(e.date)),
                  Expanded(flex: 1, child: Text('${e.students}')),
                  Expanded(
                    flex: 2,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: _StatusChip(e.status),
                    ),
                  ),
                  SizedBox(
                    width: 90,
                    child: TextButton(
                      onPressed: () => onOpenExam(e.id),
                      child: Text(
                        e.status == 'Needs Review' ? 'Review' : 'Open',
                        style: const TextStyle(
                            color: CmColors.navy,
                            fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ExamCards extends StatelessWidget {
  const _ExamCards({required this.exams, required this.onOpenExam});
  final List<_ExamInfo> exams;
  final ValueChanged<int?> onOpenExam;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final e in exams)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _Panel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(e.title,
                            style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: CmColors.navy)),
                      ),
                      _StatusChip(e.status),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${e.code}  |  ${e.date}  |  ${e.students} students',
                    style: const TextStyle(
                        fontSize: 13, color: CmColors.slate),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    height: 44,
                    child: OutlinedButton(
                      onPressed: () => onOpenExam(e.id),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: CmColors.navy,
                        side: const BorderSide(color: CmColors.line),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      child: Text(
                        e.status == 'Needs Review' ? 'Review' : 'Open',
                        style:
                            const TextStyle(fontWeight: FontWeight.w700),
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
}

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Column(
        children: [
          const Icon(Icons.error_outline, size: 40, color: CmColors.slate),
          const SizedBox(height: 12),
          Text(message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: CmColors.navy)),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: onRetry,
            style: FilledButton.styleFrom(backgroundColor: CmColors.navy),
            child: const Text('Try again'),
          ),
        ],
      ),
    );
  }
}

class _EmptyPanel extends StatelessWidget {
  const _EmptyPanel(this.message);
  final String message;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: SizedBox(
        width: double.infinity,
        child: Text(message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: CmColors.slate)),
      ),
    );
  }
}
// END OF FILE
