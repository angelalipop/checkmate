import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../services/auth_storage.dart';
import 'login_screen.dart' show CmColors, LoginScreen;

// =============================================================
// CheckMate — Teacher Dashboard (responsive)
//
// Desktop  (>= 900):  persistent sidebar + top bar
// Tablet   (600-899): app bar + drawer
// Mobile   (< 600):   app bar + drawer + bottom navigation
//
// Classes and exams come from ApiService. Review queue and analytics
// are still sample data (no backend endpoints yet).
// =============================================================

const double _kDesktop = 900;
const double _kTablet = 600;

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
// SCREEN
// =============================================================

class TeacherDashboard extends StatefulWidget {
  const TeacherDashboard({super.key, this.teacherName = 'Teacher'});

  final String teacherName;

  @override
  State<TeacherDashboard> createState() => _TeacherDashboardState();
}

class _TeacherDashboardState extends State<TeacherDashboard> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  TeacherPage _page = TeacherPage.dashboard;

  bool _loading = true;
  String? _error;
  List<_ClassInfo> _classes = [];
  List<_ExamInfo> _exams = [];

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  // The backend must return only this teacher's classes/exams.
  // Nothing here filters by teacher on the client.
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
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _loading = false;
      });
    }
  }

  static const _bottomPages = [
    TeacherPage.dashboard,
    TeacherPage.classes,
    TeacherPage.exams,
    TeacherPage.scans,
  ];

  Future<void> _logout() async {
    await AuthStorage.deleteToken();
    if (!mounted) return;
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (route) => false,
    );
  }

  void _select(TeacherPage page, {bool closeDrawer = false}) {
    if (closeDrawer) Navigator.pop(context);
    setState(() => _page = page);
  }

  Widget _body() {
    if (_page == TeacherPage.dashboard) {
      return _DashboardContent(
        teacherName: widget.teacherName,
        onNavigate: (p) => _select(p),
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
                  current: _page,
                  onSelect: (p) => _select(p),
                  onLogout: _logout,
                ),
              ),
              Expanded(
                child: Column(
                  children: [
                    _DesktopTopBar(
                      teacherName: widget.teacherName,
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
      final bottomIndex = _bottomPages.indexOf(_page);

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
          // transparent_logo1.png replaces the title text (mobile/tablet).
          title: Image.asset(
            'assets/transparent_logo1.png',
            height: 48,
            fit: BoxFit.contain,
            alignment: Alignment.centerLeft,
            cacheHeight: 144,
            errorBuilder: (context, error, stackTrace) {
              debugPrint('APP BAR LOGO ERROR: $error');
              return const Text(
                'CheckMate',
                style: TextStyle(fontWeight: FontWeight.w700),
              );
            },
          ),
          actions: [
            const _NotificationBell(onDark: true),
            Padding(
              padding: const EdgeInsets.only(right: 12, left: 4),
              child: _ProfileMenu(
                name: widget.teacherName,
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
              current: _page,
              onSelect: (p) => _select(p, closeDrawer: true),
              onLogout: _logout,
            ),
          ),
        ),
        body: _body(),
        bottomNavigationBar: isMobile
            ? NavigationBar(
                backgroundColor: Colors.white,
                indicatorColor: CmColors.navy.withValues(alpha: 0.10),
                selectedIndex: bottomIndex == -1 ? 4 : bottomIndex,
                onDestinationSelected: (i) {
                  if (i == 4) {
                    _scaffoldKey.currentState?.openDrawer();
                  } else {
                    _select(_bottomPages[i]);
                  }
                },
                destinations: [
                  for (final p in _bottomPages)
                    NavigationDestination(
                      icon: Icon(p.icon, color: CmColors.slate),
                      selectedIcon: Icon(p.icon, color: CmColors.navy),
                      label: p == TeacherPage.dashboard ? 'Home' : p.label,
                    ),
                  const NavigationDestination(
                    icon: Icon(Icons.more_horiz, color: CmColors.slate),
                    selectedIcon: Icon(Icons.more_horiz, color: CmColors.navy),
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

  final TeacherPage current;
  final ValueChanged<TeacherPage> onSelect;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: CmColors.navy,
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Transparent logo with a white wordmark, made for the navy sidebar.
          // (dashboard_logo_light.png is the black-wordmark version for
          // white backgrounds.)
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
                for (final p in TeacherPage.values)
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
                // Active-state indicator bar
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
                Text(
                  label,
                  style: TextStyle(
                    color: fg,
                    fontSize: 15,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w500,
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
  const _DesktopTopBar({required this.teacherName, required this.onLogout});

  final String teacherName;
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
                  hintText: 'Search classes, exams, students',
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
          _ProfileMenu(name: teacherName, onLogout: onLogout),
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
    final initial = name.isNotEmpty ? name[0].toUpperCase() : 'T';
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