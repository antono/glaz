import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaz/frame/link.dart';
import 'package:glaz/frame/protocol.dart';
import 'package:glaz/services/tuner.dart';
import 'package:glaz/settings.dart';

/// A plucked string, roughly: the note and its harmonics, each [weights]
/// strong, starting at [phase].
List<double> tone(
  double hz,
  int rate,
  int n, {
  List<double> weights = const [1, 0.6, 0.4, 0.25, 0.15],
  double level = 0.3,
}) => [
  for (var i = 0; i < n; i++)
    level *
        [
          for (var h = 0; h < weights.length; h++)
            weights[h] * sin(2 * pi * hz * (h + 1) * i / rate + h),
        ].reduce((a, b) => a + b) /
        weights.length,
];

double cents(double a, double b) => 1200 * log(a / b) / ln2;

Uint8List toPcm16(List<double> x) {
  final b = ByteData(x.length * 2);
  for (var i = 0; i < x.length; i++) {
    b.setInt16(
      i * 2,
      (x[i] * 32767).round().clamp(-32768, 32767),
      Endian.little,
    );
  }
  return b.buffer.asUint8List();
}

class FakeMic implements PhoneMic {
  final _pcm = StreamController<Uint8List>.broadcast(sync: true);
  String? refuse;
  int started = 0, stopped = 0;

  @override
  Stream<Uint8List> get pcm => _pcm.stream;

  @override
  Future<void> start(int rate) async {
    if (refuse != null) throw StateError(refuse!);
    started++;
  }

  @override
  Future<void> stop() async => stopped++;

  void hear(List<double> x) {
    // 50 ms at a time, as Tuner.kt sends it
    final bytes = toPcm16(x);
    for (var i = 0; i < bytes.length; i += 1600) {
      _pcm.add(bytes.sublist(i, min(i + 1600, bytes.length)));
    }
  }
}

void main() {
  group('pitchOf', () {
    // the lowest and highest open strings of the Tuner's instruments
    // (apps/tuner/tuner.lua), and some between
    const notes = {
      'bass E1': 41.20,
      'guitar E2': 82.41,
      'guitar A2': 110.0,
      'guitar G3': 196.0,
      'banjo D4': 293.66,
      'domra D5': 587.33,
      'violin E5': 659.26,
    };
    for (final rate in [16000, 8000]) {
      for (final e in notes.entries) {
        test('${e.key} at $rate Hz, within 2 cents', () {
          final x = tone(e.value, rate, rate * 128 ~/ 1000);
          final hz = pitchOf(x, rate);
          expect(hz, isNotNull);
          expect(cents(hz!, e.value).abs(), lessThan(2));
        });
      }
    }

    test('a second harmonic louder than the note: still the note', () {
      final x = tone(82.41, 16000, 2048, weights: [0.4, 1, 0.5, 0.3]);
      expect(cents(pitchOf(x, 16000)!, 82.41).abs(), lessThan(2));
    });

    test('a slightly flat string reads flat', () {
      final hz = 110 * pow(2, -12 / 1200).toDouble();
      final got = pitchOf(tone(hz, 16000, 2048), 16000)!;
      expect(cents(got, 110), closeTo(-12, 1));
    });

    test('silence and noise: no pitch', () {
      expect(pitchOf(List.filled(2048, 0.0), 16000), isNull);
      final r = Random(137);
      final noise = [for (var i = 0; i < 2048; i++) r.nextDouble() - 0.5];
      expect(pitchOf(noise, 16000), isNull);
    });

    test('too quiet: no pitch', () {
      expect(pitchOf(tone(110, 16000, 2048, level: 0.001), 16000), isNull);
    });
  });

  test('midiOf: A4 is 69, E2 is 40', () {
    expect(midiOf(440), closeTo(69, 1e-9));
    expect(midiOf(82.4069), closeTo(40, 1e-3));
  });

  group('TunerService', () {
    late Settings settings;
    late FakeMic mic;
    late List<String> sent;
    late TunerService service;
    late DateTime now;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      settings = await Settings.load();
      mic = FakeMic();
      sent = [];
      now = DateTime(2026, 10, 27);
      service = TunerService(
        FrameLink()..state = LinkState.connected,
        settings,
        mic: mic,
        send: (b) {
          final s = String.fromCharCodes(b);
          expect(s, startsWith('tuner\n'));
          sent.add(s.substring(6));
        },
        now: () => now,
      );
    });

    Future<void> settle() => Future<void>.delayed(Duration.zero);

    test("the phone's microphone: the note, then quiet", () async {
      service.onMessage([tuner, 1, 0]);
      await settle();
      expect(mic.started, 1);
      expect(sent, ['s']);

      mic.hear(tone(110, 16000, 16000 ~/ 2));
      await settle();
      final note = sent.last;
      expect(note, startsWith('p'));
      final parts = note.substring(1).split(' ');
      expect(int.parse(parts[0]), closeTo(4500, 2));
      expect(int.parse(parts[1]), closeTo(1100, 1));

      // nothing found for a while: the last note found is the clock's
      mic.hear(List.filled(16000 ~/ 2, 0.0001));
      await settle();
      expect(sent.last, isNot('p'));
      now = now.add(const Duration(seconds: 1));
      mic.hear(List.filled(16000 ~/ 2, 0.0001));
      await settle();
      expect(sent.last, 'p');

      service.onMessage([tuner, 0]);
      await settle();
      expect(mic.stopped, 1);
    });

    test("the glasses' microphone: their sound, 16 bit at 8 kHz", () async {
      service.onMessage([tuner, 1, 1]);
      await settle();
      expect(mic.started, 0);
      expect(sent, ['s']);

      service.onMessage([recStart, 16, 8, forTuner]);
      final bytes = toPcm16(tone(196, 8000, 4000));
      for (var i = 0; i < bytes.length; i += 238) {
        service.onMessage([
          audioChunk,
          ...bytes.sublist(i, min(i + 238, bytes.length)),
        ]);
      }
      await settle();
      final pitch = int.parse(sent.last.substring(1).split(' ')[0]);
      expect(pitch, closeTo(5500, 2)); // G3
    });

    test("another app's sound is not the tuner's", () async {
      service.onMessage([tuner, 1, 1]);
      await settle();
      service.onMessage([recStart, 16, 8, forTranslate]);
      service.onMessage([audioChunk, ...toPcm16(tone(196, 8000, 4000))]);
      await settle();
      expect(sent, ['s']);
    });

    test('off on the phone: the glasses are told', () async {
      settings.setService('tuner', false);
      service.onMessage([tuner, 1, 0]);
      await settle();
      expect(mic.started, 0);
      expect(sent, ['sTuner is off on phone']);
    });

    test('no microphone permission: the glasses are told', () async {
      mic.refuse = 'allow the microphone';
      service.onMessage([tuner, 1, 0]);
      await settle();
      expect(sent, ['sallow the microphone']);
    });

    test('silenced in the background: open glaz', () async {
      service.onMessage([tuner, 1, 0]);
      await settle();
      for (var i = 0; i < 25; i++) {
        mic.hear(List.filled(800, 0.0));
        now = now.add(const Duration(milliseconds: 50));
      }
      await settle();
      expect(sent.last, 'sopen glaz on the phone');
      mic.hear(tone(110, 16000, 8000));
      await settle();
      expect(sent, contains('s'));
      expect(sent.last, startsWith('p'));
    });
  });
}
