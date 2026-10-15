import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../services/recordings.dart';
import '../services/services.dart';
import 'photos_screen.dart' show dayLabel;

String _clock(Duration d) {
  final s = d.inSeconds;
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

String _two(int n) => n.toString().padLeft(2, '0');

/// Recordings from the glasses' Recorder, newest first, by day; tap one to
/// play it.
class RecordingsScreen extends StatefulWidget {
  const RecordingsScreen({super.key});

  @override
  State<RecordingsScreen> createState() => _RecordingsScreenState();
}

class _RecordingsScreenState extends State<RecordingsScreen> {
  AudioPlayer? _player;
  final _subs = <StreamSubscription<Object?>>[];
  String? _playing; // path of the recording loaded in the player
  PlayerState _state = PlayerState.stopped;
  Duration _position = Duration.zero;

  AudioPlayer get player {
    if (_player != null) return _player!;
    final p = _player = AudioPlayer();
    _subs.addAll([
      p.onPlayerStateChanged.listen((s) => _set(() => _state = s)),
      p.onPositionChanged.listen((d) => _set(() => _position = d)),
      p.onPlayerComplete.listen(
        (_) => _set(() {
          _state = PlayerState.completed;
          _position = Duration.zero;
        }),
      ),
    ]);
    return p;
  }

  void _set(VoidCallback f) {
    if (mounted) setState(f);
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _player?.dispose();
    super.dispose();
  }

  Future<void> _toggle(Recording r) async {
    if (_playing == r.file.path && _state == PlayerState.playing) {
      await player.pause();
    } else if (_playing == r.file.path && _state == PlayerState.paused) {
      await player.resume();
    } else {
      setState(() {
        _playing = r.file.path;
        _position = Duration.zero;
      });
      await player.play(DeviceFileSource(r.file.path));
    }
  }

  Future<void> _delete(Recording r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete recording?'),
        content: Text(recordingName(r.at)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (_playing == r.file.path) {
      await player.stop();
      _playing = null;
    }
    await Services.instance.recorder.store.delete(r);
  }

  @override
  Widget build(BuildContext context) {
    final recorder = Services.instance.recorder;
    return ListenableBuilder(
      listenable: Listenable.merge([recorder, recorder.store]),
      builder: (context, _) => FutureBuilder<List<Recording>>(
        future: recorder.store.list(),
        builder: (context, snap) {
          final all = snap.data;
          if (all == null) return const SizedBox.shrink();
          final now = DateTime.now();
          final children = <Widget>[];
          if (recorder.recording) children.add(const _Live());
          DateTime? day;
          for (final r in all) {
            // the one coming in now is still being written
            if (recorder.recording &&
                recorder.started != null &&
                r.at.difference(recorder.started!).inSeconds.abs() < 2) {
              continue;
            }
            final d = DateTime(r.at.year, r.at.month, r.at.day);
            if (d != day) {
              day = d;
              children.add(_DayHeader(dayLabel(d, now)));
            }
            children.add(_tile(context, r));
          }
          if (all.isEmpty && !recorder.recording) {
            children.add(const _Empty());
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            children: children,
          );
        },
      ),
    );
  }

  Widget _tile(BuildContext context, Recording r) {
    final scheme = Theme.of(context).colorScheme;
    final current = _playing == r.file.path;
    final playing = current && _state == PlayerState.playing;
    final total = r.length.inMilliseconds;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Column(
        children: [
          ListTile(
            leading: IconButton.filledTonal(
              tooltip: playing ? 'Pause' : 'Play',
              icon: Icon(playing ? Icons.pause : Icons.play_arrow),
              onPressed: () => _toggle(r),
            ),
            title: Text(
              '${_two(r.at.hour)}:${_two(r.at.minute)}:${_two(r.at.second)}',
            ),
            subtitle: Text(
              current && _state != PlayerState.stopped
                  ? '${_clock(_position)} / ${_clock(r.length)}'
                  : _clock(r.length),
            ),
            trailing: IconButton(
              tooltip: 'Delete',
              icon: Icon(Icons.delete_outline, color: scheme.onSurfaceVariant),
              onPressed: () => _delete(r),
            ),
            onTap: () => _toggle(r),
          ),
          if (current && total > 0 && _state != PlayerState.stopped)
            Slider(
              value: _position.inMilliseconds.clamp(0, total).toDouble(),
              max: total.toDouble(),
              onChanged: (v) => player.seek(Duration(milliseconds: v.round())),
            ),
        ],
      ),
    );
  }
}

class _DayHeader extends StatelessWidget {
  const _DayHeader(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
      child: Text(
        label,
        style: Theme.of(context).textTheme.titleSmall
            ?.copyWith(color: scheme.primary),
      ),
    );
  }
}

/// Shown while the glasses are recording.
class _Live extends StatefulWidget {
  const _Live();

  @override
  State<_Live> createState() => _LiveState();
}

class _LiveState extends State<_Live> {
  late final Timer _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final started = Services.instance.recorder.started;
    final d = started == null
        ? Duration.zero
        : DateTime.now().difference(started);
    return Card(
      margin: const EdgeInsets.only(top: 16),
      color: scheme.errorContainer,
      child: ListTile(
        leading: Icon(Icons.fiber_manual_record, color: scheme.error),
        title: const Text('Recording on the glasses'),
        subtitle: Text('${_clock(d)}  -  tap on the glasses to stop'),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.mic_none, size: 48, color: scheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(
              'No recordings yet.\nOpen Apps > Recorder on the glasses '
              'and tap to record.',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
