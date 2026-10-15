import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:glaz/frame/lua_min.dart';

void main() {
  test('comments go, strings and line breaks stay', () {
    const src = '''
-- a comment
local clock = '--:--'   -- not a comment inside the string
local s = "a -- b"
local long = [[
  -- this is a string, kept as is
]]
--[[ a long
comment ]] local x = 137
  local y = 2 --[==[ ]] still a comment ]==]
''';
    final min = minifyLua(src);
    expect(min.split('\n').length, src.split('\n').length);
    expect(min, contains("local clock = '--:--'"));
    expect(min, contains('local s = "a -- b"'));
    expect(min, contains('  -- this is a string, kept as is'));
    expect(min, isNot(contains('a comment')));
    expect(min, isNot(contains('still a comment')));
    expect(min.split('\n')[7], 'local x = 137');
    expect(min.split('\n')[8], 'local y = 2');
  });

  // The real proof: Lua compiles each minified file to exactly the bytecode
  // of the original. Needs lua 5.4 on PATH (the devenv shell has it).
  test('every Lua file compiles to the same bytecode, minified', () async {
    final lua = await Process.run('lua', [
      '-v',
    ]).catchError((_) => ProcessResult(0, 1, '', ''));
    if (lua.exitCode != 0 || !'${lua.stdout}${lua.stderr}'.contains('5.4')) {
      markTestSkipped('no lua 5.4 on PATH');
      return;
    }
    final dir = Directory.systemTemp.createTempSync('glaz_min');
    final files = [
      File('assets/lua/frame_app.lua'),
      for (final d in ['modules', 'sprites', 'lib'])
        ...Directory('assets/lua/$d')
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.lua')),
    ];
    for (final f in files) {
      final name = f.path.split('/').last;
      File('${dir.path}/$name').writeAsStringSync(f.readAsStringSync());
      File('${dir.path}/$name.min')
          .writeAsStringSync(minifyLua(f.readAsStringSync()));
    }
    // Files with lines too long for the glasses to read whole get extra
    // line breaks (lib/*.min.lua): there the line numbers inside differ,
    // so they only have to load. Every other file must match exactly.
    const check = r'''
local dir, bad = arg[1], {}
for name in io.popen('ls ' .. dir):lines() do
  if not name:match('%.min$') then
    local src = io.open(dir .. '/' .. name):read('a')
    local min = io.open(dir .. '/' .. name .. '.min'):read('a')
    local a = assert(load(src, '=' .. name))
    local b, err = load(min, '=' .. name)
    local wrapped = false
    for l in src:gmatch('[^\n]*') do if #l > 400 then wrapped = true end end
    for l in min:gmatch('[^\n]*') do
      if #l > 500 then bad[#bad + 1] = name .. ' (a line over 500)' end
    end
    if not b then
      bad[#bad + 1] = name .. ' (' .. err .. ')'
    elseif not wrapped and string.dump(a, true) ~= string.dump(b, true) then
      bad[#bad + 1] = name
    end
  end
end
print(table.concat(bad, ' '))
''';
    final r = await Process.run('lua', ['-e', check, '-', dir.path]);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    expect('${r.stdout}'.trim(), '', reason: 'differ: ${r.stdout}');
    expect(files.length, greaterThan(15));
  });
}
