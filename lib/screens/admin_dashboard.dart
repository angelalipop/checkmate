import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/api_service.dart';
import '../services/auth_storage.dart';
import 'answer_sheet_input_screen.dart';
import 'classes_screen.dart';
import 'exams_screen.dart';
import 'login_screen.dart' show CmColors, LoginScreen;
import 'students_screen.dart';
import 'subjects_screen.dart';

// =============================================================
// CheckMate — Admin app shell + Dashboard home
//
// AdminShell wraps every admin screen:
//   Desktop  (>= 900):  navy sidebar (256px) that collapses to an
//                       80px icon rail. Collapse state persists while
//                       navigating (kept in a shared notifier).
//   Tablet / phone:     navy top bar (hamburger + logo) and a
//                       full-height overlay drawer. Closes via the close
//                       button, backdrop tap, Escape, or after navigating.
//
// Module screens (Subjects, Classes, ...) are NOT modified. They are
// simply wrapped by AdminShell when pushed.
// =============================================================

const double _kDesktop = 900;
const double _kTablet = 600;
const double _kSidebarWide = 256;
const double _kSidebarRail = 80;

/// Persists the sidebar collapse state across screens for the session.
final ValueNotifier<bool> _sidebarCollapsed = ValueNotifier<bool>(false);

/// The dashboard's route, so "Dashboard" in the sidebar can return to it
/// without popping past it (which previously landed on the login screen).
Route<dynamic>? _adminDashboardRoute;

/// Lets the shell ask the dashboard to refresh its counts.
VoidCallback? _refreshDashboard;

// =============================================================
// SIGNED-IN USER (shown at the bottom of the navigation panel)
// =============================================================

class _AdminIdentity {
  static String? name;
  static String? email;
  static bool _loaded = false;

  /// Reads name/email from the stored JWT payload (no network call).
  static Future<void> load() async {
    if (_loaded) return;
    try {
      final token = await AuthStorage.getToken();
      if (token == null || token.isEmpty) return;

      final parts = token.split('.');
      if (parts.length != 3) return;

      final payload =
          utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
      final decoded = jsonDecode(payload);

      if (decoded is Map) {
        final source = decoded['user'] is Map ? decoded['user'] as Map : decoded;
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
    _loaded = false;
  }

  static String initials(String n) {
    final parts =
        n.trim().split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
    if (parts.isEmpty) return 'AD';
    if (parts.length == 1) {
      return parts[0].substring(0, math.min(2, parts[0].length)).toUpperCase();
    }
    return (parts[0][0] + parts[1][0]).toUpperCase();
  }
}

// =============================================================
// THEME TOKENS (light + dark). All colors in this file come from here.
// =============================================================

class _Tk {
  const _Tk._(this.dark);
  final bool dark;

  factory _Tk.of(BuildContext context) =>
      _Tk._(Theme.of(context).brightness == Brightness.dark);

  Color get bg => dark ? const Color(0xFF0B1220) : CmColors.bg;
  Color get surface => dark ? const Color(0xFF111B2E) : Colors.white;
  Color get border => dark ? const Color(0xFF24324A) : CmColors.line;
  Color get text => dark ? const Color(0xFFF1F5F9) : CmColors.navy;
  Color get muted => dark ? const Color(0xFF94A3B8) : CmColors.slate;

  /// Deep navy for the sidebar / top bar.
  Color get navy => dark ? const Color(0xFF111C33) : const Color(0xFF1B2A4A);

  /// Muted (non-neon) green used for accents.
  Color get emerald =>
      dark ? const Color(0xFF3FA886) : const Color(0xFF2F8F72);
  Color get amber => CmColors.amber;
  Color get shadow => Colors.black.withValues(alpha: dark ? 0.30 : 0.05);
}

// =============================================================
// DESTINATIONS
// =============================================================

enum AdminPage {
  dashboard('Dashboard', Icons.space_dashboard_outlined),
  teachers('Teachers', Icons.people_outline),
  subjects('Subjects', Icons.library_books_outlined),
  classes('Classes', Icons.menu_book_outlined),
  students('Students', Icons.school_outlined),
  exams('Exams', Icons.assignment_outlined),
  scans('Scan Answer Sheet', Icons.document_scanner_outlined),
  attempts('Attempts', Icons.fact_check_outlined),
  results('Results', Icons.assessment_outlined);

  const AdminPage(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// Items shown in the navigation panel.
const List<AdminPage> _navPages = [
  AdminPage.dashboard,
  AdminPage.teachers,
  AdminPage.subjects,
  AdminPage.classes,
  AdminPage.students,
  AdminPage.exams,
];

Widget? _screenFor(AdminPage page) {
  switch (page) {
    case AdminPage.subjects:
      return const SubjectsScreen();
    case AdminPage.classes:
      return const ClassesScreen();
    case AdminPage.students:
      return const StudentsScreen();
    case AdminPage.exams:
      return const ExamsScreen();
    case AdminPage.scans:
      return const AnswerSheetInputScreen();
    default:
      return null; // dashboard / teachers / attempts / results
  }
}

Route<void> _shellRoute(AdminPage page, Widget screen) {
  return MaterialPageRoute<void>(
    builder: (_) => _ModuleShell(page: page, child: screen),
  );
}

Future<void> _performLogout(BuildContext context) async {
  await AuthStorage.deleteToken();
  _AdminIdentity.reset();
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

  final AdminPage page;
  final Widget child;

  void _select(BuildContext context, AdminPage target) {
    if (target == page) return;

    if (target == AdminPage.dashboard) {
      // Return to the dashboard route itself — never pop past it.
      final dashboard = _adminDashboardRoute;
      if (dashboard != null) {
        Navigator.of(context).popUntil((route) => route == dashboard);
      } else {
        Navigator.of(context).pop();
      }
      _refreshDashboard?.call();
      return;
    }

    final screen = _screenFor(target);
    if (screen == null) {
      _soon(context, target.label);
      return;
    }

    Navigator.of(context).pushReplacement(_shellRoute(target, screen));
  }

  @override
  Widget build(BuildContext context) {
    return AdminShell(
      current: page,
      onSelect: (p) => _select(context, p),
      onLogout: () => _performLogout(context),
      child: child,
    );
  }
}

// =============================================================
// APP SHELL
// =============================================================

class AdminShell extends StatefulWidget {
  const AdminShell({
    super.key,
    required this.current,
    required this.onSelect,
    required this.onLogout,
    required this.child,
    this.desktopHeader,
    this.mobileActions = const [],
  });

  final AdminPage current;
  final ValueChanged<AdminPage> onSelect;
  final VoidCallback onLogout;
  final Widget child;

  /// Optional bar shown above the content on desktop (dashboard only).
  final Widget? desktopHeader;

  /// Optional actions on the right of the mobile top bar.
  final List<Widget> mobileActions;

  @override
  State<AdminShell> createState() => _AdminShellState();
}

class _AdminShellState extends State<AdminShell> {
  bool _drawerOpen = false;

  @override
  void initState() {
    super.initState();
    _AdminIdentity.load().then((_) {
      if (mounted) setState(() {});
    });
  }

  void _openDrawer() => setState(() => _drawerOpen = true);

  void _closeDrawer() {
    if (_drawerOpen) setState(() => _drawerOpen = false);
  }

  void _select(AdminPage page) {
    _closeDrawer(); // always close after navigating
    widget.onSelect(page);
  }

  @override
  Widget build(BuildContext context) {
    final tk = _Tk.of(context);

    return LayoutBuilder(builder: (context, constraints) {
      final w = constraints.maxWidth;

      // ---------- Desktop ----------
      if (w >= _kDesktop) {
        return Scaffold(
          backgroundColor: tk.bg,
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
                      userName: _AdminIdentity.name ?? 'Administrator',
                      userEmail: _AdminIdentity.email,
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
      return Scaffold(
        backgroundColor: tk.bg,
        body: Stack(
          children: [
            Column(
              children: [
                _MobileTopBar(
                  onMenu: _openDrawer,
                  actions: widget.mobileActions,
                ),
                Expanded(child: widget.child),
              ],
            ),
            if (_drawerOpen) _buildDrawer(w),
          ],
        ),
      );
    });
  }

  Widget _buildDrawer(double screenWidth) {
    final tk = _Tk.of(context);
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
            namesRoute: true,
            label: 'Navigation drawer',
            child: Material(
              color: tk.navy,
              elevation: 16,
              child: SafeArea(
                child: _Sidebar(
                  current: widget.current,
                  onSelect: _select,
                  onLogout: () {
                    _closeDrawer();
                    widget.onLogout();
                  },
                  userName: _AdminIdentity.name ?? 'Administrator',
                  userEmail: _AdminIdentity.email,
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
    final tk = _Tk.of(context);

    return Material(
      color: tk.navy,
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: 64,
          child: Row(
            children: [
              const SizedBox(width: 4),
              IconButton(
                tooltip: 'Open navigation menu',
                icon: const Icon(Icons.menu, color: Colors.white),
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
                        color: Colors.white,
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

  final AdminPage current;
  final ValueChanged<AdminPage> onSelect;
  final VoidCallback onLogout;
  final String userName;
  final String? userEmail;
  final bool collapsible;
  final bool collapsed;
  final VoidCallback? onToggle;
  final VoidCallback? onClose; // non-null => drawer mode

  @override
  Widget build(BuildContext context) {
    final tk = _Tk.of(context);

    return Container(
      color: tk.navy,
      child: LayoutBuilder(builder: (context, constraints) {
        // Hide labels while the width animation is still narrow.
        final showLabels = constraints.maxWidth > 180;

        return Padding(
          padding: EdgeInsets.fromLTRB(
              showLabels ? 12 : 12, 16, showLabels ? 12 : 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(tk, showLabels),
              Divider(color: Colors.white.withValues(alpha: 0.12), height: 24),
              Expanded(
                child: ListView(
                  children: [
                    for (final p in _navPages)
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
              Divider(color: Colors.white.withValues(alpha: 0.12), height: 20),
              _userCard(context, tk, showLabels),
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
      }),
    );
  }

  Widget _userCard(BuildContext context, _Tk tk, bool showLabels) {
    final avatar = CircleAvatar(
      radius: 16,
      backgroundColor: tk.emerald,
      child: Text(
        _AdminIdentity.initials(userName),
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w800,
        ),
      ),
    );

    final email = userEmail;

    final content = InkWell(
      borderRadius: BorderRadius.circular(12),
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
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (email != null && email.isNotEmpty)
                      Text(
                        email,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white60,
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
      child: showLabels ? content : Tooltip(message: userName, child: content),
    );
  }

  Widget _header(_Tk tk, bool showLabels) {
    final toggle = collapsible
        ? IconButton(
            tooltip: collapsed ? 'Expand sidebar' : 'Collapse sidebar',
            icon: Icon(
              collapsed
                  ? Icons.keyboard_double_arrow_right
                  : Icons.keyboard_double_arrow_left,
              color: Colors.white70,
            ),
            onPressed: onToggle,
          )
        : null;

    final close = onClose != null
        ? IconButton(
            tooltip: 'Close navigation menu',
            icon: const Icon(Icons.close, color: Colors.white70),
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
            errorBuilder: (context, error, stackTrace) =>
                Icon(Icons.fact_check_rounded, color: tk.emerald, size: 32),
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
                  errorBuilder: (context, error, stackTrace) => Row(
                    children: [
                      Icon(Icons.fact_check_rounded, color: tk.emerald),
                      const SizedBox(width: 8),
                      const Flexible(
                        child: Text(
                          'CheckMate',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white,
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
            if (toggle != null) toggle,
            if (close != null) close,
          ],
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(6),
          ),
          child: const Text(
            'ADMIN PORTAL',
            style: TextStyle(
              color: Colors.white,
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
    final fg = active ? Colors.white : Colors.white70;

    final item = Material(
      color: active ? Colors.white.withValues(alpha: 0.10) : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: SizedBox(
          height: 44,
          child: Row(
            mainAxisAlignment:
                showLabel ? MainAxisAlignment.start : MainAxisAlignment.center,
            children: [
              if (showLabel) const SizedBox(width: 12),
              Icon(icon, color: fg, size: 21),
              if (showLabel) ...[
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: fg,
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
// DASHBOARD (home) — same data loading and navigation as before
// =============================================================

class AdminDashboard extends StatefulWidget {
  const AdminDashboard({
    super.key,
    this.adminName = 'Admin',
    this.adminEmail,
  });

  final String adminName;

  /// Optional. Shown under the name in the navigation panel. If omitted,
  /// it is read from the stored login token when available.
  final String? adminEmail;

  @override
  State<AdminDashboard> createState() => _AdminDashboardState();
}

class _AdminDashboardState extends State<AdminDashboard> {
  bool _loading = true;
  String? _error;
  int _subjects = 0, _classes = 0, _students = 0, _exams = 0;
  Route<dynamic>? _route;

  @override
  void initState() {
    super.initState();
    if (widget.adminEmail != null && widget.adminEmail!.isNotEmpty) {
      _AdminIdentity.email = widget.adminEmail;
    }
    _refreshDashboard = _loadData;
    _loadData();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
    _adminDashboardRoute = _route;
  }

  @override
  void dispose() {
    if (_adminDashboardRoute == _route) _adminDashboardRoute = null;
    if (_refreshDashboard == _loadData) _refreshDashboard = null;
    super.dispose();
  }

  Future<void> _loadData() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final token = await AuthStorage.getToken();
      if (token == null || token.isEmpty) {
        throw Exception('Your session has expired. Please log in again.');
      }

      final results = await Future.wait([
        ApiService.getSubjects(token),
        ApiService.getClasses(token),
        ApiService.getStudents(token),
        ApiService.getExams(token),
      ]);

      if (!mounted) return;
      setState(() {
        _subjects = results[0].length;
        _classes = results[1].length;
        _students = results[2].length;
        _exams = results[3].length;
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

  Future<void> _logout() => _performLogout(context);

  Future<void> _open(AdminPage page) async {
    if (page == AdminPage.dashboard) return;

    final screen = _screenFor(page);
    if (screen == null) {
      // Teachers / Attempts / Results have no screen yet.
      _soon(context, page.label);
      return;
    }

    await Navigator.push(context, _shellRoute(page, screen));

    // Refresh counts after returning (something may have been added).
    if (mounted) _loadData();
  }

  @override
  Widget build(BuildContext context) {
    return AdminShell(
      current: AdminPage.dashboard,
      onSelect: _open,
      onLogout: _logout,
      desktopHeader: const _DesktopTopBar(),
      mobileActions: const [_NotificationBell(onDark: true)],
      child: _DashboardContent(
        adminName: widget.adminName,
        loading: _loading,
        error: _error,
        onRetry: _loadData,
        onOpen: _open,
        subjects: _subjects,
        classes: _classes,
        students: _students,
        exams: _exams,
      ),
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
    final tk = _Tk.of(context);

    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: tk.surface,
        border: Border(bottom: BorderSide(color: tk.border)),
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
                  color: tk.muted,
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
                  style: TextStyle(color: tk.text),
                  decoration: InputDecoration(
                    hintText: 'Search subjects, classes, exams, students',
                    hintStyle: TextStyle(color: tk.muted, fontSize: 14),
                    prefixIcon: Icon(Icons.search, color: tk.muted),
                    isDense: true,
                    filled: true,
                    fillColor: tk.bg,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: tk.border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: tk.border),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: tk.navy, width: 1.5),
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
    final tk = _Tk.of(context);

    return IconButton(
      tooltip: 'Notifications',
      onPressed: () => _soon(context, 'Notifications'),
      icon: Stack(
        clipBehavior: Clip.none,
        children: [
          Icon(Icons.notifications_none,
              color: onDark ? Colors.white : tk.text),
          Positioned(
            right: -1,
            top: -1,
            child: Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(
                color: tk.amber,
                shape: BoxShape.circle,
                border: Border.all(
                    color: onDark ? tk.navy : tk.surface, width: 1.5),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================
// DASHBOARD CONTENT
// =============================================================

class _DashboardContent extends StatelessWidget {
  const _DashboardContent({
    required this.adminName,
    required this.loading,
    required this.error,
    required this.onRetry,
    required this.onOpen,
    required this.subjects,
    required this.classes,
    required this.students,
    required this.exams,
  });

  final String adminName;
  final bool loading;
  final String? error;
  final VoidCallback onRetry;
  final ValueChanged<AdminPage> onOpen;
  final int subjects, classes, students, exams;

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
    final tk = _Tk.of(context);

    return LayoutBuilder(builder: (context, constraints) {
      final pad = constraints.maxWidth >= _kTablet ? 36.0 : 16.0;

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
                    'Welcome Back, $adminName',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                      color: tk.text,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(_today(), style: TextStyle(color: tk.muted)),
                  const SizedBox(height: 24),
                  if (loading)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 48),
                      child: Center(
                        child: CircularProgressIndicator(color: tk.text),
                      ),
                    )
                  else if (error != null)
                    _ErrorPanel(message: error!, onRetry: onRetry)
                  else ...[
                    _stats(w),
                    const SizedBox(height: 32),
                    Text(
                      'Manage',
                      style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w700,
                        color: tk.text,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Quick access to school records',
                      style: TextStyle(fontSize: 13, color: tk.muted),
                    ),
                    const SizedBox(height: 14),
                    _modules(w),
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

  // ---------- Stats: 4 across on desktop, 2 across otherwise ----------

  Widget _stats(double w) {
    final cols = w >= _kDesktop - 250 ? 4 : 2;
    return _grid(w, cols, [
      _StatCard(
        icon: Icons.library_books_outlined,
        value: '$subjects',
        label: 'Subjects',
        note: 'Total subjects',
      ),
      _StatCard(
        icon: Icons.menu_book_outlined,
        value: '$classes',
        label: 'Classes',
        note: 'Class codes',
      ),
      _StatCard(
        icon: Icons.school_outlined,
        value: '$students',
        label: 'Students',
        note: 'Enrolled',
        tone: _Tone.green,
      ),
      _StatCard(
        icon: Icons.assignment_outlined,
        value: '$exams',
        label: 'Exams',
        note: 'All examinations',
        tone: _Tone.amber,
      ),
    ]);
  }

  // ---------- Manage shortcuts ----------

  Widget _modules(double w) {
    const modules = [
      AdminPage.subjects,
      AdminPage.classes,
      AdminPage.students,
      AdminPage.teachers,
      AdminPage.exams,
    ];
    final cols = w >= 1000 ? 3 : (w >= _kTablet ? 2 : 1);
    return _grid(w, cols, [
      for (final m in modules) _ModuleCard(page: m, onTap: () => onOpen(m)),
    ]);
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

enum _Tone { neutral, green, amber }

class _Panel extends StatelessWidget {
  const _Panel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tk = _Tk.of(context);

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: tk.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: tk.border),
        boxShadow: [
          BoxShadow(
            color: tk.shadow,
            blurRadius: 12,
            offset: const Offset(0, 2),
          ),
        ],
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
    this.tone = _Tone.neutral,
  });

  final IconData icon;
  final String value, label, note;
  final _Tone tone;

  @override
  Widget build(BuildContext context) {
    final tk = _Tk.of(context);

    final Color boxColor;
    final Color iconColor;
    switch (tone) {
      case _Tone.green:
        boxColor = tk.emerald.withValues(alpha: 0.16);
        iconColor = tk.emerald;
      case _Tone.amber:
        boxColor = tk.amber.withValues(alpha: 0.18);
        iconColor = tk.amber;
      case _Tone.neutral:
        boxColor = tk.muted.withValues(alpha: 0.14);
        iconColor = tk.text;
    }

    return Semantics(
      label: '$label: $value',
      child: _Panel(
        child: Stack(
          children: [
            SizedBox(
              width: double.infinity,
              child: Padding(
                padding: const EdgeInsets.only(top: 22),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(value,
                        style: TextStyle(
                            fontSize: 30,
                            fontWeight: FontWeight.w700,
                            color: tk.text,
                            height: 1.1)),
                    const SizedBox(height: 6),
                    Text(label,
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: tk.text)),
                    const SizedBox(height: 2),
                    Text(note,
                        style: TextStyle(fontSize: 12, color: tk.muted)),
                  ],
                ),
              ),
            ),
            Positioned(
              top: 0,
              right: 0,
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: boxColor,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: iconColor, size: 22),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModuleCard extends StatelessWidget {
  const _ModuleCard({required this.page, required this.onTap});

  final AdminPage page;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tk = _Tk.of(context);

    return Semantics(
      button: true,
      label: 'Open ${page.label}',
      excludeSemantics: true,
      child: Material(
        color: tk.surface,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 22),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: tk.border),
              boxShadow: [
                BoxShadow(
                  color: tk.shadow,
                  blurRadius: 12,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: tk.muted.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(page.icon, color: tk.text, size: 22),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(page.label,
                      style: TextStyle(
                          fontSize: 15.5,
                          fontWeight: FontWeight.w600,
                          color: tk.text)),
                ),
                Icon(Icons.chevron_right, color: tk.muted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final tk = _Tk.of(context);

    return _Panel(
      child: SizedBox(
        width: double.infinity,
        child: Column(
          children: [
            Icon(Icons.error_outline, size: 40, color: tk.amber),
            const SizedBox(height: 12),
            Text(message,
                textAlign: TextAlign.center,
                style: TextStyle(color: tk.text)),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: onRetry,
              style: FilledButton.styleFrom(backgroundColor: tk.navy),
              child: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }
}