import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../frame/glyphs.dart';
import '../frame/link.dart';
import '../frame/protocol.dart';
import '../settings.dart';

/// The longest piece of a word the glasses show at once, hyphen included:
/// with the pivot letter at a third of the screen, longer runs off its
/// right edge (apps/reader/reader.lua).
const maxPiece = 13;

/// TEXT_GET's from: wherever the phone says the place is.
const resumeFrom = 0xFFFFFFFF;

/// The text as the glasses show it, a word at a time: what their font has
/// (Cyrillic and all), and a word
/// longer than [maxPiece] cut into pieces of about equal length, each but
/// the last ending in '-'. A hyphenated word is cut at its own hyphens
/// first.
List<String> readerWords(String text) => [
  for (final w in forGlasses(text).split(RegExp(r'\s+')))
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

/// Where the Reader's library is kept: the app's own folder, as the
/// settings.
Future<Directory> readerRoot() async =>
    Directory('${(await getApplicationSupportDirectory()).path}/reader');

/// A text in the Reader's library. Its words are counted when it is added;
/// the text itself is read from its file only when wanted.
class Book {
  Book(this.id, this.title, this.words, {this.place = 0, DateTime? added})
    : added = added ?? DateTime.now();

  final int id;
  String title;
  final int words;

  /// The number of the word the glasses showed last.
  int place;
  final DateTime added;

  /// The text number the glasses are told with every answer: a different
  /// one makes them drop what they hold. 1 to 255, from the id, so it
  /// stays the same across restarts of the phone app.
  int get version => id % 255 + 1;

  /// How far through, 0 to 100.
  int get percent => words == 0 ? 0 : (place + 1) * 100 ~/ words;

  Map<String, Object> toJson() => {
    'id': id,
    'title': title,
    'words': words,
    'place': place,
    'added': added.toIso8601String(),
  };

  static Book fromJson(Map<String, dynamic> j) => Book(
    j['id'] as int,
    j['title'] as String,
    j['words'] as int,
    place: j['place'] as int? ?? 0,
    added: DateTime.tryParse(j['added'] as String? ?? ''),
  );
}

/// A title for a text that came without one: its first few words.
String titleOf(String text) {
  final words = text.trim().split(RegExp(r'\s+'));
  final t = words.take(6).join(' ');
  return t.length > 48 ? '${t.substring(0, 47)}...' : t;
}

/// The Reader's library -- texts the user added, each with its place --
/// and which of them the glasses read. Feeds the glasses a few dozen words
/// at a time as they ask (TEXT_GET, docs/PROTOCOL.md, "Reader"): they have
/// no room for a book.
///
/// In [dir]: library.json, the list, and one `id`.txt per text, as the
/// user gave it.
class ReaderService extends ChangeNotifier {
  ReaderService(this.link, this.settings, this.dir) {
    link.events.where((m) => m.isNotEmpty && m[0] == textGet).listen(onRequest);
  }

  final FrameLink link;
  final Settings settings;
  final Directory dir;

  /// At most this much text in one answer: a MODULE_CALL the glasses
  /// put together in memory, a few hundred bytes (docs/PROTOCOL.md,
  /// "Memory on the glasses"); the glasses ask again for the rest.
  static const maxBytes = 300;

  final _books = <Book>[];
  int _next = 1;
  int? _current;
  List<String> _words = const [];

  /// Newest first.
  List<Book> get books => List.unmodifiable(_books.reversed);

  /// The text the glasses read; null with an empty library.
  Book? get current => _byId(_current);

  /// The current text's words, as the glasses get them.
  List<String> get words => _words;

  Book? _byId(int? id) {
    for (final b in _books) {
      if (b.id == id) return b;
    }
    return null;
  }

  File _file(int id) => File('${dir.path}/$id.txt');
  File get _index => File('${dir.path}/library.json');

  Future<void> load() async {
    try {
      if (!await _index.exists()) return;
      final j = jsonDecode(await _index.readAsString()) as Map<String, dynamic>;
      _next = j['next'] as int? ?? 1;
      _current = j['current'] as int?;
      _books
        ..clear()
        ..addAll([
          for (final b in j['books'] as List)
            Book.fromJson(b as Map<String, dynamic>),
        ]);
      await _loadWords();
    } catch (_) {}
    notifyListeners();
  }

  Future<void> _save() async {
    try {
      await dir.create(recursive: true);
      await _index.writeAsString(
        jsonEncode({
          'next': _next,
          'current': _current,
          'books': [for (final b in _books) b.toJson()],
        }),
      );
    } catch (_) {}
  }

  Future<void> _loadWords() async {
    final b = current;
    _words = b == null ? const [] : readerWords(await textOf(b));
  }

  /// A text as the user gave it; '' if its file is gone.
  Future<String> textOf(Book book) async {
    try {
      return await _file(book.id).readAsString();
    } catch (_) {
      return '';
    }
  }

  /// Adds a text and makes it the one to read, from the start.
  Future<Book> add(String text, {String title = ''}) async {
    final book = Book(
      _next++,
      title.trim().isEmpty ? titleOf(text) : title.trim(),
      readerWords(text).length,
    );
    await dir.create(recursive: true);
    await _file(book.id).writeAsString(text);
    _books.add(book);
    _current = book.id;
    _words = readerWords(text);
    await _save();
    notifyListeners();
    return book;
  }

  /// [text] made the one to read: the text in the library that is the
  /// same, from its own place, else a new one added -- a transcript sent
  /// twice is not two texts.
  Future<Book> addOrSelect(String text, {String title = ''}) async {
    for (final b in _books) {
      if (await textOf(b) == text) {
        await select(b);
        return b;
      }
    }
    return add(text, title: title);
  }

  /// Takes a text out of the library. If it was the one to read, the
  /// newest left is read instead.
  Future<void> remove(Book book) async {
    _books.removeWhere((b) => b.id == book.id);
    try {
      await _file(book.id).delete();
    } catch (_) {}
    if (_current == book.id) {
      _current = _books.isEmpty ? null : _books.last.id;
      await _loadWords();
    }
    await _save();
    notifyListeners();
  }

  /// The text the glasses read from now on, from its own place.
  Future<void> select(Book book) async {
    if (_current == book.id) return;
    _current = book.id;
    await _loadWords();
    await _save();
    notifyListeners();
  }

  Future<void> rename(Book book, String title) async {
    if (title.trim().isEmpty) return;
    book.title = title.trim();
    await _save();
    notifyListeners();
  }

  /// Back to the start of a text.
  Future<void> restart(Book book) async {
    book.place = 0;
    await _save();
    notifyListeners();
  }

  /// Puts the Reader on the glasses' screen, from the current text's place.
  Future<void> openOnGlasses() => link.openModule('reader', 'new');

  /// [0x0A, place (4), from (4), count, wpm (2), version], big-endian: the
  /// glasses' place and speed in text number version, and count words
  /// wanted from word number from -- [resumeFrom] for the place; none, when
  /// they only say where they are.
  @visibleForTesting
  Future<void> onRequest(List<int> m) async {
    if (m.length < 13) return;
    final b = ByteData.sublistView(Uint8List.fromList(m));
    final at = b.getUint32(1);
    var from = b.getUint32(5);
    final count = b.getUint8(9);
    final wpm = b.getUint16(10);
    final version = b.getUint8(12);
    // the place is the glasses' own unless they ask where it is -- and it
    // is in the text they hold, which may no longer be the current one
    if (from != resumeFrom) {
      for (final book in _books) {
        if (book.version == version && at < book.words && book.place != at) {
          book.place = at;
          await _save();
        }
      }
    }
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
    // words of another text than the one wanted now: the current one
    // from its place, and the new version tells the glasses to start over
    final book = current;
    if (book == null || version != book.version) from = resumeFrom;
    await link.callModule(
      'reader',
      answer(from == resumeFrom ? (book?.place ?? 0) : from, count),
    );
  }

  /// MODULE_CALL's argument for apps/reader/reader.lua:
  /// 't:from:total:version:words', as many of count words as fit in
  /// [maxBytes] of UTF-8. No text: 't:0:0:0:'.
  String answer(int from, int count) {
    final total = _words.length;
    final start = min(from, total);
    final out = StringBuffer('t:$start:$total:${current?.version ?? 0}:');
    final head = out.length;
    var bytes = head;
    for (var i = start; i < min(total, start + count); i++) {
      final w = _words[i];
      final n = utf8.encode(w).length;
      if (out.length > head && bytes + 1 + n > maxBytes) break;
      if (out.length > head) {
        out.write(' ');
        bytes++;
      }
      out.write(w);
      bytes += n;
    }
    return out.toString();
  }
}
