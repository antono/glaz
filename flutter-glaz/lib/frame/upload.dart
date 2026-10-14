import 'dart:async';

import 'package:flutter/services.dart';
import 'package:frame_ble/frame_ble.dart';

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

/// Everything to upload, in order: libraries, sprites, modules, main.lua
/// last -- a half-finished upload then leaves no main.lua to boot into.
/// [installed] says which modules to send (by file name, no .lua).
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
  return [
    ...await under('lib'),
    ...await under('sprites'),
    ...modules.where((f) => !disabled.contains(f.$1.replaceAll('.lua', ''))),
    ('main.lua', menuWithout(app, disabled)),
  ];
}

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
  Future<void> start() => run(
    "require('main')",
    'Frame app is running',
    timeout: const Duration(seconds: 30),
  );
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
  await repl.run(
    "frame.display.text('uploading...', 60, 140);frame.display.show();"
        "print('shown')",
    'shown',
  );

  final total = files.fold<int>(0, (n, f) => n + f.$2.length);
  var done = 0;
  for (final (name, text) in files) {
    report('Uploading $name', done / total);
    await device.uploadScript(name, text);
    done += text.length;
  }

  report('Starting the app', 1);
  await repl.start();
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
