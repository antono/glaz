import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaz/frame/link.dart';
import 'package:glaz/services/photo_dir.dart';
import 'package:glaz/services/recordings.dart';
import 'package:glaz/settings.dart';

void main() {
  late Directory root;
  late Settings settings;
  late RecorderService recorder;
  final clock = DateTime(2026, 10, 15, 13, 7, 1);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = await Settings.load();
    root = Directory.systemTemp.createTempSync('glaz_rec');
    recorder = RecorderService(
      FrameLink(),
      settings,
      RecordingStore(root),
      now: () => clock,
    );
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('a recording is filed by day, named by its start', () async {
    recorder.onMessage([0x1F, 8, 8]);
    expect(recorder.recording, isTrue);
    recorder.onMessage([0x05, 0, 1, 255]); // signed 0, 1, -1
    recorder.onMessage([0x06, 128]); // -128
    await recorder.flush();
    expect(recorder.recording, isFalse);

    final file = File('${root.path}/2026-10-15/2026-10-15 13-07-01.wav');
    final bytes = file.readAsBytesSync();
    expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
    final h = ByteData.sublistView(bytes);
    expect(h.getUint32(24, Endian.little), 8000); // rate
    expect(h.getUint16(34, Endian.little), 8); // bits
    expect(h.getUint32(40, Endian.little), 4); // data size
    expect(h.getUint32(4, Endian.little), 40);
    // a WAV's 8-bit samples are unsigned
    expect(bytes.sublist(44), [128, 129, 127, 0]);

    final list = await recorder.store.list();
    expect(list.single.at, clock);
    expect(list.single.length, const Duration(microseconds: 500));
  });

  test('16-bit samples are kept as they come', () async {
    recorder.onMessage([0x1F, 16, 8]);
    recorder.onMessage([0x05, 0x34, 0x12]);
    recorder.onMessage([0x06]);
    await recorder.flush();
    final bytes = File('${root.path}/2026-10-15/2026-10-15 13-07-01.wav')
        .readAsBytesSync();
    final h = ByteData.sublistView(bytes);
    expect(h.getUint16(34, Endian.little), 16);
    expect(h.getUint32(28, Endian.little), 16000); // bytes a second
    expect(bytes.sublist(44), [0x34, 0x12]);
  });

  test('sound with no recording started is ignored', () async {
    recorder.onMessage([0x05, 1, 2, 3]);
    recorder.onMessage([0x06]);
    await recorder.flush();
    expect(await recorder.store.list(), isEmpty);
  });

  test('the Recordings service off keeps nothing', () async {
    settings.setService('recordings', false);
    recorder.onMessage([0x1F, 8, 8]);
    recorder.onMessage([0x05, 1, 2]);
    recorder.onMessage([0x06]);
    await recorder.flush();
    expect(await recorder.store.list(), isEmpty);
  });

  test('wavLength reads the header', () {
    // 137 seconds of 8 kHz 8-bit sound
    final header = wavHeader(137 * 8000, 8000, 8);
    expect(wavLength(header, 44 + 137 * 8000), const Duration(seconds: 137));
  });

  group('the transcript inside the WAV', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('glaz_wav'));
    tearDown(() => tmp.deleteSync(recursive: true));

    Future<File> wav(int bytes, {bool cut = false}) async {
      final w = await RecordingWriter.open(File('${tmp.path}/a.wav'), 8000, 8);
      w.add(List.filled(bytes, 1));
      if (cut) {
        await Future<void>.delayed(Duration.zero);
        return w.file; // never closed: its header still says 0
      }
      await w.close();
      return w.file;
    }

    test('kept, read back, replaced; the sound stays as it was', () async {
      final f = await wav(137);
      expect(await wavComment(f), isNull);
      await setWavComment(f, 'Купить молоко');
      expect(await wavComment(f), 'Купить молоко');
      await setWavComment(f, 'short');
      expect(await wavComment(f), 'short');
      final bytes = f.readAsBytesSync();
      final h = ByteData.sublistView(bytes);
      // RIFF size is the file's, less 8; the samples untouched
      expect(h.getUint32(4, Endian.little), bytes.length - 8);
      expect(h.getUint32(40, Endian.little), 137);
      expect(bytes.sublist(44, 44 + 137).every((b) => b == 129), isTrue);
      expect(
        wavLength(bytes.sublist(0, 44), bytes.length).inMicroseconds,
        137 * 1000000 ~/ 8000,
      );
    });

    test('a recording cut short takes one too', () async {
      final f = await wav(100, cut: true);
      await setWavComment(f, 'x');
      expect(await wavComment(f), 'x');
    });

    test('a transcript beside its recording moves into it', () async {
      final f = await wav(10);
      await transcriptOf(f).writeAsString('beside');
      await foldTranscripts(tmp);
      expect(transcriptOf(f).existsSync(), isFalse);
      expect(await wavComment(f), 'beside');
    });
  });

  test('files move to the shared folder, empty folders go', () async {
    final tmp = Directory.systemTemp.createTempSync('glaz_adopt');
    final from = Directory('${tmp.path}/own');
    final to = Directory('${tmp.path}/shared');
    File('${from.path}/2026-10-18/a.jpg').createSync(recursive: true);
    File('${from.path}/2026-10-18/b.jpg')
      ..createSync(recursive: true)
      ..writeAsStringSync('new');
    File('${to.path}/2026-10-18/b.jpg')
      ..createSync(recursive: true)
      ..writeAsStringSync('already');
    expect(await adoptInto(from, to, 'jpg'), 1);
    expect(File('${to.path}/2026-10-18/a.jpg').existsSync(), isTrue);
    // one already there is left alone, and so is its source
    expect(File('${to.path}/2026-10-18/b.jpg').readAsStringSync(), 'already');
    expect(File('${from.path}/2026-10-18/b.jpg').existsSync(), isTrue);
    expect(await adoptInto(Directory('${tmp.path}/none'), to, 'jpg'), 0);
    tmp.deleteSync(recursive: true);
  });

  test('recordings go to the shared Recordings/Glaz', () {
    expect(
      sharedDir(
        '/storage/emulated/0/Android/data/dev.glaz/files',
        'Recordings/Glaz',
      ),
      '/storage/emulated/0/Recordings/Glaz',
    );
  });
}
