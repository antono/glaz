import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaz/frame/font.dart';
import 'package:glaz/frame/glyphs.dart';
import 'package:glaz/frame/protocol.dart';
import 'package:glaz/services/assistant.dart';
import 'package:glaz/services/recordings.dart';
import 'package:glaz/services/speech.dart';
import 'package:glaz/services/translate.dart';
import 'package:glaz/settings.dart';

import 'assistant_test.dart' show SentLink, FakeAgent;
import 'speech_test.dart' show FakeTranscriber;

/// Translates as '[to] text'; [models] are those on the phone, [fail]
/// makes every translation go wrong.
class FakeTranslator extends Translator {
  FakeTranslator([Set<String>? models]) : models = models ?? {'en', 'ru'};
  final Set<String> models;
  bool fail = false;
  final downloads = <String>[];

  /// Downloads wait for this when set.
  Completer<void>? gate;

  @override
  Future<bool> hasModel(String mlkit) async => models.contains(mlkit);

  @override
  Future<void> download(String mlkit) async {
    downloads.add(mlkit);
    await gate?.future;
    models.add(mlkit);
  }

  /// 'from>to' of each translation, in order.
  final pairs = <String>[];

  @override
  Future<String> translate(String text, String from, String to) async {
    pairs.add('$from>$to');
    if (fail) throw StateError('no luck');
    return '[$to] $text';
  }
}

/// Reads [blocks] off any photo, in [lang]; [fail] makes reading go wrong.
class FakePhotoReader extends PhotoReader {
  FakePhotoReader(this.blocks, [this.lang]);
  List<String> blocks;
  String? lang;
  bool fail = false;
  final hints = <String>[];
  final photos = <List<int>>[];

  @override
  Future<List<String>> read(Uint8List jpeg, TrLanguage hint) async {
    photos.add(jpeg);
    hints.add(hint.value);
    if (fail) throw StateError('blurred');
    return blocks;
  }

  @override
  Future<String?> language(String text) async => lang;
}

/// As FakeTranscriber, with the permission given once [gate] completes.
class SlowTranscriber extends FakeTranscriber {
  SlowTranscriber(this.gate);
  final Future<void> gate;

  @override
  Future<void> permit() => gate;
}

/// Recognition that the test ends, as ML Kit's may end by itself.
class EndingTranscriber extends Transcriber {
  final going = <_Ending>[];

  @override
  Future<SpeechModel> model(String language) async => SpeechModel.available;

  @override
  Future<void> download(
    String language, {
    void Function(int got, int total)? progress,
  }) async {}

  @override
  Transcription start(String language) => _Ending()..also(going);
}

class _Ending extends Transcription {
  void also(List<_Ending> list) => list.add(this);
  void stop() => end();

  @override
  Future<void> add(
    List<int> samples, {
    required int rate,
    required int bits,
    bool unsigned8 = false,
  }) async {}

  @override
  Future<void> finish() async => end();

  @override
  Future<void> cancel() async => end();
}

/// [0x0F, op, sess, from (2), count], as apps/translate/translate.lua packs it.
List<int> req(int op, int sess, int from, int count) => [
  translate,
  op,
  sess,
  from >> 8,
  from & 0xFF,
  count,
];

void main() {
  group('languages', () {
    test('heard by the recognizer, the lists in step', () {
      final tags = {for (final l in speechLanguages) l.$1};
      for (final l in translateLanguages) {
        expect(tags, contains(l.speech), reason: l.value);
      }
      expect(trFromValues, translateFrom);
      expect(trToValues, translateTo);
      expect(trFromLabels, [for (final l in translateLanguages) l.label]);
      expect(trToLabels, [
        for (final l in translateLanguages)
          if (l.shown) l.label,
      ]);
      expect(trToValues.toSet().difference(trFromValues.toSet()), isEmpty);
      expect(trFromValues, contains('en'));
      expect(trToValues, contains('ru'));
    });

    test('what it translates into, the glasses can draw', () {
      for (final l in translateLanguages.where((l) => l.shown)) {
        expect(forGlasses(l.label), isNot(contains('?')), reason: l.value);
        expect(forGlasses(l.label), l.label, reason: l.value);
      }
    });
  });

  group('TranslateLog', () {
    const long =
        'Встречаемся в 137 кабинете на третьем этаже после обеда, '
        'если ничего не изменится до тех пор, и обсудим всё остальное там';

    test('lines fit the glasses, a window fits a message', () {
      final log = TranslateLog();
      for (var i = 0; i < 20; i++) {
        log.translated(log.heard(long), long, withSource: true);
      }
      for (var i = 0; i < log.length; i++) {
        expect(textWidth(log[i].text), lessThanOrEqualTo(TranslateLog.width));
      }
      final w = log.window(0, 16, follow: false);
      expect(utf8.encode(w).length, lessThanOrEqualTo(300));
      expect(w, startsWith('w:1:0:${log.length}:0\n'));
      final tail = log.window(0, 4, follow: true);
      expect(tail, startsWith('w:1:${log.length - 4}:${log.length}:1\n'));
      expect(tail.split('\n'), hasLength(5));
    });

    test('empty', () {
      expect(TranslateLog().window(0, 4, follow: true), 'w:1:0:0:1');
      expect(TranslateLog().counted, 'n:1:0');
    });

    test('what is being heard is one line, then the piece heard', () {
      final log = TranslateLog();
      log.partial(long);
      expect(log.length, 1);
      expect(log[0].kind, TrKind.partial);
      log.partial('');
      expect(log.length, 0);
      log.heard(long);
      expect(log.length, greaterThan(1));
      expect(
        {for (var i = 0; i < log.length; i++) log[i].kind},
        {TrKind.partial},
      );
    });

    test('a piece heard becomes its translation, the original above', () {
      final log = TranslateLog();
      log.translated(log.heard('hello'), 'привет', withSource: false);
      expect(log.window(0, 4, follow: true), 'w:1:0:1:1\nT|привет');
      log.translated(log.heard('bye'), 'пока', withSource: true);
      expect(log.window(1, 4, follow: false), 'w:1:1:3:0\nS|bye\nT|пока');
    });

    test('pieces finish in order: lines before one waiting stay', () {
      final log = TranslateLog();
      log.info('en > ru 13:07');
      final a = log.heard('one');
      final b = log.heard('two');
      log.partial('thr');
      log.translated(b, 'два', withSource: false);
      expect(
        [for (var i = 0; i < log.length; i++) log[i].wire],
        ['I|en > ru 13:07', 'P|one', 'T|два', 'P|thr'],
      );
      log.translated(a, 'раз', withSource: false);
      log.partial('');
      expect(
        [for (var i = 0; i < log.length; i++) log[i].wire],
        ['I|en > ru 13:07', 'T|раз', 'T|два'],
      );
    });

    test('not translated: what was heard, and why', () {
      final log = TranslateLog();
      log.failed(log.heard('hello'), 'hello', 'no model');
      expect(
        log.window(0, 4, follow: true),
        'w:1:0:2:1\nS|hello\nE|not translated: no model',
      );
    });

    test('cleared: another session, 255 wraps to 1', () {
      final log = TranslateLog()..session = 255;
      final id = log.heard('x');
      log.clear();
      expect(log.session, 1);
      expect(log.length, 0);
      log.translated(id, 'y', withSource: false); // gone with the rest
      expect(log.length, 0);
    });

    test('too long: the oldest 1000 lines go, another session', () {
      final log = TranslateLog(maxLines: 1010);
      for (var i = 0; i < 1011; i++) {
        log.info('$i');
      }
      expect(log.length, 11);
      expect(log[0].text, '1000');
      expect(log.session, 2);
    });
  });

  group('TranslateService', () {
    late Settings settings;
    late SentLink link;
    late FakeTranscriber transcriber;
    late FakeTranslator translator;
    final clock = DateTime(2026, 10, 23, 13, 7);

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      settings = await Settings.load();
      link = SentLink();
      transcriber = FakeTranscriber();
      translator = FakeTranslator();
    });

    TranslateService make({PhotoReader? reader}) => TranslateService(
      link,
      settings,
      transcriber,
      translator,
      reader: reader,
      now: () => clock,
    );

    /// A photo the glasses send as glaz_photo.lua does, [from] its
    /// PHOTO_FROM byte.
    void photo(TranslateService t, {int from = photoForTranslate}) {
      t.onMessage([photoFrom, from]);
      t.onMessage([photoChunk, 0xFF, 0xD8]);
      t.onMessage([photoEnd, 0xFF, 0xD9]);
    }

    /// What went to apps/translate/translate.lua, in order.
    List<String> calls() => [
      for (final s in link.sent)
        if (s.$1 == moduleCall && s.$2.startsWith('translate\n'))
          s.$2.substring('translate\n'.length),
    ];

    List<String> pushes() => [
      for (final c in calls())
        if (c.startsWith('w:')) c,
    ];

    test('the tail asked for: the empty log', () {
      final t = make();
      t.onMessage(req(2, 0, 0, 4));
      expect(calls(), ['w:1:0:0:1']);
      expect(t.open && t.following, isTrue);
    });

    test('heard in the speaker\'s language, translated, pushed', () {
      fakeAsync((async) {
        settings.setConfig('translate', 'from', 'de');
        final t = make();
        t.onMessage(req(2, 0, 0, 4));
        t.onMessage([recStart, 16, 8, forTranslate]);
        async.flushMicrotasks();
        expect(transcriber.language, 'de-DE');
        expect(t.listening, isTrue);
        expect(pushes().last, 'w:1:0:1:1\nI|de > ru 13:07');
        // German is not on the phone yet
        expect(calls(), contains('s:downloading de>ru..'));
        expect(translator.downloads, ['de']);

        t.onMessage([audioChunk, 1, 2]);
        async.flushMicrotasks();
        async.elapse(TranslateService.pushGap);
        // FakeTranscriber hears each piece as its number
        expect(pushes().last, 'w:1:0:2:1\nI|de > ru 13:07\nT|[ru] 1');
        expect(transcriber.got, [1, 2]);

        t.onMessage([audioEnd]);
        async.flushMicrotasks();
        expect(t.listening, isFalse);
      });
    });

    test('a photo: its blocks translated from the language told', () {
      fakeAsync((async) {
        final reader = FakePhotoReader(['Ausgang', 'Kein Zutritt'], 'de');
        final t = make(reader: reader);
        t.onMessage(req(2, 0, 0, 4));
        photo(t);
        async.flushMicrotasks();
        async.elapse(TranslateService.pushGap);
        expect(reader.photos.single.take(2), [0xFF, 0xD8]);
        expect(reader.hints, ['en']); // the speaker's, for the script
        expect(translator.pairs, ['de>ru', 'de>ru']);
        expect(
          pushes().last,
          'w:1:0:3:1\nI|photo de > ru 13:07\nT|[ru] Ausgang\n'
          'T|[ru] Kein Zutritt',
        );
        expect(calls(), contains('s:reading photo..'));
        expect(t.status, '');
      });
    });

    test('a photo in a language not told: the speaker\'s', () {
      fakeAsync((async) {
        settings.setConfig('translate', 'from', 'fr');
        final t = make(reader: FakePhotoReader(['Sortie']));
        t.onMessage(req(2, 0, 0, 4));
        photo(t);
        async.flushMicrotasks();
        expect(translator.pairs, ['fr>ru']);
        expect(t.log[0].text, 'photo fr > ru 13:07');
      });
    });

    test('a photo with no text, or not read, says so', () {
      fakeAsync((async) {
        final reader = FakePhotoReader([]);
        final t = make(reader: reader);
        t.onMessage(req(2, 0, 0, 4));
        photo(t);
        async.flushMicrotasks();
        expect(t.log[0].text, 'photo 13:07: no text');
        expect(translator.pairs, isEmpty);

        reader.fail = true;
        photo(t);
        async.flushMicrotasks();
        expect(t.status, 'blurred');
        expect(t.log.length, 1);
      });
    });

    test('photos of other apps are not read', () {
      fakeAsync((async) {
        final reader = FakePhotoReader(['Exit']);
        final t = make(reader: reader);
        photo(t, from: 0);
        photo(t, from: 3);
        async.flushMicrotasks();
        expect(reader.photos, isEmpty);
        expect(t.log.length, 0);
      });
    });

    test('the original shown above, with source on', () {
      fakeAsync((async) {
        settings.setConfig('translate', 'source', 'on');
        final t = make();
        t.onMessage(req(2, 0, 0, 4));
        t.onMessage([recStart, 16, 8, forTranslate]);
        t.onMessage([audioChunk, 7]);
        async.flushMicrotasks();
        async.elapse(TranslateService.pushGap);
        expect(calls().last, endsWith('\nS|1\nT|[ru] 1'));
      });
    });

    test('pushes at most one a pushGap, the latest', () {
      fakeAsync((async) {
        final t = make();
        t.onMessage(req(2, 0, 0, 4));
        t.onMessage([recStart, 16, 8, forTranslate]);
        async.flushMicrotasks();
        final n = calls().length;
        t.log.info('a');
        t.clear();
        t.log.info('b');
        t.clear();
        async.elapse(
          TranslateService.pushGap - const Duration(milliseconds: 1),
        );
        expect(calls(), hasLength(n));
        async.elapse(const Duration(milliseconds: 1));
        expect(calls(), hasLength(n + 1));
        expect(calls().last, 'w:3:0:0:1');
        async.elapse(TranslateService.pushGap * 3);
        expect(calls(), hasLength(n + 1));
      });
    });

    test('reading back: the lines asked for, then only the count', () {
      fakeAsync((async) {
        final t = make();
        t.onMessage(req(2, 0, 0, 4));
        t.onMessage([recStart, 16, 8, forTranslate]);
        async.flushMicrotasks();
        t.onMessage(req(1, 1, 0, 8));
        expect(calls().last, 'w:1:0:1:0\nI|en > ru 13:07');
        expect(t.following, isFalse);
        final n = calls().length;
        t.onMessage([audioChunk, 1]);
        async.flushMicrotasks();
        async.elapse(TranslateService.countGap * 2);
        final after = calls().sublist(n);
        expect(after, isNotEmpty);
        expect(after.every((c) => c.startsWith('n:1:')), isTrue);
        expect(after.last, 'n:1:2');
      });
    });

    test('another session asked for: the tail, followed', () {
      final t = make();
      t.onMessage(req(1, 7, 0, 8));
      expect(calls(), ['w:1:0:0:1']);
      expect(t.following, isTrue);
    });

    test('closed: nothing more goes to the glasses', () {
      fakeAsync((async) {
        final t = make();
        t.onMessage(req(2, 0, 0, 4));
        t.onMessage([recStart, 16, 8, forTranslate]);
        async.flushMicrotasks();
        t.onMessage([audioEnd]);
        t.onMessage(req(0, 1, 0, 0));
        final n = link.sent.length;
        t.clear();
        t.onMessage([audioChunk, 1]);
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 5));
        expect(link.sent, hasLength(n));
        expect(t.open, isFalse);
      });
    });

    test('a model missing: downloading, then the status cleared', () {
      fakeAsync((async) {
        translator = FakeTranslator({'en'})..gate = Completer<void>();
        final t = make();
        t.onMessage(req(2, 0, 0, 4));
        t.onMessage([recStart, 16, 8, forTranslate]);
        async.flushMicrotasks();
        expect(calls(), contains('s:downloading en>ru..'));
        expect(t.status, 'downloading en>ru..');
        translator.gate!.complete();
        async.flushMicrotasks();
        expect(translator.downloads, ['ru']);
        expect(calls().last, 's:');
        expect(t.status, '');
      });
    });

    test('not translated: the original and why, in the log', () {
      fakeAsync((async) {
        translator.fail = true;
        final t = make();
        t.onMessage(req(2, 0, 0, 4));
        t.onMessage([recStart, 16, 8, forTranslate]);
        t.onMessage([audioChunk, 1]);
        async.flushMicrotasks();
        async.elapse(TranslateService.pushGap);
        expect(calls().last, endsWith('\nS|1\nE|not translated: no luck'));
      });
    });

    test('recognition ended by itself: started again, given up', () {
      fakeAsync((async) {
        final ending = EndingTranscriber();
        final t = TranslateService(link, settings, ending, translator);
        t.onMessage(req(2, 0, 0, 4));
        t.onMessage([recStart, 16, 8, forTranslate]);
        async.flushMicrotasks();
        for (var i = 1; i <= TranslateService.maxEmpty; i++) {
          expect(ending.going, hasLength(i));
          ending.going.last.stop();
          async.flushMicrotasks();
          async.elapse(TranslateService.restartGap);
        }
        expect(ending.going, hasLength(TranslateService.maxEmpty));
        expect(t.listening, isFalse);
        expect(calls().last, 'x:recognition failed');
      });
    });

    test('recognition ended quietly after a silence: only started again', () {
      fakeAsync((async) {
        var at = clock;
        final ending = EndingTranscriber();
        final t = TranslateService(
          link,
          settings,
          ending,
          translator,
          now: () => at,
        );
        t.onMessage(req(2, 0, 0, 4));
        t.onMessage([recStart, 16, 8, forTranslate]);
        async.flushMicrotasks();
        for (var i = 1; i <= TranslateService.maxEmpty * 2; i++) {
          expect(ending.going, hasLength(i));
          at = at.add(const Duration(seconds: 7));
          ending.going.last.stop();
          async.flushMicrotasks();
          async.elapse(TranslateService.restartGap);
        }
        expect(t.listening, isTrue);
        expect(calls().where((c) => c.startsWith('x:')), isEmpty);
      });
    });

    test('recognition starts once the permission and model are there', () {
      fakeAsync((async) {
        final gate = Completer<void>();
        transcriber = SlowTranscriber(gate.future)
          ..state = SpeechModel.downloadable;
        final t = make();
        t.onMessage(req(2, 0, 0, 4));
        t.onMessage([recStart, 16, 8, forTranslate]);
        t.onMessage([audioChunk, 1, 2]);
        async.flushMicrotasks();
        expect(transcriber.starts, 0);
        expect(t.listening, isTrue);
        gate.complete();
        async.flushMicrotasks();
        expect(transcriber.starts, 1);
        // the sound that came meanwhile is heard
        expect(transcriber.got, [1, 2]);
        async.elapse(TranslateService.pushGap);
        expect(pushes().last, endsWith('\nT|[ru] 1'));
      });
    });

    test('no speech for the language: the glasses stop sending', () {
      fakeAsync((async) {
        transcriber.state = SpeechModel.unavailable;
        final t = make();
        t.onMessage(req(2, 0, 0, 4));
        t.onMessage([recStart, 16, 8, forTranslate]);
        async.flushMicrotasks();
        expect(t.listening, isFalse);
        expect(transcriber.starts, 0);
        expect(calls().last, 'x:no speech for en');
      });
    });

    test('a piece is translated in the pair it was heard in', () {
      fakeAsync((async) {
        translator.gate = Completer<void>();
        translator.models.remove('ru');
        final t = make();
        t.onMessage(req(2, 0, 0, 4));
        t.onMessage([recStart, 16, 8, forTranslate]);
        async.flushMicrotasks();
        t.onMessage([audioChunk, 1]);
        t.onMessage([audioEnd]);
        async.flushMicrotasks();
        settings.setConfig('translate', 'to', 'de');
        t.onMessage([recStart, 16, 8, forTranslate]);
        translator.gate!.complete();
        async.flushMicrotasks();
        expect(translator.pairs.first, 'en>ru');
      });
    });

    test('the service off: the glasses are told', () {
      settings.setService('translate', false);
      final t = make();
      t.onMessage(req(2, 0, 0, 4));
      t.onMessage([recStart, 16, 8, forTranslate]);
      expect(calls().last, 'x:Translate is off on phone');
      expect(t.listening, isFalse);
      expect(transcriber.starts, 0);
    });

    test('nothing sent before the glasses open it', () {
      fakeAsync((async) {
        final t = make();
        t.onMessage([recStart, 16, 8, forTranslate]);
        t.onMessage([audioChunk, 1]);
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 2));
        expect(link.sent, isEmpty);
        expect(t.log.length, 2);
      });
    });

    test('another app\'s sound is not heard', () {
      fakeAsync((async) {
        final t = make();
        t.onMessage(req(2, 0, 0, 4));
        t.onMessage([recStart, 16, 8, forTranslate]);
        t.onMessage([recStart, 16, 8, forAssistant]);
        t.onMessage([audioChunk, 1]);
        async.flushMicrotasks();
        expect(t.listening, isFalse);
        expect(transcriber.got, isEmpty);
      });
    });
  });

  group('the others leave Translate\'s sound alone', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('Recorder keeps no recording of it', () async {
      final settings = await Settings.load();
      final recorder = RecorderService(
        SentLink(),
        settings,
        RecordingStore(Directory.systemTemp.createTempSync('glaz_tr')),
      );
      recorder.onMessage([recStart, 16, 8, forTranslate]);
      expect(recorder.recording, isFalse);
    });

    test('the assistant drops its question for it', () async {
      final settings = await Settings.load();
      final agent = FakeAgent('OK');
      final assistant = AssistantService(
        SentLink(),
        settings,
        FakeTranscriber(),
        agent: (_) => agent,
      );
      assistant.onMessage([recStart, 16, 8, forAssistant]);
      expect(assistant.state, AssistantState.listening);
      assistant.onMessage([recStart, 16, 8, forTranslate]);
      expect(assistant.state, AssistantState.idle);
      assistant.onMessage([audioChunk, 1, 2]);
      assistant.onMessage([audioEnd]);
      await pumpEventQueue();
      expect(agent.asked, isEmpty);
    });
  });
}
