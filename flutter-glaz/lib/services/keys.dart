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
class KeyRemote {
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

  /// The Back being dropped is still down.
  bool _echo = false;
  KeyEvent? _claimed;

  bool get _active =>
      settings.serviceOn('keys') && link.connected && !link.busy;

  /// Starts listening. The keys taken are also kept from the focus system,
  /// so arrows do not move the focus and Space does not press a button.
  void attach() {
    HardwareKeyboard.instance.addHandler(handle);
    FocusManager.instance.addEarlyKeyEventHandler(
      (event) => identical(event, _claimed)
          ? KeyEventResult.handled
          : KeyEventResult.ignored,
    );
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
      if (down) _backAt = event.timeStamp;
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
