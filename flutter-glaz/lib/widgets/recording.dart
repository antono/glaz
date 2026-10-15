import 'dart:async';

import 'package:flutter/material.dart';

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
