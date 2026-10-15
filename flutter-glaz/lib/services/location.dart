import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../frame/link.dart';
import '../frame/protocol.dart';
import '../settings.dart';

/// Where the phone is, as far as this service knows: degrees, metres, and
/// when it was measured.
typedef Fix = ({double lat, double lon, double accuracy, DateTime at});

/// Answer statuses in LOCATION (docs/PROTOCOL.md, "Location").
const fixOk = 0, fixNotAllowed = 1, fixUnavailable = 2;

/// [id, status, lat, lon (int32 microdegrees), accuracy m, age s (uint16)],
/// big-endian. Coordinates are zero unless status is [fixOk].
Uint8List encodeFix(int id, int status, [Fix? fix, DateTime? now]) {
  final b = ByteData(14)
    ..setUint8(0, id)
    ..setUint8(1, status);
  if (status == fixOk && fix != null) {
    final age = (now ?? DateTime.now()).difference(fix.at).inSeconds;
    b
      ..setInt32(2, (fix.lat * 1e6).round())
      ..setInt32(6, (fix.lon * 1e6).round())
      ..setUint16(10, fix.accuracy.round().clamp(0, 65535))
      ..setUint16(12, age.clamp(0, 65535));
  }
  return b.buffer.asUint8List();
}

/// One answered request, for the Services screen. No coordinates kept.
class LocationLogEntry {
  LocationLogEntry(this.module, this.status);
  final String module;
  final int status;
  final DateTime at = DateTime.now();
}

/// Tells modules on the glasses where the phone is, when they ask
/// (LOCATION_GET) and the user allowed that module (Glaz > Menu). The
/// phone's own location permission is asked for from the Services tab,
/// never from a request: the glasses may ask when the phone is in a pocket.
class LocationService extends ChangeNotifier {
  LocationService(this.link, this.settings, {this.locate = phoneFix}) {
    link.events
        .where((m) => m.isNotEmpty && m[0] == locationGet)
        .listen(onRequest);
  }

  final FrameLink link;
  final Settings settings;

  /// Where the phone is now, or null. Replaceable in tests.
  final Future<Fix?> Function() locate;

  final log = <LocationLogEntry>[];

  /// [0x1C, id, module...]
  @visibleForTesting
  Future<void> onRequest(List<int> m) async {
    if (m.length < 3) return;
    final id = m[1];
    final module = utf8.decode(m.sublist(2), allowMalformed: true);
    final (status, fix) = await answer(module);
    log.insert(0, LocationLogEntry(module, status));
    if (log.length > 20) log.removeLast();
    notifyListeners();
    await link.send(location, encodeFix(id, status, fix));
  }

  Future<(int, Fix?)> answer(String module) async {
    if (!settings.serviceOn('location') || !settings.locAllowed(module)) {
      return (fixNotAllowed, null);
    }
    final fix = await locate();
    return fix == null ? (fixUnavailable, null) : (fixOk, fix);
  }

  /// Whether the phone lets this app read its position.
  static Future<bool> permitted() async {
    final p = await Geolocator.checkPermission();
    return p == LocationPermission.always || p == LocationPermission.whileInUse;
  }

  /// Asks the user, from the Services tab.
  Future<bool> requestPermission() async {
    final p = await Geolocator.requestPermission();
    notifyListeners();
    return p == LocationPermission.always || p == LocationPermission.whileInUse;
  }
}

/// The phone's position: a fresh fix within 10 s if it can get one, else
/// the last known one; null without permission or location turned off.
Future<Fix?> phoneFix() async {
  try {
    if (!await Geolocator.isLocationServiceEnabled()) return null;
    if (!await LocationService.permitted()) return null;
    Position? p;
    try {
      p = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 10),
        ),
      );
    } catch (_) {
      p = await Geolocator.getLastKnownPosition();
    }
    if (p == null) return null;
    return (
      lat: p.latitude,
      lon: p.longitude,
      accuracy: p.accuracy,
      at: p.timestamp,
    );
  } catch (_) {
    return null;
  }
}
