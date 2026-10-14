import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaz/frame/ascii.dart';
import 'package:glaz/frame/link.dart';
import 'package:glaz/services/network.dart';
import 'package:glaz/services/notifications.dart';
import 'package:glaz/settings.dart';

void main() {
  group('toAscii', () {
    test('transliterates Cyrillic, keeping capitals', () {
      expect(
        toAscii('Встречаемся в 137 кабинете'),
        'Vstrechaemsya v 137 kabinete',
      );
      expect(toAscii('Щука Ёж'), 'Shchuka Ezh');
    });

    test('maps typography, drops emoji, marks the unknown', () {
      expect(toAscii('«Да» — ok… 👍🏻'), '"Da" - ok... ');
      expect(toAscii('+16°C'), '+16C');
      expect(toAscii('日本語'), '?');
    });
  });

  group('notifications', () {
    test('encode makes three ASCII lines, cut to 200 bytes', () {
      final bytes = NotificationService.encode('Telegram', 'Анна', 'а\nб');
      expect(ascii.decode(bytes), 'Telegram\nAnna\na b');
      final long = NotificationService.encode('A', 'B', 'x' * 500);
      expect(long.length, NotificationService.maxBytes);
    });

    test('appName', () {
      expect(NotificationService.appName('org.telegram.messenger'), 'Telegram');
      expect(NotificationService.appName('com.spotify.music'), 'Spotify');
    });
  });

  group('network', () {
    late Settings settings;
    late List<http.Request> seen;

    NetworkService service(http.Response Function(http.Request) reply) =>
        NetworkService(
          FrameLink(),
          settings,
          client: MockClient((r) async {
            seen.add(r);
            return reply(r);
          }),
        );

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      settings = await Settings.load();
      seen = [];
    });

    test('403 without the permission, and nothing is fetched', () async {
      final net = service((_) => http.Response('hi', 200));
      final (status, body) = await net.answer(
        'weather',
        'GET',
        'https://x.test/',
        '',
      );
      expect(status, 403);
      expect(ascii.decode(body), 'not allowed: Glaz > Apps');
      expect(seen, isEmpty);
    });

    test('403 when the service is off, even with the permission', () async {
      settings.setNetAllowed('weather', true);
      settings.setService('network', false);
      final net = service((_) => http.Response('hi', 200));
      final (status, _) = await net.answer(
        'weather',
        'GET',
        'https://x.test/',
        '',
      );
      expect(status, 403);
    });

    test('400 for other methods and schemes', () async {
      settings.setNetAllowed('weather', true);
      final net = service((_) => http.Response('hi', 200));
      expect(
        (await net.answer('weather', 'DELETE', 'https://x.test/', '')).$1,
        400,
      );
      expect(
        (await net.answer('weather', 'GET', 'file:///etc/passwd', '')).$1,
        400,
      );
    });

    test('fetches when allowed, body cut to 4 KB', () async {
      settings.setNetAllowed('weather', true);
      final net = service((_) => http.Response('y' * 10000, 200));
      final (status, body) = await net.answer(
        'weather',
        'POST',
        'https://x.test/a',
        'q=137',
      );
      expect(status, 200);
      expect(body.length, NetworkService.maxBody);
      expect(seen.single.method, 'POST');
      expect(seen.single.body, 'q=137');
    });

    test('status 0 and the reason when the request fails', () async {
      settings.setNetAllowed('weather', true);
      final net = service((_) => throw Exception('offline'));
      final (status, body) = await net.answer(
        'weather',
        'GET',
        'https://x.test/',
        '',
      );
      expect(status, 0);
      expect(ascii.decode(body), contains('offline'));
    });

    test('a request split over packets is put back together', () async {
      settings.setNetAllowed('weather', true);
      final net = service((_) => http.Response('ok', 200));
      final text = utf8.encode('weather\nGET\nhttps://wttr.in/?format=%t\n');
      net.onPacket([0x19, 7, 1, ...text.sublist(0, 10)]);
      expect(net.log, isEmpty);
      net.onPacket([0x19, 7, 0, ...text.sublist(10)]);
      await pumpEventQueue();
      expect(net.log.single.module, 'weather');
      expect(net.log.single.url, 'https://wttr.in/?format=%t');
      expect(net.log.single.status, 200);
    });
  });
}
