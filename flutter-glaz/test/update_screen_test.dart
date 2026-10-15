import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:glaz/frame/update_art.dart';
import 'package:glaz/frame/update_screen.dart';

void main() {
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
    await picture.draw('firmware update');
    await picture.freeze();
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
    assert(x >= 0 and x + w <= 640, 'off screen')
    bitmaps = bitmaps + 1
  end,
  text = function(s, x, y) assert(#s <= 25) end,
  show = function() shown = shown + 1 end,
} }
''';
    final script = [
      stub,
      ...writes,
      "frame.display.show() assert(shown == 2, 'frozen') "
          "assert(bitmaps == ${updateArt.length * 2 + 1}) print('ok')",
    ].join('\n');
    final r = await Process.run('lua', ['-e', script]);
    expect(r.stderr, isEmpty);
    expect(r.stdout, contains('ok'));
  });
}
