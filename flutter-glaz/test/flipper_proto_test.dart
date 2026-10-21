import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:glaz/flipper/proto.dart';

Uint8List fixture(String name) => File('test/fixtures/$name').readAsBytesSync();

/// A frame message as the Flipper sends one: command id 0, the frame in
/// field 22.
Uint8List frameMessage(List<int> data, [int orientation = 0]) =>
    mainMessage(0, mainScreenFrame, [
      0x0A, ...varint(data.length), ...data, // data = 1
      0x10, orientation, // orientation = 2
    ]);

/// Rows as they go to the glasses: a nibble a byte.
List<int> nibbles(List<int> rows) => [
  for (final b in rows) ...[b >> 4, b & 15],
];

bool pixel(Uint8List rows, int x, int y) =>
    rows[y * rowBytes + (x >> 3)] & (0x80 >> (x & 7)) != 0;

void main() {
  test('StartScreenStream, as a real Flipper took it', () {
    // sent over USB to a Flipper, which answered OK with command id 137
    expect(startScreenStream(137), [0x06, 0x08, 0x89, 0x01, 0xA2, 0x01, 0x00]);
  });

  test('an input event: OK, short', () {
    expect(inputEvent(5, FlipperKey.ok, FlipperInput.short), [
      0x09, 0x08, 0x05, 0xBA, 0x01, 0x04, 0x08, 0x04, 0x10, 0x02, //
    ]);
  });

  test('the answer to a request: its id, status OK, empty', () {
    final m = MessageSplitter().add([0x05, 0x08, 0x89, 0x01, 0x22, 0x00]);
    expect(m.single.commandId, 137);
    expect(m.single.status, 0);
    expect(m.single.content, mainEmpty);
  });

  test('a frame in pieces of any size comes out whole, once', () {
    final data = fixture('flipper_frame_a.bin');
    final msg = [...frameMessage(data), ...frameMessage(data, 1)];
    for (final size in [1, 7, 20, 243, 486, msg.length]) {
      final s = MessageSplitter();
      final got = <FlipperMessage>[];
      for (var i = 0; i < msg.length; i += size) {
        got.addAll(s.add(msg.sublist(i, (i + size).clamp(0, msg.length))));
      }
      expect(got.length, 2, reason: 'pieces of $size');
      expect(got.every((m) => m.isFrame && m.commandId == 0), isTrue);
      final f = decodeFrame(got.last.body);
      expect(f.data, data);
      expect(f.orientation, 1);
    }
  });

  test('pages become rows: one pixel each corner', () {
    final page = Uint8List(frameBytes);
    page[0] |= 1; // x 0, y 0
    page[127] |= 1 << 1; // x 127, y 1
    page[7 * 128] |= 1 << 7; // x 0, y 63
    page[7 * 128 + 127] |= 1 << 7; // x 127, y 63
    final rows = toRows(page);
    expect(rows[0], 0x80);
    expect(rows[rowBytes + 15], 0x01);
    expect(rows[63 * rowBytes], 0x80);
    expect(rows[63 * rowBytes + 15], 0x01);
    var lit = 0;
    for (final b in rows) {
      lit += b.toRadixString(2).replaceAll('0', '').length;
    }
    expect(lit, 4);
  });

  test('a real frame: every pixel lands where the page puts it', () {
    final page = fixture('flipper_frame_b.bin');
    final rows = toRows(page);
    for (var y = 0; y < screenH; y++) {
      for (var x = 0; x < screenW; x++) {
        final dark = page[(y ~/ 8) * 128 + x] >> (y % 8) & 1 == 1;
        expect(pixel(rows, x, y), dark, reason: '$x,$y');
      }
    }
  });

  test('turned round: the top left pixel goes bottom right', () {
    final page = Uint8List(frameBytes)..[0] = 1;
    final rows = toRows(page, orientationHorizontalFlip);
    expect(pixel(rows, 127, 63), isTrue);
    expect(pixel(rows, 0, 0), isFalse);
  });

  test('a cut frame is refused', () {
    expect(() => toRows(Uint8List(100)), throwsFormatException);
  });

  group('rowsUpdate', () {
    final a = toRows(fixture('flipper_frame_a.bin'));
    final b = toRows(fixture('flipper_frame_b.bin'));

    test('first time, every row', () {
      final u = rowsUpdate(a, null)!;
      expect(u.length, 8 + frameBytes * 2);
      expect(u.sublist(0, 8), List.filled(8, 0xFF));
      expect(u.sublist(8), nibbles(a));
      expect(u.sublist(8).every((n) => n < 16), isTrue);
    });

    test('nothing changed, nothing to send', () {
      expect(rowsUpdate(a, Uint8List.fromList(a)), isNull);
    });

    test('only the rows that changed, in order', () {
      final u = rowsUpdate(b, a)!;
      final changed = [
        for (var y = 0; y < screenH; y++)
          if (u[y >> 3] & (0x80 >> (y & 7)) != 0) y,
      ];
      expect(changed, isNotEmpty);
      expect(changed.length, lessThan(screenH));
      expect(u.length, 8 + changed.length * rowNibbles);
      // the glasses' rows, patched with it, are b
      final glasses = Uint8List.fromList(a);
      var at = 8;
      for (final y in changed) {
        for (var i = 0; i < rowBytes; i++) {
          glasses[y * rowBytes + i] = u[at + 2 * i] << 4 | u[at + 2 * i + 1];
        }
        at += rowNibbles;
      }
      expect(glasses, b);
    });
  });
}
