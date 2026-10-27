import 'package:flutter_test/flutter_test.dart';

import 'package:glaz/frame/link.dart';
import 'package:glaz/frame/protocol.dart';
import 'package:glaz/services/scales.dart';

void main() {
  test('a pentatonic goes alone, a mode with its pentatonic', () {
    expect(scaleAnswer(0), 'g0 14 minor pent|m pent|0357a|||');
    expect(scaleAnswer(2), 'g2 14 dorian|dorian|023579a|9|m pent|0357a');
    expect(scaleAnswer(8), 'g8 14 major pent|M pent|02479|||');
    expect(scaleAnswer(10), 'g10 14 major|major|024579b|b|M pent|02479');
    expect(scaleAnswer(9), 'g9 14 major blues|Mblues|023479|3|M pent|02479');
  });

  test('past either end it wraps round', () {
    expect(scaleAnswer(14), scaleAnswer(0));
    expect(scaleAnswer(255), scaleAnswer(255 % 14));
  });

  test('every scale fits the glasses: labels, notes, one-digit flavour', () {
    for (final s in guitarScales) {
      expect(s.short.length, lessThanOrEqualTo(6), reason: s.name);
      expect(s.name.length, lessThanOrEqualTo(12), reason: s.name);
      expect(s.notes.first, 0, reason: s.name);
      expect(s.notes.every((n) => n >= 0 && n < 12), isTrue, reason: s.name);
      if (s.flavour != null) expect(s.notes, contains(s.flavour));
      expect('${s.name}${s.short}'.contains('|'), isFalse);
    }
  });

  test('SCALE_GET is answered, other messages are not', () {
    final sent = <String>[];
    final service = ScalesService(FrameLink(), send: sent.add);
    service.onMessage([scaleGet, 3]);
    service.onMessage([scaleGet]);
    service.onMessage([tuner, 1, 0]);
    expect(sent, [scaleAnswer(3)]);
  });
}
