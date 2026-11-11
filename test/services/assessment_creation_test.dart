import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:checkmate/screens/exams_tab.dart';

void main() {
  final classes = <Map<String, dynamic>>[
    {
      'id': 1,
      'section': 'BSIT41A',
      'student_count': 10,
      'subject': {'id': 1, 'code': 'QA', 'name': 'Test Subject'},
    },
  ];
  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showAssessmentCreation(context, classes: classes),
              child: const Text('Create'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
  }

  testWidgets('creation dropdown has exactly the nine approved types', (
    tester,
  ) async {
    await open(tester);
    final dropdown = tester.widget<DropdownButtonFormField<String>>(
      find.byType(DropdownButtonFormField<String>).first,
    );
    // Opening the dropdown renders all available choices.
    expect(dropdown.onChanged, isNotNull);
    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();
    for (final type in [
      'Quiz',
      'Short Quiz',
      'Long Quiz',
      'Performance Task',
      'Laboratory',
      'Prelim',
      'Midterm',
      'Pre-Finals',
      'Finals',
    ]) {
      expect(find.text(type), findsWidgets);
    }
    expect(find.text('Other'), findsNothing);
  });
  testWidgets('PT manual path opens score-column form without a builder', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Performance Task').last);
    await tester.pumpAndSettle();
    expect(find.text('Create an Assessment'), findsOneWidget);
    expect(find.text('Create Scorebook Column Only'), findsOneWidget);
    await tester.tap(find.text('Create Scorebook Column Only'));
    await tester.pumpAndSettle();
    expect(find.text('Create Performance Task column'), findsOneWidget);
    expect(find.text('Maximum Score'), findsOneWidget);
    expect(find.text('Assigned Sections'), findsOneWidget);
    expect(find.text('Save Questions and Answers'), findsNothing);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });
  testWidgets('major examination automatically selects its fixed period', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Finals').last);
    await tester.pumpAndSettle();
    final period = tester.widget<DropdownButtonFormField<String>>(
      find.byType(DropdownButtonFormField<String>).last,
    );
    expect(period.onChanged, isNull);
    expect(find.text('Finals'), findsWidgets);
  });
}
