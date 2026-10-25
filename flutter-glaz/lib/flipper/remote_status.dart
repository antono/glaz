import 'dart:async';
import 'dart:io';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../services/glaz_log.dart';
import 'companion.dart';

/// What the Flipper's Glaz app (flipper-glaz/) shows of the glasses.
/// Null: not known; no [name], no glasses connected.
class GlassesStatus {
  const GlassesStatus({this.name, this.diskFree, this.memFree, this.app});
  final String? name;
  final int? diskFree;
  final int? memFree;
  final String? app;
}

/// The status as the Flipper reads it (`Status::parse` in
/// flipper-glaz/src/main.rs): a version byte, 1, then fields as tag,
/// length, value -- 1 the name, 2 free disk and 3 free memory in bytes
/// as u32 little-endian, 4 the app. A field not known is left out.
List<int> encodeStatus(GlassesStatus s) {
  final out = <int>[1];
  void text(int tag, String? v) {
    if (v == null) return;
    // The Flipper's fonts are ASCII, and it keeps 23 bytes.
    final b = [for (final c in v.codeUnits.take(maxText)) c < 0x80 ? c : 0x3F];
    out.addAll([tag, b.length, ...b]);
  }

  void number(int tag, int? v) {
    if (v == null) return;
    final n = v.clamp(0, 0xFFFFFFFF);
    out.addAll([tag, 4, n & 0xFF, n >> 8 & 0xFF, n >> 16 & 0xFF, n >> 24]);
  }

  text(1, s.name);
  number(2, s.diskFree);
  number(3, s.memFree);
  text(4, s.app);
  return out;
}

const maxText = 23;

/// A way to the Flipper's Glaz app: the status goes to it, its key
/// presses come back. The service is written against this, so tests give
/// it a Flipper of their own.
abstract class FlipperStatusPort {
  /// Connects to a Flipper with the Glaz app open; false when there is
  /// none.
  Future<bool> open();
  Future<void> close();
  Future<void> write(List<int> bytes);

  /// The keys characteristic's notifications, as they come: a press
  /// each (presses.dart).
  Stream<List<int>> get keys;

  /// Fires when an open link goes down by itself.
  Stream<void> get lost;
}

/// The glaz GATT service of the Flipper's Glaz app (flipper-glaz/src/
/// link.rs), advertised under the name 'Glaz'. On Android the Flipper is
/// paired through the Companion Device Manager ([FlipperCompanion]) and
/// found by the address it keeps; elsewhere it is looked for by the
/// service while Glaz runs, and the system pairs on the first write.
class FlipperStatusBle implements FlipperStatusPort {
  FlipperStatusBle({FlipperCompanion? companion})
    : companion = companion ?? FlipperCompanion();

  final FlipperCompanion companion;

  static final service = Guid('a96fe95e-083f-402e-8be1-a9d5235813ca');

  /// Phone -> Flipper: the status, an authenticated write, so the
  /// Flipper must be paired.
  static final status = Guid('99a2eadd-2f24-4073-b412-56fc14ba5ecb');

  /// Flipper -> phone: the presses, notified.
  static final pressed = Guid('fdf4c755-bc63-4750-9c39-e6ee8b8f55e9');

  /// The status is written whole: the MTU must hold it (link.rs drops a
  /// write in pieces).
  static const mtu = 185;

  /// Looked for this long where there is no Companion Device Manager.
  static const scanFor = Duration(seconds: 5);

  BluetoothDevice? _device;
  BluetoothCharacteristic? _status;
  StreamSubscription<BluetoothConnectionState>? _state;
  StreamSubscription<List<int>>? _pressed;
  final _keys = StreamController<List<int>>.broadcast();
  final _lost = StreamController<void>.broadcast();

  @override
  Stream<List<int>> get keys => _keys.stream;
  @override
  Stream<void> get lost => _lost.stream;

  @override
  Future<bool> open() async {
    if (Platform.isAndroid) {
      for (final p in await companion.paired()) {
        if (await _try(BluetoothDevice.fromId(p.address))) return true;
      }
      return false;
    }
    final d = await _scan();
    return d != null && await _try(d);
  }

  /// The nearest Flipper advertising the glaz service, if one does in
  /// [scanFor]. A connected Flipper does not advertise. The scanner is
  /// the link's too: what it finds is checked for the service, should
  /// the link start a scan of its own meanwhile.
  static Future<BluetoothDevice?> _scan() async {
    final found = Completer<BluetoothDevice?>();
    final sub = FlutterBluePlus.onScanResults.listen((results) {
      final glaz = results.where(
        (r) => r.advertisementData.serviceUuids.contains(service),
      );
      if (glaz.isNotEmpty && !found.isCompleted) {
        found.complete(glaz.reduce((a, b) => a.rssi >= b.rssi ? a : b).device);
      }
    });
    try {
      await FlutterBluePlus.startScan(
        withServices: [service],
        timeout: scanFor,
      );
      return await found.future.timeout(scanFor, onTimeout: () => null);
    } catch (_) {
      return null; // Bluetooth off, or not on this platform
    } finally {
      await sub.cancel();
      try {
        await FlutterBluePlus.stopScan();
      } catch (_) {}
    }
  }

  Future<bool> _try(BluetoothDevice d) async {
    try {
      await d.connect(timeout: const Duration(seconds: 10));
    } catch (_) {
      return false; // not in range, or not in the Glaz app
    }
    try {
      if (Platform.isAndroid) await d.requestMtu(mtu);
      var glaz = _find(await d.discoverServices());
      if (glaz == null && Platform.isAndroid) {
        // Android keeps a paired device's services, as they were the
        // first time: from Remote, or an older Glaz app. Ask afresh.
        await d.clearGattCache();
        glaz = _find(await d.discoverServices());
      }
      final char = glaz?.characteristics
          .where((c) => c.uuid == status)
          .firstOrNull;
      if (glaz == null || char == null) {
        glazLog(LogKind.link, 'Flipper remote: ${d.platformName} has no Glaz');
        await d.disconnect();
        return false;
      }
      _device = d;
      _status = char;
      await _state?.cancel();
      _state = d.connectionState.listen((s) {
        if (s == BluetoothConnectionState.disconnected && _device == d) {
          _device = null;
          _status = null;
          _pressed?.cancel();
          _pressed = null;
          _state?.cancel();
          _state = null;
          _lost.add(null);
        }
      });
      final keys = glaz.characteristics
          .where((c) => c.uuid == pressed)
          .firstOrNull;
      if (keys != null) {
        _pressed = keys.onValueReceived.listen(_keys.add);
        await keys.setNotifyValue(true);
      }
      glazLog(
        LogKind.link,
        'Flipper remote: ${d.platformName}, mtu ${d.mtuNow}'
        '${keys == null ? ', no keys' : ''}',
      );
      return true;
    } catch (e) {
      glazLog(LogKind.link, 'Flipper remote: $e', problem: true);
      await close();
      try {
        await d.disconnect();
      } catch (_) {}
      return false;
    }
  }

  static BluetoothService? _find(List<BluetoothService> services) =>
      services.where((s) => s.uuid == service).firstOrNull;

  @override
  Future<void> write(List<int> bytes) async {
    await _status?.write(bytes);
  }

  @override
  Future<void> close() async {
    await _state?.cancel();
    _state = null;
    await _pressed?.cancel();
    _pressed = null;
    final d = _device;
    _device = null;
    _status = null;
    try {
      await d?.disconnect();
    } catch (_) {}
  }
}
