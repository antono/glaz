import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/recordings.dart';
import '../services/services.dart';
import '../theme.dart';

/// How long the glasses have been recording, 'm:ss', counting every second;
/// '0:00' when they are not.
class RecordingClock extends StatefulWidget {
  const RecordingClock(this.recorder, {super.key, this.style});
  final RecorderService recorder;
  final TextStyle? style;

  static String format(Duration d) =>
      '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  State<RecordingClock> createState() => _RecordingClockState();
}

class _RecordingClockState extends State<RecordingClock> {
  late final Timer _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final started = widget.recorder.started;
    final d = started == null
        ? Duration.zero
        : DateTime.now().difference(started);
    return Text(RecordingClock.format(d), style: widget.style);
  }
}

/// While the glasses record, a red strip above every screen of the app --
/// tabs and pages pushed over them alike -- with the time; a tap stops it.
/// Put round the navigator (MaterialApp.builder).
class RecordingBanner extends StatelessWidget {
  const RecordingBanner({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final services = Services.instance;
    final recorder = services.recorder;
    return ListenableBuilder(
      listenable: recorder,
      builder: (context, _) {
        if (!recorder.recording) return child;
        final style = Theme.of(context).textTheme.labelLarge
            ?.copyWith(color: FrameColors.white, fontFamily: monoFamily);
        return Column(
          children: [
            Material(
              color: FrameColors.red,
              child: InkWell(
                onTap: () => services.link.remoteRecord(false),
                child: SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 6,
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.fiber_manual_record,
                          size: 14,
                          color: FrameColors.white,
                        ),
                        const SizedBox(width: 8),
                        Text('REC', style: style),
                        const SizedBox(width: 8),
                        RecordingClock(recorder, style: style),
                        const Spacer(),
                        Text('STOP', style: style),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: MediaQuery.removePadding(
                context: context,
                removeTop: true,
                child: child,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Recorder's quality: its 'bits' setting, as Menu > Recorder has it
/// (glasses_menu.dart); the rate is fixed at 8 kHz, all the link carries.
const recordQualities = [('8', 'Speech'), ('16', 'Better')];

String recordQuality(Services s) {
  final bits = s.settings.config('recorder', 'bits') ?? '8';
  return recordQualities
      .firstWhere((q) => q.$1 == bits, orElse: () => (bits, '$bits bit'))
      .$2;
}

/// The record button with its settings next to it: what Remote and Voice
/// show.
class RecordRow extends StatelessWidget {
  const RecordRow({super.key});

  @override
  Widget build(BuildContext context) => Row(
    children: [
      const Expanded(child: RecordButton()),
      const SizedBox(width: 8),
      IconButton.filledTonal(
        tooltip: 'Recording settings',
        onPressed: () => showRecordSettings(context),
        icon: const Icon(Icons.tune),
      ),
    ],
  );
}

/// Recording settings, as a sheet from below: the quality, and whether the
/// phone keeps recordings at all (the Recordings service).
Future<void> showRecordSettings(BuildContext context) {
  final settings = Services.instance.settings;
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final text = Theme.of(context).textTheme;
        final bits = settings.config('recorder', 'bits') ?? '8';
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Recording', style: text.titleMedium),
              const SizedBox(height: 12),
              Row(
                children: [
                  const SizedBox(width: 64, child: Text('Quality')),
                  Expanded(
                    child: SegmentedButton<String>(
                      showSelectedIcon: false,
                      segments: [
                        for (final (v, l) in recordQualities)
                          ButtonSegment(value: v, label: Text(l)),
                      ],
                      selected: {bits},
                      emptySelectionAllowed: true,
                      onSelectionChanged: (s) {
                        if (s.isNotEmpty) {
                          settings.setConfig('recorder', 'bits', s.first);
                        }
                      },
                    ),
                  ),
                ],
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Save on the phone'),
                value: settings.serviceOn('recordings'),
                onChanged: (on) => settings.setService('recordings', on),
              ),
              Text(
                '8 kHz mono. Speech is 8 bit; Better is 16 bit and sends '
                'twice as much -- on a busy link some is lost. Shared with '
                'Menu > Recorder. Recordings land in Voice.',
                style: text.bodySmall?.copyWith(color: FrameColors.grey),
              ),
            ],
          ),
        );
      },
    ),
  );
}

/// Start and stop Recorder on the glasses. Red while they record, with the
/// time; the state is the glasses' own, read from what they send, so it is
/// right however the recording was started or ended.
class RecordButton extends StatefulWidget {
  const RecordButton({super.key});

  @override
  State<RecordButton> createState() => _RecordButtonState();
}

class _RecordButtonState extends State<RecordButton> {
  /// Asked, and the glasses have not answered yet.
  bool _asked = false;
  Timer? _giveUp;

  @override
  void initState() {
    super.initState();
    Services.instance.recorder.addListener(_changed);
  }

  @override
  void dispose() {
    _giveUp?.cancel();
    Services.instance.recorder.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    _giveUp?.cancel();
    if (mounted) setState(() => _asked = false);
  }

  void _press(bool on) {
    HapticFeedback.mediumImpact();
    setState(() => _asked = true);
    Services.instance.link.remoteRecord(on);
    // no answer: Recorder could not start (no microphone, a bad link)
    _giveUp?.cancel();
    _giveUp = Timer(const Duration(seconds: 5), _changed);
  }

  @override
  Widget build(BuildContext context) {
    final services = Services.instance;
    return ListenableBuilder(
      // the glasses connected, a setting changed
      listenable: Listenable.merge([services.link, services.settings]),
      builder: (context, _) => _build(services),
    );
  }

  Widget _build(Services services) {
    final recorder = services.recorder;
    final link = services.link;
    final saving = services.settings.serviceOn('recordings');
    final enabled = link.connected && !link.busy && saving && !_asked;
    const padding = EdgeInsets.symmetric(vertical: 14, horizontal: 16);
    if (recorder.recording) {
      return FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: FrameColors.red,
          foregroundColor: FrameColors.white,
          padding: padding,
        ),
        onPressed: enabled ? () => _press(false) : null,
        icon: const Icon(Icons.stop),
        label: Row(
          mainAxisSize: MainAxisSize.min,
          children: [const Text('Stop  ·  '), RecordingClock(recorder)],
        ),
      );
    }
    final why = !saving
        ? 'Saving recordings is off (settings)'
        : link.connected
        ? 'Record on the glasses'
        : 'Connect to the glasses first';
    return Tooltip(
      message: why,
      child: OutlinedButton.icon(
        style: OutlinedButton.styleFrom(padding: padding),
        onPressed: enabled ? () => _press(true) : null,
        icon: Icon(
          Icons.fiber_manual_record,
          color: enabled ? FrameColors.red : null,
        ),
        label: Text('Record  ·  ${recordQuality(services)}'),
      ),
    );
  }
}
