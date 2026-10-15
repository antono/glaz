import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:glaz/widgets/eye_art.dart';

void main() {
  test('at rest the eye is assets/logo/logo.png, pixel for pixel', () {
    final png = img.decodePng(File('assets/logo/logo.png').readAsBytesSync())!;
    final cell = png.width ~/ 32; // tool/logo.py renders 32 cells at 512 px
    final grid = eyePixels();
    for (var y = 0; y < 32; y++) {
      for (var x = 0; x < 32; x++) {
        final p = png.getPixel(x * cell + cell ~/ 2, y * cell + cell ~/ 2);
        final want = p.a == 0 ? null : (p.r.toInt(), p.g.toInt(), p.b.toInt());
        final c = grid[y][x];
        final got = c == null
            ? null
            : ((c.r * 255).round(), (c.g * 255).round(), (c.b * 255).round());
        expect(got, want, reason: 'pixel ($x, $y)');
      }
    }
  });

  test('a twitch widens the pupil and moves the veins, roots stay', () {
    int dark(List<List<dynamic>> g) =>
        g.expand((r) => r).where((c) => c == eyePixels()[15][15]).length;
    expect(dark(eyePixels(pupilR: 3.5)), greaterThan(dark(eyePixels())));

    final moved = twitchVeins(1.4, 3);
    expect(moved, isNot(equals(restVeins)));
    for (var v = 0; v < restVeins.length; v++) {
      expect(moved[v].first, restVeins[v].first);
    }
    expect(twitchVeins(0, 3), restVeins);
  });
}
