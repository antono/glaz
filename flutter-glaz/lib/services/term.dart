import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:xterm/core.dart';

import '../frame/link.dart';
import '../frame/protocol.dart';
import '../settings.dart';
import '../term/hosts.dart';
import '../term/screen.dart';
import 'glaz_log.dart';

/// A shell on a host, as the terminal needs it.
abstract class TermSession {
  Stream<Uint8List> get output;
  void write(Uint8List data);
  void resize(int cols, int rows);
  Future<void> get done;
  void close();
}

/// Opens a [TermSession] on [host], [cols] by [rows].
typedef TermOpener = Future<TermSession> Function(
  TermHost host,
  TermHosts hosts,
  int cols,
  int rows,
);

/// Why a connect failed, in words for the glasses' screen.
class TermTrouble implements Exception {
  TermTrouble(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The terminal on the glasses (modules/term.lua). The module asks with
/// TERM [1, cols, rows] when it comes on screen and says [0] when it goes;
/// the phone holds an SSH shell on the chosen host (term/hosts.dart), keeps
/// its screen in an xterm [Terminal], and sends the glasses the rows that
/// changed, one frame at a time, as Flipper's: the next only once they
/// answer [2, seq]. A keyboard on the phone types into it (keys.dart).
///
/// The shell outlives the module for [keepFor]: closed on the glasses by
/// mistake, or for a notification, it is still there when they open it
/// again.
class TermService extends ChangeNotifier {
  TermService(
    this.link,
    this.settings,
    this.hosts, {
    TermOpener? open,
    void Function(List<int>)? send,
    void Function(List<int>)? gesture,
  }) : _open = open ?? openSsh,
       _send = send ?? ((b) => link.send(moduleCall, b, log: false)),
       _gesture = gesture ?? ((b) => link.send(input, b));

  final FrameLink link;
  final Settings settings;
  final TermHosts hosts;
  final TermOpener _open;
  final void Function(List<int>) _send;
  final void Function(List<int>) _gesture;

  /// No answer from the glasses this long: they get every row again.
  static const answerWait = Duration(milliseconds: 1500);

  /// Output is gathered this long before a frame goes: a burst of it is
  /// one frame, not one a write.
  static const gather = Duration(milliseconds: 40);

  /// The shell is kept this long after the module closes.
  static const keepFor = Duration(minutes: 15);

  final terminal = Terminal(maxLines: 500);

  /// What is going on, for the phone's screen.
  String state = 'off';

  /// The module is on the glasses' screen.
  bool _wanted = false;
  bool _opening = false;
  TermSession? _session;
  TermHost? _host;
  StreamSubscription<String>? _output;
  Timer? _keep;
  Timer? _gather;

  List<GlassesRow>? _shown; // what the glasses have
  List<GlassesRow>? _inFlight; // sent as _seq, not answered yet
  int _seq = 0;
  bool _typed = false;
  Timer? _answer;

  static const _prefix = 'term\n';

  /// The keyboard goes to the shell: the terminal is on the glasses'
  /// screen and connected.
  bool get takesKeys => _wanted && _session != null;

  void attach() {
    link.events.listen(onEvent);
    link.addListener(() {
      if (link.state != LinkState.connected && _wanted) _stop();
    });
    terminal.addListener(_changed);
    terminal.onOutput = (s) => _session?.write(utf8.encode(s));
  }

  /// A message from the glasses; only TERM's are this service's.
  void onEvent(List<int> m) {
    if (m.isEmpty || m[0] != term || m.length < 2) return;
    switch (m[1]) {
      case 1:
        _start(m.length > 2 ? m[2] : termCols, m.length > 3 ? m[3] : termRows);
      case 0:
        _stop();
      case 2:
        if (m.length > 2) _taken(m[2]);
    }
  }

  void _status(String text) {
    state = text;
    notifyListeners();
    _send([..._prefix.codeUnits, ...ascii.encode('s${_ascii(text)}')]);
  }

  static String _ascii(String s) => s.replaceAll(RegExp(r'[^ -~\n]'), '?');

  Future<void> _start(int cols, int rows) async {
    _wanted = true;
    _keep?.cancel();
    _keep = null;
    // the glasses start blank: every row again
    _shown = null;
    _inFlight = null;
    if (!settings.serviceOn('term')) {
      _status('Terminal is off in glaz');
      return;
    }
    final host = hosts.selected;
    if (host == null) {
      _status('Add a host:\nglaz > Menu > Terminal');
      return;
    }
    if (_session != null && _host?.id == host.id) {
      _session!.resize(cols, rows);
      notifyListeners(); // takes the keys again
      _pump();
      return;
    }
    if (_opening) return;
    _close();
    _opening = true;
    _status('connecting to\n${host.label}');
    try {
      terminal.resize(cols, rows);
      final session = await _open(host, hosts, cols, rows);
      _opening = false;
      if (!_wanted && _keep == null) {
        session.close();
        return;
      }
      _session = session;
      _host = host;
      _output = session.output
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(terminal.write);
      session.done.whenComplete(() => _ended(session));
      state = 'connected to ${host.label}';
      glazLog(LogKind.link, 'Terminal: $state');
      notifyListeners();
      _pump();
    } catch (e) {
      _opening = false;
      final why = e is TermTrouble ? e.message : '$e';
      glazLog(LogKind.link, 'Terminal: $why', problem: true);
      if (_wanted) _status('${host.label}:\n$why');
    }
  }

  void _ended(TermSession session) {
    if (_session != session) return;
    _close();
    if (_wanted) _status('the shell ended;\nclose and open again');
  }

  void _changed() {
    if (!_wanted || _session == null) return;
    _gather ??= Timer(gather, () {
      _gather = null;
      _pump();
    });
  }

  /// Sends the glasses what changed, unless they still owe an answer.
  void _pump() {
    if (!_wanted || _inFlight != null || _session == null) return;
    final latest = glassesRows(terminal);
    final frame = termFrame(latest, _shown, _seq + 1, typed: _typed);
    if (frame == null) return;
    _seq = (_seq + 1) & 0xFF;
    _typed = false;
    _inFlight = latest;
    _send([..._prefix.codeUnits, ...frame]);
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

  void _stop() {
    _wanted = false;
    _answer?.cancel();
    _gather?.cancel();
    _gather = null;
    _inFlight = null;
    _shown = null;
    if (_session != null) {
      _keep?.cancel();
      _keep = Timer(keepFor, () {
        _keep = null;
        _close();
      });
    }
    notifyListeners(); // the keys go back to the glasses' menu
  }

  void _close() {
    _output?.cancel();
    _output = null;
    final s = _session;
    _session = null;
    _host = null;
    state = 'off';
    notifyListeners();
    s?.close();
  }

  /// Ends the shell now, whatever the glasses show.
  void disconnect() {
    _keep?.cancel();
    _keep = null;
    _close();
  }

  /// The keys that are keys to the shell, not characters.
  static final _keys = {
    LogicalKeyboardKey.enter: TerminalKey.enter,
    LogicalKeyboardKey.numpadEnter: TerminalKey.enter,
    LogicalKeyboardKey.backspace: TerminalKey.backspace,
    LogicalKeyboardKey.tab: TerminalKey.tab,
    LogicalKeyboardKey.escape: TerminalKey.escape,
    LogicalKeyboardKey.arrowUp: TerminalKey.arrowUp,
    LogicalKeyboardKey.arrowDown: TerminalKey.arrowDown,
    LogicalKeyboardKey.arrowLeft: TerminalKey.arrowLeft,
    LogicalKeyboardKey.arrowRight: TerminalKey.arrowRight,
    LogicalKeyboardKey.home: TerminalKey.home,
    LogicalKeyboardKey.end: TerminalKey.end,
    LogicalKeyboardKey.pageUp: TerminalKey.pageUp,
    LogicalKeyboardKey.pageDown: TerminalKey.pageDown,
    LogicalKeyboardKey.insert: TerminalKey.insert,
    LogicalKeyboardKey.delete: TerminalKey.delete,
    LogicalKeyboardKey.f1: TerminalKey.f1,
    LogicalKeyboardKey.f2: TerminalKey.f2,
    LogicalKeyboardKey.f3: TerminalKey.f3,
    LogicalKeyboardKey.f4: TerminalKey.f4,
    LogicalKeyboardKey.f5: TerminalKey.f5,
    LogicalKeyboardKey.f6: TerminalKey.f6,
    LogicalKeyboardKey.f7: TerminalKey.f7,
    LogicalKeyboardKey.f8: TerminalKey.f8,
    LogicalKeyboardKey.f9: TerminalKey.f9,
    LogicalKeyboardKey.f10: TerminalKey.f10,
    LogicalKeyboardKey.f11: TerminalKey.f11,
    LogicalKeyboardKey.f12: TerminalKey.f12,
  };

  static final _modifiers = {
    LogicalKeyboardKey.shiftLeft,
    LogicalKeyboardKey.shiftRight,
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.controlRight,
    LogicalKeyboardKey.altLeft,
    LogicalKeyboardKey.altRight,
    LogicalKeyboardKey.metaLeft,
    LogicalKeyboardKey.metaRight,
    LogicalKeyboardKey.capsLock,
    LogicalKeyboardKey.fn,
  };

  /// A key down (or repeat) for the shell; true if it was taken, which it
  /// is whenever [takesKeys]. Ctrl+Alt+Esc closes the terminal on the
  /// glasses, as a double tap would.
  bool key(
    LogicalKeyboardKey key, {
    String? character,
    bool ctrl = false,
    bool alt = false,
    bool shift = false,
  }) {
    if (!takesKeys) return false;
    if (ctrl && alt && key == LogicalKeyboardKey.escape) {
      _gesture([1, 2]); // a double tap: back
      return true;
    }
    if (_modifiers.contains(key)) return true;
    final special = _keys[key];
    final c = character ?? '';
    if ((ctrl || alt) && special == null) {
      final code = c.isNotEmpty ? c.toLowerCase().codeUnitAt(0) : _letter(key);
      if (code != null && terminal.charInput(code, ctrl: ctrl, alt: alt)) {
        _typed = true;
        return true;
      }
    }
    if (special != null) {
      terminal.keyInput(special, shift: shift, alt: alt, ctrl: ctrl);
    } else if (c.isNotEmpty && c.codeUnitAt(0) >= 0x20) {
      terminal.textInput(c);
    } else {
      return true;
    }
    _typed = true;
    return true;
  }

  /// a..z for a letter key, as Ctrl gives no character for it.
  static int? _letter(LogicalKeyboardKey key) {
    final id = key.keyId;
    return id >= 0x61 && id <= 0x7A ? id : null;
  }
}

/// The real thing: SSH with dartssh2, a key or a password, the host's key
/// checked against the one seen before (TermHosts.trust).
Future<TermSession> openSsh(
  TermHost host,
  TermHosts hosts,
  int cols,
  int rows,
) async {
  final key = hosts.keyOf(host);
  List<SSHKeyPair>? identities;
  if (key != null) {
    final pem = await hosts.pem(key);
    if (pem == null) throw TermTrouble('key ${key.name} is gone');
    try {
      identities = SSHKeyPair.fromPem(pem, await hosts.passphrase(key));
    } catch (e) {
      throw TermTrouble('key ${key.name}: $e');
    }
  }
  final password = await hosts.password(host);
  final SSHSocket socket;
  try {
    socket = await SSHSocket.connect(
      host.host,
      host.port,
      timeout: const Duration(seconds: 10),
    );
  } catch (e) {
    throw TermTrouble('cannot reach ${host.address}');
  }
  var changed = false;
  final client = SSHClient(
    socket,
    username: host.user,
    identities: identities,
    onPasswordRequest: () => password,
    onVerifyHostKey: (type, fingerprint) {
      final ok = hosts.trust(
        host,
        'SHA256:${base64.encode(fingerprint).replaceAll('=', '')}',
      );
      changed = !ok;
      return ok;
    },
  );
  try {
    await client.authenticated;
    final shell = await client.shell(
      pty: SSHPtyConfig(type: 'xterm-256color', width: cols, height: rows),
    );
    return _SshSession(client, shell);
  } catch (e) {
    client.close();
    if (changed) {
      throw TermTrouble('HOST KEY CHANGED;\nnot connecting');
    }
    if (e is SSHAuthError) {
      throw TermTrouble('not let in as ${host.user}');
    }
    throw TermTrouble('$e');
  }
}

class _SshSession implements TermSession {
  _SshSession(this.client, this.shell);
  final SSHClient client;
  final SSHSession shell;

  /// stdout and stderr as one, as a terminal shows them.
  @override
  late final Stream<Uint8List> output = () {
    final both = StreamController<Uint8List>();
    var open = 2;
    void closed() {
      if (--open == 0) both.close();
    }

    shell.stdout.listen(both.add, onDone: closed, onError: both.addError);
    shell.stderr.listen(both.add, onDone: closed, onError: both.addError);
    return both.stream;
  }();

  @override
  void write(Uint8List data) => shell.write(data);

  @override
  void resize(int cols, int rows) => shell.resizeTerminal(cols, rows);

  @override
  Future<void> get done => shell.done;

  @override
  void close() {
    shell.close();
    client.close();
  }
}
