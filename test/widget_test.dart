import 'package:flutter_test/flutter_test.dart';

import 'package:checkmate/main.dart';

void main() {
  testWidgets('Checkmate app loads', (WidgetTester tester) async {
    await tester.pumpWidget(const CheckmateApp());

    expect(find.text('Checkmate'), findsOneWidget);
  });
}
