import 'package:flutter_test/flutter_test.dart';

import 'package:glaz/frame/link.dart';

/// The payload back out of [packets], as data.lua on the glasses puts it
/// together: the first packet's length, then every packet's bytes.
List<int> reassemble(List<List<int>> packets, int code) {
  final first = packets.first;
  expect(first[0], 0x01);
  expect(first[1], code);
  final size = first[2] << 8 | first[3];
  final out = [...first.sublist(4)];
  for (final p in packets.skip(1)) {
    expect(p.sublist(0, 2), [0x01, code]);
    out.addAll(p.sublist(2));
  }
  expect(out.length, size);
  return out;
}

void main() {
  const max = 240; // a 244 MTU's maxDataLength, as frame_ble works it out

  test('every packet fits, and the payload comes back whole', () {
    for (final n in [1, 2, 137, max - 4, max - 3, max - 2, max, 1000, 2100]) {
      final payload = [for (var i = 0; i < n; i++) i & 0xFF];
      final packets = messagePackets(0x2D, payload, max);
      expect(
        packets.every((p) => p.length <= max + 1),
        isTrue,
        reason: '$n bytes',
      );
      expect(reassemble(packets, 0x2D), payload, reason: '$n bytes');
    }
  });

  test('as frame_ble cuts it: a full first packet, then full ones', () {
    final packets = messagePackets(0x2D, List.filled(1000, 7), max);
    // 237 in the first, 239 in the next three, 46 in the last
    expect([for (final p in packets) p.length], [241, 241, 241, 241, 48]);
  });

  test('no payload, no packets', () {
    expect(messagePackets(0x22, [], max), isEmpty);
  });
}
