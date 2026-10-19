import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaz/frame/protocol.dart';
import 'package:glaz/main.dart';
import 'package:glaz/screens/menu_screen.dart';
import 'package:glaz/services/services.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final dir = Directory.systemTemp.createTempSync('glaz_widget');
    await Services.start(
      photoDir: Directory('${dir.path}/photos'),
      recordingDir: Directory('${dir.path}/recordings'),
      readerDir: Directory('${dir.path}/reader'),
    );
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

    await tester.tap(find.text('Remote'));
    await tester.pumpAndSettle();
    expect(find.text('OK'), findsOneWidget);
    expect(
      find.text('Connect to the glasses first (Glasses tab).'),
      findsOneWidget,
    );

    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Services'));
    await tester.pumpAndSettle();
    expect(find.text('Clock'), findsOneWidget);
    // Internet and Location: both wait for a module to be allowed
    expect(find.text('No app allowed yet: Menu tab'), findsNWidgets(2));
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(find.text('About'));
    await tester.pumpAndSettle();
    expect(find.text('Open source licences'), findsOneWidget);
  });

  testWidgets('photo settings hide behind the icon by Take a photo', (
    tester,
  ) async {
    await tester.pumpWidget(const GlazApp());
    await tester.tap(find.text('Remote'));
    await tester.pumpAndSettle();

    final take = find.textContaining('Take a photo');
    await tester.scrollUntilVisible(take, 200);
    expect(find.textContaining('M, Mid'), findsOneWidget);
    expect(find.text('Quality'), findsNothing);

    await tester.tap(find.byTooltip('Photo settings'));
    await tester.pumpAndSettle();
    expect(find.text('Quality'), findsOneWidget);
    await tester.tap(find.text('L'));
    await tester.tap(find.text('High'));
    await tester.pumpAndSettle();
    expect(find.textContaining('L, High'), findsOneWidget);
    expect(Services.instance.settings.config('photo', 'resolution'), '720');
  });

  testWidgets('recording settings hide behind the icon by Record', (
    tester,
  ) async {
    await tester.pumpWidget(const GlazApp());
    await tester.tap(find.text('Remote'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.textContaining('Record  ·'), 200);
    expect(find.text('Record  ·  Speech'), findsOneWidget);

    await tester.tap(find.byTooltip('Recording settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Better'));
    await tester.pumpAndSettle();
    expect(Services.instance.settings.config('recorder', 'bits'), '16');
    expect(find.text('Save on the phone'), findsOneWidget);
    await tester.tap(find.text('Save on the phone'));
    await tester.pumpAndSettle();
    expect(Services.instance.settings.serviceOn('recordings'), isFalse);
    // the sheet away, the button says what it will do
    await tester.tapAt(const Offset(400, 20));
    await tester.pumpAndSettle();
    expect(find.text('Record  ·  Better'), findsOneWidget);
  });

  testWidgets('recording on the glasses shows everywhere, red', (tester) async {
    await tester.pumpWidget(const GlazApp());
    await tester.tap(find.text('Remote'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.textContaining('Record  ·'), 200);
    expect(find.text('REC'), findsNothing);

    final recorder = Services.instance.recorder;
    await tester.runAsync(() async {
      recorder.onMessage([recStart, 8, 8]);
      await recorder.flush();
    });
    await tester.pump();
    // the strip over the app, the button turned red with the time
    expect(find.text('REC'), findsOneWidget);
    expect(find.text('STOP'), findsOneWidget);
    expect(find.textContaining('Record  ·'), findsNothing);
    expect(find.textContaining('Stop'), findsWidgets);
    expect(find.text('0:00'), findsWidgets);
    // over a page pushed on top too
    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Services'));
    await tester.pumpAndSettle();
    expect(find.text('REC'), findsOneWidget);

    await tester.runAsync(() async {
      recorder.onMessage([audioEnd]);
      await recorder.flush();
    });
    await tester.pump();
    expect(find.text('REC'), findsNothing);
  });

  testWidgets('Weather has a settings page with the Internet permission', (
    tester,
  ) async {
    final settings = Services.instance.settings;
    await tester.pumpWidget(const GlazApp());
    await tester.tap(find.text('Menu'));
    await tester.pumpAndSettle();

    // built already, but below the fold of the 800x600 test screen, and
    // only tappable once clear of the navigation bar
    await tester.scrollUntilVisible(
      find.text('Weather').hitTestable(),
      100,
      scrollable: find
          .descendant(
            of: find.byType(MenuScreen),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(find.text('Weather'));
    await tester.pumpAndSettle();
    expect(find.text('WEATHER'), findsOneWidget);

    expect(settings.netAllowed('weather'), isFalse);
    await tester.tap(find.text('Internet access'));
    await tester.pumpAndSettle();
    expect(settings.netAllowed('weather'), isTrue);

    await tester.enterText(find.widgetWithText(TextField, 'City'), 'Minsk');
    expect(settings.config('weather', 'city'), 'Minsk');
    // let SettingsSync's debounce run out (nothing is connected to send to)
    await tester.pump(const Duration(seconds: 1));
  });

  test('a saved tab order is kept, cleaned and completed', () {
    expect(tabOrderFrom(null), [
      'glasses',
      'photos',
      'recordings',
      'remote',
      'menu',
      'more',
    ]);
    expect(tabOrderFrom(['more', 'gone', 'glasses', 'more']), [
      'more',
      'glasses',
      'photos',
      'recordings',
      'remote',
      'menu',
    ]);
  });

  testWidgets('holding the bar opens its editing mode; Done closes it', (
    tester,
  ) async {
    await tester.pumpWidget(const GlazApp());
    expect(find.text('Done'), findsNothing);

    await tester.longPress(find.byType(NavigationBar));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Drag the icons to move them'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);

    await tester.tap(find.text('Done'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Done'), findsNothing);
    expect(find.byType(NavigationBar), findsOneWidget);
  });
}
