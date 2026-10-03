import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../services/auth_storage.dart';
import 'answer_sheet_input_screen.dart';
import 'classes_screen.dart';
import 'exams_screen.dart';
import 'login_screen.dart' show CmColors, LoginScreen;
import 'students_screen.dart';
import 'subjects_screen.dart';

// =============================================================
// CheckMate — Admin Dashboard (responsive)
//
// Mirrors the Teacher Dashboard layout:
// Desktop  (>= 900):  persistent sidebar + top bar
// Tablet   (600-899): app bar + drawer
// Mobile   (< 600):   app bar + drawer + bottom navigation
//
// Module screens (Subjects, Classes, ...) keep their own Scaffold,
// so sidebar / card taps push them on top of this dashboard.
// =============================================================

const double _kDesktop = 900;
const double _kTablet = 600;

enum AdminPage {
  dashboard('Dashboard', Icons.space_dashboard_outlined),
  subjects('Subjects', Icons.menu_book_outlined),
  classes('Classes', Icons.class_outlined),
  students('Students', Icons.people_outline),
  exams('Exams', Icons.assignment_outlined),
  scans('Scan Answer Sheet', Icons.document_scanner_outlined),
  attempts('Attempts', Icons.fact_check_outlined),
  results('Results', Icons.assessment_outlined);

  const AdminPage(this.label, this.icon);
  final String label;
  final IconData icon;
}

class AdminDashboard extends StatefulWidget {
  const AdminDashboard({super.key, this.adminName = 'Admin'});

  final String adminName;

  @override
  State<AdminDashboard> createState() => _AdminDashboardState();
}

class _AdminDashboardState extends State<AdminDashboard> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  bool _loading = true;
  String? _error;
  int _subjects = 0, _classes = 0, _students = 0, _exams = 0;

  static const _bottomPages = [
    AdminPage.dashboard,
    AdminPage.classes,
    AdminPage.exams,
    AdminPage.scans,
  ];

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

  Future<void> _logout() async {
    await AuthStorage.deleteToken();
    if (!mounted) return;
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (route) => false,
    );
  }

  Future<void> _open(AdminPage page, {bool closeDrawer = false}) async {
    if (closeDrawer) Navigator.pop(context);

    Widget? screen;
    switch (page) {
      case AdminPage.subjects:
        screen = const SubjectsScreen();
      case AdminPage.classes:
        screen = const ClassesScreen();
      case AdminPage.students:
        screen = const StudentsScreen();
      case AdminPage.exams:
        screen = const ExamsScreen();
      case AdminPage.scans:
        screen = const AnswerSheetInputScreen();
      case AdminPage.dashboard:
        return;
      case AdminPage.attempts:
      case AdminPage.results:
        _soon(context, page.label);
        return;
    }

    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => screen!),
    );

    // Refresh counts after returning (something may have been added).
    if (mounted) _loadData();
  }

  Widget _body() => _DashboardContent(
        adminName: widget.adminName,
        loading: _loading,
        error: _error,
        onRetry: _loadData,
        onOpen: _open,
        subjects: _subjects,
        classes: _classes,
        students: _students,
        exams: _exams,
      );

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final w = constraints.maxWidth;

      // ---------- Desktop ----------
      if (w >= _kDesktop) {
        return Scaffold(
          backgroundColor: CmColors.bg,
          body: Row(
            children: [
              SizedBox(
                width: 250,
                child: _Sidebar(
                  current: AdminPage.dashboard,
                  onSelect: (p) => _open(p),
                  onLogout: _logout,
                ),
              ),
              Expanded(
                child: Column(
                  children: [
                    _DesktopTopBar(
                      name: widget.adminName,
                      onLogout: _logout,
                    ),
                    Expanded(child: _body()),
                  ],
                ),
              ),
            ],
          ),
        );
      }

      // ---------- Tablet / Mobile ----------
      final isMobile = w < _kTablet;

      return Scaffold(
        key: _scaffoldKey,
        backgroundColor: CmColors.bg,
        appBar: AppBar(
          backgroundColor: CmColors.navy,
          foregroundColor: Colors.white,
          elevation: 0,
          leading: IconButton(
            tooltip: 'Menu',
            icon: const Icon(Icons.menu),
            onPressed: () => _scaffoldKey.currentState?.openDrawer(),
          ),
          titleSpacing: 4,
          title: Image.asset(
            'assets/transparent_logo1.png',
            height: 48,
            fit: BoxFit.contain,
            alignment: Alignment.centerLeft,
            cacheHeight: 144,
            errorBuilder: (context, error, stackTrace) => const Text(
              'CheckMate Admin',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          actions: [
            const _NotificationBell(onDark: true),
            Padding(
              padding: const EdgeInsets.only(right: 12, left: 4),
              child: _ProfileMenu(
                name: widget.adminName,
                onLogout: _logout,
                showName: false,
              ),
            ),
          ],
        ),
        drawer: Drawer(
          backgroundColor: CmColors.navy,
          child: SafeArea(
            child: _Sidebar(
              current: AdminPage.dashboard,
              onSelect: (p) => _open(p, closeDrawer: true),
              onLogout: _logout,
            ),
          ),
        ),
        body: _body(),
        bottomNavigationBar: isMobile
            ? NavigationBar(
                backgroundColor: Colors.white,
                indicatorColor: CmColors.navy.withValues(alpha: 0.10),
                selectedIndex: 0,
                onDestinationSelected: (i) {
                  if (i == 4) {
                    _scaffoldKey.currentState?.openDrawer();
                  } else {
                    _open(_bottomPages[i]);
                  }
                },
                destinations: [
                  for (final p in _bottomPages)
                    NavigationDestination(
                      icon: Icon(p.icon, color: CmColors.slate),
                      selectedIcon: Icon(p.icon, color: CmColors.navy),
                      label: switch (p) {
                        AdminPage.dashboard => 'Home',
                        AdminPage.scans => 'Scan',
                        _ => p.label,
                      },
                    ),
                  const NavigationDestination(
                    icon: Icon(Icons.more_horiz, color: CmColors.slate),
                    selectedIcon:
                        Icon(Icons.more_horiz, color: CmColors.navy),
                    label: 'More',
                  ),
                ],
              )
            : null,
      );
    });
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
  });

  final AdminPage current;
  final ValueChanged<AdminPage> onSelect;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: CmColors.navy,
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            child: Image.asset(
              'assets/dashboard_logo.png',
              width: double.infinity,
              fit: BoxFit.contain,
              cacheWidth: 600,
              errorBuilder: (context, error, stackTrace) => const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.fact_check_rounded, color: Colors.white),
                  SizedBox(width: 8),
                  Text('CheckMate',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w800)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 32),
          Expanded(
            child: ListView(
              children: [
                for (final p in AdminPage.values)
                  _SidebarItem(
                    icon: p.icon,
                    label: p.label,
                    active: p == current,
                    onTap: () => onSelect(p),
                  ),
              ],
            ),
          ),
          const Divider(color: Colors.white24, height: 24),
          _SidebarItem(
            icon: Icons.person_outline,
            label: 'Profile',
            active: false,
            onTap: () => _soon(context, 'Profile'),
          ),
          _SidebarItem(
            icon: Icons.logout,
            label: 'Log out',
            active: false,
            onTap: onLogout,
          ),
        ],
      ),
    );
  }
}

class _SidebarItem extends StatelessWidget {
  const _SidebarItem({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = active ? Colors.white : Colors.white70;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: active ? Colors.white.withValues(alpha: 0.10) : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Container(
            height: 48,
            padding: const EdgeInsets.only(right: 12),
            child: Row(
              children: [
                Container(
                  width: 4,
                  height: 24,
                  margin: const EdgeInsets.only(right: 12),
                  decoration: BoxDecoration(
                    color: active ? Colors.white : Colors.transparent,
                    borderRadius: const BorderRadius.horizontal(
                      right: Radius.circular(4),
                    ),
                  ),
                ),
                Icon(icon, color: fg, size: 22),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: fg,
                      fontSize: 15,
                      fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================
// TOP BAR (desktop) + shared bits
// =============================================================

class _DesktopTopBar extends StatelessWidget {
  const _DesktopTopBar({required this.name, required this.onLogout});

  final String name;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 72,
      padding: const EdgeInsets.symmetric(horizontal: 32),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: CmColors.line)),
      ),
      child: Row(
        children: [
          Expanded(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: TextField(
                decoration: InputDecoration(
                  hintText: 'Search subjects, classes, exams, students',
                  prefixIcon:
                      const Icon(Icons.search, color: CmColors.slate),
                  isDense: true,
                  filled: true,
                  fillColor: CmColors.bg,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: CmColors.line),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: CmColors.line),
                  ),
                ),
              ),
            ),
          ),
          const Spacer(),
          const _NotificationBell(),
          const SizedBox(width: 8),
          _ProfileMenu(name: name, onLogout: onLogout),
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
          Icon(Icons.notifications_none,
              color: onDark ? Colors.white : CmColors.navy),
          Positioned(
            right: -1,
            top: -1,
            child: Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(
                color: CmColors.amber,
                shape: BoxShape.circle,
                border: Border.all(
                    color: onDark ? CmColors.navy : Colors.white, width: 1.5),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProfileMenu extends StatelessWidget {
  const _ProfileMenu({
    required this.name,
    required this.onLogout,
    this.showName = true,
  });

  final String name;
  final VoidCallback onLogout;
  final bool showName;

  @override
  Widget build(BuildContext context) {
    final initial = name.isNotEmpty ? name[0].toUpperCase() : 'A';
    return PopupMenuButton<String>(
      tooltip: 'Account',
      offset: const Offset(0, 44),
      onSelected: (v) {
        if (v == 'logout') {
          onLogout();
        } else {
          _soon(context, 'Profile');
        }
      },
      itemBuilder: (_) => const [
        PopupMenuItem(value: 'profile', child: Text('Profile')),
        PopupMenuItem(value: 'logout', child: Text('Log out')),
      ],
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: CmColors.slate,
            child: Text(initial,
                style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w700)),
          ),
          if (showName) ...[
            const SizedBox(width: 10),
            Text(name,
                style: const TextStyle(
                    color: CmColors.navy, fontWeight: FontWeight.w600)),
            const Icon(Icons.keyboard_arrow_down, color: CmColors.slate),
          ],
        ],
      ),
    );
  }
}

void _soon(BuildContext context, String what) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text('$what is coming soon.')),
  );
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
                    'Welcome Back, $adminName',
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
                    _scanBanner(),
                    const SizedBox(height: 32),
                    _sectionHeader('Manage'),
                    const SizedBox(height: 12),
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

  // ---------- Stats ----------

  Widget _stats(double w) {
    final cols = w >= _kDesktop ? 4 : 2;
    return _grid(w, cols, [
      _StatCard(
        icon: Icons.menu_book_outlined,
        value: '$subjects',
        label: 'Subjects',
        note: 'Total subjects',
      ),
      _StatCard(
        icon: Icons.class_outlined,
        value: '$classes',
        label: 'Classes',
        note: 'Class codes',
      ),
      _StatCard(
        icon: Icons.people_outline,
        value: '$students',
        label: 'Students',
        note: 'Enrolled',
        color: CmColors.green,
      ),
      _StatCard(
        icon: Icons.assignment_outlined,
        value: '$exams',
        label: 'Exams',
        note: 'All examinations',
        color: CmColors.amber,
      ),
    ]);
  }

  // ---------- Scan banner ----------

  Widget _scanBanner() {
    return _Panel(
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: CmColors.navy.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.document_scanner_outlined,
                color: CmColors.navy, size: 26),
          ),
          const SizedBox(width: 16),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Scan Answer Sheet',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: CmColors.navy)),
                SizedBox(height: 2),
                Text('Capture or upload student answer sheets for checking.',
                    style: TextStyle(fontSize: 13, color: CmColors.slate)),
              ],
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            height: 44,
            child: FilledButton(
              onPressed: () => onOpen(AdminPage.scans),
              style: FilledButton.styleFrom(
                backgroundColor: CmColors.navy,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('Scan',
                  style: TextStyle(fontWeight: FontWeight.w700)),
            ),
          ),
        ],
      ),
    );
  }

  // ---------- Modules ----------

  Widget _modules(double w) {
    const modules = [
      AdminPage.subjects,
      AdminPage.classes,
      AdminPage.students,
      AdminPage.exams,
      AdminPage.attempts,
      AdminPage.results,
    ];
    final cols = w >= 1000 ? 3 : (w >= _kTablet ? 2 : 1);
    return _grid(w, cols, [
      for (final m in modules) _ModuleCard(page: m, onTap: () => onOpen(m)),
    ]);
  }

  // ---------- Layout helpers ----------

  Widget _sectionHeader(String title) {
    return Text(title,
        style: const TextStyle(
            fontSize: 19, fontWeight: FontWeight.w700, color: CmColors.navy));
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
  const _Panel({required this.child}) : padding = 20;

  final Widget child;
  final double padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(padding),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: CmColors.line),
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

class _ModuleCard extends StatelessWidget {
  const _ModuleCard({required this.page, required this.onTap});

  final AdminPage page;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: CmColors.line),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: CmColors.navy.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(page.icon, color: CmColors.navy, size: 24),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(page.label,
                    style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: CmColors.navy)),
              ),
              const Icon(Icons.chevron_right, color: CmColors.slate),
            ],
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
    return _Panel(
      child: SizedBox(
        width: double.infinity,
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
      ),
    );
  }
}