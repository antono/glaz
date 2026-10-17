import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:frame_ble/frame_ble.dart';

import 'lua_min.dart';
import 'update_screen.dart';

/// Putting the app on the glasses, the way ../../host_test.py does it:
/// stop the running app, take main.lua out of the way, reset into a bare
/// REPL with all memory free, upload, then start main.lua. See
/// ../../docs/FRAME.md ("Deploy as main.lua") for why each step is there.
///
/// The Lua comes from the app's assets (assets/lua/), which link to the
/// repository's frame_app.lua, app/ and modules/.

/// One file for the glasses: its name there, its text, and its bytecode
/// when the app was built with it (tool/compile_lua.sh) and it still
/// matches the text. Without bytecode the text goes up and the glasses
/// compile it.
typedef LuaFile = (String name, String text, Uint8List? code);

/// The FNV-1a hash tool/luac_frame.c prints for a source file.
int fnv1a(List<int> bytes) {
  var h = 0x811c9dc5;
  for (final b in bytes) {
    h = ((h ^ b) * 0x01000193) & 0xFFFFFFFF;
  }
  return h;
}

/// Where tool/compile_lua.sh puts the bytecode of the source asset [path]:
/// assets/lua/modules/photo.lua -> assets/luac/modules.photo.luac.
String luacAsset(String path) =>
    'assets/luac/${path.substring('assets/lua/'.length).replaceAll(RegExp(r'\.lua$'), '').replaceAll('/', '.')}.luac';

/// assets/luac/index.txt: source asset -> hash of the text compiled.
Future<Map<String, int>> _compiled(AssetBundle bundle) async {
  try {
    final index = await bundle.loadString(
      'assets/luac/index.txt',
      cache: false,
    );
    return {
      for (final line in index.split('\n'))
        if (line.trim().split(' ') case [final path, final hash])
          path: int.parse(hash, radix: 16),
    };
  } catch (_) {
    return {}; // built without tool/compile_lua.sh
  }
}

/// Everything to upload, in order: libraries, the app's parts, modules, the
/// app, main.lua last -- a half-finished upload then leaves no main.lua to
/// boot into. [installed] says which modules to send (by file name, no
/// .lua); frame_app.lua leaves the others out of its menu. No sprites: the
/// phone draws the eye itself while it uploads (update_screen.dart), and
/// one kept on the glasses took memory the app needs.
///
/// Each file carries its bytecode from assets/luac/ when that was compiled
/// from this very text. The glasses no longer have the memory to compile
/// main.lua themselves. The text is minified (lua_min.dart), for what goes
/// up as source: half the time, and the memory main.lua needs to start.
Future<List<LuaFile>> luaFiles(
  AssetBundle bundle,
  bool Function(String module) installed,
) async {
  final manifest = await AssetManifest.loadFromAssetBundle(bundle);
  final assets = manifest.listAssets().where((a) => a.endsWith('.lua'));
  final compiled = await _compiled(bundle);

  String base(String path) => path.split('/').last;
  String module(String path) => base(path).replaceAll('.lua', '');

  Future<LuaFile> file(String path, [String? name]) async {
    final bytes = (await bundle.load(path)).buffer.asUint8List();
    final text = String.fromCharCodes(bytes);
    Uint8List? code;
    if (compiled[path] case final hash? when hash == fnv1a(bytes)) {
      try {
        code = (await bundle.load(luacAsset(path))).buffer.asUint8List();
      } catch (_) {} // listed, but not in this build: source it is
    }
    return (name ?? base(path), minifyLua(text), code);
  }

  Future<List<LuaFile>> under(String dir, [bool Function(String)? keep]) async {
    final paths = assets.where((a) => a.startsWith('assets/lua/$dir/')).toList()
      ..sort();
    return [
      for (final p in paths)
        if (keep == null || keep(module(p))) await file(p),
    ];
  }

  return [
    ...await under('lib'),
    // parts of frame_app.lua in files of their own (glaz_host.lua...); the
    // loader goes up as main.lua, last
    ...(await under('app')).where((f) => f.$1 != _boot),
    ...await under('modules', installed),
    // the app itself, loaded by main.lua: the firmware's require() cannot
    // be trusted with a file its size (app/glaz_boot.lua)
    await file('assets/lua/frame_app.lua', appFile),
    await file('assets/lua/app/$_boot', 'main.lua'),
  ];
}

/// What frame_app.lua is called on the glasses; main.lua, which loads it,
/// is app/glaz_boot.lua.
const appFile = 'glaz_app.lua';
const _boot = 'glaz_boot.lua';

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

/// Where main.lua is put out of the way while an upload runs: a reset with
/// a main.lua would start it. Moved back when it is still the right one.
const mainKept = 'glaz_prev.lua';

/// How much of a file one read() on the glasses gives at most: their
/// LUAL_BUFFERSIZE, 16 * sizeof(void*) * sizeof(lua_Number) = 16 * 4 * 8.
const frameReadMax = 512;

/// The hash [checkHelper] works out on the glasses for a file holding
/// [bytes]: FNV-1a over what read() gives, piece by piece, each followed
/// by a newline. read() stops at a newline, which it takes but does not
/// return, or after [frameReadMax] bytes; the pieces here are cut the same
/// way. Should the two ever disagree, the file only goes up again.
int frameFileHash(List<int> bytes) {
  var h = 0x811c9dc5;
  void add(int b) => h = ((h ^ b) * 0x01000193) & 0xFFFFFFFF;
  var i = 0;
  while (i < bytes.length) {
    for (var n = 0; n < frameReadMax && i < bytes.length; n++) {
      final b = bytes[i++];
      if (b == 0x0A) break;
      add(b);
    }
    add(0x0A);
  }
  return h;
}

/// What a [LuaFile] is on the glasses once uploaded: its bytecode, or its
/// text as uploadScript writes it (a CRLF becomes a newline).
List<int> uploadedBytes(LuaFile f) =>
    f.$3 ?? f.$2.replaceAll('\r\n', '\n').codeUnits;

/// Whether the glasses keep [f] as uploaded. Not what goes up as source
/// to be compiled there: what that compiles to is only known there.
bool checkable(LuaFile f) => f.$3 != null;

/// Says whether a file on the glasses is already what an upload would
/// write: glaz_check(name, hash) prints 'same NAME' or 'diff NAME', and
/// files that are the same go in glaz_keep, for Clearing old files to
/// leave. See [frameFileHash] for the hash. Uploaded for the duration of
/// an upload, like [compileHelper]. A read() that never ends -- the
/// firmware's at the end of a file is not quite sure -- gives up and says
/// diff after 4000 pieces.
const checkHelper = r'''
glaz_keep = {}
function glaz_check(name, want)
  local ok, h = pcall(frame.file.open, name, 'read')
  if not ok then print('diff ' .. name) return end
  local byte, x, n = string.byte, 0x811c9dc5, 0
  while true do
    local l = h:read()
    if not l then break end
    n = n + 1
    if n > 4000 then x = nil break end
    for i = 1, #l do x = ((x ~ byte(l, i)) * 16777619) & 0xFFFFFFFF end
    x = ((x ~ 10) * 16777619) & 0xFFFFFFFF
  end
  h:close()
  if x == want then
    glaz_keep[name] = true
    print('same ' .. name)
  else
    print('diff ' .. name)
  end
end
print('glaz_check ready')
''';

/// What the glasses print, one line at a time. The firmware packs prints
/// that come faster than the link into one notification, joined by '\n'
/// -- a listing of twenty files arrived as a few of them -- so a reply is
/// split before it is compared.
Stream<String> replLines(BrilliantDevice device) => device.stringResponse
    .expand((s) => s.split('\n'))
    .map((l) => l.trim())
    .where((l) => l.isNotEmpty);

/// Talks to the REPL: print() a token and wait for it to come back.
class Repl {
  Repl(this.device);
  final BrilliantDevice device;

  Future<void> _expect(String token, Duration timeout, String lua) async {
    final seen = replLines(device)
        .firstWhere((s) => s == token)
        .timeout(timeout);
    await device.sendString(lua, awaitResponse: false, log: false);
    await seen;
  }

  /// Runs [lua] and collects every line it prints until [end] -- or until
  /// a line that [match] accepts, which is collected too.
  Future<List<String>> lines(
    String lua,
    String end, {
    Duration timeout = const Duration(seconds: 5),
    bool Function(String line)? match,
  }) async {
    final out = <String>[];
    final last = match ?? (s) => s == end;
    final done = replLines(device)
        .takeWhile((s) {
          if (!last(s)) return true;
          if (match != null) out.add(s);
          return false;
        })
        .forEach(out.add)
        .timeout(timeout);
    await device.sendString(lua, awaitResponse: false, log: false);
    await done;
    return out;
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
  /// Starts main.lua with a reset: the firmware then require()s it as it
  /// does at power-on, on a fresh Lua with the heap in one piece. Not
  /// require('main') here, in the Lua that has just compiled two dozen
  /// files: the firmware reads the file with a realloc() per byte, and in
  /// that broken-up heap one failed and the glasses rebooted (seen right
  /// after Upload; the same main.lua started fine on the reboot).
  ///
  /// When it does not come up, the error says what the glasses printed
  /// instead -- 'not enough memory', say.
  Future<void> start() async {
    final seen = <String>[];
    final sub = replLines(device).listen((t) {
      if (t != '\x02') seen.add(t);
    });
    try {
      final running = replLines(device)
          .firstWhere((s) => s == 'Frame app is running')
          .timeout(const Duration(seconds: 40));
      await device.sendResetSignal();
      await running;
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

/// Lua that unhooks the app's tap and Bluetooth callbacks; run before a
/// reset. The firmware keeps them across a reset of Lua -- a registry
/// index, in a C static (imu.c, bluetooth.c) -- and the new Lua has
/// something else, or nothing, there. A tap during Upload then broke the
/// file being written: "attempt to call a nil value (hook '?')".
const unhook =
    'pcall(frame.imu.tap_callback,nil) '
    'pcall(frame.bluetooth.receive_callback,nil)';

Future<void> uploadApp(
  BrilliantDevice device,
  List<LuaFile> files,
  void Function(String step, [double? progress]) report,
) async {
  final repl = Repl(device);

  report('Stopping the app');
  await device.sendBreakSignal();
  await repl.ready();
  // main.lua out of the way, but kept: it may need no uploading
  await repl.run(
    "$unhook pcall(frame.file.rename, 'main.lua', '$mainKept');"
        "print('cleared')",
    'cleared',
  );

  report('Resetting the glasses');
  await device.sendResetSignal();
  await repl.ready();
  // the eye wired up, with what is going on under it; its art lives in Lua
  // globals, so after a reset it is loaded again
  final picture = GlassesPicture(repl.run);
  await picture.load();
  await picture.draw('Uploading...', progress: 0);

  // Only what changed goes up: the glasses hash each file they have and
  // say whether it is what this upload would write. Usually one or two
  // modules of two dozen are not.
  report('Checking what changed');
  await picture.draw('Checking...', progress: 0);
  final same = await _unchanged(device, repl, files);
  debugPrint('glaz Upload: ${same.length} of ${files.length} files unchanged');

  // Lua files from earlier uploads -- modules switched off or gone, sprites
  // no longer drawn, files that changed -- go; those found the same stay.
  // Done on the glasses, answered with one line: listing the files to the
  // phone made them print two dozen lines at once, and lines printed
  // faster than the link sends are lost -- the end of the list never
  // arrived. Anything not Lua stays: settings.txt, say.
  report('Clearing old files');
  final cleared = await repl.lines(
    "local n=0 for _,e in ipairs(frame.file.listdir('/')) do "
        "if e.type~=2 and e.name:match('%.lua\$') and not glaz_keep[e.name] "
        "and pcall(frame.file.remove,e.name) then n=n+1 end end "
        "print('cleared '..n)",
    'cleared',
    // its own line, not part of the count
    match: (l) => l.startsWith('cleared '),
  );
  debugPrint('glaz Upload: ${cleared.isEmpty ? 'cleared' : cleared.last}');

  // Bytecode built with the app goes up as it is. main.lua bytecode goes
  // last, after any compiling below: a reset with a main.lua on the glasses
  // would start it.
  int size(LuaFile f) => f.$3?.length ?? f.$2.length;
  final main = files.firstWhere((f) => f.$1 == 'main.lua');
  final order = [
    for (final f in files)
      if (f != main && !same.contains(f.$1)) f,
    if (!same.contains('main.lua')) main,
  ];
  final total = order.fold<int>(0, (n, f) => n + size(f));
  var done = 0;
  for (var i = 0; i < order.length; i++) {
    final (target, text, code) = order[i];
    // main.lua as source goes up under another name, for the same reason
    final name = target == 'main.lua' && code == null ? mainSource : target;
    report('Uploading $name', done / total);
    await picture.draw('Uploading: $name', progress: done / total);
    if (code == null) {
      await device.uploadScript(name, text);
    } else if (target != 'main.lua') {
      await uploadBytes(device, name, code, meanwhile: picture.tick);
    }
    done += size(order[i]);
  }

  // What went up as source -- built without tool/compile_lua.sh, or since
  // changed -- is compiled on the glasses, while their memory is free: at
  // start they then load bytecode without debug information -- about a
  // third of the compiled source in memory, and no compiler and no
  // whole-file buffer (FRAME.md, "require() holds the whole source").
  //
  // main.lua goes first, on a freshly reset Lua with the heap in one piece:
  // compiling it and dumping the result peaks around 80 KB (measured on a
  // laptop), and after seventeen smaller files the heap was too broken up
  // for it -- the dump ran out of memory. The small files follow. Today
  // main.lua is too big for even that, so it needs its bytecode.
  final toCompile = [
    for (final (name, _, code) in files)
      if (code == null) name,
  ]..sort((a, b) => a == 'main.lua' ? -1 : (b == 'main.lua' ? 1 : 0));
  if (toCompile.isNotEmpty) {
    debugPrint('glaz Upload: compiling on the glasses: ${toCompile.join(' ')}');
    await device.uploadScript('glaz_compile.lua', compileHelper);
    report('Resetting the glasses');
    await device.sendResetSignal();
    await repl.ready();
    await repl.run("require('glaz_compile')", 'glaz_compile ready');
    await picture.load();
  }
  for (var i = 0; i < toCompile.length; i++) {
    final name = toCompile[i];
    report('Compiling $name', i / toCompile.length);
    await picture.draw('Compiling: $name', progress: i / toCompile.length);
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
  if (toCompile.isNotEmpty) {
    await repl.run(
      "pcall(frame.file.remove,'glaz_compile.lua') "
          "pcall(frame.file.remove,'$mainSource') print('removed')",
      'removed',
    );
  }
  if (same.contains('main.lua')) {
    await repl.run(
      "pcall(frame.file.rename,'$mainKept','main.lua') print('restored')",
      'restored',
    );
  } else if (main.$3 case final code?) {
    report('Uploading main.lua', done / total);
    await picture.draw('Uploading: main.lua', progress: done / total);
    await uploadBytes(device, 'main.lua', code, meanwhile: picture.tick);
  }

  report('Starting the app', 1);
  await picture.draw('Starting...', progress: 1);
  await repl.start();
}

/// The names of [files] the glasses already have as this upload would
/// write them; main.lua is looked for where the upload put it, [mainKept].
/// Leaves glaz_keep on the glasses naming them, for Clearing old files.
Future<Set<String>> _unchanged(
  BrilliantDevice device,
  Repl repl,
  List<LuaFile> files,
) async {
  await device.uploadScript('glaz_check.lua', checkHelper);
  await repl.run("require('glaz_check')", 'glaz_check ready');
  final same = <String>{};
  for (final f in files.where(checkable)) {
    final name = f.$1 == 'main.lua' ? mainKept : f.$1;
    final want = frameFileHash(uploadedBytes(f));
    final said = await repl.lines(
      "glaz_check('$name',$want)",
      '',
      timeout: const Duration(seconds: 15),
      match: (l) => l == 'same $name' || l == 'diff $name',
    );
    if (said.lastOrNull == 'same $name') same.add(f.$1);
  }
  return same;
}

/// [bytes] in hex, two digits a byte, split into pieces of at most [max]
/// digits (rounded down to whole bytes).
List<String> hexPieces(List<int> bytes, int max) {
  final per = max ~/ 2;
  return [
    for (var i = 0; i < bytes.length || i == 0; i += per)
      [
        for (final b in bytes.skip(i).take(per))
          b.toRadixString(16).padLeft(2, '0'),
      ].join(),
  ];
}

/// Turns hex back into bytes, on the glasses, for [uploadBytes].
const _unhex =
    "function glaz_unhex(s) return (s:gsub('..',function(x) "
    "return string.char(tonumber(x,16)) end)) end";

/// Writes [bytes] to [name] on the glasses, as frame_ble's uploadScript
/// does a script, but byte for byte: uploadScript sends text, and bytecode
/// is not text (AGENTS.md: non-ASCII breaks it). Sent as hex, two
/// characters a byte: escaping only the bytes that need it came to three
/// and a third, as bytecode is mostly not printable.
///
/// [meanwhile] is called between pieces, at most every [meanwhileEvery]:
/// the upload's picture moves on (GlassesPicture.tick).
Future<void> uploadBytes(
  BrilliantDevice device,
  String name,
  Uint8List bytes, {
  Future<void> Function()? meanwhile,
  Duration meanwhileEvery = const Duration(milliseconds: 300),
}) async {
  Future<void> run(String lua, String what) async {
    final resp = await device.sendString("$lua;print('\x02')", log: false);
    if (resp != '\x02') throw Exception('$what $name: $resp');
  }

  await run(_unhex, 'Error preparing');
  await run("f=frame.file.open('$name','w')", 'Error opening');
  // the command around a piece: f:write(glaz_unhex(''));print('\x02')
  final since = Stopwatch()..start();
  for (final piece in hexPieces(bytes, device.maxStringLength! - 36)) {
    await run("f:write(glaz_unhex('$piece'))", 'Error writing');
    if (meanwhile != null && since.elapsed >= meanwhileEvery) {
      await meanwhile();
      since.reset();
    }
  }
  await run('f:close() glaz_unhex=nil', 'Error closing');
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
  await device.sendBreakSignal();
  var hasApp = true;
  try {
    final repl = Repl(device);
    await repl.ready(attempts: 3);
    // no main.lua -- an upload cut short -- and nothing would ever say it
    // runs: say so now, rather than wait it out
    final said = await repl.lines(
      "$unhook print(pcall(frame.file.open,'main.lua','read') and 'app' "
          "or 'no app')",
      '',
      match: (l) => l == 'app' || l == 'no app',
    );
    hasApp = said.lastOrNull != 'no app';
  } catch (_) {} // a stuck app: reset it all the same
  if (!hasApp) {
    throw Exception('there is no app on the glasses: Upload it again');
  }
  // the app is up in about a second (app/glaz_boot.lua)
  final running = replLines(device)
      .firstWhere((s) => s == 'Frame app is running')
      .timeout(restartWait);
  await device.sendResetSignal();
  try {
    await running;
  } on TimeoutException {
    report('Restarted; waiting for the glasses');
  } on StateError {
    report('Restarted; waiting for the glasses'); // link dropped meanwhile
  }
}

/// How long Restart waits to hear the app say it runs.
const restartWait = Duration(seconds: 12);
