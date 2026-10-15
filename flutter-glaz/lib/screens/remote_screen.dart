import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../frame/link.dart';
import '../services/services.dart';
import '../settings.dart';
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
        const SizedBox(height: 28),
        _PhotoCard(link: link, enabled: on),
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

/// A photo from the glasses' camera, with the two settings that matter:
/// size and quality. They are Camera's own settings (Menu > Camera), so the
/// two stay in step; the photo lands in Photos with the others.
class _PhotoCard extends StatefulWidget {
  const _PhotoCard({required this.link, required this.enabled});
  final FrameLink link;
  final bool enabled;

  @override
  State<_PhotoCard> createState() => _PhotoCardState();
}

class _PhotoCardState extends State<_PhotoCard> {
  static const _sizes = [('256', 'S'), ('512', 'M'), ('720', 'L')];
  static const _qualities = [
    ('LOW', 'Low'),
    ('MEDIUM', 'Mid'),
    ('HIGH', 'High'),
  ];
  static const _qualityIndex = {
    'VERY_LOW': 1,
    'LOW': 2,
    'MEDIUM': 3,
    'HIGH': 4,
    'VERY_HIGH': 5,
  };

  int _received = 0;
  bool _waiting = false;

  @override
  void initState() {
    super.initState();
    final photos = Services.instance.photos;
    _received = photos.received;
    photos.addListener(_onPhoto);
  }

  @override
  void dispose() {
    Services.instance.photos.removeListener(_onPhoto);
    super.dispose();
  }

  void _onPhoto() {
    final n = Services.instance.photos.received;
    if (n == _received) return;
    _received = n;
    if (_waiting && mounted) {
      setState(() => _waiting = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Saved to Photos')));
    }
  }

  Future<void> _shoot(Settings settings) async {
    HapticFeedback.mediumImpact();
    final size = int.parse(settings.config('photo', 'resolution') ?? '512');
    final quality =
        _qualityIndex[settings.config('photo', 'quality') ?? 'MEDIUM'] ?? 3;
    setState(() => _waiting = true);
    await widget.link.remotePhoto(size, quality);
    // the glasses take about 1.5 s to expose, then a few to send
    Future.delayed(const Duration(seconds: 20), () {
      if (mounted && _waiting) setState(() => _waiting = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final settings = Services.instance.settings;
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final size = settings.config('photo', 'resolution') ?? '512';
        final quality = settings.config('photo', 'quality') ?? 'MEDIUM';
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Photo', style: text.titleMedium),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const SizedBox(width: 56, child: Text('Size')),
                    Expanded(
                      child: SegmentedButton<String>(
                        showSelectedIcon: false,
                        segments: [
                          for (final (v, l) in _sizes)
                            ButtonSegment(value: v, label: Text(l)),
                        ],
                        selected: {size},
                        onSelectionChanged: (s) =>
                            settings.setConfig('photo', 'resolution', s.first),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const SizedBox(width: 56, child: Text('Quality')),
                    Expanded(
                      child: SegmentedButton<String>(
                        showSelectedIcon: false,
                        segments: [
                          for (final (v, l) in _qualities)
                            ButtonSegment(value: v, label: Text(l)),
                        ],
                        // Very low and very high, set in Menu > Camera,
                        // show no segment as selected
                        selected: {quality},
                        emptySelectionAllowed: true,
                        onSelectionChanged: (s) {
                          if (s.isNotEmpty) {
                            settings.setConfig('photo', 'quality', s.first);
                          }
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: widget.enabled && !_waiting
                      ? () => _shoot(settings)
                      : null,
                  icon: _waiting
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.photo_camera),
                  label: Text(_waiting ? 'Taking...' : 'Take a photo'),
                ),
                const SizedBox(height: 6),
                Text(
                  'Saved in Photos with the others. The Photos service '
                  '(More > Services) must be on.',
                  style: text.bodySmall?.copyWith(color: FrameColors.grey),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
