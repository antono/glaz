import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaz/main.dart';
import 'package:glaz/services/services.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final dir = Directory.systemTemp.createTempSync('glaz_widget');
    await Services.start(photoDir: Directory('${dir.path}/photos'));
  });

  testWidgets('opens on the glasses tab, not connected', (tester) async {
    await tester.pumpWidget(const GlazApp());

    expect(find.text('GLASSES'), findsOneWidget);
    expect(find.text('Not connected'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
    // The gestures card is below the fold of the 800x600 test screen.
    await tester.scrollUntilVisible(find.text('3 taps'), 200);
    expect(find.text('3 taps'), findsOneWidget);
  });

  testWidgets('the tabs switch', (tester) async {
    await tester.pumpWidget(const GlazApp());

    await tester.tap(find.text('Photos'));
    // the gallery reads its folder for real, outside the test's fake clock
    await tester.runAsync(
      () => Future.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('No photos yet'), findsOneWidget);

    await tester.tap(find.text('Menu'));
    await tester.pumpAndSettle();
    expect(find.text('MENU'), findsOneWidget);
    expect(find.text('Camera'), findsOneWidget); // Apps starts expanded

    await tester.tap(find.text('Services'));
    await tester.pumpAndSettle();
    expect(find.text('Clock'), findsOneWidget);
    expect(find.text('No app allowed yet: Menu tab'), findsOneWidget);

    await tester.tap(find.text('About'));
    await tester.pumpAndSettle();
    expect(find.text('Open source licences'), findsOneWidget);
  });

  testWidgets('Internet permission is off until allowed in Menu', (
    tester,
  ) async {
    final settings = Services.instance.settings;
    await tester.pumpWidget(const GlazApp());
    await tester.tap(find.text('Menu'));
    await tester.pumpAndSettle();

    expect(settings.netAllowed('weather'), isFalse);
    // built already, but below the fold of the 800x600 test screen
    await tester.ensureVisible(find.text('Allow Internet access'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Allow Internet access'));
    await tester.pumpAndSettle();
    expect(settings.netAllowed('weather'), isTrue);
  });
}
