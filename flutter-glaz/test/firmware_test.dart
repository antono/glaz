import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaz/frame/firmware.dart';
import 'package:glaz/frame/model.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('official releases and custom builds', () {
    final official = FirmwarePackage('a', 'v25.278.1113');
    final custom = FirmwarePackage('b', 'v26.287.1723-tap-tuning');
    expect(official.official, isTrue);
    expect(custom.official, isFalse);
    // day 278 of 2025 is 5 October; releases are stamped in UTC
    expect(official.built, DateTime.utc(2025, 10, 5, 11, 13));
    expect(custom.built, DateTime.utc(2026, 10, 14, 17, 23));
    expect(FirmwarePackage('c', 'nightly').built, isNull);
  });

  test('packages are found in the assets, newest first', () async {
    final list = await firmwarePackages(rootBundle, GlassesModel.frame);
    // the zips are fetched, not committed: nothing to check without them
    if (list.isEmpty) return;
    // two builds of one minute (stable, file-space) may share a stamp
    for (var i = 1; i < list.length; i++) {
      expect(list[i - 1].built!.isBefore(list[i].built!), isFalse);
    }
    expect(list.every((p) => p.asset.endsWith('.zip')), isTrue);
    expect(list.every((p) => p.model == GlassesModel.frame), isTrue);
  });

  test('each pair of glasses is offered its own firmware only', () {
    const assets = [
      'assets/firmware/frame-firmware-v25.278.1113.zip',
      'assets/firmware/frame-firmware-v26.287.1723-tap-tuning.zip',
      'assets/firmware/halo-firmware-v0.8.22.bin',
      'assets/firmware/other-firmware-v1.0.0.zip',
      'assets/logo/logo.png',
    ];
    final frame = firmwareFor(assets, GlassesModel.frame);
    expect(frame.map((p) => p.version), [
      'v25.278.1113',
      'v26.287.1723-tap-tuning',
    ]);
    expect(frame.every((p) => p.model == GlassesModel.frame), isTrue);
    final halo = firmwareFor(assets, GlassesModel.halo);
    expect(halo.map((p) => p.asset), [
      'assets/firmware/halo-firmware-v0.8.22.bin',
    ]);
    expect(halo.single.model, GlassesModel.halo);
  });
}
