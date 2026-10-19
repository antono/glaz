import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaz/frame/protocol.dart';
import 'package:glaz/services/reader.dart';
import 'package:glaz/settings.dart';

import 'assistant_test.dart' show SentLink;

/// TEXT_GET as the glasses send it (modules/reader.lua).
List<int> request(int place, int from, int count, int wpm) {
  final b = ByteData(12)
    ..setUint8(0, textGet)
    ..setUint32(1, place)
    ..setUint32(5, from)
    ..setUint8(9, count)
    ..setUint16(10, wpm);
  return b.buffer.asUint8List();
}

void main() {
  group('words', () {
    test('ASCII, split on any space', () {
      expect(readerWords('  Привет,\n\tмир  137 '), ['Privet,', 'mir', '137']);
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

  group('service', () {
    late Settings settings;
    late SentLink link;
    late ReaderService reader;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      settings = await Settings.load();
      link = SentLink();
      final dir = Directory.systemTemp.createTempSync('glaz_reader');
      reader = ReaderService(link, settings, File('${dir.path}/reader.txt'));
      await reader.setText(List.generate(137, (i) => 'w$i').join(' '));
    });

    test('answers from the place on resume, and keeps the place', () async {
      settings.readerPlace = 100;
      await reader.onRequest(request(0, resumeFrom, 3, 300));
      expect(link.sent.last, (moduleCall, 'reader\nt:100:137:w100 w101 w102'));
      expect(settings.readerPlace, 100);

      await reader.onRequest(request(110, 103, 2, 300));
      expect(link.sent.last, (moduleCall, 'reader\nt:103:137:w103 w104'));
      expect(settings.readerPlace, 110);
    });

    test('the end of the text, and no text', () async {
      await reader.onRequest(request(130, 135, 60, 300));
      expect(link.sent.last.$2, 'reader\nt:135:137:w135 w136');
      await reader.setText('');
      await reader.onRequest(request(0, resumeFrom, 60, 300));
      expect(link.sent.last.$2, 'reader\nt:0:0:');
    });

    test('an answer fits in maxBytes', () {
      final a = reader.answer(0, 255);
      expect(a.length, lessThanOrEqualTo(ReaderService.maxBytes));
    });

    test('a pause keeps the speed; a request for words does not', () async {
      await reader.onRequest(request(5, 6, 60, 450));
      expect(settings.config('reader', 'wpm'), isNull);
      await reader.onRequest(request(5, 0, 0, 450));
      expect(settings.config('reader', 'wpm'), '450');
      expect(settings.readerPlace, 5);
    });

    test('the text and the place outlive a restart', () async {
      settings.readerPlace = 42;
      final again = ReaderService(link, settings, reader.file);
      await again.load();
      expect(again.words.length, 137);
      expect(again.place, 42);
    });
  });
}
