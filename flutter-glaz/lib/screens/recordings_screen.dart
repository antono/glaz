import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../services/recordings.dart';
import '../services/services.dart';
import '../widgets/recording.dart';
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

  /// Where the player is; several times a second while it plays, so only
  /// the time and the slider follow it, not the whole list.
  final _position = ValueNotifier(Duration.zero);

  /// The recordings on disk: read when they change -- a recording started,
  /// finished or deleted -- not on every rebuild.
  late Future<List<Recording>> _list;
  late final Listenable _changes;

  @override
  void initState() {
    super.initState();
    final recorder = Services.instance.recorder;
    _list = recorder.store.list();
    _changes = Listenable.merge([recorder, recorder.store])
      ..addListener(_reread);
  }

  void _reread() => _set(() {
    _list = Services.instance.recorder.store.list();
  });

  AudioPlayer get player {
    if (_player != null) return _player!;
    final p = _player = AudioPlayer();
    _subs.addAll([
      p.onPlayerStateChanged.listen((s) => _set(() => _state = s)),
      p.onPositionChanged.listen((d) => _position.value = d),
      p.onPlayerComplete.listen(
        (_) => _set(() {
          _state = PlayerState.completed;
          _position.value = Duration.zero;
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
    _changes.removeListener(_reread);
    _position.dispose();
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
        _position.value = Duration.zero;
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
    return FutureBuilder<List<Recording>>(
      future: _list,
      builder: (context, snap) {
        final all = snap.data;
        if (all == null) return const SizedBox.shrink();
        final now = DateTime.now();
        // start and stop from here too; red with the time while recording
        final children = <Widget>[
          const Padding(padding: EdgeInsets.only(top: 16), child: RecordRow()),
        ];
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
            subtitle: current && _state != PlayerState.stopped
                ? ValueListenableBuilder(
                    valueListenable: _position,
                    builder: (context, at, _) =>
                        Text('${_clock(at)} / ${_clock(r.length)}'),
                  )
                : Text(_clock(r.length)),
            trailing: IconButton(
              tooltip: 'Delete',
              icon: Icon(Icons.delete_outline, color: scheme.onSurfaceVariant),
              onPressed: () => _delete(r),
            ),
            onTap: () => _toggle(r),
          ),
          if (current && total > 0 && _state != PlayerState.stopped)
            ValueListenableBuilder(
              valueListenable: _position,
              builder: (context, at, _) => Slider(
                value: at.inMilliseconds.clamp(0, total).toDouble(),
                max: total.toDouble(),
                onChanged: (v) =>
                    player.seek(Duration(milliseconds: v.round())),
              ),
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
              'No recordings yet.\nTap Record above, or open Apps > '
              'Recorder on the glasses and tap there.',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
