import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// The glasses' parts (docs/DEVICES.md), run in Lua 5.4 on stand-ins for
// each pair of glasses: the app's parts, glaz.frame.lua and glaz.halo.lua,
// and glaz_boot's require(), which hands a file its part.

Future<String> _run(String script) async {
  final r = await Process.run('lua', ['-e', '$script\nprint("ok")']);
  expect(r.stderr, isEmpty);
  return r.stdout as String;
}

// Frame's display: no clear(), palette names, show() flips.
const _frame = '''
local drawn, shown, bitmaps = {}, 0, {}
frame = {
  time = { utc = function() return 0 end },
  fpga_read = function() return '\\0' end,
  display = {
    text = function(s, x, y, opt) drawn[#drawn + 1] = { s, x, y, opt } end,
    show = function() shown = shown + 1 end,
    bitmap = function(x, y, w, f, p, bits) bitmaps[#bitmaps + 1] = { x, p } end,
  },
}
''';

// Halo's: 256x256, colours as numbers, drawing at once.
const _halo = '''
local drawn, font, cleared, bitmaps = {}, nil, 0, {}
frame = { display = {
  set_font = function(id, size, scale) font = size end,
  text = function(s, x, y, color)
    assert(math.type(x) == 'integer' and math.type(y) == 'integer')
    assert(type(color) == 'number')
    drawn[#drawn + 1] = { s, x, y, color, font }
  end,
  clear = function() cleared = cleared + 1 end,
  bitmap = function(x, y, w, f, p, bits) bitmaps[#bitmaps + 1] = { x, p } end,
} }
''';

// A top bar to draw: the path cut to n, a recording, a quiet link.
const _bar = '''
local cut
local bar = {
  path = function(n) cut = n return 'Glaz > Apps' end,
  icon = { 2, 'rec' }, link = { 6, 'bt' },
  clock = '12:34', level = 9, low = true,
}
''';

// A file system for glaz_boot: name -> text, read as each pair of glasses
// reads it (Frame: a line at a time, at most 512 bytes, the line break
// dropped; Halo: n bytes).
String _files(Map<String, String> files) {
  final entries = [
    for (final MapEntry(:key, :value) in files.entries)
      "['$key'] = [==[$value]==],",
  ].join('\n');
  return '''
local FILES = { $entries }
local function handle(text)
  local at = 1
  return {
    read = function(_, n)
      if at > #text then return nil end
      if n then
        local s = string.sub(text, at, at + n - 1)
        at = at + #s
        return s
      end
      local nl = string.find(text, '\\n', at, true)
      local stop = math.min(nl and nl - 1 or #text, at + 511)
      local s = string.sub(text, at, stop)
      at = stop + 1
      if nl == at then at = at + 1 end
      return s
    end,
    write = function() end,
    close = function() end,
  }
end
frame = frame or {}
frame.file = {
  open = function(name, mode)
    if mode == 'write' then return handle('') end
    local text = FILES[name]
    if not text then error('no file ' .. name) end
    return handle(text)
  end,
  listdir = function()
    local out = {}
    for k, v in pairs(FILES) do out[#out + 1] = { name = k, size = #v } end
    return out
  end,
}
frame.imu = { tap_callback = function() end }
frame.bluetooth = { receive_callback = function() end }
frame.time = frame.time or { utc = function() return 0 end }
frame.sleep = function() end
''';
}

String _read(String path) => File(path).readAsStringSync();

void main() {
  test(
    'Frame: text where it is asked, by palette name, show() flips',
    () async {
      final out = await _run('''
$_frame
local D = dofile('../glaz.frame.lua')
assert(D.layout.row_h == 55 and D.layout.left_x == 60)
D.text('> Camera', 60, 65, 'WHITE')
assert(drawn[1][1] == '> Camera' and drawn[1][2] == 60 and drawn[1][3] == 65)
assert(drawn[1][4].color == 'WHITE')
D.begin() D.show()
assert(shown == 1)
D.blank()
assert(shown == 2 and drawn[2][1] == ' ')
$_bar
D.top_bar(bar)
-- the path stops short of the icon; the battery is red
assert(cut == (376 - 10 - 60) // 20)
assert(bitmaps[1][1] == 376 and bitmaps[1][2] == 2)
assert(bitmaps[2][1] == 400 and bitmaps[2][2] == 6)
assert(drawn[#drawn][1] == '9%' and drawn[#drawn][4].color == 'RED')
''');
      expect(out, contains('ok'));
    },
  );

  test('Halo: centred, cut to the circle, ASCII, colours as numbers', () async {
    final out = await _run('''
$_halo
local D = dofile('../glaz.halo.lua')
-- the middle row is the widest; a line at the edge holds nothing
assert(D.fit(122, 16) > D.fit(62, 16) and D.fit(250, 16) == 0)
-- notifications wrap where the narrowest rows cut
assert(D.layout.notice_chars == D.fit(62, 16))
assert(D.layout.notice_chars == D.fit(62 + 4 * 30, 16))
D.text('> Camera', 60, 62, 'SKYBLUE')
local d = drawn[1]
assert(d[1] == '> Camera' and d[4] == 0x31A2F2 and d[5] == 16)
assert(d[2] == 128 - (8 * 16) // 2 + 1, 'not centred')
-- too long for its row: cut to what fits there
D.text(string.rep('x', 40), 0, 62)
assert(#drawn[2][1] == D.fit(62, 16) and drawn[2][4] == 0xFFFFFF)
-- the font has printable ASCII only
D.text('caf\\u{E9}', 0, 122)
assert(drawn[3][1] == 'caf?')
D.show()          -- nothing to flip
D.begin() D.blank()
assert(cleared == 2)
$_bar
D.top_bar(bar)
assert(cut == D.fit(42, 8))
assert(bitmaps[1][2] == 2 and bitmaps[2][2] == 6)
''');
    expect(out, contains('ok'));
  });

  for (final device in ['frame', 'halo']) {
    final other = device == 'frame' ? 'halo' : 'frame';
    test('$device: require() hands a file its part, and no other', () async {
      final out = await _run('''
${_files({
        'main.lua': _read('../app/glaz_boot.$device.lua'),
        'glaz_boot.lua': _read('../app/glaz_boot.lua'),
        'glaz_app.lua': 'local name, D = ...\n'
            'RESULT = { name = name, D = D, m = require("m"),\n'
            '  only = require("only"), plain = require("plain") }\n'
            'RESULT.elsewhere = pcall(require, "elsewhere")\n',
        'glaz_app.$device.lua': 'return { device = "$device" }',
        'm.lua': 'local _, D = ...\nreturn { D = D }',
        'm.$device.lua': 'return { x = 1 }',
        'only.$device.lua': 'return "only $device"',
        'plain.lua': 'local _, D = ...\nreturn D == nil',
        // another pair's part, as if left behind: never loaded
        'elsewhere.$other.lua': 'return 1',
      })}
local f = frame.file.open('main.lua', 'read')
assert(load(f:read(1 << 20), '=main.lua'))()
assert(RESULT.name == 'glaz_app' and RESULT.D.device == '$device')
assert(RESULT.m.D.x == 1)
assert(RESULT.only == 'only $device')
assert(RESULT.plain == true)
assert(RESULT.elsewhere == false)
''');
      expect(out, contains('ok'));
    });

    // The host's break, as these glasses raise it: once on Halo, so the
    // app's pcalls must hand it on, and glaz_boot must not take it for a
    // crash and start the app again.
    final brk = device == 'frame' ? 'break signal' : 'interrupted';
    test('$device: a break stops the app, not restarts it', () async {
      final out = await _run('''
${_files({'main.lua': _read('../app/glaz_boot.$device.lua'), 'glaz_boot.lua': _read('../app/glaz_boot.lua'), 'glaz_app.lua': 'STARTS = (STARTS or 0) + 1\n'
          'local ok, e = pcall(error, "glaz_app.lua:1: $brk", 0)\n'
          'if not ok and glaz_break(e) then error(e, 0) end\n'
          'error("kept the break")\n'})}
local printed = {}
print = function(s) printed[#printed + 1] = tostring(s) end
local f = frame.file.open('main.lua', 'read')
local ok, e = pcall(assert(load(f:read(1 << 20), '=main.lua')))
assert(not ok and string.find(e, '$brk', 1, true), tostring(e))
assert(STARTS == 1, 'restarted ' .. STARTS)
assert(#printed == 0, printed[1])
io.write('ok')
''');
      expect(out, contains('ok'));
    });
  }
}
