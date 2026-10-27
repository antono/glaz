import 'package:flutter_test/flutter_test.dart';

import 'package:glaz/frame/model.dart';

void main() {
  test('the advertised name tells Frame from Halo', () {
    expect(GlassesModel.fromName('Frame 4F'), GlassesModel.frame);
    expect(GlassesModel.fromName('Halo 3C'), GlassesModel.halo);
    expect(GlassesModel.fromName(' Halo 3C'), GlassesModel.halo);
  });

  test('a name that says neither gives no model', () {
    expect(GlassesModel.fromName(null), isNull);
    expect(GlassesModel.fromName(''), isNull);
    expect(GlassesModel.fromName('My glasses'), isNull);
  });

  test('once connected, the Lua service tells Frame from Halo', () {
    const lua = '7a230001-5475-a6a4-654c-8431f6ad49c4';
    final frame = [
      lua,
      GlassesModel.luaWrite,
      '7a230003-5475-a6a4-654c-8431f6ad49c4',
    ];
    expect(GlassesModel.fromGatt(frame), GlassesModel.frame);
    expect(
      GlassesModel.fromGatt([...frame, GlassesModel.haloAudio.toUpperCase()]),
      GlassesModel.halo,
    );
    // not discovered yet, or no Lua service: no word
    expect(GlassesModel.fromGatt([]), isNull);
    expect(
      GlassesModel.fromGatt(['00002a19-0000-1000-8000-00805f9b34fb']),
      isNull,
    );
  });

  test('only Frame loads bytecode', () {
    expect(GlassesModel.frame.loadsBytecode, isTrue);
    expect(GlassesModel.halo.loadsBytecode, isFalse);
  });
}
