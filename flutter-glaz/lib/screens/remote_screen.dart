import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../frame/link.dart';
import '../services/services.dart';
import '../theme.dart';

/// A remote for the glasses: what the wearer does with taps and tilts,
/// from the phone. The glasses take it as the same gestures, so the menu
/// and the apps behave exactly as they do on the head.
class RemoteScreen extends StatelessWidget {
  const RemoteScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final link = Services.instance.link;
    return ListenableBuilder(
      listenable: link,
      builder: (context, _) => _build(context, link),
    );
  }

  Widget _build(BuildContext context, FrameLink link) {
    final text = Theme.of(context).textTheme;
    final on = link.connected && !link.busy;
    void press(Future<void> Function() action) {
      HapticFeedback.selectionClick();
      action();
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        Text(
          on
              ? 'Tilt and tap on the glasses, from here.'
              : 'Connect to the glasses first (Glasses tab).',
          textAlign: TextAlign.center,
          style: text.bodyMedium?.copyWith(color: FrameColors.grey),
        ),
        const SizedBox(height: 24),
        Center(
          child: _Pad(
            enabled: on,
            onPrevious: () => press(() => link.remoteTilt(next: false)),
            onNext: () => press(() => link.remoteTilt(next: true)),
            onSelect: () => press(() => link.remoteTaps(1)),
          ),
        ),
        const SizedBox(height: 28),
        Row(
          children: [
            Expanded(
              child: _GestureButton(
                icon: Icons.undo,
                label: 'Back',
                hint: '2 taps',
                onPressed: on ? () => press(() => link.remoteTaps(2)) : null,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _GestureButton(
                icon: Icons.menu,
                label: 'Menu',
                hint: '3 taps',
                onPressed: on ? () => press(() => link.remoteTaps(3)) : null,
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        Text(
          'Up and left go back one item, down and right forward one -- the '
          'glasses scroll by tilting toward a shoulder, one axis. OK is a '
          'single tap: select, or bring back the last app.',
          textAlign: TextAlign.center,
          style: text.bodySmall?.copyWith(color: FrameColors.grey),
        ),
      ],
    );
  }
}

/// A round pad: four arrows round an OK button.
class _Pad extends StatelessWidget {
  const _Pad({
    required this.enabled,
    required this.onPrevious,
    required this.onNext,
    required this.onSelect,
  });

  final bool enabled;
  final VoidCallback onPrevious, onNext, onSelect;

  @override
  Widget build(BuildContext context) {
    const size = 260.0;
    final color = enabled ? FrameColors.skyBlue : FrameColors.outline;
    Widget arrow(IconData icon, VoidCallback onTap, Alignment at, String tip) =>
        Align(
          alignment: at,
          child: IconButton(
            iconSize: 56,
            tooltip: tip,
            color: color,
            onPressed: enabled ? onTap : null,
            icon: Icon(icon),
          ),
        );
    return SizedBox.square(
      dimension: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: FrameColors.surface,
          border: Border.all(color: FrameColors.outline, width: 2),
        ),
        child: Stack(
          children: [
            arrow(
              Icons.keyboard_arrow_up,
              onPrevious,
              Alignment.topCenter,
              'Previous',
            ),
            arrow(
              Icons.keyboard_arrow_left,
              onPrevious,
              Alignment.centerLeft,
              'Previous',
            ),
            arrow(
              Icons.keyboard_arrow_right,
              onNext,
              Alignment.centerRight,
              'Next',
            ),
            arrow(
              Icons.keyboard_arrow_down,
              onNext,
              Alignment.bottomCenter,
              'Next',
            ),
            Center(
              child: SizedBox.square(
                dimension: 96,
                child: FilledButton(
                  style: FilledButton.styleFrom(shape: const CircleBorder()),
                  onPressed: enabled ? onSelect : null,
                  child: const Text(
                    'OK',
                    style: TextStyle(
                      fontFamily: monoFamily,
                      fontWeight: FontWeight.bold,
                      fontSize: 20,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GestureButton extends StatelessWidget {
  const _GestureButton({
    required this.icon,
    required this.label,
    required this.hint,
    required this.onPressed,
  });

  final IconData icon;
  final String label, hint;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => OutlinedButton(
    style: OutlinedButton.styleFrom(
      padding: const EdgeInsets.symmetric(vertical: 16),
    ),
    onPressed: onPressed,
    child: Column(
      children: [
        Icon(icon),
        const SizedBox(height: 4),
        Text(label),
        Text(
          hint,
          style: Theme.of(context).textTheme.labelSmall
              ?.copyWith(color: FrameColors.grey),
        ),
      ],
    ),
  );
}
