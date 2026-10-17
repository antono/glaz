import 'package:flutter/foundation.dart';

import '../settings.dart';
import 'recordings.dart';
import 'speech.dart';

/// Turns recordings into text, kept next to them
/// ([Recording.transcriptFile]), in the language the user picked
/// ([Settings.speechLanguage]).
class TranscriptService extends ChangeNotifier {
  /// Gets the model of the language picked ready as soon as it is picked.
  TranscriptService(this.store, this.settings, this.transcriber) {
    settings.addListener(() {
      if (settings.speechLanguage != _language) prepare().ignore();
    });
  }

  final RecordingStore store;
  final Settings settings;

  /// Null where the phone has no speech recognition.
  final Transcriber? transcriber;

  /// The recordings being transcribed now, by path, with what is heard so
  /// far.
  final live = <String, String>{};

  /// How far the language's model has downloaded, 0..1; null when not
  /// downloading or not known.
  double? downloading;

  /// The picked language's model, as [prepare] last found it; null before.
  SpeechModel? model;

  /// Why the model could not be had, if it could not.
  String? modelError;

  String? _language;
  Future<void>? _preparing;

  /// How many times as fast as it was spoken a recording is fed to the
  /// recognizer; faster than about this, ML Kit overflows.
  @visibleForTesting
  static double speed = 3;

  /// How often to look again at a download ML Kit retries by itself.
  @visibleForTesting
  static Duration retryEvery = const Duration(seconds: 3);

  /// Makes sure the picked language's model is on the phone, downloading
  /// it if need be.
  Future<void> prepare() {
    final language = settings.speechLanguage;
    if (_language == language && _preparing != null) return _preparing!;
    _language = language;
    return _preparing = _prepare(language).whenComplete(() {
      if (_language == language) _preparing = null;
    });
  }

  Future<void> _prepare(String language) async {
    final t = transcriber;
    if (t == null) return;
    model = null;
    modelError = null;
    notifyListeners();
    try {
      model = await t.model(language);
      if (model == SpeechModel.downloadable ||
          model == SpeechModel.downloading) {
        downloading = 0;
        notifyListeners();
        try {
          await t.download(
            language,
            progress: (got, total) {
              downloading = total > 0 ? got / total : null;
              notifyListeners();
            },
          );
        } catch (_) {
          // 'not completed yet and will be retried automatically': ML Kit
          // goes on by itself; wait a while for it before giving up
          for (var i = 0; i < 40; i++) {
            if (await t.model(language) != SpeechModel.downloading) break;
            await Future<void>.delayed(retryEvery);
          }
          if (await t.model(language) != SpeechModel.available) rethrow;
        }
        model = await t.model(language);
      }
    } catch (e) {
      modelError = '$e';
      rethrow;
    } finally {
      downloading = null;
      notifyListeners();
    }
  }

  /// One recording, read from its file as fast as the recognizer takes it.
  /// Throws if the language is not on this phone or recognition fails.
  Future<void> transcribe(Recording r) async {
    final t = transcriber;
    final path = r.file.path;
    if (t == null || live.containsKey(path)) return;
    live[path] = '';
    notifyListeners();
    try {
      final language = settings.speechLanguage;
      if (model != SpeechModel.available || _language != language) {
        await prepare();
      }
      if (model != SpeechModel.available) {
        throw StateError(
          'No speech recognition for this language here ($model)',
        );
      }

      await t.permit();

      final wav = await r.file.readAsBytes();
      if (wav.length < 44) return;
      String text;
      try {
        text = await _hear(t, language, wav, path, speed);
      } on TranscriptionError catch (e) {
        // fed faster than it hears: once more, as fast as it was spoken
        if (!e.message.contains('AUDIO_BUFFER_OVERFLOW')) rethrow;
        text = await _hear(t, language, wav, path, 1);
      }
      await store.saveTranscript(r, text);
    } finally {
      live.remove(path);
      notifyListeners();
    }
  }

  /// A WAV's sound to the recognizer, [faster] times as fast as it was
  /// spoken: all at once overflows the recognizer.
  Future<String> _hear(
    Transcriber t,
    String language,
    Uint8List wav,
    String path,
    double faster,
  ) async {
    final header = ByteData.sublistView(wav, 0, 44);
    final rate = header.getUint32(24, Endian.little);
    final bits = header.getUint16(34, Endian.little);
    final perSecond = rate * bits ~/ 8;

    live[path] = '';
    notifyListeners();
    final s = t.start(language);
    final sub = s.heard.listen((_) {
      live[path] = s.text;
      notifyListeners();
    });
    try {
      // a tenth of a second at a time
      final piece = perSecond ~/ 10;
      final clock = Stopwatch()..start();
      for (var at = 44; at < wav.length; at += piece) {
        final end = at + piece < wav.length ? at + piece : wav.length;
        await s.add(
          Uint8List.sublistView(wav, at, end),
          rate: rate,
          bits: bits,
          unsigned8: true,
        );
        final due = Duration(
          microseconds: (end - 44) * 1000000 ~/ (perSecond * faster),
        );
        if (due > clock.elapsed) {
          await Future<void>.delayed(due - clock.elapsed);
        }
      }
      await s.finish();
      return await s.done;
    } finally {
      await sub.cancel();
    }
  }
}
