import 'package:flutter_test/flutter_test.dart';

import 'package:handbreak_example/main.dart';

void main() {
  testWidgets('Demo app renders picker UI', (WidgetTester tester) async {
    await tester.pumpWidget(const HandbreakDemoApp());

    expect(find.text('Pick Video / Image (Files)'), findsOneWidget);
    expect(find.text('Pick Video from Camera Roll'), findsOneWidget);
    expect(find.text('Pick Image from Camera Roll'), findsOneWidget);
    expect(find.textContaining('Pick a video or image'), findsOneWidget);
  });
}