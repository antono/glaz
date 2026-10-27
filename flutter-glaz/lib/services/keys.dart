import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../frame/link.dart';
import '../frame/protocol.dart';
import '../settings.dart';
import 'term.dart';

/// Any keyboard the phone has as the remote: Bluetooth or USB, a
/// presentation clicker, a gamepad's D-pad, a Flipper Zero in Bluetooth
/// Remote > Keynote. The keys drive the glasses as the Remote tab does
/// (docs/PROTOCOL.md, "Remote"), while the glasses are connected and no
/// text field has the focus; otherwise they do what they always do.
///
/// | Keys | Glasses |
/// | --- | --- |
/// | left, Page Up, previous track | previous item |
/// | right, Page Down, next track | next item |
/// | up / down | a module's own (Scales: the scale); else previous / next |
/// | Space, Enter, D-pad centre, A, play | select; held, the menu |
/// | Backspace, Esc, B | back |
/// | Menu, Start | the menu |
///
/// Android gives keys to the app on screen only. With [background] on --
/// KeyRemoteService.kt, which the user turns on in Accessibility -- the
/// same keys reach the glasses with another app in front, sent here on
/// [channel]; the service keeps them from that app only while they are
/// taken here: the glasses connected, the service on.
///
/// Android 16 (target SDK 36) has predictive back: Android's Back may never
/// come as a key, but as a pop of the route ([didPopRoute]), or, with
/// nothing to pop, close the app without asking. So while the keys are
/// taken, [holdsBack] keeps the root route from popping by itself
/// (main.dart), and a pop this soon after a Back key is dropped.
class KeyRemote extends ChangeNotifier with WidgetsBindingObserver {
  KeyRemote(this.link, this.settings, {void Function(List<int>)? send})
    : _send = send ?? ((b) => link.send(input, b));

  final FrameLink link;
  final Settings settings;
  final void Function(List<int>) _send;

  /// Holding OK this long opens the menu instead: the Flipper has no
  /// menu key.
  static const hold = Duration(milliseconds: 600);

  /// Flipper's Keynote sends its Back as Backspace and then Android's own
  /// Back (hid_keynote.c); the second one, this soon, is dropped rather
  /// than closing the app.
  static const backEcho = Duration(milliseconds: 500);

  static final _previous = {
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.pageUp,
    LogicalKeyboardKey.mediaTrackPrevious,
  };
  static final _next = {
    LogicalKeyboardKey.arrowRight,
    LogicalKeyboardKey.pageDown,
    LogicalKeyboardKey.mediaTrackNext,
  };
  // a pair of their own (INPUT [3, ...]): a module may take them (Scales)
  static final _upDown = {
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowDown,
  };
  static final _ok = {
    LogicalKeyboardKey.space,
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
    LogicalKeyboardKey.select,
    LogicalKeyboardKey.gameButtonA,
    LogicalKeyboardKey.mediaPlayPause,
  };
  static final _back = {
    LogicalKeyboardKey.backspace,
    LogicalKeyboardKey.escape,
    LogicalKeyboardKey.gameButtonB,
  };
  static final _menu = {
    LogicalKeyboardKey.contextMenu,
    LogicalKeyboardKey.gameButtonStart,
  };

  /// When OK went down; null while it is up.
  Duration? _okDown;
  Duration? _backAt;

  /// Since the last Back key, for the pop that may follow it.
  final _sinceBack = Stopwatch();

  /// The Back being dropped is still down.
  bool _echo = false;
  KeyEvent? _claimed;

  static const channel = MethodChannel('glaz/keys');

  /// Every key taken, as Android key codes: what the background service
  /// keeps from other apps.
  static final androidCodes = [
    for (final e in kAndroidToLogicalKey.entries)
      if ({
        ..._previous,
        ..._next,
        ..._upDown,
        ..._ok,
        ..._back,
        ..._menu,
      }.contains(e.value))
        e.key,
  ];

  /// The keys work with Glaz in the background too: the user has turned
  /// on its accessibility service. Android only.
  bool background = false;

  /// A keyboard remote is attached to the phone (Keyboards.kt): while one
  /// is, and drives the glasses ([drives]), their own gestures are off but
  /// the triple tap to sleep (main.dart, HANDS_OFF). Android only.
  bool keyboard = false;

  /// The attached keyboard reaches the glasses: the service is on, and
  /// Glaz is on screen ([shown]) or the background service takes the keys.
  bool drives({required bool shown}) =>
      keyboard && settings.serviceOn('keys') && (shown || background);

  void _keyboard(bool on) {
    if (on == keyboard) return;
    keyboard = on;
    notifyListeners();
  }

  bool get _active =>
      settings.serviceOn('keys') && link.connected && !link.busy;

  bool? _sentActive;
  bool? _sentAll;

  /// The terminal on the glasses: while it [TermService.takesKeys], every
  /// key goes to its shell instead, in the background too.
  TermService? get terminal => _terminal;
  set terminal(TermService? t) {
    _terminal?.removeListener(_sync);
    _terminal = t;
    t?.addListener(_sync);
    _sync();
  }

  TermService? _terminal;

  bool get _typingInShell => _terminal?.takesKeys ?? false;

  /// Back should not close Glaz by itself: it may be Keynote's echo.
  /// Listeners hear when it changes.
  bool holdsBack = false;

  void _hold() {
    if (_active == holdsBack) return;
    holdsBack = _active;
    notifyListeners();
  }

  /// The pop is the echo of a Back key just taken: dropped, once.
  @override
  Future<bool> didPopRoute() async {
    final echo = _sinceBack.isRunning && _sinceBack.elapsed < backEcho;
    _sinceBack
      ..stop()
      ..reset();
    return echo;
  }

  /// Starts listening. The keys taken are also kept from the focus system,
  /// so arrows do not move the focus and Space does not press a button.
  void attach() {
    // before the app's own observers: they would pop
    WidgetsBinding.instance.addObserver(this);
    HardwareKeyboard.instance.addHandler(handle);
    FocusManager.instance.addEarlyKeyEventHandler(
      (event) => identical(event, _claimed)
          ? KeyEventResult.handled
          : KeyEventResult.ignored,
    );
    link.addListener(_hold);
    settings.addListener(_hold);
    _hold();
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'key') fromBackground(call.arguments as List);
      if (call.method == 'keyboard') _keyboard(call.arguments as bool);
    });
    link.addListener(_sync);
    settings.addListener(_sync);
    // back from the system settings, where the service may have changed
    AppLifecycleListener(onResume: refresh);
    _sync();
    refresh();
  }

  /// Asks Android whether the background service is on, and whether a
  /// keyboard is attached.
  Future<void> refresh() async {
    _keyboard(await _call<bool>('keyboard') ?? false);
    final on = await _call<bool>('background') ?? false;
    if (on == background) return;
    background = on;
    notifyListeners();
  }

  /// Opens the system page where the background service is turned on.
  Future<void> openSettings() => _call<void>('settings');

  /// Tells the service which keys to take: all of them, or none.
  void _sync() {
    final all = _active && _typingInShell;
    if (all != _sentAll) {
      _sentAll = all;
      _call<void>('takeAll', all);
    }
    final active = _active;
    if (active == _sentActive) return;
    _sentActive = active;
    _call<void>('take', active ? androidCodes : const <int>[]);
  }

  static Future<T?> _call<T>(String method, [Object? args]) async {
    try {
      return await channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null; // tests, and a platform without the service
    } on PlatformException {
      return null;
    }
  }

  /// One key from the background service: `[action, key code, scan code,
  /// time in ms, character, meta state]`, action 0 down, 1 repeat, 2 up;
  /// the character the key types, 0 for none. No text field to mind: Glaz
  /// is not on screen.
  void fromBackground(List args) {
    final [action as int, code as int, scan as int, ms as int, ...rest] = args;
    final logical = kAndroidToLogicalKey[code];
    if (_typingInShell) {
      if (action == 2 || logical == null) return;
      final char = rest.isNotEmpty ? rest[0] as int : 0;
      final meta = rest.length > 1 ? rest[1] as int : 0;
      _terminal!.key(
        logical,
        character: char > 0 ? String.fromCharCode(char) : null,
        // Android's META_CTRL_ON, META_ALT_ON, META_SHIFT_ON
        ctrl: meta & 0x1000 != 0,
        alt: meta & 0x02 != 0,
        shift: meta & 0x01 != 0,
      );
      return;
    }
    if (logical == null || !_active) return;
    final physical =
        kAndroidToPhysicalKey[scan] ?? const PhysicalKeyboardKey(0);
    final at = Duration(milliseconds: ms);
    _take(switch (action) {
      0 => KeyDownEvent(
        physicalKey: physical,
        logicalKey: logical,
        timeStamp: at,
      ),
      1 => KeyRepeatEvent(
        physicalKey: physical,
        logicalKey: logical,
        timeStamp: at,
      ),
      _ => KeyUpEvent(
        physicalKey: physical,
        logicalKey: logical,
        timeStamp: at,
      ),
    });
  }

  /// One key event; true if it was taken for the glasses.
  bool handle(KeyEvent event) {
    if (_typingInShell && !_typing()) {
      // all of it, key ups too, or the focus system acts on them
      if (event is! KeyUpEvent) {
        final k = HardwareKeyboard.instance;
        _terminal!.key(
          event.logicalKey,
          character: event.character,
          ctrl: k.isControlPressed,
          alt: k.isAltPressed,
          shift: k.isShiftPressed,
        );
      }
      _claimed = event;
      return true;
    }
    final taken = _active && !_typing() && _take(event);
    _claimed = taken ? event : null;
    return taken;
  }

  bool _take(KeyEvent event) {
    final key = event.logicalKey;
    final down = event is KeyDownEvent;
    if (_ok.contains(key)) {
      if (down) {
        _okDown = event.timeStamp;
      } else if (event is KeyUpEvent) {
        final at = _okDown;
        if (at == null) return false;
        _okDown = null;
        _send([1, event.timeStamp - at >= hold ? 3 : 1]);
      }
      return true;
    }
    if (key == LogicalKeyboardKey.goBack) {
      // its key up is dropped too, however late, or Android acts on it
      if (!down) {
        final echo = _echo;
        if (event is KeyUpEvent) _echo = false;
        return echo;
      }
      final at = _backAt;
      return _echo = at != null && event.timeStamp - at < backEcho;
    }
    final List<int> gesture;
    // Up and Down: the glasses treat them as previous and next where the
    // module on screen has no use of its own for them
    if (_upDown.contains(key)) {
      gesture = [3, key == LogicalKeyboardKey.arrowUp ? 255 : 1];
    } else if (_previous.contains(key)) {
      gesture = [2, 255];
    } else if (_next.contains(key)) {
      gesture = [2, 1];
    } else if (_back.contains(key)) {
      gesture = [1, 2];
      if (down) {
        _backAt = event.timeStamp;
        _sinceBack
          ..reset()
          ..start();
      }
    } else if (_menu.contains(key)) {
      gesture = [1, 3];
    } else {
      return false;
    }
    if (down) _send(gesture);
    return true;
  }

  /// A text field has the focus: the keys are for typing.
  static bool _typing() {
    final context = FocusManager.instance.primaryFocus?.context;
    return context != null &&
        (context.widget is EditableText ||
            context.findAncestorWidgetOfExactType<EditableText>() != null);
  }
}
