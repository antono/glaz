import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../frame/link.dart';
import '../frame/protocol.dart';
import '../settings.dart';

/// One recording on the phone.
class Recording {
  Recording(this.file, this.at, this.length, [this.transcript]);
  final File file;
  final DateTime at;
  final Duration length;

  /// What was said in it, once transcribed (services/transcripts.dart);
  /// kept in the WAV itself ([wavComment]).
  final String? transcript;
}

/// Where a transcript was kept before it went into the WAV: next to the
/// sound, '... 13-07-01.txt'. Still read; [foldTranscripts] moves it in.
File transcriptOf(File wav) =>
    File(wav.path.replaceFirst(RegExp(r'\.wav$'), '.txt'));

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
/// size; zero for anything else. A recording cut short still has 0 for its
/// samples' size: they run to the end of the file then.
Duration wavLength(Uint8List header, int fileBytes) {
  if (header.length < 44) return Duration.zero;
  final b = ByteData.sublistView(header);
  final perSecond = b.getUint32(28, Endian.little);
  if (perSecond == 0) return Duration.zero;
  final said = b.getUint32(40, Endian.little);
  final data = said == 0 || said > fileBytes - 44 ? fileBytes - 44 : said;
  return Duration(microseconds: data * 1000000 ~/ perSecond);
}

// The transcript lives in the WAV, after the samples, in the standard
// comment: a LIST chunk of type INFO holding ICMT, UTF-8 ending in a zero.
// Android lets an app read, with READ_MEDIA_AUDIO, the recordings an earlier
// install of it left in Recordings/Glaz, but no .txt beside them: that
// folder takes sound only. Inside the sound the text goes where it goes.

/// The transcript kept in [wav]; null when it has none.
Future<String?> wavComment(File wav) async {
  final f = await wav.open();
  try {
    final length = await f.length();
    var at = 12;
    while (at + 8 <= length) {
      await f.setPosition(at);
      final head = await f.read(8);
      final id = ascii.decode(head.sublist(0, 4), allowInvalid: true);
      final size = ByteData.sublistView(head).getUint32(4, Endian.little);
      if (id == 'LIST') {
        return _icmt(await f.read(min(size, length - at - 8)));
      }
      // samples of a recording cut short: they run to the end
      if (id == 'data' && size == 0) return null;
      at += 8 + size + (size & 1);
    }
    return null;
  } finally {
    await f.close();
  }
}

String? _icmt(Uint8List list) {
  if (list.length < 4 || ascii.decode(list.sublist(0, 4)) != 'INFO') {
    return null;
  }
  final b = ByteData.sublistView(list);
  var at = 4;
  while (at + 8 <= list.length) {
    final id = ascii.decode(list.sublist(at, at + 4), allowInvalid: true);
    final size = b.getUint32(at + 4, Endian.little);
    final end = min(at + 8 + size, list.length);
    if (id == 'ICMT') {
      var text = list.sublist(at + 8, end);
      final zero = text.indexOf(0);
      if (zero >= 0) text = text.sublist(0, zero);
      return utf8.decode(text, allowMalformed: true);
    }
    at += 8 + size + (size & 1);
  }
  return null;
}

/// Puts [text] in [wav] as its transcript, in place of any before. Only
/// for a WAV of [RecordingWriter]'s shape, its samples at byte 44.
Future<void> setWavComment(File wav, String text) async {
  // append: read and write, kept as it is; the position is set below
  final f = await wav.open(mode: FileMode.append);
  try {
    final length = await f.length();
    await f.setPosition(0);
    final header = await f.read(44);
    if (header.length < 44 || ascii.decode(header.sublist(36, 40)) != 'data') {
      throw const FormatException('not a WAV of Recorder');
    }
    final h = ByteData.sublistView(header);
    var data = h.getUint32(40, Endian.little);
    if (data == 0 || data > length - 44) data = length - 44;
    final end = 44 + data + (data & 1);

    final t = [...utf8.encode(text), 0];
    if (t.length.isOdd) t.add(0);
    final chunk = BytesBuilder()
      ..add(ascii.encode('LIST'))
      ..add(_u32(4 + 8 + t.length))
      ..add(ascii.encode('INFOICMT'))
      ..add(_u32(t.length))
      ..add(t);

    await f.truncate(end);
    await f.setPosition(end);
    await f.writeFrom(chunk.takeBytes());
    await f.setPosition(4);
    await f.writeFrom(_u32(end + 20 + t.length - 8));
    await f.setPosition(40);
    await f.writeFrom(_u32(data));
  } finally {
    await f.close();
  }
}

Uint8List _u32(int n) =>
    (ByteData(4)..setUint32(0, n, Endian.little)).buffer.asUint8List();

/// Moves the transcripts kept beside the recordings under [dir] (the
/// '.txt' of [transcriptOf]) into the recordings themselves.
Future<void> foldTranscripts(Directory dir) async {
  if (!await dir.exists()) return;
  await for (final e in dir.list(recursive: true)) {
    if (e is! File || !e.path.endsWith('.wav')) continue;
    final txt = transcriptOf(e);
    try {
      if (!await txt.exists()) continue;
      await setWavComment(e, await txt.readAsString());
      await txt.delete();
    } catch (_) {} // left as it was, still read from there
  }
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

/// The recordings on the phone, one folder a day, like the photos, each
/// with its transcript once it has one:
///
///     root/2026-10-15/2026-10-15 13-07-01.wav
///
/// The transcript is in the WAV ([wavComment]); the folders are the whole
/// state, and [list] reads them back.
class RecordingStore extends ChangeNotifier {
  RecordingStore(this.root, {this.notes});

  final Directory root;

  /// Where a transcript goes when its WAV cannot take it: a recording an
  /// earlier install left in Recordings/Glaz, which this one may read but
  /// not change. The app's own folder: lost with the app, but transcribing
  /// again is all it takes. Null: such a transcript is not kept.
  final Directory? notes;

  File? _note(File wav) {
    final n = notes;
    if (n == null || !wav.path.startsWith('${root.path}/')) return null;
    return transcriptOf(
      File('${n.path}/${wav.path.substring(root.path.length + 1)}'),
    );
  }

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
        out.add(
          Recording(e, at, wavLength(header, size), await _transcript(e)),
        );
      } catch (_) {}
    }
    out.sort((a, b) => b.at.compareTo(a.at));
    return out;
  }

  /// In the WAV, else beside it (from before), else in [notes].
  Future<String?> _transcript(File wav) async {
    final inside = await wavComment(wav).catchError((_) => null);
    if (inside != null) return inside;
    for (final f in [transcriptOf(wav), _note(wav)]) {
      if (f != null && await f.exists()) return f.readAsString();
    }
    return null;
  }

  Future<void> saveTranscript(Recording r, String text) async {
    try {
      await setWavComment(r.file, text);
      final beside = transcriptOf(r.file);
      if (await beside.exists()) await beside.delete();
    } on FileSystemException {
      final note = _note(r.file);
      if (note == null) rethrow;
      await note.parent.create(recursive: true);
      await note.writeAsString(text);
    }
    notifyListeners();
  }

  Future<void> delete(Recording r) async {
    await r.file.delete();
    for (final f in [transcriptOf(r.file), _note(r.file)]) {
      if (f != null && await f.exists()) await f.delete();
    }
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
        // the assistant listening (services/assistant.dart), not Recorder
        if (m.length > 3 && m[3] == forAssistant) return;
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
