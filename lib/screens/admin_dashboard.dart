import 'package:flutter/material.dart';

import '../services/auth_storage.dart';
import 'classes_screen.dart';
import 'login_screen.dart';
import 'subjects_screen.dart';
import 'students_screen.dart';
import 'exams_screen.dart';
import 'answer_sheet_input_screen.dart';

class AdminDashboard extends StatelessWidget {
  const AdminDashboard({
    super.key,
  });

  // =========================
  // LOGOUT
  // =========================

  Future<void> _logout(
    BuildContext context,
  ) async {
    await AuthStorage.deleteToken();

    if (!context.mounted) {
      return;
    }

    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(
        builder: (context) => const LoginScreen(),
      ),
      (route) => false,
    );
  }

  // =========================
  // OPEN SCAN ANSWER SHEET
  // =========================

  void _openAnswerSheetScanner(
    BuildContext context,
  ) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) =>
            const AnswerSheetInputScreen(),
      ),
    );
  }

  // =========================
  // BUILD
  // =========================

  @override
  Widget build(
    BuildContext context,
  ) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'CheckMate Admin',
        ),
        actions: [
          IconButton(
            tooltip: 'Logout',
            icon: const Icon(
              Icons.logout,
            ),
            onPressed: () =>
                _logout(context),
          ),
        ],
      ),

      body: Padding(
        padding: const EdgeInsets.all(16),

        child: Column(
          crossAxisAlignment:
              CrossAxisAlignment.start,

          children: [
            Text(
              'Admin Dashboard',
              style: Theme.of(
                context,
              )
                  .textTheme
                  .headlineMedium
                  ?.copyWith(
                    fontWeight:
                        FontWeight.bold,
                  ),
            ),

            const SizedBox(
              height: 8,
            ),

            Text(
              'Manage CheckMate from here.',
              style: Theme.of(
                context,
              )
                  .textTheme
                  .bodyMedium,
            ),

            const SizedBox(
              height: 24,
            ),

            // =========================
            // SCAN ANSWER SHEET
            // =========================

            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () =>
                    _openAnswerSheetScanner(
                  context,
                ),
                icon: const Icon(
                  Icons.document_scanner_outlined,
                  size: 28,
                ),
                label: const Text(
                  'Scan Answer Sheet',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(
                    vertical: 18,
                  ),
                  shape:
                      RoundedRectangleBorder(
                    borderRadius:
                        BorderRadius.circular(12),
                  ),
                ),
              ),
            ),

            const SizedBox(
              height: 20,
            ),

            // =========================
            // DASHBOARD MODULES
            // =========================

            Expanded(
              child: GridView.count(
                crossAxisCount: 2,

                crossAxisSpacing: 12,

                mainAxisSpacing: 12,

                children: [
                  // SUBJECTS
                  _dashboardCard(
                    context,
                    icon: Icons
                        .menu_book_outlined,
                    title: 'Subjects',
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) =>
                              const SubjectsScreen(),
                        ),
                      );
                    },
                  ),

                  // CLASSES
                  _dashboardCard(
                    context,
                    icon: Icons.class_outlined,
                    title: 'Classes',
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) =>
                              const ClassesScreen(),
                        ),
                      );
                    },
                  ),

                  // STUDENTS
                  _dashboardCard(
                    context,
                    icon: Icons.people_outline,
                    title: 'Students',
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) =>
                              const StudentsScreen(),
                        ),
                      );
                    },
                  ),

                  // EXAMS
                  _dashboardCard(
                    context,
                    icon: Icons
                        .assignment_outlined,
                    title: 'Exams',
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) =>
                              const ExamsScreen(),
                        ),
                      );
                    },
                  ),

                  // ATTEMPTS
                  _dashboardCard(
                    context,
                    icon: Icons
                        .fact_check_outlined,
                    title: 'Attempts',
                  ),

                  // RESULTS
                  _dashboardCard(
                    context,
                    icon: Icons
                        .assessment_outlined,
                    title: 'Results',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // =========================
  // DASHBOARD CARD
  // =========================

  Widget _dashboardCard(
    BuildContext context, {
    required IconData icon,
    required String title,
    VoidCallback? onTap,
  }) {
    return Card(
      elevation: 2,

      child: InkWell(
        borderRadius:
            BorderRadius.circular(12),

        onTap: onTap ??
            () {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(
                SnackBar(
                  content: Text(
                    '$title module coming soon.',
                  ),
                ),
              );
            },

        child: Column(
          mainAxisAlignment:
              MainAxisAlignment.center,

          children: [
            Icon(
              icon,
              size: 42,
            ),

            const SizedBox(
              height: 12,
            ),

            Text(
              title,
              style: const TextStyle(
                fontSize: 16,
                fontWeight:
                    FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}