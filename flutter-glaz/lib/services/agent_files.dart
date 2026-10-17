import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../frame/link.dart';
import '../glasses_menu.dart';
import '../settings.dart';
import 'assistant.dart';
import 'photos.dart';
import 'recordings.dart';
import 'transcripts.dart';

/// What a query brought the agent: text, and photos with it.
class QueryResult {
  const QueryResult(this.text, [this.images = const []]);
  final String text;
  final List<Uint8List> images;
}

/// Commands in the agent's answer that bring it something, instead of
/// doing something on the glasses: the phone answers them in the next
/// message (docs/PROTOCOL.md, "Assistant").
abstract class AgentQueries {
  bool handles(String command);
  Future<QueryResult> run(GlassesCommand command);
}

/// Glaz's photos and recordings for the agent, and a photo from the
/// glasses taken for it, if the user allows (Glaz > More > Assistant).
class GlazFiles implements AgentQueries {
  GlazFiles(
    this.link,
    this.settings,
    this.photos,
    this.recordings,
    this.transcripts,
  );

  final FrameLink link;
  final Settings settings;
  final PhotoService photos;
  final RecordingStore recordings;
  final TranscriptService transcripts;

  static const commands = {
    'photo',
    'photos',
    'getphoto',
    'recordings',
    'transcript',
  };

  /// At most this many in a list.
  static const listed = 20;
  static const photoWait = Duration(seconds: 20);
  static const transcribeWait = Duration(seconds: 90);

  @override
  bool handles(String command) => commands.contains(command);

  @override
  Future<QueryResult> run(GlassesCommand c) async {
    if (!settings.agentFiles) {
      return const QueryResult(
        'Not allowed: the user has not let you see photos and recordings.',
      );
    }
    try {
      return switch (c.name) {
        'photo' => await _take(),
        'photos' => QueryResult(await _photoList(_day(c.arg))),
        'getphoto' => await _getPhoto(c.arg),
        'recordings' => QueryResult(await _recordingList(_day(c.arg))),
        'transcript' => QueryResult(await _transcript(c.arg)),
        _ => QueryResult('Unknown: $c'),
      };
    } catch (e) {
      return QueryResult('$c failed: $e');
    }
  }

  /// A photo from the glasses, as the Remote's photo button takes it:
  /// Camera's size and quality, saved in Photos.
  Future<QueryResult> _take() async {
    if (!link.connected) {
      return const QueryResult('The glasses are not connected.');
    }
    if (!settings.serviceOn('photos')) {
      return const QueryResult('The Photos service is off on the phone.');
    }
    final before = photos.last;
    final got = Completer<File>();
    void saved() {
      final f = photos.last;
      if (f != null && f != before && !got.isCompleted) got.complete(f);
    }

    photos.addListener(saved);
    try {
      await link.remotePhoto(_photoSize(), _photoQuality());
      final file = await got.future.timeout(photoWait);
      return QueryResult('The photo, ${_name(file)}, taken just now:', [
        await upright(await file.readAsBytes()),
      ]);
    } on TimeoutException {
      return const QueryResult('No photo came from the glasses.');
    } finally {
      photos.removeListener(saved);
    }
  }

  int _photoSize() =>
      int.tryParse(settings.config('photo', 'resolution') ?? '') ?? 512;

  int _photoQuality() {
    final camera = glassesMenu
        .expand((s) => s.modules)
        .firstWhere((m) => m.id == 'photo');
    final q = camera.settings.firstWhere((s) => s.key == 'quality');
    final i = q.options.indexOf(settings.config('photo', 'quality') ?? '');
    return i < 0 ? q.options.indexOf(q.initial) + 1 : i + 1;
  }

  Future<List<(File, DateTime)>> _allPhotos() async {
    final out = <(File, DateTime)>[];
    for (final day in await photos.store.days()) {
      for (final f in [
        ...day.photos,
        for (final s in day.series) ...s.photos,
      ]) {
        final at = photoTime(f);
        if (at != null) out.add((f, at));
      }
    }
    out.sort((a, b) => b.$2.compareTo(a.$2));
    return out;
  }

  Future<String> _photoList(DateTime? day) async {
    final all = [
      for (final p in await _allPhotos())
        if (day == null || _sameDay(p.$2, day)) p,
    ];
    if (all.isEmpty) return 'No photos${day == null ? '' : ' that day'}.';
    final lines = [
      for (final p in all.take(listed)) '${_name(p.$1)}  ${stampLabel(p.$2)}',
    ];
    return 'Photos, newest first, ${lines.length} of ${all.length}:\n'
        '${lines.join('\n')}';
  }

  Future<QueryResult> _getPhoto(String name) async {
    for (final p in await _allPhotos()) {
      if (_name(p.$1) == name.trim()) {
        return QueryResult('$name, taken ${stampLabel(p.$2)}:', [
          await upright(await p.$1.readAsBytes()),
        ]);
      }
    }
    return QueryResult('No photo named "$name"; @photos lists them.');
  }

  Future<String> _recordingList(DateTime? day) async {
    final all = [
      for (final r in await recordings.list())
        if (day == null || _sameDay(r.at, day)) r,
    ];
    if (all.isEmpty) return 'No recordings${day == null ? '' : ' that day'}.';
    final lines = [
      for (final r in all.take(listed))
        '${_name(r.file)}  ${stampLabel(r.at)}  ${r.length.inSeconds} s  '
            '${_snippet(r.transcript)}',
    ];
    return 'Recordings, newest first, ${lines.length} of ${all.length}:\n'
        '${lines.join('\n')}';
  }

  static String _snippet(String? transcript) {
    if (transcript == null) return '(not transcribed yet)';
    final t = transcript.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.isEmpty) return '(nothing heard)';
    return '"${t.length > 80 ? '${t.substring(0, 80)}...' : t}"';
  }

  Future<String> _transcript(String name) async {
    Recording? find(List<Recording> all) {
      for (final r in all) {
        if (_name(r.file) == name.trim()) return r;
      }
      return null;
    }

    var r = find(await recordings.list());
    if (r == null) return 'No recording named "$name"; @recordings lists them.';
    if (r.transcript == null) {
      await transcripts.transcribe(r).timeout(transcribeWait);
      r = find(await recordings.list()) ?? r;
    }
    final text = r.transcript;
    if (text == null) return 'Could not transcribe $name.';
    return text.trim().isEmpty
        ? 'Nothing was heard in $name.'
        : 'The transcript of $name:\n$text';
  }

  static String _name(File f) => f.uri.pathSegments.last;

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  /// 'today', 'yesterday' or '2026-10-17'; null for anything else: every
  /// day.
  static DateTime? _day(String arg) {
    final a = arg.trim().toLowerCase();
    final now = DateTime.now();
    if (a == 'today') return now;
    if (a == 'yesterday') return now.subtract(const Duration(days: 1));
    final m = RegExp(r'^(\d{4})-(\d\d)-(\d\d)$').firstMatch(a);
    if (m == null) return null;
    return DateTime(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
  }
}

/// [jpeg] the right way up. The glasses' photos are kept as they came,
/// turned, with an Exif Orientation saying how to show them
/// (withOrientation in photos.dart); a model reads the pixels only.
Future<Uint8List> upright(Uint8List jpeg) => compute(_upright, jpeg);

Uint8List _upright(Uint8List jpeg) {
  final image = img.decodeJpg(jpeg);
  if (image == null) return jpeg;
  return img.encodeJpg(img.bakeOrientation(image), quality: 90);
}
