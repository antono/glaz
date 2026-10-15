import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaz/frame/link.dart';
import 'package:glaz/screens/photos_screen.dart';
import 'package:glaz/services/photo_dir.dart';
import 'package:glaz/services/photos.dart';
import 'package:glaz/settings.dart';

void main() {
  // a real JPEG, 4 wide and 2 tall, so the rotation is visible
  final jpeg = Uint8List.fromList(
    img.encodeJpg(img.Image(width: 4, height: 2)),
  );

  late Directory root;
  late Settings settings;
  late PhotoService photos;
  late DateTime clock;

  // what the glasses send for one photo: label, chunks, end
  void receive(int from, {bool label = true}) {
    if (label) photos.onMessage([0x1A, from]);
    photos.onMessage([0x07, ...jpeg.sublist(0, 10)]);
    photos.onMessage([0x08, ...jpeg.sublist(10)]);
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = await Settings.load();
    root = Directory.systemTemp.createTempSync('glaz_photos');
    clock = DateTime(2026, 10, 14, 17, 52, 10);
    photos = PhotoService(
      FrameLink(),
      settings,
      PhotoStore(root),
      now: () => clock,
    );
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('a single shot is filed under its day, upright', () async {
    receive(0);
    await photos.flush();
    final days = await photos.store.days();
    expect(days.single.date, DateTime(2026, 10, 14));
    expect(days.single.series, isEmpty);
    final file = days.single.photos.single;
    expect(file.path, endsWith('2026-10-14/2026-10-14 17-52-10-000.jpg'));
    expect(photoTime(file), DateTime(2026, 10, 14, 17, 52, 10));
    expect(photos.last?.path, file.path, reason: 'the remote opens it');
    final saved = img.decodeJpg(file.readAsBytesSync())!;
    expect((saved.width, saved.height), (2, 4));
  });

  test('a series goes in one folder named by its start, counted', () async {
    for (var i = 0; i < 3; i++) {
      receive(5);
      clock = clock.add(const Duration(seconds: 4));
    }
    receive(0); // a Camera shot in between stays out of the series
    await photos.flush();
    final day = (await photos.store.days()).single;
    final series = day.series.single;
    expect(series.dir.path, endsWith('2026-10-14/2026-10-14 17-52-10'));
    expect(series.start, DateTime(2026, 10, 14, 17, 52, 10));
    expect(series.photos.map((f) => f.uri.pathSegments.last), [
      '2026-10-14 17-52-10-000.jpg',
      '2026-10-14 17-52-14-000.jpg',
      '2026-10-14 17-52-18-000.jpg',
    ]);
    expect(day.photos, hasLength(1));
    expect(day.count, 4);
  });

  test('a new series number, or a long gap, starts a new folder', () async {
    receive(1);
    clock = clock.add(const Duration(minutes: 1));
    receive(2); // next series
    clock = clock.add(const Duration(minutes: 11));
    receive(2); // same number, but the glasses must have restarted
    await photos.flush();
    final series = (await photos.store.days()).single.series;
    expect(series.map((s) => s.photos.length), [1, 1, 1]);
    expect(series.first.start, DateTime(2026, 10, 14, 18, 4, 10));
  });

  test('a photo cut short is dropped, not glued to the next', () async {
    photos.onMessage([0x1A, 0]);
    photos.onMessage([0x07, 1, 2, 3]); // the end never came
    receive(0);
    await photos.flush();
    final file = (await photos.store.days()).single.photos.single;
    expect(img.decodeJpg(file.readAsBytesSync()), isNotNull);
  });

  test('without a label it is a single shot', () async {
    receive(3);
    receive(0, label: false);
    await photos.flush();
    final day = (await photos.store.days()).single;
    expect(day.series.single.photos, hasLength(1));
    expect(day.photos, hasLength(1));
  });

  test('nothing is saved with the service off', () async {
    settings.setService('photos', false);
    receive(0);
    await photos.flush();
    expect(await photos.store.days(), isEmpty);
  });

  test('names are dates and times, shown with colons', () {
    expect(
      photoTime(File('x/2026-10-14 17-52-14-137.jpg')),
      DateTime(2026, 10, 14, 17, 52, 14, 137),
    );
    expect(photoTime(File('x/0001.jpg')), isNull);
    expect(stampLabel(DateTime(2026, 10, 14, 7, 5, 9)), '2026-10-14 07:05:09');
  });

  test('shared Pictures/Glaz next to the app folder', () {
    expect(
      sharedPictures('/storage/emulated/0/Android/data/dev.glaz.glaz/files'),
      '/storage/emulated/0/Pictures/Glaz',
    );
    // a second user, or a removable card, keeps its own volume
    expect(
      sharedPictures('/storage/emulated/10/Android/data/dev.glaz.glaz/files'),
      '/storage/emulated/10/Pictures/Glaz',
    );
    expect(sharedPictures('/data/user/0/dev.glaz.glaz/files'), isNull);
  });

  test('day labels', () {
    final now = DateTime(2026, 10, 14, 9);
    expect(dayLabel(DateTime(2026, 10, 14), now), 'Today');
    expect(dayLabel(DateTime(2026, 10, 13), now), 'Yesterday');
    expect(dayLabel(DateTime(2026, 3, 7), now), '7 March');
    expect(dayLabel(DateTime(2025, 3, 7), now), '7 March 2025');
  });
}
