import 'dart:async';

import 'package:flutter/foundation.dart';

import '../flipper/remote_status.dart';
import '../frame/link.dart';
import '../frame/protocol.dart';
import '../glasses_menu.dart';
import '../settings.dart';
import 'glasses_lua.dart';
import 'keys.dart';

/// Tells the Flipper's Glaz app (flipper-glaz/) about the glasses: their
/// name, free disk and memory, and the app on their screen. The Flipper
/// is the phone's keyboard remote meanwhile ([KeyRemote]); while a
/// keyboard is attached, this looks for a Flipper among the paired ones
/// and writes the status to it whenever it changes.
class FlipperRemote extends ChangeNotifier {
  FlipperRemote(
    this.link,
    this.settings,
    this.keys,
    this.lua, {
    FlipperStatusPort? port,
  }) : port = port ?? FlipperStatusBle();

  final FrameLink link;
  final Settings settings;
  final KeyRemote keys;
  final GlassesLua lua;
  final FlipperStatusPort port;

  /// Free disk and memory are asked of the glasses this often, and a
  /// Flipper not found is looked for again.
  static const every = Duration(minutes: 1);

  /// Lua's heap on the glasses in all, measured (docs/FRAME.md): free
  /// memory is this less what Lua uses.
  static const luaHeap = 135 * 1024;

  /// A Flipper with the Glaz app is connected.
  bool connected = false;
  bool _opening = false;

  /// The module on the glasses' screen, by its number in tree order
  /// (APP_START); null: the menu.
  int? _app;
  int? _diskFree;
  int? _memFree;
  List<int>? _sent;
  Timer? _timer;

  bool get _wanted => settings.serviceOn('flipper_remote') && keys.keyboard;

  /// [_wanted] when last looked: the Flipper is looked for as it turns
  /// true, and then once a minute, not on every change of the link.
  bool _wasWanted = false;

  void attach() {
    link.events.listen(onEvent);
    link.addListener(_changed);
    keys.addListener(_changed);
    port.lost.listen((_) {
      connected = false;
      _sent = null;
      notifyListeners();
    });
    _timer = Timer.periodic(every, (_) => _tick());
    _changed();
  }

  /// What the glasses are, as the Flipper shows it.
  GlassesStatus get status {
    if (!link.connected) return const GlassesStatus();
    final modules = [for (final s in glassesMenu) ...s.modules];
    final app = _app;
    return GlassesStatus(
      name: link.name ?? 'Frame',
      diskFree: _diskFree,
      memFree: _memFree,
      app: app != null && app >= 1 && app <= modules.length
          ? modules[app - 1].label
          : 'Menu',
    );
  }

  @visibleForTesting
  void onEvent(List<int> m) {
    if (m.length < 2) return;
    switch (m[0]) {
      case appStart:
        _app = m[1];
      case appStop || appBackground:
        if (_app == m[1]) _app = null;
      default:
        return;
    }
    _send();
  }

  void _changed() {
    if (!link.connected) {
      _app = null;
      _diskFree = null;
      _memFree = null;
    }
    final wanted = _wanted;
    final turnedOn = wanted && !_wasWanted;
    _wasWanted = wanted;
    if (turnedOn && !connected) {
      _open();
    } else if (!wanted && connected) {
      connected = false;
      _sent = null;
      port.close();
      notifyListeners();
    }
    _send();
  }

  Future<void> _open() async {
    if (_opening) return;
    _opening = true;
    try {
      connected = await port.open();
    } finally {
      _opening = false;
    }
    if (!connected) return;
    notifyListeners();
    _send(); // what is known now; disk and memory once the glasses answer
    await _ask();
    _send();
  }

  Future<void> _tick() async {
    if (_wanted && !connected) return _open();
    await _ask();
    _send();
  }

  /// Free disk and memory, from the glasses' own Lua (docs/PROTOCOL.md,
  /// "Lua console"); frame.file.space is the glaz firmware's.
  Future<void> _ask() async {
    if (!connected || !link.connected || link.busy) return;
    try {
      final a = await lua.run(
        "(frame.file.space and frame.file.space().free or -1) .. ' ' .. "
        "math.floor(collectgarbage('count') * 1024)",
      );
      final m = RegExp(r'(-?\d+) (\d+)').firstMatch(a.text);
      if (!a.ok || m == null) return;
      final disk = int.parse(m[1]!);
      _diskFree = disk < 0 ? null : disk;
      _memFree = (luaHeap - int.parse(m[2]!)).clamp(0, luaHeap);
    } catch (_) {
      // no answer: what is known stays
    }
  }

  void _send() {
    if (!connected) return;
    final bytes = encodeStatus(status);
    if (listEquals(bytes, _sent)) return;
    _sent = bytes;
    port.write(bytes).catchError((Object _) {
      _sent = null; // tried again with the next change
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    link.removeListener(_changed);
    keys.removeListener(_changed);
    super.dispose();
  }
}
