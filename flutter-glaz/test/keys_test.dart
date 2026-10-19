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

  test("Keynote's Back as a pop of the route: dropped, once", () async {
    expect(await keys.didPopRoute(), isFalse, reason: 'no Back key yet');
    press(LogicalKeyboardKey.backspace, 0);
    expect(await keys.didPopRoute(), isTrue);
    expect(await keys.didPopRoute(), isFalse, reason: 'the next is real');
  });

  test('Back is held while the keys are taken', () {
    keys.attach();
    expect(keys.holdsBack, isTrue);
    link.state = LinkState.disconnected;
    link.notifyListeners();
    expect(keys.holdsBack, isFalse);
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

  // Android key codes (android.view.KeyEvent), as KeyRemoteService sends
  const dpadUp = 19, dpadRight = 22, dpadCenter = 23, del = 67;

  test('the background service takes the same keys', () {
    expect(
      KeyRemote.androidCodes,
      containsAll([dpadUp, dpadRight, dpadCenter, del, 62, 66, 92, 93, 82]),
    );
    expect(KeyRemote.androidCodes, isNot(contains(4)), reason: 'Back');
    expect(KeyRemote.androidCodes, isNot(contains(45)), reason: 'Q');
  });

  test('keys from the background drive the glasses alike', () {
    void bg(int action, int code, int ms) =>
        keys.fromBackground([action, code, 0, ms]);
    bg(0, dpadUp, 0);
    bg(2, dpadUp, 50);
    bg(0, dpadRight, 1000);
    bg(2, dpadRight, 1050);
    bg(0, dpadCenter, 2000);
    bg(2, dpadCenter, 2137);
    // held: Android repeats the key down, then one up
    bg(0, dpadCenter, 3000);
    for (var ms = 3400; ms < 3700; ms += 50) {
      bg(1, dpadCenter, ms);
    }
    bg(2, dpadCenter, 3700);
    bg(0, del, 4000);
    bg(2, del, 4050);
    link.state = LinkState.disconnected;
    bg(0, dpadUp, 5000);
    bg(2, dpadUp, 5050);
    expect(sent, [
      [2, 255],
      [2, 1],
      [1, 1],
      [1, 3],
      [1, 2],
    ]);
  });

  test('an attached keyboard drives the glasses only while it can', () {
    settings.setService('keys', false);
    keys.keyboard = true;
    expect(keys.drives(shown: true), isFalse, reason: 'service off');
    settings.setService('keys', true);
    expect(keys.drives(shown: true), isTrue);
    expect(keys.drives(shown: false), isFalse, reason: 'no background');
    keys.background = true;
    expect(keys.drives(shown: false), isTrue);
    keys.keyboard = false;
    expect(keys.drives(shown: true), isFalse);
  });
}
