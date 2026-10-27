import 'dart:async';

import 'package:flutter/foundation.dart';

import '../flipper/companion.dart';
import '../flipper/presses.dart';
import '../flipper/remote_status.dart';
import '../frame/link.dart';
import '../frame/protocol.dart';
import '../glasses_menu.dart';
import '../settings.dart';
import 'glasses_lua.dart';
import 'glaz_log.dart';

/// The Flipper's Glaz app (flipper-glaz/) as a remote for the glasses.
/// Its presses drive them as a keyboard's do ([gestureFor]), and it is
/// told about them: their name, free disk and memory, and the app on
/// their screen, written whenever it changes. While the service is on,
/// this looks for the paired Flipper, and again once a minute. Off
/// Android that is a scan, and only while the glasses are connected: the
/// link scans for them with the same one scanner. On Android the
/// system also wakes glaz when the Flipper comes near, and says so
/// ([appeared], hold.dart).
class FlipperRemote extends ChangeNotifier {
  FlipperRemote(
    this.link,
    this.settings,
    this.lua, {
    FlipperStatusPort? port,
    FlipperCompanion? companion,
    void Function(List<int>)? send,
  }) : companion = companion ?? FlipperCompanion(),
       port = port ?? FlipperStatusBle(companion: companion),
       _sendInput = send ?? ((b) => link.send(input, b));

  final FrameLink link;
  final Settings settings;
  final GlassesLua lua;
  final FlipperCompanion companion;
  final FlipperStatusPort port;
  final void Function(List<int>) _sendInput;

  /// Free disk and memory are asked of the glasses this often, and a
  /// Flipper not found is looked for again.
  static const every = Duration(minutes: 1);

  /// Lua's heap on the glasses in all, measured (docs/FRAME.md): free
  /// memory is this less what Lua uses.
  static const luaHeap = 135 * 1024;

  /// A Flipper with the Glaz app is connected.
  bool connected = false;

  /// The connected Flipper's name.
  String? get name => connected ? port.name : null;

  /// The Flippers the phone is paired with (Android only).
  List<FlipperPaired> paired = const [];
  bool _opening = false;

  /// Goes up with every [forget]: an open under way then is let go.
  int _forgets = 0;

  /// The module on the glasses' screen, by its number in tree order
  /// (APP_START); null: the menu.
  int? _app;
  int? _diskFree;
  int? _memFree;
  List<int>? _sent;
  Timer? _timer;

  /// Whose status last reached this connection's Flipper: logged when
  /// it changes, not with every write. Empty: nothing yet.
  String? _told = '';

  /// What Android was last told by [_observe]; null: nothing yet.
  bool? _observing;

  bool get _wanted => settings.serviceOn('flipper_remote');

  /// The Flipper drives the glasses, as a keyboard does (main.dart,
  /// HANDS_OFF).
  bool get drives => connected && _wanted;

  /// Off Android the Flipper is found by a scan, which would stop the
  /// link's own: looked for only once the glasses are there.
  bool get _mayLook =>
      defaultTargetPlatform == TargetPlatform.android ||
      (link.connected && !link.busy);

  /// [_wanted] when last looked: the Flipper is looked for as it turns
  /// true, and then once a minute, not on every change of the link.
  bool _wasWanted = false;

  void attach() {
    link.events.listen(onEvent);
    link.addListener(_changed);
    settings.addListener(_changed);
    port.keys.listen(onKeys);
    port.lost.listen((_) {
      connected = false;
      _sent = null;
      notifyListeners();
    });
    _timer = Timer.periodic(every, (_) => _tick());
    _changed();
    _refresh();
  }

  /// A press from the Flipper, to the glasses while they are connected
  /// and free; anything not a press is dropped.
  @visibleForTesting
  void onKeys(List<int> bytes) {
    final p = decodePress(bytes);
    if (p == null || !drives || !link.connected || link.busy) return;
    final g = gestureFor(p);
    if (g != null) _sendInput(g);
  }

  /// Pairs a Flipper (Android's chooser, then its PIN) and starts
  /// connecting to it at once; false when none was paired.
  Future<bool> pair() async {
    final p = await companion.pair();
    await _refresh();
    if (p == null) return false;
    if (_wanted) {
      // the new association is watched too
      _observing = true;
      unawaited(companion.observe(true));
    }
    if (_wanted && !connected) unawaited(_open());
    return true;
  }

  /// Android saw the paired Flipper come near (LinkHold): connected now
  /// rather than at the next minute's look.
  void appeared() {
    if (_wanted && !connected) unawaited(_open());
  }

  /// Android wakes glaz as a paired Flipper comes near while the service
  /// is on, and no more once it is off.
  void _observe() {
    if (paired.isEmpty) return;
    final on = _wanted;
    if (on == _observing) return;
    _observing = on;
    unawaited(companion.observe(on));
  }

  /// Unpairs the Flipper at [address], letting go of it first.
  Future<void> forget(String address) async {
    _forgets++;
    if (connected) {
      connected = false;
      _sent = null;
      await port.close();
      notifyListeners();
    }
    await companion.forget(address);
    await _refresh();
  }

  Future<void> _refresh() async {
    paired = await companion.paired();
    _observe();
    notifyListeners();
  }

  /// What the glasses are, as the Flipper shows it.
  GlassesStatus get status {
    if (!link.connected) return const GlassesStatus();
    final modules = [for (final s in glassesMenu) ...s.modules];
    final app = _app;
    return GlassesStatus(
      name: link.name ?? 'Frame',
      battery: link.battery,
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
    _observe();
    _send();
  }

  Future<void> _open() async {
    if (_opening || !_mayLook) return;
    _opening = true;
    final forgets = _forgets;
    try {
      connected = await port.open();
    } finally {
      _opening = false;
    }
    if (connected && (!_wanted || forgets != _forgets)) {
      // turned off, or the Flipper forgotten, while it was connecting
      connected = false;
      await port.close();
    }
    if (!connected) return;
    _told = '';
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
    final glasses = status.name;
    port
        .write(bytes)
        .then((_) {
          if (_told == glasses) return;
          _told = glasses;
          glazLog(
            LogKind.link,
            'Flipper remote: told ${glasses ?? 'no glasses'}',
          );
        })
        .catchError((Object _) {
          _sent = null; // tried again with the next change
        });
  }

  @override
  void dispose() {
    _timer?.cancel();
    link.removeListener(_changed);
    settings.removeListener(_changed);
    super.dispose();
  }
}
