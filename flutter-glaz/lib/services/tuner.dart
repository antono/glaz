import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../frame/link.dart';
import '../frame/protocol.dart';
import '../settings.dart';

/// The fundamental of [x], in Hz, or null when there is none: too quiet,
/// or no pitch (noise, a chord's mush). YIN (de Cheveigné and Kawahara,
/// 2002): the difference of the first half of [x] with itself shifted,
/// normalised by its running mean, and the first dip under [threshold] is
/// the period -- the first, not the deepest, so a strong second harmonic
/// is not taken for the note. Refined between samples with a parabola
/// through the plain difference, at the dip a few periods on: the
/// parabola is as far off in samples there, a few times less of a period.
/// At the first dip a high note read 3 to 8 cents off at 8 kHz.
double? pitchOf(
  List<double> x,
  int rate, {
  double minHz = 30,
  double maxHz = 1100,
  double minLevel = 0.002,
  double threshold = 0.15,
}) {
  final w = x.length ~/ 2;
  final maxLag = min(rate ~/ minHz, x.length - w - 1);
  final minLag = max(2, rate ~/ maxHz);
  if (maxLag <= minLag) return null;

  var energy = 0.0;
  for (var i = 0; i < w; i++) {
    energy += x[i] * x[i];
  }
  if (sqrt(energy / w) < minLevel) return null;

  // the difference, normalised by its mean up to each lag
  final raw = Float64List(maxLag + 2);
  final d = Float64List(maxLag + 2);
  d[0] = 1;
  var running = 0.0;
  for (var tau = 1; tau <= maxLag + 1; tau++) {
    var s = 0.0;
    for (var i = 0; i < w; i++) {
      final v = x[i] - x[i + tau];
      s += v * v;
    }
    raw[tau] = s;
    running += s;
    d[tau] = running == 0 ? 1 : s * tau / running;
  }

  var tau = -1;
  for (var t = minLag; t <= maxLag; t++) {
    if (d[t] < threshold) {
      tau = t;
      while (tau < maxLag && d[tau + 1] < d[tau]) {
        tau++;
      }
      break;
    }
  }
  if (tau < 0) {
    // nothing under the threshold: the deepest, if it is deep at all
    tau = minLag;
    for (var t = minLag + 1; t <= maxLag; t++) {
      if (d[t] < d[tau]) tau = t;
    }
    if (d[tau] > 0.35) return null;
  }

  final k = min(4, maxLag ~/ tau);
  var at = k * tau;
  for (var t = max(1, at - k); t <= min(maxLag, at + k); t++) {
    if (raw[t] < raw[at]) at = t;
  }
  final a = raw[at - 1], b = raw[at], c = raw[at + 1];
  final bend = a - 2 * b + c;
  final shift = bend > 0 ? (a - c) / (2 * bend) : 0.0;
  return rate * k / (at + shift);
}

/// [hz] as a MIDI note number with its fraction: 69 is A4, 440 Hz.
double midiOf(double hz) => 69 + 12 * log(hz / 440) / ln2;

/// Sound coming in, a piece at a time, and its pitch every [hop]: the
/// last [size] samples, 128 ms, enough for two and a half periods of a
/// bass's low E (41 Hz). The pitch is the median of the last three found,
/// so a stray octave or a pluck's first scratch does not show.
class PitchTracker {
  PitchTracker(this.rate) : size = rate * 128 ~/ 1000, hop = rate ~/ 10;

  final int rate;
  final int size;
  final int hop;

  final _samples = <double>[];
  int _fresh = 0;
  final _last = <double?>[];

  /// Samples from -1 to 1. Calls [found] for each hop: Hz, or null when
  /// nothing is heard.
  void add(Iterable<double> samples, void Function(double? hz) found) {
    for (final s in samples) {
      _samples.add(s);
      if (++_fresh < hop) continue;
      _fresh = 0;
      if (_samples.length > size) {
        _samples.removeRange(0, _samples.length - size);
      }
      if (_samples.length == size) found(_smoothed(pitchOf(_samples, rate)));
    }
  }

  double? _smoothed(double? hz) {
    _last.add(hz);
    if (_last.length > 3) _last.removeAt(0);
    final heard = [for (final h in _last) ?h]..sort();
    if (heard.length < 2) return null;
    return heard.length == 3 ? heard[1] : (heard[0] + heard[1]) / 2;
  }
}

/// 16-bit little-endian PCM as samples from -1 to 1.
Iterable<double> pcm16(List<int> bytes) sync* {
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    final v = bytes[i] | bytes[i + 1] << 8;
    yield (v >= 0x8000 ? v - 0x10000 : v) / 32768;
  }
}

/// 8-bit signed PCM, as the glasses send it, as samples from -1 to 1.
Iterable<double> pcm8(List<int> bytes) sync* {
  for (final b in bytes) {
    yield (b >= 0x80 ? b - 0x100 : b) / 128;
  }
}

/// The phone's own microphone, for the tuner.
abstract class PhoneMic {
  /// Android's, through "glaz/tuner"; elsewhere there is none.
  static PhoneMic platform = _ChannelMic();

  /// Starts hearing, 16-bit mono at [rate] Hz, into [pcm]. Throws a
  /// [StateError] whose message says why it cannot, for the glasses.
  Future<void> start(int rate);
  Future<void> stop();

  /// 16-bit little-endian PCM, as it is heard.
  Stream<Uint8List> get pcm;
}

class _ChannelMic implements PhoneMic {
  static const _calls = MethodChannel('glaz/tuner');
  static final _events = const EventChannel('glaz/tuner/events')
      .receiveBroadcastStream()
      .cast<Uint8List>();

  @override
  Stream<Uint8List> get pcm => _events;

  @override
  Future<void> start(int rate) async {
    if (!Platform.isAndroid) throw StateError('no microphone here');
    if (!(await Permission.microphone.request()).isGranted) {
      throw StateError('allow the microphone');
    }
    if (await _calls.invokeMethod<bool>('start', {'rate': rate}) != true) {
      throw StateError('microphone busy');
    }
  }

  @override
  Future<void> stop() => _calls.invokeMethod('stop');
}

/// The glasses' Tuner (apps/tuner/tuner.lua, docs/PROTOCOL.md, "Tuner"): it
/// asks with TUNER [1, mic] when a tuning is on screen and says [0] when
/// it goes. The phone hears -- its own microphone (mic 0), or the glasses'
/// streamed as Recorder's is (mic 1, REC_START's for = 3) -- finds the
/// pitch and sends it, at most one message at a time:
/// 'p', the pitch, a space and the Hz, the pitch in hundredths of a
/// semitone and the Hz in tenths; 'p' when nothing is heard any more; 's'
/// and a reason when it cannot.
/// The glasses know the instrument and work out the string.
class TunerService {
  TunerService(
    this.link,
    this.settings, {
    PhoneMic? mic,
    FutureOr<void> Function(List<int>)? send,
    DateTime Function()? now,
  }) : mic = mic ?? PhoneMic.platform,
       _send = send ?? ((b) => link.send(moduleCall, b, log: false)),
       _now = now ?? DateTime.now;

  final FrameLink link;
  final Settings settings;
  final PhoneMic mic;
  final FutureOr<void> Function(List<int>) _send;
  final DateTime Function() _now;

  /// The phone's microphone: 16 kHz is enough for any string's note, and
  /// every phone has it.
  static const phoneRate = 16000;

  /// Nothing heard this long after a note: the glasses are told.
  static const quiet = Duration(milliseconds: 600);

  /// The phone's microphone hearing nothing at all, not even its own
  /// hiss, this long: Android silences an app in the background.
  static const muted = Duration(seconds: 1);

  bool _wanted = false;
  bool _phone = false; // hearing with the phone's microphone
  bool _glasses = false; // the glasses' sound is coming in for this
  int _glassesBits = 8;
  PitchTracker? _tracker;
  StreamSubscription<Uint8List>? _pcm;
  DateTime? _noteAt;
  bool _noteShown = false;
  DateTime? _zeroSince;

  String? _want; // the latest for the glasses
  String? _sent; // what they have
  bool _sending = false;

  static const _prefix = 'tuner\n';

  void attach() {
    link.events.listen(onMessage);
    link.addListener(() {
      if (link.state != LinkState.connected && _wanted) _stop();
    });
  }

  /// A message from the glasses: TUNER's, and the sound that is for it.
  void onMessage(List<int> m) {
    if (m.isEmpty) return;
    switch (m[0]) {
      case tuner:
        if (m.length < 2) return;
        if (m[1] == 1) {
          _start(fromGlasses: m.length > 2 && m[2] == 1);
        } else {
          _stop();
        }
      case recStart:
        _glasses = _wanted && m.length > 3 && m[3] == forTuner;
        if (_glasses) {
          _glassesBits = m.length > 1 && m[1] == 16 ? 16 : 8;
          _tracker = PitchTracker(
            m.length > 2 && m[2] > 0 ? m[2] * 1000 : 8000,
          );
        }
      case audioChunk:
      case audioEnd:
        if (!_glasses) return;
        final bytes = m.sublist(1);
        _hear(_glassesBits == 16 ? pcm16(bytes) : pcm8(bytes));
        if (m[0] == audioEnd) _glasses = false;
    }
  }

  Future<void> _start({required bool fromGlasses}) async {
    _wanted = true;
    _noteAt = null;
    _noteShown = false;
    _sent = null;
    if (!settings.serviceOn('tuner')) {
      _report('sTuner is off on phone');
      return;
    }
    if (fromGlasses) {
      await _stopPhone();
      _report('s'); // heard: the sound follows
      return;
    }
    if (_phone) {
      _report('s');
      return;
    }
    _phone = true;
    _tracker = PitchTracker(phoneRate);
    _zeroSince = null;
    _pcm = mic.pcm.listen(_fromPhone);
    try {
      await mic.start(phoneRate);
    } on StateError catch (e) {
      await _stopPhone();
      if (_wanted) _report('s${e.message}');
      return;
    } catch (_) {
      await _stopPhone();
      if (_wanted) _report('sno microphone here');
      return;
    }
    if (!_wanted) {
      await _stopPhone();
      return;
    }
    _report('s');
  }

  void _fromPhone(Uint8List bytes) {
    if (!_phone) return;
    if (bytes.every((b) => b == 0)) {
      final now = _now();
      _zeroSince ??= now;
      if (now.difference(_zeroSince!) >= muted) {
        _report('sopen glaz on the phone');
      }
      return;
    }
    if (_zeroSince != null) {
      _zeroSince = null;
      _report('s');
    }
    _hear(pcm16(bytes));
  }

  void _hear(Iterable<double> samples) {
    final tracker = _tracker;
    if (tracker == null || !_wanted) return;
    tracker.add(samples, (hz) {
      final now = _now();
      if (hz != null) {
        _noteAt = now;
        _noteShown = true;
        final pitch = (midiOf(hz) * 100).round();
        _report('p$pitch ${(hz * 10).round()}');
      } else if (_noteShown &&
          (_noteAt == null || now.difference(_noteAt!) >= quiet)) {
        _noteShown = false;
        _report('p');
      }
    });
  }

  /// Sends [arg] once what went before has gone; meanwhile only the latest
  /// is kept: the link takes one a code every 200 ms.
  void _report(String arg) {
    _want = arg;
    if (!_sending) _flush();
  }

  Future<void> _flush() async {
    _sending = true;
    try {
      while (_want != null && _want != _sent) {
        final arg = _want!;
        _sent = arg;
        await _send([..._prefix.codeUnits, ...arg.codeUnits]);
      }
    } finally {
      _sending = false;
    }
  }

  Future<void> _stop() async {
    _wanted = false;
    _glasses = false;
    _tracker = null;
    _want = null;
    await _stopPhone();
  }

  Future<void> _stopPhone() async {
    if (!_phone) return;
    _phone = false;
    await _pcm?.cancel();
    _pcm = null;
    try {
      await mic.stop();
    } catch (_) {}
  }
}
