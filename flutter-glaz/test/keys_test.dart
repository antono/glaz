import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaz/frame/link.dart';
import 'package:glaz/services/keys.dart';
import 'package:glaz/settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Settings settings;
  late FrameLink link;
  late List<List<int>> sent;
  late KeyRemote keys;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = await Settings.load();
    link = FrameLink()..state = LinkState.connected;
    sent = [];
    keys = KeyRemote(link, settings, send: sent.add);
  });

  KeyEvent down(LogicalKeyboardKey key, int ms) => KeyDownEvent(
    physicalKey: PhysicalKeyboardKey.keyA,
    logicalKey: key,
    timeStamp: Duration(milliseconds: ms),
  );
  KeyEvent up(LogicalKeyboardKey key, int ms) => KeyUpEvent(
    physicalKey: PhysicalKeyboardKey.keyA,
    logicalKey: key,
    timeStamp: Duration(milliseconds: ms),
  );
  bool press(LogicalKeyboardKey key, int ms, {int held = 100}) {
    final a = keys.handle(down(key, ms));
    final b = keys.handle(up(key, ms + held));
    return a && b;
  }

  test('arrows tilt, Backspace is back, Menu the menu', () {
    expect(press(LogicalKeyboardKey.arrowUp, 0), isTrue);
    press(LogicalKeyboardKey.arrowRight, 1000);
    press(LogicalKeyboardKey.backspace, 2000);
    press(LogicalKeyboardKey.contextMenu, 3000);
    expect(sent, [
      [2, 255],
      [2, 1],
      [1, 2],
      [1, 3],
    ]);
  });

  test('OK selects on release; held, it opens the menu', () {
    expect(keys.handle(down(LogicalKeyboardKey.space, 0)), isTrue);
    expect(sent, isEmpty, reason: 'a hold is only known on release');
    keys.handle(up(LogicalKeyboardKey.space, 137));
    press(LogicalKeyboardKey.space, 1000, held: 700);
    expect(sent, [
      [1, 1],
      [1, 3],
    ]);
  });

  test("Keynote's Back: Backspace, then Android's Back, dropped", () {
    press(LogicalKeyboardKey.backspace, 0);
    expect(press(LogicalKeyboardKey.goBack, 50), isTrue);
    expect(sent, [
      [1, 2],
    ]);
    // a Back on its own is the phone's
    expect(press(LogicalKeyboardKey.goBack, 5000), isFalse);
  });

  test('other keys, and every key without the glasses, are left alone', () {
    expect(press(LogicalKeyboardKey.keyQ, 0), isFalse);
    link.state = LinkState.disconnected;
    expect(press(LogicalKeyboardKey.arrowDown, 1000), isFalse);
    link.state = LinkState.connected;
    settings.setService('keys', false);
    expect(press(LogicalKeyboardKey.arrowDown, 2000), isFalse);
    expect(sent, isEmpty);
  });
}
