import 'dart:typed_data';

import 'package:xterm/core.dart';

/// The terminal on the glasses (apps/term/term.lua): what the phone's model
/// of the screen becomes there. A cell is one ASCII character and one
/// attribute byte, frame.display.mono's attrs: the text's palette index in
/// the low nibble, the background's in the high one (0: none).
///
/// The glasses draw printable ASCII only, so the rest is brought down to
/// it: box drawing to - | +, a full block to a lit cell, anything else to
/// '?'. Sixteen colors are all Frame has; xterm's 256 and RGB go to the
/// nearest of them.

/// The size the glasses ask for: 45x12 cells of 14x28.
const termCols = 45;
const termRows = 12;

/// Frame's palette (frame.display's colour table), by index.
abstract final class FramePalette {
  static const none = 0;
  static const white = 1;
  static const grey = 2;
  static const red = 3;
  static const pink = 4;
  static const darkBrown = 5;
  static const brown = 6;
  static const orange = 7;
  static const yellow = 8;
  static const darkGreen = 9;
  static const green = 10;
  static const lightGreen = 11;
  static const nightBlue = 12;
  static const seaBlue = 13;
  static const skyBlue = 14;
  static const cloudBlue = 15;

  /// What each looks like, roughly, for the nearest to an RGB color.
  static const rgb = <int, int>{
    white: 0xFFFFFF,
    grey: 0x808080,
    red: 0xCC2020,
    pink: 0xF080A0,
    darkBrown: 0x503018,
    brown: 0x8A5A2B,
    orange: 0xF09020,
    yellow: 0xF0E040,
    darkGreen: 0x1A5020,
    green: 0x30B040,
    lightGreen: 0x90F070,
    nightBlue: 0x101850,
    seaBlue: 0x2050A0,
    skyBlue: 0x50A0F0,
    cloudBlue: 0xB0D0F0,
  };
}

/// ANSI's 16 as text: black would vanish on the black OLED, so grey.
const _ansiText = [
  FramePalette.grey, // black
  FramePalette.red,
  FramePalette.green,
  FramePalette.yellow,
  FramePalette.skyBlue, // blue: SEABLUE is too dark to read
  FramePalette.pink, // magenta
  FramePalette.cloudBlue, // cyan
  FramePalette.white,
  FramePalette.grey, // bright black
  FramePalette.red,
  FramePalette.lightGreen,
  FramePalette.yellow,
  FramePalette.skyBlue,
  FramePalette.pink,
  FramePalette.cloudBlue,
  FramePalette.white,
];

/// ANSI's 16 as a background: black is no background at all.
const _ansiBackground = [
  FramePalette.none,
  FramePalette.red,
  FramePalette.darkGreen,
  FramePalette.brown,
  FramePalette.nightBlue,
  FramePalette.darkBrown,
  FramePalette.seaBlue,
  FramePalette.grey,
  FramePalette.grey,
  FramePalette.red,
  FramePalette.green,
  FramePalette.orange,
  FramePalette.seaBlue,
  FramePalette.pink,
  FramePalette.skyBlue,
  FramePalette.white,
];

/// Text on a background: dark text where the terminal wants black, so it
/// shows on the background instead of a hole in it (palette 0 draws
/// nothing).
const _darkText = FramePalette.nightBlue;

/// The Frame color nearest to [rgb], 0xRRGGBB.
int nearestFrame(int rgb) {
  var best = FramePalette.white;
  var bestDistance = 1 << 30;
  final r = rgb >> 16 & 0xFF, g = rgb >> 8 & 0xFF, b = rgb & 0xFF;
  FramePalette.rgb.forEach((index, c) {
    final dr = r - (c >> 16 & 0xFF);
    final dg = g - (c >> 8 & 0xFF);
    final db = b - (c & 0xFF);
    final d = 2 * dr * dr + 4 * dg * dg + 3 * db * db;
    if (d < bestDistance) {
      bestDistance = d;
      best = index;
    }
  });
  return best;
}

/// xterm's 256 colors as RGB: 16..231 the cube, 232..255 greys.
int _xterm256(int i) {
  if (i < 232) {
    const steps = [0, 95, 135, 175, 215, 255];
    final n = i - 16;
    return steps[n ~/ 36] << 16 | steps[n ~/ 6 % 6] << 8 | steps[n % 6];
  }
  final v = 8 + 10 * (i - 232);
  return v << 16 | v << 8 | v;
}

/// A cell's color in xterm's encoding (CellColor) as a Frame palette index;
/// null for the default.
int? _frameColor(int color, {required bool background}) {
  final value = color & CellColor.valueMask;
  final ansi = background ? _ansiBackground : _ansiText;
  switch (color & CellColor.typeMask) {
    case CellColor.named:
      return ansi[value & 0x0F];
    case CellColor.palette:
      if (value < 16) return ansi[value];
      final rgb = _xterm256(value);
      if (background && rgb == 0) return FramePalette.none;
      return nearestFrame(rgb);
    case CellColor.rgb:
      if (background && value == 0) return FramePalette.none;
      return nearestFrame(value);
    default:
      return null;
  }
}

/// What the glasses show for a code point: itself if printable ASCII, else
/// something close, else '?'. A full block comes back as null: a lit cell.
String? glassesChar(int codePoint) {
  if (codePoint == 0) return ' ';
  if (codePoint >= 0x20 && codePoint <= 0x7E) {
    return String.fromCharCode(codePoint);
  }
  // box drawing, U+2500..U+257F: light, heavy and double alike
  if (codePoint >= 0x2500 && codePoint <= 0x257F) {
    const horizontal = {
      0x2500, 0x2501, 0x2504, 0x2505, 0x2508, 0x2509, 0x254C, 0x254D, //
      0x2550, 0x2574, 0x2576, 0x2578, 0x257A, 0x257C, 0x257E,
    };
    const vertical = {
      0x2502, 0x2503, 0x2506, 0x2507, 0x250A, 0x250B, 0x254E, 0x254F, //
      0x2551, 0x2575, 0x2577, 0x2579, 0x257B, 0x257D, 0x257F,
    };
    if (horizontal.contains(codePoint)) return '-';
    if (vertical.contains(codePoint)) return '|';
    return '+';
  }
  if (codePoint == 0x2588) return null; // full block
  if (codePoint >= 0x2580 && codePoint <= 0x259F) return '#'; // shades
  const near = {
    0x00A0: ' ', 0x00B7: '.', 0x2022: '*', 0x2013: '-', 0x2014: '-', //
    0x2018: "'", 0x2019: "'", 0x201C: '"', 0x201D: '"', 0x2026: '~',
    0x2190: '<', 0x2192: '>', 0x2191: '^', 0x2193: 'v', 0x25B6: '>',
    0x25C0: '<', 0x2713: 'v', 0x2717: 'x', 0x00AB: '<', 0x00BB: '>',
  };
  return near[codePoint] ?? '?';
}

/// One row as the glasses take it: [text] and an attribute byte a cell.
class GlassesRow {
  GlassesRow(this.text, this.attrs);

  final String text;
  final Uint8List attrs;

  /// Nothing to draw: blanks with no background.
  bool get blank =>
      text.trim().isEmpty && attrs.every((a) => a >> 4 == FramePalette.none);

  @override
  bool operator ==(Object other) =>
      other is GlassesRow &&
      other.text == text &&
      _sameBytes(other.attrs, attrs);

  @override
  int get hashCode => Object.hash(text, Object.hashAll(attrs));

  @override
  String toString() => 'GlassesRow($text)';
}

bool _sameBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// The cell's attribute byte: text in the low nibble, background in the
/// high. Inverse (the cursor too) puts the text's color behind, and dark
/// text on it where there was no background.
int _attr(int fg, int bg, int flags, {bool cursor = false}) {
  var text = _frameColor(fg, background: false) ?? FramePalette.white;
  var back = _frameColor(bg, background: true) ?? FramePalette.none;
  final inverse = (flags & CellAttr.inverse != 0) != cursor;
  if (inverse) {
    final behind = text;
    text = back == FramePalette.none ? _darkText : back;
    back = behind;
  }
  if (flags & CellAttr.invisible != 0) {
    text = back == FramePalette.none ? _darkText : back;
  }
  return back << 4 | text;
}

/// The terminal's visible screen as the glasses' rows, the cursor drawn in
/// as an inverted cell when it shows.
List<GlassesRow> glassesRows(Terminal terminal) {
  final buffer = terminal.buffer;
  final top = buffer.height - terminal.viewHeight;
  final cursorShown = terminal.cursorVisibleMode;
  final rows = <GlassesRow>[];
  for (var y = 0; y < terminal.viewHeight && y < termRows; y++) {
    final line = buffer.lines[top + y];
    final text = StringBuffer();
    final attrs = Uint8List(termCols);
    var skip = false;
    for (var x = 0; x < termCols; x++) {
      final inLine = x < line.length;
      final cursor = cursorShown && y == buffer.cursorY && x == buffer.cursorX;
      final fg = inLine ? line.getForeground(x) : 0;
      final bg = inLine ? line.getBackground(x) : 0;
      final flags = inLine ? line.getAttributes(x) : 0;
      var a = _attr(fg, bg, flags, cursor: cursor);
      String? c;
      if (skip) {
        c = ' '; // the second half of a wide character
        skip = false;
      } else {
        final cp = inLine ? line.getCodePoint(x) : 0;
        c = glassesChar(cp);
        if (inLine && line.getWidth(x) == 2) skip = true;
      }
      if (c == null) {
        // a full block: the text's color lit behind a blank
        final lit = a & 0x0F;
        a = lit << 4 | lit;
        c = ' ';
      }
      text.write(c);
      attrs[x] = a;
    }
    rows.add(GlassesRow(text.toString(), attrs));
  }
  while (rows.length < termRows) {
    rows.add(
      GlassesRow(
        ' ' * termCols,
        Uint8List(termCols)..fillRange(0, termCols, 1),
      ),
    );
  }
  return rows;
}

/// A row on the wire: n, the characters, an attribute byte each. Trailing
/// blanks with no background are left off.
List<int> encodeRow(GlassesRow row) {
  var n = row.text.length;
  while (n > 0 &&
      row.text.codeUnitAt(n - 1) == 0x20 &&
      row.attrs[n - 1] >> 4 == FramePalette.none) {
    n--;
  }
  return [n, ...row.text.codeUnits.take(n), ...row.attrs.take(n)];
}

/// The frame for apps/term/term.lua, its remote() 'f': seq, flags (bit 0:
/// the wearer typed since the last), a 16-bit mask of the rows that differ
/// from [shown] (row 1 the high bit), then those rows. Null when nothing
/// changed and nothing was typed. [shown] null: every row.
List<int>? termFrame(
  List<GlassesRow> latest,
  List<GlassesRow>? shown,
  int seq, {
  bool typed = false,
}) {
  var mask = 0;
  final body = <int>[];
  for (var r = 0; r < latest.length && r < 16; r++) {
    if (shown != null && r < shown.length && shown[r] == latest[r]) continue;
    mask |= 0x8000 >> r;
    body.addAll(encodeRow(latest[r]));
  }
  if (mask == 0 && !typed) return null;
  return [
    0x66, // 'f'
    seq & 0xFF,
    typed ? 1 : 0,
    mask >> 8,
    mask & 0xFF,
    ...body,
  ];
}
