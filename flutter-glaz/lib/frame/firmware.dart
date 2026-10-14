import 'package:flutter/services.dart';

/// A firmware package the app can install: a Nordic DFU zip from
/// assets/firmware/ (tool/fetch_firmware.sh puts them there).
class FirmwarePackage {
  FirmwarePackage(this.asset, this.version);

  /// e.g. assets/firmware/frame-firmware-v25.278.1113.zip
  final String asset;

  /// e.g. v25.278.1113, or v26.287.1723-tap-tuning for a custom build
  final String version;

  /// Official releases are bare vYY.DDD.HHMM; anything after that marks a
  /// build of our own.
  bool get official => _official.hasMatch(version);
  static final _official = RegExp(r'^v\d\d\.\d{3}\.\d{4}$');

  /// The build time encoded in the version: year, day of year, UTC time.
  DateTime? get built {
    final m = RegExp(r'^v(\d\d)\.(\d{3})\.(\d\d)(\d\d)').firstMatch(version);
    if (m == null) return null;
    return DateTime.utc(2000 + int.parse(m[1]!))
        .add(Duration(days: int.parse(m[2]!) - 1))
        .add(Duration(hours: int.parse(m[3]!), minutes: int.parse(m[4]!)));
  }

  Future<Uint8List> bytes(AssetBundle bundle) async =>
      (await bundle.load(asset)).buffer.asUint8List();
}

final _name = RegExp(r'^assets/firmware/frame-firmware-(v[^/]+)\.zip$');

/// Newest first; custom builds and official ones sort together by date.
Future<List<FirmwarePackage>> firmwarePackages(AssetBundle bundle) async {
  final manifest = await AssetManifest.loadFromAssetBundle(bundle);
  final list = [
    for (final a in manifest.listAssets())
      if (_name.firstMatch(a) case final m?) FirmwarePackage(a, m[1]!),
  ];
  list.sort(
    (a, b) => (b.built ?? DateTime(0)).compareTo(a.built ?? DateTime(0)),
  );
  return list;
}
