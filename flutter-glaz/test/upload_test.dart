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
    expect(names, containsAll(['photo.lua', 'photo.frame.lua']));
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
    // a module with a Halo part goes up; one without does not
    expect(names, containsAll(['about.lua', 'about.halo.lua']));
    expect(names, isNot(contains('reader.lua')));
    // Frame-only parts of the app stay off
    expect(names, isNot(contains('glaz_blink.frame.lua')));
    // Halo's require() takes text only: no bytecode
    for (final (name, _, code) in files) {
      expect(code, isNull, reason: name);
    }
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
        'assets/lua/modules/about.lua',
        'assets/lua/modules/about.frame.lua',
        'assets/lua/modules/about.halo.lua',
        'assets/lua/modules/reader.lua',
        'assets/lua/modules/reader.frame.lua',
        'assets/lua/app/glaz_boot.halo.lua',
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
      luacAsset('assets/lua/modules/photo.lua'),
      'assets/luac/modules.photo.luac',
    );
    expect(luacAsset('assets/lua/glaz.lua'), 'assets/luac/glaz.luac');
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
      expect(checkable(('x.lua', 'a', code)), isTrue);
      expect(checkable(('x.lua', 'return 1', null)), isFalse);
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
      File('${dir.path}/run.lua').writeAsStringSync('''
frame = { file = {} }
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
      ]);
    }, skip: hasLua ? false : 'no lua 5.4 on PATH');
  });

  test('bytes go up as hex pieces that read back the same', () {
    final bytes = [for (var i = 0; i < 256; i++) i, 137];
    final pieces = hexPieces(bytes, 41);
    for (final p in pieces) {
      expect(p.length, lessThanOrEqualTo(41));
      expect(p.length.isEven, isTrue);
      expect(RegExp(r'^[0-9a-f]*$').hasMatch(p), isTrue);
    }
    final all = pieces.join();
    expect([
      for (var i = 0; i < all.length; i += 2)
        int.parse(all.substring(i, i + 2), radix: 16),
    ], bytes);
    expect(hexPieces([], 40), ['']);
  });

  test('STATUS: battery and firmware', () {
    final link = FrameLink();
    link.onStatus([0x1B, 84, ...'v25.080.0838'.codeUnits]);
    expect(link.battery, 84);
    expect(link.firmware, 'v25.080.0838');
    link.onStatus([0x1B, 255, ...'v25.080.0838'.codeUnits]);
    expect(link.battery, 84, reason: '255 = not sampled, keep the last');
  });
}
