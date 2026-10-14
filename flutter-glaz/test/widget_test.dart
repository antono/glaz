import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaz/main.dart';

void main() {
  testWidgets('opens on the glasses tab, not connected', (tester) async {
    await tester.pumpWidget(const GlazApp());

    expect(find.text('GLASSES'), findsOneWidget);
    expect(find.text('Not connected'), findsOneWidget);
    expect(find.text('3 taps'), findsOneWidget);
  });

  testWidgets('the tabs switch', (tester) async {
    await tester.pumpWidget(const GlazApp());

    await tester.tap(find.text('Menu'));
    await tester.pumpAndSettle();
    expect(find.text('MENU'), findsOneWidget);
    expect(find.text('Camera'), findsOneWidget); // Apps starts expanded

    await tester.tap(find.text('About'));
    await tester.pumpAndSettle();
    expect(find.text('Open source licences'), findsOneWidget);
  });
}
