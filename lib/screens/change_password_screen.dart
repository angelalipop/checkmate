import 'package:checkmate/theme/cm_theme.dart';
import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../services/auth_storage.dart';

/// Shown after sign-in when the account still has a temporary password.
/// [nextBuilder] builds the screen to open once the password is changed.
class ChangePasswordScreen extends StatefulWidget {
  const ChangePasswordScreen({super.key, required this.nextBuilder});

  final WidgetBuilder nextBuilder;

  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  final _currentController = TextEditingController();
  final _newController = TextEditingController();
  final _confirmController = TextEditingController();

  bool _loading = false;
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _currentController.dispose();
    _newController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();

    final current = _currentController.text;
    final next = _newController.text;
    final confirm = _confirmController.text;

    if (current.isEmpty) {
      setState(() => _error = 'Enter your temporary password.');
      return;
    }
    if (next.length < 8) {
      setState(() => _error = 'New password must be at least 8 characters.');
      return;
    }
    if (next != confirm) {
      setState(() => _error = 'New passwords do not match.');
      return;
    }
    if (next == current) {
      setState(
        () => _error =
            'Choose a password different from the '
            'temporary one.',
      );
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final token = await AuthStorage.getToken();

      if (token == null || token.isEmpty) {
        throw Exception('Your session has expired. Please sign in again.');
      }

      await ApiService.changePassword(
        token: token,
        currentPassword: current,
        newPassword: next,
      );

      if (!mounted) return;

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: widget.nextBuilder),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _loading = false;
      });
    }
  }

  InputDecoration _decoration(String label) {
    return InputDecoration(
      labelText: label,
      prefixIcon: const Icon(Icons.lock_outline, color: CmTheme.slateText),
      filled: true,
      fillColor: CmTheme.background,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: CmTheme.lineBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: CmTheme.lineBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: CmTheme.navy, width: 1.5),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: CmTheme.background,
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Card(
              elevation: 0,
              color: CmTheme.surfaceWhite,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
                side: const BorderSide(color: CmTheme.lineBorder),
              ),
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(
                      Icons.lock_reset_rounded,
                      size: 56,
                      color: CmTheme.navy,
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Set a new password',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                        color: CmTheme.navy,
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'You signed in with a temporary password. '
                      'Choose your own to continue.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 14, color: CmTheme.slateText),
                    ),
                    const SizedBox(height: 24),
                    TextField(
                      controller: _currentController,
                      obscureText: _obscure,
                      enabled: !_loading,
                      decoration: _decoration('Temporary password'),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _newController,
                      obscureText: _obscure,
                      enabled: !_loading,
                      decoration: _decoration('New password').copyWith(
                        suffixIcon: IconButton(
                          icon: Icon(
                            _obscure
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                            color: CmTheme.slateText,
                          ),
                          onPressed: () => setState(() => _obscure = !_obscure),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _confirmController,
                      obscureText: _obscure,
                      enabled: !_loading,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) {
                        if (!_loading) _submit();
                      },
                      decoration: _decoration('Confirm new password'),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: CmTheme.surfaceWhite,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: CmTheme.redDanger),
                        ),
                        child: Text(
                          _error!,
                          style: const TextStyle(
                            color: CmTheme.redDanger,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 24),
                    SizedBox(
                      height: 52,
                      child: FilledButton(
                        onPressed: _loading ? null : _submit,
                        style: FilledButton.styleFrom(
                          backgroundColor: CmTheme.navy,
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
                                  color: CmTheme.surfaceWhite,
                                ),
                              )
                            : const Text(
                                'Change password',
                                style: TextStyle(fontWeight: FontWeight.w700),
                              ),
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
