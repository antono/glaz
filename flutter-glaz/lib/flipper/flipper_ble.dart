import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../services/glaz_log.dart';

/// A way to the Flipper's RPC: bytes both ways. The mirror is written
/// against this, so tests give it a Flipper of their own.
abstract class FlipperPort {
  /// Connects; throws a [FlipperTrouble] when it cannot.
  Future<void> open();
  Future<void> close();
  Future<void> write(List<int> bytes);

  /// Bytes from the Flipper as they come; not split into messages.
  Stream<List<int>> get received;

  /// Fires when an open link goes down by itself.
  Stream<void> get lost;
}

/// Why the Flipper could not be reached, in words short enough for the
/// glasses (ASCII).
class FlipperTrouble implements Exception {
  const FlipperTrouble(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The Flipper Zero's serial service over Bluetooth (firmware
/// targets/f7/ble_glue/services/serial_service.c). The RPC starts by itself
/// once the phone is connected and paired; nothing is typed first, as over
/// USB. Pairing takes the PIN the Flipper shows.
class FlipperBle implements FlipperPort {
  static final service = Guid('8fe5b3d5-2e7f-4a98-2a48-7acc60fe0000');

  /// Flipper -> phone, indications.
  static final fromFlipper = Guid('19ed82ae-ed21-4c9d-4145-228e61fe0000');

  /// Phone -> Flipper.
  static final toFlipper = Guid('19ed82ae-ed21-4c9d-4145-228e62fe0000');

  /// Room left in the Flipper's buffer: a big-endian uint32, notified
  /// whole again once it has been emptied.
  static final flowControl = Guid('19ed82ae-ed21-4c9d-4145-228e63fe0000');

  /// Names a Flipper advertises with its serial service on: 'Flipper'
  /// and its name. In Bluetooth Remote it is 'Control' and its name, and
  /// has no RPC.
  static const namePrefix = 'Flipper ';

  static const scanFor = Duration(seconds: 8);

  BluetoothDevice? _device;
  BluetoothCharacteristic? _tx;
  final _received = StreamController<List<int>>.broadcast();
  final _lost = StreamController<void>.broadcast();
  final _subs = <StreamSubscription<Object?>>[];
  int _room = 0;
  Completer<void>? _roomCame;
  bool _closing = false;

  @override
  Stream<List<int>> get received => _received.stream;
  @override
  Stream<void> get lost => _lost.stream;

  @override
  Future<void> open() async {
    _closing = false;
    final device = await _find();
    _device = device;
    try {
      await device.connect(timeout: const Duration(seconds: 15));
    } catch (e) {
      throw FlipperTrouble('Flipper did not answer');
    }
    try {
      await _setUp(device);
    } catch (e) {
      glazLog(LogKind.link, 'Flipper: $e', problem: true);
      await close();
      if (e is FlipperTrouble) rethrow;
      throw const FlipperTrouble('Flipper: no RPC, pair again?');
    }
  }

  Future<void> _setUp(BluetoothDevice device) async {
    if (defaultTargetPlatform == TargetPlatform.android &&
        await device.bondState.first != BluetoothBondState.bonded) {
      // Android asks for the PIN the Flipper shows
      await device.createBond(timeout: 60);
    }
    final services = await device.discoverServices();
    final serial = services
        .where((s) => s.serviceUuid == service)
        .firstOrNull;
    if (serial == null) {
      throw const FlipperTrouble('Flipper: Bluetooth Remote on?');
    }
    BluetoothCharacteristic char(Guid id) =>
        serial.characteristics.firstWhere((c) => c.characteristicUuid == id);
    final rx = char(fromFlipper);
    final flow = char(flowControl);
    _tx = char(toFlipper);

    _subs.add(
      flow.onValueReceived.listen((v) {
        _room = _uint32(v);
        if (_room > 0) _roomCame?.complete();
        _roomCame = null;
      }),
    );
    _room = _uint32(await flow.read());
    await flow.setNotifyValue(true);

    _subs.add(rx.onValueReceived.listen(_received.add));
    await rx.setNotifyValue(true);

    _subs.add(
      device.connectionState.listen((s) {
        if (s == BluetoothConnectionState.disconnected && !_closing) {
          _lost.add(null);
        }
      }),
    );
    glazLog(LogKind.link, 'Flipper up, mtu ${device.mtuNow}, room $_room');
  }

  static int _uint32(List<int> v) =>
      v.length < 4 ? 0 : v[0] << 24 | v[1] << 16 | v[2] << 8 | v[3];

  /// A Flipper paired before, else the nearest one advertising.
  Future<BluetoothDevice> _find() async {
    try {
      final bonded = await FlutterBluePlus.bondedDevices;
      final known = bonded.where(
        (d) => d.platformName.startsWith(namePrefix),
      );
      if (known.isNotEmpty) return known.first;
    } catch (_) {
      // not on this platform (iOS): scan
    }
    final found = Completer<BluetoothDevice>();
    final sub = FlutterBluePlus.onScanResults.listen((results) {
      final flippers = results.where(
        (r) => r.advertisementData.advName.startsWith(namePrefix),
      );
      if (flippers.isNotEmpty && !found.isCompleted) {
        found.complete(
          flippers.reduce((a, b) => a.rssi >= b.rssi ? a : b).device,
        );
      }
    });
    try {
      await FlutterBluePlus.startScan(
        withKeywords: [namePrefix.trim()],
        timeout: scanFor,
      );
      return await found.future.timeout(
        scanFor,
        onTimeout: () => throw const FlipperTrouble('no Flipper found'),
      );
    } finally {
      await sub.cancel();
      try {
        await FlutterBluePlus.stopScan();
      } catch (_) {}
    }
  }

  @override
  Future<void> write(List<int> bytes) async {
    final tx = _tx;
    final device = _device;
    if (tx == null || device == null) throw const FlipperTrouble('closed');
    var at = 0;
    while (at < bytes.length) {
      if (_room <= 0) {
        // the Flipper says when its buffer is empty again
        _roomCame ??= Completer<void>();
        await _roomCame!.future.timeout(
          const Duration(seconds: 2),
          onTimeout: () => throw const FlipperTrouble('Flipper is stuck'),
        );
      }
      final n = min(min(_room, device.mtuNow - 3), bytes.length - at);
      await tx.write(bytes.sublist(at, at + n));
      _room -= n;
      at += n;
    }
  }

  @override
  Future<void> close() async {
    _closing = true;
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    _tx = null;
    _roomCame = null;
    try {
      await _device?.disconnect();
    } catch (_) {}
  }
}
