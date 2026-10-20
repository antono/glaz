import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaz/frame/protocol.dart';
import 'package:glaz/services/reader.dart';
import 'package:glaz/settings.dart';

import 'assistant_test.dart' show SentLink;

/// TEXT_GET as the glasses send it (modules/reader.lua).
List<int> request(int place, int from, int count, int wpm, int text) {
  final b = ByteData(13)
    ..setUint8(0, textGet)
    ..setUint32(1, place)
    ..setUint32(5, from)
    ..setUint8(9, count)
    ..setUint16(10, wpm)
    ..setUint8(12, text);
  return b.buffer.asUint8List();
}

void main() {
  group('words', () {
    test('Cyrillic kept, split on any space', () {
      expect(readerWords('  Привет,\n\tмир  137 '), ['Привет,', 'мир', '137']);
      expect(splitWord('достопримечательность'), [
        'достопримеч-',
        'ательность',
      ]);
    });

    test('a long word is cut evenly, the pieces hyphenated', () {
      expect(splitWord('extraordinarily'), ['extraord-', 'inarily']);
      expect(splitWord('short'), ['short']);
      for (final p in splitWord('a' * 137)) {
        expect(p.length, lessThanOrEqualTo(maxPiece));
      }
    });

    test('a hyphenated word is cut at its own hyphens first', () {
      expect(splitWord('state-of-the-art-machinery'), [
        'state-of-the-',
        'art-machinery',
      ]);
      expect(splitWord('well-intentioned-ness'), [
        'well-',
        'intentioned-',
        'ness',
      ]);
    });
  });

  group('library', () {
    late Settings settings;
    late SentLink link;
    late Directory dir;
    late ReaderService reader;
    late Book book;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      settings = await Settings.load();
      link = SentLink();
      dir = Directory.systemTemp.createTempSync('glaz_reader');
      reader = ReaderService(link, settings, dir);
      book = await reader.add(List.generate(137, (i) => 'w$i').join(' '));
    });

    test('a new text is read, titled by its first words', () {
      expect(reader.current, book);
      expect(book.title, 'w0 w1 w2 w3 w4 w5');
      expect(book.words, 137);
    });

    test('a text sent again is the one there, not a second', () async {
      final other = await reader.add('Купить молоко');
      expect(reader.current, other);
      final again = await reader.addOrSelect(
        List.generate(137, (i) => 'w$i').join(' '),
        title: 'Recording',
      );
      expect(again, book);
      expect(reader.current, book);
      expect(reader.books, hasLength(2));
      final third = await reader.addOrSelect('new', title: 'Recording');
      expect(third.title, 'Recording');
      expect(reader.books, hasLength(3));
    });

    test('answers from the place on resume, and keeps the place', () async {
      final v = book.version;
      book.place = 100;
      await reader.onRequest(request(0, resumeFrom, 3, 300, 0));
      expect(link.sent.last, (
        moduleCall,
        'reader\nt:100:137:$v:w100 w101 w102',
      ));
      expect(book.place, 100);

      await reader.onRequest(request(110, 103, 2, 300, v));
      expect(link.sent.last, (moduleCall, 'reader\nt:103:137:$v:w103 w104'));
      expect(book.place, 110);
    });

    test('the end of the text, and no text', () async {
      await reader.onRequest(request(130, 135, 60, 300, book.version));
      expect(link.sent.last.$2, 'reader\nt:135:137:${book.version}:w135 w136');
      await reader.remove(book);
      expect(reader.current, isNull);
      await reader.onRequest(request(0, resumeFrom, 60, 300, 0));
      expect(link.sent.last.$2, 'reader\nt:0:0:0:');
    });

    test('another text picked while the glasses read the first', () async {
      final second = await reader.add('one two three', title: 'Second');
      expect(reader.current, second);
      // the glasses still hold the first: their place goes to it, and the
      // answer is the second from its place, with its own number
      await reader.onRequest(request(40, 60, 60, 300, book.version));
      expect(book.place, 40);
      expect(second.place, 0);
      expect(
        link.sent.last.$2,
        'reader\nt:0:3:${second.version}:one two three',
      );

      await reader.select(book);
      await reader.onRequest(request(1, 3, 60, 300, second.version));
      expect(
        link.sent.last.$2,
        startsWith('reader\nt:40:137:${book.version}:w40 '),
      );
      expect(second.place, 1);
    });

    test('an answer fits in maxBytes, of UTF-8', () async {
      expect(
        reader.answer(0, 255).length,
        lessThanOrEqualTo(ReaderService.maxBytes),
      );
      await reader.add(List.filled(137, 'слово').join(' '));
      final answer = reader.answer(0, 255);
      expect(answer, contains('слово слово'));
      expect(
        utf8.encode(answer).length,
        lessThanOrEqualTo(ReaderService.maxBytes),
      );
    });

    test('a pause keeps the speed; a request for words does not', () async {
      await reader.onRequest(request(5, 6, 60, 450, book.version));
      expect(settings.config('reader', 'wpm'), isNull);
      await reader.onRequest(request(5, 0, 0, 450, book.version));
      expect(settings.config('reader', 'wpm'), '450');
      expect(book.place, 5);
    });

    test('the library outlives a restart; delete takes the file', () async {
      final second = await reader.add('one two three', title: 'Second');
      await reader.select(book);
      await reader.restart(book);
      book.place = 42;
      await reader.rename(book, 'First');
      final again = ReaderService(link, settings, dir);
      await again.load();
      expect([for (final b in again.books) b.title], ['Second', 'First']);
      expect(again.current?.title, 'First');
      expect(again.current?.place, 42);
      expect(again.words.length, 137);

      await again.remove(again.current!);
      expect(again.current?.id, second.id);
      expect(again.words, ['one', 'two', 'three']);
      expect(File('${dir.path}/${book.id}.txt').existsSync(), isFalse);
    });
  });
}
