import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../frame/link.dart';
import '../frame/protocol.dart';
import '../settings.dart';

/// Any keyboard the phone has as the remote: Bluetooth or USB, a
/// presentation clicker, a gamepad's D-pad, a Flipper Zero in Bluetooth
/// Remote > Keynote. The keys drive the glasses as the Remote tab does
/// (docs/PROTOCOL.md, "Remote"), while the glasses are connected and no
/// text field has the focus; otherwise they do what they always do.
///
/// | Keys | Glasses |
/// | --- | --- |
/// | up, left, Page Up, previous track | previous item |
/// | down, right, Page Down, next track | next item |
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
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.pageUp,
    LogicalKeyboardKey.mediaTrackPrevious,
  };
  static final _next = {
    LogicalKeyboardKey.arrowDown,
    LogicalKeyboardKey.arrowRight,
    LogicalKeyboardKey.pageDown,
    LogicalKeyboardKey.mediaTrackNext,
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
        ..._ok,
        ..._back,
        ..._menu,
      }.contains(e.value))
        e.key,
  ];

  /// The keys work with Glaz in the background too: the user has turned
  /// on its accessibility service. Android only.
  bool background = false;

  bool get _active =>
      settings.serviceOn('keys') && link.connected && !link.busy;

  bool? _sentActive;

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
    });
    link.addListener(_sync);
    settings.addListener(_sync);
    // back from the system settings, where the service may have changed
    AppLifecycleListener(onResume: refresh);
    _sync();
    refresh();
  }

  /// Asks Android whether the background service is on.
  Future<void> refresh() async {
    final on = await _call<bool>('background') ?? false;
    if (on == background) return;
    background = on;
    notifyListeners();
  }

  /// Opens the system page where the background service is turned on.
  Future<void> openSettings() => _call<void>('settings');

  /// Tells the service which keys to take: all of them, or none.
  void _sync() {
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
  /// time in ms]`, action 0 down, 1 repeat, 2 up. No text field to mind:
  /// Glaz is not on screen.
  void fromBackground(List args) {
    final [action as int, code as int, scan as int, ms as int] = args;
    final logical = kAndroidToLogicalKey[code];
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
    if (_previous.contains(key)) {
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
