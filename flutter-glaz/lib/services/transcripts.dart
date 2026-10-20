import 'dart:async';
import 'dart:io';

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

  /// Makes sure [language]'s model -- the one picked, by default -- is on
  /// the phone, downloading it if need be.
  Future<void> prepare([String? language]) {
    language ??= settings.speechLanguage;
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

  /// Whether [r] has a transcript heard in another language than the one
  /// picked now -- or in one not known, from before languages were kept.
  /// It may then be transcribed again, in place of the one it has. One in
  /// a language picked for that recording alone is never stale.
  bool stale(Recording r) =>
      r.transcript != null &&
      !r.languagePicked &&
      r.language != settings.speechLanguage;

  /// A recording coming in from the glasses, heard as it comes
  /// ([RecorderService]): its transcript is there the moment it ends, in
  /// the language picked for all. Its sound goes to [LiveHearing.add] as
  /// the glasses send it. Null where the phone has no speech recognition.
  /// Should the language not be on the phone, or anything go wrong, it
  /// hears nothing and the recording waits to be transcribed by hand.
  LiveHearing? hearLive(File wav, int rate, int bits) {
    final t = transcriber;
    final path = wav.path;
    if (t == null || live.containsKey(path)) return null;
    live[path] = '';
    notifyListeners();
    return LiveHearing._(this, t, path, settings.speechLanguage, rate, bits);
  }

  void _heardLive(String path, String text) {
    if (!live.containsKey(path)) return;
    live[path] = text;
    notifyListeners();
  }

  Future<void> _endLive(String path, String? text, String language) async {
    try {
      if (text != null) {
        await store.saveTranscript(
          Recording(File(path), DateTime.now(), Duration.zero),
          text,
          language: language,
        );
      }
    } catch (_) {
      // the recording stays, to be transcribed by hand
    } finally {
      live.remove(path);
      notifyListeners();
    }
  }

  /// One recording, read from its file as fast as the recognizer takes it,
  /// in [language] -- picked for this recording alone -- or else the one
  /// picked for all. Throws if the language is not on this phone or
  /// recognition fails.
  Future<void> transcribe(Recording r, {String? language}) async {
    final t = transcriber;
    final path = r.file.path;
    if (t == null || live.containsKey(path)) return;
    live[path] = '';
    notifyListeners();
    try {
      final picked = language != null;
      language ??= settings.speechLanguage;
      if (model != SpeechModel.available || _language != language) {
        await prepare(language);
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
      await store.saveTranscript(r, text, language: language, picked: picked);
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

/// One recording heard while it comes in: [TranscriptService.hearLive].
class LiveHearing {
  LiveHearing._(
    this._service,
    Transcriber t,
    this._path,
    this._language,
    this._rate,
    this._bits,
  ) {
    _feed = _start(t);
  }

  final TranscriptService _service;
  final String _path;
  final String _language;
  final int _rate;
  final int _bits;
  Transcription? _tr;
  late Future<void> _feed;

  /// Ended before the sound did: what it heard is not the whole of it.
  bool _cut = false;
  bool _finishing = false;

  Future<void> _start(Transcriber t) async {
    try {
      // only a language already on the phone: no download mid-recording
      if (await t.model(_language) != SpeechModel.available) return;
      await t.permit();
      final tr = _tr = t.start(_language);
      tr.heard.listen((_) => _service._heardLive(_path, tr.text));
      tr.done.whenComplete(() {
        if (!_finishing) _cut = true;
      }).ignore();
    } catch (_) {
      _tr = null;
    }
  }

  /// Sound as the glasses send it: 8-bit samples signed.
  void add(List<int> samples) {
    if (samples.isEmpty) return;
    _feed = _feed.then((_) async {
      final tr = _tr;
      if (tr == null || _cut) return;
      try {
        await tr.add(samples, rate: _rate, bits: _bits);
      } catch (_) {
        _cut = true;
      }
    });
  }

  /// The recording is over and on disk: what was heard goes into it.
  Future<void> finish() async {
    await _feed;
    final tr = _tr;
    String? text;
    if (tr != null && !_cut) {
      _finishing = true;
      try {
        await tr.finish();
        text = await tr.done;
      } catch (_) {
        text = null;
      }
    }
    await _service._endLive(_path, text, _language);
  }
}
