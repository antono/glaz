import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaz/frame/font.dart';
import 'package:glaz/frame/protocol.dart';
import 'package:glaz/services/gemini.dart';
import 'package:glaz/settings.dart';

import 'assistant_test.dart' show SentLink;

/// GEM_GET as the glasses send it (apps/gemini/gemini.lua).
List<int> request(int op, int page, int n, int top) {
  final b = ByteData(7)
    ..setUint8(0, geminiGet)
    ..setUint8(1, op)
    ..setUint8(2, page)
    ..setUint16(3, n)
    ..setUint16(5, top);
  return b.buffer.asUint8List();
}

/// The last MODULE_CALL for gemini: its header fields and its lines.
(List<String>, List<String>) lastAnswer(SentLink link) {
  final (code, text) = link.sent.last;
  expect(code, moduleCall);
  expect(text.startsWith('gemini\n'), isTrue);
  final lines = text.substring('gemini\n'.length).split('\n');
  return (lines.first.split(':'), lines.skip(1).toList());
}

const page137 = '''
# Room 137

Some text that is long enough to need more than one line on the glasses.
=> /next Next page
=> https://example.org A web page
* a point
> a quote
```
pre   formatted
```
''';

void main() {
  group('font', () {
    test('lines fit the width, words kept whole', () {
      final lines = wrapToWidth('Привет мир ' * 20, 300);
      expect(lines.length, greaterThan(1));
      for (final l in lines) {
        expect(textWidth(l), lessThanOrEqualTo(300));
      }
      expect(lines.join(' '), ('Привет мир ' * 20).trim());
    });

    test('a cut line ends in ..', () {
      final s = cutToWidth('a' * 137, 200);
      expect(s.endsWith('..'), isTrue);
      expect(textWidth(s), lessThanOrEqualTo(200));
    });
  });

  group('gemtext', () {
    test('kinds, links resolved, back and home around it', () {
      final p = gemtextPage('gemini://example.org/dir/', page137);
      final wire = p.lines.map((l) => l.wire).toList();
      expect(wire.first, 'L0|< back');
      expect(wire[1], 'Q|example.org/dir');
      expect(wire, contains('H|Room 137'));
      expect(wire, contains('L1|Next page'));
      expect(wire, contains('L2|A web page [https]'));
      expect(wire, contains('T|- a point'));
      expect(wire, contains('Q|a quote'));
      expect(wire, contains('P|pre   formatted'));
      expect(wire.sublist(wire.length - 2), ['L0|< back', 'L65535|home']);
      expect(p.links, ['gemini://example.org/next', 'https://example.org']);
      expect(wire.where((w) => w.startsWith('T|Some')).length, 1);
      expect(
        p.lines.where((l) => l.kind == 'T' && l.text.isNotEmpty).length,
        greaterThan(1),
      );
    });

    test('the home page is the bookmarks', () {
      final p = homePage(defaultBookmarks);
      expect(p.lines.map((l) => l.wire), [
        'H|Bookmarks',
        'L1|Gemini project',
        'L2|Antenna aggregator',
      ]);
      expect(p.links.first, 'gemini://geminiprotocol.net');
    });
  });

  group('service', () {
    late Settings settings;
    late SentLink link;
    late GeminiService gemini;
    final fetched = <String>[];

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      settings = await Settings.load();
      settings.setNetAllowed('gemini', true);
      link = SentLink();
      fetched.clear();
      gemini = GeminiService(
        link,
        settings,
        fetch: (uri) async {
          fetched.add('$uri');
          if (uri.path == '/old') {
            return (status: 31, meta: '/next', body: const <int>[]);
          }
          return (status: 20, meta: 'text/gemini', body: utf8.encode(page137));
        },
      );
    });

    test('the glasses first get the home page', () async {
      await gemini.onRequest(request(2, 0, 0, 0));
      final (head, lines) = lastAnswer(link);
      expect(head, ['p', '1', '0', '3', '0', '0']);
      expect(lines, [
        'H|Bookmarks',
        'L1|Gemini project',
        'L2|Antenna aggregator',
      ]);
    });

    test('a link opens, back returns where it was', () async {
      await gemini.onRequest(request(2, 0, 0, 0));
      await gemini.onRequest(request(1, 1, 1, 0));
      expect(fetched, ['gemini://geminiprotocol.net']);
      var (head, lines) = lastAnswer(link);
      expect(head[1], '2');
      expect(head[5], '1', reason: 'a page to go back to');
      expect(lines.first, 'L0|< back');

      // the page's own link, then back
      await gemini.onRequest(request(1, 2, 1, 0));
      expect(fetched.last, 'gemini://geminiprotocol.net/next');
      await gemini.onRequest(request(1, 3, 0, 0));
      (head, lines) = lastAnswer(link);
      expect(head[1], '4');
      expect(fetched.length, 2, reason: 'back from the cache');
      expect(gemini.url, 'gemini://geminiprotocol.net');

      await gemini.onRequest(request(1, 4, homeLink, 0));
      expect(gemini.url, homeUrl);
      (head, lines) = lastAnswer(link);
      expect(head[5], '0', reason: 'home: the double tap leaves');
    });

    test('redirects are followed', () async {
      final page = await gemini.load('gemini://example.org/old');
      expect(page.url, 'gemini://example.org/next');
    });

    test('without the Internet, a page that says so', () async {
      settings.setNetAllowed('gemini', false);
      final page = await gemini.load('gemini://example.org/');
      expect(fetched, isEmpty);
      expect(page.lines.map((l) => l.text), contains('No Internet'));
    });

    test('an answer fits in what the glasses hold', () async {
      setBookmarks(settings, [
        for (var i = 0; i < 137; i++) Bookmark('gemini://h$i.org', 'Site $i'),
      ]);
      await gemini.onRequest(request(2, 0, 0, 0));
      final (_, text) = link.sent.last;
      expect(utf8.encode(text).length, lessThan(GeminiService.maxBytes + 20));
      final (head, lines) = lastAnswer(link);
      expect(head[3], '138');
      expect(lines.length, lessThanOrEqualTo(GeminiService.maxLines));
      // the rest from where asked
      await gemini.onRequest(request(2, int.parse(head[1]), 100, 100));
      final (head2, lines2) = lastAnswer(link);
      expect(head2[2], '100');
      expect(head2[4], '100');
      expect(lines2.first, 'L100|Site 99');
    });
  });
}
