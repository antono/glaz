import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:glaz/frame/link.dart';
import 'package:glaz/services/glasses_files.dart';

void main() {
  test('a listing: folders first, then files by name, with sizes', () {
    final list = parseListing('f\t137\tmain.lua\nd\tphotos\nf\t12\tabout.lua');
    expect(list.map((e) => e.name), ['photos', 'about.lua', 'main.lua']);
    expect(list.first.folder, isTrue);
    expect(list.last.size, 137);
  });

  test('an answer in packets is put back together', () async {
    final files = GlassesFiles(FrameLink());
    // the link is not connected, so nothing is sent; answer as the glasses
    // would, to the id the request will take (1)
    final reading = files.read('main.lua');
    await Future<void>.delayed(Duration.zero);
    files.onPacket([0x1E, 1, 1, ...utf8.encode('+local x')]);
    files.onPacket([0x1E, 1, 0, ...utf8.encode(' = 137\n')]);
    expect(utf8.decode(await reading), 'local x = 137\n');
  });

  test("the glasses' error comes through", () async {
    final files = GlassesFiles(FrameLink());
    final listing = files.list('nope');
    await Future<void>.delayed(Duration.zero);
    files.onPacket([0x1D, 1, 0, ...utf8.encode('-no such directory')]);
    await expectLater(
      listing,
      throwsA(predicate((e) => '$e'.contains('no such directory'))),
    );
  });
}
