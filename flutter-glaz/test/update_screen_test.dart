import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:glaz/frame/update_art.dart';
import 'package:glaz/frame/update_screen.dart';

void main() {
  test('the cables run from a connector to the eye, over the cables', () {
    for (final wire in updateWires) {
      for (var i = 0; i < wire.length; i += 3) {
        final (x, y, w) = (wire[i], wire[i + 1], wire[i + 2]);
        for (var dx = 0; dx < w; dx++) {
          expect(updateArt[y][x + dx], 'k', reason: 'cable at $x,$y');
        }
      }
    }
  });

  test('the art is one width, in the palette', () {
    final width = updateArt.first.length;
    expect(width.isEven, isTrue, reason: 'two pixels a byte');
    for (final row in updateArt) {
      expect(row.length, width);
      expect(row.split('').every(updateArtColors.containsKey), isTrue);
    }
  });

  test('every write fits the REPL, and the Lua draws whole bitmaps', () async {
    final writes = <String>[];
    final picture = GlassesPicture((lua, token) async {
      expect(lua, endsWith("print('$token')"));
      writes.add(lua);
    });
    await picture.load();
    await picture.draw('Uploading: a_long_module_name_137.lua', progress: .37);
    await picture.tick();
    await picture.draw('firmware update');
    await picture.freeze();
    // the sparks move on with every frame
    final phases = [
      for (final w in writes)
        if (RegExp(r'E\((\d)\)').firstMatch(w) case final m?) m[1],
    ];
    expect(phases, ['1', '2', '3']);
    for (final w in writes) {
      expect(w.length, lessThanOrEqualTo(GlassesPicture.maxWrite), reason: w);
    }

    // Frame's display as far as the picture uses it: every bitmap must hold
    // whole rows of its width, 4 bits a pixel.
    const stub = '''
local shown, bitmaps = 0, 0
frame = { display = {
  bitmap = function(x, y, w, fmt, pal, data)
    assert(fmt == 16 and pal == 0 and w % 2 == 0)
    assert(#data > 0 and #data % (w // 2) == 0, 'ragged bitmap')
    assert(x >= 0 and x + w <= 640 and y >= 0 and y < 340, 'off screen')
    bitmaps = bitmaps + 1
  end,
  text = function(s, x, y) assert(#s <= 25) end,
  show = function() shown = shown + 1 end,
} }
''';
    final script = [
      stub,
      ...writes,
      // three frames of art, a bar, and sparks on top
      "frame.display.show() assert(shown == 3, 'frozen') "
          "assert(bitmaps > ${updateArt.length * 3 + 1}) print('ok')",
    ].join('\n');
    final r = await Process.run('lua', ['-e', script]);
    expect(r.stderr, isEmpty);
    expect(r.stdout, contains('ok'));
  });
}
