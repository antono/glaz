import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaz/frame/link.dart';
import 'package:glaz/frame/upload.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('menuWithout', () {
    const src = '''
local data = 1
local MENU = {
  { label = 'Apps',     'photo', 'timeseries', 'stopwatch', 'files',
                        'weather' },
  { label = 'Info',     'notifications', 'about' },
}
local x = { 'weather' }
''';

    test('takes switched-off modules out of MENU only', () {
      final out = menuWithout(src, {'weather', 'timeseries'});
      expect(
        out,
        contains("{ label = 'Apps',     'photo', 'stopwatch', 'files',"),
      );
      expect(out, isNot(contains("'timeseries'")));
      expect(out, contains("local x = { 'weather' }")); // outside MENU
      expect(out, contains("'notifications', 'about' },"));
    });

    test('nothing switched off, nothing changed', () {
      expect(menuWithout(src, {}), src);
    });
  });

  test('the files to upload come from the repository, main.lua last', () async {
    final files = await luaFiles(rootBundle, (m) => m != 'weather');
    final names = files.map((f) => f.$1).toList();
    expect(names.take(2), ['camera.min.lua', 'data.min.lua']);
    expect(names, contains('photo.lua'));
    expect(names, contains('flipper.lua')); // a sprite
    expect(names, isNot(contains('weather.lua')));
    expect(names.last, 'main.lua');
    final main = files.last.$2;
    expect(main, contains('function app_loop()'));
    expect(main, isNot(contains("'weather'")));
    // Frame-side Lua must be ASCII (AGENTS.md)
    for (final (name, text) in files) {
      expect(text.codeUnits.every((c) => c < 128), isTrue, reason: name);
    }
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
