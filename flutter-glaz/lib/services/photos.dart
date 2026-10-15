import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../frame/link.dart';
import '../frame/protocol.dart';
import '../settings.dart';

/// A series from Time series: one folder, named by when it started.
class PhotoSeries {
  PhotoSeries(this.dir, this.start, this.photos);
  final Directory dir;
  final DateTime start;
  final List<File> photos;
}

/// Everything taken on one day: single shots and the series started then.
class PhotoDay {
  PhotoDay(this.date, this.photos, this.series);
  final DateTime date;
  final List<File> photos;
  final List<PhotoSeries> series;

  int get count =>
      photos.length + series.fold(0, (n, s) => n + s.photos.length);
}

String _two(int n) => n.toString().padLeft(2, '0');
String _day(DateTime t) => '${t.year}-${_two(t.month)}-${_two(t.day)}';
String _time(DateTime t) =>
    '${_two(t.hour)}-${_two(t.minute)}-${_two(t.second)}';

/// The name of a photo taken at [t]: '2026-10-14 17-35-01-137.jpg'.
String _photoName(DateTime t) =>
    '${_day(t)} ${_time(t)}-${t.millisecond.toString().padLeft(3, '0')}.jpg';

final _photoPattern = RegExp(
  r'^(\d{4})-(\d\d)-(\d\d) (\d\d)-(\d\d)-(\d\d)-(\d{3})\.jpg$',
);

/// When a photo was taken, read back from its name; null for other names.
DateTime? photoTime(File file) {
  final m = _photoPattern.firstMatch(file.uri.pathSegments.last);
  if (m == null) return null;
  final n = [for (var i = 1; i <= 7; i++) int.parse(m[i]!)];
  return DateTime(n[0], n[1], n[2], n[3], n[4], n[5], n[6]);
}

/// How a date and time is shown: '2026-10-14 17:52:10', the same as the
/// names on disk but with the usual colons.
String stampLabel(DateTime t) =>
    '${_day(t)} ${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';

/// The photos on the phone, filed by date (docs/PROTOCOL.md, "Photos"):
///
///     root/2026-10-14/2026-10-14 17-35-01-137.jpg   single shot
///     root/2026-10-14/2026-10-14 17-52-10/          a series, by its start
///         2026-10-14 17-52-14-002.jpg               ... and its photos
///
/// Every name is a date and time: photos by when they were taken, series
/// folders by when they started. Names sort in time order.
/// The folders are the whole state: [days] reads them back, so photos
/// survive restarts with nothing else to keep in sync.
class PhotoStore extends ChangeNotifier {
  PhotoStore(this.root);

  final Directory root;

  static final _dayName = RegExp(r'^(\d{4})-(\d\d)-(\d\d)$');
  static final _seriesName = RegExp(
    r'^(\d{4})-(\d\d)-(\d\d) (\d\d)-(\d\d)-(\d\d)$',
  );

  /// Read the folders again (after a permission change, say).
  void refresh() => notifyListeners();

  Future<File> saveSingle(Uint8List jpeg, DateTime at) async {
    final dir = Directory('${root.path}/${_day(at)}');
    await dir.create(recursive: true);
    final file = File('${dir.path}/${_photoName(at)}');
    await file.writeAsBytes(jpeg);
    notifyListeners();
    return file;
  }

  /// The folder for a series started at [start].
  Directory seriesDir(DateTime start) =>
      Directory('${root.path}/${_day(start)}/${_day(start)} ${_time(start)}');

  Future<File> saveInSeries(Uint8List jpeg, Directory dir, DateTime at) async {
    await dir.create(recursive: true);
    final file = File('${dir.path}/${_photoName(at)}');
    await file.writeAsBytes(jpeg);
    notifyListeners();
    return file;
  }

  /// Newest day first; within a day, newest first.
  Future<List<PhotoDay>> days() async {
    if (!await root.exists()) return [];
    final days = <PhotoDay>[];
    await for (final entry in root.list()) {
      final m = _dayName.firstMatch(_name(entry));
      if (entry is! Directory || m == null) continue;
      final date = DateTime(
        int.parse(m[1]!),
        int.parse(m[2]!),
        int.parse(m[3]!),
      );
      final photos = (await _jpegs(entry)).reversed.toList();
      final series = <PhotoSeries>[];
      await for (final sub in entry.list()) {
        final s = _seriesName.firstMatch(_name(sub));
        if (sub is! Directory || s == null) continue;
        final start = DateTime(
          int.parse(s[1]!),
          int.parse(s[2]!),
          int.parse(s[3]!),
          int.parse(s[4]!),
          int.parse(s[5]!),
          int.parse(s[6]!),
        );
        final files = await _jpegs(sub);
        if (files.isNotEmpty) series.add(PhotoSeries(sub, start, files));
      }
      series.sort((a, b) => b.start.compareTo(a.start));
      if (photos.isNotEmpty || series.isNotEmpty) {
        days.add(PhotoDay(date, photos, series));
      }
    }
    days.sort((a, b) => b.date.compareTo(a.date));
    return days;
  }

  static String _name(FileSystemEntity e) =>
      e.uri.pathSegments.lastWhere((s) => s.isNotEmpty, orElse: () => '');

  /// The JPEGs directly in [dir], oldest first (names sort by time).
  static Future<List<File>> _jpegs(Directory dir) async {
    final files = [
      await for (final e in dir.list())
        if (e is File && e.path.endsWith('.jpg')) e,
    ];
    files.sort((a, b) => a.path.compareTo(b.path));
    return files;
  }
}

/// Receives photos from the glasses and files them in a [PhotoStore].
class PhotoService extends ChangeNotifier {
  PhotoService(this.link, this.settings, this.store, {DateTime Function()? now})
    : _now = now ?? DateTime.now {
    link.events.listen(onMessage);
  }

  final FrameLink link;
  final Settings settings;
  final PhotoStore store;
  final DateTime Function() _now;

  /// A photo more than this after the last one of its series starts a new
  /// folder: the counter on the glasses restarts at 1 with them.
  static const seriesGap = Duration(minutes: 10);

  final _chunks = BytesBuilder(copy: false);
  int _from = 0; // PHOTO_FROM of the photo being received; 0 = single
  int? _series;
  Directory? _seriesDir;
  DateTime _seriesLast = DateTime(0);
  Future<void> _saving = Future.value();
  int received = 0;

  @visibleForTesting
  void onMessage(List<int> m) {
    if (m.isEmpty) return;
    switch (m[0]) {
      case photoFrom:
        // a new photo begins; whatever is half-received was cut short
        _chunks.clear();
        _from = m.length > 1 ? m[1] : 0;
      case photoChunk:
        _chunks.add(m.sublist(1));
      case photoEnd:
        _chunks.add(m.sublist(1));
        final jpeg = _chunks.takeBytes();
        final from = _from;
        _from = 0;
        final at = _now();
        if (!settings.serviceOn('photos')) return;
        // one at a time, in the order they came
        _saving = _saving.then((_) => _save(jpeg, from, at)).catchError((_) {});
    }
  }

  /// Waits for photos already received to be on disk.
  Future<void> flush() => _saving;

  Future<void> _save(Uint8List jpeg, int from, DateTime at) async {
    final upright = await compute(_upright, jpeg);
    if (from == 0) {
      await store.saveSingle(upright, at);
    } else {
      if (from != _series ||
          _seriesDir == null ||
          at.difference(_seriesLast) > seriesGap) {
        _series = from;
        _seriesDir = store.seriesDir(at);
      }
      _seriesLast = at;
      await store.saveInSeries(upright, _seriesDir!, at);
    }
    received++;
    notifyListeners();
  }
}

/// The camera is mounted turned by 90 degrees; this is what frame_msg's
/// RxPhoto does too. A photo that does not decode is kept as it came.
Uint8List _upright(Uint8List jpeg) {
  final image = img.decodeJpg(jpeg);
  if (image == null) return jpeg;
  return img.encodeJpg(img.copyRotate(image, angle: 270), quality: 90);
}
