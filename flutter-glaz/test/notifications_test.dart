import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaz/frame/protocol.dart';
import 'package:glaz/services/notifications.dart';
import 'package:glaz/settings.dart';

import 'assistant_test.dart' show SentLink;

/// NOTICES_GET as the glasses send it (modules/notifications.lua).
List<int> request(int op, int n) {
  final b = ByteData(6)
    ..setUint8(0, noticesGet)
    ..setUint8(1, op)
    ..setUint32(2, n);
  return b.buffer.asUint8List();
}

void main() {
  late SentLink link;
  late NotificationService notices;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    link = SentLink();
    notices = NotificationService(link, await Settings.load());
    for (var i = 1; i <= 60; i++) {
      await notices.send('Telegram', 'Message $i', 'Meeting in room 137');
    }
  });

  test('newest first, the last 50 kept', () {
    expect(notices.kept.length, NotificationService.keep);
    expect(notices.kept.first.title, 'Message 60');
  });

  test('the list, a window at a time', () async {
    await notices.onRequest(request(1, 0));
    final (code, text) = link.sent.last;
    expect(code, moduleCall);
    final lines = text.split('\n');
    expect(lines[0], 'notifications');
    expect(lines[1], 'l:0:50');
    expect(lines.length - 2, NotificationService.window);
    expect(lines[2], '60|Telegram: Message 60');

    await notices.onRequest(request(1, 45));
    expect(link.sent.last.$2.split('\n').length - 2, 5);
  });

  test('one, all of it', () async {
    final id = notices.kept[3].id;
    await notices.onRequest(request(2, id));
    final lines = link.sent.last.$2.split('\n');
    expect(lines[1], 'f:$id');
    expect(lines[2], endsWith('Telegram'));
    expect(lines.sublist(3), ['Message 57', 'Meeting in room 137']);

    await notices.onRequest(request(2, 1));
    expect(link.sent.last.$2.split('\n').last, '(gone)');
  });
}
