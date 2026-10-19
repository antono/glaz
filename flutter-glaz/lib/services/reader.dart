import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../frame/ascii.dart';
import '../frame/link.dart';
import '../frame/protocol.dart';
import '../settings.dart';

/// The longest piece of a word the glasses show at once, hyphen included:
/// with the pivot letter at a third of the screen, longer runs off its
/// right edge (modules/reader.lua).
const maxPiece = 13;

/// TEXT_GET's from: wherever the phone says the place is.
const resumeFrom = 0xFFFFFFFF;

/// The text as the glasses show it, a word at a time: ASCII, and a word
/// longer than [maxPiece] cut into pieces of about equal length, each but
/// the last ending in '-'. A hyphenated word is cut at its own hyphens
/// first.
List<String> readerWords(String text) => [
  for (final w in toAscii(text).split(RegExp(r'\s+')))
    if (w.isNotEmpty) ...splitWord(w),
];

List<String> splitWord(String word, {int max = maxPiece}) {
  if (word.length <= max) return [word];
  // 'state-of-the-art' -> 'state-of-', 'the-art': its own hyphens first,
  // as many segments to a piece as fit
  final pieces = <String>[];
  var piece = '';
  for (final m in RegExp(r'[^-]+-*|-+').allMatches(word)) {
    final seg = m[0]!;
    if (piece.isNotEmpty && piece.length + seg.length > max) {
      pieces.add(piece);
      piece = '';
    }
    piece += seg;
  }
  if (piece.isNotEmpty) pieces.add(piece);
  return [for (final p in pieces) ..._evenly(p, max)];
}

// 'extraordinarily' -> 'extraord-', 'inarily': equal parts, so neither is
// a stub, each with its hyphen at most max long.
List<String> _evenly(String word, int max) {
  if (word.length <= max) return [word];
  final n = (word.length + max - 2) ~/ (max - 1);
  final size = (word.length + n - 1) ~/ n;
  return [
    for (var i = 0; i < word.length; i += size)
      i + size < word.length
          ? '${word.substring(i, i + size)}-'
          : word.substring(i),
  ];
}

/// Where the Reader's text is kept: the app's own folder, as the settings.
Future<File> readerText() async =>
    File('${(await getApplicationSupportDirectory()).path}/reader.txt');

/// Keeps the Reader's text and its place in it, and feeds the glasses a
/// few dozen words at a time as they ask (TEXT_GET, docs/PROTOCOL.md,
/// "Reader"): the glasses have no room for a book.
class ReaderService extends ChangeNotifier {
  ReaderService(this.link, this.settings, this.file) {
    link.events.where((m) => m.isNotEmpty && m[0] == textGet).listen(onRequest);
  }

  final FrameLink link;
  final Settings settings;

  /// Where the text is kept, as the user gave it.
  final File file;

  /// At most this much text in one answer: a MODULE_CALL the glasses
  /// put together in memory.
  static const maxBytes = 900;

  String _text = '';
  List<String> _words = const [];

  String get text => _text;
  List<String> get words => _words;

  /// The number of the word the glasses showed last.
  int get place => min(settings.readerPlace, max(0, _words.length - 1));

  Future<void> load() async {
    try {
      if (await file.exists()) _take(await file.readAsString());
    } catch (_) {}
  }

  void _take(String text) {
    _text = text;
    _words = readerWords(text);
    notifyListeners();
  }

  /// A new text, read from the start.
  Future<void> setText(String text) async {
    _take(text);
    settings.readerPlace = 0;
    try {
      await file.writeAsString(text);
    } catch (_) {}
  }

  /// Back to the start of the text.
  void restart() {
    settings.readerPlace = 0;
    notifyListeners();
  }

  /// Puts the Reader on the glasses' screen, starting again from the
  /// place: with a new text, the start.
  Future<void> openOnGlasses() => link.openModule('reader', 'new');

  /// [0x0A, place (4), from (4), count, wpm (2)], big-endian: the glasses'
  /// place and speed, and count words wanted from word number from --
  /// [resumeFrom] for the place; none, when they only say where they are.
  @visibleForTesting
  Future<void> onRequest(List<int> m) async {
    if (m.length < 12) return;
    final b = ByteData.sublistView(Uint8List.fromList(m));
    final at = b.getUint32(1);
    final from = b.getUint32(5);
    final count = b.getUint8(9);
    final wpm = b.getUint16(10);
    // the place is the glasses' own unless they ask where it is
    if (from != resumeFrom && at < _words.length) settings.readerPlace = at;
    notifyListeners();
    if (count == 0) {
      // paused or left: the speed tilted to is kept as the setting. Not
      // from a request for words: one sent before the glasses had a
      // speed picked here would undo it.
      if (wpm > 0 && '$wpm' != settings.config('reader', 'wpm')) {
        settings.setConfig('reader', 'wpm', '$wpm');
      }
      return;
    }
    await link.callModule(
      'reader',
      answer(from == resumeFrom ? place : from, count),
    );
  }

  /// MODULE_CALL's argument for modules/reader.lua: 't:from:total:words',
  /// as many of count words as fit in [maxBytes].
  String answer(int from, int count) {
    final total = _words.length;
    final start = min(from, total);
    final out = StringBuffer('t:$start:$total:');
    final head = out.length;
    for (var i = start; i < min(total, start + count); i++) {
      final w = _words[i];
      if (out.length > head && out.length + 1 + w.length > maxBytes) break;
      if (out.length > head) out.write(' ');
      out.write(w);
    }
    return out.toString();
  }
}
