import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../frame/link.dart';
import '../frame/protocol.dart';
import '../settings.dart';

/// One recording on the phone.
class Recording {
  Recording(this.file, this.at, this.length);
  final File file;
  final DateTime at;
  final Duration length;
}

String _two(int n) => n.toString().padLeft(2, '0');
String _day(DateTime t) => '${t.year}-${_two(t.month)}-${_two(t.day)}';

/// The name of a recording started at [t]: '2026-10-15 13-07-01.wav'.
String recordingName(DateTime t) =>
    '${_day(t)} ${_two(t.hour)}-${_two(t.minute)}-${_two(t.second)}.wav';

final _namePattern = RegExp(
  r'^(\d{4})-(\d\d)-(\d\d) (\d\d)-(\d\d)-(\d\d)\.wav$',
);

/// When a recording started, read back from its name; null for other names.
DateTime? recordingTime(File file) {
  final m = _namePattern.firstMatch(file.uri.pathSegments.last);
  if (m == null) return null;
  final n = [for (var i = 1; i <= 6; i++) int.parse(m[i]!)];
  return DateTime(n[0], n[1], n[2], n[3], n[4], n[5]);
}

/// The 44-byte header of a mono PCM WAV holding [dataBytes] of samples.
Uint8List wavHeader(int dataBytes, int rate, int bits) {
  final b = ByteData(44);
  void tag(int at, String s) {
    for (var i = 0; i < 4; i++) {
      b.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  final block = bits ~/ 8;
  tag(0, 'RIFF');
  b.setUint32(4, 36 + dataBytes, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  b
    ..setUint32(16, 16, Endian.little) // fmt chunk size
    ..setUint16(20, 1, Endian.little) // PCM
    ..setUint16(22, 1, Endian.little) // mono
    ..setUint32(24, rate, Endian.little)
    ..setUint32(28, rate * block, Endian.little)
    ..setUint16(32, block, Endian.little)
    ..setUint16(34, bits, Endian.little);
  tag(36, 'data');
  b.setUint32(40, dataBytes, Endian.little);
  return b.buffer.asUint8List();
}

/// How long a WAV written by [RecordingWriter] plays, from its header and
/// size; zero for anything else.
Duration wavLength(Uint8List header, int fileBytes) {
  if (header.length < 44) return Duration.zero;
  final b = ByteData.sublistView(header);
  final perSecond = b.getUint32(28, Endian.little);
  if (perSecond == 0) return Duration.zero;
  final data = fileBytes - 44;
  return Duration(microseconds: data * 1000000 ~/ perSecond);
}

/// A recording being written, as the sound comes in. The file is a valid
/// WAV after every [add] but for its sizes, which [close] puts right: a
/// recording cut short by the app dying still plays most everywhere.
class RecordingWriter {
  RecordingWriter._(this.file, this._out, this.rate, this.bits);

  final File file;
  final RandomAccessFile _out;
  final int rate;
  final int bits;
  int bytes = 0;
  Future<void> _last = Future.value();

  static Future<RecordingWriter> open(File file, int rate, int bits) async {
    await file.parent.create(recursive: true);
    final out = await file.open(mode: FileMode.write);
    await out.writeFrom(wavHeader(0, rate, bits));
    return RecordingWriter._(file, out, rate, bits);
  }

  /// Samples as the glasses send them: 8-bit ones are signed, a WAV's are
  /// not; 16-bit ones are little-endian signed in both.
  void add(List<int> samples) {
    if (samples.isEmpty) return;
    final data = bits == 8
        ? Uint8List.fromList([for (final s in samples) (s + 128) & 0xFF])
        : Uint8List.fromList(samples);
    bytes += data.length;
    _last = _last.then((_) => _out.writeFrom(data));
  }

  Future<void> close() async {
    await _last;
    await _out.setPosition(0);
    await _out.writeFrom(wavHeader(bytes, rate, bits));
    await _out.close();
  }
}

/// The recordings on the phone, one folder a day, like the photos:
///
///     root/2026-10-15/2026-10-15 13-07-01.wav
///
/// The folders are the whole state; [list] reads them back.
class RecordingStore extends ChangeNotifier {
  RecordingStore(this.root);

  final Directory root;

  void refresh() => notifyListeners();

  Future<RecordingWriter> begin(DateTime at, int rate, int bits) =>
      RecordingWriter.open(
        File('${root.path}/${_day(at)}/${recordingName(at)}'),
        rate,
        bits,
      );

  /// Newest first.
  Future<List<Recording>> list() async {
    if (!await root.exists()) return [];
    final out = <Recording>[];
    await for (final e in root.list(recursive: true)) {
      if (e is! File) continue;
      final at = recordingTime(e);
      if (at == null) continue;
      try {
        final size = await e.length();
        final f = await e.open();
        final header = await f.read(44);
        await f.close();
        out.add(Recording(e, at, wavLength(header, size)));
      } catch (_) {}
    }
    out.sort((a, b) => b.at.compareTo(a.at));
    return out;
  }

  Future<void> delete(Recording r) async {
    await r.file.delete();
    final dir = r.file.parent;
    if (await dir.list().isEmpty) await dir.delete();
    notifyListeners();
  }
}

/// Receives the sound Recorder streams from the glasses (docs/PROTOCOL.md,
/// "Recorder") and writes each recording to a [RecordingStore] as it comes.
class RecorderService extends ChangeNotifier {
  RecorderService(
    this.link,
    this.settings,
    this.store, {
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    link.events.listen(onMessage);
    // the glasses gone mid-recording: keep what came
    link.addListener(() {
      if (!link.connected) _finish();
    });
  }

  final FrameLink link;
  final Settings settings;
  final RecordingStore store;
  final DateTime Function() _now;

  Future<RecordingWriter?> _writer = Future.value();
  bool _open = false;

  /// A recording is coming in now.
  bool get recording => _open;

  /// When the current recording began.
  DateTime? started;

  @visibleForTesting
  void onMessage(List<int> m) {
    if (m.isEmpty) return;
    switch (m[0]) {
      case recStart:
        _finish();
        if (!settings.serviceOn('recordings')) return;
        final bits = m.length > 1 && m[1] == 16 ? 16 : 8;
        final rate = m.length > 2 && m[2] > 0 ? m[2] * 1000 : 8000;
        final at = started = _now();
        _open = true;
        _writer = _writer
            .then<RecordingWriter?>((_) => store.begin(at, rate, bits))
            .catchError((_) => null);
        notifyListeners();
      case audioChunk:
        if (!_open) return;
        final data = m.sublist(1);
        _writer = _writer.then((w) => w?..add(data));
      case audioEnd:
        if (!_open) return;
        final data = m.sublist(1);
        _writer = _writer.then((w) => w?..add(data));
        _finish();
    }
  }

  void _finish() {
    if (!_open) return;
    _open = false;
    started = null;
    _writer = _writer
        .then((w) async {
          await w?.close();
          return null;
        })
        .catchError((_) => null)
        .then((_) {
          store.refresh();
          notifyListeners();
          return null;
        });
  }

  /// Waits for what was received to be on disk.
  Future<void> flush() => _writer;
}
