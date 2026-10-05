import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../services/auth_storage.dart';
import 'admin_dashboard.dart';
import 'admin_login_screen.dart';
import 'change_password_screen.dart';
import 'teacher_dashboard.dart';

class CmColors {
  static const navy = Color(0xFF1E293B); 
  static const slate = Color(0xFF64748B); 
  static const bg = Color(0xFFF8FAFC); 
  static const green = Color(0xFF10B981); 
  static const amber = Color(0xFFF59E0B); 
  static const line = Color(0xFFE2E8F0);
}

const double kDesktopBreakpoint = 900;

class CmBrandPanel extends StatelessWidget {
  const CmBrandPanel({
    super.key,
    required this.heading,
    required this.subheading,
    this.backgroundColor = CmColors.navy,
    this.illustrationAsset = 'assets/login_illustration.png',
  });

  final String heading;
  final String subheading;

  final Color backgroundColor;

  final String illustrationAsset;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: backgroundColor,
      padding: const EdgeInsets.fromLTRB(48, 48, 48, 56),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [

          Expanded(
            child: Center(
              child: Image.asset(
                illustrationAsset,
                fit: BoxFit.contain,
                errorBuilder: (context, error, stackTrace) => Icon(
                  Icons.laptop_mac_rounded,
                  size: 140,
                  color: Colors.white.withValues(alpha: 0.18),
                ),
              ),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            heading,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            subheading,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 14,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _loading = false;
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    FocusScope.of(context).unfocus();

    final email = _emailController.text.trim();
    final password = _passwordController.text;

    if (email.isEmpty || password.isEmpty) {
      setState(() {
        _error = 'Please enter your email and password.';
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final result = await ApiService.login(
        email: email,
        password: password,
      );

      if (!mounted) {
        return;
      }

      // Get JWT token.
      final token = result['token']?.toString();

      if (token == null || token.isEmpty) {
        throw Exception(
          'Login succeeded, but no authentication token was received.',
        );
      }

      // Save JWT securely.
      await AuthStorage.saveToken(token);

      // Get user information.
      final user = result['user'];

      if (user is! Map) {
        throw Exception(
          'Invalid user information received.',
        );
      }

      final role = user['role']?.toString().toLowerCase();

      debugPrint('LOGIN USER: $user');
      debugPrint('LOGIN ROLE: $role');

      // ADMIN
      if (role == 'admin') {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (context) => const AdminDashboard(),
          ),
        );

        return;
      }

      // TEACHER
      if (role == 'teacher') {
        final teacherName = (user['name'] ?? user['email']).toString();

        // Temporary password (new account or admin reset): the backend
        // blocks every other route until it is changed.
        if (user['must_change_password'] == true) {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (context) => ChangePasswordScreen(
                nextBuilder: (_) =>
                    TeacherDashboard(teacherName: teacherName),
              ),
            ),
          );

          return;
        }

        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (context) =>
                TeacherDashboard(teacherName: teacherName),
          ),
        );

        return;
      }

      throw Exception(
        'Unknown user role: ${user['role']}',
      );
    } catch (e) {
      if (!mounted) {
        return;
      }

      debugPrint('LOGIN ERROR: $e');

      setState(() {
        _error = e.toString().replaceFirst(
              'Exception: ',
              '',
            );
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _goToAdminLogin() async {
    // Clear any lingering error before leaving — LoginScreen's State stays
    // alive underneath the pushed route, so without this the old error
    // banner would still be showing when the user comes back here.
    setState(() => _error = null);

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const AdminLoginScreen(),
      ),
    );

    // Belt-and-suspenders: also clear on return, in case an error was set
    // by some other path while this screen was covered.
    if (mounted) {
      setState(() => _error = null);
    }
  }

  InputDecoration _fieldDecoration({
    required String label,
    required IconData icon,
    Widget? suffixIcon,
  }) {
    return InputDecoration(
      labelText: label,
      prefixIcon: Icon(icon, color: CmColors.slate),
      suffixIcon: suffixIcon,
      filled: true,
      fillColor: CmColors.bg,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: CmColors.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: CmColors.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: CmColors.navy, width: 1.5),
      ),
    );
  }

  Widget _buildFormCard(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Card(
        elevation: 0,
        color: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: BorderSide(color: CmColors.line),
        ),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Logo mark — place the file at assets/logo.png and register
              // it in pubspec.yaml under flutter: assets:
              Center(
                child: Image.asset(
                  'assets/logo.png',
                  height: 150,
                  errorBuilder: (context, error, stackTrace) => const Icon(
                    Icons.fact_check_rounded,
                    size: 72,
                    color: CmColors.navy,
                  
                ),
              ),
              ),

              const SizedBox(height: 20),

              const Text(
                'Welcome to CheckMate',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  color: CmColors.navy,
                ),
              ),

              const SizedBox(height: 6),

              Text(
                'Sign in to continue.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: CmColors.slate,
                ),
              ),

              const SizedBox(height: 28),

              TextField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.next,
                decoration: _fieldDecoration(
                  label: 'Email or username',
                  icon: Icons.email_outlined,
                ),
              ),

              const SizedBox(height: 16),

              TextField(
                controller: _passwordController,
                obscureText: _obscure,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) {
                  if (!_loading) {
                    _login();
                  }
                },
                decoration: _fieldDecoration(
                  label: 'Password',
                  icon: Icons.lock_outline,
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscure
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                      color: CmColors.slate,
                    ),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
              ),

              if (_error != null) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFEF2F2),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFFFECACA)),
                  ),
                  child: Text(
                    _error!,
                    style: const TextStyle(
                      color: Color(0xFFDC2626),
                      fontSize: 13,
                    ),
                  ),
                ),
              ],

              const SizedBox(height: 24),

              // Both buttons share the same height/radius so they read as
              // one consistent pair rather than primary + smaller variant.
              SizedBox(
                height: 52,
                child: FilledButton(
                  onPressed: _loading ? null : _login,
                  style: FilledButton.styleFrom(
                    backgroundColor: CmColors.navy,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: _loading
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text(
                          'Sign in',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                ),
              ),

              const SizedBox(height: 12),

              SizedBox(
                height: 52,
                child: OutlinedButton(
                  onPressed: _loading ? null : _goToAdminLogin,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: CmColors.navy,
                    side: const BorderSide(color: CmColors.line),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text(
                    'Sign in as Admin',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scrollableForm = SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Center(child: _buildFormCard(context)),
    );

    return Scaffold(
      backgroundColor: CmColors.bg,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isDesktop = constraints.maxWidth >= kDesktopBreakpoint;
          if (!isDesktop) {
            return scrollableForm;
          }
          return Row(
            children: [
              Expanded(child: scrollableForm),
              Expanded(
                child: CmBrandPanel(
                  heading: 'Sign in to CheckMate',
                  subheading:
                      'Automated exam checking, item analysis, and '
                      'results delivery for your whole department.',
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}