import 'dart:async';

import 'package:flutter/services.dart';
import 'package:frame_ble/frame_ble.dart';

import '../services/glaz_log.dart';
import 'lua_min.dart';
import 'model.dart';
import 'parts.dart';
import 'update_screen.dart';

/// Putting the app on the glasses, the way ../../scripts/host_test.py does it:
/// stop the running app, take main.lua out of the way, reset into a bare
/// REPL with all memory free, upload, then start main.lua. See
/// ../../docs/FRAME.md ("Deploy as main.lua") for why each step is there.
///
/// The Lua comes from the app's assets (assets/lua/), which link to the
/// repository's glaz/ and apps/.

/// One file for the glasses: its name there, its text, and its bytecode
/// when the app was built with it (tool/compile_lua.sh) and it still
/// matches the text. Without bytecode the text goes up, and require()
/// loads it as text on the glasses.
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
/// assets/lua/apps/photo/photo.lua -> assets/luac/apps.photo.photo.luac.
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

/// Everything to upload to [model], in order: libraries, the app's parts,
/// modules, the app, main.lua last -- a half-finished upload then leaves no
/// main.lua to boot into. [installed] says which modules to send (by file
/// name, no .lua); glaz.lua leaves the others out of its menu. No sprites:
/// the phone draws the eye itself while it uploads (update_screen.dart),
/// and one kept on the glasses took memory the app needs.
///
/// Of each file's parts (docs/DEVICES.md) only [model]'s go up, and a
/// module only when it has one (parts.dart). A part with nothing in it
/// (`return {}`) does not go up: it only says the module runs there, which
/// the phone knows already, and on Frame every file takes a 4 KB block of a
/// file system of about 44 ([emptyPart]). main.lua is glaz_boot's part for
/// [model]: it knows the glasses before anything is loaded.
///
/// Each file carries its bytecode from assets/luac/ when that was compiled
/// from this very text and [model] loads bytecode (Frame's; Halo takes
/// text only). The glasses do not compile anything: Frame has not the
/// memory for the app ([needBytecode]). The text is minified
/// (lua_min.dart), for what goes up as source: half the time, and less
/// to load.
Future<List<LuaFile>> luaFiles(
  AssetBundle bundle,
  bool Function(String module) installed, {
  GlassesModel model = GlassesModel.frame,
}) async {
  final manifest = await AssetManifest.loadFromAssetBundle(bundle);
  final assets = manifest.listAssets().where((a) => a.endsWith('.lua'));
  final compiled = await _compiled(bundle);
  final modules = modulesFor(assets, model);

  String base(String path) => path.split('/').last;

  Future<LuaFile> file(String path, [String? name]) async {
    final bytes = (await bundle.load(path)).buffer.asUint8List();
    final text = String.fromCharCodes(bytes);
    Uint8List? code;
    if (model.loadsBytecode) {
      if (compiled[path] case final hash? when hash == fnv1a(bytes)) {
        try {
          code = (await bundle.load(luacAsset(path))).buffer.asUint8List();
        } catch (_) {} // listed, but not in this build: source it is
      }
    }
    return (name ?? base(path), minifyLua(text), code);
  }

  // a file the same everywhere, or [model]'s part
  bool mine(String path) {
    final part = partFor(base(path));
    return part == null || part == model;
  }

  Future<List<LuaFile>> under(String dir, [bool Function(String)? keep]) async {
    final paths = assets.where((a) => a.startsWith('assets/lua/$dir/')).toList()
      ..sort();
    return [
      for (final p in paths)
        if (mine(p) && (keep == null || keep(stemOf(base(p))))) await file(p),
    ].where((f) => !emptyPart(f)).toList();
  }

  return [
    ...await under('lib'),
    // parts of glaz.lua in files of their own (glaz_host.lua...); the
    // loader's part goes up as main.lua, last
    ...(await under('glaz')).where(
      (f) =>
          stemOf(f.$1) != 'glaz' &&
          (partFor(f.$1) == null || stemOf(f.$1) != _boot),
    ),
    ...await under('apps', (m) => installed(m) && modules.contains(m)),
    // the app itself, loaded by main.lua: the firmware's require() cannot
    // be trusted with a file its size (glaz/glaz_boot.frame.lua)
    await file(
      'assets/lua/glaz/glaz.${model.name}.lua',
      '$appName.${model.name}.lua',
    ),
    await file('assets/lua/glaz/glaz.lua', appFile),
    await file('assets/lua/glaz/$_boot.${model.name}.lua', 'main.lua'),
  ];
}

/// Whether [f] is a part with nothing in it: `return {}`, or no code at
/// all. require() does without it (glaz/glaz_boot.lua).
bool emptyPart(LuaFile f) {
  if (partFor(f.$1) == null) return false;
  final code = f.$2
      .split('\n')
      .where((l) => !l.trimLeft().startsWith('--'))
      .join()
      .replaceAll(RegExp(r'\s'), '');
  return code.isEmpty || code == 'return{}';
}

/// What glaz.lua is called on the glasses, and its parts after it
/// (glaz_app.frame.lua); main.lua, which loads it, is glaz_boot's part.
const appName = 'glaz_app';
const appFile = '$appName.lua';
const _boot = 'glaz_boot';

/// Stops an upload to [model] that would not start: Frame cannot load the
/// app from text -- compiling it takes more memory than the glasses have
/// (docs/FRAME.md) -- so it needs the app's bytecode, which every build
/// makes (tool/compile_lua.sh; apk, linux-app, the Nix package, CI). The
/// smaller files may go up as text: changed since the build, say.
void needBytecode(List<LuaFile> files, GlassesModel model) {
  if (!model.loadsBytecode) return;
  final app = files.where((f) => f.$1 == appFile).firstOrNull;
  if (app != null && app.$3 == null) {
    throw Exception(
      '$appFile has no bytecode, and ${model.label} cannot compile it: '
      'build the app with tool/compile_lua.sh (apk and linux-app do)',
    );
  }
}

/// What the last upload wrote, on the glasses: 'hash size name' a line,
/// for each file ([checkHelper]). Not Lua, so Clearing old files leaves
/// it; written once the files are all there.
const sumsFile = 'glaz_sums.txt';

/// [sumsFile]'s text for [files], all of them on the glasses now.
String sums(List<LuaFile> files) => [
  for (final f in files)
    '${frameFileHash(uploadedBytes(f))} ${uploadedBytes(f).length} ${f.$1}',
].join('\n');

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

/// Helpers on the glasses for the duration of an upload, as glaz_check.lua.
///
/// Says whether a file on the glasses is already what an upload would
/// write: glaz_check(name, hash) prints 'same NAME' or 'diff NAME', and
/// files that are the same go in glaz_keep, for Clearing old files to
/// leave. See [frameFileHash] for the hash. Uploaded for the duration of
/// an upload. A read() that never ends -- the
/// firmware's at the end of a file is not quite sure -- gives up and says
/// diff after 4000 pieces.
///
/// Most files need no reading: [sumsFile], which the last upload wrote,
/// says what each file got, and a file still of that size is taken to be
/// what it says. It is read and removed on loading: an upload cut short
/// leaves none, and every file is read again. Its main.lua is looked for
/// as [mainKept], where the upload has put it.
const checkHelper = r'''
glaz_keep = {}
-- glaz_sums.txt, 'hash size name' a line, and the files' sizes now
local sums, sizes = {}, {}
local ok, h = pcall(frame.file.open, 'glaz_sums.txt', 'read')
if ok then
  for _ = 1, 200 do
    local l = h:read()
    if not l then break end
    local x, s, n = l:match('^(%d+) (%d+) (%S+)$')
    if n then sums[n] = { tonumber(x), tonumber(s) } end
  end
  h:close()
  pcall(frame.file.remove, 'glaz_sums.txt')
end
pcall(function()
  for _, e in ipairs(frame.file.listdir('/')) do sizes[e.name] = e.size end
end)
function glaz_check(name, want)
  local s = sums[name == 'glaz_prev.lua' and 'main.lua' or name]
  if s and s[1] == want and sizes[name] == s[2] then
    glaz_keep[name] = true
    print('same ' .. name)
    return
  end
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
-- room for an upload: free space, and what clearing the Lua files not in
-- glaz_keep frees, each in whole blocks of b bytes; -1 when the firmware
-- cannot tell (frame.file.space is the glaz firmware's)
function glaz_room(b)
  local s = frame.file.space and frame.file.space()
  if not s then print('room -1') return end
  local f = s.free
  for _, e in ipairs(frame.file.listdir('/')) do
    if e.type ~= 2 and e.name:match('%.lua$') and not glaz_keep[e.name] then
      f = f + (e.size + b - 1) // b * b
    end
  end
  print('room ' .. f)
end
-- a file through the data channel, for uploadBytes: opens it, says
-- 'recv NAME', and writes every packet that comes, saying 'got N' (bytes
-- so far) after each, then 'wrote NAME' after the last
function glaz_recv(name, size)
  local f, got, ble = frame.file.open(name, 'w'), 0, frame.bluetooth
  ble.receive_callback(function(d)
    f:write(d)
    got = got + #d
    if got < size then
      print('got ' .. got)
    else
      ble.receive_callback(nil)
      f:close()
      print('wrote ' .. name)
    end
  end)
  print('recv ' .. name)
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
  /// require('main') here, in the Lua that has just written two dozen
  /// files: in a broken-up heap the firmware's require() failed a
  /// realloc() and the glasses rebooted (seen when the upload still
  /// compiled files there; the same main.lua started fine on the reboot).
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
      glazLog(
        LogKind.task,
        'the glasses said on start: ${said.join(' / ')}',
        problem: true,
      );
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

/// How long each step of an upload took, and how fast the files went up:
/// logged when it ends, done or not, to see where the time goes.
class UploadSteps {
  final _clock = Stopwatch()..start();
  final _took = <String, Duration>{};
  String? _step;
  var _since = Duration.zero;

  /// Bytes written to the glasses, and how many files.
  var bytes = 0;
  var files = 0;

  /// [step] starts now; the one before it ends.
  void start(String step) {
    final now = _clock.elapsed;
    if (_step case final s?) {
      _took[s] = (_took[s] ?? Duration.zero) + now - _since;
    }
    _step = step;
    _since = now;
  }

  /// 'took 41.2 s: stopping 0.3 s, ..., writing 25.1 s (12 files, 137 KB,
  /// 5.4 KB/s), starting 4.4 s'.
  String summary() {
    start(''); // closes the last step
    String s(Duration d) => (d.inMilliseconds / 1000).toStringAsFixed(1);
    final steps = [
      for (final MapEntry(:key, :value) in _took.entries)
        if (key.isNotEmpty)
          key == 'writing' && bytes > 0
              ? 'writing ${s(value)} s ($files files, ${bytes ~/ 1024} KB, '
                    '${(bytes / 1024 / (value.inMilliseconds / 1000)).toStringAsFixed(1)} KB/s)'
              : '$key ${s(value)} s',
    ];
    return 'took ${s(_clock.elapsed)} s: ${steps.join(', ')}';
  }

  /// What the upload did, for the person who started it: 'nothing
  /// changed, 8.8 s', or '2 files written (14 KB), 12.1 s'.
  String result() {
    final took =
        '${(_clock.elapsed.inMilliseconds / 1000).toStringAsFixed(1)} s';
    if (files == 0) return 'nothing changed, $took';
    final kb = bytes < 1024 ? '$bytes bytes' : '${bytes ~/ 1024} KB';
    return '$files ${files == 1 ? 'file' : 'files'} written ($kb), $took';
  }
}

/// Puts [files] (luaFiles) on the glasses, [model] being which they are:
/// the picture on them while it runs is that model's. Says what it did
/// ([UploadSteps.result]).
Future<String> uploadApp(
  BrilliantDevice device,
  List<LuaFile> files,
  void Function(String step, [double? progress]) report, {
  GlassesModel model = GlassesModel.frame,
}) async {
  final steps = UploadSteps();
  try {
    await _upload(device, files, report, steps, model);
  } finally {
    glazLog(LogKind.task, 'Upload: ${steps.summary()}');
  }
  return steps.result();
}

Future<void> _upload(
  BrilliantDevice device,
  List<LuaFile> files,
  void Function(String step, [double? progress]) report,
  UploadSteps steps,
  GlassesModel model,
) async {
  final repl = Repl(device);

  steps.start('stopping');
  report('Stopping the app');
  await device.sendBreakSignal();
  await repl.ready();
  // main.lua out of the way, but kept: it may need no uploading
  await repl.run(
    "$unhook pcall(frame.file.rename, 'main.lua', '$mainKept');"
        "print('cleared')",
    'cleared',
  );

  steps.start('resetting');
  report('Resetting the glasses');
  await device.sendResetSignal();
  await repl.ready();
  // the eye wired up, with what is going on under it; its art lives in Lua
  // globals, so after a reset it is loaded again
  final picture = model == GlassesModel.halo
      ? HaloPicture(repl.run)
      : GlassesPicture(repl.run);
  await picture.load();
  await picture.draw('Uploading...', progress: 0);

  // Only what changed goes up: the glasses hash each file they have and
  // say whether it is what this upload would write. Usually one or two
  // modules of two dozen are not.
  steps.start('checking');
  report('Checking what changed');
  await picture.draw('Checking...', progress: 0);
  Set<String> same;
  try {
    same = await _unchanged(device, repl, files);
  } on Exception catch (e) {
    // Full to the last block: not even the check's helper can be written,
    // so nothing could be cleared to make room. Left so by an upload that
    // ran out halfway, which also took main.lua: every Lua file goes, and
    // everything goes up again. Not Lua (settings.txt, say) stays.
    if (!'$e'.contains('error writing to file')) rethrow;
    glazLog(
      LogKind.task,
      'Upload: the glasses are full; clearing every Lua file',
      problem: true,
    );
    report('Clearing the glasses: they are full');
    await repl.lines(
      "local n=0 for _,e in ipairs(frame.file.listdir('/')) do "
          "if e.type~=2 and e.name:match('%.lua\$') "
          "and pcall(frame.file.remove,e.name) then n=n+1 end end "
          "print('cleared '..n)",
      'cleared',
      // a full file system takes its time to give up files
      timeout: const Duration(seconds: 30),
      match: (l) => l.startsWith('cleared '),
    );
    same = await _unchanged(device, repl, files);
  }
  glazLog(
    LogKind.task,
    'Upload: ${same.length} of ${files.length} files unchanged',
  );

  // Room for it, before anything goes: an upload that runs out of space
  // halfway leaves the glasses with no app (main.lua is already aside).
  // Free space now, and what clearing old files frees, against what goes
  // up, each file in whole blocks. frame.file.space is the glaz firmware's;
  // without it the upload goes ahead unchecked.
  try {
    await _room(repl, [
      for (final f in files)
        if (!same.contains(f.$1)) f,
    ]);
  } catch (_) {
    // nothing cleared yet: the old app goes back, and starts
    await repl.run(
      "pcall(frame.file.rename,'$mainKept','main.lua') print('restored')",
      'restored',
    );
    await device.sendResetSignal();
    rethrow;
  }

  // Lua files from earlier uploads -- modules switched off or gone, sprites
  // no longer drawn, files that changed -- go; those found the same stay.
  // Done on the glasses, answered with one line: listing the files to the
  // phone made them print two dozen lines at once, and lines printed
  // faster than the link sends are lost -- the end of the list never
  // arrived. Anything not Lua stays: settings.txt, say.
  steps.start('clearing');
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
  glazLog(
    LogKind.task,
    'Upload: ${cleared.isEmpty ? 'cleared' : cleared.last}',
  );

  // Bytecode goes up as it is, text as text; main.lua last, so a
  // half-finished upload leaves none to start.
  int size(LuaFile f) => f.$3?.length ?? f.$2.length;
  final main = files.firstWhere((f) => f.$1 == 'main.lua');
  final order = [
    for (final f in files)
      if (f != main && !same.contains(f.$1)) f,
    if (!same.contains('main.lua')) main,
  ];
  final source = [
    for (final f in order)
      if (f.$3 == null) f.$1,
  ];
  if (source.isNotEmpty) {
    glazLog(LogKind.task, 'Upload: as text, no bytecode: ${source.join(' ')}');
  }
  final total = order.fold<int>(0, (n, f) => n + size(f));
  var done = 0;
  steps.start('writing');
  for (final f in order) {
    final (name, text, code) = f;
    report('Uploading $name', done / total);
    await picture.draw('Uploading: $name', progress: done / total);
    if (code == null) {
      await device.uploadScript(name, text);
    } else {
      await uploadBytes(device, name, code, meanwhile: picture.tick);
    }
    done += size(f);
    steps.bytes = done;
    steps.files++;
  }
  if (same.contains('main.lua')) {
    await repl.run(
      "pcall(frame.file.rename,'$mainKept','main.lua') print('restored')",
      'restored',
    );
  }
  // the next upload's check reads this rather than every file
  await device.uploadScript(sumsFile, sums(files));

  steps.start('starting');
  report('Starting the app', 1);
  await picture.draw('Starting...', progress: 1);
  await repl.start();
}

/// A file system block on Frame: a flash page (CODEPAGESIZE). littlefs
/// gives every file at least one, but for the tiniest, kept in its
/// directory's own.
const fileBlock = 4096;

/// Blocks to spare beyond the files: littlefs writes a directory anew
/// elsewhere as it grows.
const _spareBlocks = 1;

/// The bytes [files] take on the glasses' file system, in whole blocks.
int blocksFor(Iterable<LuaFile> files) => files.fold(0, (n, f) {
  final size = uploadedBytes(f).length;
  return n + (size <= 32 ? 0 : (size + fileBlock - 1) ~/ fileBlock * fileBlock);
});

/// Throws, before anything is cleared, when [writes] would not fit. Run
/// after [_unchanged]: its helper has glaz_room(), and its glaz_keep says
/// which files stay.
Future<void> _room(Repl repl, List<LuaFile> writes) async {
  // in glaz_check.lua: a line of Lua must fit one packet (MTU less 3)
  final said = await repl.lines(
    'glaz_room($fileBlock)',
    '',
    match: (l) => l.startsWith('room '),
  );
  final room = int.tryParse(said.lastOrNull?.substring(5) ?? '') ?? -1;
  if (room < 0) return; // cannot tell: go ahead
  // and a block for sumsFile, removed when the check read it
  final need = blocksFor(writes) + (_spareBlocks + 1) * fileBlock;
  glazLog(
    LogKind.task,
    'Upload: needs ${need ~/ 1024} KB, the glasses have ${room ~/ 1024} KB',
  );
  if (need > room) {
    throw Exception(
      'not enough room on the glasses: the upload needs ${need ~/ 1024} KB '
      'and they have ${room ~/ 1024} KB. Switch some apps off in Menu, '
      'or delete files on the glasses, and upload again',
    );
  }
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
  for (final f in files) {
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

/// [bytes] in packets of at most [max] bytes.
List<List<int>> dataPieces(List<int> bytes, int max) => [
  for (var i = 0; i < bytes.length; i += max)
    bytes.sublist(i, i + max < bytes.length ? i + max : bytes.length),
];

/// Writes [bytes] to [name] on the glasses, byte for byte: uploadScript
/// sends text, and bytecode is not text (AGENTS.md: non-ASCII breaks it).
/// Sent as they are over the data channel, a full packet each (about 240
/// bytes), to glaz_recv ([checkHelper], which must be loaded): as hex
/// through the REPL, a packet carried half as many, and the glasses
/// decoded them in Lua.
///
/// One packet at a time, each answered: the firmware keeps one data
/// packet, and the next overwrites it (lua_bluetooth_data_interrupt in
/// bluetooth.c). The callback runs while the REPL is idle -- frame.sleep()
/// runs Lua all the while -- so the picture's writes go between packets.
///
/// [meanwhile] is called between packets, at most every [meanwhileEvery]:
/// the upload's picture moves on (GlassesPicture.tick).
Future<void> uploadBytes(
  BrilliantDevice device,
  String name,
  Uint8List bytes, {
  Future<void> Function()? meanwhile,
  Duration meanwhileEvery = const Duration(milliseconds: 300),
}) async {
  final repl = Repl(device);
  if (bytes.isEmpty) {
    await repl.run(
      "frame.file.open('$name','w'):close() print('wrote $name')",
      'wrote $name',
    );
    return;
  }
  await repl.run("glaz_recv('$name',${bytes.length})", 'recv $name');
  final pieces = dataPieces(bytes, device.maxDataLength!);
  final since = Stopwatch()..start();
  var sent = 0;
  try {
    for (final piece in pieces) {
      sent += piece.length;
      final ack = sent < bytes.length ? 'got $sent' : 'wrote $name';
      final heard = replLines(device)
          .firstWhere((s) => s == ack || s.contains('error'))
          .timeout(const Duration(seconds: 5));
      await device.sendData(piece);
      final said = await heard;
      if (said != ack) throw Exception('Error writing $name: $said');
      if (meanwhile != null &&
          sent < bytes.length &&
          since.elapsed >= meanwhileEvery) {
        await meanwhile();
        since.reset();
      }
    }
  } catch (_) {
    // the file half written: let go of it and of the callback
    await device.sendString(
      'pcall(frame.bluetooth.receive_callback,nil)',
      awaitResponse: false,
      log: false,
    );
    rethrow;
  }
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
  // the app is up in about a second (glaz/glaz_boot.lua)
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
