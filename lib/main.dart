import 'package:flutter/material.dart';

import 'screens/admin_dashboard.dart';
import 'screens/login_screen.dart';
import 'services/api_service.dart';
import 'services/auth_storage.dart';

void main() {
  runApp(const CheckmateApp());
}

class CheckmateApp extends StatelessWidget {
  const CheckmateApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Checkmate',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2563EB),
        ),
        useMaterial3: true,
      ),
      home: const AuthCheck(),
    );
  }
}

class AuthCheck extends StatefulWidget {
  const AuthCheck({super.key});

  @override
  State<AuthCheck> createState() => _AuthCheckState();
}

class _AuthCheckState extends State<AuthCheck> {
  bool _loading = true;
  Widget? _nextScreen;

  @override
  void initState() {
    super.initState();
    _checkSession();
  }

  Future<void> _checkSession() async {
    try {
      // Get the saved JWT.
      final token = await AuthStorage.getToken();

      // No token means the user needs to log in.
      if (token == null || token.isEmpty) {
        _setNextScreen(const LoginScreen());
        return;
      }

      // Validate the JWT with the backend.
      final result = await ApiService.getCurrentUser(token);

      final user = result['user'];

      if (user is! Map) {
        throw Exception('Invalid user information.');
      }

      final role = user['role']?.toString().toLowerCase();

      debugPrint('SESSION USER: $user');
      debugPrint('SESSION ROLE: $role');

      if (role == 'admin') {
        _setNextScreen(const AdminDashboard());
        return;
      }

      // Teacher dashboard will be added later.
      if (role == 'teacher') {
        await AuthStorage.deleteToken();
        _setNextScreen(const LoginScreen());
        return;
      }

      // Unknown role.
      await AuthStorage.deleteToken();
      _setNextScreen(const LoginScreen());
    } catch (e) {
      debugPrint('SESSION CHECK ERROR: $e');

      // Token is invalid/expired or the server couldn't validate it.
      await AuthStorage.deleteToken();

      _setNextScreen(const LoginScreen());
    }
  }

  void _setNextScreen(Widget screen) {
    if (!mounted) {
      return;
    }

    setState(() {
      _nextScreen = screen;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    return _nextScreen ?? const LoginScreen();
  }
}