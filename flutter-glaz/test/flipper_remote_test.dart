import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaz/flipper/companion.dart';
import 'package:glaz/flipper/presses.dart';
import 'package:glaz/flipper/remote_status.dart';
import 'package:glaz/frame/link.dart';
import 'package:glaz/frame/protocol.dart';
import 'package:glaz/glasses_menu.dart';
import 'package:glaz/services/flipper_remote.dart';
import 'package:glaz/services/glasses_lua.dart';
import 'package:glaz/services/glaz_log.dart';
import 'package:glaz/settings.dart';

class FakeFlipper implements FlipperStatusPort {
  final written = <List<int>>[];

  /// Set: [open] waits for it, as a connect does.
  Completer<bool>? slow;
  final _lost = StreamController<void>.broadcast(sync: true);
  final _keys = StreamController<List<int>>.broadcast(sync: true);
  bool there = true;
  int opened = 0;
  int closed = 0;
  bool _open = false;

  @override
  String? get name => _open ? 'Glaz' : null;

  @override
  Future<bool> open() async {
    opened++;
    return _open = await (slow?.future ?? Future.value(there));
  }

  @override
  Future<void> close() async {
    _open = false;
    closed++;
  }

  @override
  Future<void> write(List<int> bytes) async => written.add(bytes);
  @override
  Stream<void> get lost => _lost.stream;
  @override
  Stream<List<int>> get keys => _keys.stream;

  void drop() => _lost.add(null);
  void press(List<int> bytes) => _keys.add(bytes);
}

/// Android's Companion Device Manager, as a list: [pair] adds [next].
class FakeCompanion implements FlipperCompanion {
  final list = <FlipperPaired>[];
  FlipperPaired? next = const FlipperPaired('13:37:13:37:01:37', 'Glaz');

  @override
  Future<FlipperPaired?> pair() async {
    final p = next;
    if (p != null) list.add(p);
    return p;
  }

  @override
  Future<List<FlipperPaired>> paired() async => [...list];

  @override
  Future<void> forget(String address) async =>
      list.removeWhere((p) => p.address == address);

  /// What [observe] was told, in order.
  final observed = <bool>[];

  @override
  Future<void> observe(bool on) async => observed.add(on);
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

  group('flipperLabel', () {
    test('the association\'s name first', () {
      expect(flipperLabel('Glaz', 'Flipper Uge1t', '13:37'), 'Glaz');
    });

    test('a device made from an address has no name: Bluetooth\'s, '
        'else the address', () {
      expect(flipperLabel(null, '', '13:37:13:37:01:37'), '13:37:13:37:01:37');
      expect(flipperLabel('', 'Glaz', '13:37'), 'Glaz');
      expect(flipperLabel(null, 'Glaz', '13:37'), 'Glaz');
    });
  });

  group('presses', () {
    test('decoded: version 1, the key and the press', () {
      expect(
        decodePress([1, 1, 1]),
        const FlipperKeyPress(FlipperKey.up, FlipperPress.short),
      );
      expect(
        decodePress([1, 6, 3]),
        const FlipperKeyPress(FlipperKey.back, FlipperPress.repeat),
      );
      expect(decodePress([1, 5, 2]).toString(), 'ok long');
      // Glaz's order, not the RPC's: Left 3, Right 4
      expect(decodePress([1, 3, 1])!.key, FlipperKey.left);
      expect(decodePress([1, 4, 1])!.key, FlipperKey.right);
    });

    test('anything else: null', () {
      expect(decodePress([]), isNull);
      expect(decodePress([1, 1]), isNull);
      expect(decodePress([1, 1, 1, 137]), isNull);
      expect(decodePress([2, 1, 1]), isNull);
      expect(decodePress([1, 0, 1]), isNull);
      expect(decodePress([1, 7, 1]), isNull);
      expect(decodePress([1, 1, 0]), isNull);
      expect(decodePress([1, 1, 4]), isNull);
    });

    test('mapped to the glasses\' gestures', () {
      const previous = [2, 255], next = [2, 1];
      final table = {
        for (final press in FlipperPress.values) ...{
          (FlipperKey.up, press): previous,
          (FlipperKey.left, press): previous,
          (FlipperKey.down, press): next,
          (FlipperKey.right, press): next,
        },
        (FlipperKey.ok, FlipperPress.short): [1, 1],
        (FlipperKey.ok, FlipperPress.long): [1, 3],
        (FlipperKey.ok, FlipperPress.repeat): null,
        (FlipperKey.back, FlipperPress.short): [1, 2],
        (FlipperKey.back, FlipperPress.long): null,
        (FlipperKey.back, FlipperPress.repeat): null,
      };
      expect(table.length, 18);
      table.forEach((kp, gesture) {
        expect(
          gestureFor(FlipperKeyPress(kp.$1, kp.$2)),
          gesture,
          reason: '${kp.$1.name} ${kp.$2.name}',
        );
      });
    });
  });

  group('FlipperRemote', () {
    late Settings settings;
    late FrameLink link;
    late FakeFlipper flipperZero;
    late FakeCompanion companion;
    late FlipperRemote remote;
    late List<List<int>> sent;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      settings = await Settings.load();
      link = FrameLink()
        ..state = LinkState.connected
        ..name = 'Frame 137';
      flipperZero = FakeFlipper();
      companion = FakeCompanion();
      sent = [];
      remote = FlipperRemote(
        link,
        settings,
        GlassesLua(link),
        port: flipperZero,
        companion: companion,
        send: sent.add,
      );
    });

    // ignore: invalid_use_of_protected_member
    void changed(dynamic n) => n.notifyListeners();

    test('the Flipper gets the glasses and the menu', () {
      fakeAsync((async) {
        remote.attach();
        async.flushMicrotasks();
        expect(flipperZero.opened, 1);
        expect(remote.connected, isTrue);
        expect(texts(flipperZero.written.last), {1: 'Frame 137', 4: 'Menu'});
      });
    });

    test('the app on screen, by its number in tree order', () {
      fakeAsync((async) {
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
        remote.attach();
        async.flushMicrotasks();
        remote.onEvent([appStart, 1]);
        link.state = LinkState.disconnected;
        changed(link);
        expect(flipperZero.written.last, [1]);
      });
    });

    test('off in Services: the Flipper let go', () {
      fakeAsync((async) {
        remote.attach();
        async.flushMicrotasks();
        settings.setService('flipper_remote', false);
        expect(flipperZero.closed, 1);
        expect(remote.connected, isFalse);
      });
    });

    test('no Flipper with the app: looked for again a minute on', () {
      fakeAsync((async) {
        flipperZero.there = false;
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
        remote.attach();
        async.flushMicrotasks();
        expect(flipperZero.opened, 0);
      });
    });
    test('presses reach the glasses', () {
      fakeAsync((async) {
        remote.attach();
        async.flushMicrotasks();
        flipperZero.press([1, 4, 1]); // Right
        flipperZero.press([1, 5, 2]); // OK, held
        flipperZero.press([1, 6, 2]); // Back, held: closes the Flipper app
        expect(sent, [
          [2, 1],
          [1, 3],
        ]);
      });
    });

    test('presses dropped while the glasses are gone or busy', () {
      fakeAsync((async) {
        remote.attach();
        async.flushMicrotasks();
        link.state = LinkState.disconnected;
        flipperZero.press([1, 5, 1]);
        link
          ..state = LinkState.connected
          ..task = 'Upload';
        flipperZero.press([1, 5, 1]);
        expect(sent, isEmpty);
        link.task = null;
        flipperZero.press([1, 5, 1]);
        expect(sent, [
          [1, 1],
        ]);
      });
    });

    test('garbage ignored', () {
      fakeAsync((async) {
        remote.attach();
        async.flushMicrotasks();
        for (final b in [
          <int>[],
          [1, 5],
          [2, 5, 1],
          [1, 0, 1],
          [1, 7, 1],
          [1, 5, 4],
          [1, 5, 1, 137],
        ]) {
          flipperZero.press(b);
        }
        expect(sent, isEmpty);
      });
    });

    test('paired Flippers are known once attached', () {
      fakeAsync((async) {
        companion.list.add(const FlipperPaired('13:37:13:37:13:37', null));
        remote.attach();
        async.flushMicrotasks();
        expect(remote.paired.single.address, '13:37:13:37:13:37');
      });
    });

    test('pair: the new Flipper listed and connected at once', () {
      fakeAsync((async) {
        flipperZero.there = false;
        remote.attach();
        async.flushMicrotasks();
        expect(remote.connected, isFalse);
        flipperZero.there = true;
        bool? ok;
        remote.pair().then((v) => ok = v);
        async.flushMicrotasks();
        expect(ok, isTrue);
        expect(remote.paired.single.name, 'Glaz');
        expect(remote.connected, isTrue);
        expect(texts(flipperZero.written.last)[1], 'Frame 137');
      });
    });

    test('pair cancelled: nothing changes', () {
      fakeAsync((async) {
        flipperZero.there = false;
        remote.attach();
        async.flushMicrotasks();
        companion.next = null;
        bool? ok;
        remote.pair().then((v) => ok = v);
        async.flushMicrotasks();
        expect(ok, isFalse);
        expect(remote.paired, isEmpty);
        expect(flipperZero.opened, 1);
      });
    });

    test('forget: the Flipper let go and unpaired', () {
      fakeAsync((async) {
        remote.attach();
        remote.pair();
        async.flushMicrotasks();
        remote.forget('13:37:13:37:01:37');
        async.flushMicrotasks();
        expect(flipperZero.closed, 1);
        expect(remote.connected, isFalse);
        expect(remote.paired, isEmpty);
      });
    });

    test('turned off while connecting: let go once connected', () {
      fakeAsync((async) {
        flipperZero.slow = Completer();
        remote.attach();
        async.flushMicrotasks();
        settings.setService('flipper_remote', false);
        flipperZero.slow!.complete(true);
        async.flushMicrotasks();
        expect(remote.connected, isFalse);
        expect(flipperZero.closed, 1);
        flipperZero.press([1, 5, 1]);
        expect(sent, isEmpty);
      });
    });

    test('forgotten while connecting: let go once connected', () {
      fakeAsync((async) {
        companion.list.add(const FlipperPaired('13:37:13:37:01:37', 'Glaz'));
        flipperZero.slow = Completer();
        remote.attach();
        async.flushMicrotasks();
        remote.forget('13:37:13:37:01:37');
        async.flushMicrotasks();
        flipperZero.slow!.complete(true);
        async.flushMicrotasks();
        expect(remote.connected, isFalse);
        expect(remote.paired, isEmpty);
        expect(flipperZero.closed, 1);
      });
    });

    test('Android watches for the paired Flipper while the service is on', () {
      fakeAsync((async) {
        companion.list.add(const FlipperPaired('13:37:13:37:01:37', 'Glaz'));
        remote.attach();
        async.flushMicrotasks();
        expect(companion.observed, [true]);
        changed(link); // nothing that matters: not told again
        settings.setService('flipper_remote', false);
        settings.setService('flipper_remote', true);
        async.flushMicrotasks();
        expect(companion.observed, [true, false, true]);
      });
    });

    test('nothing paired: Android not asked to watch', () {
      fakeAsync((async) {
        remote.attach();
        async.flushMicrotasks();
        settings.setService('flipper_remote', false);
        expect(companion.observed, isEmpty);
      });
    });

    test('pair: the new Flipper watched for too', () {
      fakeAsync((async) {
        companion.list.add(const FlipperPaired('13:37:13:37:13:37', null));
        remote.attach();
        async.flushMicrotasks();
        remote.pair();
        async.flushMicrotasks();
        expect(companion.observed, [true, true]);
      });
    });

    test('appeared: connected at once, not a minute on', () {
      fakeAsync((async) {
        flipperZero.there = false;
        remote.attach();
        async.flushMicrotasks();
        flipperZero.there = true;
        remote.appeared();
        async.flushMicrotasks();
        expect(flipperZero.opened, 2);
        expect(remote.connected, isTrue);
        remote.appeared(); // connected: nothing more
        async.flushMicrotasks();
        expect(flipperZero.opened, 2);
      });
    });

    test('appeared while off: left alone', () {
      fakeAsync((async) {
        settings.setService('flipper_remote', false);
        remote.attach();
        async.flushMicrotasks();
        remote.appeared();
        async.flushMicrotasks();
        expect(flipperZero.opened, 0);
      });
    });

    test('the name: the connected Flipper\'s', () {
      fakeAsync((async) {
        flipperZero.there = false;
        remote.attach();
        async.flushMicrotasks();
        expect(remote.name, isNull);
        flipperZero.there = true;
        async.elapse(FlipperRemote.every);
        expect(remote.name, 'Glaz');
      });
    });

    test('whose status the Flipper has is logged as it changes', () {
      fakeAsync((async) {
        bool told(LogEntry e) => e.text.startsWith('Flipper remote: told');
        final before = GlazLog.instance.entries.where(told).length;
        remote.attach();
        async.flushMicrotasks();
        remote.onEvent([appStart, 1]);
        async.flushMicrotasks();
        var logged = GlazLog.instance.entries.where(told).toList();
        expect(logged.length, before + 1);
        expect(logged.last.text, 'Flipper remote: told Frame 137');
        changed(link); // the same glasses: not logged again
        async.flushMicrotasks();
        expect(GlazLog.instance.entries.where(told).length, before + 1);
        link.state = LinkState.disconnected;
        changed(link);
        async.flushMicrotasks();
        logged = GlazLog.instance.entries.where(told).toList();
        expect(logged.length, before + 2);
        expect(logged.last.text, 'Flipper remote: told no glasses');
      });
    });

    test('drives the glasses while connected and on', () {
      fakeAsync((async) {
        expect(remote.drives, isFalse);
        remote.attach();
        async.flushMicrotasks();
        expect(remote.drives, isTrue);
        settings.setService('flipper_remote', false);
        expect(remote.drives, isFalse);
      });
    });
  });
}
