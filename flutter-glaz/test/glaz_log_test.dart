import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:glaz/frame/link.dart';
import 'package:glaz/frame/protocol.dart';
import 'package:glaz/services/glaz_log.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('glaz_log'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('kept in its file across restarts, the last of them', () async {
    final file = File('${tmp.path}/glaz.log');
    final log = GlazLog();
    await log.attach(file);
    for (var i = 0; i < GlazLog.keep + 137; i++) {
      log.add(LogKind.link, 'entry $i');
    }
    log.add(LogKind.glasses, 'weather err: x\ny', problem: true);
    expect(log.entries, hasLength(GlazLog.keep));
    await log.flush();

    final again = GlazLog();
    await again.attach(file);
    expect(again.entries, hasLength(GlazLog.keep));
    final last = again.entries.last;
    expect(last.kind, LogKind.glasses);
    expect(last.problem, isTrue);
    expect(last.text, 'weather err: x / y');
    expect(again.entries.first.text, 'entry 138');
  });

  test('clear empties it, file included', () async {
    final file = File('${tmp.path}/glaz.log');
    final log = GlazLog();
    await log.attach(file);
    log.add(LogKind.task, 'Upload: done');
    await log.flush();
    await log.clear();
    expect(log.entries, isEmpty);
    final again = GlazLog();
    await again.attach(file);
    expect(again.entries, isEmpty);
  });

  test('messages by name, text as text', () {
    expect(describeMessage(appOpen, 'weather'.codeUnits), 'APP_OPEN weather');
    expect(
      describeMessage(moduleCall, 'assistant\na:Hi'.codeUnits),
      'MODULE_CALL assistant / a:Hi',
    );
    expect(describeMessage(input, [1, 3]), 'INPUT 1 3');
    expect(describeMessage(menuHide, []), 'MENU_HIDE');
    expect(describeMessage(0x7E, [0]), '0x7e 0');
  });
}
