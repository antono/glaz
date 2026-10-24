import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_language_id/google_mlkit_language_id.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';
import 'package:path_provider/path_provider.dart';

import '../frame/font.dart';
import '../frame/glyphs.dart';
import '../frame/link.dart';
import '../frame/protocol.dart';
import '../settings.dart';
import 'glaz_log.dart';
import 'photos.dart';
import 'speech.dart';

/// A language Translate hears or writes: [value] as the setting holds it,
/// [speech] the recognizer's tag (speechLanguages), [mlkit] ML Kit
/// Translation's code.
class TrLanguage {
  const TrLanguage(
    this.value,
    this.speech,
    this.mlkit,
    this.label, {
    this.shown = true,
  });
  final String value, speech, mlkit, label;

  /// The glasses' font draws it: ASCII, Latin-1, Cyrillic.
  final bool shown;
}

/// What both the recognizer (speechLanguages) and ML Kit Translation have.
/// Those not [TrLanguage.shown] can be heard, not shown: their letters
/// would be '?' on the glasses, or lose their marks (Vietnamese).
const translateLanguages = <TrLanguage>[
  TrLanguage('en', 'en-US', 'en', 'English'),
  TrLanguage('ru', 'ru-RU', 'ru', 'Русский'),
  TrLanguage('de', 'de-DE', 'de', 'Deutsch'),
  TrLanguage('fr', 'fr-FR', 'fr', 'Français'),
  TrLanguage('es', 'es-ES', 'es', 'Español'),
  TrLanguage('it', 'it-IT', 'it', 'Italiano'),
  TrLanguage('pt', 'pt-BR', 'pt', 'Português'),
  TrLanguage('pl', 'pl-PL', 'pl', 'Polski'),
  TrLanguage('tr', 'tr-TR', 'tr', 'Türkçe'),
  TrLanguage('vi', 'vi-VN', 'vi', 'Tiếng Việt', shown: false),
  TrLanguage('hi', 'hi-IN', 'hi', 'हिन्दी', shown: false),
  TrLanguage('ja', 'ja-JP', 'ja', '日本語', shown: false),
  TrLanguage('ko', 'ko-KR', 'ko', '한국어', shown: false),
  TrLanguage('zh', 'cmn-Hans-CN', 'zh', '中文 (简体)', shown: false),
  TrLanguage('zh-TW', 'cmn-Hant-TW', 'zh', '中文 (繁體)', shown: false),
];

// The same, as the const lists glasses_menu.dart's settings need; a test
// keeps them equal to translateLanguages.
const trFromValues = [
  'en', 'ru', 'de', 'fr', 'es', 'it', 'pt', 'pl', 'tr', //
  'vi', 'hi', 'ja', 'ko', 'zh', 'zh-TW',
];
const trFromLabels = [
  'English', 'Русский', 'Deutsch', 'Français', 'Español', 'Italiano', //
  'Português', 'Polski', 'Türkçe', 'Tiếng Việt', 'हिन्दी', '日本語', //
  '한국어', '中文 (简体)', '中文 (繁體)',
];
const trToValues = ['en', 'ru', 'de', 'fr', 'es', 'it', 'pt', 'pl', 'tr'];
const trToLabels = [
  'English', 'Русский', 'Deutsch', 'Français', 'Español', 'Italiano', //
  'Português', 'Polski', 'Türkçe',
];

TrLanguage? trLanguage(String value) {
  for (final l in translateLanguages) {
    if (l.value == value) return l;
  }
  return null;
}

List<String> get translateFrom => [for (final l in translateLanguages) l.value];
List<String> get translateTo => [
  for (final l in translateLanguages)
    if (l.shown) l.value,
];

/// What a line of the log is; [wire] its letter for modules/translate.lua.
enum TrKind {
  translation('T'),
  source('S'),
  partial('P'),
  info('I'),
  error('E');

  const TrKind(this.wire);
  final String wire;
}

/// One line of the log, as the glasses draw it.
class TrLine {
  const TrLine(this.kind, this.text);
  final TrKind kind;
  final String text;

  String get wire => '${kind.wire}|$text';
}

/// What was heard as one final piece, waiting for its translation:
/// [lines] are what the glasses show for it meanwhile, then what it
/// became.
class _Segment {
  _Segment(this.id, this.source, this.lines, {this.done = false});
  final int id;
  final String source;
  List<TrLine> lines;
  bool done;
}

/// Everything Translate has heard and translated, as lines for the
/// glasses: wrapped to [width] px, in what their font has. The lines of a
/// segment still being translated come after those that are done, and
/// what is being heard now is the last line; so only the end of the log
/// ever changes, and a line's number before it stays what it is.
class TranslateLog {
  TranslateLog({this.maxLines = 5000});

  /// More than this many lines and the oldest [drop] go.
  final int maxLines;
  static const drop = 1000;

  /// As gemini.dart's lineWidth: from where modules/translate.lua draws
  /// text to the screen's right edge, less a little.
  static const width = 530;

  /// The log the glasses hold lines of, 1..255: another one when lines
  /// before theirs went, so they take it from the end again.
  int session = 1;

  final _frozen = <TrLine>[];
  final _pending = <_Segment>[];
  TrLine? _partial;
  List<TrLine>? _tail;
  int _next = 0;

  List<TrLine> get _end =>
      _tail ??= [for (final s in _pending) ...s.lines, ?_partial];

  int get length => _frozen.length + _end.length;

  TrLine operator [](int i) =>
      i < _frozen.length ? _frozen[i] : _end[i - _frozen.length];

  static List<TrLine> _wrap(TrKind kind, String text) => [
    for (final l in wrapToWidth(forGlasses(text), width)) TrLine(kind, l),
  ];

  /// A line of its own: which languages, when.
  void info(String text) => _add(_wrap(TrKind.info, text));

  /// What is being heard now; '' when it is gone. Only its last line is
  /// shown: the rest changes as it is heard.
  void partial(String text) {
    final lines = _wrap(TrKind.partial, text);
    _partial = lines.isEmpty ? null : lines.last;
    _tail = null;
  }

  /// A piece heard to the end, shown as it was heard until [translated] or
  /// [failed] says what it became; its number for those.
  int heard(String source) {
    final id = _next++;
    _pending.add(_Segment(id, source, _wrap(TrKind.partial, source)));
    _tail = null;
    return id;
  }

  /// Piece [id] translated as [text]; [withSource]: what was heard above
  /// it, dimmed.
  void translated(int id, String text, {required bool withSource}) => _done(
    id,
    (source) => [
      if (withSource) ..._wrap(TrKind.source, source),
      ..._wrap(TrKind.translation, text),
    ],
  );

  /// Piece [id] could not be translated, for [why]: what was heard, and why.
  void failed(int id, String source, String why) => _done(
    id,
    (source) => [
      ..._wrap(TrKind.source, source),
      ..._wrap(TrKind.error, 'not translated: $why'),
    ],
  );

  void _done(int id, List<TrLine> Function(String source) lines) {
    final s = _pending.where((s) => s.id == id).firstOrNull;
    if (s == null) return; // cleared since
    s
      ..lines = lines(s.source)
      ..done = true;
    _tail = null;
    // done in the order heard: those before it waiting keep it out of the
    // part that no longer changes
    while (_pending.isNotEmpty && _pending.first.done) {
      _frozen.addAll(_pending.removeAt(0).lines);
    }
    _trim();
  }

  void _add(List<TrLine> lines) {
    if (_pending.isEmpty) {
      _frozen.addAll(lines);
      _trim();
    } else {
      _pending.add(_Segment(-1, '', lines, done: true));
    }
    _tail = null;
  }

  void _trim() {
    if (length <= maxLines) return;
    _frozen.removeRange(0, drop < _frozen.length ? drop : _frozen.length);
    _bump();
  }

  void _bump() => session = session % 255 + 1;

  /// Empty again, as another log.
  void clear() {
    _frozen.clear();
    _pending.clear();
    _partial = null;
    _tail = null;
    _bump();
  }

  /// MODULE_CALL's argument for modules/translate.lua
  /// (docs/PROTOCOL.md, "Translate"): 'w:sess:from:total:f' and a line each
  /// from [from], at most [count] and [maxLines], as many as fit in
  /// [maxBytes]. [follow]: the last [count], for the glasses following
  /// the end.
  String window(
    int from,
    int count, {
    required bool follow,
    int maxBytes = 900,
    int maxLines = 16,
  }) {
    final total = length;
    final n = count.clamp(1, maxLines);
    final start = (follow ? total - n : from).clamp(0, total);
    final out = StringBuffer('w:$session:$start:$total:${follow ? 1 : 0}');
    var bytes = out.length;
    for (var i = start; i < total && i < start + n; i++) {
      final l = '\n${this[i].wire}';
      final size = utf8.encode(l).length;
      if (bytes + size > maxBytes) break;
      out.write(l);
      bytes += size;
    }
    return out.toString();
  }

  /// 'n:sess:total', for glasses that read back and only want to know.
  String get counted => 'n:$session:$length';
}

/// Text to text, on the phone; ML Kit's, or a fake in tests. Languages
/// by [TrLanguage.mlkit].
abstract class Translator {
  /// The one this platform has; null where there is none.
  static Translator? get platform =>
      !kIsWeb && Platform.isAndroid ? MlKitTranslator() : null;

  Future<bool> hasModel(String mlkit);

  /// Gets [mlkit]'s model onto the phone; throws if it could not.
  Future<void> download(String mlkit);

  Future<String> translate(String text, String from, String to);
}

/// ML Kit's on-device translation: nothing leaves the phone once the two
/// languages' models are on it. They download over any network, not only
/// Wi-Fi: they are wanted where the wearer is.
class MlKitTranslator extends Translator {
  final _models = OnDeviceTranslatorModelManager();
  OnDeviceTranslator? _t;
  String? _pair;

  static TranslateLanguage _lang(String code) =>
      TranslateLanguage.values.firstWhere((l) => l.bcpCode == code);

  @override
  Future<bool> hasModel(String mlkit) => _models.isModelDownloaded(mlkit);

  @override
  Future<void> download(String mlkit) async {
    if (!await _models.downloadModel(mlkit, isWifiRequired: false)) {
      throw StateError('download failed');
    }
  }

  @override
  Future<String> translate(String text, String from, String to) async {
    final pair = '$from>$to';
    if (_t == null || _pair != pair) {
      await _t?.close();
      _t = OnDeviceTranslator(
        sourceLanguage: _lang(from),
        targetLanguage: _lang(to),
      );
      _pair = pair;
    }
    return _t!.translateText(text);
  }
}

/// The text on a photo, on the phone; ML Kit's, or a fake in tests.
abstract class PhotoReader {
  /// The one this platform has; null where there is none.
  static PhotoReader? get platform =>
      !kIsWeb && Platform.isAndroid ? MlKitPhotoReader() : null;

  /// The blocks of text on [jpeg] (Exif says how it is turned), each as
  /// one line, top to bottom; [hint]: the language it is likely in, for
  /// its script.
  Future<List<String>> read(Uint8List jpeg, TrLanguage hint);

  /// [text]'s language as ML Kit Translation's code; null when unsure.
  Future<String?> language(String text);
}

/// ML Kit's text recognition and language identification, on the phone.
/// No Cyrillic: ML Kit reads Latin, Chinese, Devanagari, Japanese and
/// Korean, and the script is picked by the language the photo is likely
/// in (the speaker's, Glaz > Menu > Translate); the others read Latin too.
class MlKitPhotoReader extends PhotoReader {
  static TextRecognitionScript _script(TrLanguage l) => switch (l.mlkit) {
    'zh' => TextRecognitionScript.chinese,
    'ja' => TextRecognitionScript.japanese,
    'ko' => TextRecognitionScript.korean,
    'hi' => TextRecognitionScript.devanagiri,
    _ => TextRecognitionScript.latin,
  };

  @override
  Future<List<String>> read(Uint8List jpeg, TrLanguage hint) async {
    // ML Kit reads a file, and turns it as its Exif says
    final file = File('${(await getTemporaryDirectory()).path}/translate.jpg');
    await file.writeAsBytes(jpeg, flush: true);
    final r = TextRecognizer(script: _script(hint));
    try {
      final text = await r.processImage(InputImage.fromFilePath(file.path));
      return [
        for (final b in text.blocks)
          if (b.text.trim().isNotEmpty)
            b.text.replaceAll(RegExp(r'\s+'), ' ').trim(),
      ];
    } finally {
      await r.close();
      file.delete().catchError((_) => file);
    }
  }

  @override
  Future<String?> language(String text) async {
    final id = LanguageIdentifier(confidenceThreshold: 0.5);
    try {
      final code = await id.identifyLanguage(text);
      return code == id.undeterminedLanguageCode ? null : code;
    } finally {
      await id.close();
    }
  }
}

/// Calls [send] at once, then at most once a [gap]: what comes meanwhile
/// is sent once when the gap is over, as it is then.
class _Pace {
  _Pace(this.gap, this.send);
  final Duration gap;
  final void Function() send;
  Timer? _cool;
  bool _again = false;

  void call() {
    if (_cool != null) {
      _again = true;
      return;
    }
    send();
    _cool = Timer(gap, () {
      _cool = null;
      if (_again) {
        _again = false;
        call();
      }
    });
  }

  void cancel() {
    _cool?.cancel();
    _cool = null;
    _again = false;
  }
}

/// Translate's phone side (docs/PROTOCOL.md, "Translate"): modules/
/// translate.lua streams what the glasses hear, the recognizer here writes
/// down what the other speaker says, ML Kit translates each piece on the
/// phone, and the glasses get the log a few lines at a time. A photo they
/// take for it (PHOTO_FROM 255) is read here, and its text translated into
/// the same log, a piece a block. Only while
/// the glasses have Translate open does anything go to them: a
/// MODULE_CALL would start it in the background otherwise.
class TranslateService extends ChangeNotifier {
  TranslateService(
    this.link,
    this.settings,
    this.transcriber,
    this.translator, {
    this.reader,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    _push = _Pace(pushGap, () {
      if (open && following) {
        link.send(
          moduleCall,
          utf8.encode('translate\n${log.window(0, tailCount, follow: true)}'),
          log: false,
        );
      }
    });
    _count = _Pace(countGap, () {
      if (open && !following) {
        link.send(
          moduleCall,
          utf8.encode('translate\n${log.counted}'),
          log: false,
        );
      }
    });
    _progress = _Pace(countGap, () {
      if (_progressText != null) _status(_progressText!, progress: true);
    });
    link.events
        .where(
          (m) =>
              m.isNotEmpty &&
              (m[0] == translate ||
                  m[0] == recStart ||
                  m[0] == audioChunk ||
                  m[0] == audioEnd ||
                  m[0] == photoFrom ||
                  m[0] == photoChunk ||
                  m[0] == photoEnd),
        )
        .listen(onMessage);
    link.addListener(() {
      if (!link.connected) _gone();
    });
  }

  final FrameLink link;
  final Settings settings;

  /// Null where the phone has no speech recognition.
  final Transcriber? transcriber;

  /// Null where the phone cannot translate: what is heard is shown as it
  /// was heard.
  final Translator? translator;

  /// Null where the phone cannot read a photo.
  final PhotoReader? reader;
  final DateTime Function() _now;

  final log = TranslateLog();

  /// At most one push of the log's end this often while the glasses
  /// follow it, and one count while they read back.
  static const pushGap = Duration(milliseconds: 350);
  static const countGap = Duration(seconds: 1);

  /// After this long without a line, a new info line says when it goes on.
  static const forget = Duration(minutes: 10);

  /// Recognition ended by itself is started again, at most once this
  /// often, and given up after [maxEmpty] goes in a row that went wrong, or
  /// ended in less than [quickEnd], having heard nothing. One that ended
  /// quietly after a silence only starts again.
  static const restartGap = Duration(seconds: 2);
  static const maxEmpty = 3;
  static const quickEnd = Duration(seconds: 1);

  /// The sound kept while the speech model is being made ready, at most
  /// this many seconds of it: it is heard once recognition starts.
  static const earlySeconds = 2;

  /// The glasses have Translate open: from their first request to CLOSE.
  bool open = false;

  /// They show the log's end and want it pushed as it grows.
  bool following = false;

  /// Their sound is being heard.
  bool listening = false;

  /// Lines a push carries: the glasses' own window.
  int tailCount = 4;

  /// What the glasses' status row says, from the phone; '' for nothing.
  String status = '';
  String _shown = '';

  late final _Pace _push, _count, _progress;
  String? _progressText;

  Transcription? _tr;
  StreamSubscription<Heard>? _heardSub;
  Future<void> _feed = Future.value();
  Future<void> _queue = Future.value();
  Future<void> _ready = Future.value();
  int _run = 0;
  List<List<int>>? _early;
  int _earlyBytes = 0;
  int _rate = 8000;
  int _bits = 16;
  TrLanguage _from = trLanguage('en')!;
  TrLanguage _to = trLanguage('ru')!;
  String? _pair;
  String? _missing;
  DateTime _lastAt = DateTime(0);
  DateTime _startedAt = DateTime(0);
  bool _heardAny = false;
  int _empty = 0;
  Timer? _restart;
  bool _toldNoTranslator = false;
  BytesBuilder? _photo; // a photo of Translate's coming in; null when not
  Future<void> _reading = Future.value();

  TrLanguage get _fromSetting =>
      trLanguage(settings.config('translate', 'from') ?? 'en') ??
      trLanguage('en')!;

  TrLanguage get _toSetting {
    final l = trLanguage(settings.config('translate', 'to') ?? 'ru');
    return l != null && l.shown ? l : trLanguage('ru')!;
  }

  bool get _withSource => settings.config('translate', 'source') == 'on';

  @visibleForTesting
  void onMessage(List<int> m) {
    if (m.isEmpty) return;
    switch (m[0]) {
      case translate:
        _request(m);
      case recStart:
        if (m.length > 3 && m[3] == forTranslate) {
          _listen(
            m.length > 1 && m[1] == 16 ? 16 : 8,
            m.length > 2 && m[2] > 0 ? m[2] * 1000 : 8000,
          );
        } else if (listening) {
          // another app's sound from now on
          listening = false;
          _stop();
          notifyListeners();
        }
      case audioChunk:
        if (listening) _add(m.sublist(1));
      case audioEnd:
        if (!listening) return;
        _add(m.sublist(1));
        listening = false;
        _early = null;
        _restart?.cancel();
        // let go of, not dropped: what is still being heard comes into the
        // log as it is, even after listening goes on with another
        final tr = _tr;
        _tr = null;
        _heardSub = null;
        if (tr != null) {
          _feed = _feed.then((_) => tr.finish()).catchError((_) {});
        }
        notifyListeners();
      case photoFrom:
        // another photo begins: Translate's, or one PhotoService keeps
        _photo = m.length > 1 && m[1] == photoForTranslate
            ? BytesBuilder(copy: false)
            : null;
      case photoChunk:
        _photo?.add(m.sublist(1));
      case photoEnd:
        final photo = _photo;
        if (photo == null) return;
        _photo = null;
        photo.add(m.sublist(1));
        final jpeg = photo.takeBytes();
        // one at a time, in the order taken
        _reading = _reading.then((_) => _read(jpeg)).catchError((_) {});
    }
  }

  /// Reads the text on a photo the glasses took for Translate and puts it
  /// in the log: a line saying which languages, then each block of text,
  /// translated as a piece heard is. Its language is told from the text;
  /// the speaker's (setting 'from') when that cannot be.
  Future<void> _read(Uint8List jpeg) async {
    if (!settings.serviceOn('translate')) {
      _status('Translate is off on phone');
      return;
    }
    final r = reader;
    if (r == null) {
      _status('no text recognition');
      return;
    }
    final hint = _fromSetting, to = _toSetting;
    final at = _now();
    _status('reading photo..');
    List<String> blocks;
    try {
      blocks = await r.read(withOrientation(jpeg), hint);
    } catch (e) {
      glazLog(LogKind.translate, 'photo not read: $e', problem: true);
      _status(_short(e));
      return;
    }
    if (blocks.isEmpty) {
      log.info('photo ${_hm(at)}: no text');
      _status('');
      _changed();
      return;
    }
    String? code;
    try {
      code = await r.language(blocks.join('\n'));
    } catch (e) {
      glazLog(LogKind.translate, 'photo language: $e', problem: true);
    }
    final from =
        translateLanguages.where((l) => l.mlkit == code).firstOrNull ?? hint;
    glazLog(LogKind.translate, 'photo: ${blocks.length} blocks, ${from.value}');
    log.info('photo ${from.value} > ${to.value} ${_hm(at)}');
    _pair = null; // listening again says its languages again
    final ready = _translationModels(from, to);
    for (final b in blocks) {
      final id = log.heard(b);
      _queue = _queue.then((_) => _translate(id, b, from, to, ready));
    }
    _changed();
  }

  /// [0x0F, op, sess, from (2), count]: 0 close, 1 lines from `from`,
  /// 2 the last `count` and follow.
  void _request(List<int> m) {
    if (m.length < 6) return;
    final op = m[1];
    final sess = m[2];
    final from = m[3] << 8 | m[4];
    final count = m[5].clamp(1, 16);
    switch (op) {
      case 0:
        open = false;
        following = false;
        _push.cancel();
        _count.cancel();
        _progress.cancel();
        notifyListeners();
        return;
      case 1 || 2:
        if (!open) {
          open = true;
          _shown = ''; // the glasses start with an empty status row
        }
        if (op == 2) tailCount = count;
        if (op == 2 || sess != log.session) {
          // their log is another: the end of this one
          following = true;
          link.callModule('translate', log.window(0, count, follow: true));
        } else {
          following = false;
          link.callModule('translate', log.window(from, count, follow: false));
        }
        if (status != _shown) {
          _shown = status;
          link.callModule('translate', 's:$status');
        }
        notifyListeners();
      default:
        // 3 the phone's microphone, 4 a photo: not yet
        return;
    }
  }

  void _listen(int bits, int rate) {
    _restart?.cancel();
    _stop();
    listening = false;
    if (!settings.serviceOn('translate')) {
      _give('Translate is off on phone');
      return;
    }
    if (transcriber == null) {
      _give('no speech recognition');
      return;
    }
    _bits = bits;
    _rate = rate;
    _from = _fromSetting;
    _to = _toSetting;
    final pair = '${_from.value} > ${_to.value}';
    final now = _now();
    if (log.length == 0 || pair != _pair || now.difference(_lastAt) > forget) {
      log.info('$pair ${_hm(now)}');
    }
    _pair = pair;
    _lastAt = now;
    listening = true;
    _empty = 0;
    // recognition starts once the permission and the speech model are
    // there; the sound meanwhile is kept, a little of it
    final run = ++_run;
    _early = [];
    _earlyBytes = 0;
    _ready = _prepare(
      _from,
      _to,
      speech: (why) {
        if (run != _run || !listening) return;
        final early = _early ?? const <List<int>>[];
        _early = null;
        if (why != null) {
          _give(why);
          return;
        }
        if (_tr == null) _start();
        for (final c in early) {
          _add(c);
        }
      },
    );
    _changed();
  }

  /// Listening is over on the phone, for [why]: the glasses stop sending
  /// their sound ('x:').
  void _give(String why) {
    listening = false;
    _restart?.cancel();
    _stop();
    _status(why, stop: true);
    notifyListeners();
  }

  static String _hm(DateTime t) =>
      '${'${t.hour}'.padLeft(2, '0')}:${'${t.minute}'.padLeft(2, '0')}';

  void _start() {
    // the pair it was heard in, and its models: those of a later listen
    // are not this one's
    final from = _from, to = _to, ready = _ready;
    final tr = _tr = transcriber!.start(_from.speech);
    _heardAny = false;
    _startedAt = _now();
    _heardSub = tr.heard.listen((h) {
      if (h.partial) {
        log.partial(h.text);
      } else {
        log.partial('');
        final text = h.text.trim();
        if (text.isNotEmpty) {
          _heardAny = true;
          _empty = 0;
          _lastAt = _now();
          glazLog(LogKind.translate, 'heard: $text');
          final id = log.heard(text);
          _queue = _queue.then((_) => _translate(id, text, from, to, ready));
        }
      }
      _changed();
    });
    tr.done.then((_) => _ended(tr), onError: (Object e) => _ended(tr, e));
  }

  /// [tr] is over: the sound ended, or the recognizer stopped by itself
  /// while the glasses still send it, and then it is started again.
  void _ended(Transcription tr, [Object? error]) {
    if (error != null) {
      glazLog(LogKind.translate, 'recognition: $error', problem: true);
    }
    if (tr != _tr) return;
    _tr = null;
    _heardSub = null; // its stream is closed
    log.partial('');
    _changed();
    if (!listening) return;
    final quick = _now().difference(_startedAt) < quickEnd;
    if (!_heardAny && (error != null || quick) && ++_empty >= maxEmpty) {
      _give('recognition failed');
      return;
    }
    final wait = restartGap - _now().difference(_startedAt);
    _restart = Timer(wait.isNegative ? Duration.zero : wait, () {
      if (listening && _tr == null) _start();
    });
  }

  void _add(List<int> samples) {
    final tr = _tr;
    if (samples.isEmpty) return;
    final early = _early;
    if (tr == null && early != null) {
      if (_earlyBytes + samples.length <= _rate * _bits ~/ 8 * earlySeconds) {
        early.add(samples);
        _earlyBytes += samples.length;
      }
      return;
    }
    if (tr == null) return;
    _feed = _feed
        .then((_) => tr.add(samples, rate: _rate, bits: _bits))
        .catchError((_) {});
  }

  /// Drops the transcription going on, quietly.
  void _stop() {
    _early = null;
    _heardSub?.cancel();
    _heardSub = null;
    final tr = _tr;
    _tr = null;
    if (tr != null) tr.cancel().catchError((_) {});
    log.partial('');
  }

  /// The glasses gone: nothing goes to them until they open it again.
  void _gone() {
    if (!open && !listening && _tr == null) return;
    open = false;
    following = false;
    listening = false;
    _restart?.cancel();
    _push.cancel();
    _count.cancel();
    _progress.cancel();
    _stop();
    notifyListeners();
  }

  /// Gets the models onto the phone: speech for [from], translation for
  /// both, saying so on the glasses as it goes. [speech] is called once
  /// the speech part is over: with null when recognition can start, or
  /// why it cannot. A translation model missing only fails the pieces.
  Future<void> _prepare(
    TrLanguage from,
    TrLanguage to, {
    required void Function(String? why) speech,
  }) async {
    _missing = null;
    final t = transcriber!;
    try {
      await t.permit();
      var m = await t.model(from.speech);
      if (m == SpeechModel.downloadable || m == SpeechModel.downloading) {
        _status('speech ${from.value} 0%');
        await t.download(
          from.speech,
          progress: (got, total) {
            if (total > 0) {
              _stepped('speech ${from.value} ${got * 100 ~/ total}%');
            }
          },
        );
        _progressText = null;
        m = await t.model(from.speech);
      }
      if (m == SpeechModel.unavailable) {
        speech('no speech for ${from.value}');
        return;
      }
    } catch (e) {
      _progressText = null;
      glazLog(LogKind.translate, 'no speech: $e', problem: true);
      speech(_short(e));
      return;
    }
    speech(null);
    await _translationModels(from, to);
  }

  /// Gets the translation models for [from] and [to] onto the phone,
  /// saying so on the glasses as it goes; a failure only says why.
  Future<void> _translationModels(TrLanguage from, TrLanguage to) async {
    _missing = null;
    try {
      final tr = translator;
      if (tr != null && from.mlkit != to.mlkit) {
        for (final code in {from.mlkit, to.mlkit}) {
          if (await tr.hasModel(code)) continue;
          _status('downloading ${from.value}>${to.value}..');
          try {
            await tr.download(code);
          } catch (_) {
            _missing = 'no ${from.value}>${to.value} model';
            rethrow;
          }
        }
      }
      _status('');
    } catch (e) {
      _progressText = null;
      glazLog(LogKind.translate, 'not ready: $e', problem: true);
      _status(_short(e));
    }
  }

  Future<void> _translate(
    int id,
    String text,
    TrLanguage from,
    TrLanguage to,
    Future<void> ready,
  ) async {
    final t = translator;
    if (from.mlkit == to.mlkit || t == null) {
      if (t == null && from.mlkit != to.mlkit && !_toldNoTranslator) {
        _toldNoTranslator = true;
        _status('no translation on phone');
      }
      log.translated(id, text, withSource: false);
    } else {
      try {
        await ready;
        final out = await t.translate(text, from.mlkit, to.mlkit);
        glazLog(LogKind.translate, 'translated: $out');
        log.translated(id, out, withSource: _withSource);
      } catch (e) {
        glazLog(LogKind.translate, 'not translated: $e', problem: true);
        log.failed(id, text, _missing ?? _short(e));
      }
    }
    _changed();
  }

  static String _short(Object e) {
    var s = e is PlatformException ? (e.message ?? e.code) : '$e';
    s = s
        .replaceFirst(RegExp(r'^(Bad state|Exception|StateError): '), '')
        .split('\n')
        .first
        .trim();
    return s.length > 40 ? s.substring(0, 40) : s;
  }

  /// The log changed: on the phone's screen, and to the glasses at the
  /// pace they take it.
  void _changed() {
    notifyListeners();
    if (!open) return;
    following ? _push() : _count();
  }

  /// A step of a download: at most one a second to the glasses.
  void _stepped(String text) {
    _progressText = text;
    _progress();
  }

  /// The glasses' status row, when it changes and they have Translate open.
  /// [stop]: the phone no longer hears them, and they stop sending ('x:',
  /// sent even when the text is the same).
  void _status(String text, {bool progress = false, bool stop = false}) {
    if (!progress) {
      _progressText = null;
      _progress.cancel();
    }
    final t = forGlasses(text);
    final cut = t.length > 30 ? t.substring(0, 30) : t;
    if (cut == status && !stop) return;
    status = cut;
    notifyListeners();
    if (open && (stop || cut != _shown)) {
      _shown = cut;
      link.callModule('translate', '${stop ? 'x' : 's'}:$cut');
    }
  }

  /// A new, empty log; the glasses take it from its end.
  void clear() {
    log.clear();
    _changed();
  }

  @override
  void dispose() {
    _restart?.cancel();
    _push.cancel();
    _count.cancel();
    _progress.cancel();
    _stop();
    super.dispose();
  }
}
