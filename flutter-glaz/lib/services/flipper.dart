import 'dart:async';

import 'package:flutter/foundation.dart';

import '../flipper/flipper_ble.dart';
import '../flipper/proto.dart';
import '../frame/link.dart';
import '../frame/protocol.dart';
import '../settings.dart';
import 'glaz_log.dart';

/// A Flipper Zero's screen on the glasses (apps/flipper/flipper.lua, and
/// docs/FLIPPER.md). The module asks with FLIPPER [1] when it comes on
/// screen and says [0] when it goes; meanwhile the phone holds the Flipper
/// over Bluetooth, takes its screen frames and sends the glasses the rows
/// that changed, one frame at a time: the next only once the glasses
/// answer [2, seq] for the last.
class FlipperMirror extends ChangeNotifier {
  FlipperMirror(
    this.link,
    this.settings, {
    FlipperPort? port,
    void Function(List<int>)? send,
  }) : port = port ?? FlipperBle(),
       _send = send ?? ((b) => link.send(moduleCall, b, log: false));

  final FrameLink link;
  final Settings settings;
  final FlipperPort port;
  final void Function(List<int>) _send;

  /// No answer from the glasses this long: they get every row again.
  static const answerWait = Duration(milliseconds: 1500);

  /// The Flipper lost while the module is open: tried again after this.
  static const retryAfter = Duration(seconds: 3);

  /// What is going on, for the phone's screen.
  String state = 'off';

  bool _wanted = false;
  bool _open = false;
  bool _opening = false;
  int _commandId = 0;
  final _splitter = MessageSplitter();
  final _subs = <StreamSubscription<Object?>>[];
  Timer? _retry;

  Uint8List? _latest; // the Flipper's screen as the glasses draw rows
  Uint8List? _shown; // what the glasses have
  int _seq = 0;
  Uint8List? _inFlight; // sent as _seq, not answered yet
  Timer? _answer;

  static const _prefix = 'flipper\n';

  void attach() {
    link.events.listen(onEvent);
    link.addListener(() {
      if (link.state != LinkState.connected && _wanted) _stop();
    });
  }

  /// A message from the glasses; only FLIPPER's are this service's.
  void onEvent(List<int> m) {
    if (m.isEmpty || m[0] != flipper || m.length < 2) return;
    switch (m[1]) {
      case 1:
        _start();
      case 0:
        _stop();
      case 2:
        if (m.length > 2) _taken(m[2]);
    }
  }

  void _status(String text) {
    state = text;
    notifyListeners();
    _send([..._prefix.codeUnits, ...'s$text'.codeUnits]);
  }

  int _nextId() {
    _commandId = _commandId >= 0x7FFFFFFF ? 1 : _commandId + 1;
    return _commandId;
  }

  Future<void> _start() async {
    _wanted = true;
    _retry?.cancel();
    if (!settings.serviceOn('flipper')) {
      _status('Flipper is off in glaz');
      return;
    }
    // the glasses start blank: every row again
    _shown = null;
    _inFlight = null;
    if (_open) {
      _pump();
      return;
    }
    if (_opening) return;
    _opening = true;
    _status('looking for the Flipper');
    try {
      await port.open();
    } on FlipperTrouble catch (e) {
      _opening = false;
      if (_wanted) {
        _status(e.message);
        _retry = Timer(retryAfter, () {
          if (_wanted) _start();
        });
      }
      return;
    }
    _opening = false;
    if (!_wanted) {
      await port.close();
      return;
    }
    _open = true;
    _splitter.clear();
    _subs
      ..add(port.received.listen(_onBytes))
      ..add(port.lost.listen((_) => _onLost()));
    state = 'connected';
    notifyListeners();
    try {
      await port.write(startScreenStream(_nextId()));
      // the Flipper sends a frame when its screen changes, not before
      if (_latest == null) _status('press a Flipper button');
    } catch (e) {
      glazLog(LogKind.link, 'Flipper: $e', problem: true);
      _onLost();
    }
  }

  void _onBytes(List<int> bytes) {
    for (final m in _splitter.add(bytes)) {
      if (m.status != 0) {
        glazLog(LogKind.link, 'Flipper: status ${m.status}', problem: true);
      }
      if (!m.isFrame) continue;
      try {
        final f = decodeFrame(m.body);
        _latest = toRows(f.data, f.orientation);
      } on FormatException catch (e) {
        glazLog(LogKind.link, 'Flipper frame: $e', problem: true);
        continue;
      }
      _pump();
    }
  }

  /// Sends the glasses what changed, unless they still owe an answer.
  void _pump() {
    final latest = _latest;
    if (!_wanted || _inFlight != null || latest == null) return;
    final update = rowsUpdate(latest, _shown);
    if (update == null) return;
    _seq = (_seq + 1) & 0xFF;
    _inFlight = latest;
    _send([..._prefix.codeUnits, 0x66 /* f */, _seq, ...update]);
    _answer?.cancel();
    _answer = Timer(answerWait, () {
      // lost on the way, or the glasses were busy: start over
      _inFlight = null;
      _shown = null;
      _pump();
    });
  }

  void _taken(int seq) {
    if (_inFlight == null || seq != _seq) return;
    _answer?.cancel();
    _shown = _inFlight;
    _inFlight = null;
    _pump();
  }

  void _onLost() {
    _close();
    if (!_wanted) return;
    _status('Flipper lost');
    _retry = Timer(retryAfter, () {
      if (_wanted) _start();
    });
  }

  Future<void> _stop() async {
    _wanted = false;
    _retry?.cancel();
    if (_open) {
      try {
        await port.write(stopScreenStream(_nextId()));
      } catch (_) {}
    }
    _close();
  }

  void _close() {
    final was = _open;
    _open = false;
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    _answer?.cancel();
    _inFlight = null;
    _shown = null;
    _latest = null;
    state = 'off';
    notifyListeners();
    if (was) port.close();
  }

  /// Presses [key] on the Flipper: press, short or long, release.
  Future<void> press(FlipperKey key, {bool long = false}) async {
    if (!_open) return;
    for (final type in [
      FlipperInput.press,
      long ? FlipperInput.long : FlipperInput.short,
      FlipperInput.release,
    ]) {
      await port.write(inputEvent(_nextId(), key, type));
    }
  }
}
