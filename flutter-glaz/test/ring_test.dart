import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaz/frame/link.dart';
import 'package:glaz/services/keys.dart';
import 'package:glaz/services/ring.dart';
import 'package:glaz/settings.dart';

/// The JX-05 as recorded on a Pixel 7 (getevent), in the phone's pixels:
/// the ring's 0..3583 is 0..2399.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<LogicalKeyboardKey> pressed;
  late Ring ring;

  setUp(() {
    pressed = [];
    ring = Ring(pressed.add);
  });

  void swipe(List<List<num>> path, int ms) {
    ring.motion([0, ...path.first, ms]);
    for (final p in path.skip(1)) {
      ring.motion([1, ...p, ms += 30]);
    }
    ring.motion([2, ...path.last, ms + 30]);
  }

  test('swipes are arrows, by their longer way', () {
    // up: y 2300 -> 200 raw
    swipe([
      [589, 1540],
      [589, 1000],
      [589, 134],
    ], 0);
    swipe([
      [589, 678],
      [589, 2344],
    ], 1000);
    swipe([
      [914, 1789],
      [500, 1789],
      [81, 1789],
    ], 2000);
    swipe([
      [292, 1789],
      [1870, 1800],
    ], 3000);
    expect(pressed, [
      LogicalKeyboardKey.arrowUp,
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.arrowLeft,
      LogicalKeyboardKey.arrowRight,
    ]);
  });

  test('a tap is select, after the wait for a second one', () {
    fakeAsync((async) {
      swipe([
        [589, 1540],
      ], 0);
      expect(pressed, isEmpty);
      async.elapse(Ring.twice);
      expect(pressed, [LogicalKeyboardKey.enter]);
    });
  });

  test('two taps 130 ms apart are back, and no select', () {
    fakeAsync((async) {
      swipe([
        [589, 1540],
      ], 0);
      async.elapse(const Duration(milliseconds: 135));
      swipe([
        [589, 1540],
      ], 135);
      async.elapse(const Duration(seconds: 1));
      expect(pressed, [LogicalKeyboardKey.escape]);
    });
  });

  test('a move or lift without a touch is nothing', () {
    ring.motion([1, 10, 10, 0]);
    ring.motion([2, 900, 10, 10]);
    expect(pressed, isEmpty);
  });

  test('a held volume key is one press: down the menu, up back', () {
    for (var ms = 0; ms < 1000; ms += 150) {
      ring.key([25, ms]);
    }
    ring.key([24, 3000]);
    ring.key([24, 3150]);
    ring.key([25, 5000]);
    expect(pressed, [
      LogicalKeyboardKey.contextMenu,
      LogicalKeyboardKey.escape,
      LogicalKeyboardKey.contextMenu,
    ]);
  });

  test('through the keyboard remote, to the glasses while connected', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = await Settings.load();
    final link = FrameLink()..state = LinkState.connected;
    final sent = <List<int>>[];
    final keys = KeyRemote(link, settings, send: sent.add);
    fakeAsync((async) {
      keys.ring.motion([0, 589, 1540, 0]);
      keys.ring.motion([2, 589, 134, 200]);
      keys.ring.motion([0, 589, 1540, 1000]);
      keys.ring.motion([2, 589, 1540, 1030]);
      async.elapse(Ring.twice);
      keys.ring.key([25, 2000]);
      keys.ring.key([24, 3000]);
      expect(sent, [
        [3, 255],
        [1, 1],
        [1, 3],
        [1, 2],
      ]);
      link.state = LinkState.disconnected;
      keys.ring.motion([0, 589, 1540, 4000]);
      keys.ring.motion([2, 1800, 1540, 4200]);
      expect(sent, hasLength(4));
    });
  });
}
