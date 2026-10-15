import 'dart:math' as math;
import 'dart:ui';

/// The glaz eye, drawn the way tool/logo.py draws its 'bloodshot' variant,
/// so it can move: the pupil can widen and the veins can shift. At rest
/// ([pupilR] 2.6, veins untouched) it is pixel for pixel assets/logo/logo.png
/// (test/eye_art_test.dart checks).
///
/// Returns a 32x32 grid, row by row; null is transparent.
List<List<Color?>> eyePixels({
  double pupilR = restPupil,
  List<List<math.Point<int>>> veins = restVeins,
}) {
  const n = 32;
  const halfW = 14.5, halfH = 10.5, irisR = 7.2;
  final grid = List.generate(n, (_) => List<Color?>.filled(n, null));
  void set(int x, int y, Color c) {
    if (x >= 0 && x < n && y >= 0 && y < n) grid[y][x] = c;
  }

  const c = (n - 1) / 2;
  const r = (halfW * halfW + halfH * halfH) / (2 * halfH);
  bool inside(int x, int y) =>
      _hypot(x - c, y - (c + (r - halfH))) <= r &&
      _hypot(x - c, y - (c - (r - halfH))) <= r;

  final sclera = <int>{
    for (var y = 0; y < n; y++)
      for (var x = 0; x < n; x++)
        if (inside(x, y)) y * n + x,
  };
  bool inSclera(int x, int y) =>
      x >= 0 && x < n && y >= 0 && y < n && sclera.contains(y * n + x);

  // outline: pixels next to the sclera (8-neighbourhood) but outside it
  for (final p in sclera) {
    final x = p % n, y = p ~/ n;
    for (var dx = -1; dx <= 1; dx++) {
      for (var dy = -1; dy <= 1; dy++) {
        if (!inSclera(x + dx, y + dy)) set(x + dx, y + dy, _outline);
      }
    }
  }
  // the white, a shadow row under the upper lid
  final top = <int, int>{};
  for (final p in sclera) {
    final x = p % n, y = p ~/ n;
    top[x] = math.min(top[x] ?? y, y);
  }
  for (final p in sclera) {
    final x = p % n, y = p ~/ n;
    set(x, y, y - top[x]! < 1 ? _shade : _sclera);
  }
  // veins, clipped to the white
  for (final path in veins) {
    for (var i = 0; i < path.length - 1; i++) {
      for (final p in _line(path[i], path[i + 1])) {
        if (inSclera(p.x, p.y)) set(p.x, p.y, i == 0 ? _veinDark : _vein);
      }
    }
  }
  // iris, pupil, highlight
  const ix = c, iy = c;
  for (final p in sclera) {
    final x = p % n, y = p ~/ n;
    final d = _hypot(x - ix, y - iy);
    if (d > irisR) continue;
    final Color col;
    if (d > irisR - 1.2) {
      col = _irisEdge;
    } else if (d <= pupilR + 0.4) {
      col = _pupil;
    } else if (d <= pupilR + 1.6) {
      col = _irisIn;
    } else {
      final a = math.atan2(y - iy, x - ix);
      col = ((a + math.pi) / (math.pi / 6)).floor() % 2 == 1 ? _iris : _irisAlt;
    }
    set(x, y, col);
  }
  final hx = _round(ix - pupilR * 0.9), hy = _round(iy - pupilR * 0.9);
  for (final (x, y) in [
    (hx, hy),
    (hx - 1, hy),
    (hx, hy - 1),
    (hx - 1, hy - 1),
  ]) {
    if (inSclera(x, y)) set(x, y, _glint);
  }
  set(_round(ix + pupilR), _round(iy + pupilR - 1), _glint);
  return grid;
}

const restPupil = 2.6;

/// tool/logo.py veins_for(32): from the corners, then from the lids.
const restVeins = <List<math.Point<int>>>[
  [
    math.Point(3, 16),
    math.Point(7, 15),
    math.Point(10, 13),
    math.Point(11, 10),
  ],
  [math.Point(7, 15), math.Point(9, 18), math.Point(8, 21)],
  [math.Point(4, 17), math.Point(8, 19), math.Point(10, 22)],
  [math.Point(5, 14), math.Point(7, 11), math.Point(9, 9)],
  [
    math.Point(28, 16),
    math.Point(24, 17),
    math.Point(22, 20),
    math.Point(22, 23),
  ],
  [math.Point(24, 17), math.Point(23, 13), math.Point(24, 10)],
  [math.Point(27, 15), math.Point(24, 13), math.Point(21, 9)],
  [math.Point(27, 17), math.Point(25, 20), math.Point(26, 21)],
  [math.Point(15, 6), math.Point(14, 8), math.Point(12, 8)],
  [math.Point(18, 26), math.Point(19, 24), math.Point(21, 24)],
  [math.Point(12, 25), math.Point(11, 23)],
];

/// The veins at a moment of a twitch: every point but each vein's root
/// moves by up to [amount] pixels, differently per point and per [step].
List<List<math.Point<int>>> twitchVeins(double amount, int step) => [
  for (var v = 0; v < restVeins.length; v++)
    [
      for (var i = 0; i < restVeins[v].length; i++)
        i == 0
            ? restVeins[v][i]
            : math.Point(
                restVeins[v][i].x + _jitter(v, i, step, 0, amount),
                restVeins[v][i].y + _jitter(v, i, step, 1, amount),
              ),
    ],
];

int _jitter(int v, int i, int step, int axis, double amount) {
  // a fixed pseudo-random value per point, axis and step: no Random state
  final h = math.sin(v * 12.9898 + i * 78.233 + step * 37.719 + axis * 4.581);
  final f = ((h * 43758.5453) % 1) * 2 - 1; // -1..1
  return (f * amount).round();
}

const _outline = Color.fromARGB(255, 24, 8, 12);
const _sclera = Color.fromARGB(255, 250, 244, 236);
const _shade = Color.fromARGB(255, 214, 196, 192);
const _veinDark = Color.fromARGB(255, 140, 18, 30);
const _vein = Color.fromARGB(255, 190, 38, 51);
const _irisEdge = Color.fromARGB(255, 24, 60, 10);
const _iris = Color.fromARGB(255, 68, 137, 26);
const _irisAlt = Color.fromARGB(255, 163, 206, 39);
const _irisIn = Color.fromARGB(255, 120, 170, 30);
const _pupil = Color.fromARGB(255, 8, 8, 8);
const _glint = Color.fromARGB(255, 255, 255, 255);

double _hypot(double a, double b) => math.sqrt(a * a + b * b);

/// Python's round(): halves go to the even neighbour.
int _round(double v) {
  final f = v.floorToDouble();
  final diff = v - f;
  if (diff > 0.5) return f.toInt() + 1;
  if (diff < 0.5) return f.toInt();
  return f.toInt().isEven ? f.toInt() : f.toInt() + 1;
}

/// Bresenham, as tool/logo.py line(): the points from a to b.
List<math.Point<int>> _line(math.Point<int> a, math.Point<int> b) {
  var x0 = a.x, y0 = a.y;
  final x1 = b.x, y1 = b.y;
  final dx = (x1 - x0).abs(), dy = -(y1 - y0).abs();
  final sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1;
  var err = dx + dy;
  final pts = <math.Point<int>>[];
  while (true) {
    pts.add(math.Point(x0, y0));
    if (x0 == x1 && y0 == y1) return pts;
    final e2 = 2 * err;
    if (e2 >= dy) {
      err += dy;
      x0 += sx;
    }
    if (e2 <= dx) {
      err += dx;
      y0 += sy;
    }
  }
}
