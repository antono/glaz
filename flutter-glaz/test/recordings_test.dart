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
