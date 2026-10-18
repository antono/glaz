import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:glaz/frame/link.dart';
import 'package:glaz/services/glasses_lua.dart';

void main() {
  test('the name before the cursor: its table and what is typed', () {
    expect(splitName('fra'), (null, 'fra'));
    expect(splitName('frame.'), ('frame', ''));
    expect(splitName('frame.disp'), ('frame', 'disp'));
    expect(splitName('x = frame.display.te'), ('frame.display', 'te'));
    expect(splitName('print(frame.battery'), ('frame', 'battery'));
    expect(splitName('137 + '), isNull);
    expect(splitName(''), isNull);
  });

  test('an answer in packets is put back together', () async {
    final lua = GlassesLua(FrameLink());
    // not connected: run() refuses before sending anything
    await expectLater(lua.run('1+1'), throwsA(isA<Exception>()));
    // packets for no question are dropped
    lua.onPacket([0x09, 1, 0, ...utf8.encode('+137')]);
  });
}
