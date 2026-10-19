import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaz/flipper/flipper_ble.dart';
import 'package:glaz/flipper/proto.dart';
import 'package:glaz/frame/link.dart';
import 'package:glaz/frame/protocol.dart';
import 'package:glaz/services/flipper.dart';
import 'package:glaz/settings.dart';

class FakeFlipper implements FlipperPort {
  final written = <List<int>>[];
  final _received = StreamController<List<int>>.broadcast(sync: true);
  final _lost = StreamController<void>.broadcast(sync: true);
  FlipperTrouble? refuse;
  int opened = 0;
  int closed = 0;

  @override
  Future<void> open() async {
    if (refuse != null) throw refuse!;
    opened++;
  }

  @override
  Future<void> close() async => closed++;
  @override
  Future<void> write(List<int> bytes) async => written.add(bytes);
  @override
  Stream<List<int>> get received => _received.stream;
  @override
  Stream<void> get lost => _lost.stream;

  /// A screen frame, in two pieces as Bluetooth would bring it.
  void frame(List<int> data) {
    final m = mainMessage(0, mainScreenFrame, [
      0x0A, ...varint(data.length), ...data, //
    ]);
    _received.add(m.sublist(0, 100));
    _received.add(m.sublist(100));
  }

  void drop() => _lost.add(null);

  /// The PB_Main content fields written, in order.
  List<int> get contents => [
    for (final w in written) decodeMain(Uint8List.fromList(w.sublist(1))).content,
  ];
}

Uint8List fixture(String name) =>
    File('test/fixtures/$name').readAsBytesSync();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Settings settings;
  late FrameLink link;
  late FakeFlipper flipperZero;
  late List<List<int>> sent;
  late FlipperMirror mirror;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = await Settings.load();
    link = FrameLink()..state = LinkState.connected;
    flipperZero = FakeFlipper();
    sent = [];
    mirror = FlipperMirror(link, settings, port: flipperZero, send: sent.add);
  });

  /// What went to the module: 'f' frames and 's' words, prefix stripped.
  List<List<int>> toModule() => [
    for (final s in sent)
      if (String.fromCharCodes(s.take(8)) == 'flipper\n') s.sublist(8),
  ];
  List<List<int>> frames() =>
      toModule().where((m) => m[0] == 0x66).toList();
  List<String> words() => [
    for (final m in toModule())
      if (m[0] == 0x73) String.fromCharCodes(m.sublist(1)),
  ];

  test('on screen: the stream starts, and the first frame is every row', () {
    fakeAsync((async) {
      mirror.onEvent([flipper, 1]);
      async.flushMicrotasks();
      expect(flipperZero.opened, 1);
      expect(flipperZero.contents, [mainStartScreenStream]);
      expect(words().last, 'press a Flipper button');

      flipperZero.frame(fixture('flipper_frame_a.bin'));
      async.flushMicrotasks();
      final f = frames().single;
      expect(f[1], 1, reason: 'seq');
      expect(f.sublist(2, 10), List.filled(8, 0xFF));
      expect(f.sublist(10), [
        for (final b in toRows(fixture('flipper_frame_a.bin'))) ...[
          b >> 4,
          b & 15,
        ],
      ]);
    });
  });

  test('one frame at a time: the next waits for the answer', () {
    fakeAsync((async) {
      mirror.onEvent([flipper, 1]);
      async.flushMicrotasks();
      flipperZero.frame(fixture('flipper_frame_a.bin'));
      flipperZero.frame(fixture('flipper_frame_b.bin'));
      async.flushMicrotasks();
      expect(frames().length, 1, reason: 'b waits');

      mirror.onEvent([flipper, 2, 1]);
      async.flushMicrotasks();
      expect(frames().length, 2);
      final f = frames().last;
      expect(f[1], 2);
      expect(f.length, lessThan(2 + 8 + frameBytes * 2), reason: 'changes only');

      mirror.onEvent([flipper, 2, 2]);
      flipperZero.frame(fixture('flipper_frame_b.bin'));
      async.flushMicrotasks();
      expect(frames().length, 2, reason: 'nothing changed');
    });
  });

  test('no answer: every row again', () {
    fakeAsync((async) {
      mirror.onEvent([flipper, 1]);
      async.flushMicrotasks();
      flipperZero.frame(fixture('flipper_frame_a.bin'));
      async.flushMicrotasks();
      async.elapse(FlipperMirror.answerWait);
      expect(frames().length, 2);
      expect(frames().last.sublist(2, 10), List.filled(8, 0xFF));
    });
  });

  test('a stale answer is ignored', () {
    fakeAsync((async) {
      mirror.onEvent([flipper, 1]);
      async.flushMicrotasks();
      flipperZero.frame(fixture('flipper_frame_a.bin'));
      flipperZero.frame(fixture('flipper_frame_b.bin'));
      async.flushMicrotasks();
      mirror.onEvent([flipper, 2, 99]);
      async.flushMicrotasks();
      expect(frames().length, 1);
    });
  });

  test('gone: the stream stops and the Flipper is let go', () {
    fakeAsync((async) {
      mirror.onEvent([flipper, 1]);
      async.flushMicrotasks();
      mirror.onEvent([flipper, 0]);
      async.flushMicrotasks();
      expect(flipperZero.contents, [
        mainStartScreenStream,
        mainStopScreenStream,
      ]);
      expect(flipperZero.closed, 1);
      flipperZero.frame(fixture('flipper_frame_a.bin'));
      async.flushMicrotasks();
      expect(frames(), isEmpty);
    });
  });

  test('no Flipper: the glasses are told, and it is tried again', () {
    fakeAsync((async) {
      flipperZero.refuse = const FlipperTrouble('no Flipper found');
      mirror.onEvent([flipper, 1]);
      async.flushMicrotasks();
      expect(words().last, 'no Flipper found');
      flipperZero.refuse = null;
      async.elapse(FlipperMirror.retryAfter);
      expect(flipperZero.opened, 1);
    });
  });

  test('lost: said, and back by itself', () {
    fakeAsync((async) {
      mirror.onEvent([flipper, 1]);
      async.flushMicrotasks();
      flipperZero.drop();
      async.flushMicrotasks();
      expect(words().last, 'Flipper lost');
      async.elapse(FlipperMirror.retryAfter);
      expect(flipperZero.opened, 2);
    });
  });

  test('the service off: nothing is opened', () {
    fakeAsync((async) {
      settings.setService('flipper', false);
      mirror.onEvent([flipper, 1]);
      async.flushMicrotasks();
      expect(flipperZero.opened, 0);
      expect(words().last, 'Flipper is off in glaz');
    });
  });

  test('a button: press, short, release', () {
    fakeAsync((async) {
      mirror.onEvent([flipper, 1]);
      async.flushMicrotasks();
      flipperZero.written.clear();
      mirror.press(FlipperKey.back);
      async.flushMicrotasks();
      expect(flipperZero.contents, List.filled(3, mainSendInputEvent));
    });
  });

  test('words for the glasses are ASCII', () {
    fakeAsync((async) {
      flipperZero.refuse = const FlipperTrouble('no Flipper found');
      mirror.onEvent([flipper, 1]);
      async.flushMicrotasks();
      for (final w in words()) {
        expect(w.codeUnits.every((c) => c < 128), isTrue, reason: w);
      }
    });
  });
}
