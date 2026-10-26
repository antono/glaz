import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// app/glaz_display.lua on a stand-in for each display: Frame's (no
// width(), palette names, show() flips) and Halo's (256x256, colours as
// numbers, drawing at once). See docs/HALO.md.
const _module = '../app/glaz_display.lua';

Future<String> _run(String stub, String checks) async {
  final script = [
    stub,
    "local M = dofile('$_module')",
    checks,
    "print('ok')",
  ].join('\n');
  final r = await Process.run('lua', ['-e', script]);
  expect(r.stderr, isEmpty);
  return r.stdout as String;
}

const _frame = '''
local drawn, shown = {}, 0
frame = {
  time = { utc = function() return 0 end },
  fpga_read = function() return '\\0' end,
  display = {
    text = function(s, x, y, opt) drawn[#drawn + 1] = { s, x, y, opt } end,
    show = function() shown = shown + 1 end,
  },
}
''';

const _halo = '''
local drawn, font, cleared = {}, nil, 0
frame = { display = {
  width = function() return 256 end,
  set_font = function(id, size, scale) font = size end,
  text = function(s, x, y, color)
    assert(math.type(x) == 'integer' and math.type(y) == 'integer')
    assert(type(color) == 'number')
    drawn[#drawn + 1] = { s, x, y, color, font }
  end,
  clear = function() cleared = cleared + 1 end,
  show = function() error('Halo has no back buffer to show') end,
} }
''';

void main() {
  test(
    'Frame: text where it is asked, by palette name, and show() flips',
    () async {
      final out = await _run(_frame, '''
assert(not M.halo)
assert(M.layout.screen_w == 640 and M.layout.row_h == 55)
M.text('> Camera', 60, 65, 'WHITE')
assert(drawn[1][1] == '> Camera' and drawn[1][2] == 60 and drawn[1][3] == 65)
assert(drawn[1][4].color == 'WHITE')
M.begin() M.show()
assert(shown == 1)
M.blank()
assert(shown == 2 and drawn[2][1] == ' ')
''');
      expect(out, contains('ok'));
    },
  );

  test('Halo: centred, cut to the circle, ASCII, colours as numbers', () async {
    final out = await _run(_halo, '''
assert(M.halo)
assert(M.layout.screen_w == 256)
-- the middle row is the widest; a line at the edge holds nothing
assert(M.fit(120, 16) > M.fit(62, 16) and M.fit(250, 16) == 0)
M.text('> Camera', 60, 62, 'SKYBLUE')
local d = drawn[1]
assert(d[1] == '> Camera' and d[4] == 0x31A2F2 and d[5] == 16)
assert(d[2] == 128 - (8 * 16) // 2 + 1, 'not centred')
-- too long for its row: cut to what fits there
M.text(string.rep('x', 40), 0, 62)
assert(#drawn[2][1] == M.fit(62, 16) and drawn[2][4] == 0xFFFFFF)
-- the font has printable ASCII only
M.text('caf\\u{E9}', 0, 122)
assert(drawn[3][1] == 'caf?')
M.show()          -- nothing to flip
M.begin() M.blank()
assert(cleared == 2)
''');
    expect(out, contains('ok'));
  });
}
