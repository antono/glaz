import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaz/frame/link.dart';
import 'package:glaz/frame/upload.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the files to upload come from the repository, main.lua last', () async {
    final files = await luaFiles(rootBundle, (m) => m != 'weather');
    final names = files.map((f) => f.$1).toList();
    expect(names.take(2), ['camera.min.lua', 'data.min.lua']);
    expect(names, contains('photo.lua'));
    expect(names, contains('logo.lua')); // the splash sprite
    expect(names, isNot(contains('flipper.lua'))); // not drawn: not sent
    expect(names, isNot(contains('weather.lua'))); // switched off
    expect(names.last, 'main.lua');
    final main = files.last.$2;
    expect(main, contains('function app_loop()'));
    // minified: no comment lines left
    expect(main, isNot(contains('-- Startup banner')));
    // the sprite is read as text on the glasses: never bytecode
    expect(files.where((f) => readAsText(f.$2)).map((f) => f.$1), ['logo.lua']);
    expect(files.firstWhere((f) => f.$1 == 'logo.lua').$3, isNull);
    // Frame-side Lua must be ASCII (AGENTS.md)
    for (final (name, text, _) in files) {
      expect(text.codeUnits.every((c) => c < 128), isTrue, reason: name);
    }
  });

  test(
    'bytecode from tool/compile_lua.sh, when it matches the source',
    () async {
      final files = await luaFiles(rootBundle, (_) => true);
      final main = files.last;
      // not compiled before the tests ran: nothing to check
      if (main.$3 == null) return;
      // Lua 5.4 bytecode: ESC 'Lua', version 0x54, format 0
      expect(main.$3!.sublist(0, 6), [0x1b, 0x4c, 0x75, 0x61, 0x54, 0x00]);
      for (final (name, text, code) in files) {
        if (!readAsText(text)) expect(code, isNotNull, reason: name);
      }
    },
  );

  test('luacAsset and fnv1a match tool/compile_lua.sh', () {
    expect(
      luacAsset('assets/lua/modules/photo.lua'),
      'assets/luac/modules.photo.luac',
    );
    expect(luacAsset('assets/lua/frame_app.lua'), 'assets/luac/frame_app.luac');
    expect(
      luacAsset('assets/lua/lib/data.min.lua'),
      'assets/luac/lib.data.min.luac',
    );
    expect(fnv1a([]), 0x811c9dc5);
    expect(fnv1a('a'.codeUnits), 0xe40c292c);
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

  test('the progress bar on the glasses is ASCII', () {
    expect(progressBar(0), '[................] 0%');
    expect(progressBar(0.5), '[########........] 50%');
    expect(progressBar(1.2), '[################] 100%');
  });
}
