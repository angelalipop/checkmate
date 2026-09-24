import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../services/auth_storage.dart';
import 'admin_dashboard.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    FocusScope.of(context).unfocus();

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final result = await ApiService.login(
        email: _emailController.text.trim(),
        password: _passwordController.text,
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Welcome, ${user['name'] ?? user['email']}. '
              'Teacher Dashboard is coming soon.',
            ),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: 420,
            ),
            child: Card(
              elevation: 2,
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.stretch,
                  children: [
                    const Icon(
                      Icons.fact_check_rounded,
                      size: 64,
                      color: Color(0xFF2563EB),
                    ),

                    const SizedBox(height: 16),

                    Text(
                      'Checkmate',
                      textAlign: TextAlign.center,
                      style: Theme.of(context)
                          .textTheme
                          .headlineMedium
                          ?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),

                    const SizedBox(height: 8),

                    Text(
                      'Exam management and assessment',
                      textAlign: TextAlign.center,
                      style: Theme.of(context)
                          .textTheme
                          .bodyMedium,
                    ),

                    const SizedBox(height: 32),

                    TextField(
                      controller: _emailController,
                      keyboardType:
                          TextInputType.emailAddress,
                      textInputAction:
                          TextInputAction.next,
                      decoration:
                          const InputDecoration(
                        labelText: 'Email',
                        prefixIcon: Icon(
                          Icons.email_outlined,
                        ),
                        border: OutlineInputBorder(),
                      ),
                    ),

                    const SizedBox(height: 16),

                    TextField(
                      controller: _passwordController,
                      obscureText: true,
                      onSubmitted: (_) {
                        if (!_loading) {
                          _login();
                        }
                      },
                      decoration:
                          const InputDecoration(
                        labelText: 'Password',
                        prefixIcon: Icon(
                          Icons.lock_outline,
                        ),
                        border: OutlineInputBorder(),
                      ),
                    ),

                    if (_error != null) ...[
                      const SizedBox(height: 16),

                      Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context)
                              .colorScheme
                              .error,
                        ),
                      ),
                    ],

                    const SizedBox(height: 24),

                    SizedBox(
                      height: 50,
                      child: FilledButton(
                        onPressed:
                            _loading ? null : _login,
                        child: _loading
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child:
                                    CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('Sign In'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}