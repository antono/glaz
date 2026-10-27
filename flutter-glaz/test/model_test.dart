import 'package:flutter_test/flutter_test.dart';

import 'package:glaz/frame/model.dart';

void main() {
  test('the advertised name tells Frame from Halo', () {
    expect(GlassesModel.fromName('Frame 4F'), GlassesModel.frame);
    expect(GlassesModel.fromName('Halo 1A2B'), GlassesModel.halo);
    expect(GlassesModel.fromName(' Halo 1A2B'), GlassesModel.halo);
  });

  test('a name that says neither gives no model', () {
    expect(GlassesModel.fromName(null), isNull);
    expect(GlassesModel.fromName(''), isNull);
    expect(GlassesModel.fromName('My glasses'), isNull);
  });

  test('only Frame runs the glasses app for now', () {
    expect(GlassesModel.frame.supported, isTrue);
    expect(GlassesModel.halo.supported, isFalse);
  });
}
