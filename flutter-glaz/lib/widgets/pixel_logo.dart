import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'eye_art.dart';

/// The glaz eye, drawn pixel by pixel (eye_art.dart, the same art as
/// tool/logo.py's logo). It blinks now and then; a tap makes it twitch: the
/// pupil widens a little and the veins crawl, then it settles.
class PixelLogo extends StatefulWidget {
  const PixelLogo({super.key, this.size = 160, this.blink = true});

  final double size;
  final bool blink;

  @override
  State<PixelLogo> createState() => _PixelLogoState();
}

class _PixelLogoState extends State<PixelLogo> with TickerProviderStateMixin {
  static const _period = Duration(seconds: 5);

  /// How far the pupil widens at the height of a twitch, in art pixels.
  static const _dilate = 0.9;

  /// How far a vein point strays, in art pixels.
  static const _crawl = 1.4;

  /// The veins take a new shape this many times during a twitch.
  static const _steps = 6;

  late final _lid = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  );
  late final _twitch = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    if (widget.blink) {
      _timer = Timer.periodic(_period, (_) => _blinkOnce());
    }
  }

  Future<void> _blinkOnce() async {
    if (!mounted || _twitch.isAnimating) return;
    await _lid.forward(from: 0);
    if (mounted) await _lid.reverse();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _lid.dispose();
    _twitch.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'glaz logo: a wide-open eye',
      image: true,
      child: GestureDetector(
        onTap: () => _twitch.forward(from: 0),
        child: AnimatedBuilder(
          animation: Listenable.merge([_lid, _twitch]),
          builder: (context, _) {
            final t = _twitch.value;
            // up and back down: 0 at rest, 1 halfway through
            final swell = math.sin(math.pi * t);
            final pixels = t == 0
                ? eyePixels()
                : eyePixels(
                    pupilR: restPupil + _dilate * swell,
                    veins: twitchVeins(_crawl * swell, (t * _steps).floor()),
                  );
            return Transform.scale(
              scaleY: 1 - 0.9 * Curves.easeIn.transform(_lid.value),
              child: CustomPaint(
                size: Size.square(widget.size),
                painter: _EyePainter(pixels),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _EyePainter extends CustomPainter {
  _EyePainter(this.pixels);
  final List<List<Color?>> pixels;

  @override
  void paint(Canvas canvas, Size size) {
    final cell = size.width / pixels.length;
    final paint = Paint()..isAntiAlias = false;
    for (var y = 0; y < pixels.length; y++) {
      for (var x = 0; x < pixels[y].length; x++) {
        final c = pixels[y][x];
        if (c == null) continue;
        paint.color = c;
        // a hair wider than the cell, so no seams show between pixels
        canvas.drawRect(
          Rect.fromLTWH(x * cell, y * cell, cell + 0.5, cell + 0.5),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_EyePainter old) => old.pixels != pixels;
}
