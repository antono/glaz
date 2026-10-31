import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaz/frame/link.dart';
import 'package:glaz/frame/model.dart';
import 'package:glaz/frame/parts.dart';
import 'package:glaz/frame/upload.dart';
import 'package:glaz/glasses_menu.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the files to upload come from the repository, main.lua last', () async {
    final files = await luaFiles(rootBundle, (m) => m != 'weather');
    final names = files.map((f) => f.$1).toList();
    expect(names.take(2), ['camera.min.lua', 'data.min.lua']);
    expect(names, contains('photo.lua'));
    // an empty part stays behind: every file takes a block on Frame
    expect(names, isNot(contains('photo.frame.lua')));
    expect(
      names,
      containsAll(['glaz_blink.frame.lua', 'glaz_photo.frame.lua']),
    );
    expect(names, isNot(contains('logo.lua'))); // no sprites: the phone draws
    expect(names, isNot(contains('weather.lua'))); // switched off
    expect(names, isNot(contains('weather.frame.lua')));
    // the app and its part, then main.lua: glaz_boot's part, which loads
    // glaz_boot.lua, which loads the app
    expect(names.sublist(names.length - 3), [
      'glaz_app.frame.lua',
      appFile,
      'main.lua',
    ]);
    expect(files.last.$2, contains(RegExp(r"device\s*=\s*'frame'")));
    expect(names, contains('glaz_boot.lua'));
    final boot = files.firstWhere((f) => f.$1 == 'glaz_boot.lua').$2;
    expect(boot, contains("pcall(require, 'glaz_app')"));
    final app = files[files.length - 2].$2;
    expect(app, contains('function app_loop()'));
    // minified: no comment lines left
    expect(app, isNot(contains('-- Startup banner')));
    // Frame's parts only
    expect(names.where((n) => n.contains('.halo.')), isEmpty);
    expect(names, isNot(contains('glaz_boot.frame.lua'))); // it is main.lua
    // Frame-side Lua must be ASCII (AGENTS.md)
    for (final (name, text, _) in files) {
      expect(text.codeUnits.every((c) => c < 128), isTrue, reason: name);
    }
  });

  test('Halo gets its own parts, its modules only, and source', () async {
    final files = await luaFiles(
      rootBundle,
      (_) => true,
      model: GlassesModel.halo,
    );
    final names = files.map((f) => f.$1).toList();
    expect(names.where((n) => n.contains('.frame.')), isEmpty);
    expect(names.sublist(names.length - 3), [
      'glaz_app.halo.lua',
      appFile,
      'main.lua',
    ]);
    expect(files.last.$2, contains(RegExp(r"device\s*=\s*'halo'")));
    // a module with a Halo part goes up -- an empty part itself not, one
    // with something in it too -- and one without does not
    expect(names, contains('stopwatch.lua'));
    expect(names, isNot(contains('stopwatch.halo.lua')));
    expect(names, containsAll(['about.lua', 'about.halo.lua']));
    expect(names, isNot(contains('reader.lua')));
    // Frame-only parts of the app stay off
    expect(names, isNot(contains('glaz_blink.frame.lua')));
    // Halo's require() takes text only: no bytecode
    for (final (name, _, code) in files) {
      expect(code, isNull, reason: name);
    }
  });

  test('an empty part is told from one with something in it', () {
    expect(emptyPart(('a.frame.lua', '-- nothing\nreturn {}\n', null)), isTrue);
    expect(emptyPart(('a.frame.lua', 'return{}', null)), isTrue);
    expect(emptyPart(('a.frame.lua', 'return { x = 1 }', null)), isFalse);
    // not a part: kept whatever it holds
    expect(emptyPart(('a.lua', 'return {}', null)), isFalse);
  });

  test('files take whole blocks, the tiniest none', () {
    expect(blocksFor([('a.lua', 'x', null)]), 0);
    expect(blocksFor([('a.lua', 'x' * 33, null)]), fileBlock);
    expect(blocksFor([('a.lua', 'x' * 4097, null)]), 2 * fileBlock);
  });

  test('Frame needs the app as bytecode; Halo takes text', () {
    final code = Uint8List.fromList([1]);
    final text = [(appFile, 'x', null), ('m.lua', 'y', null)];
    expect(
      () => needBytecode(text, GlassesModel.frame),
      throwsA(predicate((e) => '$e'.contains('tool/compile_lua.sh'))),
    );
    // a smaller file may be text, the app may not
    needBytecode([
      (appFile, 'x', code),
      ('m.lua', 'y', null),
    ], GlassesModel.frame);
    needBytecode(text, GlassesModel.halo);
  });

  test('every app in ../apps is an asset folder in pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final apps = Directory('../apps')
        .listSync()
        .whereType<Directory>()
        .where((d) => !d.path.split('/').last.startsWith('_')); // __pycache__
    expect(apps, isNotEmpty);
    for (final d in apps) {
      final name = d.path.split('/').last;
      expect(pubspec, contains('- assets/lua/apps/$name/\n'), reason: name);
    }
  });

  test('the assets link every app\'s Lua and nothing else', () {
    // only the Lua: an app's README, screenshots and tests stay out of
    // the app (tool/link_apps.sh makes the links)
    Set<String> names(String dir, bool Function(FileSystemEntity) keep) => {
      for (final f in Directory(
        dir,
      ).listSync(recursive: true, followLinks: false))
        if (keep(f)) f.path.substring(dir.length),
    };
    final lua = names(
      '../apps/',
      (f) => f is File && f.path.endsWith('.lua') && !f.path.contains('/_'),
    );
    final linked = names('assets/lua/apps/', (f) => f is Link);
    expect(linked, lua, reason: 'run tool/link_apps.sh');
    expect(names('assets/lua/apps/', (f) => f is File), isEmpty);
  });

  test('a part is told by its suffix', () {
    expect(partFor('reader.frame.lua'), GlassesModel.frame);
    expect(partFor('about.halo.lua'), GlassesModel.halo);
    expect(partFor('reader.lua'), isNull);
    expect(partFor('data.min.lua'), isNull);
    expect(stemOf('reader.frame.lua'), 'reader');
    expect(stemOf('data.min.lua'), 'data.min');
    expect(
      modulesFor([
        'assets/lua/apps/about/about.lua',
        'assets/lua/apps/about/about.frame.lua',
        'assets/lua/apps/about/about.halo.lua',
        'assets/lua/apps/reader/reader.lua',
        'assets/lua/apps/reader/reader.frame.lua',
        'assets/lua/glaz/glaz_boot.halo.lua',
      ], GlassesModel.halo),
      {'about'},
    );
  });

  test('every app in the menu is on Frame', () async {
    final parts = await GlassesParts.load(rootBundle);
    for (final m in glassesMenu.expand((s) => s.modules)) {
      expect(parts.has(m.id, GlassesModel.frame), isTrue, reason: m.id);
    }
    expect(parts.has('about', GlassesModel.halo), isTrue);
    expect(parts.has('reader', GlassesModel.halo), isFalse);
  });

  test('Upload sends what is switched on and runs there', () async {
    final parts = await GlassesParts.load(rootBundle);
    bool on(String m) => m != 'weather';
    final frame = parts.sentTo(GlassesModel.frame, on);
    expect(frame, containsAll(['reader', 'uptime']));
    expect(frame, isNot(contains('weather')));
    final halo = parts.sentTo(GlassesModel.halo, on);
    expect(halo, contains('uptime'));
    expect(halo, isNot(contains('reader')));
  });

  test(
    'bytecode from tool/compile_lua.sh, when it matches the source',
    () async {
      final files = await luaFiles(rootBundle, (_) => true);
      final app = files[files.length - 2];
      // not compiled before the tests ran: nothing to check
      if (app.$3 == null) return;
      // Lua 5.4 bytecode: ESC 'Lua', version 0x54, format 0
      expect(app.$3!.sublist(0, 6), [0x1b, 0x4c, 0x75, 0x61, 0x54, 0x00]);
      for (final (name, _, code) in files) {
        expect(code, isNotNull, reason: name);
      }
    },
  );

  test('luacAsset and fnv1a match tool/compile_lua.sh', () {
    expect(
      luacAsset('assets/lua/apps/photo/photo.lua'),
      'assets/luac/apps.photo.photo.luac',
    );
    expect(luacAsset('assets/lua/glaz/glaz.lua'), 'assets/luac/glaz.glaz.luac');
    expect(
      luacAsset('assets/lua/lib/data.min.lua'),
      'assets/luac/lib.data.min.luac',
    );
    expect(fnv1a([]), 0x811c9dc5);
    expect(fnv1a('a'.codeUnits), 0xe40c292c);
  });

  group('what changed', () {
    // cut where Frame's read() cuts: at a newline, or after 512 bytes
    final cases = <String, List<int>>{
      'empty': [],
      'one line': 'print(1)'.codeUnits,
      'ends in a newline': 'a\nb\n'.codeUnits,
      'empty lines': '\n\n\nx'.codeUnits,
      'a long line': [for (var i = 0; i < 1300; i++) 0x41 + i % 26],
      '512 then a newline': [...List.filled(512, 0x78), 0x0A, 0x79],
      '512 then more': [...List.filled(512, 0x78), 0x79],
      'bytecode': [for (var i = 0; i < 3000; i++) (i * 137) % 256],
    };

    test('the hash tells the cases apart', () {
      final hashes = {for (final b in cases.values) frameFileHash(b)};
      expect(hashes, hasLength(cases.length));
      expect(frameFileHash([]), 0x811c9dc5);
      expect(frameFileHash('a'.codeUnits), fnv1a('a\n'.codeUnits));
    });

    test('text goes up as uploadScript writes it', () {
      expect(uploadedBytes(('x.lua', 'a\r\nb', null)), 'a\nb'.codeUnits);
      final code = Uint8List.fromList([1, 2]);
      expect(uploadedBytes(('x.lua', 'a', code)), code);
    });

    // checkHelper itself, on Lua 5.4, with frame.file as the firmware's
    // file.c has it; skipped without a lua 5.4 on PATH (devenv has one)
    final lua = Process.runSync('lua', ['-v']);
    final hasLua =
        lua.exitCode == 0 && '${lua.stdout}${lua.stderr}'.contains('5.4');
    test('the glasses work out the same hash', () {
      final dir = Directory.systemTemp.createTempSync('glaz_check');
      addTearDown(() => dir.deleteSync(recursive: true));
      var checks = '';
      var n = 0;
      for (final bytes in cases.values) {
        File('${dir.path}/f$n').writeAsBytesSync(bytes);
        checks += "glaz_check('f$n', ${frameFileHash(bytes)})\n";
        checks += "glaz_check('f$n', ${frameFileHash(bytes) ^ 1})\n";
        n++;
      }
      checks += "glaz_check('missing', 0)\n";
      // room: 4096 free, and f0 (kept, being the same) does not count, but
      // a stale Lua file of 5000 bytes is two blocks freed; not Lua stays
      checks += "glaz_room(4096)\n";
      File('${dir.path}/run.lua').writeAsStringSync('''
frame = { file = {} }
function frame.file.space() return { free = 4096 } end
function frame.file.listdir()
  return {
    { name = 'f0', size = 10, type = 1 },
    { name = 'stale.lua', size = 5000, type = 1 },
    { name = 'settings.txt', size = 10, type = 1 },
    { name = 'photos', size = 0, type = 2 },
  }
end
function frame.file.open(name)
  local f = assert(io.open(name, 'rb'))
  return {
    read = function()
      local s = {}
      for i = 1, $frameReadMax do
        local c = f:read(1)
        if c == nil or c == '\\n' then
          if i == 1 then return c and '' or nil end
          break
        end
        s[#s + 1] = c
      end
      return table.concat(s)
    end,
    close = function() f:close() end,
  }
end
$checkHelper
$checks''');
      final out = Process.runSync('lua', [
        'run.lua',
      ], workingDirectory: dir.path);
      expect(out.stderr, '');
      expect('${out.stdout}'.trim().split('\n'), [
        'glaz_check ready',
        for (var i = 0; i < n; i++) ...['same f$i', 'diff f$i'],
        'diff missing',
        'room ${4096 + 2 * 4096}',
      ]);
    }, skip: hasLua ? false : 'no lua 5.4 on PATH');

    test('the last upload\'s sums spare reading what has not changed', () {
      final dir = Directory.systemTemp.createTempSync('glaz_sums');
      addTearDown(() => dir.deleteSync(recursive: true));
      // on the glasses: a.lua as the sums say; b.lua the same text but its
      // sums say otherwise; c.lua grown since; main.lua aside as mainKept
      final a = 'print(137)'.codeUnits;
      final c = 'print(1370)'.codeUnits;
      File('${dir.path}/a.lua').writeAsStringSync('not what the sums say');
      File('${dir.path}/b.lua').writeAsBytesSync(a);
      File('${dir.path}/c.lua').writeAsBytesSync(c);
      File('${dir.path}/$mainKept').writeAsStringSync('x');
      final files = <LuaFile>[
        ('a.lua', 'print(137)', null),
        ('c.lua', 'print(137)', null),
        ('main.lua', 'x', null),
      ];
      File('${dir.path}/$sumsFile')
          .writeAsStringSync('${sums(files)}\n0 10 b.lua');
      final h = frameFileHash(a);
      File('${dir.path}/run.lua').writeAsStringSync('''
frame = { file = {} }
function frame.file.listdir()
  return {
    { name = 'a.lua', size = ${a.length}, type = 1 },
    { name = 'b.lua', size = ${a.length}, type = 1 },
    { name = 'c.lua', size = ${c.length}, type = 1 },
    { name = '$mainKept', size = 1, type = 1 },
  }
end
function frame.file.remove(name) assert(os.remove(name)) end
function frame.file.open(name)
  local f = assert(io.open(name, 'rb'))
  return {
    read = function() return f:read('l') end,
    close = function() f:close() end,
  }
end
$checkHelper
glaz_check('a.lua', $h)
glaz_check('b.lua', $h)
glaz_check('c.lua', $h)
glaz_check('$mainKept', ${frameFileHash('x'.codeUnits)})
print(io.open('$sumsFile') and 'sums kept' or 'sums gone')
''');
      final out = Process.runSync('lua', [
        'run.lua',
      ], workingDirectory: dir.path);
      expect(out.stderr, '');
      expect('${out.stdout}'.trim().split('\n'), [
        'glaz_check ready',
        'same a.lua', // by its sums alone
        'same b.lua', // read: its sums were wrong
        'diff c.lua', // its size is not what the sums say
        'same $mainKept',
        'sums gone',
      ]);
    }, skip: hasLua ? false : 'no lua 5.4 on PATH');

    test('glaz_recv writes what the data channel brings, saying so', () {
      final dir = Directory.systemTemp.createTempSync('glaz_recv');
      addTearDown(() => dir.deleteSync(recursive: true));
      final bytes = [for (var i = 0; i < 300; i++) (i * 137) & 0xFF];
      final pieces = dataPieces(bytes, 137);
      String lua(List<int> p) => "'${p.map((b) => '\\$b').join()}'";
      File('${dir.path}/run.lua').writeAsStringSync('''
frame = { file = {}, bluetooth = {} }
local cb
function frame.bluetooth.receive_callback(f) cb = f end
function frame.file.open(name, mode) return assert(io.open(name, 'wb')) end
$checkHelper
glaz_recv('out', ${bytes.length})
${pieces.map((p) => 'cb(${lua(p)})').join('\n')}
print(cb == nil and 'unhooked' or 'hooked')
''');
      final out = Process.runSync('lua', [
        'run.lua',
      ], workingDirectory: dir.path);
      expect(out.stderr, '');
      expect('${out.stdout}'.trim().split('\n'), [
        'glaz_check ready',
        'recv out',
        'got 137',
        'got 274',
        'wrote out',
        'unhooked',
      ]);
      expect(File('${dir.path}/out').readAsBytesSync(), bytes);
    }, skip: hasLua ? false : 'no lua 5.4 on PATH');
  });

  test('an upload says what it did', () {
    final none = UploadSteps();
    expect(none.result(), startsWith('nothing changed, '));
    final some = UploadSteps()
      ..files = 1
      ..bytes = 137;
    expect(some.result(), startsWith('1 file written (137 bytes), '));
    final more = UploadSteps()
      ..files = 3
      ..bytes = 137 * 1024;
    expect(more.result(), startsWith('3 files written (137 KB), '));
  });

  test('bytes go up in packets that read back the same', () {
    final bytes = [for (var i = 0; i < 256; i++) i, 137];
    final pieces = dataPieces(bytes, 41);
    for (final p in pieces) {
      expect(p.length, lessThanOrEqualTo(41));
    }
    expect(pieces.expand((p) => p).toList(), bytes);
    expect(dataPieces([], 40), isEmpty);
  });

  test('STATUS: battery and firmware', () {
    final link = FrameLink();
    link.onStatus([0x1B, 84, ...'v25.080.0838'.codeUnits]);
    expect(link.battery, 84);
    expect(link.firmware, 'v25.080.0838');
    link.onStatus([0x1B, 255, ...'v25.080.0838'.codeUnits]);
    expect(link.battery, 84, reason: '255 = not sampled, keep the last');
  });

  test('STATUS: the app is up, and onStatusAnswer hears it every time', () {
    final link = FrameLink();
    var heard = 0;
    link.onStatusAnswer.add(() => heard++);
    link.onStatus([0x1B, 84]);
    link.onStatus([0x1B, 85]);
    link.onStatus([0x1B]); // too short: no answer
    expect(heard, 2);
  });
}
