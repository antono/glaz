import 'dart:async';

import 'package:flutter/material.dart';

/// The glaz eye, drawn with hard pixel edges. It blinks now and then.
///
/// The art comes from tool/logo.py; scaling uses FilterQuality.none so the
/// pixels stay square at any size.
class PixelLogo extends StatefulWidget {
  const PixelLogo({super.key, this.size = 160, this.blink = true});

  final double size;
  final bool blink;

  @override
  State<PixelLogo> createState() => _PixelLogoState();
}

class _PixelLogoState extends State<PixelLogo>
    with SingleTickerProviderStateMixin {
  static const _period = Duration(seconds: 5);

  late final _lid = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
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
    if (!mounted) return;
    await _lid.forward(from: 0);
    if (mounted) await _lid.reverse();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _lid.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = Image.asset(
      'assets/logo/logo.png',
      width: widget.size,
      height: widget.size,
      filterQuality: FilterQuality.none,
      semanticLabel: 'glaz logo: a wide-open eye',
    );
    return GestureDetector(
      onTap: _blinkOnce,
      child: AnimatedBuilder(
        animation: _lid,
        builder: (context, child) => Transform.scale(
          scaleY: 1 - 0.9 * Curves.easeIn.transform(_lid.value),
          child: child,
        ),
        child: image,
      ),
    );
  }
}
