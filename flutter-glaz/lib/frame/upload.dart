import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:frame_ble/frame_ble.dart';

import 'lua_min.dart';

/// Putting the app on the glasses, the way ../../host_test.py does it:
/// stop the running app, take main.lua out of the way, reset into a bare
/// REPL with all memory free, upload, then start main.lua. See
/// ../../docs/FRAME.md ("Deploy as main.lua") for why each step is there.
///
/// The Lua comes from the app's assets (assets/lua/), which link to the
/// repository's frame_app.lua, modules/ and sprites/.

/// One file for the glasses: its name there and its text.
typedef LuaFile = (String name, String text);

/// [menu] (frame_app.lua's source) with [disabled] module names taken out
/// of its MENU table, so switched-off apps neither load nor show.
String menuWithout(String source, Set<String> disabled) {
  final start = source.indexOf('local MENU = {');
  if (start < 0 || disabled.isEmpty) return source;
  final end = source.indexOf(RegExp(r'^}', multiLine: true), start);
  if (end < 0) return source;
  var menu = source.substring(start, end);
  for (final name in disabled) {
    menu = menu.replaceAll(RegExp("'${RegExp.escape(name)}'\\s*,?\\s*"), '');
  }
  return source.substring(0, start) + menu + source.substring(end);
}

/// Everything to upload, in order: libraries, the splash sprite, modules,
/// main.lua last -- a half-finished upload then leaves no main.lua to boot
/// into. [installed] says which modules to send (by file name, no .lua).
/// Only the sprite frame_app.lua draws (SPLASH_SPRITE) goes; the others in
/// sprites/ are for utils/show_sprite.py. Every file is minified
/// (lua_min.dart): half the time, and the memory main.lua needs to start.
Future<List<LuaFile>> luaFiles(
  AssetBundle bundle,
  bool Function(String module) installed,
) async {
  final manifest = await AssetManifest.loadFromAssetBundle(bundle);
  final assets = manifest.listAssets().where((a) => a.endsWith('.lua'));

  String base(String path) => path.split('/').last;
  Future<List<LuaFile>> under(String dir, [bool Function(String)? keep]) async {
    final paths = assets.where((a) => a.startsWith('assets/lua/$dir/')).toList()
      ..sort();
    return [
      for (final p in paths)
        if (keep == null || keep(base(p).replaceAll('.lua', '')))
          (base(p), await bundle.loadString(p, cache: false)),
    ];
  }

  final modules = await under('modules');
  final disabled = {
    for (final p in assets.where((a) => a.startsWith('assets/lua/modules/')))
      if (!installed(base(p).replaceAll('.lua', '')))
        base(p).replaceAll('.lua', ''),
  };
  final app = await bundle.loadString('assets/lua/frame_app.lua', cache: false);
  final splash = splashSprite(app);
  return [
    for (final (name, text) in [
      ...await under('lib'),
      ...await under('sprites', (s) => s == splash),
      ...modules.where((f) => !disabled.contains(f.$1.replaceAll('.lua', ''))),
      ('main.lua', menuWithout(app, disabled)),
    ])
      (name, minifyLua(text)),
  ];
}

/// The sprite frame_app.lua shows on start: its SPLASH_SPRITE.
String? splashSprite(String app) =>
    RegExp(r"local SPLASH_SPRITE\s*=\s*'(\w+)'").firstMatch(app)?.group(1);

/// Compiles a file on the glasses, in place, to bytecode without debug
/// information. Uploaded for the duration of an upload and run from the
/// bare REPL, with all the memory free; see [uploadApp].
///
/// It reads the file through load()'s reader a line at a time, so the
/// source is never held whole; lines are under 512 bytes, the most one
/// read() gives (lua_min.dart breaks longer ones).
const compileHelper = r'''
function glaz_compile(name, out)
  local h = frame.file.open(name, 'read')
  local f, err = load(function()
    local l = h:read()
    if l then return l .. '\n' end
  end, '=' .. name)
  h:close()
  if not f then print('E ' .. err) return end
  local b = string.dump(f, true)
  f = nil
  collectgarbage('collect')
  local o = frame.file.open(out or name, 'write')
  o:write(b)
  o:close()
  print('C ' .. #b)
end
print('glaz_compile ready')
''';

/// What main.lua is uploaded as, before it is compiled into main.lua.
const mainSource = 'glaz_main.lua';

/// Files frame_app.lua reads as text instead of require()-ing them -- the
/// splash sprite, scanned line by line -- so they must stay source.
bool readAsText(String text) =>
    RegExp(r'^_M\.art = \{', multiLine: true).hasMatch(text);

/// Talks to the REPL: print() a token and wait for it to come back.
class Repl {
  Repl(this.device);
  final BrilliantDevice device;

  Future<void> _expect(String token, Duration timeout, String lua) async {
    final seen = device.stringResponse
        .firstWhere((s) => s.trim() == token)
        .timeout(timeout);
    await device.sendString(lua, awaitResponse: false, log: false);
    await seen;
  }

  /// Runs [lua] and collects every line it prints until [end].
  Future<List<String>> lines(
    String lua,
    String end, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final out = <String>[];
    final done = device.stringResponse
        .map((s) => s.trim())
        .takeWhile((s) => s != end)
        .forEach(out.add)
        .timeout(timeout);
    await device.sendString(lua, awaitResponse: false, log: false);
    await done;
    return out;
  }

  /// Draws [lines] on the glasses, one under another -- what the upload is
  /// doing, since their own app is stopped meanwhile. Short ASCII lines: the
  /// whole command has to fit one REPL write (about 240 bytes).
  Future<void> show(List<String> lines) {
    String esc(String l) => l.replaceAll(RegExp(r"[^ -~]|['\\]"), '?');
    final draw = [
      for (var i = 0; i < lines.length; i++)
        "frame.display.text('${esc(lines[i])}',60,${80 + i * 60})",
    ].join(' ');
    return run('$draw frame.display.show() print(\'shown\')', 'shown');
  }

  /// Runs [lua], which must end by printing [token].
  Future<void> run(
    String lua,
    String token, {
    Duration timeout = const Duration(seconds: 5),
  }) => _expect(token, timeout, lua);

  /// Until the REPL answers. A break can be swallowed while the app is
  /// loading its modules (host_test.py, wait_for_repl), so it is sent again
  /// after every unanswered ping.
  Future<void> ready({int attempts = 6}) async {
    for (var n = 1; n <= attempts; n++) {
      try {
        await run("print('ready$n')", 'ready$n');
        return;
      } catch (_) {
        await device.sendBreakSignal();
      }
    }
    throw Exception('the glasses did not answer');
  }

  /// require() the app and wait for the line it prints once running.
  /// When it does not come up, the error says what the glasses printed
  /// instead -- 'not enough memory', say.
  Future<void> start() async {
    final seen = <String>[];
    final sub = device.stringResponse.listen((s) {
      final t = s.trim();
      if (t.isNotEmpty && t != '\x02') seen.add(t);
    });
    try {
      await run(
        "require('main')",
        'Frame app is running',
        timeout: const Duration(seconds: 30),
      );
    } catch (_) {
      final said = seen.where((s) => s != 'Frame app is running').toList();
      debugPrint('glaz: the glasses said on start: ${said.join(' / ')}');
      throw Exception(
        said.isEmpty
            ? 'the app on the glasses did not start, and said nothing'
            : 'the app on the glasses did not start: ${said.join(' / ')}',
      );
    } finally {
      await sub.cancel();
    }
  }
}

Future<void> uploadApp(
  BrilliantDevice device,
  List<LuaFile> files,
  void Function(String step, [double? progress]) report,
) async {
  final repl = Repl(device);

  report('Stopping the app');
  await device.sendBreakSignal();
  await repl.ready();
  await repl.run(
    "pcall(frame.file.remove, 'main.lua');print('cleared')",
    'cleared',
  );

  report('Resetting the glasses');
  await device.sendResetSignal();
  await repl.ready();
  await repl.show(['Uploading...']);

  // Lua files from earlier uploads that this one does not bring: modules
  // switched off or gone, sprites no longer drawn. Anything else stays --
  // settings.txt, and whatever is not Lua.
  report('Clearing old files');
  final keep = {for (final (name, _) in files) name};
  final present = await repl.lines(
    "for _,e in ipairs(frame.file.listdir('/')) do "
        "if e.type ~= 2 then print(e.name) end end print('listed')",
    'listed',
  );
  for (final name in present) {
    // a name that would break the Lua string is left alone
    if (name.endsWith('.lua') &&
        !keep.contains(name) &&
        !name.contains("'") &&
        !name.contains('\\')) {
      report('Removing $name');
      await repl.run(
        "pcall(frame.file.remove, '$name');print('removed')",
        'removed',
      );
    }
  }

  final total = files.fold<int>(0, (n, f) => n + f.$2.length);
  var done = 0;
  for (var i = 0; i < files.length; i++) {
    final (target, text) = files[i];
    // main.lua goes up as source under another name: a reset with a
    // main.lua on the glasses would start it (see the compile step)
    final name = target == 'main.lua' ? mainSource : target;
    report('Uploading $name', done / total);
    await repl.show([
      'Uploading ${i + 1}/${files.length}',
      name,
      progressBar(done / total),
    ]);
    await device.uploadScript(name, text);
    done += text.length;
  }

  // Compile everything require() loads, on the glasses, while their memory
  // is free: at start they then load bytecode without debug information --
  // about a third of the compiled source in memory, and no compiler and no
  // whole-file buffer (FRAME.md, "require() holds the whole source"). With
  // the source, the app ran out of memory starting.
  //
  // main.lua goes first, on a freshly reset Lua with the heap in one piece:
  // compiling it and dumping the result peaks around 80 KB (measured on a
  // laptop), and after seventeen smaller files the heap was too broken up
  // for it -- the dump ran out of memory. The small files follow.
  await device.uploadScript('glaz_compile.lua', compileHelper);
  report('Resetting the glasses');
  await device.sendResetSignal();
  await repl.ready();
  await repl.run("require('glaz_compile')", 'glaz_compile ready');
  final toCompile = [
    for (final (name, text) in files)
      if (!readAsText(text)) name,
  ]..sort((a, b) => a == 'main.lua' ? -1 : (b == 'main.lua' ? 1 : 0));
  for (var i = 0; i < toCompile.length; i++) {
    final name = toCompile[i];
    report('Compiling $name', i / toCompile.length);
    await repl.show([
      'Compiling ${i + 1}/${toCompile.length}',
      name,
      progressBar(i / toCompile.length),
    ]);
    // pcall: any error -- out of memory in string.dump, say -- comes back
    // as 'E ...', and 'compiled' always follows, so nothing waits it out
    final source = name == 'main.lua' ? mainSource : name;
    final said = await repl.lines(
      "collectgarbage('collect') "
          "local ok,e=pcall(glaz_compile,'$source','$name') "
          "if not ok then print('E '..tostring(e)) end print('compiled')",
      'compiled',
      timeout: const Duration(seconds: 30),
    );
    final error = said.where((l) => l.startsWith('E ')).firstOrNull;
    if (error != null || !said.any((l) => l.startsWith('C '))) {
      final why = error?.substring(2) ?? said.join(' / ');
      throw Exception(
        why.contains('memory')
            ? 'compiling $name on the glasses ran out of memory: $why'
            : 'compiling $name on the glasses: $why',
      );
    }
  }
  await repl.run(
    "pcall(frame.file.remove,'glaz_compile.lua') "
        "pcall(frame.file.remove,'$mainSource') print('removed')",
    'removed',
  );

  report('Starting the app', 1);
  await repl.show(['Starting...', '', progressBar(1)]);
  await repl.start();
}

/// '[##########..........] 50%': in ASCII, as the glasses' font is.
String progressBar(double done, {int width = 16}) {
  final f = done.clamp(0.0, 1.0);
  final n = (f * width).round();
  return '[${'#' * n}${'.' * (width - n)}] ${(f * 100).round()}%';
}

/// Stops the app and boots main.lua again, as host_test.py does on exit:
/// break, then reset. A second require('main') would not do -- Frame's Lua
/// keeps a loaded module for good. host_test.py saw the link drop a few
/// seconds after such a reset; frame_ble then reconnects on its own, so a
/// missing "running" line is not an error here.
Future<void> restartApp(
  BrilliantDevice device,
  void Function(String step, [double? progress]) report,
) async {
  report('Restarting the glasses');
  final running = device.stringResponse
      .firstWhere((s) => s.trim() == 'Frame app is running')
      .timeout(const Duration(seconds: 30));
  await device.sendBreakSignal();
  await device.sendResetSignal();
  try {
    await running;
  } on TimeoutException {
    report('Restarted; waiting for the glasses');
  } on StateError {
    report('Restarted; waiting for the glasses'); // link dropped meanwhile
  }
}
