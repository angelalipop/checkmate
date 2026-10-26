import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/api_service.dart';
import '../services/auth_storage.dart';
import 'answer_sheet_input_screen.dart';
import 'exams_tab.dart';
import 'login_screen.dart' show CmColors, LoginScreen;

// =============================================================
// CheckMate — Teacher app shell + Dashboard home
//
// TeacherShell wraps every teacher screen (same pattern as AdminShell):
//   Desktop  (>= 900):  navy sidebar (256px) that collapses to an
//                       80px icon rail. The collapse state is shared, so
//                       it persists across every tab / module screen.
//   Tablet / phone:     navy top bar (hamburger + logo) and a
//                       full-height overlay drawer. Closes via the close
//                       button, backdrop tap, Escape, or after navigating.
//                       Phones also keep the bottom navigation bar.
//
// Module screens (Exams, Scans) are NOT modified. They are simply
// wrapped by TeacherShell when pushed.
//
// Classes and exams come from ApiService. Review queue and analytics
// are still sample data (no backend endpoints yet).
// =============================================================

const double _kDesktop = 900;
const double _kTablet = 600;
const double _kSidebarWide = 256;
const double _kSidebarRail = 80;

// =============================================================
// SIDEBAR PALETTE
// =============================================================

class _Pal {
  _Pal._();

  /// Sidebar + mobile top bar background (expanded and collapsed).
  static const Color sidebar = Color(0xFF162137);

  /// Active / hovered sidebar item.
  static const Color sidebarActive = Color(0xFF2D384D);

  /// Sidebar text and icons.
  static const Color sidebarFg = Color(0xFFCFD8E5);

  /// Notification dot (amber).
  static const Color notifDot = Color(0xFFF7A224);

  /// Divider above Profile / Log out (white at 12% opacity).
  static final Color divider = Colors.white.withValues(alpha: 0.12);
}

/// Persists the sidebar collapse state across screens for the session.
final ValueNotifier<bool> _sidebarCollapsed = ValueNotifier<bool>(false);

/// The dashboard's route, so sidebar items in module screens can return to
/// it without popping past it (which would land on the login screen).
Route<dynamic>? _teacherDashboardRoute;

/// Lets a module screen's shell ask the dashboard to switch tab.
void Function(TeacherPage page)? _dashboardNavigate;

// =============================================================
// DESTINATIONS
// =============================================================

enum TeacherPage {
  dashboard('Dashboard', Icons.space_dashboard_outlined),
  classes('My Classes', Icons.class_outlined),
  exams('Exams', Icons.assignment_outlined),
  scans('Scans', Icons.document_scanner_outlined),
  results('Results', Icons.fact_check_outlined),
  analytics('Analytics', Icons.insights_outlined),
  reports('Reports', Icons.summarize_outlined);

  const TeacherPage(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// Pages shown in the phone bottom navigation bar (a 5th "More" opens the
/// drawer).
const List<TeacherPage> _bottomPages = [
  TeacherPage.dashboard,
  TeacherPage.classes,
  TeacherPage.exams,
  TeacherPage.scans,
];

// ---------- Placeholder data ----------

const _scoreBuckets = <String, int>{
  '0-59': 3,
  '60-69': 5,
  '70-79': 11,
  '80-89': 10,
  '90-100': 6,
};

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

String _classCode(Map<String, dynamic> c) {
  final subject = c['subject'];
  final code = subject is Map ? subject['code']?.toString() ?? '' : '';
  final section = c['section']?.toString() ?? '';
  return [code, section].where((e) => e.isNotEmpty).join(' - ');
}

class _ClassInfo {
  const _ClassInfo({
    required this.id,
    required this.subject,
    required this.section,
    required this.code,
    required this.students,
    required this.recentExam,
    required this.status,
  });

  final int? id;
  final String subject, section, code;
  final String? recentExam, status;
  final int students;
}

class _ExamInfo {
  const _ExamInfo({
    required this.title,
    required this.code,
    required this.date,
    required this.students,
    required this.status,
  });

  final String title, code, date, status;
  final int students;
}

// =============================================================
// SIGNED-IN USER (shown at the bottom of the navigation panel)
// =============================================================

class _TeacherIdentity {
  static String? name;
  static String? email;

  /// Used when the stored token has no name.
  static String fallbackName = 'Teacher';
  static bool _loaded = false;

  /// Reads name/email from the stored JWT payload (no network call).
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
    } catch (_) {
      // Fall back to defaults.
    }
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

// =============================================================
// NAVIGATION HELPERS
// =============================================================

/// Teacher-facing module screens:
///  - Exams: ExamsTab (exam list -> in-place collapsible builder with inline
///    questions, paper preview popup, PDF print/download).
///  - Scans: AnswerSheetInputScreen -> camera/upload -> OMR -> scoring.
Widget? _moduleScreenFor(TeacherPage page) {
  switch (page) {
    case TeacherPage.exams:
      return const ExamsTab();
    case TeacherPage.scans:
      return const AnswerSheetInputScreen();
    default:
      return null; // shown inside the dashboard body
  }
}

/// No transition: the shell (sidebar + header) stays visually in place, so
/// switching to Exams / Scans feels exactly like switching a dashboard tab.
Route<void> _shellRoute(TeacherPage page, Widget screen) {
  return PageRouteBuilder<void>(
    transitionDuration: Duration.zero,
    reverseTransitionDuration: Duration.zero,
    pageBuilder: (_, _, _) => _ModuleShell(page: page, child: screen),
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

/// Wraps an existing, unmodified module screen with the shared shell.
class _ModuleShell extends StatelessWidget {
  const _ModuleShell({required this.page, required this.child});

  final TeacherPage page;
  final Widget child;

  void _select(BuildContext context, TeacherPage target) {
    if (target == page) return;

    // Another module screen: swap it in, keeping the same shell.
    final screen = _moduleScreenFor(target);
    if (screen != null) {
      Navigator.of(context).pushReplacement(_shellRoute(target, screen));
      return;
    }

    // A tab that lives inside the dashboard: return to the dashboard route
    // itself (never pop past it) and switch its tab.
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
    // The Exams tab uses the same top bar (sidebar toggle, search, bell) as
    // the dashboard. Scans keeps its own screen header.
    final hasHeader = page == TeacherPage.exams;
    return TeacherShell(
      current: page,
      onSelect: (p) => _select(context, p),
      onLogout: () => _performLogout(context),
      desktopHeader: hasHeader ? const _DesktopTopBar() : null,
      mobileActions:
          hasHeader ? const [_NotificationBell(onDark: true)] : const [],
      child: child,
    );
  }
}

// =============================================================
// APP SHELL
// =============================================================

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

  /// Optional bar shown above the content on desktop (dashboard only).
  final Widget? desktopHeader;

  /// Optional actions on the right of the mobile top bar.
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
    _closeDrawer(); // always close after navigating
    widget.onSelect(page);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;

        // ---------- Desktop ----------
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
                        // When the page has its own header, the toggle lives there.
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

        // ---------- Tablet / phone ----------
        final isMobile = w < _kTablet;
        final bottomIndex = _bottomPages.indexOf(widget.current);

        // The drawer sits above the whole Scaffold so it also covers the
        // bottom navigation bar.
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
                // Dimmed backdrop — tap to close.
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

// =============================================================
// MOBILE TOP BAR
// =============================================================

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

// =============================================================
// SIDEBAR
// =============================================================

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
  final VoidCallback? onClose; // non-null => drawer mode

  @override
  Widget build(BuildContext context) {
    return Container(
      color: _Pal.sidebar,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Hide labels while the width animation is still narrow.
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
      // Icon-only rail: circular logo (+ toggle when this page has none).
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

// =============================================================
// SCREEN (dashboard home + in-dashboard tabs)
// =============================================================

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
  List<_ClassInfo> _classes = [];
  List<_ExamInfo> _exams = [];

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

  /// Called by a module screen's shell to land on a dashboard tab.
  void _goTo(TeacherPage page) {
    if (!mounted) return;
    setState(() => _page = page);
  }

  // The backend must return only this teacher's classes/exams.
  // Nothing here filters by teacher on the client.
  Future<void> _loadData({bool silent = false}) async {
    if (!mounted) return;
    // A silent refresh keeps the current content on screen (no spinner flash).
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

      // Student count per class.
      final counts = <String, int>{};
      await Future.wait(rawClasses.map((c) async {
        final id = int.tryParse(c['id']?.toString() ?? '');
        if (id == null) return;
        final students = await ApiService.getStudents(token, classId: id);
        counts[id.toString()] = students.length;
      }));

      String codeForExam(Map<String, dynamic> e) {
        final cd = e['class'];
        return cd is Map ? _classCode(Map<String, dynamic>.from(cd)) : '';
      }

      final exams = rawExams.map((e) {
        final cd = e['class'];
        final classId = cd is Map ? cd['id']?.toString() : null;
        return _ExamInfo(
          title: e['title']?.toString() ?? 'Untitled exam',
          code: codeForExam(e),
          date: (e['created_at']?.toString() ?? '').split('T').first,
          students: counts[e['class_id']?.toString() ?? classId ?? ''] ?? 0,
          status: _prettyStatus(e['status']?.toString()),
        );
      }).toList();

      final classes = rawClasses.map((c) {
        final subject = c['subject'];
        final id = int.tryParse(c['id']?.toString() ?? '');
        final title = c['title'];
        // Most recent exam for this class (list order from the API).
        final recent = rawExams.where((e) {
          final cd = e['class'];
          final eid = e['class_id']?.toString() ??
              (cd is Map ? cd['id']?.toString() : null);
          return eid != null && eid == c['id']?.toString();
        });
        return _ClassInfo(
          id: id,
          subject: subject is Map
              ? subject['name']?.toString() ?? 'Subject'
              : (title?.toString() ?? 'Subject'),
          section: c['section']?.toString() ?? '',
          code: _classCode(c),
          students: counts[c['id']?.toString() ?? ''] ?? 0,
          recentExam: recent.isEmpty ? null : recent.first['title']?.toString(),
          status: recent.isEmpty
              ? null
              : _prettyStatus(recent.first['status']?.toString()),
        );
      }).toList();

      if (!mounted) return;
      setState(() {
        _classes = classes;
        _exams = exams;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      if (silent) return; // keep showing the last good data
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _loading = false;
      });
    }
  }


  Future<void> _logout() => _performLogout(context);

  Future<void> _select(TeacherPage page) async {
    // Exams / Scans have their own full-screen Scaffold/AppBar, so they are
    // opened as routes — wrapped in the same shell so the sidebar (and its
    // collapse state) stays consistent.
    final screen = _moduleScreenFor(page);
    if (screen != null) {
      await Navigator.push(context, _shellRoute(page, screen));
      // Refresh exams/statuses after creating, building or scanning.
      if (mounted) _loadData(silent: true);
      return;
    }

    setState(() => _page = page);
  }

  Widget _body() {
    if (_page == TeacherPage.dashboard) {
      return _DashboardContent(
        teacherName: widget.teacherName,
        onNavigate: _select,
        loading: _loading,
        error: _error,
        onRetry: _loadData,
        classes: _classes,
        exams: _exams,
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

// =============================================================
// TOP BAR (desktop) + shared bits
// =============================================================

class _DesktopTopBar extends StatelessWidget {
  const _DesktopTopBar();

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
                  style: const TextStyle(color: CmColors.navy),
                  decoration: InputDecoration(
                    hintText: 'Search classes, exams, students',
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

// =============================================================
// DASHBOARD CONTENT
// =============================================================

class _DashboardContent extends StatelessWidget {
  const _DashboardContent({
    required this.teacherName,
    required this.onNavigate,
    required this.loading,
    required this.error,
    required this.onRetry,
    required this.classes,
    required this.exams,
  });

  final String teacherName;
  final ValueChanged<TeacherPage> onNavigate;
  final bool loading;
  final String? error;
  final VoidCallback onRetry;
  final List<_ClassInfo> classes;
  final List<_ExamInfo> exams;

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
                  _sectionHeader('My Classes', 'View all',
                      () => onNavigate(TeacherPage.classes)),
                  const SizedBox(height: 12),
                  if (classes.isEmpty)
                    const _EmptyPanel(
                        'No classes assigned yet. Your administrator assigns Class Codes to you.')
                  else
                    _grid(
                      w,
                      w >= 1000 ? 3 : (w >= _kTablet ? 2 : 1),
                      [for (final c in classes) _ClassCard(info: c)],
                    ),
                  const SizedBox(height: 32),
                  _sectionHeader('Recent Examinations', 'View all',
                      () => onNavigate(TeacherPage.exams)),
                  const SizedBox(height: 12),
                  if (exams.isEmpty)
                    const _EmptyPanel('No examinations yet.')
                  else if (w >= 720)
                    _ExamTable(exams: exams)
                  else
                    _ExamCards(exams: exams),
                  const SizedBox(height: 32),
                  _sectionHeader('Reports', null, null),
                  const SizedBox(height: 12),
                  _reports(context),
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

  // ---------- Stats ----------

  Widget _stats(double w) {
    final cols = w >= _kDesktop ? 4 : 2;
    final completed = exams.where((e) => _isDone(e.status)).length;
    final active = exams.length - completed;
    return _grid(w, cols, [
      _StatCard(
        icon: Icons.class_outlined,
        value: '${classes.length}',
        label: 'My Classes',
        note: 'Assigned by admin',
      ),
      _StatCard(
        icon: Icons.assignment_outlined,
        value: '$active',
        label: 'Active Exams',
        note: 'Not yet finalized',
      ),
      const _StatCard(
        icon: Icons.rate_review_outlined,
        value: '12',
        label: 'For Review',
        note: 'Sample data',
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

  // ---------- Review + Analytics ----------

  Widget _reviewAndAnalytics(BuildContext context, double w) {
    final review = _ReviewQueueCard(
      onReview: () => _soon(context, 'Verification screen'),
    );
    const analytics = _AnalyticsCard();

    if (w >= _kDesktop) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(flex: 5, child: review),
          const SizedBox(width: 16),
          const Expanded(flex: 6, child: analytics),
        ],
      );
    }
    return Column(
      children: [review, const SizedBox(height: 16), analytics],
    );
  }

  // ---------- Reports ----------

  Widget _reports(BuildContext context) {
    const items = [
      (Icons.description_outlined, 'Examination reports'),
      (Icons.person_outline, 'Student score reports'),
      (Icons.groups_outlined, 'Class performance'),
      (Icons.table_chart_outlined, 'Item analysis'),
      (Icons.event_available_outlined, 'Attendance'),
    ];
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        for (final (icon, label) in items)
          ActionChip(
            avatar: Icon(icon, size: 18, color: CmColors.navy),
            label: Text(label),
            labelStyle: const TextStyle(
                color: CmColors.navy, fontWeight: FontWeight.w600),
            backgroundColor: Colors.white,
            side: const BorderSide(color: CmColors.line),
            padding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            onPressed: () => _soon(context, label),
          ),
      ],
    );
  }

  // ---------- Layout helpers ----------

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

// =============================================================
// CARDS
// =============================================================

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
  const _ReviewQueueCard({required this.onReview});
  final VoidCallback onReview;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      borderColor: CmColors.amber.withValues(alpha: 0.6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.rate_review_outlined,
                  color: CmColors.amber),
              const SizedBox(width: 8),
              const Text('Review Queue',
                  style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: CmColors.navy)),
            ],
          ),
          const SizedBox(height: 4),
          const Text('Sample data until scanning is connected',
              style: TextStyle(fontSize: 12, color: CmColors.slate)),
          const SizedBox(height: 12),
          const Text('12 answer sheets need verification',
              style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: CmColors.navy)),
          const SizedBox(height: 16),
          const _ReviewRow(
              icon: Icons.edit_note,
              title: 'Identification recognition',
              engine: 'Google ML Kit',
              count: 8),
          const _ReviewRow(
              icon: Icons.radio_button_checked,
              title: 'Low-confidence bubbles',
              engine: 'OpenCV OMR',
              count: 3),
          const _ReviewRow(
              icon: Icons.image_not_supported_outlined,
              title: 'Unreadable scan',
              engine: 'Rescan needed',
              count: 1),
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
  const _AnalyticsCard();

  @override
  Widget build(BuildContext context) {
    final maxCount = _scoreBuckets.values.reduce((a, b) => a > b ? a : b);

    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Score Distribution',
              style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: CmColors.navy)),
          const SizedBox(height: 2),
          const Text('Sample data until results are connected',
              style: TextStyle(fontSize: 12, color: CmColors.slate)),
          const SizedBox(height: 16),
          Wrap(
            spacing: 24,
            runSpacing: 8,
            children: const [
              _MiniStat('Class average', '78.4'),
              _MiniStat('Highest', '98'),
              _MiniStat('Lowest', '46'),
            ],
          ),
          const SizedBox(height: 20),
          SizedBox(
            height: 140,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final e in _scoreBuckets.entries)
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
                            height: 90 * e.value / maxCount,
                            decoration: BoxDecoration(
                              color: CmColors.navy,
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
              children: const [
                Icon(Icons.warning_amber_rounded,
                    size: 20, color: CmColors.amber),
                SizedBox(width: 10),
                Expanded(
                  child: Text('3 items answered correctly by fewer than 40%',
                      style: TextStyle(
                          fontSize: 13, color: CmColors.navy)),
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

class _ClassCard extends StatelessWidget {
  const _ClassCard({required this.info});
  final _ClassInfo info;

  @override
  Widget build(BuildContext context) {
    return _Panel(
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
                    Text(info.subject,
                        style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: CmColors.navy)),
                    const SizedBox(height: 2),
                    Text(info.section,
                        style: const TextStyle(color: CmColors.slate)),
                  ],
                ),
              ),
              if (info.status != null) _StatusChip(info.status!),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              const Icon(Icons.tag, size: 16, color: CmColors.slate),
              const SizedBox(width: 6),
              Text('Class Code: ${info.code}',
                  style: const TextStyle(
                      fontSize: 13, color: CmColors.navy)),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              const Icon(Icons.people_outline,
                  size: 16, color: CmColors.slate),
              const SizedBox(width: 6),
              Text('${info.students} students',
                  style: const TextStyle(
                      fontSize: 13, color: CmColors.navy)),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              const Icon(Icons.assignment_outlined,
                  size: 16, color: CmColors.slate),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                    info.recentExam == null
                        ? 'No exams yet'
                        : 'Recent: ${info.recentExam}',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 13, color: CmColors.navy)),
              ),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            height: 44,
            child: OutlinedButton(
              onPressed: () => _soon(context, 'Class details'),
              style: OutlinedButton.styleFrom(
                foregroundColor: CmColors.navy,
                side: const BorderSide(color: CmColors.line),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('View class',
                  style: TextStyle(fontWeight: FontWeight.w700)),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================
// EXAMS: table (wide) and cards (narrow)
// =============================================================

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
      default: // Draft, Ready, Scanning
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
              // Darker text tone keeps contrast AA on the tinted background.
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
  const _ExamTable({required this.exams});
  final List<_ExamInfo> exams;

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
                      onPressed: () => _soon(context, 'Exam details'),
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
  const _ExamCards({required this.exams});
  final List<_ExamInfo> exams;

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
                      onPressed: () => _soon(context, 'Exam details'),
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