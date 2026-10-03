import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../services/auth_storage.dart';
import 'admin_dashboard.dart';
import 'login_screen.dart' show CmColors, CmBrandPanel, kDesktopBreakpoint;


class AdminLoginScreen extends StatefulWidget {
  const AdminLoginScreen({super.key});

  @override
  State<AdminLoginScreen> createState() => _AdminLoginScreenState();
}

class _AdminLoginScreenState extends State<AdminLoginScreen> {
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

      final token = result['token']?.toString();

      if (token == null || token.isEmpty) {
        throw Exception(
          'Login succeeded, but no authentication token was received.',
        );
      }

      final user = result['user'];

      if (user is! Map) {
        throw Exception('Invalid user information received.');
      }

      final role = user['role']?.toString().toLowerCase();

      debugPrint('ADMIN LOGIN USER: $user');
      debugPrint('ADMIN LOGIN ROLE: $role');

      if (role != 'admin') {
        throw Exception(
          'This account is not an admin account. '
          'Use the regular sign-in screen instead.',
        );
      }

      await AuthStorage.saveToken(token);

      if (!mounted) {
        return;
      }

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => const AdminDashboard(),
        ),
      );
    } catch (e) {
      if (!mounted) {
        return;
      }

      debugPrint('ADMIN LOGIN ERROR: $e');

      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  void _goBackToTeacherLogin() {
    // Clear this screen's own error before popping, purely defensive —
    // AdminLoginScreen gets a fresh State each time it's pushed, but this
    // keeps the two screens' back-navigation behavior symmetric.
    setState(() => _error = null);
    Navigator.pop(context);
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
              Center(
                child: Image.asset(
                  'assets/logo.png',
                  height: 150,
                  errorBuilder: (context, error, stackTrace) => const Icon(
                    Icons.admin_panel_settings_outlined,
                    size: 72,
                    color: CmColors.navy,
                  
                ),
              ),
              ),

              const SizedBox(height: 20),

              const Text(
                'Admin',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  color: CmColors.navy,
                ),
              ),

              const SizedBox(height: 6),


              const SizedBox(height: 28),

              TextField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.next,
                decoration: _fieldDecoration(
                  label: 'Admin email',
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

              // Same height as LoginScreen's buttons for visual consistency.
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
                child: TextButton(
                  onPressed: _loading ? null : _goBackToTeacherLogin,
                  child: const Text(
                    'Back to teacher sign in',
                    style: TextStyle(
                      color: CmColors.slate,
                      fontWeight: FontWeight.w700,
                    ),
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
                  heading: 'Admin console',
                  subheading:
                      'Finalize exam questionnaires, manage teacher '
                      'accounts, and oversee enrollment by section.',
                  backgroundColor: CmColors.navy,
                  illustrationAsset: 'assets/admin_illustration.png',
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}