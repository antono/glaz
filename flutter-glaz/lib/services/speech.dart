import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// Turns sound as the app has it -- the glasses' 8-bit signed or 16-bit
/// samples, or a WAV's -- into what speech recognition takes: 16 kHz mono
/// 16-bit little-endian PCM. Fed piece by piece, it carries what it needs
/// from one piece to the next, so the pieces join without a click.
class Pcm16k {
  /// [unsigned8]: 8-bit samples are a WAV's, unsigned; the glasses' are
  /// signed.
  Pcm16k(this.rate, this.bits, {this.unsigned8 = false});

  static const outRate = 16000;

  final int rate;
  final int bits;
  final bool unsigned8;

  int? _last; // the last sample of the piece before
  double _at = 0; // where the next sample out falls, counted from _last
  int? _odd; // half a 16-bit sample left over

  Uint8List add(List<int> bytes) {
    final ins = <int>[?_last];
    if (bits == 16) {
      var i = 0;
      if (_odd != null && bytes.isNotEmpty) {
        ins.add((_odd! | bytes[0] << 8).toSigned(16));
        _odd = null;
        i = 1;
      }
      for (; i + 1 < bytes.length; i += 2) {
        ins.add((bytes[i] | bytes[i + 1] << 8).toSigned(16));
      }
      if (i < bytes.length) _odd = bytes[i];
    } else {
      for (final b in bytes) {
        ins.add(unsigned8 ? ((b & 0xFF) - 128) << 8 : b.toSigned(8) << 8);
      }
    }
    if (ins.isEmpty) return Uint8List(0);

    // straight lines between the samples in, read off at the rate out
    final step = rate / outRate;
    final last = ins.length - 1;
    final out = ByteData(2 * ((last - _at) / step + 2).ceil());
    var n = 0;
    var at = _at;
    while (at <= last) {
      final i = at.floor();
      final f = at - i;
      final v = i < last ? ins[i] + (ins[i + 1] - ins[i]) * f : ins[i] * 1.0;
      out.setInt16(2 * n++, v.round().clamp(-32768, 32767), Endian.little);
      at += step;
    }
    _last = ins[last];
    _at = at - last;
    return out.buffer.asUint8List(0, 2 * n);
  }
}

/// Recognition went wrong; [text] is what was heard before it did.
class TranscriptionError implements Exception {
  TranscriptionError(this.message, [this.text = '']);
  final String message;
  final String text;

  @override
  String toString() => message;
}

/// How ready speech recognition is for a language on this phone.
enum SpeechModel { unavailable, downloadable, downloading, available }

/// A piece of what was heard. A [partial] one is still being heard and the
/// next one replaces it; a final one stays.
class Heard {
  const Heard(this.text, {this.partial = false});
  final String text;
  final bool partial;
}

/// Speech to text, as it is spoken. What the app transcribes with --
/// recordings now, a voice to talk to an assistant with later -- so one
/// on the phone itself and one elsewhere can stand for each other.
abstract class Transcriber {
  /// The one this platform has; null where there is none.
  static Transcriber? get platform =>
      !kIsWeb && Platform.isAndroid ? MlKitTranscriber() : null;

  /// [language]: a BCP 47 tag, 'ru-RU'; 'auto' is the phone's own.
  Future<SpeechModel> model(String language);

  /// Gets the model for [language] onto the phone; [progress] with the
  /// bytes so far and in all.
  Future<void> download(
    String language, {
    void Function(int got, int total)? progress,
  });

  /// Asks the user for what recognition needs, if anything; throws if
  /// they say no.
  Future<void> permit() async {}

  Transcription start(String language);
}

/// One go of speech recognition: sound in with [add], what is heard out on
/// [heard], and all of it at the end from [done].
abstract class Transcription {
  // gone wrong before anyone waits for it is not an unhandled error
  Transcription() {
    _done.future.ignore();
  }

  final _heard = StreamController<Heard>.broadcast();
  final _done = Completer<String>();
  final _final = <String>[];
  String _partial = '';

  Stream<Heard> get heard => _heard.stream;

  /// Everything heard so far, the partial piece last.
  String get text => [..._final, if (_partial.isNotEmpty) _partial].join(' ');

  /// Everything heard, once the sound has all been heard; a
  /// [TranscriptionError] if recognition went wrong.
  Future<String> get done => _done.future;

  /// Sound as the glasses send it, or as a WAV holds it ([unsigned8]).
  Future<void> add(
    List<int> samples, {
    required int rate,
    required int bits,
    bool unsigned8 = false,
  });

  /// No more sound; [done] completes once the rest is heard.
  Future<void> finish();

  /// Drop it: [done] completes with what was heard so far.
  Future<void> cancel();

  @protected
  void hear(Heard h) {
    if (_done.isCompleted) return;
    if (h.partial) {
      _partial = h.text.trim();
    } else {
      _partial = '';
      if (h.text.trim().isNotEmpty) _final.add(h.text.trim());
    }
    _heard.add(h);
  }

  @protected
  void end([Object? error]) {
    if (_done.isCompleted) return;
    _partial = '';
    if (error != null) {
      _done.completeError(error);
    } else {
      _done.complete(text);
    }
    _heard.close();
  }
}

/// ML Kit's speech recognition on the phone itself, Basic mode
/// (android/.../Speech.kt): no Internet, nothing leaves the phone once the
/// language is downloaded.
class MlKitTranscriber extends Transcriber {
  static const _calls = MethodChannel('glaz/speech');
  static final _events = const EventChannel('glaz/speech/events')
      .receiveBroadcastStream()
      .map((e) => Map<String, Object?>.from(e as Map));
  static var _next = 1;

  @override
  Future<SpeechModel> model(String language) async {
    final s = await _calls.invokeMethod<String>('status', {
      'language': language,
    });
    return SpeechModel.values.firstWhere(
      (m) => m.name == s,
      orElse: () => SpeechModel.unavailable,
    );
  }

  @override
  Future<void> download(
    String language, {
    void Function(int got, int total)? progress,
  }) async {
    final sub = _events.where((e) => e['kind'] == 'download').listen((e) {
      progress?.call((e['got'] as num).toInt(), (e['total'] as num).toInt());
    });
    try {
      await _calls.invokeMethod('download', {'language': language});
    } finally {
      await sub.cancel();
    }
  }

  /// The microphone: the recognizer will not run without it, though it
  /// only ever hears what the app gives it.
  @override
  Future<void> permit() async {
    if (!(await Permission.microphone.request()).isGranted) {
      throw StateError('Speech recognition needs the microphone permission');
    }
  }

  @override
  Transcription start(String language) =>
      _MlKitTranscription(_next++, language);
}

class _MlKitTranscription extends Transcription {
  _MlKitTranscription(this.id, String language) {
    _sub = MlKitTranscriber._events.where((e) => e['id'] == id).listen((e) {
      final text = e['text'] as String? ?? '';
      switch (e['kind']) {
        case 'partial':
          hear(Heard(text, partial: true));
        case 'final':
          hear(Heard(text));
        case 'error':
          _error ??= text.isEmpty ? 'speech recognition failed' : text;
        case 'done':
          _sub?.cancel();
          end(_error == null ? null : TranscriptionError(_error!, this.text));
      }
    });
    _started = MlKitTranscriber._calls.invokeMethod('start', {
      'id': id,
      'language': language,
    });
    _started.then(
      (_) {},
      onError: (Object e) {
        _sub?.cancel();
        end(e);
      },
    );
  }

  final int id;
  StreamSubscription<Object?>? _sub;
  late final Future<void> _started;
  String? _error;
  Pcm16k? _pcm;

  @override
  Future<void> add(
    List<int> samples, {
    required int rate,
    required int bits,
    bool unsigned8 = false,
  }) async {
    final pcm = _pcm ??= Pcm16k(rate, bits, unsigned8: unsigned8);
    final data = pcm.add(samples);
    if (data.isEmpty) return;
    await _started;
    await MlKitTranscriber._calls.invokeMethod('feed', {
      'id': id,
      'data': data,
    });
  }

  @override
  Future<void> finish() async {
    await _started;
    await MlKitTranscriber._calls.invokeMethod('finish', {'id': id});
  }

  @override
  Future<void> cancel() async {
    await _started;
    await MlKitTranscriber._calls.invokeMethod('cancel', {'id': id});
  }
}

/// Languages to transcribe in: ML Kit's Basic mode, its own tags. 'auto'
/// is the phone's language: Basic mode does not tell languages apart.
const speechLanguages = [
  ('auto', 'Phone language'),
  ('ru-RU', 'Русский'),
  ('en-US', 'English'),
  ('de-DE', 'Deutsch'),
  ('fr-FR', 'Français'),
  ('es-ES', 'Español'),
  ('it-IT', 'Italiano'),
  ('pt-BR', 'Português'),
  ('pl-PL', 'Polski'),
  ('tr-TR', 'Türkçe'),
  ('hi-IN', 'हिन्दी'),
  ('ja-JP', '日本語'),
  ('ko-KR', '한국어'),
  ('cmn-Hans-CN', '中文 (简体)'),
  ('cmn-Hant-TW', '中文 (繁體)'),
  ('vi-VN', 'Tiếng Việt'),
];
