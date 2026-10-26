import 'package:flutter/services.dart';

import '../services/glaz_log.dart';

/// A Flipper the phone is paired with: its Bluetooth address, and its
/// name when Android knows it.
class FlipperPaired {
  const FlipperPaired(this.address, this.name);
  final String address;
  final String? name;
}

/// Android's Companion Device Manager (Companion.kt): pairs the phone
/// with a Flipper running the Glaz app, found by the glaz service, and
/// keeps the association, which holds the Flipper's address. Elsewhere,
/// and in tests, there is none: nothing is paired.
class FlipperCompanion {
  static const channel = MethodChannel('glaz/companion');

  /// Shows Android's chooser, then pairs (Android asks for the PIN the
  /// Flipper shows); null when cancelled or it went wrong.
  Future<FlipperPaired?> pair() async {
    try {
      final m = await channel.invokeMapMethod<String, Object?>('associate');
      if (m == null) return null;
      final paired = FlipperPaired(
        m['address']! as String,
        m['name'] as String?,
      );
      if (m['bonded'] != true) {
        // associated, but the PIN was refused or never confirmed
        glazLog(
          LogKind.link,
          'Flipper pairing: ${paired.name ?? paired.address} not paired',
          problem: true,
        );
      }
      return paired;
    } on MissingPluginException {
      return null; // tests, and a platform without it
    } on PlatformException catch (e) {
      glazLog(LogKind.link, 'Flipper pairing: ${e.message}', problem: true);
      return null;
    }
  }

  /// The Flippers this app is associated with.
  Future<List<FlipperPaired>> paired() async {
    try {
      final list = await channel.invokeListMethod<Map>('associated');
      return [
        for (final m in list ?? const <Map>[])
          FlipperPaired(m['address'] as String, m['name'] as String?),
      ];
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    }
  }

  /// Drops the association with the Flipper at [address]; Android's
  /// pairing stays.
  Future<void> forget(String address) async {
    try {
      await channel.invokeMethod<void>('forget', address);
    } on MissingPluginException {
      return;
    } on PlatformException catch (e) {
      glazLog(LogKind.link, 'Flipper forget: ${e.message}', problem: true);
    }
  }

  /// Whether Android wakes glaz when a paired Flipper comes near
  /// (FlipperPresence.kt), for every Flipper paired; Android keeps it.
  Future<void> observe(bool on) async {
    try {
      await channel.invokeMethod<void>('observe', on);
    } on MissingPluginException {
      return;
    } on PlatformException catch (e) {
      glazLog(LogKind.link, 'Flipper observe: ${e.message}', problem: true);
    }
  }
}
