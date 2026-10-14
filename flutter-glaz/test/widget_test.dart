import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaz/main.dart';
import 'package:glaz/services/services.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Services.start();
  });

  testWidgets('tabs switch screens', (tester) async {
    await tester.pumpWidget(const GlazApp());
    expect(find.text('Not connected'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.apps_outlined));
    await tester.pumpAndSettle();
    expect(find.text('Camera'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.hub_outlined));
    await tester.pumpAndSettle();
    expect(find.text('Clock'), findsOneWidget);
    expect(find.text('No app allowed yet: Apps tab'), findsOneWidget);
  });

  testWidgets('Internet permission is off until allowed', (tester) async {
    final settings = Services.instance.settings;
    await tester.pumpWidget(const GlazApp());
    await tester.tap(find.byIcon(Icons.apps_outlined));
    await tester.pumpAndSettle();

    expect(settings.netAllowed('weather'), isFalse);
    await tester.scrollUntilVisible(find.text('Allow Internet access'), 100);
    await tester.tap(find.text('Allow Internet access'));
    await tester.pumpAndSettle();
    expect(settings.netAllowed('weather'), isTrue);
  });

  testWidgets('theme picker switches to dark and remembers it', (tester) async {
    await tester.pumpWidget(const GlazApp());
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.dark);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('theme'), 'dark');
  });
}
