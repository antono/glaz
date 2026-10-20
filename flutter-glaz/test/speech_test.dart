import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaz/frame/link.dart';
import 'package:glaz/services/recordings.dart';
import 'package:glaz/services/speech.dart';
import 'package:glaz/services/transcripts.dart';
import 'package:glaz/settings.dart';

List<int> samples(Uint8List pcm) {
  final b = ByteData.sublistView(pcm);
  return [for (var i = 0; i < pcm.length; i += 2) b.getInt16(i, Endian.little)];
}

/// Hears each piece of sound as one word, its number, and keeps the sound.
class FakeTranscriber extends Transcriber {
  FakeTranscriber([this.state = SpeechModel.available]);
  SpeechModel state;

  /// Goes wrong like ML Kit fed too fast, this many times first.
  int overflows = 0;
  int starts = 0;
  String? language;
  final got = <int>[];

  @override
  Future<SpeechModel> model(String language) async => state;

  @override
  Future<void> download(
    String language, {
    void Function(int got, int total)? progress,
  }) async {
    progress?.call(137, 137);
    state = SpeechModel.available;
  }

  @override
  Transcription start(String language) {
    this.language = language;
    starts++;
    return _Fake(this);
  }
}

class _Fake extends Transcription {
  _Fake(this.t);
  final FakeTranscriber t;
  var n = 0;

  @override
  Future<void> add(
    List<int> samples, {
    required int rate,
    required int bits,
    bool unsigned8 = false,
  }) async {
    t.got.addAll(samples);
    hear(Heard('${++n}', partial: true));
    hear(Heard('$n'));
  }

  @override
  Future<void> finish() async {
    if (t.overflows > 0) {
      t.overflows--;
      t.got.clear();
      end(TranscriptionError('ERROR_TYPE_AUDIO_BUFFER_OVERFLOW', text));
    } else {
      end();
    }
  }

  @override
  Future<void> cancel() async => end();
}

void main() {
  group('Pcm16k', () {
    test('8 kHz doubles, half way between samples', () {
      final out = samples(Pcm16k(8000, 16).add([0, 0, 0, 1, 0, 2]));
      // 0, 256, 512: between each two, the one half way
      expect(out, [0, 128, 256, 384, 512]);
    });

    test('pieces join as if fed whole', () {
      final whole = Uint8List.fromList([
        for (var i = 0; i < 137; i++) ...[i & 0xFF, (i * 7) & 0x7F],
      ]);
      final one = samples(Pcm16k(8000, 16).add(whole));
      final p = Pcm16k(8000, 16);
      final pieces = [
        ...samples(p.add(whole.sublist(0, 51))), // odd: half a sample over
        ...samples(p.add(whole.sublist(51, 200))),
        ...samples(p.add(whole.sublist(200))),
      ];
      expect(pieces, one);
    });

    test("8-bit: the glasses' are signed, a WAV's are not", () {
      expect(samples(Pcm16k(16000, 8).add([0, 1, 255, 128])), [
        0,
        256,
        -256,
        -32768,
      ]);
      expect(samples(Pcm16k(16000, 8, unsigned8: true).add([128, 129, 0])), [
        0,
        256,
        -32768,
      ]);
    });
  });

  group('TranscriptService', () {
    late Directory root;
    late Settings settings;
    late RecordingStore store;

    setUp(() async {
      TranscriptService.speed = 1000;
      SharedPreferences.setMockInitialValues({});
      settings = await Settings.load();
      root = Directory.systemTemp.createTempSync('glaz_speech');
      store = RecordingStore(root);
    });

    tearDown(() => root.deleteSync(recursive: true));

    Future<Recording> record(int bytes) async {
      final w = await store.begin(DateTime(2026, 10, 16, 13, 7, 1), 8000, 8);
      w.add(List.filled(bytes, 0));
      await w.close();
      return (await store.list()).single;
    }

    test('the text lands in the sound, in the language set', () async {
      settings.speechLanguage = 'ru-RU';
      final t = FakeTranscriber(SpeechModel.downloadable);
      final service = TranscriptService(store, settings, t);
      // 8 kHz 8-bit: a tenth of a second is 800 bytes, so three pieces
      final r = await record(2000);
      await service.transcribe(r);

      expect(t.language, 'ru-RU');
      expect(t.got, hasLength(2000));
      expect(t.got.first, 128, reason: 'WAV bytes as they are');
      expect(await wavComment(r.file), '1 2 3');
      expect((await store.list()).single.transcript, '1 2 3');
      expect(service.live, isEmpty);
    });

    test('another language picked: transcribed again in it', () async {
      settings.speechLanguage = 'ru-RU';
      final t = FakeTranscriber();
      final service = TranscriptService(store, settings, t);
      await service.transcribe(await record(1000));
      var r = (await store.list()).single;
      expect(r.language, 'ru-RU');
      expect(service.stale(r), isFalse);

      settings.speechLanguage = 'en-US';
      expect(service.stale(r), isTrue, reason: 'heard in Russian');
      await service.transcribe(r);
      expect(t.language, 'en-US');
      r = (await store.list()).single;
      expect(r.transcript, '1 2');
      expect(r.language, 'en-US');
      expect(service.stale(r), isFalse);
    });

    test('a language picked for one recording alone stays', () async {
      settings.speechLanguage = 'ru-RU';
      final t = FakeTranscriber();
      final service = TranscriptService(store, settings, t);
      await service.transcribe(await record(1000), language: 'en-US');
      expect(t.language, 'en-US');
      var r = (await store.list()).single;
      expect(r.language, 'en-US');
      expect(r.languagePicked, isTrue);
      expect(await wavLanguagePicked(r.file), isTrue);
      expect(service.stale(r), isFalse, reason: 'picked for it');

      // again in the one for all: no longer picked, follows it
      await service.transcribe(r);
      r = (await store.list()).single;
      expect(r.language, 'ru-RU');
      expect(r.languagePicked, isFalse);
      settings.speechLanguage = 'de-DE';
      expect(service.stale(r), isTrue);
    });

    test('a transcript of no known language may go again', () async {
      final service = TranscriptService(store, settings, FakeTranscriber());
      final r = await record(10);
      await setWavComment(r.file, 'old');
      expect(service.stale((await store.list()).single), isTrue);
      expect(service.stale(r), isFalse, reason: 'no transcript at all');
    });

    test('heard while it comes in: the text is there as it ends', () async {
      settings.speechLanguage = 'ru-RU';
      final t = FakeTranscriber();
      final service = TranscriptService(store, settings, t);
      final recorder = RecorderService(
        FrameLink(),
        settings,
        store,
        transcripts: service,
        now: () => DateTime(2026, 10, 16, 13, 7, 1),
      );
      recorder.onMessage([0x1F, 8, 8]);
      recorder.onMessage([0x05, 0, 1, 255]); // the glasses' signed 8-bit
      recorder.onMessage([0x05, 2]);
      recorder.onMessage([0x06, 3]);
      await recorder.flush();
      while (service.live.isNotEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(t.got, hasLength(5), reason: 'the sound as it came');
      expect(t.language, 'ru-RU');
      final r = (await store.list()).single;
      expect(r.transcript, isNotEmpty);
      expect(r.language, 'ru-RU');
      expect(r.length, const Duration(microseconds: 5 * 1000000 ~/ 8000));
    });

    test('a language not on the phone: heard later, by hand', () async {
      final service = TranscriptService(
        store,
        settings,
        FakeTranscriber(SpeechModel.downloadable),
      );
      final recorder = RecorderService(
        FrameLink(),
        settings,
        store,
        transcripts: service,
        now: () => DateTime(2026, 10, 16, 13, 7, 1),
      );
      recorder.onMessage([0x1F, 8, 8]);
      recorder.onMessage([0x06, 1, 2]);
      await recorder.flush();
      while (service.live.isNotEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect((await store.list()).single.transcript, isNull);
    });

    test('overflowed, it goes again as fast as spoken', () async {
      final t = FakeTranscriber()..overflows = 1;
      final service = TranscriptService(store, settings, t);
      final r = await record(1000);
      await service.transcribe(r);
      expect(t.starts, 2);
      expect(await wavComment(r.file), '1 2');
    });

    test('deleting a recording deletes its transcript', () async {
      final service = TranscriptService(store, settings, FakeTranscriber());
      final r = await record(10);
      await service.transcribe(r);
      expect(await wavComment(r.file), isNotNull);
      await store.delete(r);
      expect(r.file.existsSync(), isFalse);
      expect(transcriptOf(r.file).existsSync(), isFalse);
    });

    test('a language the phone does not have is an error', () async {
      final service = TranscriptService(
        store,
        settings,
        FakeTranscriber(SpeechModel.unavailable),
      );
      final r = await record(10);
      await expectLater(service.transcribe(r), throwsStateError);
      expect(await wavComment(r.file), isNull);
      expect(service.live, isEmpty);
    });
  });
}
