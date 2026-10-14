import 'package:flutter/material.dart';

import '../theme.dart';
import '../widgets/pixel_logo.dart';

/// The first tab: the glasses' status and how to drive them.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
      children: [
        const Center(child: PixelLogo()),
        const SizedBox(height: 12),
        Center(child: Text('[ glaz ]', style: text.headlineMedium)),
        const SizedBox(height: 4),
        Center(
          child: Text(
            'companion for Frame glasses',
            style: text.bodyMedium?.copyWith(color: FrameColors.grey),
          ),
        ),
        const SizedBox(height: 28),
        const _ConnectionCard(),
        const SizedBox(height: 16),
        const _GesturesCard(),
      ],
    );
  }
}

class _ConnectionCard extends StatelessWidget {
  const _ConnectionCard();

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.bluetooth_disabled, color: FrameColors.grey),
                const SizedBox(width: 12),
                Expanded(child: Text('Not connected', style: text.titleMedium)),
                const _StatusDot(color: FrameColors.grey),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'Connecting over Bluetooth comes in the next version. Until '
              'then the glasses work on their own: the menu, the camera and '
              'the sensors all run on the glasses themselves.',
              style: text.bodyMedium?.copyWith(color: FrameColors.grey),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: null,
                icon: const Icon(Icons.bluetooth_searching),
                label: const Text('Connect'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      );
}

/// Frame has no buttons: everything is a tap on the arm or a head tilt.
class _GesturesCard extends StatelessWidget {
  const _GesturesCard();

  static const _gestures = [
    (Icons.looks_one_outlined, '1 tap', 'select, or open the last app'),
    (Icons.looks_two_outlined, '2 taps', 'back, one level up'),
    (Icons.looks_3_outlined, '3 taps', 'show or hide the menu'),
    (Icons.swap_horiz, 'tilt head', 'toward a shoulder to scroll'),
  ];

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text('On the glasses', style: text.titleMedium),
            ),
            for (final (icon, gesture, meaning) in _gestures)
              ListTile(
                dense: true,
                leading: Icon(icon, color: FrameColors.skyBlue),
                title: Text(
                  gesture,
                  style: text.bodyLarge?.copyWith(fontFamily: monoFamily),
                ),
                subtitle: Text(meaning),
              ),
          ],
        ),
      ),
    );
  }
}
