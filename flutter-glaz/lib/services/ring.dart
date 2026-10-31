import 'dart:async';

import 'package:flutter/services.dart';

/// A ring remote, the JX-05 sold for TikTok: no keyboard, it swipes and
/// taps like a finger. Each press is one short touch of its own, as the
/// phone saw it (docs/REMOTE.md, "A ring remote"):
///
/// | Ring | Comes as | Key |
/// | --- | --- | --- |
/// | up / down | a swipe up / down, ~0.2 s | arrow up / down |
/// | left / right | a swipe left / right | arrow left / right |
/// | centre | a touch without moving | Enter: select |
/// | centre twice | two touches ~130 ms apart | Escape: back |
/// | centre held | volume down | context menu: the menu |
/// | held up / down | volume down / up, repeated | the menu / back |
///
/// The keys go to [press], which gives them to the glasses as a keyboard's
/// (keys.dart). The motion comes from KeyRemoteService.kt: `[action, x, y,
/// time in ms]`, action 0 touch, 1 move, 2 lift.
class Ring {
  Ring(this.press);

  final void Function(LogicalKeyboardKey) press;

  /// Moving this far, in the phone's pixels, is a swipe; the ring's span
  /// 900 to 1700.
  static const swipe = 200.0;

  /// A second touch this soon makes a double: the ring sends both about
  /// 130 ms apart. A single tap waits this long to be sure.
  static const twice = Duration(milliseconds: 250);

  /// The ring repeats a held key every 150 ms; a press of the same key
  /// this soon after the last is that repeat.
  static const repeat = Duration(milliseconds: 400);

  Offset? _from;
  Timer? _tap;
  int? _key;
  int _keyAt = 0;

  /// One motion from the ring.
  void motion(List args) {
    final [action as int, x as num, y as num, ...] = args;
    final at = Offset(x.toDouble(), y.toDouble());
    switch (action) {
      case 0:
        _from ??= at;
      case 1:
        break;
      default:
        final from = _from;
        if (from == null) return;
        _from = null;
        _lifted(at - from);
    }
  }

  void _lifted(Offset d) {
    if (d.distance >= swipe) {
      press(
        d.dy.abs() > d.dx.abs()
            ? (d.dy < 0
                  ? LogicalKeyboardKey.arrowUp
                  : LogicalKeyboardKey.arrowDown)
            : (d.dx < 0
                  ? LogicalKeyboardKey.arrowLeft
                  : LogicalKeyboardKey.arrowRight),
      );
      return;
    }
    final first = _tap;
    if (first != null && first.isActive) {
      first.cancel();
      _tap = null;
      press(LogicalKeyboardKey.escape);
      return;
    }
    _tap = Timer(twice, () {
      _tap = null;
      press(LogicalKeyboardKey.enter);
    });
  }

  /// One volume key from the ring, `[Android key code, time in ms]`, key
  /// downs only.
  void key(List args) {
    final [code as int, ms as int, ...] = args;
    final again = code == _key && ms - _keyAt < repeat.inMilliseconds;
    _key = code;
    _keyAt = ms;
    if (again) return;
    // Android's KEYCODE_VOLUME_UP, KEYCODE_VOLUME_DOWN
    if (code == 24) press(LogicalKeyboardKey.escape);
    if (code == 25) press(LogicalKeyboardKey.contextMenu);
  }

  void dispose() => _tap?.cancel();
}
