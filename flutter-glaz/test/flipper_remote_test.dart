import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaz/flipper/remote_status.dart';
import 'package:glaz/frame/link.dart';
import 'package:glaz/frame/protocol.dart';
import 'package:glaz/glasses_menu.dart';
import 'package:glaz/services/flipper_remote.dart';
import 'package:glaz/services/glasses_lua.dart';
import 'package:glaz/services/keys.dart';
import 'package:glaz/settings.dart';

class FakeFlipper implements FlipperStatusPort {
  final written = <List<int>>[];
  final _lost = StreamController<void>.broadcast(sync: true);
  bool there = true;
  int opened = 0;
  int closed = 0;

  @override
  Future<bool> open() async {
    opened++;
    return there;
  }

  @override
  Future<void> close() async => closed++;
  @override
  Future<void> write(List<int> bytes) async => written.add(bytes);
  @override
  Stream<void> get lost => _lost.stream;

  void drop() => _lost.add(null);
}

/// The status' text fields, by tag, as the Flipper reads them.
Map<int, String> texts(List<int> b) {
  final out = <int, String>{};
  for (var i = 1; i + 1 < b.length; i += 2 + b[i + 1]) {
    if (b[i] == 1 || b[i] == 4) {
      out[b[i]] = String.fromCharCodes(b.sublist(i + 2, i + 2 + b[i + 1]));
    }
  }
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('encodeStatus', () {
    test('nothing known: the version alone', () {
      expect(encodeStatus(const GlassesStatus()), [1]);
    });

    test('every field, numbers little-endian', () {
      expect(
        encodeStatus(
          const GlassesStatus(
            name: 'Frame',
            diskFree: 137 * 1024,
            memFree: 137,
            app: 'Clock',
          ),
        ),
        [
          1,
          1, 5, ...'Frame'.codeUnits, //
          2, 4, 0x00, 0x24, 0x02, 0x00,
          3, 4, 137, 0, 0, 0,
          4, 5, ...'Clock'.codeUnits,
        ],
      );
    });

    test('text: ASCII only, 23 bytes at most', () {
      final b = encodeStatus(GlassesStatus(name: 'Очки ${'x' * 40}'));
      expect(b[2], maxText);
      expect(String.fromCharCodes(b.sublist(3, 8)), '???? ');
    });
  });

  group('FlipperRemote', () {
    late Settings settings;
    late FrameLink link;
    late KeyRemote keys;
    late FakeFlipper flipperZero;
    late FlipperRemote remote;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      settings = await Settings.load();
      link = FrameLink()
        ..state = LinkState.connected
        ..name = 'Frame 137';
      keys = KeyRemote(link, settings, send: (_) {});
      flipperZero = FakeFlipper();
      remote = FlipperRemote(
        link,
        settings,
        keys,
        GlassesLua(link),
        port: flipperZero,
      );
    });

    // ignore: invalid_use_of_protected_member
    void changed(dynamic n) => n.notifyListeners();

    test('no keyboard: no Flipper looked for', () {
      fakeAsync((async) {
        remote.attach();
        async.flushMicrotasks();
        expect(flipperZero.opened, 0);
      });
    });

    test('a keyboard: the Flipper gets the glasses and the menu', () {
      fakeAsync((async) {
        keys.keyboard = true;
        remote.attach();
        async.flushMicrotasks();
        expect(flipperZero.opened, 1);
        expect(remote.connected, isTrue);
        expect(texts(flipperZero.written.last), {1: 'Frame 137', 4: 'Menu'});
      });
    });

    test('the app on screen, by its number in tree order', () {
      fakeAsync((async) {
        keys.keyboard = true;
        remote.attach();
        async.flushMicrotasks();
        final first = glassesMenu.first.modules.first.label;

        remote.onEvent([appStart, 1]);
        expect(texts(flipperZero.written.last)[4], first);
        remote.onEvent([appStop, 2]); // another one: nothing changes
        expect(texts(flipperZero.written.last)[4], first);
        remote.onEvent([appBackground, 1]);
        expect(texts(flipperZero.written.last)[4], 'Menu');
      });
    });

    test('the same status is not written twice', () {
      fakeAsync((async) {
        keys.keyboard = true;
        remote.attach();
        async.flushMicrotasks();
        final n = flipperZero.written.length;
        changed(link);
        remote.onEvent([appStop, 1]);
        expect(flipperZero.written.length, n);
      });
    });

    test('the glasses gone: the Flipper is told, with no name', () {
      fakeAsync((async) {
        keys.keyboard = true;
        remote.attach();
        async.flushMicrotasks();
        remote.onEvent([appStart, 1]);
        link.state = LinkState.disconnected;
        changed(link);
        expect(flipperZero.written.last, [1]);
      });
    });

    test('the keyboard gone: the Flipper let go', () {
      fakeAsync((async) {
        keys.keyboard = true;
        remote.attach();
        async.flushMicrotasks();
        keys.keyboard = false;
        changed(keys);
        expect(flipperZero.closed, 1);
        expect(remote.connected, isFalse);
      });
    });

    test('no Flipper with the app: looked for again a minute on', () {
      fakeAsync((async) {
        flipperZero.there = false;
        keys.keyboard = true;
        remote.attach();
        async.flushMicrotasks();
        expect(flipperZero.opened, 1);
        flipperZero.there = true;
        async.elapse(FlipperRemote.every);
        expect(flipperZero.opened, 2);
        expect(remote.connected, isTrue);
        expect(texts(flipperZero.written.last)[1], 'Frame 137');
      });
    });

    test('the Flipper lost: written whole when it is back', () {
      fakeAsync((async) {
        keys.keyboard = true;
        remote.attach();
        async.flushMicrotasks();
        flipperZero.drop();
        expect(remote.connected, isFalse);
        async.elapse(FlipperRemote.every);
        expect(flipperZero.opened, 2);
        expect(texts(flipperZero.written.last)[1], 'Frame 137');
      });
    });

    test('off in Services: no Flipper looked for', () {
      fakeAsync((async) {
        settings.setService('flipper_remote', false);
        keys.keyboard = true;
        remote.attach();
        async.flushMicrotasks();
        expect(flipperZero.opened, 0);
      });
    });
  });
}
