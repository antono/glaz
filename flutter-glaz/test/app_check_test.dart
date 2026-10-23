import 'package:flutter_test/flutter_test.dart';

import 'package:glaz/services/app_check.dart';

void main() {
  test('what the glasses have for an app', () {
    // the app answered: the REPL is not asked
    expect(glassesAppFrom(heard: true), GlassesApp.running);
    expect(glassesAppFrom(heard: false, repl: 'no app'), GlassesApp.missing);
    expect(glassesAppFrom(heard: false, repl: 'app'), GlassesApp.stopped);
    // neither answered: a busy app, or asleep
    expect(glassesAppFrom(heard: false), GlassesApp.unknown);
  });

  test('the probe asks for main.lua, and prints either answer', () {
    expect(AppCheck.probe, contains("'main.lua'"));
    expect(AppCheck.probe, contains("'no app'"));
    expect(AppCheck.probe.codeUnits.every((c) => c < 128), isTrue);
  });
}
