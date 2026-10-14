import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:glaz/screens/about_screen.dart';

void main() {
  test('About shows the pubspec version', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final version = RegExp(r'^version: ([^+\s]+)', multiLine: true)
        .firstMatch(pubspec)!
        .group(1);
    expect(appVersion, version);
  });
}
